const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const manifest = @import("manifest.zig");
const reference = @import("reference.zig");
const storage = @import("../storage.zig");

const dockerfile_limit = 1024 * 1024;
const build_layer_limit = 8 * 1024 * 1024 * 1024;
const copy_count_limit = 128;
const copy_entry_limit = 100_000;
const copy_path_list_limit = 64 * 1024 * 1024;
const copy_depth_limit = 128;

pub const Copy = struct { source: []const u8, target: []const u8, target_is_directory: bool };

pub const BuildConfig = struct {
    env: []const []const u8 = &.{},
    user: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    entrypoint: ?[]const []const u8 = null,
    cmd: ?[]const []const u8 = null,
};

pub const Plan = struct {
    context_path: []const u8,
    base_reference: []const u8,
    copies: []const Copy,
    config: BuildConfig,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.context_path);
        allocator.free(self.base_reference);
        for (self.copies) |copy| {
            allocator.free(copy.source);
            allocator.free(copy.target);
        }
        allocator.free(self.copies);
        for (self.config.env) |entry| allocator.free(entry);
        allocator.free(self.config.env);
        if (self.config.user) |value| allocator.free(value);
        if (self.config.working_dir) |value| allocator.free(value);
        if (self.config.entrypoint) |value| freeArguments(allocator, value);
        if (self.config.cmd) |value| freeArguments(allocator, value);
    }
};

pub const Result = struct { digest: []const u8, layer_count: usize };

const DirectoryMetadata = struct { path: []const u8, mode: u16, mtime: Io.Timestamp };

const BuildAccounting = struct {
    input_bytes: u64 = 0,
    entry_count: usize = 0,
    visited_entries: usize = 0,
    path_list_bytes: usize = 0,

    fn noteVisitedEntry(self: *BuildAccounting) !void {
        if (self.visited_entries == copy_entry_limit) return error.BuildTooManyEntries;
        self.visited_entries += 1;
    }

    fn addPath(self: *BuildAccounting, writer: *Io.Writer, path: []const u8) !void {
        const bytes = std.math.add(usize, path.len, 1) catch return error.BuildTooManyEntries;
        if (self.entry_count == copy_entry_limit or bytes > copy_path_list_limit - self.path_list_bytes) return error.BuildTooManyEntries;
        try writer.writeAll(path);
        try writer.writeAll("\x00");
        self.entry_count += 1;
        self.path_list_bytes += bytes;
    }

    fn addFileSize(self: *BuildAccounting, size: u64) !void {
        if (self.input_bytes > build_layer_limit or size > build_layer_limit - self.input_bytes) return error.BuildLayerTooLarge;
        self.input_bytes += size;
    }
};

const SourceParent = struct {
    dir: Io.Dir,
    basename: []const u8,
    owned_dir: ?Io.Dir,

    fn deinit(self: *SourceParent, io: Io) void {
        if (self.owned_dir) |dir| dir.close(io);
    }
};

