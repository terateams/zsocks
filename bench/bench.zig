//! zsocks-bench — a zero-dependency SOCKS5 load generator that drives real
//! requests through the proxy against a *pool* of public websites.
//!
//! Why a pool of sites? Hammering a single host quickly trips per-origin rate
//! limits and CDN throttling, which skews proxy benchmarks. Each request here
//! picks a random target from the list, so load is spread across many origins
//! and the numbers reflect the proxy's relay path rather than one site's quota.
//!
//! The client speaks SOCKS5 directly (no libc resolver): it connects to the
//! proxy by IP and hands the *domain* to the proxy (ATYP=0x03), so the proxy
//! performs DNS exactly as a real client would. HTTPS targets are driven with
//! the std TLS client over the tunnel; HTTP targets send a plain GET.
//!
//! Build/run:  zig build bench -- --proxy 127.0.0.1:1080 --requests 200 --concurrency 20

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const version = @import("build_options").version;

const tls_read_buf_len = 32 * 1024;
const tls_write_buf_len = 16 * 1024;
// Must exceed std.crypto.tls max_ciphertext_record_len (~16645B): the TLS layer
// asks the underlying socket reader/writer for a contiguous record-sized slice.
const sock_read_buf_len = 32 * 1024;
const sock_write_buf_len = 32 * 1024;

// A diverse pool of high-availability endpoints (global + China) plus a couple
// of sized download endpoints for throughput. Override with --list <file>.
const default_sites = [_][]const u8{
    // small/latency-oriented (200/204 with modest bodies)
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://www.google.com/generate_204",
    "https://github.com/robots.txt",
    "https://api.github.com/",
    "https://www.wikipedia.org/",
    "https://www.apple.com/",
    "https://www.microsoft.com/robots.txt",
    "https://www.bing.com/",
    "https://aws.amazon.com/robots.txt",
    "https://www.cloudflarestatus.com/",
    // China mainland origins
    "https://www.baidu.com/",
    "https://www.taobao.com/robots.txt",
    "https://www.qq.com/robots.txt",
    "https://www.aliyun.com/robots.txt",
    "https://www.bilibili.com/robots.txt",
    "https://mirrors.tuna.tsinghua.edu.cn/",
    "https://mirrors.aliyun.com/",
    "https://www.jd.com/robots.txt",
    "https://te3.lsn189.cn/static/images/nav-logo.png",
    // throughput-oriented sized downloads
    "https://speed.cloudflare.com/__down?bytes=2000000",
    "https://speed.cloudflare.com/__down?bytes=10000000",
};

const Target = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
    raw: []const u8,
};

fn parseUrl(url: []const u8) !Target {
    var s = url;
    var tls = true;
    var port: u16 = 443;
    if (std.mem.startsWith(u8, s, "https://")) {
        s = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s["http://".len..];
        tls = false;
        port = 80;
    }
    const slash = std.mem.indexOfScalar(u8, s, '/');
    const authority = if (slash) |i| s[0..i] else s;
    const path = if (slash) |i| s[i..] else "/";
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        // guard against IPv6 literals (not used in the default list)
        if (std.mem.indexOfScalar(u8, authority, ']') == null) {
            host = authority[0..c];
            port = try std.fmt.parseInt(u16, authority[c + 1 ..], 10);
        }
    }
    if (host.len == 0) return error.BadUrl;
    return .{ .tls = tls, .host = host, .port = port, .path = path, .raw = url };
}

const ErrKind = enum {
    none,
    connect,
    socks,
    auth,
    tls,
    request,
    response,
    timeout,
};

const Result = struct {
    ok: bool = false,
    site: usize = 0,
    status: u16 = 0,
    bytes: u64 = 0,
    ttfb_ms: f64 = 0,
    total_ms: f64 = 0,
    err: ErrKind = .none,
};

const Config = struct {
    proxy: net.IpAddress,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    requests: u32 = 100,
    concurrency: u32 = 10,
    seed: u64 = 0,
    insecure: bool = false,
};

