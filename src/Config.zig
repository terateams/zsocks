//! Command-line configuration. zsocks has no config file; every setting is a
//! flag so it drops cleanly into a container `CMD`/`args` line.

const std = @import("std");

pub const version = "0.1.0";

pub const Config = struct {
    listen_host: [:0]const u8 = "0.0.0.0",
    listen_port: u16 = 1080,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    max_conns: u32 = 256,
    buf_size: usize = 16 * 1024,
    timeout_sec: u32 = 60,
    udp_enabled: bool = true,
    /// Address advertised to clients in the UDP ASSOCIATE reply. Defaults to
    /// the listen host; override when the proxy sits behind NAT/port-forward.
    udp_advertise: ?[:0]const u8 = null,

    pub fn authRequired(self: Config) bool {
        return self.username != null;
    }
};

pub const ParseResult = union(enum) {
    config: Config,
    help,
    version,
};

pub const ParseError = error{
    MissingValue,
    InvalidValue,
    UnknownFlag,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Parse argv (excluding program name). On error, writes a message to stderr
/// and returns the error so the caller can exit non-zero.
pub fn parse(args: []const [:0]const u8) ParseError!ParseResult {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-h") or eq(arg, "--help")) return .help;
        if (eq(arg, "-v") or eq(arg, "--version")) return .version;

        if (eq(arg, "--no-udp")) {
            cfg.udp_enabled = false;
            continue;
        }

        // All remaining flags require a value.
        const want_value = struct {
            fn next(list: []const [:0]const u8, idx: *usize) ParseError![:0]const u8 {
                if (idx.* + 1 >= list.len) return ParseError.MissingValue;
                idx.* += 1;
                return list[idx.*];
            }
        }.next;

        if (eq(arg, "-l") or eq(arg, "--listen")) {
            cfg.listen_host = try want_value(args, &i);
        } else if (eq(arg, "-p") or eq(arg, "--port")) {
            cfg.listen_port = parseU16(try want_value(args, &i)) catch return ParseError.InvalidValue;
        } else if (eq(arg, "-u") or eq(arg, "--user")) {
            cfg.username = try want_value(args, &i);
        } else if (eq(arg, "-P") or eq(arg, "--pass")) {
            cfg.password = try want_value(args, &i);
        } else if (eq(arg, "--max-conns")) {
            cfg.max_conns = parseUint(u32, try want_value(args, &i)) catch return ParseError.InvalidValue;
        } else if (eq(arg, "--buf-size")) {
            cfg.buf_size = parseUint(usize, try want_value(args, &i)) catch return ParseError.InvalidValue;
        } else if (eq(arg, "--timeout")) {
            cfg.timeout_sec = parseUint(u32, try want_value(args, &i)) catch return ParseError.InvalidValue;
        } else if (eq(arg, "--udp-advertise")) {
            cfg.udp_advertise = try want_value(args, &i);
        } else {
            std.debug.print("zsocks: unknown flag '{s}'\n", .{arg});
            return ParseError.UnknownFlag;
        }
    }

    // Validation.
    if (cfg.max_conns == 0) cfg.max_conns = 1;
    if (cfg.buf_size < 512) cfg.buf_size = 512;
    // Clamp idle timeout so it never overflows poll()'s i32 millisecond arg.
    const max_timeout_sec = std.math.maxInt(i32) / 1000;
    if (cfg.timeout_sec > max_timeout_sec) cfg.timeout_sec = max_timeout_sec;
    if (cfg.username != null and cfg.password == null) {
        std.debug.print("zsocks: --user requires --pass\n", .{});
        return ParseError.MissingValue;
    }
    if (cfg.password != null and cfg.username == null) {
        std.debug.print("zsocks: --pass requires --user\n", .{});
        return ParseError.MissingValue;
    }
    if (cfg.username) |un| {
        if (un.len > 255 or cfg.password.?.len > 255) {
            std.debug.print("zsocks: user/pass must be <= 255 bytes\n", .{});
            return ParseError.InvalidValue;
        }
    }
    return .{ .config = cfg };
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10);
}

fn parseUint(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

pub fn printHelp() void {
    std.debug.print(
        \\zsocks — a tiny, zero-dependency SOCKS5 proxy
        \\
        \\USAGE:
        \\  zsocks [OPTIONS]
        \\
        \\OPTIONS:
        \\  -l, --listen <host>     Bind address (default 0.0.0.0)
        \\  -p, --port <port>       Listen port (default 1080)
        \\  -u, --user <name>       Username; enables RFC1929 auth
        \\  -P, --pass <pass>       Password (required with --user)
        \\      --max-conns <n>     Max concurrent connections (default 256)
        \\      --buf-size <bytes>  Relay buffer per direction (default 16384)
        \\      --timeout <sec>     Socket idle timeout, 0=off (default 60)
        \\      --no-udp            Disable UDP ASSOCIATE (TCP only)
        \\      --udp-advertise <h> Address sent to clients for UDP relay
        \\                          (use when behind NAT; default = listen host)
        \\  -h, --help              Show this help
        \\  -v, --version           Show version
        \\
        \\MEMORY:
        \\  TCP peak ≈ max-conns × (2 × buf-size). Each active UDP ASSOCIATE adds
        \\  ~131 KB of relay buffers. Connections beyond max-conns are rejected,
        \\  so total memory stays bounded and predictable.
        \\
        \\EXAMPLES:
        \\  zsocks -p 1080
        \\  zsocks -p 1080 -u alice -P secret --max-conns 128
        \\  zsocks -p 1080 --no-udp --buf-size 8192
        \\
    , .{});
}

pub fn printVersion() void {
    std.debug.print("zsocks {s}\n", .{version});
}

test "parse defaults" {
    const r = try parse(&.{});
    try std.testing.expect(r == .config);
    try std.testing.expectEqual(@as(u16, 1080), r.config.listen_port);
    try std.testing.expect(!r.config.authRequired());
    try std.testing.expect(r.config.udp_enabled);
}

test "parse auth + flags" {
    const args = [_][:0]const u8{ "-p", "9050", "-u", "bob", "-P", "pw", "--no-udp", "--max-conns", "10" };
    const r = try parse(&args);
    try std.testing.expectEqual(@as(u16, 9050), r.config.listen_port);
    try std.testing.expect(r.config.authRequired());
    try std.testing.expect(!r.config.udp_enabled);
    try std.testing.expectEqual(@as(u32, 10), r.config.max_conns);
}

test "user without pass fails" {
    const args = [_][:0]const u8{ "-u", "bob" };
    try std.testing.expectError(ParseError.MissingValue, parse(&args));
}

test "help and version" {
    try std.testing.expect((try parse(&.{"-h"})) == .help);
    try std.testing.expect((try parse(&.{"--version"})) == .version);
}
