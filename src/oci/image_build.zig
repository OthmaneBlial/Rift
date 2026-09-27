const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const manifest = @import("manifest.zig");
const reference = @import("reference.zig");
const storage = @import("../storage.zig");

const dockerfile_limit = 1024 * 1024;
const build_layer_limit = 8 * 1024 * 1024 * 1024;
const copy_count_limit = 128;

pub const Copy = struct { source: []const u8, target: []const u8 };

pub const Plan = struct {
    context_path: []const u8,
    base_reference: []const u8,
    copies: []const Copy,
};

pub const Result = struct { digest: []const u8, layer_count: usize };

pub fn readPlan(allocator: std.mem.Allocator, io: Io, context_argument: []const u8) !Plan {
    var context = Io.Dir.cwd().openDir(io, context_argument, .{ .iterate = true }) catch return error.InvalidBuildContext;
    defer context.close(io);

    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = context.realPath(io, &path_buffer) catch return error.InvalidBuildContext;
    const context_path = try allocator.dupe(u8, path_buffer[0..path_len]);
    defer allocator.free(context_path);

    const dockerfile = context.openFile(io, "Dockerfile", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false }) catch return error.InvalidBuildContext;
    defer dockerfile.close(io);
    if ((try dockerfile.stat(io)).size > dockerfile_limit) return error.InvalidDockerfile;
    var dockerfile_buffer: [16 * 1024]u8 = undefined;
    var dockerfile_reader = dockerfile.reader(io, &dockerfile_buffer);
    const body = try dockerfile_reader.interface.allocRemaining(allocator, .limited(dockerfile_limit));
    defer allocator.free(body);
    return parseDockerfile(allocator, context_path, body);
}

pub fn parseDockerfile(allocator: std.mem.Allocator, context_path: []const u8, body: []const u8) !Plan {
    if (body.len > dockerfile_limit or std.mem.indexOfScalar(u8, body, 0) != null) return error.InvalidDockerfile;
    var base_reference: ?[]const u8 = null;
    errdefer if (base_reference) |base| allocator.free(base);
    var copies: std.ArrayList(Copy) = .empty;
    errdefer {
        for (copies.items) |copy| {
            allocator.free(copy.source);
            allocator.free(copy.target);
        }
        copies.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[line.len - 1] == '\\') return error.InvalidDockerfile;
        const separator = std.mem.indexOfAny(u8, line, " \t") orelse return error.InvalidDockerfile;
        const instruction = line[0..separator];
        var offset = separator;
        if (std.ascii.eqlIgnoreCase(instruction, "FROM")) {
            if (base_reference != null or copies.items.len != 0) return error.UnsupportedBuildStages;
            const base = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.UnsupportedBuildStages;
            var parsed = reference.parse(allocator, base) catch return error.InvalidDockerfile;
            defer parsed.deinit(allocator);
            base_reference = try parsed.formatAlloc(allocator);
        } else if (std.ascii.eqlIgnoreCase(instruction, "COPY")) {
            if (base_reference == null or copies.items.len == copy_count_limit) return error.InvalidDockerfile;
            const source_arg = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            const target_arg = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.UnsupportedCopyForm;
            const normalized_source = normalizeSource(source_arg);
            if (!validContextPath(normalized_source)) return error.InvalidBuildSource;
            if (!validTarget(target_arg)) return error.InvalidBuildTarget;
            const source = try allocator.dupe(u8, normalized_source);
            const target = allocator.dupe(u8, target_arg) catch |err| {
                allocator.free(source);
                return err;
            };
            copies.append(allocator, .{ .source = source, .target = target }) catch |err| {
                allocator.free(source);
                allocator.free(target);
                return err;
            };
        } else {
            return error.UnsupportedDockerfileInstruction;
        }
    }
    if (base_reference == null or copies.items.len == 0) return error.InvalidDockerfile;
    const owned_context_path = try allocator.dupe(u8, context_path);
    errdefer allocator.free(owned_context_path);
    const owned_copies = try copies.toOwnedSlice(allocator);
    return .{
        .context_path = owned_context_path,
        .base_reference = base_reference.?,
        .copies = owned_copies,
    };
}