pub fn readPlan(allocator: std.mem.Allocator, io: Io, context_argument: []const u8) !Plan {
    var context = Io.Dir.cwd().openDir(io, context_argument, .{ .iterate = true }) catch return error.InvalidBuildContext;
    defer context.close(io);

    if (context.statFile(io, ".dockerignore", .{ .follow_symlinks = false })) |_| {
        return error.UnsupportedDockerIgnore;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.InvalidBuildContext,
    }

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
    var environment: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (environment.items) |entry| allocator.free(entry);
        environment.deinit(allocator);
    }
    var user: ?[]const u8 = null;
    errdefer if (user) |value| allocator.free(value);
    var working_dir: ?[]const u8 = null;
    errdefer if (working_dir) |value| allocator.free(value);
    var entrypoint: ?[]const []const u8 = null;
    errdefer if (entrypoint) |value| freeArguments(allocator, value);
    var command: ?[]const []const u8 = null;
    errdefer if (command) |value| freeArguments(allocator, value);

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
            const target_is_directory = target_arg.len > 1 and target_arg[target_arg.len - 1] == '/';
            const normalized_target = if (target_is_directory) target_arg[0 .. target_arg.len - 1] else target_arg;
            if (!validContextPath(normalized_source)) return error.InvalidBuildSource;
            if (!validTarget(normalized_target)) return error.InvalidBuildTarget;
            const source = try allocator.dupe(u8, normalized_source);
            const target = allocator.dupe(u8, normalized_target) catch |err| {
                allocator.free(source);
                return err;
            };
            copies.append(allocator, .{ .source = source, .target = target, .target_is_directory = target_is_directory }) catch |err| {
                allocator.free(source);
                allocator.free(target);
                return err;
            };
        } else if (std.ascii.eqlIgnoreCase(instruction, "ENV")) {
            if (base_reference == null) return error.InvalidDockerfile;
            var found_assignment = false;
            while (try nextEnvironmentAssignment(allocator, line, &offset)) |assignment| {
                found_assignment = true;
                const key = environmentKey(assignment);
                var replaced = false;
                for (environment.items) |*existing| {
                    if (!std.mem.eql(u8, environmentKey(existing.*), key)) continue;
                    allocator.free(existing.*);
                    existing.* = assignment;
                    replaced = true;
                    break;
                }
                if (!replaced) {
                    environment.append(allocator, assignment) catch |err| {
                        allocator.free(assignment);
                        return err;
                    };
                }
            }
            if (!found_assignment) return error.InvalidDockerfile;
        } else if (std.ascii.eqlIgnoreCase(instruction, "USER")) {
            if (base_reference == null) return error.InvalidDockerfile;
            const value = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.InvalidDockerfile;
            const owned = try allocator.dupe(u8, value);
            if (user) |previous| allocator.free(previous);
            user = owned;
        } else if (std.ascii.eqlIgnoreCase(instruction, "WORKDIR")) {
            if (base_reference == null) return error.InvalidDockerfile;
            const raw_path = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.InvalidDockerfile;
            const path = normalizeWorkingDirectory(raw_path) orelse return error.UnsupportedBuildWorkingDirectory;
            const config_path = try allocator.dupe(u8, path);
            if (working_dir) |previous| allocator.free(previous);
            working_dir = config_path;
        } else if (std.ascii.eqlIgnoreCase(instruction, "ENTRYPOINT")) {
            if (base_reference == null) return error.InvalidDockerfile;
            const value = try parseCommand(allocator, line[offset..]) orelse return error.InvalidDockerfile;
            if (entrypoint) |previous| freeArguments(allocator, previous);
            entrypoint = value;
        } else if (std.ascii.eqlIgnoreCase(instruction, "CMD")) {
            if (base_reference == null) return error.InvalidDockerfile;
            const value = try parseCommand(allocator, line[offset..]) orelse return error.InvalidDockerfile;
            if (command) |previous| freeArguments(allocator, previous);
            command = value;
        } else {
            return error.UnsupportedDockerfileInstruction;
        }
    }
    if (base_reference == null) return error.InvalidDockerfile;
    const owned_context_path = try allocator.dupe(u8, context_path);
    errdefer allocator.free(owned_context_path);
    const owned_copies = try copies.toOwnedSlice(allocator);
    errdefer {
        for (owned_copies) |copy| {
            allocator.free(copy.source);
            allocator.free(copy.target);
        }
        allocator.free(owned_copies);
    }
    const owned_environment = try environment.toOwnedSlice(allocator);
    errdefer {
        for (owned_environment) |entry| allocator.free(entry);
        allocator.free(owned_environment);
    }
    return .{
        .context_path = owned_context_path,
        .base_reference = base_reference.?,
        .copies = owned_copies,
        .config = .{
            .env = owned_environment,
            .user = user,
            .working_dir = working_dir,
            .entrypoint = entrypoint,
            .cmd = command,
        },
    };
}

fn freeArguments(allocator: std.mem.Allocator, arguments: []const []const u8) void {
    for (arguments) |argument| allocator.free(argument);
    allocator.free(arguments);
}

fn environmentKey(assignment: []const u8) []const u8 {
    return assignment[0..std.mem.indexOfScalar(u8, assignment, '=').?];
}

fn nextEnvironmentAssignment(allocator: std.mem.Allocator, line: []const u8, offset: *usize) !?[]const u8 {
    while (offset.* < line.len and (line[offset.*] == ' ' or line[offset.*] == '\t')) : (offset.* += 1) {}
    if (offset.* == line.len) return null;

    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    var quote: u8 = 0;
    while (offset.* < line.len) : (offset.* += 1) {
        const character = line[offset.*];
        if (quote == 0 and (character == ' ' or character == '\t')) break;
        if (character == '\'' or character == '"') {
            if (quote == 0) {
                quote = character;
                continue;
            }
            if (quote == character) {
                quote = 0;
                continue;
            }
        }
        try value.append(allocator, character);
    }
    if (quote != 0) return error.InvalidDockerfile;
    const assignment = try value.toOwnedSlice(allocator);
    errdefer allocator.free(assignment);
    const separator = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.InvalidDockerfile;
    if (!validEnvironmentKey(assignment[0..separator])) return error.InvalidDockerfile;
    return assignment;
}

