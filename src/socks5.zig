//! SOCKS5 (RFC 1928) protocol handling: method negotiation, RFC 1929
//! username/password auth, the CONNECT command and UDP ASSOCIATE, plus the
//! bidirectional relay loops. One instance handles one client connection.

const std = @import("std");
const net = @import("net.zig");
const Config = @import("Config.zig").Config;
const c = std.c;

const VER: u8 = 0x05;

const Method = struct {
    const no_auth: u8 = 0x00;
    const userpass: u8 = 0x02;
    const none_acceptable: u8 = 0xFF;
};

const Cmd = struct {
    const connect: u8 = 0x01;
    const udp_assoc: u8 = 0x03;
};

const Atyp = struct {
    const ipv4: u8 = 0x01;
    const domain: u8 = 0x03;
    const ipv6: u8 = 0x04;
};

const Rep = struct {
    const ok: u8 = 0x00;
    const general_failure: u8 = 0x01;
    const host_unreachable: u8 = 0x04;
    const conn_refused: u8 = 0x05;
    const cmd_not_supported: u8 = 0x07;
    const atyp_not_supported: u8 = 0x08;
};

const max_udp = 65535;

/// Destination parsed from a SOCKS5 request or UDP header. IP literals are
/// turned into a ready `net.Addr`; domains are resolved on demand.
const Target = struct {
    direct: ?net.Addr = null,
    host: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,

    fn resolve(self: *Target, dgram: bool) !net.Addr {
        if (self.direct) |a| return a;
        self.host[self.host_len] = 0;
        return net.resolve(self.host[0..self.host_len :0], self.port, dgram);
    }
};

/// Parse an address (ATYP + ADDR + PORT) from `data`, returning bytes
/// consumed. Shared by the TCP request path and the UDP header path.
fn parseAddr(atyp: u8, data: []const u8, target: *Target) ?usize {
    switch (atyp) {
        Atyp.ipv4 => {
            if (data.len < 4 + 2) return null;
            const octets: [4]u8 = data[0..4].*;
            const port_be: u16 = @bitCast(data[4..6].*);
            target.direct = net.Addr.fromIp4(octets, port_be);
            target.port = std.mem.readInt(u16, data[4..6], .big);
            return 6;
        },
        Atyp.ipv6 => {
            if (data.len < 16 + 2) return null;
            const octets: [16]u8 = data[0..16].*;
            const port_be: u16 = @bitCast(data[16..18].*);
            target.direct = net.Addr.fromIp6(octets, port_be);
            target.port = std.mem.readInt(u16, data[16..18], .big);
            return 18;
        },
        Atyp.domain => {
            if (data.len < 1) return null;
            const dlen = data[0];
            if (data.len < 1 + @as(usize, dlen) + 2) return null;
            @memcpy(target.host[0..dlen], data[1 .. 1 + dlen]);
            target.host_len = dlen;
            target.port = std.mem.readInt(u16, data[1 + dlen ..][0..2], .big);
            return 1 + @as(usize, dlen) + 2;
        },
        else => return null,
    }
}