pub fn build(
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: Io.Dir,
    plan: Plan,
    base_manifest_digest: []const u8,
    store: storage.BlobStore,
) !Result {
    var context = Io.Dir.openDirAbsolute(io, plan.context_path, .{ .iterate = true, .follow_symlinks = false }) catch return error.InvalidBuildContext;
    defer context.close(io);
    const runtime = try openRuntimeStage(io, data_dir);
    defer runtime.close(io);
    const stage_name = stageName(allocator, io) catch return error.BuildStagingFailed;
    defer allocator.free(stage_name);
    try runtime.createDir(io, stage_name, .fromMode(0o700));
    errdefer runtime.deleteTree(io, stage_name) catch {};
    var stage = try runtime.openDir(io, stage_name, .{ .iterate = true, .follow_symlinks = false });
    defer stage.close(io);
    const active = try stage.createFile(io, "active.lock", .{ .exclusive = true, .lock = .exclusive, .permissions = .fromMode(0o600) });
    defer active.close(io);
    defer runtime.deleteTree(io, stage_name) catch {};

    try stage.createDir(io, "layer", .fromMode(0o700));
    var layer_root = try stage.openDir(io, "layer", .{ .iterate = true, .follow_symlinks = false });
    defer layer_root.close(io);
    var layer_paths: std.ArrayList([]const u8) = .empty;
    var layer_input_bytes: u64 = 0;
    for (plan.copies) |copy| {
        try copyRegularFile(allocator, io, context, layer_root, copy, &layer_paths, &layer_input_bytes);
    }

    var stage_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const stage_path = try stage.realPath(io, &stage_path_buffer);
    const layer_path = try std.fmt.allocPrint(allocator, "{s}/layer", .{stage_path_buffer[0..stage_path]});
    defer allocator.free(layer_path);
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/layer.tar", .{stage_path_buffer[0..stage_path]});
    defer allocator.free(archive_path);
    try createLayerArchive(allocator, io, archive_path, layer_path, layer_paths.items);
    const archive_info = try stage.statFile(io, "layer.tar", .{ .follow_symlinks = false });
    if (archive_info.kind != .file or archive_info.size > build_layer_limit) return error.BuildLayerTooLarge;
    const layer_digest = try hashFile(allocator, io, stage, "layer.tar", archive_info.size);
    const layer_file = try stage.openFile(io, "layer.tar", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer layer_file.close(io);
    var layer_reader_buffer: [32 * 1024]u8 = undefined;
    var layer_reader = layer_file.reader(io, &layer_reader_buffer);
    try store.writeVerified(layer_digest, archive_info.size, &layer_reader.interface);

    const base_body = try store.readVerifiedAlloc(allocator, base_manifest_digest, 4 * 1024 * 1024);
    defer allocator.free(base_body);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const base_manifest = try manifest.parseManifest(scratch, base_body);
    const base_config_body = try store.readVerifiedAlloc(scratch, base_manifest.config.digest, 4 * 1024 * 1024);
    if (base_config_body.len != base_manifest.config.size) return error.InvalidImageConfig;
    _ = try config.parse(scratch, base_config_body, base_manifest.layers.len);
    const new_config = try appendDiffId(scratch, base_config_body, layer_digest);
    const config_descriptor = try storeBytes(allocator, store, "application/vnd.oci.image.config.v1+json", new_config);

    var layers: std.ArrayList(manifest.Descriptor) = .empty;
    try layers.appendSlice(scratch, base_manifest.layers);
    try layers.append(scratch, .{
        .mediaType = "application/vnd.oci.image.layer.v1.tar",
        .digest = layer_digest,
        .size = archive_info.size,
    });
    const manifest_body = try std.json.Stringify.valueAlloc(scratch, manifest.Manifest{
        .schemaVersion = 2,
        .mediaType = "application/vnd.oci.image.manifest.v1+json",
        .config = config_descriptor,
        .layers = layers.items,
    }, .{});
    const output_manifest = try storeBytes(allocator, store, "application/vnd.oci.image.manifest.v1+json", manifest_body);
    return .{ .digest = output_manifest.digest, .layer_count = layers.items.len };
}

fn openRuntimeStage(io: Io, data_dir: Io.Dir) !Io.Dir {
    try data_dir.createDirPath(io, "runtime");
    return data_dir.openDir(io, "runtime", .{ .iterate = true, .follow_symlinks = false });
}

fn stageName(allocator: std.mem.Allocator, io: Io) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    return std.fmt.allocPrint(allocator, "run-{s}", .{std.fmt.bytesToHex(random, .lower)});
}

