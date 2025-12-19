const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const ansi = @import("ansi.zig");
const dwarf = @import("dwarf.zig");
const source = @import("source.zig");
const proc = @import("proc.zig");

const log = std.log;
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

pub const std_options: std.Options = .{
    // Set the log level to info
    .log_level = .info,

    // Define logFn to override the std implementation
    .logFn = logger.myLogger,
};

pub fn main() !void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = std.process.argsAlloc(allocator) catch |err| panic("failed to allocate cli arguments: {any}", .{err});
    defer std.process.argsFree(allocator, args);

    mainImpl(allocator, args) catch |err| {
        switch (err) {
            error.NotEnoughCliArgs => log.err("no program to debug; usage: {s} <EXECUTABLE>", .{args[0]}),
            error.NoDwarfInfo => log.err("executable {s} has no DWARF debug info", .{args[1]}),
            else => log.err("failed to printfdebug {s}: {any}", .{ args[1], err }),
        }

        if (@errorReturnTrace()) |err_trace| {
            log.info("error return trace:", .{});
            var buffer: [1024]u8 = undefined;

            const stdout = std.fs.File.stdout();
            var writer = stdout.writer(&buffer);
            const interface = &writer.interface;

            defer interface.flush() catch {};
            err_trace.format(interface) catch {};
        }

        std.process.exit(1);
    };
}

fn mainImpl(allocator: Allocator, args: [][:0]u8) !void {
    var stdin_buffer: [256]u8 = undefined;

    var stdin = try setupStdin();
    var stdin_reader = stdin.reader(&stdin_buffer);

    if (args.len < 2) {
        return error.NotEnoughCliArgs;
    }

    var debugger = try Debugger.init(allocator, args[1]);
    defer debugger.deinit();

    try debugger.run();

    // TODO: this only works on non-PIE executables
    try debugger.insertPrintfBreakPoints();

    try debugger.cont();

    while (true) {
        const status = try debugger.wait();
        if (status.exited() or status.terminated()) {
            break;
        }

        const breakpoint_addr = debugger.getRegs().rip - 1;
        if (debugger.sources.printf_lines.get(breakpoint_addr)) |source_line| {
            // try prompt(&stdin_reader.interface, debugger.sources, source_line);
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
        \\(printfdebugger) 
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

        log.info("there is only command: [c] - continue", .{});
        std.debug.print("(printfdebugger) ", .{});
    }
}

fn setupStdin() !std.fs.File {
    const stdin = std.fs.File.stdin();
    if (!stdin.isTty()) {
        return error.NotATty;
    } else if (!stdin.getOrEnableAnsiEscapeSupport()) {
        return error.NoAnsiEscapes;
    }
    return stdin;
}
