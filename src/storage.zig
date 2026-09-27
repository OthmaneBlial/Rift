const std = @import("std");

const sha256_prefix = "sha256:";

pub const BlobStore = struct {
    io: std.Io,
    blobs: std.Io.Dir,
    images: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) anyerror!BlobStore {
        try root.createDirPath(io, "blobs/sha256");
        try root.createDirPath(io, "images");
        const blobs = try root.openDir(io, "blobs/sha256", .{});
        errdefer blobs.close(io);
        return .{
            .io = io,
            .blobs = blobs,
            .images = try root.openDir(io, "images", .{ .iterate = true }),
        };
    }

    pub fn deinit(store: *BlobStore) void {
        store.images.close(store.io);
        store.blobs.close(store.io);
        store.* = undefined;
    }

    pub fn recordImage(store: BlobStore, allocator: std.mem.Allocator, record: ImageRecord) anyerror!void {
        if (!validImageRecord(record)) return error.InvalidImageMetadata;
        const filename = try imageFilename(allocator, record.reference);
        defer allocator.free(filename);
        const contents = try std.fmt.allocPrint(allocator, "v1\n{s}\n{s}\n{s}\n{d}", .{
            record.reference,
            record.digest,
            record.platform,
            record.layer_count,
        });
        defer allocator.free(contents);
        var atomic = try store.images.createFileAtomic(store.io, filename, .{ .replace = true });
        defer atomic.deinit(store.io);
        try atomic.file.writeStreamingAll(store.io, contents);
        try atomic.replace(store.io);
    }

    pub fn listImages(store: BlobStore, allocator: std.mem.Allocator) anyerror![]ImageRecord {
        var records: std.ArrayList(ImageRecord) = .empty;
        errdefer {
            deinitImageRecords(allocator, records.items);
            records.deinit(allocator);
        }

        var entries = store.images.iterate();
        while (try entries.next(store.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rift")) continue;
            const record = try readImageRecord(store, allocator, entry.name);
            try records.append(allocator, record);
        }

        std.mem.sort(ImageRecord, records.items, {}, struct {
            fn lessThan(_: void, lhs: ImageRecord, rhs: ImageRecord) bool {
                return std.mem.lessThan(u8, lhs.reference, rhs.reference);
            }
        }.lessThan);
        return records.toOwnedSlice(allocator);
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

        return fileMatches(store.io, file, digest, expected_size);
    }

    pub fn openVerified(store: BlobStore, digest: []const u8, expected_size: u64) anyerror!std.Io.File {
        const filename = try sha256Filename(digest);
        const file = try store.blobs.openFile(store.io, filename, .{
            .mode = .read_only,
            .follow_symlinks = false,
        });
        errdefer file.close(store.io);
        if (!(try fileMatches(store.io, file, digest, expected_size))) return error.CorruptCachedBlob;
        return file;
    }

    pub fn readVerifiedAlloc(store: BlobStore, allocator: std.mem.Allocator, digest: []const u8, max_size: u64) anyerror![]u8 {
        const filename = try sha256Filename(digest);
        const file = try store.blobs.openFile(store.io, filename, .{
            .mode = .read_only,
            .follow_symlinks = false,
        });
        defer file.close(store.io);
        const size = (try file.stat(store.io)).size;
        if (size > max_size or size > std.math.maxInt(usize)) return error.BlobTooLarge;
        const contents = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(contents);
        var buffer: [32 * 1024]u8 = undefined;
        var reader = file.reader(store.io, &buffer);
        try reader.interface.readSliceAll(contents);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(contents);
        if (!hashMatches(hash.finalResult(), digest)) return error.CorruptCachedBlob;
        return contents;
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
        }

        if (total != expected_size) return error.BlobSizeMismatch;
        if (!hashMatches(hash.finalResult(), digest)) return error.BlobDigestMismatch;
        try atomic.replace(store.io);
    }
};

fn fileMatches(io: std.Io, file: std.Io.File, digest: []const u8, expected_size: u64) !bool {
    if ((try file.stat(io)).size != expected_size) return false;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var reader_buffer: [32 * 1024]u8 = undefined;
    var buffer: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        const amount: u64 = @intCast(count);
        if (total > expected_size or amount > expected_size - total) return false;
        hash.update(buffer[0..count]);
        total += amount;
    }
    return total == expected_size and hashMatches(hash.finalResult(), digest);
}

pub const ImageRecord = struct {
    reference: []const u8,
    digest: []const u8,
    platform: []const u8,
    layer_count: usize,

    pub fn deinit(record: *ImageRecord, allocator: std.mem.Allocator) void {
        allocator.free(record.reference);
        allocator.free(record.digest);
        allocator.free(record.platform);
        record.* = undefined;
    }
};

