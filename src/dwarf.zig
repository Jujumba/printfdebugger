const std = @import("std");
const source = @import("source.zig");
const libdw = @cImport({
    @cInclude("dwarf.h");
    @cInclude("elfutils/libdw.h");
});

const mem = std.mem;
const heap = std.heap;

const Sources = source.Sources;
const SourceFileContent = source.SourceFileContent;
const SourceFileLine = source.SourceFileLine;
const AutoHashMap = std.AutoHashMap;
const HashMap = std.HashMap;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const C_SUCCESS: c_int = 0;

const logger = std.log.scoped(.dwarf);

pub const Error = error{ NoDwarfInfo, LibDw };

const HashContext = struct {
    const This = @This();

    pub fn hash(ctx: This, key: SourceFileLine) u64 {
        _ = ctx;
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(key.file_name);
        hasher.update(&mem.toBytes(key.lineno));
        return hasher.final();
    }

    pub fn eql(ctx: This, x: SourceFileLine, y: SourceFileLine) bool {
        _ = ctx;
        return mem.eql(u8, x.file_name, y.file_name) and x.lineno == y.lineno;
    }
};

pub fn readDwarfSources(allocator: Allocator, fd: c_int) !Sources {
    var scratch_arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer scratch_arena.deinit();

    const dbg_session = libdw.dwarf_begin(fd, 0) orelse return Error.NoDwarfInfo;
    defer _ = libdw.dwarf_end(dbg_session);

    var offset: libdw.Dwarf_Off = 0;
    var next_offset: libdw.Dwarf_Off = 0;
    var header_size: usize = 0;

    var sources = Sources.init(allocator);

    while (libdw.dwarf_nextcu(dbg_session, offset, &next_offset, &header_size, null, null, null) == 0) : (offset = next_offset) {
        var cu_die: libdw.Dwarf_Die = undefined;
        if (libdw.dwarf_offdie(dbg_session, offset + header_size, &cu_die) == null) {
            continue;
        }

        var lines: *libdw.Dwarf_Lines = undefined;
        var nlines: usize = 0;
        if (libdw.dwarf_getsrclines(&cu_die, @ptrCast(&lines), &nlines) != C_SUCCESS) {
            continue;
        }

        readLines(allocator, scratch_arena.allocator(), &sources, lines, nlines);
    }

    return sources;
}

fn readLines(
    allocator: Allocator,
    scratch_allocator: Allocator,
    sources: *Sources,
    lines: *libdw.Dwarf_Lines,
    nlines: usize,
) void {
    var traversed_lines: HashMap(SourceFileLine, void, HashContext, 80) = .init(scratch_allocator);

    for (0..nlines) |i| {
        const line: *libdw.Dwarf_Line = libdw.dwarf_onesrcline(lines, i) orelse continue;
        const file_name: []const u8 = blk: {
            const ptr: [*c]const u8 = libdw.dwarf_linesrc(line, null, null);
            const copy = allocator.dupe(u8, ptr[0..mem.len(ptr)]) catch @panic("oom");
            break :blk copy;
        };

        const addr = getLineAddr(line) catch continue;
        const lineno = getLineNo(line) catch continue;
        const source_file = sources.getFileOrRead(allocator, file_name) catch continue;
        const source_line: SourceFileLine = .{ .file_name = file_name, .lineno = lineno };

        if (lineno == 0 or lineno >= source_file.lineidx.len or traversed_lines.contains(source_line)) {
            continue;
        }

        traversed_lines.put(source_line, {}) catch @panic("oom");

        const nth_line_start = source_file.lineidx[lineno - 1];
        const nth_line_end = source_file.lineidx[lineno];
        const nth_line = source_file.content[nth_line_start..nth_line_end];

        if (mem.containsAtLeast(u8, nth_line, 1, "printf")) {
            logger.info("{s}:{d} has a printf, setting a breakpoint", .{ file_name, lineno });
            sources.printf_lines.put(addr, source_line) catch @panic("oom");
        }
    }
}

fn getLineAddr(line: *libdw.Dwarf_Line) !usize {
    var addr: usize = 0;
    if (libdw.dwarf_lineaddr(line, &addr) != C_SUCCESS) {
        return error.LibDw;
    }
    return addr;
}

fn getLineNo(line: *libdw.Dwarf_Line) !u32 {
    var lineno: u32 = 0;
    if (libdw.dwarf_lineno(line, @ptrCast(&lineno)) != C_SUCCESS) {
        return error.LibDw;
    }
    return lineno;
}