fn validEnvironmentKey(key: []const u8) bool {
    if (key.len == 0 or !std.ascii.isAlphabetic(key[0]) and key[0] != '_') return false;
    for (key[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    return true;
}

fn normalizeWorkingDirectory(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.eql(u8, path, "/")) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    const normalized = path[0..end];
    return if (validTarget(normalized)) normalized else null;
}

fn parseCommand(allocator: std.mem.Allocator, raw: []const u8) !?[]const []const u8 {
    const value = std.mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return null;
    if (value[0] == '[') {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky([]const []const u8, arena.allocator(), value, .{}) catch return error.InvalidDockerfile;
        const result = try allocator.alloc([]const u8, parsed.len);
        var copied: usize = 0;
        errdefer {
            for (result[0..copied]) |argument| allocator.free(argument);
            allocator.free(result);
        }
        for (parsed) |argument| {
            if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidDockerfile;
            result[copied] = try allocator.dupe(u8, argument);
            copied += 1;
        }
        return result;
    }
    const result = try allocator.alloc([]const u8, 3);
    errdefer allocator.free(result);
    result[0] = try allocator.dupe(u8, "/bin/sh");
    errdefer allocator.free(result[0]);
    result[1] = try allocator.dupe(u8, "-c");
    errdefer allocator.free(result[1]);
    result[2] = try allocator.dupe(u8, value);
    return result;
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
    var archive_paths = try stage.createFile(io, "archive-paths.nul", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer archive_paths.close(io);
    var archive_paths_buffer: [32 * 1024]u8 = undefined;
    var archive_paths_writer = archive_paths.writerStreaming(io, &archive_paths_buffer);
    var accounting: BuildAccounting = .{};
    var directory_metadata: std.ArrayList(DirectoryMetadata) = .empty;
    defer {
        for (directory_metadata.items) |entry| allocator.free(entry.path);
        directory_metadata.deinit(allocator);
    }
    for (plan.copies) |copy| {
        try copySource(allocator, io, context, layer_root, copy, &archive_paths_writer.interface, &accounting, &directory_metadata);
    }
    try archive_paths_writer.interface.flush();
    try applyDirectoryMetadata(io, layer_root, directory_metadata.items);

    var stage_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const stage_path = try stage.realPath(io, &stage_path_buffer);
    const layer_path = try std.fmt.allocPrint(allocator, "{s}/layer", .{stage_path_buffer[0..stage_path]});
    defer allocator.free(layer_path);
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/layer.tar", .{stage_path_buffer[0..stage_path]});
    defer allocator.free(archive_path);
    const path_list_path = try std.fmt.allocPrint(allocator, "{s}/archive-paths.nul", .{stage_path_buffer[0..stage_path]});
    defer allocator.free(path_list_path);
    try createLayerArchive(allocator, io, archive_path, layer_path, path_list_path);
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
    const new_config = try appendDiffId(scratch, base_config_body, layer_digest, plan.config);
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

fn openSourceParent(io: Io, context: Io.Dir, path: []const u8) !SourceParent {
    var components = std.mem.splitScalar(u8, path, '/');
    var current = context;
    var owned_current: ?Io.Dir = null;
    const first = components.next() orelse return error.InvalidBuildSource;
    var basename = first;
    while (components.next()) |next_component| {
        const next = current.openDir(io, basename, .{ .follow_symlinks = false }) catch return error.InvalidBuildSource;
        if (owned_current) |previous| previous.close(io);
        owned_current = next;
        current = next;
        basename = next_component;
    }
    return .{ .dir = current, .basename = basename, .owned_dir = owned_current };
}

fn copySource(
    allocator: std.mem.Allocator,
    io: Io,
    context: Io.Dir,
    layer_root: Io.Dir,
    copy: Copy,
    archive_writer: *Io.Writer,
    accounting: *BuildAccounting,
    directory_metadata: *std.ArrayList(DirectoryMetadata),
) !void {
    var source_parent = try openSourceParent(io, context, copy.source);
    defer source_parent.deinit(io);
    const source_info = source_parent.dir.statFile(io, source_parent.basename, .{ .follow_symlinks = false }) catch return error.InvalidBuildSource;
    const target_relative = copy.target[1..];
    switch (source_info.kind) {
        .file => {
            const file_target = if (copy.target_is_directory)
                try joinBuildPath(allocator, target_relative, source_parent.basename)
            else
                try allocator.dupe(u8, target_relative);
            defer allocator.free(file_target);
            try copyRegularFile(io, source_parent.dir, source_parent.basename, source_info, layer_root, file_target, archive_writer, accounting);
        },
        .directory => {
            if (source_info.permissions.toMode() & 0o500 != 0o500) return error.UnsupportedBuildDirectoryPermissions;
            var source_dir = source_parent.dir.openDir(io, source_parent.basename, .{ .iterate = true, .follow_symlinks = false }) catch return error.InvalidBuildSource;
            defer source_dir.close(io);
            const entries_before = accounting.entry_count;
            try copyDirectoryContents(allocator, io, source_dir, target_relative, layer_root, archive_writer, accounting, directory_metadata, 0);
            if (accounting.entry_count == entries_before) {
                try layer_root.createDirPath(io, target_relative);
                try layer_root.setTimestamps(io, target_relative, .{ .modify_timestamp = .{ .new = source_info.mtime } });
                try accounting.addPath(archive_writer, target_relative);
                try recordDirectoryMetadata(allocator, directory_metadata, target_relative, 0o755, source_info.mtime);
            }
        },
        else => return error.InvalidBuildSource,
    }
}

fn copyDirectoryContents(
    allocator: std.mem.Allocator,
    io: Io,
    source_dir: Io.Dir,
    target_prefix: []const u8,
    layer_root: Io.Dir,
    archive_writer: *Io.Writer,
    accounting: *BuildAccounting,
    directory_metadata: *std.ArrayList(DirectoryMetadata),
    depth: usize,
) anyerror!void {
    if (depth >= copy_depth_limit) return error.BuildTooManyEntries;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var entries = source_dir.iterate();
    while (try entries.next(io)) |entry| {
        try accounting.noteVisitedEntry();
        const name = try allocator.dupe(u8, entry.name);
        names.append(allocator, name) catch |err| {
            allocator.free(name);
            return err;
        };
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (names.items) |name| {
        const source_info = source_dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.InvalidBuildSource;
        const target_path = try joinBuildPath(allocator, target_prefix, name);
        defer allocator.free(target_path);
        switch (source_info.kind) {
            .file => try copyRegularFile(io, source_dir, name, source_info, layer_root, target_path, archive_writer, accounting),
            .directory => {
                const mode = source_info.permissions.toMode() & 0o777;
                if (mode & 0o500 != 0o500) return error.UnsupportedBuildDirectoryPermissions;
                try layer_root.createDirPath(io, target_path);
                try accounting.addPath(archive_writer, target_path);
                try recordDirectoryMetadata(allocator, directory_metadata, target_path, mode, source_info.mtime);
                var child_dir = source_dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch return error.InvalidBuildSource;
                defer child_dir.close(io);
                try copyDirectoryContents(allocator, io, child_dir, target_path, layer_root, archive_writer, accounting, directory_metadata, depth + 1);
            },
            else => return error.InvalidBuildSource,
        }
    }
}

fn joinBuildPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
    if (path.len > 4096) {
        allocator.free(path);
        return error.InvalidBuildSource;
    }
    return path;
}

fn recordDirectoryMetadata(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(DirectoryMetadata),
    path: []const u8,
    mode: u16,
    mtime: Io.Timestamp,
) !void {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            entry.mode = mode;
            entry.mtime = mtime;
            return;
        }
    }
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try entries.append(allocator, .{ .path = owned_path, .mode = mode, .mtime = mtime });
}

fn applyDirectoryMetadata(io: Io, root: Io.Dir, entries: []DirectoryMetadata) !void {
    std.mem.sort(DirectoryMetadata, entries, {}, struct {
        fn lessThan(_: void, lhs: DirectoryMetadata, rhs: DirectoryMetadata) bool {
            return lhs.path.len > rhs.path.len;
        }
    }.lessThan);
    for (entries) |entry| {
        const separator = std.mem.lastIndexOfScalar(u8, entry.path, '/');
        const parent_path = if (separator) |index| entry.path[0..index] else null;
        const basename_start = if (separator) |index| index + 1 else 0;
        const basename = entry.path[basename_start..];
        var parent = if (parent_path) |path|
            try root.openDir(io, path, .{ .iterate = true, .follow_symlinks = false })
        else
            root;
        defer if (parent_path != null) parent.close(io);
        var directory = try parent.openDir(io, basename, .{ .iterate = true, .follow_symlinks = false });
        defer directory.close(io);
        try directory.setPermissions(io, .fromMode(entry.mode));
        try parent.setTimestamps(io, basename, .{
            .follow_symlinks = false,
            .modify_timestamp = .{ .new = entry.mtime },
        });
    }
}

fn copyRegularFile(
    io: Io,
    source_parent: Io.Dir,
    source_name: []const u8,
    source_info: Io.File.Stat,
    layer_root: Io.Dir,
    target_relative: []const u8,
    archive_writer: *Io.Writer,
    accounting: *BuildAccounting,
) !void {
    if (source_info.kind != .file) return error.InvalidBuildSource;
    try accounting.addFileSize(source_info.size);
    const source = source_parent.openFile(io, source_name, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false }) catch return error.InvalidBuildSource;
    defer source.close(io);

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
    try accounting.addPath(archive_writer, target_relative);
}