pub const Connection = struct {
    gpa: std.mem.Allocator,
    cfg: *const Config,
    client_fd: net.Fd,
    peer: net.Addr,
    /// Two relay buffers owned by the connection pool (one per direction).
    buf_c2r: []u8,
    buf_r2c: []u8,

    pub fn run(self: *Connection) void {
        net.setTimeouts(self.client_fd, self.cfg.timeout_sec);
        defer net.close(self.client_fd);
        self.handshake() catch return;
    }

    fn handshake(self: *Connection) !void {
        try self.negotiateMethod();
        if (self.cfg.authRequired()) try self.authUserPass();
        try self.handleRequest();
    }

    // --- Method negotiation -------------------------------------------------

    fn negotiateMethod(self: *Connection) !void {
        var head: [2]u8 = undefined;
        try self.readExact(&head);
        if (head[0] != VER) return error.BadVersion;
        const nmethods = head[1];
        var methods: [255]u8 = undefined;
        try self.readExact(methods[0..nmethods]);

        const want: u8 = if (self.cfg.authRequired()) Method.userpass else Method.no_auth;
        var ok = false;
        for (methods[0..nmethods]) |m| {
            if (m == want) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            _ = net.sendAll(self.client_fd, &.{ VER, Method.none_acceptable }) catch {};
            return error.NoAcceptableMethod;
        }
        try net.sendAll(self.client_fd, &.{ VER, want });
    }

    // --- RFC 1929 username/password ----------------------------------------

    fn authUserPass(self: *Connection) !void {
        var head: [2]u8 = undefined;
        try self.readExact(&head);
        if (head[0] != 0x01) return error.BadAuthVersion;
        const ulen = head[1];
        var ubuf: [255]u8 = undefined;
        try self.readExact(ubuf[0..ulen]);
        var plen_b: [1]u8 = undefined;
        try self.readExact(&plen_b);
        const plen = plen_b[0];
        var pbuf: [255]u8 = undefined;
        try self.readExact(pbuf[0..plen]);

        const user_ok = std.mem.eql(u8, ubuf[0..ulen], self.cfg.username.?);
        const pass_ok = std.mem.eql(u8, pbuf[0..plen], self.cfg.password.?);
        if (user_ok and pass_ok) {
            try net.sendAll(self.client_fd, &.{ 0x01, 0x00 });
        } else {
            _ = net.sendAll(self.client_fd, &.{ 0x01, 0x01 }) catch {};
            return error.AuthFailed;
        }
    }

    // --- Request ------------------------------------------------------------

    fn handleRequest(self: *Connection) !void {
        var head: [4]u8 = undefined;
        try self.readExact(&head);
        if (head[0] != VER) return error.BadVersion;
        const cmd = head[1];
        const atyp = head[3];

        var target = Target{};
        try self.readRequestAddr(atyp, &target);

        switch (cmd) {
            Cmd.connect => try self.doConnect(&target),
            Cmd.udp_assoc => {
                if (!self.cfg.udp_enabled) {
                    try self.replyError(Rep.cmd_not_supported);
                    return;
                }
                try self.doUdpAssociate();
            },
            else => try self.replyError(Rep.cmd_not_supported),
        }
    }

    /// Read DST.ADDR + DST.PORT for the given ATYP from the stream.
    fn readRequestAddr(self: *Connection, atyp: u8, target: *Target) !void {
        var buf: [1 + 256 + 2]u8 = undefined;
        switch (atyp) {
            Atyp.ipv4 => {
                try self.readExact(buf[0..6]);
                _ = parseAddr(atyp, buf[0..6], target) orelse return error.BadAddr;
            },
            Atyp.ipv6 => {
                try self.readExact(buf[0..18]);
                _ = parseAddr(atyp, buf[0..18], target) orelse return error.BadAddr;
            },
            Atyp.domain => {
                try self.readExact(buf[0..1]);
                const dlen = buf[0];
                const end = 1 + @as(usize, dlen) + 2;
                try self.readExact(buf[1..end]);
                _ = parseAddr(atyp, buf[0..end], target) orelse return error.BadAddr;
            },
            else => {
                try self.replyError(Rep.atyp_not_supported);
                return error.BadAtyp;
            },
        }
    }

    // --- CONNECT ------------------------------------------------------------

    fn doConnect(self: *Connection, target: *Target) !void {
        const remote = target.resolve(false) catch {
            try self.replyError(Rep.host_unreachable);
            return;
        };
        const rfd = net.tcpSocket(remote.family()) catch {
            try self.replyError(Rep.general_failure);
            return;
        };
        var rfd_owned = true;
        defer if (rfd_owned) net.close(rfd);

        net.setTimeouts(rfd, self.cfg.timeout_sec);
        net.connect(rfd, &remote) catch {
            try self.replyError(Rep.conn_refused);
            return;
        };

        const bound = net.getSockName(rfd) catch net.Addr.anyIp4(0);
        try self.replyOk(&bound);

        rfd_owned = false;
        defer net.close(rfd);
        self.relayTcp(rfd);
    }

    /// Bidirectional copy between client and remote. Each direction is closed
    /// independently on EOF (preserving TCP half-close), and the relay ends
    /// once both directions are done or the idle timeout elapses.
    fn relayTcp(self: *Connection, rfd: net.Fd) void {
        const timeout_ms = self.pollTimeout();
        const active = net.Poll.IN | net.Poll.ERR | net.Poll.HUP;
        var c2r_open = true; // client -> remote
        var r2c_open = true; // remote -> client
        var fds = [2]c.pollfd{
            net.pollfd(self.client_fd, net.Poll.IN),
            net.pollfd(rfd, net.Poll.IN),
        };
        while (c2r_open or r2c_open) {
            const n = net.Poll.wait(&fds, timeout_ms) catch return;
            if (n == 0) return; // idle timeout

            if (c2r_open and fds[0].revents & active != 0) {
                if (!pump(self.client_fd, rfd, self.buf_c2r)) {
                    net.shutdownWrite(rfd); // tell remote: no more client data
                    c2r_open = false;
                    fds[0].fd = -1; // stop polling this direction
                }
            }
            if (r2c_open and fds[1].revents & active != 0) {
                if (!pump(rfd, self.client_fd, self.buf_r2c)) {
                    net.shutdownWrite(self.client_fd);
                    r2c_open = false;
                    fds[1].fd = -1;
                }
            }
            fds[0].revents = 0;
            fds[1].revents = 0;
        }
    }

    // --- UDP ASSOCIATE ------------------------------------------------------

    fn doUdpAssociate(self: *Connection) !void {
        const ufd = net.udpSocket(c.AF.INET) catch {
            try self.replyError(Rep.general_failure);
            return;
        };
        defer net.close(ufd);
        net.setTimeouts(ufd, self.cfg.timeout_sec);
        var bind_addr = net.Addr.anyIp4(0);
        net.bindAddr(ufd, &bind_addr) catch {
            try self.replyError(Rep.general_failure);
            return;
        };

        const local = net.getSockName(ufd) catch {
            try self.replyError(Rep.general_failure);
            return;
        };

        // Allocate relay buffers *before* replying so a failure surfaces as a
        // SOCKS error rather than a silently-dead association.
        const in_buf = self.gpa.alloc(u8, max_udp) catch {
            try self.replyError(Rep.general_failure);
            return;
        };
        defer self.gpa.free(in_buf);
        const out_buf = self.gpa.alloc(u8, max_udp + 262) catch {
            try self.replyError(Rep.general_failure);
            return;
        };
        defer self.gpa.free(out_buf);

        const advertise_host = self.cfg.udp_advertise orelse self.cfg.listen_host;
        var advertised = net.resolve(advertise_host, 0, true) catch net.Addr.anyIp4(0);
        setPort(&advertised, local.port());
        try self.replyOk(&advertised);

        self.udpLoop(ufd, in_buf, out_buf);
    }

    fn udpLoop(self: *Connection, ufd: net.Fd, in_buf: []u8, out_buf: []u8) void {
        var up4: net.Fd = net.invalid_fd;
        var up6: net.Fd = net.invalid_fd;
        defer net.close(up4);
        defer net.close(up6);

        var client_addr: ?net.Addr = null;
        const timeout_ms = self.pollTimeout();

        while (true) {
            var fds: [4]c.pollfd = undefined;
            var nfds: usize = 0;
            const idx_ctrl = nfds;
            fds[nfds] = net.pollfd(self.client_fd, net.Poll.IN);
            nfds += 1;
            const idx_udp = nfds;
            fds[nfds] = net.pollfd(ufd, net.Poll.IN);
            nfds += 1;
            var idx_up4: ?usize = null;
            var idx_up6: ?usize = null;
            if (up4 != net.invalid_fd) {
                idx_up4 = nfds;
                fds[nfds] = net.pollfd(up4, net.Poll.IN);
                nfds += 1;
            }
            if (up6 != net.invalid_fd) {
                idx_up6 = nfds;
                fds[nfds] = net.pollfd(up6, net.Poll.IN);
                nfds += 1;
            }

            const ready = net.Poll.wait(fds[0..nfds], timeout_ms) catch return;
            if (ready == 0) return; // idle timeout ends the association

            // TCP control connection closing terminates the association.
            if (fds[idx_ctrl].revents & (net.Poll.IN | net.Poll.HUP | net.Poll.ERR) != 0) {
                var tmp: [1]u8 = undefined;
                const r = net.recv(self.client_fd, &tmp) catch return;
                if (r == 0) return;
            }

            // Client -> target. Pin the association to the first client
            // endpoint (full address incl. port) to reject injected datagrams.
            if (fds[idx_udp].revents & net.Poll.IN != 0) {
                const pkt = net.recvFrom(ufd, in_buf) catch continue;
                if (client_addr == null) client_addr = pkt.from;
                if (pkt.from.eql(&client_addr.?)) {
                    forwardClientToTarget(in_buf[0..pkt.len], &up4, &up6, self.cfg.timeout_sec);
                }
            }

            // Target -> client.
            if (idx_up4) |ix| {
                if (fds[ix].revents & net.Poll.IN != 0) {
                    if (client_addr) |ca| forwardTargetToClient(ufd, up4, &ca, in_buf, out_buf);
                }
            }
            if (idx_up6) |ix| {
                if (fds[ix].revents & net.Poll.IN != 0) {
                    if (client_addr) |ca| forwardTargetToClient(ufd, up6, &ca, in_buf, out_buf);
                }
            }
        }
    }

    // --- Replies & low-level IO --------------------------------------------

    fn replyOk(self: *Connection, bound: *const net.Addr) !void {
        try self.sendReply(Rep.ok, bound);
    }

    fn replyError(self: *Connection, code: u8) !void {
        const z = net.Addr.anyIp4(0);
        try self.sendReply(code, &z);
    }

    fn sendReply(self: *Connection, code: u8, bound: *const net.Addr) !void {
        var buf: [22]u8 = undefined;
        buf[0] = VER;
        buf[1] = code;
        buf[2] = 0x00; // RSV
        const w = 3 + writeAddr(buf[3..], bound);
        try net.sendAll(self.client_fd, buf[0..w]);
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try net.recv(self.client_fd, buf[off..]);
            if (n == 0) return error.Closed;
            off += n;
        }
    }

    fn pollTimeout(self: *Connection) i32 {
        return if (self.cfg.timeout_sec == 0) -1 else @intCast(self.cfg.timeout_sec * 1000);
    }
};