const Shared = struct {
    io: Io,
    gpa: std.mem.Allocator,
    cfg: Config,
    sites: []const Target,
    results: []Result,
    next: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bundle: *std.crypto.Certificate.Bundle,
    ca_lock: *Io.RwLock,
};

const Worker = struct {
    sh: *Shared,
    id: u32,
    // per-worker reusable buffers
    sr: [sock_read_buf_len]u8 = undefined,
    sw: [sock_write_buf_len]u8 = undefined,
    tr: [tls_read_buf_len]u8 = undefined,
    tw: [tls_write_buf_len]u8 = undefined,
};

fn nowMs(io: Io) f64 {
    const ns = Io.Timestamp.now(io, .awake).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn writeSocksGreeting(w: *Io.Writer, auth: bool) !void {
    if (auth) {
        try w.writeAll(&.{ 0x05, 0x01, 0x02 });
    } else {
        try w.writeAll(&.{ 0x05, 0x01, 0x00 });
    }
    try w.flush();
}

fn socksHandshake(w: *Io.Writer, r: *Io.Reader, cfg: Config, t: Target) ErrKind {
    const want_auth = cfg.user != null;
    writeSocksGreeting(w, want_auth) catch return .socks;
    var method: [2]u8 = undefined;
    r.readSliceAll(&method) catch return .socks;
    if (method[0] != 0x05) return .socks;

    if (method[1] == 0x02) {
        if (cfg.user == null) return .auth;
        const u = cfg.user.?;
        const p = cfg.pass orelse "";
        if (u.len > 255 or p.len > 255) return .auth;
        var buf: [515]u8 = undefined;
        var n: usize = 0;
        buf[n] = 0x01;
        n += 1;
        buf[n] = @intCast(u.len);
        n += 1;
        @memcpy(buf[n .. n + u.len], u);
        n += u.len;
        buf[n] = @intCast(p.len);
        n += 1;
        @memcpy(buf[n .. n + p.len], p);
        n += p.len;
        w.writeAll(buf[0..n]) catch return .auth;
        w.flush() catch return .auth;
        var ar: [2]u8 = undefined;
        r.readSliceAll(&ar) catch return .auth;
        if (ar[1] != 0x00) return .auth;
    } else if (method[1] != 0x00) {
        return .socks;
    } else if (want_auth) {
        // We offered auth but server selected none — fine, continue.
    }

    // CONNECT with domain ATYP so the proxy resolves the target.
    if (t.host.len > 255) return .request;
    var req: [262]u8 = undefined;
    var n: usize = 0;
    req[n] = 0x05;
    n += 1; // ver
    req[n] = 0x01;
    n += 1; // CONNECT
    req[n] = 0x00;
    n += 1; // rsv
    req[n] = 0x03;
    n += 1; // ATYP=domain
    req[n] = @intCast(t.host.len);
    n += 1;
    @memcpy(req[n .. n + t.host.len], t.host);
    n += t.host.len;
    req[n] = @intCast(t.port >> 8);
    n += 1;
    req[n] = @intCast(t.port & 0xff);
    n += 1;
    w.writeAll(req[0..n]) catch return .socks;
    w.flush() catch return .socks;

    // Reply: VER REP RSV ATYP BND.ADDR BND.PORT
    var head: [4]u8 = undefined;
    r.readSliceAll(&head) catch return .socks;
    if (head[1] != 0x00) return .connect;
    const rest: usize = switch (head[3]) {
        0x01 => 4 + 2,
        0x04 => 16 + 2,
        0x03 => blk: {
            var l: [1]u8 = undefined;
            r.readSliceAll(&l) catch return .socks;
            break :blk @as(usize, l[0]) + 2;
        },
        else => return .socks,
    };
    var skip: [262]u8 = undefined;
    r.readSliceAll(skip[0..rest]) catch return .socks;
    return .none;
}

fn parseStatus(buf: []const u8) u16 {
    // "HTTP/1.1 200 ..." -> 200
    if (buf.len < 12) return 0;
    if (!std.mem.startsWith(u8, buf, "HTTP/")) return 0;
    const sp = std.mem.indexOfScalar(u8, buf, ' ') orelse return 0;
    const code = std.mem.trimStart(u8, buf[sp + 1 ..], " ");
    if (code.len < 3) return 0;
    return std.fmt.parseInt(u16, code[0..3], 10) catch 0;
}

fn asciiContainsChunked(h: []const u8) bool {
    // case-insensitive search for "chunked" in a Transfer-Encoding value
    if (h.len < 7) return false;
    var i: usize = 0;
    while (i + 7 <= h.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(h[i .. i + 7], "chunked")) return true;
    }
    return false;
}

