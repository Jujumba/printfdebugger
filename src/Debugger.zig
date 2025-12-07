const std = @import("std");
const source = @import("source.zig");
const proc = @import("proc.zig");
const dwarf = @import("dwarf.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
});

const mem = std.mem;
const debug = std.debug;

const ArrayList = std.ArrayList;
const Sources = source.Sources;
const AutoHashMap = std.AutoHashMap;
const Allocator = mem.Allocator;

const print = debug.print;
const assert = debug.assert;
const panic = debug.panic;

allocator: Allocator,
debugee_fd: c_int,
debugee_path: [*:0]const u8,
debugee_pid: ?c_int = null,
sources: Sources,
breakpoints: AutoHashMap(usize, usize),

pub const logger = std.log.scoped(.debugger);

pub const Error = error{ ReadFailed, ForkFail, Open, NotLaunched, UnknownBreakPoint };

pub const ExecutionStatus = enum {
    exited,
    running,
};

const C_NULL: usize = @as(usize, 0);

const Debugger = @This();

pub fn init(allocator: Allocator, path: [*:0]const u8) Debugger.Error!Debugger {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return Debugger.Error.Open;
    const sources = dwarf.readDwarfSources(allocator, fd);
    return .{
        .allocator = allocator,
        .debugee_fd = fd,
        .debugee_path = path,
        .breakpoints = .init(allocator),
        .sources = sources,
    };
}

pub fn deinit(debugger: *Debugger) void {
    _ = c.close(debugger.debugee_fd);
    debugger.breakpoints.deinit();
    debugger.sources.deinit();
}

pub fn run(debugger: *Debugger) (Debugger.Error || Allocator.Error)!void {
    const fork_pid = c.fork();
    assert(fork_pid >= 0);
    debugger.debugee_pid = fork_pid;

    // child
    if (fork_pid == 0) {
        _ = c.ptrace(c.PTRACE_TRACEME, @as(c_int, 0), @as(usize, 0), @as(usize, 0));
        const argv = [_][*c]const u8{ debugger.debugee_path, null };
        const env = [_][*c]const u8{null};
        _ = c.execve(debugger.debugee_path, @ptrCast(&argv), @ptrCast(&env));
        @panic("failed to start the child process");
    }
    _ = debugger.wait() catch unreachable;

    const maps = proc.Map.readFromVfs(debugger.allocator, debugger.debugee_pid.?) catch |err| panic("failed to read /proc/pid/maps from the kernel: {}\n", .{err});

    const text_map: proc.Map = for (maps.items) |map| {
        logger.debug("map.pathname = {s}", .{map.pathname});
        if (map.permissions.execute) break map;
    } else panic("no executable code in {s}\n", .{debugger.debugee_path});

    debugger.insertBreakPoint(text_map.address_start) catch unreachable;

    _ = debugger.cont() catch unreachable;

    // TODO: insert breakpoints in debugger.printf_lines
}

pub fn wait(debugger: *Debugger) Debugger.Error!ExecutionStatus {
    if (debugger.debugee_pid == null) return Error.NotLaunched;
    var wait_status: c_int = undefined;
    assert(c.waitpid(debugger.debugee_pid.?, &wait_status, 0) != -1);

    return if (c.WIFEXITED(wait_status) or c.WIFSIGNALED(wait_status)) .exited else .running;
}

pub fn cont(debugger: *Debugger) Debugger.Error!void {
    if (debugger.debugee_pid == null) return Error.NotLaunched;
    assert(c.ptrace(c.PTRACE_CONT, debugger.debugee_pid.?, C_NULL, C_NULL) != -1);
}

pub fn insertBreakPoint(debugger: *Debugger, addr: usize) !void {
    const modulo8 = @mod(addr, 8);
    const shift: u6 = @intCast(modulo8 * 8);
    const mask = ~(@as(c_long, 0xFF) << shift);
    const int3: c_long = 0xCC;
    const aligned_addr = addr - modulo8;

    logger.info("inserting a breakpoint at 0x{x}", .{aligned_addr});

    const word = c.ptrace(c.PTRACE_PEEKTEXT, debugger.debugee_pid.?, aligned_addr, C_NULL);
    if (word == -1) {
        panic("failed to read debugee's memory (pid {}) at address {}\n", .{ debugger.debugee_pid.?, aligned_addr });
    }

    const int3_inserted: c_long = (word & mask) | (int3 << shift);
    logger.debug("word = 0x{X}, int_inserted = 0x{X}", .{ word, int3_inserted });

    const status = c.ptrace(c.PTRACE_POKETEXT, debugger.debugee_pid.?, aligned_addr, int3_inserted);
    if (status == -1) {
        panic("failed to insert in debugee (pid {}) at address {}\n", .{ debugger.debugee_pid.?, aligned_addr });
    }

    try debugger.breakpoints.put(addr, @intCast(word));
    logger.info("inserted a breakpoint at 0x{X}", .{aligned_addr});
}

pub fn restoreBreakPoint(debugger: *Debugger, regs: c.user_regs_struct) Debugger.Error!void {
    const original_instruction = debugger.breakpoints.get(regs.rip) orelse return error.UnknownBreakPoint;
    const modulo8 = @mod(regs.rip, 8);
    const aligned_addr = regs.rip - modulo8;

    logger.debug("restoring breakpoint at 0x{X}, original_instruction = 0x{X}", .{ regs.rip, original_instruction });

    const status = c.ptrace(c.PTRACE_POKETEXT, debugger.debugee_pid.?, aligned_addr, original_instruction);
    if (status == -1) {
        panic("failed to restore breakpoint in debugee's memory (pid {}) at address {}\n", .{ debugger.debugee_pid.?, aligned_addr });
    }
    debugger.setRegs(regs);
}

pub fn getRegs(debugger: *Debugger) c.user_regs_struct {
    var registers: c.user_regs_struct = undefined;
    const status = c.ptrace(c.PTRACE_GETREGS, debugger.debugee_pid.?, C_NULL, &registers);
    if (status == -1) {
        panic("failed to read debugees' registers\n", .{});
    }
    return registers;
}

pub fn setRegs(debugger: *Debugger, regs: c.user_regs_struct) void {
    const status = c.ptrace(c.PTRACE_SETREGS, debugger.debugee_pid.?, C_NULL, &regs);
    if (status == -1) {
        @panic("failed to set debugee's registers\n");
    }
}

fn insertPrintfBreakPoints(debugger: *Debugger, text_map: proc.Map) (Debugger.Error || Allocator.Error)!void {
    var it = debugger.printf_lines.keyIterator();

    while (it.next()) |printf_addr| {
        try debugger.insertBreakPoint(text_map.address_start + printf_addr.*);
    }
}