pub fn deinitImageRecords(allocator: std.mem.Allocator, records: []ImageRecord) void {
    for (records) |*record| record.deinit(allocator);
    allocator.free(records);
}

fn readImageRecord(store: BlobStore, allocator: std.mem.Allocator, filename: []const u8) anyerror!ImageRecord {
    const file = try store.images.openFile(store.io, filename, .{ .mode = .read_only, .follow_symlinks = false });
    defer file.close(store.io);
    const size = (try file.stat(store.io)).size;
    if (size == 0 or size > 1024) return error.InvalidImageMetadata;
    const contents = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(contents);
    var reader_buffer: [256]u8 = undefined;
    var reader = file.readerStreaming(store.io, &reader_buffer);
    reader.interface.readSliceAll(contents) catch return error.InvalidImageMetadata;

    var fields = std.mem.splitScalar(u8, contents, '\n');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidImageMetadata, "v1")) return error.InvalidImageMetadata;
    const image_reference = fields.next() orelse return error.InvalidImageMetadata;
    const digest = fields.next() orelse return error.InvalidImageMetadata;
    const platform = fields.next() orelse return error.InvalidImageMetadata;
    const layer_count = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidImageMetadata, 10) catch return error.InvalidImageMetadata;
    if (fields.next() != null) return error.InvalidImageMetadata;

    const expected_filename = try imageFilename(allocator, image_reference);
    defer allocator.free(expected_filename);
    if (!std.mem.eql(u8, expected_filename, filename) or !validImageFields(image_reference, digest, platform)) {
        return error.InvalidImageMetadata;
    }
    const owned_reference = try allocator.dupe(u8, image_reference);
    errdefer allocator.free(owned_reference);
    const owned_digest = try allocator.dupe(u8, digest);
    errdefer allocator.free(owned_digest);
    const owned_platform = try allocator.dupe(u8, platform);
    errdefer allocator.free(owned_platform);
    return .{
        .reference = owned_reference,
        .digest = owned_digest,
        .platform = owned_platform,
        .layer_count = layer_count,
    };
}

fn validImageRecord(record: ImageRecord) bool {
    return validImageFields(record.reference, record.digest, record.platform);
}

fn validImageFields(image_reference: []const u8, digest: []const u8, platform: []const u8) bool {
    if (image_reference.len == 0 or image_reference.len > 768 or std.mem.indexOfAny(u8, image_reference, "\r\n\t") != null) return false;
    _ = sha256Filename(digest) catch return false;
    return std.mem.eql(u8, platform, "linux/arm64") or std.mem.eql(u8, platform, "linux/amd64");
}

fn imageFilename(allocator: std.mem.Allocator, image_reference: []const u8) std.mem.Allocator.Error![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(image_reference);
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(allocator, "{s}.rift", .{hex});
}

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
    const file = try store.openVerified(digest, 5);
    file.close(store.io);
    const cached = try store.readVerifiedAlloc(std.testing.allocator, digest, 100);
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualStrings("hello", cached);
    try store.blobs.writeFile(store.io, .{ .sub_path = digest[7..], .data = "other" });
    try std.testing.expectError(error.CorruptCachedBlob, store.openVerified(digest, 5));
    try std.testing.expectError(error.CorruptCachedBlob, store.readVerifiedAlloc(std.testing.allocator, digest, 100));
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

test "records images atomically and lists them in reference order" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    try store.recordImage(allocator, .{
        .reference = "registry-1.docker.io/library/zulu:latest",
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = "linux/arm64",
        .layer_count = 2,
    });
    try store.recordImage(allocator, .{
        .reference = "registry-1.docker.io/library/alpine:latest",
        .digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .platform = "linux/arm64",
        .layer_count = 1,
    });
    try store.recordImage(allocator, .{
        .reference = "registry-1.docker.io/library/zulu:latest",
        .digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .platform = "linux/arm64",
        .layer_count = 3,
    });

    const records = try store.listImages(allocator);
    defer deinitImageRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:latest", records[0].reference);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/zulu:latest", records[1].reference);
    try std.testing.expectEqualStrings("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", records[1].digest);
    try std.testing.expectEqual(@as(usize, 3), records[1].layer_count);
}

test "rejects unsafe or non SHA-256 image records" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    try std.testing.expectError(error.InvalidImageMetadata, store.recordImage(std.testing.allocator, .{
        .reference = "image\nforged",
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = "linux/arm64",
        .layer_count = 1,
    }));
    try std.testing.expectError(error.InvalidImageMetadata, store.recordImage(std.testing.allocator, .{
        .reference = "registry-1.docker.io/library/alpine:latest",
        .digest = "sha512:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .platform = "linux/arm64",
        .layer_count = 1,
    }));
}
