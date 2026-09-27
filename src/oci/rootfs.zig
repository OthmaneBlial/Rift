const std = @import("std");
const Io = std.Io;
const layers = @import("layers.zig");
const manifest = @import("manifest.zig");
const storage = @import("../storage.zig");

/// Assemble a selected platform manifest into a private, disposable directory.
/// The caller owns staging and must remove it if any layer fails.
pub fn assemble(allocator: std.mem.Allocator, io: Io, root: Io.Dir, control: Io.Dir, store: storage.BlobStore, manifest_digest: []const u8) !void {
    const body = try store.readVerifiedAlloc(allocator, manifest_digest, 4 * 1024 * 1024);
    defer allocator.free(body);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const image = try manifest.parseManifest(arena.allocator(), body);
    var directory_metadata = std.StringHashMap(layers.DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    var ownership = std.StringHashMap(layers.Ownership).init(arena.allocator());
    defer ownership.deinit();
    var expansion_budget: layers.ExpansionBudget = .{};
    for (image.layers) |layer| {
        const blob = try store.openVerified(layer.digest, layer.size);
        defer blob.close(io);
        try layers.apply(allocator, io, root, blob, layer.mediaType, &directory_metadata, &ownership, &expansion_budget);
    }
    try layers.applyDirectoryMetadata(io, root, &directory_metadata);
    try writeOwnershipManifest(allocator, io, control, &ownership);
}

fn writeOwnershipManifest(allocator: std.mem.Allocator, io: Io, control: Io.Dir, ownership: *std.StringHashMap(layers.Ownership)) !void {
    if (ownership.count() == 0) return;
    var total: usize = "RIFTOWN1".len;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var entries = ownership.iterator();
    while (entries.next()) |entry| {
        total = std.math.add(usize, total, 12 + entry.key_ptr.*.len) catch return error.OwnershipManifestTooLarge;
        if (total > layers.max_owner_manifest_bytes) return error.OwnershipManifestTooLarge;
        try paths.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var file = try control.createFile(io, "owners", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer control.deleteFile(io, "owners") catch {};
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll("RIFTOWN1");
    for (paths.items) |path| {
        const value = ownership.get(path).?;
        try writeU32(&writer.interface, value.uid);
        try writeU32(&writer.interface, value.gid);
        try writeU32(&writer.interface, std.math.cast(u32, path.len) orelse return error.OwnershipManifestTooLarge);
        try writer.interface.writeAll(path);
    }
    try writer.interface.flush();
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

test "writes a sorted binary manifest for non-root image owners" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "control");
    var control = try temp.dir.openDir(io, "control", .{});
    defer control.close(io);
    var ownership = std.StringHashMap(layers.Ownership).init(allocator);
    defer {
        var entries = ownership.iterator();
        while (entries.next()) |entry| allocator.free(entry.key_ptr.*);
        ownership.deinit();
    }
    try ownership.put(try allocator.dupe(u8, "z"), .{ .uid = 42, .gid = 43 });
    try ownership.put(try allocator.dupe(u8, "a"), .{ .uid = 1000, .gid = 2000 });
    try ownership.put(try allocator.dupe(u8, ""), .{ .uid = 1001, .gid = 1002 });

    try writeOwnershipManifest(allocator, io, control, &ownership);
    const contents = try control.readFileAlloc(io, "owners", allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("RIFTOWN1", contents[0..8]);
    try std.testing.expectEqual(@as(u32, 1001), manifestU32(contents, 8));
    try std.testing.expectEqual(@as(u32, 1002), manifestU32(contents, 12));
    try std.testing.expectEqual(@as(u32, 0), manifestU32(contents, 16));
    try std.testing.expectEqual(@as(u32, 1000), manifestU32(contents, 20));
    try std.testing.expectEqual(@as(u32, 2000), manifestU32(contents, 24));
    try std.testing.expectEqual(@as(u32, 1), manifestU32(contents, 28));
    try std.testing.expectEqual(@as(u8, 'a'), contents[32]);
    try std.testing.expectEqual(@as(u32, 42), manifestU32(contents, 33));
    try std.testing.expectEqual(@as(u32, 43), manifestU32(contents, 37));
    try std.testing.expectEqual(@as(u32, 1), manifestU32(contents, 41));
    try std.testing.expectEqual(@as(u8, 'z'), contents[45]);
}

fn manifestU32(contents: []const u8, offset: usize) u32 {
    var bytes: [4]u8 = undefined;
    @memcpy(&bytes, contents[offset..][0..4]);
    return std.mem.readInt(u32, &bytes, .little);
}
