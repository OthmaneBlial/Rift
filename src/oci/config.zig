const std = @import("std");
const manifest = @import("manifest.zig");
const reference = @import("reference.zig");
const storage = @import("../storage.zig");

pub const Image = struct {
    architecture: []const u8,
    os: []const u8,
    config: ?Process = null,
    rootfs: Rootfs,
};

pub const Process = struct {
    User: ?[]const u8 = null,
    Env: ?[]const []const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    WorkingDir: ?[]const u8 = null,
    StopSignal: ?[]const u8 = null,
};

const StopSignalName = struct { name: []const u8, number: u8 };
const stop_signal_names = [_]StopSignalName{
    .{ .name = "HUP", .number = 1 },
    .{ .name = "INT", .number = 2 },
    .{ .name = "QUIT", .number = 3 },
    .{ .name = "ILL", .number = 4 },
    .{ .name = "TRAP", .number = 5 },
    .{ .name = "ABRT", .number = 6 },
    .{ .name = "BUS", .number = 7 },
    .{ .name = "FPE", .number = 8 },
    .{ .name = "USR1", .number = 10 },
    .{ .name = "SEGV", .number = 11 },
    .{ .name = "USR2", .number = 12 },
    .{ .name = "PIPE", .number = 13 },
    .{ .name = "ALRM", .number = 14 },
    .{ .name = "TERM", .number = 15 },
    .{ .name = "STKFLT", .number = 16 },
    .{ .name = "CHLD", .number = 17 },
    .{ .name = "CONT", .number = 18 },
    .{ .name = "TSTP", .number = 20 },
    .{ .name = "TTIN", .number = 21 },
    .{ .name = "TTOU", .number = 22 },
    .{ .name = "URG", .number = 23 },
    .{ .name = "XCPU", .number = 24 },
    .{ .name = "XFSZ", .number = 25 },
    .{ .name = "VTALRM", .number = 26 },
    .{ .name = "PROF", .number = 27 },
    .{ .name = "WINCH", .number = 28 },
    .{ .name = "IO", .number = 29 },
    .{ .name = "PWR", .number = 30 },
    .{ .name = "SYS", .number = 31 },
};

pub const Rootfs = struct {
    type: []const u8,
    diff_ids: []const []const u8,
};

pub fn load(allocator: std.mem.Allocator, store: storage.BlobStore, manifest_digest: []const u8) !Image {
    const manifest_body = try store.readVerifiedAlloc(allocator, manifest_digest, 4 * 1024 * 1024);
    const image_manifest = try manifest.parseManifest(allocator, manifest_body);
    const config_body = try store.readVerifiedAlloc(allocator, image_manifest.config.digest, 4 * 1024 * 1024);
    if (config_body.len != image_manifest.config.size) return error.InvalidImageConfig;
    return parse(allocator, config_body, image_manifest.layers.len);
}

pub fn parse(allocator: std.mem.Allocator, body: []const u8, layer_count: usize) !Image {
    const image = try std.json.parseFromSliceLeaky(Image, allocator, body, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, image.os, "linux") or !std.mem.eql(u8, image.architecture, "arm64") or
        !std.mem.eql(u8, image.rootfs.type, "layers") or image.rootfs.diff_ids.len != layer_count)
        return error.InvalidImageConfig;
    for (image.rootfs.diff_ids) |digest| {
        if (!reference.isValidDigest(digest)) return error.InvalidImageConfig;
    }
    const process = image.config orelse Process{};
    for (process.Env orelse &.{}) |variable| {
        const separator = std.mem.indexOfScalar(u8, variable, '=') orelse return error.InvalidImageConfig;
        if (separator == 0 or std.mem.indexOfScalar(u8, variable, 0) != null) return error.InvalidImageConfig;
    }
    for (process.Entrypoint orelse &.{}) |argument| if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidImageConfig;
    for (process.Cmd orelse &.{}) |argument| if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidImageConfig;
    if (process.WorkingDir) |directory| {
        if (std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidImageConfig;
    }
    if (process.User) |user| {
        if (std.mem.indexOfScalar(u8, user, 0) != null) return error.InvalidImageConfig;
    }
    if (process.StopSignal) |signal| {
        if (stopSignalNumber(signal) == null) return error.InvalidImageConfig;
    }
    return image;
}

