const std = @import("std");
const Io = std.Io;
const layers = @import("layers.zig");
const manifest = @import("manifest.zig");
const storage = @import("../storage.zig");

/// Assemble a selected platform manifest into a private, disposable directory.
/// The caller owns staging and must remove it if any layer fails.
pub fn assemble(allocator: std.mem.Allocator, io: Io, root: Io.Dir, store: storage.BlobStore, manifest_digest: []const u8) !void {
    const body = try store.readVerifiedAlloc(allocator, manifest_digest, 4 * 1024 * 1024);
    defer allocator.free(body);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const image = try manifest.parseManifest(arena.allocator(), body);
    for (image.layers) |layer| {
        const blob = try store.openVerified(layer.digest, layer.size);
        defer blob.close(io);
        try layers.apply(allocator, io, root, blob, layer.mediaType);
    }
}
