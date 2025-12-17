const std = @import("std");
const proc = @import("proc.zig");

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

const c = Debugger.c;
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

    var debugger = try Debugger.init(allocator, args[1]);
    defer debugger.deinit();

    try debugger.run();

    const maps = proc.Map.readFromVfs(debugger.allocator, debugger.debugee_pid.?) catch |err| panic("failed to read /proc/pid/maps from the kernel: {}\n", .{err});

    const executable_map: proc.Map = for (maps.items) |map| {
        if (map.permissions.execute) break map;
    } else @panic("no executable code for the debuged program\n");
    Debugger.logger.debug("executable map of {s}: 0x{X}, {s}", .{ debugger.debugee_path, executable_map.address_start, executable_map.pathname });

    // for (maps.items) |map| {
    //     if (map.permissions.execute) Debugger.logger.debug("executable map: 0x{X}, {s}", .{ map.address_start, map.pathname });
    // }

    // TODO: this only works on non PIE executables
    try debugger.insertPrintfBreakPoints(executable_map);

    try debugger.cont();

    while (true) {
        // Debugger.logger.debug("waiting for debugee", .{});
        const status = try debugger.wait();
        if (status.exited() or status.terminated()) {
            break;
        }

        // if it's a syscall
        // if (status.isSyscall()) {
        //     // Debugger.logger.debug("caught a syscall", .{});

        //     var regs = debugger.getRegs();

        //     try debugger.cont();

        //     const syscall_finish_status = try debugger.wait();

        //     // child exited
        //     if (status.exited() or status.terminated()) {
        //         break;
        //     } else if (!syscall_finish_status.isSyscall()) panic("unexpected termination status: {any}", .{syscall_finish_status});
        //     // Debugger.logger.debug("finished a syscall", .{});

        //     if (regs.orig_rax != Debugger.MMAP_SYSNO) {
        //         try debugger.cont();
        //         continue;
        //     }

        //     regs = debugger.getRegs();
        //     const mapped_addr: usize = @intCast(regs.rax);

        //     if (mapped_addr == 0) {
        //         Debugger.logger.info("fun fact: mmap() in debugee returned NULL, let's see how it would handle it!", .{});
        //         continue;
        //     }

        //     var it = debugger.sources.printf_lines.iterator();
        //     while (it.next()) |printf_line| {
        //         const printf_addr = executable_map.address_start + printf_line.key_ptr.*;
        //         if (mapped_addr <= printf_addr and printf_addr < mapped_addr + 4096) {
        //             Debugger.logger.info("SHIT we've just loaded a page with printf", .{});
        //         }
        //     }

        //     try debugger.cont();
        //     continue;
        // }

        debugger.restoreBreakPoint() catch |err| switch (err) {
            Debugger.Error.UnknownBreakPoint => {},
            else => panic("failed to restore breakpoint: {}\n", .{err}),
        };

        try debugger.cont();
    }
}