pub fn stopSignalNumber(value: []const u8) ?u8 {
    const name = if (value.len >= 3 and std.ascii.eqlIgnoreCase(value[0..3], "SIG")) value[3..] else value;
    for (stop_signal_names) |signal| {
        if (std.ascii.eqlIgnoreCase(name, signal.name)) return signal.number;
    }
    const signal = std.fmt.parseInt(u8, value, 10) catch return null;
    if (signal == 0 or signal >= 32 or signal == 9 or signal == 19) return null;
    return signal;
}

pub fn command(allocator: std.mem.Allocator, process: Process, override: []const []const u8) ![]const []const u8 {
    const entrypoint = process.Entrypoint orelse &.{};
    const arguments = if (override.len != 0) override else process.Cmd orelse &.{};
    if (entrypoint.len == 0) {
        if (arguments.len == 0) return error.ImageHasNoCommand;
        return arguments;
    }
    const result = try allocator.alloc([]const u8, entrypoint.len + arguments.len);
    @memcpy(result[0..entrypoint.len], entrypoint);
    @memcpy(result[entrypoint.len..], arguments);
    return result;
}

test "uses image defaults and appends overrides to an entrypoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"architecture":"arm64","os":"linux","config":{"Env":["PATH=/bin"],"Entrypoint":["/bin/echo"],"Cmd":["default"]},"rootfs":{"type":"layers","diff_ids":["sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}
    ;
    const image = try parse(arena.allocator(), body, 1);
    try std.testing.expectEqualStrings("default", (try command(arena.allocator(), image.config.?, &.{}))[1]);
    const selected = try command(arena.allocator(), image.config.?, &.{"override"});
    try std.testing.expectEqualStrings("/bin/echo", selected[0]);
    try std.testing.expectEqualStrings("override", selected[1]);
}

test "rejects mismatched rootfs and malformed environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"architecture":"arm64","os":"linux","config":{"Env":["BROKEN"]},"rootfs":{"type":"layers","diff_ids":[]}}
    ;
    try std.testing.expectError(error.InvalidImageConfig, parse(arena.allocator(), body, 0));
    try std.testing.expectError(error.InvalidImageConfig, parse(arena.allocator(), body, 1));
}

test "accepts null optional process settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"architecture":"arm64","os":"linux","config":{"Env":null,"Cmd":null,"Entrypoint":null},"rootfs":{"type":"layers","diff_ids":[]}}
    ;
    const image = try parse(arena.allocator(), body, 0);
    try std.testing.expectError(error.ImageHasNoCommand, command(arena.allocator(), image.config.?, &.{}));
}

test "parses catchable Docker stop signals for Linux ARM64" {
    try std.testing.expectEqual(@as(?u8, 10), stopSignalNumber("SIGUSR1"));
    try std.testing.expectEqual(@as(?u8, 15), stopSignalNumber("term"));
    try std.testing.expectEqual(@as(?u8, 2), stopSignalNumber("2"));
    try std.testing.expectEqual(@as(?u8, null), stopSignalNumber("SIGKILL"));
    try std.testing.expectEqual(@as(?u8, null), stopSignalNumber("SIGSTOP"));
    try std.testing.expectEqual(@as(?u8, null), stopSignalNumber("RTMIN+2"));
}

test "rejects image stop signals the guest cannot forward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"architecture":"arm64","os":"linux","config":{"StopSignal":"SIGKILL"},"rootfs":{"type":"layers","diff_ids":[]}}
    ;
    try std.testing.expectError(error.InvalidImageConfig, parse(arena.allocator(), body, 0));
}
