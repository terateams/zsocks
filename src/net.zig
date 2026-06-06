//! Thin, zero-allocation wrappers over libc socket syscalls via `std.c`.
//! Zig 0.16.0 removed `std.net`/`std.posix` socket helpers, so we talk to
//! the C library directly. This keeps full control over TCP and UDP and the
//! exact byte layouts the SOCKS5 protocol needs.

const std = @import("std");
const c = std.c;

pub const Fd = c.fd_t;
pub const invalid_fd: Fd = -1;

pub const Error = error{
    SocketCreate,
    SetSockOpt,
    Bind,
    Listen,
    Accept,
    Connect,
    Recv,
    Send,
    GetSockName,
    Resolve,
    AddressFamily,
    WouldBlock,
    Closed,
};

fn lastErrno() c.E {
    return @enumFromInt(c._errno().*);
}

/// A protocol-independent socket address (IPv4 or IPv6) backed by
/// `sockaddr.storage`. Constructed once and passed by pointer to syscalls.
pub const Addr = struct {
    storage: c.sockaddr.storage align(8) = std.mem.zeroes(c.sockaddr.storage),
    len: c.socklen_t = @sizeOf(c.sockaddr.storage),

    pub fn ptr(self: *const Addr) *const c.sockaddr {
        return @ptrCast(&self.storage);
    }
    pub fn mutPtr(self: *Addr) *c.sockaddr {
        return @ptrCast(&self.storage);
    }

    pub fn family(self: *const Addr) u16 {
        const in: *const c.sockaddr.in = @ptrCast(&self.storage);
        return in.family;
    }

    pub fn fromIp4(octets: [4]u8, port_be: u16) Addr {
        var a = Addr{};
        const in: *c.sockaddr.in = @ptrCast(&a.storage);
        in.* = .{ .port = port_be, .addr = @bitCast(octets) };
        a.len = @sizeOf(c.sockaddr.in);
        return a;
    }

    pub fn fromIp6(octets: [16]u8, port_be: u16) Addr {
        var a = Addr{};
        const in6: *c.sockaddr.in6 = @ptrCast(&a.storage);
        in6.* = .{ .port = port_be, .flowinfo = 0, .addr = octets, .scope_id = 0 };
        a.len = @sizeOf(c.sockaddr.in6);
        return a;
    }

    pub fn anyIp4(port_be: u16) Addr {
        return fromIp4(.{ 0, 0, 0, 0 }, port_be);
    }

    /// Port in network byte order.
    pub fn port(self: *const Addr) u16 {
        const in: *const c.sockaddr.in = @ptrCast(&self.storage);
        return in.port;
    }

    /// True when both addresses describe the same family/host (port ignored).
    pub fn sameHost(self: *const Addr, other: *const Addr) bool {
        if (self.family() != other.family()) return false;
        switch (self.family()) {
            c.AF.INET => {
                const a: *const c.sockaddr.in = @ptrCast(&self.storage);
                const b: *const c.sockaddr.in = @ptrCast(&other.storage);
                return a.addr == b.addr;
            },
            c.AF.INET6 => {
                const a: *const c.sockaddr.in6 = @ptrCast(&self.storage);
                const b: *const c.sockaddr.in6 = @ptrCast(&other.storage);
                return std.mem.eql(u8, &a.addr, &b.addr);
            },
            else => return false,
        }
    }

    /// True when both addresses match exactly, including port. Used to pin a
    /// UDP association to one client endpoint.
    pub fn eql(self: *const Addr, other: *const Addr) bool {
        if (!self.sameHost(other)) return false;
        return self.port() == other.port();
    }
};

pub fn tcpSocket(domain: u32) Error!Fd {
    const fd = c.socket(@intCast(domain), c.SOCK.STREAM, c.IPPROTO.TCP);
    if (fd < 0) return Error.SocketCreate;
    return fd;
}

pub fn udpSocket(domain: u32) Error!Fd {
    const fd = c.socket(@intCast(domain), c.SOCK.DGRAM, c.IPPROTO.UDP);
    if (fd < 0) return Error.SocketCreate;
    return fd;
}

