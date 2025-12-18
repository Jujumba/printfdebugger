const std = @import("std");
const source = @import("source.zig");
const proc = @import("proc.zig");
const dwarf = @import("dwarf.zig");

pub const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
});

const fs = std.fs;
const mem = std.mem;
const debug = std.debug;

const ArrayList = std.ArrayList;
const Sources = source.Sources;
const AutoHashMap = std.AutoHashMap;
const Allocator = mem.Allocator;

const print = debug.print;
const assert = debug.assert;
const panic = debug.panic;

const C_NULL: usize = @as(usize, 0);
const Debugger = @This();

allocator: Allocator,
debugee_fd: c_int,
debugee_path: [*:0]const u8,
debugee_pid: ?c_int = null,
executable_proc_map: ?proc.Map = null,
sources: Sources,
breakpoints: AutoHashMap(usize, usize),

pub const logger = std.log.scoped(.debugger);

pub const Error = error{ ReadFailed, ForkFail, Open, NotLaunched, UnknownBreakPoint };

pub const StopReason = struct {
    raw: c_int,

    pub fn exited(status: StopReason) bool {
        return c.WIFEXITED(status.raw);
    }

    pub fn terminated(status: StopReason) bool {
        return c.WIFSIGNALED(status.raw);
    }

    pub fn signal(status: StopReason) bool {
        return c.WIFSTOPPED(status.raw);
    }

    pub fn isSyscall(status: StopReason) bool {
        if (!status.signal()) return false;
        const syscall_signal = c.SIGTRAP | 0x80;
        return c.WSTOPSIG(status.raw) == syscall_signal;
    }

    pub fn isSegfault(status: StopReason) bool {
        if (!status.signal()) return false;
        return c.WSTOPSIG(status.raw) == c.SIGSEGV;
    }
};

pub fn init(allocator: Allocator, path: [*:0]const u8) (Debugger.Error || dwarf.Error)!Debugger {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return Debugger.Error.Open;
    const sources = try dwarf.readDwarfSources(allocator, fd);
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

pub fn run(debugger: *Debugger) !void {
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
    // catch execve
    _ = debugger.wait() catch unreachable;

    const tracing_options = c.PTRACE_O_TRACESYSGOOD | c.PTRACE_O_TRACEEXIT | c.PTRACE_O_EXITKILL;

    assert(c.ptrace(c.PTRACE_SETOPTIONS, debugger.debugee_pid.?, C_NULL, tracing_options) != -1);

    const debugee_path_len = mem.len(debugger.debugee_path);
    const debugee_realpath = try fs.realpathAlloc(debugger.allocator, debugger.debugee_path[0..debugee_path_len]);
    const maps = try proc.Map.readFromVfs(debugger.allocator, debugger.debugee_pid.?);

    const executable_proc_map = for (maps.items) |map| {
        if (map.permissions.execute and mem.eql(u8, map.pathname, debugee_realpath)) break map;
    } else panic("failed to find executable map in {s}", .{debugee_realpath});

    debugger.executable_proc_map = executable_proc_map;
}

pub fn wait(debugger: *Debugger) Debugger.Error!StopReason {
    if (debugger.debugee_pid == null) return Error.NotLaunched;
    var wait_status: c_int = undefined;
    assert(c.waitpid(debugger.debugee_pid.?, &wait_status, 0) != -1);
    return .{ .raw = wait_status };
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

    const original_instruction = c.ptrace(c.PTRACE_PEEKTEXT, debugger.debugee_pid.?, aligned_addr, C_NULL);
    if (original_instruction == -1) {
        panic("failed to read debugee's memory (pid {}) at address 0x{X}\n", .{ debugger.debugee_pid.?, aligned_addr });
    }

    const int3_inserted: c_long = (original_instruction & mask) | (int3 << shift);

    const status = c.ptrace(c.PTRACE_POKETEXT, debugger.debugee_pid.?, aligned_addr, int3_inserted);
    if (status == -1) {
        panic("failed to insert in debugee (pid {}) at address {}\n", .{ debugger.debugee_pid.?, aligned_addr });
    }

    try debugger.breakpoints.put(addr, @bitCast(original_instruction));
    logger.info("inserted a breakpoint at 0x{X}, original_instruction = 0x{X}", .{ addr, original_instruction });
}

pub fn restoreBreakPoint(debugger: *Debugger) Debugger.Error!void {
    var regs = debugger.getRegs();
    regs.rip -= 1;

    const modulo8 = @mod(regs.rip, 8);
    const aligned_addr = regs.rip - modulo8;
    const original_instruction = debugger.breakpoints.get(regs.rip) orelse return error.UnknownBreakPoint;
    logger.debug("hit a breakpoint at 0x{X}", .{regs.rip});

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

pub fn insertPrintfBreakPoints(debugger: *Debugger) !void {
    var it = debugger.sources.printf_lines.keyIterator();

    while (it.next()) |printf_offset| {
        const printf_addr = 0 + printf_offset.*;
        // assert(regs.rip < printf_addr);
        try debugger.insertBreakPoint(printf_addr);
    }
}