/// Write ATYP + ADDR + PORT for `addr` into `out`, returning bytes written.
fn writeAddr(out: []u8, addr: *const net.Addr) usize {
    switch (addr.family()) {
        c.AF.INET6 => {
            out[0] = Atyp.ipv6;
            const in6: *const c.sockaddr.in6 = @ptrCast(&addr.storage);
            @memcpy(out[1..17], &in6.addr);
            @memcpy(out[17..19], std.mem.asBytes(&in6.port));
            return 19;
        },
        else => {
            out[0] = Atyp.ipv4;
            const in: *const c.sockaddr.in = @ptrCast(&addr.storage);
            const oc: [4]u8 = @bitCast(in.addr);
            @memcpy(out[1..5], &oc);
            @memcpy(out[5..7], std.mem.asBytes(&in.port));
            return 7;
        },
    }
}

/// Parse a client UDP datagram (SOCKS5 UDP header + payload) and forward the
/// payload to its target, creating the matching upstream socket on demand.
fn forwardClientToTarget(packet: []const u8, up4: *net.Fd, up6: *net.Fd, timeout_sec: u32) void {
    // RSV(2) FRAG(1) ATYP(1) ADDR PORT DATA
    if (packet.len < 4) return;
    if (packet[2] != 0x00) return; // fragmentation unsupported
    const atyp = packet[3];
    var target = Target{};
    const consumed = parseAddr(atyp, packet[4..], &target) orelse return;
    const data = packet[4 + consumed ..];

    const dst = target.resolve(true) catch return;
    const fdp = if (dst.family() == c.AF.INET6) up6 else up4;
    if (fdp.* == net.invalid_fd) {
        fdp.* = net.udpSocket(dst.family()) catch return;
        net.setTimeouts(fdp.*, timeout_sec);
    }
    net.sendTo(fdp.*, data, &dst) catch {};
}