fn readBody(r: *Io.Reader, n: u64) u64 {
    var scratch: [16 * 1024]u8 = undefined;
    var remaining = n;
    var got_total: u64 = 0;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, scratch.len));
        const got = r.readSliceShort(scratch[0..want]) catch break;
        if (got == 0) break;
        got_total += got;
        remaining -= got;
    }
    return got_total;
}

fn readToEof(r: *Io.Reader) u64 {
    var scratch: [16 * 1024]u8 = undefined;
    var got_total: u64 = 0;
    while (true) {
        const got = r.readSliceShort(&scratch) catch break;
        if (got == 0) break;
        got_total += got;
        if (got < scratch.len) break;
    }
    return got_total;
}

// Read and frame a single HTTP/1.x response, counting body bytes. Proper
// framing (Content-Length / chunked / status-implied / close-delimited) is
// required: many origins ignore "Connection: close" and keep the socket open,
// so reading blindly until EOF would stall for the server's idle timeout.
fn readResponse(r: *Io.Reader, res: *Result, t0: f64, io: Io) void {
    const status_line = r.takeDelimiterInclusive('\n') catch {
        res.err = .response;
        return;
    };
    res.ttfb_ms = nowMs(io) - t0;
    res.status = parseStatus(status_line);

    var content_len: ?u64 = null;
    var chunked = false;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch {
            res.err = .response;
            return;
        };
        const h = std.mem.trimEnd(u8, line, "\r\n");
        if (h.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(h, "content-length:")) {
            const v = std.mem.trim(u8, h["content-length:".len..], " \t");
            content_len = std.fmt.parseInt(u64, v, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(h, "transfer-encoding:")) {
            if (asciiContainsChunked(h)) chunked = true;
        }
    }

    var body: u64 = 0;
    const no_body = res.status == 204 or res.status == 304 or (res.status >= 100 and res.status < 200);
    if (no_body) {
        // intentionally empty
    } else if (chunked) {
        while (true) {
            const cl = r.takeDelimiterInclusive('\n') catch break;
            const sz_field = std.mem.trim(u8, std.mem.trimEnd(u8, cl, "\r\n"), " \t");
            const num = if (std.mem.indexOfScalar(u8, sz_field, ';')) |s| sz_field[0..s] else sz_field;
            const sz = std.fmt.parseInt(u64, num, 16) catch break;
            if (sz == 0) break;
            body += readBody(r, sz);
            _ = r.takeDelimiterInclusive('\n') catch break; // trailing CRLF
        }
    } else if (content_len) |cl| {
        body = readBody(r, cl);
    } else {
        // close-delimited: read until EOF (such servers do close the socket)
        body = readToEof(r);
    }
    res.bytes = body;
    res.ok = true;
}