fn copyRegularFile(allocator: std.mem.Allocator, io: Io, context: Io.Dir, layer_root: Io.Dir, copy: Copy, layer_paths: *std.ArrayList([]const u8), layer_input_bytes: *u64) !void {
    var components = std.mem.splitScalar(u8, copy.source, '/');
    var current = context;
    var owned_current: ?Io.Dir = null;
    defer if (owned_current) |dir| dir.close(io);
    var component = components.next() orelse return error.InvalidBuildSource;
    while (components.next()) |next_component| {
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch return error.InvalidBuildSource;
        if (owned_current) |previous| previous.close(io);
        owned_current = next;
        current = next;
        component = next_component;
    }
    const source_info = current.statFile(io, component, .{ .follow_symlinks = false }) catch return error.InvalidBuildSource;
    if (source_info.kind != .file) return error.InvalidBuildSource;
    if (layer_input_bytes.* > build_layer_limit or source_info.size > build_layer_limit - layer_input_bytes.*) return error.BuildLayerTooLarge;
    layer_input_bytes.* += source_info.size;
    const source = current.openFile(io, component, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false }) catch return error.InvalidBuildSource;
    defer source.close(io);

    const target_relative = copy.target[1..];
    const separator = std.mem.lastIndexOfScalar(u8, target_relative, '/');
    const parent_path = if (separator) |index| target_relative[0..index] else ".";
    const basename_start = if (separator) |index| index + 1 else 0;
    const basename = target_relative[basename_start..];
    var parent = try layer_root.createDirPathOpen(io, parent_path, .{ .open_options = .{ .iterate = true, .follow_symlinks = false } });
    defer parent.close(io);
    var atomic = try parent.createFileAtomic(io, basename, .{
        .replace = true,
        .permissions = .fromMode(source_info.permissions.toMode() & 0o777),
    });
    defer atomic.deinit(io);
    var source_buffer: [32 * 1024]u8 = undefined;
    var source_reader = source.reader(io, &source_buffer);
    var target_buffer: [32 * 1024]u8 = undefined;
    var target_writer = atomic.file.writerStreaming(io, &target_buffer);
    var copied: u64 = 0;
    var buffer: [32 * 1024]u8 = undefined;
    while (true) {
        const count = try source_reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        const amount: u64 = @intCast(count);
        if (copied > build_layer_limit or amount > build_layer_limit - copied) return error.BuildLayerTooLarge;
        copied += amount;
        try target_writer.interface.writeAll(buffer[0..count]);
    }
    if (copied != source_info.size) return error.BuildSourceChanged;
    try target_writer.interface.flush();
    try atomic.file.setTimestamps(io, .{ .modify_timestamp = .{ .new = source_info.mtime } });
    try atomic.replace(io);
    try layer_paths.append(allocator, target_relative);
}

fn createLayerArchive(allocator: std.mem.Allocator, io: Io, archive_path: []const u8, layer_path: []const u8, files: []const []const u8) !void {
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(allocator, &.{
        "/usr/bin/tar",
        "-c",
        "--format=pax",
        "--uid=0",
        "--gid=0",
        "-f",
        archive_path,
        "-C",
        layer_path,
        "--",
    });
    try arguments.appendSlice(allocator, files);
    const result = std.process.run(allocator, io, .{
        .argv = arguments.items,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    }) catch return error.BuildArchiveFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.BuildArchiveFailed;
}