/// Wrap one upstream datagram in a SOCKS5 UDP header and send it to the client.
fn forwardTargetToClient(ufd: net.Fd, upfd: net.Fd, client_addr: *const net.Addr, in_buf: []u8, out_buf: []u8) void {
    const pkt = net.recvFrom(upfd, in_buf) catch return;
    out_buf[0] = 0x00; // RSV
    out_buf[1] = 0x00; // RSV
    out_buf[2] = 0x00; // FRAG
    const hdr = 3 + writeAddr(out_buf[3..], &pkt.from);
    const total = hdr + pkt.len;
    if (total > out_buf.len) return;
    @memcpy(out_buf[hdr..total], in_buf[0..pkt.len]);
    net.sendTo(ufd, out_buf[0..total], client_addr) catch {};
}

/// Copy one chunk from `src` to `dst`. Returns false on EOF or error.
fn pump(src: net.Fd, dst: net.Fd, buf: []u8) bool {
    const n = net.recv(src, buf) catch return false;
    if (n == 0) return false;
    net.sendAll(dst, buf[0..n]) catch return false;
    return true;
}

fn setPort(addr: *net.Addr, port_be: u16) void {
    const in: *c.sockaddr.in = @ptrCast(&addr.storage);
    in.port = port_be;
}

test "parseAddr ipv4" {
    var t = Target{};
    const data = [_]u8{ 1, 2, 3, 4, 0x1F, 0x90 }; // 1.2.3.4:8080
    const used = parseAddr(Atyp.ipv4, &data, &t).?;
    try std.testing.expectEqual(@as(usize, 6), used);
    try std.testing.expectEqual(@as(u16, 8080), t.port);
    try std.testing.expect(t.direct != null);
}

test "parseAddr domain" {
    var t = Target{};
    const data = [_]u8{ 9, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't', 0x00, 0x50 };
    const used = parseAddr(Atyp.domain, &data, &t).?;
    try std.testing.expectEqual(@as(usize, 12), used);
    try std.testing.expectEqual(@as(u16, 80), t.port);
    try std.testing.expectEqualStrings("localhost", t.host[0..t.host_len]);
}

test "parseAddr truncated returns null" {
    var t = Target{};
    const data = [_]u8{ 1, 2 };
    try std.testing.expect(parseAddr(Atyp.ipv4, &data, &t) == null);
}
