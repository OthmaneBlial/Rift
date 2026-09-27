const std = @import("std");

const sha256_prefix = "sha256:";

pub const BlobStore = struct {
    io: std.Io,
    blobs: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) anyerror!BlobStore {
        try root.createDirPath(io, "blobs/sha256");
        return .{
            .io = io,
            .blobs = try root.openDir(io, "blobs/sha256", .{}),
        };
    }

    pub fn deinit(store: *BlobStore) void {
        store.blobs.close(store.io);
        store.* = undefined;
    }

    pub fn containsVerified(store: BlobStore, digest: []const u8, expected_size: u64) anyerror!bool {
        const filename = try sha256Filename(digest);
        const file = store.blobs.openFile(store.io, filename, .{
            .mode = .read_only,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(store.io);

        if ((try file.stat(store.io)).size != expected_size) return false;

        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var total: u64 = 0;
        var reader_buffer: [32 * 1024]u8 = undefined;
        var buffer: [32 * 1024]u8 = undefined;
        var reader = file.readerStreaming(store.io, &reader_buffer);
        while (true) {
            const count = try reader.interface.readSliceShort(&buffer);
            if (count == 0) break;
            const amount: u64 = @intCast(count);
            if (total > expected_size or amount > expected_size - total) return false;
            hash.update(buffer[0..count]);
            total += amount;
            if (count < buffer.len) break;
        }
        return total == expected_size and hashMatches(hash.finalResult(), digest);
    }

    pub fn writeVerified(store: BlobStore, digest: []const u8, expected_size: u64, body: *std.Io.Reader) anyerror!void {
        const filename = try sha256Filename(digest);
        var atomic = try store.blobs.createFileAtomic(store.io, filename, .{ .replace = true });
        defer atomic.deinit(store.io);

        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var total: u64 = 0;
        var buffer: [32 * 1024]u8 = undefined;
        while (true) {
            const count = try body.readSliceShort(&buffer);
            if (count == 0) break;
            const amount: u64 = @intCast(count);
            if (total > expected_size or amount > expected_size - total) return error.BlobSizeMismatch;
            hash.update(buffer[0..count]);
            try atomic.file.writeStreamingAll(store.io, buffer[0..count]);
            total += amount;
            if (count < buffer.len) break;
        }

        if (total != expected_size) return error.BlobSizeMismatch;
        if (!hashMatches(hash.finalResult(), digest)) return error.BlobDigestMismatch;
        try atomic.replace(store.io);
    }
};

fn sha256Filename(digest: []const u8) error{UnsupportedDigestAlgorithm}![]const u8 {
    if (!std.mem.startsWith(u8, digest, sha256_prefix) or digest.len != sha256_prefix.len + 64) {
        return error.UnsupportedDigestAlgorithm;
    }
    for (digest[sha256_prefix.len..]) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return error.UnsupportedDigestAlgorithm;
    }
    return digest[sha256_prefix.len..];
}

fn hashMatches(hash: [std.crypto.hash.sha2.Sha256.digest_length]u8, digest: []const u8) bool {
    if (sha256Filename(digest)) |filename| {
        const actual = std.fmt.bytesToHex(hash, .lower);
        return std.mem.eql(u8, filename, &actual);
    } else |_| {
        return false;
    }
}

test "stores a blob atomically and verifies cached bytes" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    var body = std.Io.Reader.fixed("hello");
    const digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try store.writeVerified(digest, 5, &body);
    try std.testing.expect(try store.containsVerified(digest, 5));
    try std.testing.expect(!(try store.containsVerified(digest, 4)));
}

test "rejects wrong sizes and digests without publishing partial files" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    var short_body = std.Io.Reader.fixed("hello");
    const digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try std.testing.expectError(error.BlobSizeMismatch, store.writeVerified(digest, 6, &short_body));
    try std.testing.expect(!(try store.containsVerified(digest, 5)));

    var wrong_body = std.Io.Reader.fixed("hello");
    const wrong_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.BlobDigestMismatch, store.writeVerified(wrong_digest, 5, &wrong_body));
    try std.testing.expect(!(try store.containsVerified(wrong_digest, 5)));
}
