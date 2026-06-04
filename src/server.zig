//! The accept loop and the fixed-size connection/buffer pool that bounds
//! memory. At most `cfg.max_conns` connections run concurrently; each owns a
//! pre-allocated pair of relay buffers, so peak memory is fixed up front.

const std = @import("std");
const net = @import("net.zig");
const c = std.c;
const Config = @import("Config.zig").Config;
const socks5 = @import("socks5.zig");

const Slot = struct {
    buf_c2r: []u8,
    buf_r2c: []u8,
    conn: socks5.Connection = undefined,
};

/// Tiny spinlock — the pool's critical sections are only a few instructions.
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

/// A LIFO free-list of connection slots, all buffers allocated once at start.
const Pool = struct {
    mutex: SpinLock = .{},
    slots: []Slot,
    free: []usize,
    free_top: usize,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, count: u32, buf_size: usize) !Pool {
        const slots = try gpa.alloc(Slot, count);
        errdefer gpa.free(slots);
        const free = try gpa.alloc(usize, count);
        errdefer gpa.free(free);

        var made: usize = 0;
        errdefer for (slots[0..made]) |s| {
            gpa.free(s.buf_c2r);
            gpa.free(s.buf_r2c);
        };
        for (slots, 0..) |*s, i| {
            s.buf_c2r = try gpa.alloc(u8, buf_size);
            s.buf_r2c = try gpa.alloc(u8, buf_size);
            made = i + 1;
            free[i] = i;
        }
        return .{ .slots = slots, .free = free, .free_top = count, .gpa = gpa };
    }

    fn acquire(self: *Pool) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.free_top == 0) return null;
        self.free_top -= 1;
        return self.free[self.free_top];
    }

    fn release(self: *Pool, idx: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.free[self.free_top] = idx;
        self.free_top += 1;
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    cfg: *const Config,
    listen_fd: net.Fd = net.invalid_fd,
    pool: Pool,

    pub fn init(gpa: std.mem.Allocator, cfg: *const Config) !Server {
        const pool = try Pool.init(gpa, cfg.max_conns, cfg.buf_size);
        return .{ .gpa = gpa, .cfg = cfg, .pool = pool };
    }

    pub fn run(self: *Server) !void {
        ignoreSigpipe();

        const bind_addr = net.resolve(self.cfg.listen_host, self.cfg.listen_port, false) catch {
            std.debug.print("zsocks: cannot resolve listen address '{s}'\n", .{self.cfg.listen_host});
            return error.BadListenAddr;
        };
        const lfd = try net.tcpSocket(bind_addr.family());
        self.listen_fd = lfd;
        try net.setReuseAddr(lfd);
        try net.bindAddr(lfd, &bind_addr);
        try net.listen(lfd, 128);

        std.debug.print(
            "zsocks {s} listening on {s}:{d} (auth={s}, udp={s}, max-conns={d}, buf={d})\n",
            .{
                @import("Config.zig").version,
                self.cfg.listen_host,
                self.cfg.listen_port,
                if (self.cfg.authRequired()) "on" else "off",
                if (self.cfg.udp_enabled) "on" else "off",
                self.cfg.max_conns,
                self.cfg.buf_size,
            },
        );

        while (true) {
            const accepted = net.accept(lfd) catch |e| {
                if (e == net.Error.WouldBlock) continue;
                continue; // transient accept error; keep serving
            };

            const idx = self.pool.acquire() orelse {
                // At capacity: refuse to keep memory bounded.
                net.close(accepted.fd);
                continue;
            };

            const slot = &self.pool.slots[idx];
            slot.conn = .{
                .gpa = self.gpa,
                .cfg = self.cfg,
                .client_fd = accepted.fd,
                .peer = accepted.peer,
                .buf_c2r = slot.buf_c2r,
                .buf_r2c = slot.buf_r2c,
            };

            const thread = std.Thread.spawn(.{}, worker, .{ self, idx }) catch {
                net.close(accepted.fd);
                self.pool.release(idx);
                continue;
            };
            thread.detach();
        }
    }

    fn worker(self: *Server, idx: usize) void {
        self.pool.slots[idx].conn.run();
        self.pool.release(idx);
    }
};

fn ignoreSigpipe() void {
    var act = std.mem.zeroes(c.Sigaction);
    act.handler = .{ .handler = c.SIG.IGN };
    _ = c.sigaction(c.SIG.PIPE, &act, null);
}