pub fn setReuseAddr(fd: Fd) Error!void {
    var one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) != 0)
        return Error.SetSockOpt;
}

pub fn setTimeouts(fd: Fd, seconds: u32) void {
    if (seconds == 0) return;
    const tv = c.timeval{ .sec = @intCast(seconds), .usec = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(c.timeval));
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &tv, @sizeOf(c.timeval));
}

pub fn bindAddr(fd: Fd, addr: *const Addr) Error!void {
    if (c.bind(fd, addr.ptr(), addr.len) != 0) return Error.Bind;
}

pub fn listen(fd: Fd, backlog: u32) Error!void {
    if (c.listen(fd, @intCast(backlog)) != 0) return Error.Listen;
}

pub const Accepted = struct { fd: Fd, peer: Addr };

pub fn accept(fd: Fd) Error!Accepted {
    var peer = Addr{};
    const cfd = c.accept(fd, peer.mutPtr(), &peer.len);
    if (cfd < 0) {
        const e = lastErrno();
        if (e == .AGAIN or e == .INTR) return Error.WouldBlock;
        return Error.Accept;
    }
    return .{ .fd = cfd, .peer = peer };
}

/// O_NONBLOCK as a raw fcntl flag bit, derived from std.c's per-OS `O` layout.
const o_nonblock: c_int = blk: {
    var o: c.O = .{};
    o.NONBLOCK = true;
    break :blk @bitCast(o);
};

/// Toggle the socket's blocking mode. Used to bound connect() with poll().
fn setBlocking(fd: Fd, blocking: bool) Error!void {
    const cur = c.fcntl(fd, c.F.GETFL);
    if (cur < 0) return Error.SetSockOpt;
    const flags: c_int = if (blocking) cur & ~o_nonblock else cur | o_nonblock;
    if (c.fcntl(fd, c.F.SETFL, flags) < 0) return Error.SetSockOpt;
}

/// Connect with a bounded wait. A blocking connect() to a black-holed host can
/// hang for the kernel's SYN-retry default (~127 s on Linux), pinning a pool
/// slot and eroding the proxy's bounded-resource guarantee. We connect
/// non-blocking and poll for completion: `timeout_ms < 0` waits indefinitely
/// (matching the old blocking behaviour when --timeout=0), otherwise the
/// attempt is capped. The socket is restored to blocking mode on success so
/// the relay's SO_RCVTIMEO/SO_SNDTIMEO timeouts continue to apply.
pub fn connect(fd: Fd, addr: *const Addr, timeout_ms: i32) Error!void {
    try setBlocking(fd, false);
    if (c.connect(fd, addr.ptr(), addr.len) == 0) {
        try setBlocking(fd, true);
        return;
    }
    // EINTR can interrupt the syscall before it reports EINPROGRESS; the
    // attempt is still in flight in the kernel, so poll for completion too.
    const e = lastErrno();
    if (e != .INPROGRESS and e != .INTR) return Error.Connect;

    var pfd = [_]c.pollfd{pollfd(fd, Poll.OUT)};
    const n = Poll.wait(&pfd, timeout_ms) catch return Error.Connect;
    if (n == 0) return Error.Connect; // timed out

    // poll() readiness only means the handshake finished; SO_ERROR carries the
    // actual result (0 = connected, otherwise the connect errno).
    var err: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &err, &len) != 0) return Error.Connect;
    if (err != 0) return Error.Connect;

    try setBlocking(fd, true);
}

pub fn getSockName(fd: Fd) Error!Addr {
    var a = Addr{};
    if (c.getsockname(fd, a.mutPtr(), &a.len) != 0) return Error.GetSockName;
    return a;
}

pub fn close(fd: Fd) void {
    if (fd >= 0) _ = c.close(fd);
}

/// Sleep for `ms` milliseconds (best-effort; EINTR just shortens the wait).
pub fn sleepMs(ms: u32) void {
    const ts = c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = c.nanosleep(&ts, null);
}

