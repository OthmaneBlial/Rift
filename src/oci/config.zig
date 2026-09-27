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
    return image;
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
