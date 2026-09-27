const std = @import("std");
const Io = std.Io;

const max_layer_bytes = 8 * 1024 * 1024 * 1024;

pub const DirectoryMetadata = struct {
    mode: u32,
    mtime: Io.Timestamp,
};

/// Apply a verified OCI layer to a private, unpublished root directory.
/// Whiteouts run first so they cannot delete files added by the same layer.
pub fn apply(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8, directory_metadata: *std.StringHashMap(DirectoryMetadata)) !void {
    try pass(allocator, io, root, blob, media_type, directory_metadata, .whiteouts);
    try pass(allocator, io, root, blob, media_type, directory_metadata, .entries);
}

const Pass = enum { whiteouts, entries };

fn pass(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8, directory_metadata: *std.StringHashMap(DirectoryMetadata), phase: Pass) !void {
    var input_buffer: [32 * 1024]u8 = undefined;
    var input = blob.reader(io, &input_buffer);
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar"))
    {
        return applyTar(allocator, io, root, &input.interface, directory_metadata, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip"))
    {
        var output_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&input.interface, .gzip, &output_buffer);
        return applyTar(allocator, io, root, &decompressor.reader, directory_metadata, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+zstd")) {
        const output_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer allocator.free(output_buffer);
        var decompressor = std.compress.zstd.Decompress.init(&input.interface, output_buffer, .{});
        return applyTar(allocator, io, root, &decompressor.reader, directory_metadata, phase);
    }
    return error.UnsupportedLayerMediaType;
}

fn applyTar(allocator: std.mem.Allocator, io: Io, root: Io.Dir, reader: *Io.Reader, directory_metadata: *std.StringHashMap(DirectoryMetadata), phase: Pass) !void {
    var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var total: u64 = 0;
    var count: usize = 0;
    while (true) {
        @memset(&name_buffer, 0);
        @memset(&link_buffer, 0);
        const next = it.next() catch |err| switch (err) {
            error.TarUnsupportedHeader => {
                count += 1;
                if (count > 1_000_000) return error.LayerTooLarge;
                try applyHardlink(io, root, &it, &name_buffer, &link_buffer, phase);
                continue;
            },
            else => return err,
        };
        const entry = next orelse break;
        const mtime = try tarMtime(&it.header_buffer);
        count += 1;
        if (count > 1_000_000 or entry.size > max_layer_bytes - total) return error.LayerTooLarge;
        total += entry.size;
        const path = try cleanPath(entry.name, &clean_buffer);
        if (path.len == 0 and entry.kind != .directory) return error.UnsafeLayerPath;

        const name = basename(path);
        const is_whiteout = std.mem.startsWith(u8, name, ".wh.");
        if (is_whiteout) {
            if (entry.kind != .file or entry.size != 0) return error.InvalidWhiteout;
            if (std.mem.eql(u8, name, ".wh.") or std.mem.eql(u8, name[4..], ".") or
                std.mem.eql(u8, name[4..], "..")) return error.InvalidWhiteout;
            if (phase == .whiteouts) try applyWhiteout(allocator, io, root, path, name);
            continue;
        }
        if (phase == .whiteouts or path.len == 0) continue;

        var parent = (try openParent(io, root, parentPath(path), true)).?;
        defer parent.close(io);
        switch (entry.kind) {
            .directory => {
                const mode: u32 = @intCast(entry.mode & 0o7777);
                const metadata: DirectoryMetadata = .{ .mode = mode, .mtime = mtime };
                if (directory_metadata.getPtr(path)) |stored_metadata| {
                    stored_metadata.* = metadata;
                } else {
                    try directory_metadata.put(try directory_metadata.allocator.dupe(u8, path), metadata);
                }
                const existing = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (existing) |stat| {
                    if (stat.kind == .directory) continue;
                    try parent.deleteTree(io, name);
                }
                try parent.createDirPath(io, name);
            },
            .file => {
                try parent.deleteTree(io, name);
                var output = try parent.createFile(io, name, .{
                    .exclusive = true,
                    .permissions = .fromMode(@intCast(entry.mode & 0o777)),
                });
                defer output.close(io);
                var output_buffer: [32 * 1024]u8 = undefined;
                var writer = output.writerStreaming(io, &output_buffer);
                try it.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
                try output.setPermissions(io, .fromMode(@intCast(entry.mode & 0o777)));
                try output.setTimestamps(io, .{ .modify_timestamp = .init(mtime) });
            },
            .sym_link => {
                try checkLink(path, entry.link_name);
                try parent.deleteTree(io, name);
                try parent.symLink(io, entry.link_name, name, .{});
                try parent.setTimestamps(io, name, .{
                    .follow_symlinks = false,
                    .modify_timestamp = .init(mtime),
                });
            },
        }
    }
}

pub fn applyDirectoryMetadata(io: Io, root: Io.Dir, directory_metadata: *std.StringHashMap(DirectoryMetadata)) !void {
    var entries = directory_metadata.iterator();
    while (entries.next()) |entry| try applyDirectoryMetadataEntry(io, root, entry.key_ptr.*, entry.value_ptr.*);
}

fn applyDirectoryMetadataEntry(io: Io, root: Io.Dir, path: []const u8, metadata: DirectoryMetadata) !void {
    var parent = openParent(io, root, parentPath(path), false) catch |err| switch (err) {
        error.UnsafeLayerPath => return,
        else => return err,
    } orelse return;
    defer parent.close(io);
    const name = basename(path);
    const stat = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return;
    var directory = parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return,
        else => return err,
    };
    defer directory.close(io);
    try directory.setPermissions(io, .fromMode(@intCast(metadata.mode)));
    try parent.setTimestamps(io, name, .{
        .follow_symlinks = false,
        .modify_timestamp = .init(metadata.mtime),
    });
}

fn applyHardlink(io: Io, root: Io.Dir, it: *std.tar.Iterator, name_buffer: []const u8, link_buffer: []const u8, phase: Pass) !void {
    const header = &it.header_buffer;
    if (header[156] != '1' or !std.mem.eql(u8, std.mem.trim(u8, header[124..136], "0 \x00"), "")) return error.TarUnsupportedHeader;

    var raw_name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const raw_name = if (name_buffer[0] != 0) std.mem.sliceTo(name_buffer, 0) else try tarHeaderName(header, &raw_name_buffer);
    const raw_target = if (link_buffer[0] != 0) std.mem.sliceTo(link_buffer, 0) else std.mem.sliceTo(header[157..257], 0);
    var clean_name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_target_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try cleanPath(raw_name, &clean_name_buffer);
    const target = try cleanPath(raw_target, &clean_target_buffer);
    if (path.len == 0 or target.len == 0 or std.mem.eql(u8, path, target)) return error.UnsafeLayerLink;
    if (std.mem.startsWith(u8, basename(path), ".wh.")) return error.InvalidWhiteout;
    if (phase == .whiteouts) return;
    const mtime = try tarMtime(header);

    var source = (try openParent(io, root, parentPath(target), false)) orelse return error.InvalidHardlink;
    defer source.close(io);
    if ((try source.statFile(io, basename(target), .{ .follow_symlinks = false })).kind != .file) return error.InvalidHardlink;
    var parent = (try openParent(io, root, parentPath(path), true)).?;
    defer parent.close(io);
    try parent.deleteTree(io, basename(path));
    try source.hardLink(basename(target), parent, basename(path), io, .{ .follow_symlinks = false });
    try parent.setTimestamps(io, basename(path), .{
        .follow_symlinks = false,
        .modify_timestamp = .init(mtime),
    });
}

fn tarMtime(header: *const [512]u8) !Io.Timestamp {
    const field = header[136..148];
    var seconds: i96 = undefined;
    if (field[0] & 0x80 != 0) {
        var encoded: i96 = @intCast(field[0] & 0x7f);
        for (field[1..]) |byte| encoded = encoded * 256 + byte;
        seconds = if (field[0] & 0x40 != 0) encoded - (@as(i96, 1) << 95) else encoded;
    } else {
        const text = std.mem.trim(u8, field, " \x00");
        seconds = if (text.len == 0) 0 else std.fmt.parseInt(i96, text, 8) catch return error.InvalidLayerTimestamp;
    }
    const nanoseconds = std.math.mul(i96, seconds, std.time.ns_per_s) catch return error.InvalidLayerTimestamp;
    return .fromNanoseconds(nanoseconds);
}

fn tarHeaderName(header: *const [512]u8, buffer: []u8) ![]const u8 {
    const name = std.mem.sliceTo(header[0..100], 0);
    const prefix = std.mem.sliceTo(header[345..500], 0);
    if (!std.mem.eql(u8, header[257..262], "ustar") or prefix.len == 0) return name;
    if (prefix.len + 1 + name.len > buffer.len) return error.UnsafeLayerPath;
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = '/';
    @memcpy(buffer[prefix.len + 1 ..][0..name.len], name);
    return buffer[0 .. prefix.len + 1 + name.len];
}

fn applyWhiteout(allocator: std.mem.Allocator, io: Io, root: Io.Dir, path: []const u8, name: []const u8) !void {
    var parent = (try openParent(io, root, parentPath(path), false)) orelse return;
    defer parent.close(io);
    if (std.mem.eql(u8, name, ".wh..wh..opq")) {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |child| allocator.free(child);
            names.deinit(allocator);
        }
        var entries = parent.iterate();
        while (try entries.next(io)) |entry| {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        for (names.items) |child| try parent.deleteTree(io, child);
    } else {
        try parent.deleteTree(io, name[4..]);
    }
}

fn openParent(io: Io, root: Io.Dir, path: []const u8, create: bool) !?Io.Dir {
    var current = try root.openDir(io, ".", .{ .follow_symlinks = false, .iterate = true });
    errdefer current.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        const next = current.openDir(io, component, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!create) {
                    current.close(io);
                    return null;
                }
                try current.createDirPath(io, component);
                break :blk try current.openDir(io, component, .{ .follow_symlinks = false, .iterate = true });
            },
            error.NotDir, error.SymLinkLoop => return error.UnsafeLayerPath,
            else => return err,
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn cleanPath(raw: []const u8, buffer: []u8) ![]const u8 {
    if (raw.len == 0 or raw[0] == '/' or raw.len >= buffer.len) return error.UnsafeLayerPath;
    var length: usize = 0;
    var components = std.mem.splitScalar(u8, raw, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..") or std.mem.indexOfScalar(u8, component, 0) != null) return error.UnsafeLayerPath;
        if (length != 0) {
            buffer[length] = '/';
            length += 1;
        }
        if (component.len > buffer.len - length) return error.UnsafeLayerPath;
        @memcpy(buffer[length..][0..component.len], component);
        length += component.len;
    }
    return buffer[0..length];
}

fn checkLink(path: []const u8, target: []const u8) !void {
    if (target.len == 0 or std.mem.indexOfScalar(u8, target, 0) != null) return error.UnsafeLayerLink;
    var depth: usize = if (target[0] == '/') 0 else blk: {
        const parent = parentPath(path);
        if (parent.len == 0) break :blk 0;
        break :blk 1 + std.mem.count(u8, parent, "/");
    };
    var components = std.mem.tokenizeScalar(u8, target, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.UnsafeLayerLink;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

test "applies whiteouts before current layer entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root/sub");
    try temp.dir.writeFile(io, .{ .sub_path = "root/old", .data = "old" });
    try temp.dir.writeFile(io, .{ .sub_path = "root/sub/old", .data = "old" });
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeFileBytes("old", "new", .{});
    try tar.writeFileBytes("sub/new", "new", .{});
    try tar.writeFileBytes(".wh.old", "", .{});
    try tar.writeFileBytes("sub/.wh..wh..opq", "", .{});
    var output_blob = try temp.dir.createFile(io, "layer.tar", .{});
    defer output_blob.close(io);
    try output_blob.writeStreamingAll(io, archive.written());
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);

    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    const old = try root.readFileAlloc(io, "old", allocator, .limited(10));
    defer allocator.free(old);
    try std.testing.expectEqualStrings("new", old);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "sub/old", .{}));
    const newer = try root.readFileAlloc(io, "sub/new", allocator, .limited(10));
    defer allocator.free(newer);
    try std.testing.expectEqualStrings("new", newer);
}