fn hashFile(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, expected_size: u64) ![]const u8 {
    const file = try dir.openFile(io, path, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    if ((try file.stat(io)).size != expected_size) return error.BuildArchiveFailed;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var buffer: [32 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        const amount: u64 = @intCast(count);
        if (total > expected_size or amount > expected_size - total) return error.BuildArchiveFailed;
        total += amount;
        hash.update(buffer[0..count]);
    }
    if (total != expected_size) return error.BuildArchiveFailed;
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn storeBytes(allocator: std.mem.Allocator, store: storage.BlobStore, media_type: []const u8, body: []const u8) !manifest.Descriptor {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(body);
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    const digest = try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
    var reader = Io.Reader.fixed(body);
    try store.writeVerified(digest, body.len, &reader);
    return .{ .mediaType = media_type, .digest = digest, .size = body.len };
}

fn appendDiffId(allocator: std.mem.Allocator, body: []const u8, digest: []const u8) ![]u8 {
    var image = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    if (image != .object) return error.InvalidImageConfig;
    const rootfs = image.object.getPtr("rootfs") orelse return error.InvalidImageConfig;
    if (rootfs.* != .object) return error.InvalidImageConfig;
    const diff_ids = rootfs.object.getPtr("diff_ids") orelse return error.InvalidImageConfig;
    if (diff_ids.* != .array) return error.InvalidImageConfig;
    try diff_ids.array.append(.{ .string = digest });
    return std.json.Stringify.valueAlloc(allocator, image, .{});
}

fn nextWord(line: []const u8, offset: *usize) !?[]const u8 {
    while (offset.* < line.len and (line[offset.*] == ' ' or line[offset.*] == '\t')) : (offset.* += 1) {}
    if (offset.* == line.len) return null;
    const quote = if (line[offset.*] == '\'' or line[offset.*] == '"') line[offset.*] else 0;
    if (quote != 0) offset.* += 1;
    const start = offset.*;
    while (offset.* < line.len and (quote != 0 or (line[offset.*] != ' ' and line[offset.*] != '\t'))) : (offset.* += 1) {
        if (quote != 0 and line[offset.*] == quote) break;
        if (quote == 0 and (line[offset.*] == '\'' or line[offset.*] == '"')) return error.InvalidDockerfile;
    }
    const word = line[start..offset.*];
    if (quote != 0) {
        if (offset.* == line.len or line[offset.*] != quote) return error.InvalidDockerfile;
        offset.* += 1;
        if (offset.* < line.len and line[offset.*] != ' ' and line[offset.*] != '\t') return error.InvalidDockerfile;
    }
    if (word.len == 0) return error.InvalidDockerfile;
    return word;
}

fn normalizeSource(source: []const u8) []const u8 {
    const normalized = if (std.mem.startsWith(u8, source, "./")) source[2..] else source;
    return normalized;
}

fn validContextPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or std.mem.indexOfAny(u8, path, "*?[]\\") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validTarget(path: []const u8) bool {
    if (path.len < 2 or path.len > 4096 or path[0] != '/' or path[path.len - 1] == '/') return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

test "parses a single-base Dockerfile with quoted local file copies" {
    const plan = try parseDockerfile(std.testing.allocator, "/tmp/context", "FROM alpine:3.21\nCOPY 'hello world' /app/hello\n");
    defer std.testing.allocator.free(plan.base_reference);
    defer std.testing.allocator.free(plan.context_path);
    defer {
        for (plan.copies) |copy| {
            std.testing.allocator.free(copy.source);
            std.testing.allocator.free(copy.target);
        }
        std.testing.allocator.free(plan.copies);
    }
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:3.21", plan.base_reference);
    try std.testing.expectEqualStrings("hello world", plan.copies[0].source);
    try std.testing.expectEqualStrings("/app/hello", plan.copies[0].target);
}

test "rejects unsupported instructions, stages, and unsafe paths" {
    try std.testing.expectError(error.UnsupportedDockerfileInstruction, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nRUN echo unsafe\nCOPY a /a\n"));
    try std.testing.expectError(error.UnsupportedBuildStages, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nFROM alpine\nCOPY a /a\n"));
    try std.testing.expectError(error.InvalidBuildSource, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY ../secret /secret\n"));
    try std.testing.expectError(error.InvalidBuildTarget, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY file /../../secret\n"));
}