pub fn shutdownWrite(fd: Fd) void {
    _ = c.shutdown(fd, c.SHUT.WR);
}

/// Read once; returns number of bytes (0 == peer closed).
pub fn recv(fd: Fd, buf: []u8) Error!usize {
    const n = c.recv(fd, buf.ptr, buf.len, 0);
    if (n < 0) {
        const e = lastErrno();
        if (e == .AGAIN or e == .INTR) return Error.WouldBlock;
        return Error.Recv;
    }
    return @intCast(n);
}

/// Write all bytes in `buf`, looping over partial writes.
pub fn sendAll(fd: Fd, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.send(fd, buf.ptr + off, buf.len - off, 0);
        if (n < 0) {
            const e = lastErrno();
            if (e == .INTR) continue;
            return Error.Send;
        }
        if (n == 0) return Error.Send;
        off += @intCast(n);
    }
}

pub const UdpPacket = struct { len: usize, from: Addr };

pub fn recvFrom(fd: Fd, buf: []u8) Error!UdpPacket {
    var from = Addr{};
    const n = c.recvfrom(fd, buf.ptr, buf.len, 0, from.mutPtr(), &from.len);
    if (n < 0) {
        const e = lastErrno();
        if (e == .AGAIN or e == .INTR) return Error.WouldBlock;
        return Error.Recv;
    }
    return .{ .len = @intCast(n), .from = from };
}

pub fn sendTo(fd: Fd, buf: []const u8, addr: *const Addr) Error!void {
    const n = c.sendto(fd, buf.ptr, buf.len, 0, addr.ptr(), addr.len);
    if (n < 0) return Error.Send;
}

pub const Poll = struct {
    pub const IN: i16 = @intCast(c.POLL.IN);
    pub const OUT: i16 = @intCast(c.POLL.OUT);
    pub const ERR: i16 = @intCast(c.POLL.ERR);
    pub const HUP: i16 = @intCast(c.POLL.HUP);

    pub fn wait(fds: []c.pollfd, timeout_ms: i32) Error!usize {
        while (true) {
            const r = c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
            if (r < 0) {
                if (lastErrno() == .INTR) continue;
                return Error.Recv;
            }
            return @intCast(r);
        }
    }
};

pub fn pollfd(fd: Fd, events: i16) c.pollfd {
    return .{ .fd = fd, .events = events, .revents = 0 };
}

/// Resolve `host` (IPv4 / IPv6 literal or domain) + `port` to an `Addr`.
/// Returns the first usable result. `port` is host byte order.
pub fn resolve(host: [:0]const u8, port: u16, want_dgram: bool) Error!Addr {
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = c.AF.UNSPEC;
    hints.socktype = if (want_dgram) c.SOCK.DGRAM else c.SOCK.STREAM;
    hints.protocol = if (want_dgram) c.IPPROTO.UDP else c.IPPROTO.TCP;

    var port_buf: [6]u8 = undefined;
    const svc = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return Error.Resolve;

    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host.ptr, svc.ptr, &hints, &res);
    if (@intFromEnum(rc) != 0) return Error.Resolve;
    defer if (res) |r| c.freeaddrinfo(r);

    var it = res;
    while (it) |ai| : (it = ai.next) {
        const sa = ai.addr orelse continue;
        if (ai.family == c.AF.INET or ai.family == c.AF.INET6) {
            var a = Addr{};
            const copy_len: usize = @min(@as(usize, @intCast(ai.addrlen)), @sizeOf(c.sockaddr.storage));
            @memcpy(std.mem.asBytes(&a.storage)[0..copy_len], @as([*]const u8, @ptrCast(sa))[0..copy_len]);
            a.len = ai.addrlen;
            return a;
        }
    }
    return Error.Resolve;
}

test "ipv4 addr roundtrip" {
    const a = Addr.fromIp4(.{ 127, 0, 0, 1 }, std.mem.nativeToBig(u16, 8080));
    try std.testing.expectEqual(@as(u16, c.AF.INET), a.family());
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 8080), a.port());
}