test "applies final directory modes after all layers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();

    var first_archive: Io.Writer.Allocating = .init(allocator);
    defer first_archive.deinit();
    var first_tar: std.tar.Writer = .{ .underlying_writer = &first_archive.writer };
    try first_tar.writeDir("tmp", .{ .mode = 0o1777, .mtime = 1_600_000_000 });
    try temp.dir.writeFile(io, .{ .sub_path = "first.tar", .data = first_archive.written() });
    const first_blob = try temp.dir.openFile(io, "first.tar", .{ .mode = .read_only });
    defer first_blob.close(io);
    try apply(allocator, io, root, first_blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata);

    var second_archive: Io.Writer.Allocating = .init(allocator);
    defer second_archive.deinit();
    var second_tar: std.tar.Writer = .{ .underlying_writer = &second_archive.writer };
    try second_tar.writeFileBytes("tmp/probe", "ok", .{ .mtime = 1_650_000_000 });
    try second_tar.writeLink("tmp/link", "probe", .{ .mtime = 1_550_000_000 });
    try temp.dir.writeFile(io, .{ .sub_path = "second.tar", .data = second_archive.written() });
    const second_blob = try temp.dir.openFile(io, "second.tar", .{ .mode = .read_only });
    defer second_blob.close(io);
    try apply(allocator, io, root, second_blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata);

    try applyDirectoryMetadata(io, root, &directory_metadata);
    const stat = try root.statFile(io, "tmp", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o1777), @as(u32, @intCast(stat.permissions.toMode() & 0o7777)));
    try std.testing.expectEqual(@as(i64, 1_600_000_000), stat.mtime.toSeconds());
    const file_stat = try root.statFile(io, "tmp/probe", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(i64, 1_650_000_000), file_stat.mtime.toSeconds());
    const link_stat = try root.statFile(io, "tmp/link", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(i64, 1_550_000_000), link_stat.mtime.toSeconds());
    const contents = try root.readFileAlloc(io, "tmp/probe", allocator, .limited(4));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("ok", contents);
}

