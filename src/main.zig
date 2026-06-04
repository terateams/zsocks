//! zsocks — a tiny, zero-dependency SOCKS5 proxy.

const std = @import("std");
const config = @import("Config.zig");
const Server = @import("server.zig").Server;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Raw argv vector (null-terminated, lives for the whole process).
    const vec = init.minimal.args.vector;
    const args = try gpa.alloc([:0]const u8, vec.len);
    defer gpa.free(args);
    for (vec, 0..) |p, i| args[i] = std.mem.span(p);

    const result = config.parse(args[1..]) catch {
        std.process.exit(2);
    };

    switch (result) {
        .help => config.printHelp(),
        .version => config.printVersion(),
        .config => |cfg| {
            var server = try Server.init(gpa, &cfg);
            try server.run();
        },
    }
}
