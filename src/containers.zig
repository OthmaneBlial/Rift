const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const reference = @import("oci/reference.zig");
const run = @import("run.zig");

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
    const code = run.execute(init, arguments, stop_path) catch |err| {
        if (err == error.ContainerStopped) {
            try state.writeFile(init.io, .{ .sub_path = "exit", .data = "stopped\n" });
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

pub fn logs(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    var state = try openState(init, id);
    defer state.close(init.io);
    const log = try state.openFile(init.io, "log", .{ .mode = .read_only, .follow_symlinks = false });
    defer log.close(init.io);
    var reader_buffer: [32 * 1024]u8 = undefined;
    var chunk: [32 * 1024]u8 = undefined;
    var reader = log.reader(init.io, &reader_buffer);
    var remaining = (try log.stat(init.io)).size;
    while (remaining > 0) {
        const count = try reader.interface.readSliceShort(chunk[0..@intCast(@min(remaining, chunk.len))]);
        if (count == 0) return error.LogTruncated;
        try writer.writeAll(chunk[0..count]);
        remaining -= count;
    }
}

pub fn stop(init: std.process.Init, id: []const u8, writer: *Io.Writer) !void {
    var state = try openState(init, id);
    defer state.close(init.io);
    if (!(try isRunning(init.io, state))) return error.ContainerNotRunning;
    const request = state.createFile(init.io, "stop", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (request) |file| file.close(init.io);
    for (0..250) |_| {
        if (!(try isRunning(init.io, state))) {
            try writer.print("Stopped {s}\n", .{id});
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
    const running = isRunning(init.io, state) catch |err| {
        state.close(init.io);
        return err;
    };
    state.close(init.io);
    if (running) return error.ContainerRunning;
    try containers.deleteTree(init.io, id);
    try writer.print("Removed {s}\n", .{id});
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

test "container IDs stay within their state directory" {
    try std.testing.expect(validId("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validId("../other"));
    try std.testing.expect(!validId("0123456789abcdef0123456789abcdeg"));
}
