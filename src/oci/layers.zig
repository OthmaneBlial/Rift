const std = @import("std");
const Io = std.Io;

const max_layer_bytes = 8 * 1024 * 1024 * 1024;

/// Apply a verified OCI layer to a private, unpublished root directory.
/// Whiteouts run first so they cannot delete files added by the same layer.
pub fn apply(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8) !void {
    try pass(allocator, io, root, blob, media_type, .whiteouts);
    try pass(allocator, io, root, blob, media_type, .entries);
}

const Pass = enum { whiteouts, entries };

fn pass(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8, phase: Pass) !void {
    var input_buffer: [32 * 1024]u8 = undefined;
    var input = blob.reader(io, &input_buffer);
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar"))
    {
        return applyTar(allocator, io, root, &input.interface, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip"))
    {
        var output_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&input.interface, .gzip, &output_buffer);
        return applyTar(allocator, io, root, &decompressor.reader, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+zstd")) {
        const output_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer allocator.free(output_buffer);
        var decompressor = std.compress.zstd.Decompress.init(&input.interface, output_buffer, .{});
        return applyTar(allocator, io, root, &decompressor.reader, phase);
    }
    return error.UnsupportedLayerMediaType;
}

fn applyTar(allocator: std.mem.Allocator, io: Io, root: Io.Dir, reader: *Io.Reader, phase: Pass) !void {
    var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var total: u64 = 0;
    var count: usize = 0;
    while (try it.next()) |entry| {
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
            },
            .sym_link => {
                try checkLink(path, entry.link_name);
                try parent.deleteTree(io, name);
                try parent.symLink(io, entry.link_name, name, .{});
            },
        }
    }
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

    try apply(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    const old = try root.readFileAlloc(io, "old", allocator, .limited(10));
    defer allocator.free(old);
    try std.testing.expectEqualStrings("new", old);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "sub/old", .{}));
    const newer = try root.readFileAlloc(io, "sub/new", allocator, .limited(10));
    defer allocator.free(newer);
    try std.testing.expectEqualStrings("new", newer);
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
    try std.testing.expectError(error.UnsafeLayerPath, apply(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar"));
    var path_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.UnsafeLayerPath, cleanPath("../host", &path_buffer));
    try std.testing.expectError(error.UnsafeLayerLink, checkLink("bin/tool", "../../host"));
}
