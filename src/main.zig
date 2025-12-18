const std = @import("std");
const ansi = @import("ansi.zig");
const dwarf = @import("dwarf.zig");
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

    var debugger = Debugger.init(allocator, args[1]) catch |err| switch (err) {
        dwarf.Error.NoDwarfInfo => {
            print("error: executable `{s}` has no DWARF debug info\n", .{args[1]});
            return err;
        },
        else => return err,
    };
    defer debugger.deinit();

    try debugger.run();

    // TODO: this only works on non-PIE executables
    try debugger.insertPrintfBreakPoints();

    try debugger.cont();

    var stdin_buffer: [256]u8 = undefined;

    var stdin = std.fs.File.stdin();
    var stdin_reader = stdin.reader(&stdin_buffer);

    while (true) {
        const status = try debugger.wait();
        if (status.exited() or status.terminated()) {
            break;
        }

        const breakpoint_addr = debugger.getRegs().rip - 1;
        if (debugger.sources.printf_lines.get(breakpoint_addr)) |source_line| {
            prompt(&stdin_reader.interface, debugger.sources, source_line) catch |err| switch (err) {
                std.Io.Reader.Error.EndOfStream => return,
                else => return err,
            };
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

    const format =
        \\(printfdebugger) breakpoint at {s}{s}{s}:{s}{d}{s}
        \\{s}{d}{s}    {s}{s}{s}
        \\(printfdebugger) press [c] to continue: 
    ;
    const options = .{
        ansi.bold ++ ansi.greenfg,
        source_line.file_name,
        ansi.reset,
        ansi.bold ++ ansi.magentafg,
        source_line.lineno,
        ansi.reset,
        ansi.bold ++ ansi.brblackfg,
        source_line.lineno,
        ansi.reset,
        ansi.bold,
        source_file.content[line_start..line_end],
        ansi.reset,
    };
    std.debug.print(format, options);

    var answer: u8 = 0;
    while (true) {
        answer = try reader.peekByte();
        try reader.discardAll(2); // skip byte and \n

        if (answer == 'c') break;

        std.debug.print("(printfdebugger) press [c] to continue: ", .{});
    }
}