fn doRequest(wk: *Worker, t: Target) Result {
    const sh = wk.sh;
    const io = sh.io;
    var res: Result = .{};
    const t0 = nowMs(io);

    var stream = sh.cfg.proxy.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    }) catch {
        res.err = .connect;
        return res;
    };
    defer stream.close(io);

    var sreader = stream.reader(io, &wk.sr);
    var swriter = stream.writer(io, &wk.sw);

    const hs = socksHandshake(&swriter.interface, &sreader.interface, sh.cfg, t);
    if (hs != .none) {
        res.err = hs;
        return res;
    }

    if (t.tls) {
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        var client = if (sh.cfg.insecure)
            std.crypto.tls.Client.init(&sreader.interface, &swriter.interface, .{
                .host = .no_verification,
                .ca = .no_verification,
                .read_buffer = &wk.tr,
                .write_buffer = &wk.tw,
                .entropy = &entropy,
                .realtime_now = Io.Timestamp.now(io, .real),
                .allow_truncation_attacks = true,
            }) catch {
                res.err = .tls;
                return res;
            }
        else
            std.crypto.tls.Client.init(&sreader.interface, &swriter.interface, .{
                .host = .{ .explicit = t.host },
                .ca = .{ .bundle = .{ .gpa = sh.gpa, .io = io, .lock = sh.ca_lock, .bundle = sh.bundle } },
                .read_buffer = &wk.tr,
                .write_buffer = &wk.tw,
                .entropy = &entropy,
                .realtime_now = Io.Timestamp.now(io, .real),
                .allow_truncation_attacks = true,
            }) catch {
                res.err = .tls;
                return res;
            };

        sendHttpGet(&client.writer, t) catch {
            res.err = .request;
            return res;
        };
        // The TLS writer only encrypts into the socket writer's buffer; we must
        // flush the underlying socket to actually transmit the request.
        swriter.interface.flush() catch {
            res.err = .request;
            return res;
        };
        readResponse(&client.reader, &res, t0, io);
    } else {
        sendHttpGet(&swriter.interface, t) catch {
            res.err = .request;
            return res;
        };
        readResponse(&sreader.interface, &res, t0, io);
    }

    res.total_ms = nowMs(io) - t0;
    return res;
}

fn sendHttpGet(w: *Io.Writer, t: Target) !void {
    try w.writeAll("GET ");
    try w.writeAll(t.path);
    try w.writeAll(" HTTP/1.1\r\nHost: ");
    try w.writeAll(t.host);
    try w.writeAll("\r\nUser-Agent: zsocks-bench/");
    try w.writeAll(version);
    try w.writeAll("\r\nAccept: */*\r\nConnection: close\r\n\r\n");
    try w.flush();
}

fn workerMain(wk: *Worker) void {
    const sh = wk.sh;
    var prng = std.Random.DefaultPrng.init(sh.cfg.seed ^ (@as(u64, wk.id) << 32) ^ 0x9e3779b97f4a7c15);
    const rnd = prng.random();
    while (true) {
        const idx = sh.next.fetchAdd(1, .monotonic);
        if (idx >= sh.cfg.requests) break;
        const site = rnd.uintLessThan(usize, sh.sites.len);
        var r = doRequest(wk, sh.sites[site]);
        r.site = site;
        sh.results[idx] = r;
    }
}

fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const rank = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(rank));
    const hi: usize = @intFromFloat(@ceil(rank));
    if (lo == hi) return sorted[lo];
    const frac = rank - @floor(rank);
    return sorted[lo] * (1 - frac) + sorted[hi] * frac;
}

