const std = @import("std");
const source = @import("source.zig");
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

    // TODO: this only works on non-PIE executables
    try debugger.insertPrintfBreakPoints();

    try debugger.cont();

    var stdin_buffer: [256]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);

    const stdin_reader = &stdin.interface;

    while (true) {
        const status = try debugger.wait();
        if (status.exited() or status.terminated()) {
            break;
        }

        const breakpoint_addr = debugger.getRegs().rip - 1;
        if (debugger.sources.printf_lines.get(breakpoint_addr)) |source_line| {
            try prompt(stdin_reader, debugger.sources, source_line);
        }

        debugger.restoreBreakPoint() catch |err| switch (err) {
            Debugger.Error.UnknownBreakPoint => {},
            else => panic("failed to restore breakpoint: {}\n", .{err}),
        };

        try debugger.cont();
    }
}

fn prompt(reader: *std.Io.Reader, sources: source.Sources, source_line: source.SourceFileLine) !void {
    const source_file = sources.files.get(source_line.file_name) orelse return;
    var line_start = source_file.lineidx[source_line.lineno - 1];
    const line_end = source_file.lineidx[source_line.lineno];

    if (source_file.content[line_start] == '\n') line_start += 1;

    std.debug.print(
        \\(printfdebugger) hit a printf breakpoint at {s}:{d}
        \\(printfdebugger) {s}
        \\(printfdebugger) would you like to continue? [Y/n] 
    , .{ source_line.file_name, source_line.lineno, source_file.content[line_start..line_end] });

    var answer: u8 = 0;
    while (answer != 'Y' and answer != 'n') {
        answer = try reader.peekByte();
        try reader.discardAll(2); // skip byte and \n

        if (answer == 'Y' or answer == 'n') break;

        std.debug.print(
            \\ (printfdebugger) answer Y or n
            \\(printfdebugger) would you like to continue? [Y/n] 
        , .{});
    }
}

fn handleSyscall(debugger: *Debugger, status: Debugger.StopReason) void {
    if (!status.isSyscall()) {
        return;
    }
    // Debugger.logger.debug("caught a syscall", .{});

    var regs = debugger.getRegs();

    try debugger.cont();

    const syscall_finish_status = try debugger.wait();

    // child exited
    if (syscall_finish_status.exited() or syscall_finish_status.terminated()) {
        return;
    } else if (!syscall_finish_status.isSyscall()) {
        panic("unexpected termination status: {any}", .{syscall_finish_status});
    }

    if (regs.orig_rax != Debugger.MMAP_SYSNO) {
        try debugger.cont();
        return;
    }

    regs = debugger.getRegs();
    const mapped_addr: usize = @intCast(regs.rax);

    if (mapped_addr == 0) {
        Debugger.logger.info("fun fact: mmap() in debugee returned NULL, let's see how it would handle it!", .{});
        return;
    }

    var it = debugger.sources.printf_lines.iterator();
    while (it.next()) |printf_line| {
        const printf_addr = debugger.executable_proc_map.address_start + printf_line.key_ptr.*;
        if (mapped_addr <= printf_addr and printf_addr < mapped_addr + 4096) {
            Debugger.logger.info("SHIT we've just loaded a page with printf", .{});
        }
    }

    try debugger.cont();
    return;
}
