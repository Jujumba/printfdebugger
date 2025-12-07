const std = @import("std");

const mem = std.mem;
const debug = std.debug;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const panic = debug.panic;
const assert = debug.assert;

/// Entry in /proc/pid/maps
pub const Map = struct {
    address_start: usize,
    address_end: usize,
    permissions: Permissions,
    pathname: []const u8,

    const Permissions = packed struct {
        read: bool = false,
        write: bool = false,
        execute: bool = false,
        shared: bool = false,
        private: bool = false,
    };

    const Error = error{InvalidFile};

    pub fn readFromVfs(allocator: Allocator, pid: c_int) !ArrayList(Map) {
        var maps: ArrayList(Map) = .empty;

        const path = try std.fmt.allocPrint(allocator, "/proc/{d}/maps", .{pid});
        const file = try std.fs.cwd().openFile(path, .{});
        const content = try file.readToEndAlloc(allocator, 1024 * 32);

        var line_start: usize = 0;
        while (line_start < content.len) {
            const line_end = mem.indexOfAnyPos(u8, content, line_start, &.{'\n'}) orelse content.len - 1;
            const current_line = content[line_start..line_end];
            const map: Map = try .parse(allocator, current_line);
            try maps.append(allocator, map);
            line_start = line_end + 1;
        }

        return maps;
    }

    fn parse(allocator: Allocator, line: []const u8) !Map {
        assert(line[0] != '\n');
        assert(line[line.len - 1] != '\n');

        const hyphen_idx = mem.indexOfAny(u8, line, &.{'-'}) orelse @panic("/proc/pid/maps should be in correct format: no `-`");
        const space_idx = mem.indexOfAny(u8, line, &.{' '}) orelse @panic("/proc/pid/maps should be in correct format: no ` `");
        assert(hyphen_idx != 0);
        assert(hyphen_idx < space_idx - 1);

        const address_start = std.fmt.parseInt(usize, line[0..hyphen_idx], 16) catch |err| panic("failed to parse int `{s}`: {}\n", .{ line[0..hyphen_idx], err });
        const address_end = std.fmt.parseInt(usize, line[hyphen_idx + 1 .. space_idx], 16) catch |err| panic("failed to parse int `{s}`: {}\n", .{ line[0..hyphen_idx], err });

        const second_space_idx = mem.indexOfAnyPos(u8, line, space_idx + 1, &.{' '}) orelse @panic("/proc/pid/maps should be in correct format: no ` `");
        const permissions_str = line[space_idx + 1 .. second_space_idx];
        var permissions: Map.Permissions = .{};
        for (permissions_str) |p| {
            // TODO: return error if permission is already set?
            switch (p) {
                'r' => permissions.read = true,
                'w' => permissions.write = true,
                'x' => permissions.execute = true,
                's' => permissions.shared = true,
                'p' => permissions.private = true,
                '-' => continue,
                else => panic("invalid char {c} in permission string: {s}\n", .{ p, permissions_str }),
            }
        }

        var last_space = line.len - 1;
        while (last_space != 0) : (last_space -= 1) {
            if (line[last_space] == ' ') break;
        }
        assert(line[last_space] == ' ');

        const pathname_borrowed = line[last_space + 1 ..];
        const pathname = try allocator.dupe(u8, pathname_borrowed);

        return .{
            .address_start = address_start,
            .address_end = address_end,
            .permissions = permissions,
            .pathname = pathname,
        };
    }
};
