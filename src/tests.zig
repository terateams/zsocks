//! Aggregates unit tests from every module so `zig build test` runs them all.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("Config.zig"));
    std.testing.refAllDecls(@import("net.zig"));
    std.testing.refAllDecls(@import("socks5.zig"));
    std.testing.refAllDecls(@import("server.zig"));
}
