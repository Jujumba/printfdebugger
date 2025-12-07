const std = @import("std");

const debug = std.debug;
const mem = std.mem;
const heap = std.heap;
const fs = std.fs;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = heap.ArenaAllocator;
const AutoHashMap = std.AutoHashMap;
const Debugger = @import("Debugger.zig");
const ExecutionStatus = Debugger.ExecutionStatus;

const panic = debug.panic;
const print = debug.print;
const assert = debug.assert;

pub fn main() !void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.NotEnoughCliArgs;

    const logger = Debugger.logger;

    var debugger = try Debugger.init(allocator, args[1]);
    defer debugger.deinit();

    try debugger.run();

    var status: ExecutionStatus = .running;
    while (true) {
        status = try debugger.wait();
        if (status == .exited) break;
        var regs = debugger.getRegs();
        regs.rip -= 1;
        logger.info("hit breakpoint at 0x{x}", .{regs.rip});
        debugger.restoreBreakPoint(regs) catch |err| switch (err) {
            Debugger.Error.UnknownBreakPoint => logger.warn("unknown breakpoint at 0x{X}", .{regs.rip}),
            else => panic("failed to restore breakpoint at 0x{X}: {}\n", .{ regs.rip, err }),
        };
        try debugger.cont();
    }
}