fn parseHostPort(s: []const u8) !net.IpAddress {
    const c = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.NeedPort;
    const host = s[0..c];
    const port = try std.fmt.parseInt(u16, s[c + 1 ..], 10);
    return net.IpAddress.parse(host, port) catch error.ProxyMustBeIp;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const vec = init.minimal.args.vector;
    const argv = try gpa.alloc([:0]const u8, vec.len);
    defer gpa.free(argv);
    for (vec, 0..) |p, i| argv[i] = std.mem.span(p);

    var cfg: Config = .{ .proxy = try net.IpAddress.parse("127.0.0.1", 1080) };
    var list_path: ?[]const u8 = null;
    cfg.seed = @bitCast(@as(i64, @truncate(Io.Timestamp.now(io, .real).nanoseconds)));

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--proxy")) {
            i += 1;
            cfg.proxy = try parseHostPort(argv[i]);
        } else if (std.mem.eql(u8, a, "--user")) {
            i += 1;
            cfg.user = argv[i];
        } else if (std.mem.eql(u8, a, "--pass")) {
            i += 1;
            cfg.pass = argv[i];
        } else if (std.mem.eql(u8, a, "--list")) {
            i += 1;
            list_path = argv[i];
        } else if (std.mem.eql(u8, a, "--requests") or std.mem.eql(u8, a, "-n")) {
            i += 1;
            cfg.requests = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--concurrency") or std.mem.eql(u8, a, "-c")) {
            i += 1;
            cfg.concurrency = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            cfg.seed = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--insecure")) {
            cfg.insecure = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            try printLine(io, "zsocks-bench {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try usage(io);
            return;
        } else {
            try printLine(io, "unknown arg: {s}\n", .{a});
            try usage(io);
            return;
        }
    }
    if (cfg.requests == 0) cfg.requests = 1;
    if (cfg.concurrency == 0) cfg.concurrency = 1;
    if (cfg.concurrency > cfg.requests) cfg.concurrency = cfg.requests;

    // Build the target list.
    var url_storage: std.ArrayList(u8) = .empty;
    defer url_storage.deinit(gpa);
    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(gpa);

    if (list_path) |lp| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, lp, gpa, .limited(1 << 20));
        defer gpa.free(data);
        var it = std.mem.tokenizeAny(u8, data, "\r\n");
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const start = url_storage.items.len;
            try url_storage.appendSlice(gpa, trimmed);
            const stored = url_storage.items[start..];
            const t = parseUrl(stored) catch {
                try printLine(io, "skipping bad url: {s}\n", .{trimmed});
                continue;
            };
            try targets.append(gpa, t);
        }
    } else {
        for (default_sites) |u| {
            try targets.append(gpa, try parseUrl(u));
        }
    }
    if (targets.items.len == 0) {
        try printLine(io, "no targets\n", .{});
        return;
    }

    // CA bundle (shared, read-only after rescan).
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    var ca_lock: Io.RwLock = .init;
    if (!cfg.insecure) {
        bundle.rescan(gpa, io, Io.Timestamp.now(io, .real)) catch {
            try printLine(io, "warning: could not load system CA bundle; use --insecure to skip verification\n", .{});
        };
    }

    const results = try gpa.alloc(Result, cfg.requests);
    defer gpa.free(results);
    @memset(results, .{});

    var sh: Shared = .{
        .io = io,
        .gpa = gpa,
        .cfg = cfg,
        .sites = targets.items,
        .results = results,
        .bundle = &bundle,
        .ca_lock = &ca_lock,
    };

    const workers = try gpa.alloc(Worker, cfg.concurrency);
    defer gpa.free(workers);
    const threads = try gpa.alloc(std.Thread, cfg.concurrency);
    defer gpa.free(threads);

    try banner(io, &cfg, targets.items.len);

    const wall0 = nowMs(io);
    for (0..cfg.concurrency) |w| {
        workers[w] = .{ .sh = &sh, .id = @intCast(w) };
    }
    for (0..cfg.concurrency) |w| {
        threads[w] = try std.Thread.spawn(.{}, workerMain, .{&workers[w]});
    }
    for (threads) |th| th.join();
    const wall_ms = nowMs(io) - wall0;

    try report(io, gpa, &sh, wall_ms);
}

