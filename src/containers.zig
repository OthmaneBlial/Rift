const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const reference = @import("oci/reference.zig");
const run = @import("run.zig");

extern "c" fn rift_exec_terminal_start(with_tty: c_int) c_int;
extern "c" fn rift_exec_terminal_stop() void;
extern "c" fn rift_exec_terminal_take_signal() c_int;
extern "c" fn rift_exec_terminal_take_resize() c_int;
extern "c" fn rift_exec_terminal_size(rows: *u16, columns: *u16) c_int;
extern "c" fn rift_exec_terminal_read(buffer: [*]u8, capacity: usize) isize;

const exec_request_header = "RIFTEXEC1\n";
const interactive_exec_request_header = "RIFTEXEC2\n";
const max_exec_request_bytes = 64 * 1024;

pub fn spawn(init: std.process.Init, arguments: []const []const u8, writer: *Io.Writer) !void {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    const allocator = init.arena.allocator();
    const options = try run.parseOptions(allocator, arguments);
    if (options.remove_after_exit) return error.DetachedAutoRemoveUnsupported;
    var image = try reference.parse(allocator, arguments[options.image_index]);
    defer image.deinit(allocator);

    var containers = try openContainers(init);
    defer containers.close(init.io);
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const id = std.fmt.bytesToHex(random, .lower);
    try containers.createDir(init.io, &id, .fromMode(0o700));
    var spawned = false;
    errdefer if (!spawned) containers.deleteTree(init.io, &id) catch {};
    var state = try containers.openDir(init.io, &id, .{ .follow_symlinks = false });
    defer state.close(init.io);
    try state.writeFile(init.io, .{ .sub_path = "image", .data = arguments[options.image_index] });
    const lock = try state.createFile(init.io, "lock", .{ .exclusive = true });
    lock.close(init.io);
    const exec_lock = try state.createFile(init.io, "exec.lock", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    exec_lock.close(init.io);
    const log = try state.createFile(init.io, "log", .{ .exclusive = true });
    defer log.close(init.io);

    const executable = try std.process.executablePathAlloc(init.io, allocator);
    const child_args = try allocator.alloc([]const u8, arguments.len + 3);
    child_args[0] = executable;
    child_args[1] = "_worker";
    child_args[2] = &id;
    @memcpy(child_args[3..], arguments);
    _ = try std.process.spawn(init.io, .{
        .argv = child_args,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    spawned = true;
    for (0..100) |_| {
        const started = state.statFile(init.io, "started", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (started != null) break;
        try Io.sleep(init.io, .fromMilliseconds(20), .awake);
    }
    try writer.print("{s}\n", .{id});
}

pub fn worker(init: std.process.Init, id: []const u8, arguments: []const []const u8) !u8 {
    if (!validId(id)) return error.InvalidContainerId;
    if (std.c.setsid() < 0) return error.DetachSessionFailed;
    var containers = try openContainers(init);
    defer containers.close(init.io);
    var state = containers.openDir(init.io, id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.ContainerNotFound,
        else => return err,
    };
    defer state.close(init.io);
    const lock = try state.openFile(init.io, "lock", .{ .mode = .read_write, .follow_symlinks = false });
    defer lock.close(init.io);
    try lock.lock(init.io, .exclusive);
    defer lock.unlock(init.io);
    try state.writeFile(init.io, .{ .sub_path = "started", .data = "" });

    const allocator = init.arena.allocator();
    var state_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const state_path = state_path_buffer[0..try state.realPath(init.io, &state_path_buffer)];
    const stop_path = try std.fmt.allocPrint(allocator, "{s}/stop", .{state_path});
    const kill_path = try std.fmt.allocPrint(allocator, "{s}/kill", .{state_path});
    const code = run.execute(init, arguments, stop_path, kill_path, id) catch |err| {
        if (err == error.ContainerStopped) {
            try state.writeFile(init.io, .{ .sub_path = "exit", .data = "stopped\n" });
            return 0;
        }
        if (err == error.ContainerKilled) {
            try state.writeFile(init.io, .{ .sub_path = "exit", .data = "killed\n" });
            return 0;
        }
        const message = try std.fmt.allocPrint(allocator, "failed {s}\n", .{@errorName(err)});
        try state.writeFile(init.io, .{ .sub_path = "exit", .data = message });
        std.debug.print("rift: detached container failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    const message = try std.fmt.allocPrint(allocator, "exited {d}\n", .{code});
    try state.writeFile(init.io, .{ .sub_path = "exit", .data = message });
    return code;
}

pub fn list(init: std.process.Init, writer: *Io.Writer) !void {
    var containers = try openContainers(init);
    defer containers.close(init.io);
    try writer.writeAll("ID  IMAGE  STATUS\n");
    var entries = containers.iterate();
    while (try entries.next(init.io)) |entry| {
        if (entry.kind != .directory or !validId(entry.name)) continue;
        var state = try containers.openDir(init.io, entry.name, .{ .follow_symlinks = false });
        defer state.close(init.io);
        const image = try state.readFileAlloc(init.io, "image", init.arena.allocator(), .limited(768));
        const status = try statusText(init, state);
        try writer.print("{s}  {s}  {s}\n", .{ entry.name, image, status });
    }
}

pub fn inspect(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    var state = try openState(init, id);
    defer state.close(init.io);
    const image = try state.readFileAlloc(init.io, "image", init.arena.allocator(), .limited(768));
    const status = try statusText(init, state);
    try writeInspection(writer, id, image, status);
}

pub fn logs(init: std.process.Init, id: []const u8, writer: *Io.Writer, json: bool) !void {
    var state = try openState(init, id);
    defer state.close(init.io);
    const log = try state.openFile(init.io, "log", .{ .mode = .read_only, .follow_symlinks = false });
    defer log.close(init.io);
    var reader_buffer: [32 * 1024]u8 = undefined;
    var chunk: [32 * 1024]u8 = undefined;
    var reader = log.reader(init.io, &reader_buffer);
    var remaining = (try log.stat(init.io)).size;
    var offset: u64 = 0;
    while (remaining > 0) {
        const count = try reader.interface.readSliceShort(chunk[0..@intCast(@min(remaining, chunk.len))]);
        if (count == 0) return error.LogTruncated;
        if (json) {
            try writeJsonLogRecord(writer, id, offset, chunk[0..count]);
        } else {
            try writer.writeAll(chunk[0..count]);
        }
        remaining -= count;
        offset += count;
    }
}

fn writeJsonLogRecord(writer: *Io.Writer, id: []const u8, offset: u64, data: []const u8) !void {
    var encoded: [std.base64.standard.Encoder.calcSize(32 * 1024)]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, data);
    try writer.print("{{\"container_id\":\"{s}\",\"stream\":\"combined\",\"offset_bytes\":{d},\"encoding\":\"base64\",\"data\":\"{s}\"}}\n", .{ id, offset, payload });
}

pub fn exec(init: std.process.Init, id: []const u8, command: []const []const u8, writer: *Io.Writer, interactive: bool, tty: bool) !u8 {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    if (!validId(id)) return error.InvalidContainerId;
    if (tty and !interactive) return error.InvalidArguments;
    const allocator = init.arena.allocator();

    var state = try openState(init, id);
    defer state.close(init.io);
    var exec_lock = try openExecLock(init.io, state);
    defer exec_lock.close(init.io);
    try exec_lock.lock(init.io, .exclusive);
    defer exec_lock.unlock(init.io);
    if (!(try isRunning(init.io, state))) return error.ContainerNotRunning;

    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    var data_dir = try home_dir.openDir(init.io, "Library/Application Support/Rift", .{ .follow_symlinks = false });
    defer data_dir.close(init.io);
    var channel: ?ExecChannel = null;
    for (0..600) |_| {
        if (try stateShutdownRequested(init.io, state)) return error.ContainerNotRunning;
        if (!(try isRunning(init.io, state))) return error.ContainerNotRunning;
        if (try openExecChannel(init.io, data_dir, allocator, id)) |candidate| {
            const ready = regularFileExists(init.io, candidate.exec, "agent-ready") catch |err| {
                candidate.deinit(init.io);
                return err;
            };
            if (ready) {
                channel = candidate;
                break;
            }
            const stopping = shutdownRequested(init.io, state, candidate.control) catch |err| {
                candidate.deinit(init.io);
                return err;
            };
            candidate.deinit(init.io);
            if (stopping) return error.ContainerNotRunning;
        }
        try Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
    var active_channel = channel orelse return error.ExecAgentNotReady;
    defer active_channel.deinit(init.io);
    if (try shutdownRequested(init.io, state, active_channel.control)) return error.ContainerNotRunning;

    var rows: u16 = 24;
    var columns: u16 = 80;
    var terminal_started = false;
    defer if (terminal_started) rift_exec_terminal_stop();
    if (interactive) {
        if (rift_exec_terminal_start(@intFromBool(tty)) != 0) return error.ExecAttachUnavailable;
        terminal_started = true;
        if (tty and rift_exec_terminal_size(&rows, &columns) != 0) return error.ExecTerminalSizeUnavailable;
    }
    const request = try encodeExecRequest(allocator, command, interactive, tty, rows, columns);
    if (request.len > max_exec_request_bytes) return error.ExecRequestTooLarge;

    var random: [16]u8 = undefined;
    init.io.random(&random);
    const request_id = std.fmt.bytesToHex(random, .lower);
    const request_name = try std.fmt.allocPrint(allocator, "exec-{s}.request", .{request_id});
    const output_name = try std.fmt.allocPrint(allocator, "exec-{s}.output", .{request_id});
    const input_name = try std.fmt.allocPrint(allocator, "exec-{s}.input", .{request_id});
    const input_closed_name = try std.fmt.allocPrint(allocator, "exec-{s}.input-closed", .{request_id});
    const signal_name = try std.fmt.allocPrint(allocator, "exec-{s}.signal", .{request_id});
    const resize_name = try std.fmt.allocPrint(allocator, "exec-{s}.resize", .{request_id});
    const exit_name = try std.fmt.allocPrint(allocator, "exec-{s}.exit", .{request_id});
    defer {
        active_channel.exec.deleteFile(init.io, request_name) catch {};
        active_channel.exec.deleteFile(init.io, output_name) catch {};
        active_channel.exec.deleteFile(init.io, input_name) catch {};
        active_channel.exec.deleteFile(init.io, input_closed_name) catch {};
        active_channel.exec.deleteFile(init.io, signal_name) catch {};
        active_channel.exec.deleteFile(init.io, resize_name) catch {};
        active_channel.exec.deleteFile(init.io, exit_name) catch {};
    }
    const input = if (interactive) try active_channel.exec.createFile(init.io, input_name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) else null;
    defer if (input) |file| file.close(init.io);
    const output_placeholder = try active_channel.exec.createFile(init.io, output_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    output_placeholder.close(init.io);
    const output = try active_channel.exec.openFile(init.io, output_name, .{ .mode = .read_write, .follow_symlinks = false });
    defer output.close(init.io);
    var reader_buffer: [32 * 1024]u8 = undefined;
    var chunk: [32 * 1024]u8 = undefined;
    var reader = output.reader(init.io, &reader_buffer);
    var output_offset: u64 = 0;
    var atomic = try active_channel.exec.createFileAtomic(init.io, request_name, .{ .permissions = .fromMode(0o600) });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, request);
    try atomic.replace(init.io);

    var status_text: ?[]u8 = null;
    defer if (status_text) |contents| allocator.free(contents);
    var stdin_closed = false;
    var input_buffer: [32 * 1024]u8 = undefined;
    var forwarded_signal: c_int = 0;
    var forced_signal = false;
    var resize_generation: u32 = 0;
    while (status_text == null) {
        const available = (try output.stat(init.io)).size;
        while (output_offset < available) {
            const count = try reader.interface.readSliceShort(chunk[0..@intCast(@min(available - output_offset, chunk.len))]);
            if (count == 0) break;
            try writer.writeAll(chunk[0..count]);
            try writer.flush();
            output_offset += count;
        }
        if (interactive) {
            const caught_signal = rift_exec_terminal_take_signal();
            if (caught_signal != 0) {
                const signal_to_forward = if (forwarded_signal == 0) caught_signal else blk: {
                    forced_signal = true;
                    break :blk 9;
                };
                if (forwarded_signal == 0) forwarded_signal = caught_signal;
                const signal_text = try std.fmt.allocPrint(allocator, "{d}\n", .{signal_to_forward});
                try writeAtomicExecFile(init, active_channel.exec, signal_name, signal_text);
                if (!stdin_closed) {
                    const closed = try active_channel.exec.createFile(init.io, input_closed_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                    closed.close(init.io);
                    stdin_closed = true;
                }
            }
            if (tty) {
                const resize_signal = rift_exec_terminal_take_resize() != 0;
                var current_rows: u16 = 0;
                var current_columns: u16 = 0;
                if (rift_exec_terminal_size(&current_rows, &current_columns) != 0) return error.ExecTerminalSizeUnavailable;
                if (resize_signal or current_rows != rows or current_columns != columns) {
                    rows = current_rows;
                    columns = current_columns;
                    resize_generation += 1;
                    const resize_text = try std.fmt.allocPrint(allocator, "{d} {d} {d}\n", .{ resize_generation, rows, columns });
                    try writeAtomicExecFile(init, active_channel.exec, resize_name, resize_text);
                }
            }
            if (!stdin_closed) {
                const bytes_read = rift_exec_terminal_read(&input_buffer, input_buffer.len);
                if (bytes_read == -1) return error.ExecInputReadFailed;
                if (bytes_read >= 0) {
                    const count: usize = @intCast(bytes_read);
                    if (count == 0) {
                        const closed = try active_channel.exec.createFile(init.io, input_closed_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                        closed.close(init.io);
                        stdin_closed = true;
                    } else {
                        try input.?.writeStreamingAll(init.io, input_buffer[0..count]);
                    }
                }
            }
        }
        status_text = active_channel.exec.readFileAlloc(init.io, exit_name, allocator, .limited(16)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (status_text != null) break;
        if (try shutdownRequested(init.io, state, active_channel.control)) return error.ContainerNotRunning;
        if (!(try isRunning(init.io, state))) return error.ContainerNotRunning;
        try Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }

    const final_size = (try output.stat(init.io)).size;
    while (output_offset < final_size) {
        const count = try reader.interface.readSliceShort(chunk[0..@intCast(@min(final_size - output_offset, chunk.len))]);
        if (count == 0) return error.ExecOutputTruncated;
        try writer.writeAll(chunk[0..count]);
        output_offset += count;
    }
    try writer.flush();

    const code = std.fmt.parseInt(u8, std.mem.trim(u8, status_text.?, "\r\n"), 10) catch return error.InvalidExecStatus;
    if (forced_signal) return 137;
    if (forwarded_signal != 0) return @intCast(128 + forwarded_signal);
    return code;
}

pub fn stop(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    try terminate(init, id, writer, false);
}

pub fn kill(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    try terminate(init, id, writer, true);
}

fn terminate(init: std.process.Init, id: []const u8, writer: *Io.Writer, force: bool) !void {
    var state = try openState(init, id);
    defer state.close(init.io);
    if (!(try isRunning(init.io, state))) return error.ContainerNotRunning;
    const marker = if (force) "kill" else "stop";
    const request = state.createFile(init.io, marker, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (request) |file| file.close(init.io);
    for (0..250) |_| {
        if (!(try isRunning(init.io, state))) {
            try writer.print("{s} {s}\n", .{ if (force) "Killed" else "Stopped", id });
            return;
        }
        try Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
    return error.ContainerStopTimedOut;
}

pub fn remove(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    if (!validId(id)) return error.InvalidContainerId;
    var containers = try openContainers(init);
    defer containers.close(init.io);
    var state = containers.openDir(init.io, id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.ContainerNotFound,
        else => return err,
    };
    defer state.close(init.io);
    var exec_lock = try openExecLock(init.io, state);
    defer exec_lock.close(init.io);
    if (!(try exec_lock.tryLock(init.io, .exclusive))) return error.ContainerExecRunning;
    defer exec_lock.unlock(init.io);
    if (try isRunning(init.io, state)) return error.ContainerRunning;
    try containers.deleteTree(init.io, id);
    try writer.print("Removed {s}\n", .{id});
}

fn openExecLock(io: Io, state: Io.Dir) !Io.File {
    return state.openFile(io, "exec.lock", .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => state.createFile(io, "exec.lock", .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try state.openFile(io, "exec.lock", .{ .mode = .read_write, .follow_symlinks = false }),
            else => return create_err,
        },
        else => return err,
    };
}

fn regularFileExists(io: Io, dir: Io.Dir, name: []const u8) !bool {
    const info = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (info.kind != .file) return error.InvalidExecState;
    return true;
}

const ExecChannel = struct {
    runtime: Io.Dir,
    run: Io.Dir,
    control: Io.Dir,
    exec: Io.Dir,

    fn deinit(channel: ExecChannel, io: Io) void {
        channel.exec.close(io);
        channel.control.close(io);
        channel.run.close(io);
        channel.runtime.close(io);
    }
};

fn openExecChannel(io: Io, data_dir: Io.Dir, allocator: std.mem.Allocator, id: []const u8) !?ExecChannel {
    var runtime = data_dir.openDir(io, "runtime", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer runtime.close(io);
    const runtime_name = try std.fmt.allocPrint(allocator, "run-{s}", .{id});
    var run_dir = runtime.openDir(io, runtime_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            runtime.close(io);
            return null;
        },
        else => return err,
    };
    errdefer run_dir.close(io);
    var control = run_dir.openDir(io, "control", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            run_dir.close(io);
            runtime.close(io);
            return null;
        },
        else => return err,
    };
    errdefer control.close(io);
    const exec_dir = control.openDir(io, "exec", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            control.close(io);
            run_dir.close(io);
            runtime.close(io);
            return null;
        },
        else => return err,
    };
    return .{ .runtime = runtime, .run = run_dir, .control = control, .exec = exec_dir };
}

fn stateShutdownRequested(io: Io, state: Io.Dir) !bool {
    return try regularFileExists(io, state, "stop") or try regularFileExists(io, state, "kill");
}

fn shutdownRequested(io: Io, state: Io.Dir, control: Io.Dir) !bool {
    return try regularFileExists(io, state, "stop") or
        try regularFileExists(io, state, "kill") or
        try regularFileExists(io, control, "stop") or
        try regularFileExists(io, control, "exit") or
        try regularFileExists(io, control, "host-exit");
}

fn writeAtomicExecFile(init: std.process.Init, directory: Io.Dir, name: []const u8, data: []const u8) !void {
    var atomic = try directory.createFileAtomic(init.io, name, .{ .permissions = .fromMode(0o600) });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, data);
    try atomic.replace(init.io);
}

fn encodeExecRequest(allocator: std.mem.Allocator, command: []const []const u8, interactive: bool, tty: bool, rows: u16, columns: u16) ![]u8 {
    if (command.len == 0 or command.len > 256 or command[0].len == 0) return error.InvalidArguments;
    if (tty and !interactive) return error.InvalidArguments;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(if (interactive) interactive_exec_request_header else exec_request_header);
    if (interactive) {
        try output.writer.writeAll(if (tty) "3\x00" else "1\x00");
        if (tty) {
            try output.writer.writeInt(u16, rows, .little);
            try output.writer.writeInt(u16, columns, .little);
        }
    }
    for (command) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArguments;
        try output.writer.writeAll(argument);
        try output.writer.writeByte(0);
        if (output.written().len > max_exec_request_bytes) return error.ExecRequestTooLarge;
    }
    return output.toOwnedSlice();
}

test "exec request preserves argument boundaries and rejects invalid commands" {
    const encoded = try encodeExecRequest(std.testing.allocator, &.{ "/bin/echo", "a b", "", "a'b" }, false, false, 24, 80);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("RIFTEXEC1\n/bin/echo\x00a b\x00\x00a'b\x00", encoded);
    const interactive = try encodeExecRequest(std.testing.allocator, &.{ "/bin/cat", "a b" }, true, false, 24, 80);
    defer std.testing.allocator.free(interactive);
    try std.testing.expectEqualStrings("RIFTEXEC2\n1\x00/bin/cat\x00a b\x00", interactive);
    const tty = try encodeExecRequest(std.testing.allocator, &.{"/bin/sh"}, true, true, 32, 100);
    defer std.testing.allocator.free(tty);
    try std.testing.expectEqualSlices(u8, "RIFTEXEC2\n3\x00\x20\x00\x64\x00/bin/sh\x00", tty);
    try std.testing.expectError(error.InvalidArguments, encodeExecRequest(std.testing.allocator, &.{}, false, false, 24, 80));
    try std.testing.expectError(error.InvalidArguments, encodeExecRequest(std.testing.allocator, &.{""}, false, false, 24, 80));
    try std.testing.expectError(error.InvalidArguments, encodeExecRequest(std.testing.allocator, &.{ "echo", "a\x00b" }, false, false, 24, 80));
    try std.testing.expectError(error.InvalidArguments, encodeExecRequest(std.testing.allocator, &.{"/bin/sh"}, false, true, 24, 80));
}

fn statusText(init: std.process.Init, state: Io.Dir) ![]const u8 {
    if (try isRunning(init.io, state)) return "running";
    const status = state.readFileAlloc(init.io, "exit", init.arena.allocator(), .limited(128)) catch |err| switch (err) {
        error.FileNotFound => "starting or interrupted",
        else => return err,
    };
    return std.mem.trimEnd(u8, status, "\r\n");
}

fn isRunning(io: Io, state: Io.Dir) !bool {
    const lock = try state.openFile(io, "lock", .{ .mode = .read_write, .follow_symlinks = false });
    defer lock.close(io);
    const acquired = try lock.tryLock(io, .shared);
    if (acquired) lock.unlock(io);
    return !acquired;
}

fn openState(init: std.process.Init, id: []const u8) !Io.Dir {
    if (!validId(id)) return error.InvalidContainerId;
    var containers = try openContainers(init);
    defer containers.close(init.io);
    return containers.openDir(init.io, id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => error.ContainerNotFound,
        else => err,
    };
}

fn openContainers(init: std.process.Init) !Io.Dir {
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    try home_dir.createDirPath(init.io, "Library/Application Support/Rift/containers");
    return home_dir.openDir(init.io, "Library/Application Support/Rift/containers", .{ .follow_symlinks = false, .iterate = true });
}

fn validId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn writeInspection(writer: *Io.Writer, id: []const u8, image: []const u8, status: []const u8) !void {
    try writer.print("Container ID: {s}\nImage: {s}\nState: {s}\n", .{ id, image, status });
}

test "container IDs stay within their state directory" {
    try std.testing.expect(validId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validId("../other"));
    try std.testing.expect(!validId("0123456789abcdef0123456789abcdeg"));
}

test "inspection prints the container lifecycle fields" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeInspection(&output.writer, "0123456789abcdef0123456789abcdef", "alpine", "exited 37");
    try std.testing.expectEqualStrings(
        "Container ID: 0123456789abcdef0123456789abcdef\nImage: alpine\nState: exited 37\n",
        output.written(),
    );
}

test "structured log records preserve arbitrary bytes and offsets" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const data = [_]u8{ 'a', 0, '\n', 0xff };
    try writeJsonLogRecord(&output.writer, "0123456789abcdef0123456789abcdef", 7, &data);
    try std.testing.expectEqualStrings(
        "{\"container_id\":\"0123456789abcdef0123456789abcdef\",\"stream\":\"combined\",\"offset_bytes\":7,\"encoding\":\"base64\",\"data\":\"YQAK/w==\"}\n",
        output.written(),
    );
}
