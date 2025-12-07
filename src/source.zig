const std = @import("std");
const fs = std.fs;

const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const File = fs.File;

const panic = std.debug.panic;

const logger = std.log.scoped(.source);

pub const Sources = struct {
    files: StringHashMap(SourceFileContent),
    printf_lines: AutoHashMap(usize, SourceFileLine),

    pub fn getFileOrRead(sources: *Sources, allocator: Allocator, file_name: []const u8) !SourceFileContent {
        if (sources.files.get(file_name)) |source| return source;

        const source: SourceFileContent = try .read(allocator, file_name);
        sources.files.put(file_name, source) catch @panic("oom");
        return source;
    }

    pub fn init(allocator: Allocator) Sources {
        return .{ .files = .init(allocator), .printf_lines = .init(allocator) };
    }

    pub fn deinit(source_files: *Sources) void {
        source_files.files.deinit();
        source_files.printf_lines.deinit();
    }
};

pub const SourceFileContent = struct {
    content: []const u8,
    lineidx: []const u32,

    pub fn read(allocator: Allocator, fname: []const u8) !SourceFileContent {
        errdefer |err| switch (err) {
            error.FileTooBig => logger.warn("{s} exceeded 8MB limit", .{fname}),
            // error.FileNotFound => logger.warn("{s} doesn't exist", .{fname}),
            else => {},
        };

        const file = try fs.cwd().openFile(fname, .{});
        defer file.close();
        const mb: usize = 1024 * 1024;
        const content = try file.readToEndAlloc(allocator, 8 * mb);

        var lineidx: ArrayList(u32) = .empty;
        for (content, 0..) |c, i| {
            if (c == '\n') lineidx.append(allocator, @intCast(i)) catch @panic("oom");
        }

        return .{ .content = content, .lineidx = lineidx.items };
    }

    pub fn close(source: SourceFileContent, allocator: Allocator) void {
        allocator.free(source.content);
        allocator.free(source.lineidx);
    }
};

pub const SourceFileLine = struct {
    file_name: []const u8,
    lineno: usize,
};