fn report(io: Io, gpa: std.mem.Allocator, sh: *Shared, wall_ms: f64) !void {
    const results = sh.results;
    var ok: u32 = 0;
    var total_bytes: u64 = 0;
    var ttfbs: std.ArrayList(f64) = .empty;
    defer ttfbs.deinit(gpa);
    var totals: std.ArrayList(f64) = .empty;
    defer totals.deinit(gpa);

    var err_counts = [_]u32{0} ** std.meta.fields(ErrKind).len;
    const per_site_ok = try gpa.alloc(u32, sh.sites.len);
    defer gpa.free(per_site_ok);
    const per_site_n = try gpa.alloc(u32, sh.sites.len);
    defer gpa.free(per_site_n);
    @memset(per_site_ok, 0);
    @memset(per_site_n, 0);

    for (results) |r| {
        per_site_n[r.site] += 1;
        if (r.ok) {
            ok += 1;
            total_bytes += r.bytes;
            per_site_ok[r.site] += 1;
            try ttfbs.append(gpa, r.ttfb_ms);
            try totals.append(gpa, r.total_ms);
        } else {
            err_counts[@intFromEnum(r.err)] += 1;
        }
    }

    std.mem.sort(f64, ttfbs.items, {}, std.sort.asc(f64));
    std.mem.sort(f64, totals.items, {}, std.sort.asc(f64));

    const wall_s = wall_ms / 1000.0;
    const rps = @as(f64, @floatFromInt(results.len)) / wall_s;
    const mb = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const mbps = (@as(f64, @floatFromInt(total_bytes)) * 8.0) / (wall_s * 1_000_000.0);

    try printLine(io, "\n================ results ================\n", .{});
    try printLine(io, "requests     : {d} ({d} ok, {d} failed, {d:.1}% success)\n", .{
        results.len, ok, results.len - ok, 100.0 * @as(f64, @floatFromInt(ok)) / @as(f64, @floatFromInt(results.len)),
    });
    try printLine(io, "wall time    : {d:.2}s\n", .{wall_s});
    try printLine(io, "request rate : {d:.1} req/s\n", .{rps});
    try printLine(io, "data moved   : {d:.1} MB  =>  {d:.1} Mbps\n", .{ mb, mbps });
    if (ttfbs.items.len > 0) {
        try printLine(io, "ttfb  (ms)   : p50={d:.1}  p95={d:.1}  p99={d:.1}  max={d:.1}\n", .{
            percentile(ttfbs.items, 0.50), percentile(ttfbs.items, 0.95),
            percentile(ttfbs.items, 0.99), ttfbs.items[ttfbs.items.len - 1],
        });
        try printLine(io, "total (ms)   : p50={d:.1}  p95={d:.1}  p99={d:.1}  max={d:.1}\n", .{
            percentile(totals.items, 0.50), percentile(totals.items, 0.95),
            percentile(totals.items, 0.99), totals.items[totals.items.len - 1],
        });
    }

    if (results.len - ok > 0) {
        try printLine(io, "\nerrors:\n", .{});
        inline for (std.meta.fields(ErrKind), 0..) |f, idx| {
            if (comptime std.mem.eql(u8, f.name, "none")) continue;
            if (err_counts[idx] > 0) try printLine(io, "  {s:<10} {d}\n", .{ f.name, err_counts[idx] });
        }
    }

    try printLine(io, "\nper-site:\n", .{});
    for (sh.sites, 0..) |t, idx| {
        if (per_site_n[idx] == 0) continue;
        try printLine(io, "  {d:>3}/{d:<3} ok  {s}\n", .{ per_site_ok[idx], per_site_n[idx], t.raw });
    }
    try printLine(io, "=========================================\n", .{});
}

fn banner(io: Io, cfg: *const Config, nsites: usize) !void {
    try printLine(io, "zsocks-bench {s}\n", .{version});
    try printLine(io, "proxy        : ", .{});
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    cfg.proxy.format(&w) catch {};
    try printLine(io, "{s}\n", .{w.buffered()});
    try printLine(io, "auth         : {s}\n", .{if (cfg.user != null) "user/pass" else "none"});
    try printLine(io, "sites        : {d} in pool (random per request)\n", .{nsites});
    try printLine(io, "load         : {d} requests @ concurrency {d}\n", .{ cfg.requests, cfg.concurrency });
    try printLine(io, "tls verify   : {s}\n", .{if (cfg.insecure) "off (--insecure)" else "system CA bundle"});
    try printLine(io, "running ...\n", .{});
}

var stdout_buf: [4096]u8 = undefined;

fn printLine(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &fw.interface;
    try w.print(fmt, args);
    try w.flush();
}

fn usage(io: Io) !void {
    try printLine(io,
        \\zsocks-bench — SOCKS5 load generator over a pool of public sites
        \\
        \\usage: zig build bench -- [options]
        \\
        \\  --proxy <ip:port>     SOCKS5 proxy address (IP literal, default 127.0.0.1:1080)
        \\  --user <u>            SOCKS5 username
        \\  --pass <p>            SOCKS5 password
        \\  --list <file>         file of URLs (one per line) overriding the built-in pool
        \\  -n, --requests <N>    total requests to issue (default 100)
        \\  -c, --concurrency <C> concurrent workers (default 10)
        \\  --seed <n>            RNG seed for deterministic site selection
        \\  --insecure            skip TLS certificate/host verification
        \\  --version             print version and exit
        \\
    , .{});
}