test "rejects paths through symlink parents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeLink("escape", "/tmp", .{});
    try tar.writeFileBytes("escape/payload", "bad", .{});
    var output_blob = try temp.dir.createFile(io, "layer.tar", .{});
    defer output_blob.close(io);
    try output_blob.writeStreamingAll(io, archive.written());
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar"));
    var path_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.UnsafeLayerPath, cleanPath("../host", &path_buffer));
    try std.testing.expectError(error.UnsafeLayerLink, checkLink("bin/tool", "../../host"));
}

test "applies hardlinks and rejects targets outside the root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeFileBytes("source", "shared", .{});
    try writeTestHardlink(&archive.writer, "linked", "source");
    try temp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    const contents = try root.readFileAlloc(io, "linked", allocator, .limited(16));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("shared", contents);
    const source = try root.openFile(io, "source", .{ .mode = .read_write });
    defer source.close(io);
    try source.writeStreamingAll(io, "Shared");
    const linked_after_write = try root.readFileAlloc(io, "linked", allocator, .limited(16));
    defer allocator.free(linked_after_write);
    try std.testing.expectEqualStrings("Shared", linked_after_write);

    var unsafe: Io.Writer.Allocating = .init(allocator);
    defer unsafe.deinit();
    try writeTestHardlink(&unsafe.writer, "escape", "../outside");
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe.tar", .data = unsafe.written() });
    const unsafe_blob = try temp.dir.openFile(io, "unsafe.tar", .{ .mode = .read_only });
    defer unsafe_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, unsafe_blob, "application/vnd.oci.image.layer.v1.tar"));
}

fn applyOne(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    try apply(allocator, io, root, blob, media_type, &directory_metadata);
    try applyDirectoryMetadata(io, root, &directory_metadata);
}

fn writeTestHardlink(writer: *Io.Writer, name: []const u8, target: []const u8) !void {
    var header = std.tar.Writer.Header.init(.regular);
    try header.setPath("", name);
    try header.setLinkname(target);
    const bytes = std.mem.asBytes(&header);
    bytes[156] = '1';
    @memset(bytes[148..156], ' ');
    var checksum: usize = 0;
    for (bytes) |byte| checksum += byte;
    _ = try std.fmt.bufPrint(bytes[148..154], "{o:0>6}", .{checksum});
    bytes[154] = 0;
    try writer.writeAll(bytes);
}