fn createLayerArchive(allocator: std.mem.Allocator, io: Io, archive_path: []const u8, layer_path: []const u8, path_list_path: []const u8) !void {
    // macOS bsdtar defaults to restricted PAX, avoiding volatile atime/ctime headers.
    const arguments = &.{
        "/usr/bin/tar",
        "-c",
        "--uid=0",
        "--gid=0",
        "-f",
        archive_path,
        "-C",
        layer_path,
        "--null",
        "--no-recursion",
        "-T",
        path_list_path,
    };
    const result = std.process.run(allocator, io, .{
        .argv = arguments,
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

fn appendDiffId(allocator: std.mem.Allocator, body: []const u8, digest: []const u8, changes: BuildConfig) ![]u8 {
    var image = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    if (image != .object) return error.InvalidImageConfig;

    var image_config: *std.json.Value = undefined;
    if (image.object.getPtr("config")) |existing| {
        image_config = existing;
    } else {
        try image.object.put(allocator, "config", .{ .object = .{} });
        image_config = image.object.getPtr("config").?;
    }
    if (image_config.* == .null) image_config.* = .{ .object = .{} };
    if (image_config.* != .object) return error.InvalidImageConfig;

    const rootfs = image.object.getPtr("rootfs") orelse return error.InvalidImageConfig;
    if (rootfs.* != .object) return error.InvalidImageConfig;
    const diff_ids = rootfs.object.getPtr("diff_ids") orelse return error.InvalidImageConfig;
    if (diff_ids.* != .array) return error.InvalidImageConfig;
    try diff_ids.array.append(.{ .string = digest });

    if (changes.env.len != 0) {
        var environment: std.ArrayList([]const u8) = .empty;
        defer environment.deinit(allocator);
        if (image_config.object.get("Env")) |existing| {
            if (existing == .array) {
                for (existing.array.items) |entry| {
                    if (entry != .string) return error.InvalidImageConfig;
                    try environment.append(allocator, entry.string);
                }
            } else if (existing != .null) return error.InvalidImageConfig;
        }
        for (changes.env) |assignment| {
            const key = environmentKey(assignment);
            var index: usize = 0;
            while (index < environment.items.len) {
                if (std.mem.eql(u8, environmentKey(environment.items[index]), key)) {
                    _ = environment.orderedRemove(index);
                } else {
                    index += 1;
                }
            }
            try environment.append(allocator, assignment);
        }
        var values = std.json.Array.init(allocator);
        for (environment.items) |entry| try values.append(.{ .string = entry });
        try image_config.object.put(allocator, "Env", .{ .array = values });
    }
    if (changes.user) |value| try image_config.object.put(allocator, "User", .{ .string = value });
    if (changes.working_dir) |value| try image_config.object.put(allocator, "WorkingDir", .{ .string = value });
    if (changes.entrypoint) |value| {
        var arguments = std.json.Array.init(allocator);
        for (value) |argument| try arguments.append(.{ .string = argument });
        try image_config.object.put(allocator, "Entrypoint", .{ .array = arguments });
    }
    if (changes.cmd) |value| {
        var arguments = std.json.Array.init(allocator);
        for (value) |argument| try arguments.append(.{ .string = argument });
        try image_config.object.put(allocator, "Cmd", .{ .array = arguments });
    }
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
    const start: usize = if (std.mem.startsWith(u8, source, "./")) 2 else 0;
    var end = source.len;
    while (end > start and source[end - 1] == '/') : (end -= 1) {}
    return source[start..end];
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
    const plan = try parseDockerfile(std.testing.allocator, "/tmp/context", "FROM alpine:3.21\nCOPY 'hello world' /app/hello\nCOPY folder/ /opt/app/\n");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:3.21", plan.base_reference);
    try std.testing.expectEqual(@as(usize, 2), plan.copies.len);
    try std.testing.expectEqualStrings("hello world", plan.copies[0].source);
    try std.testing.expectEqualStrings("/app/hello", plan.copies[0].target);
    try std.testing.expectEqualStrings("folder", plan.copies[1].source);
    try std.testing.expectEqualStrings("/opt/app", plan.copies[1].target);
    try std.testing.expect(plan.copies[1].target_is_directory);
}

test "parses and owns common process config instructions" {
    var plan = try parseDockerfile(
        std.testing.allocator,
        "/tmp/context",
        "FROM alpine\nENV BUILD_MESSAGE=\"hello world\" BUILD_MODE=preview\nENV BUILD_MODE=local\nUSER 65534\nWORKDIR /tmp/rift-app/\nENTRYPOINT [\"/bin/sh\",\"-c\"]\nCMD [\"printf '%s:%s:%s\\\\n' \\\"$BUILD_MESSAGE\\\" \\\"$PWD\\\" \\\"$(id -u)\\\"\"]\n",
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.copies.len);
    try std.testing.expectEqualStrings("BUILD_MESSAGE=hello world", plan.config.env[0]);
    try std.testing.expectEqualStrings("BUILD_MODE=local", plan.config.env[1]);
    try std.testing.expectEqualStrings("65534", plan.config.user.?);
    try std.testing.expectEqualStrings("/tmp/rift-app", plan.config.working_dir.?);
    try std.testing.expectEqualStrings("/bin/sh", plan.config.entrypoint.?[0]);
    try std.testing.expectEqualStrings("-c", plan.config.entrypoint.?[1]);
    try std.testing.expectEqual(@as(usize, 1), plan.config.cmd.?.len);
}

test "applies build process settings while preserving base image config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"architecture":"arm64","os":"linux","config":{"Env":["PATH=/bin","BUILD_MODE=base"],"Labels":{"example":"kept"}},"rootfs":{"type":"layers","diff_ids":[]}}
    ;
    const changes: BuildConfig = .{
        .env = &.{ "BUILD_MODE=local", "BUILD_MESSAGE=hello" },
        .user = "65534",
        .working_dir = "/tmp/rift-app",
        .entrypoint = &.{ "/bin/sh", "-c" },
        .cmd = &.{"printf ready"},
    };
    const updated = try appendDiffId(arena.allocator(), body, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", changes);
    const image = try config.parse(arena.allocator(), updated, 1);
    const process = image.config.?;
    try std.testing.expectEqualStrings("65534", process.User.?);
    try std.testing.expectEqualStrings("/tmp/rift-app", process.WorkingDir.?);
    try std.testing.expectEqualStrings("/bin/sh", process.Entrypoint.?[0]);
    try std.testing.expectEqualStrings("printf ready", process.Cmd.?[0]);
    try std.testing.expectEqual(@as(usize, 3), process.Env.?.len);
    try std.testing.expectEqualStrings("PATH=/bin", process.Env.?[0]);
    try std.testing.expectEqualStrings("BUILD_MODE=local", process.Env.?[1]);
    try std.testing.expectEqualStrings("BUILD_MESSAGE=hello", process.Env.?[2]);

    const dynamic = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), updated, .{});
    const config_value = dynamic.object.get("config").?.object;
    try std.testing.expectEqualStrings("kept", config_value.get("Labels").?.object.get("example").?.string);
}

test "rejects unsupported instructions, stages, and unsafe paths" {
    try std.testing.expectError(error.UnsupportedDockerfileInstruction, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nRUN echo unsafe\nCOPY a /a\n"));
    try std.testing.expectError(error.UnsupportedBuildStages, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nFROM alpine\nCOPY a /a\n"));
    try std.testing.expectError(error.InvalidBuildSource, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY ../secret /secret\n"));
    try std.testing.expectError(error.InvalidBuildTarget, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY file /../../secret\n"));
    try std.testing.expectError(error.UnsupportedBuildWorkingDirectory, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nWORKDIR relative\n"));
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nENV broken\n"));
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCMD [1]\n"));
}
