const std = @import("std");
const ansi = @import("ansi.zig");

pub fn myLogger(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = switch (scope) {
        std.log.default_log_scope => "",
        else => " " ++ @tagName(scope) ++ " ",
    };

    const level_text = comptime switch (level) {
        .err => ansi.brredfg ++ ansi.bold ++ "error" ++ ansi.reset,
        .warn => ansi.bryellowfg ++ ansi.bold ++ "warn" ++ ansi.reset,
        .info => ansi.bold ++ "info" ++ ansi.reset,
        .debug => ansi.brgreenfg ++ ansi.bold ++ "debug" ++ ansi.reset,
    };

    const prefix = "(printfdebugger)" ++ scope_prefix ++ " [" ++ level_text ++ "] ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}
