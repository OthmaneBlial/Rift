const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const manifest = @import("manifest.zig");
const reference = @import("reference.zig");
const storage = @import("../storage.zig");
const boot_assets = @import("../boot_assets.zig");
const guest = @import("../guest.zig");
const layer_ops = @import("layers.zig");
const rootfs = @import("rootfs.zig");
const vm = @import("../vm.zig");

const dockerfile_limit = 1024 * 1024;
const build_layer_limit = 8 * 1024 * 1024 * 1024;
const copy_count_limit = 128;
const run_count_limit = 128;
const copy_entry_limit = 100_000;
const copy_path_list_limit = 64 * 1024 * 1024;
const copy_depth_limit = 128;
const build_stage_limit = 128;

pub const Copy = struct { source: []const u8, target: []const u8, target_is_directory: bool, from_stage: ?usize = null };

pub const StageBase = union(enum) { image: []const u8, stage: usize };

pub const BuildConfig = struct {
    env: []const []const u8 = &.{},
    user: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    entrypoint: ?[]const []const u8 = null,
    cmd: ?[]const []const u8 = null,
    stop_signal: ?[]const u8 = null,
};

pub const Run = struct {
    command: []const []const u8,
    config: BuildConfig,
};

pub const Instruction = union(enum) {
    copy: Copy,
    run: Run,
};

pub const Stage = struct {
    base: StageBase,
    name: ?[]const u8,
    instruction_start: usize,
    instruction_count: usize,
    config: BuildConfig,
};

pub const Plan = struct {
    context_path: []const u8,
    stages: []const Stage,
    instructions: []const Instruction,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.context_path);
        for (self.instructions) |instruction| deinitInstruction(allocator, instruction);
        allocator.free(self.instructions);
        for (self.stages) |stage| deinitStage(allocator, stage);
        allocator.free(self.stages);
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

const StageDraft = struct {
    base: ?StageBase = null,
    name: ?[]const u8 = null,
    instruction_start: usize = 0,
    environment: std.ArrayList([]const u8) = .empty,
    user: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    entrypoint: ?[]const []const u8 = null,
    command: ?[]const []const u8 = null,
    stop_signal: ?[]const u8 = null,

    fn deinit(self: *StageDraft, allocator: std.mem.Allocator) void {
        if (self.base) |base| switch (base) {
            .image => |value| allocator.free(value),
            .stage => {},
        };
        if (self.name) |value| allocator.free(value);
        for (self.environment.items) |entry| allocator.free(entry);
        self.environment.deinit(allocator);
        if (self.user) |value| allocator.free(value);
        if (self.working_dir) |value| allocator.free(value);
        if (self.entrypoint) |value| freeArguments(allocator, value);
        if (self.command) |value| freeArguments(allocator, value);
        if (self.stop_signal) |value| allocator.free(value);
        self.* = .{};
    }

    fn buildConfig(self: StageDraft) BuildConfig {
        return .{
            .env = self.environment.items,
            .user = self.user,
            .working_dir = self.working_dir,
            .entrypoint = self.entrypoint,
            .cmd = self.command,
            .stop_signal = self.stop_signal,
        };
    }
};

pub fn parseDockerfile(allocator: std.mem.Allocator, context_path: []const u8, body: []const u8) !Plan {
    if (body.len > dockerfile_limit or std.mem.indexOfScalar(u8, body, 0) != null) return error.InvalidDockerfile;
    var instructions: std.ArrayList(Instruction) = .empty;
    errdefer {
        for (instructions.items) |instruction| deinitInstruction(allocator, instruction);
        instructions.deinit(allocator);
    }
    var stages: std.ArrayList(Stage) = .empty;
    errdefer {
        for (stages.items) |stage| deinitStage(allocator, stage);
        stages.deinit(allocator);
    }
    var draft: StageDraft = .{};
    defer draft.deinit(allocator);
    var copy_count: usize = 0;
    var run_count: usize = 0;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[line.len - 1] == '\\') return error.InvalidDockerfile;
        const separator = std.mem.indexOfAny(u8, line, " \t") orelse return error.InvalidDockerfile;
        const instruction = line[0..separator];
        var offset = separator;
        if (std.ascii.eqlIgnoreCase(instruction, "FROM")) {
            if (draft.base != null) try finishStage(allocator, &stages, &draft, instructions.items.len);
            if (stages.items.len == build_stage_limit) return error.BuildStageLimitExceeded;
            const base_token = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            var raw_name: ?[]const u8 = null;
            if (try nextWord(line, &offset)) |as_token| {
                if (!std.ascii.eqlIgnoreCase(as_token, "AS")) return error.UnsupportedBuildStages;
                const alias = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
                if (!validStageName(alias)) return error.InvalidDockerfile;
                for (stages.items) |stage| {
                    if (stage.name) |existing| {
                        if (std.ascii.eqlIgnoreCase(existing, alias)) return error.DuplicateBuildStage;
                    }
                }
                raw_name = alias;
            }
            if (try nextWord(line, &offset) != null) return error.UnsupportedBuildStages;
            const inherited = findStage(stages.items, base_token, false);
            var image_reference: ?[]const u8 = null;
            errdefer if (image_reference) |value| allocator.free(value);
            if (inherited == null) {
                var parsed = reference.parse(allocator, base_token) catch return error.InvalidDockerfile;
                defer parsed.deinit(allocator);
                image_reference = try parsed.formatAlloc(allocator);
            }
            var owned_name: ?[]const u8 = if (raw_name) |value| try lowerStageName(allocator, value) else null;
            errdefer if (owned_name) |value| allocator.free(value);
            const base: StageBase = if (inherited) |index|
                .{ .stage = index }
            else
                .{ .image = image_reference.? };
            draft = .{
                .base = base,
                .name = owned_name,
                .instruction_start = instructions.items.len,
            };
            image_reference = null;
            owned_name = null;
        } else if (std.ascii.eqlIgnoreCase(instruction, "COPY")) {
            if (draft.base == null or copy_count == copy_count_limit) return error.InvalidDockerfile;
            const first_arg = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            var from_stage: ?usize = null;
            const source_arg = if (std.mem.startsWith(u8, first_arg, "--from=")) blk: {
                const stage_name = first_arg[7..];
                if (stage_name.len == 0) return error.InvalidDockerfile;
                from_stage = findStage(stages.items, stage_name, true) orelse return error.UnknownBuildStage;
                break :blk try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            } else if (std.mem.startsWith(u8, first_arg, "--")) return error.UnsupportedCopyForm else first_arg;
            const target_arg = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.UnsupportedCopyForm;
            const normalized_source = if (from_stage != null) normalizeStageSource(source_arg) else normalizeSource(source_arg);
            const target_is_directory = target_arg.len > 1 and target_arg[target_arg.len - 1] == '/';
            const normalized_target = if (target_is_directory) target_arg[0 .. target_arg.len - 1] else target_arg;
            if (!validContextPath(normalized_source)) return error.InvalidBuildSource;
            if (!validTarget(normalized_target)) return error.InvalidBuildTarget;
            const source = try allocator.dupe(u8, normalized_source);
            const target = allocator.dupe(u8, normalized_target) catch |err| {
                allocator.free(source);
                return err;
            };
            instructions.append(allocator, .{ .copy = .{
                .source = source,
                .target = target,
                .target_is_directory = target_is_directory,
                .from_stage = from_stage,
            } }) catch |err| {
                allocator.free(source);
                allocator.free(target);
                return err;
            };
            copy_count += 1;
        } else if (std.ascii.eqlIgnoreCase(instruction, "RUN")) {
            if (draft.base == null or run_count == run_count_limit) return error.InvalidDockerfile;
            const run_command = try parseCommand(allocator, line[offset..]) orelse return error.InvalidDockerfile;
            const run_config = try duplicateRunConfig(allocator, draft.environment.items, draft.user, draft.working_dir);
            const run = Run{ .command = run_command, .config = run_config };
            instructions.append(allocator, .{ .run = run }) catch |err| {
                deinitRun(allocator, run);
                return err;
            };
            run_count += 1;
        } else if (std.ascii.eqlIgnoreCase(instruction, "ENV")) {
            if (draft.base == null) return error.InvalidDockerfile;
            var found_assignment = false;
            while (try nextEnvironmentAssignment(allocator, line, &offset)) |assignment| {
                found_assignment = true;
                const key = environmentKey(assignment);
                var replaced = false;
                for (draft.environment.items) |*existing| {
                    if (!std.mem.eql(u8, environmentKey(existing.*), key)) continue;
                    allocator.free(existing.*);
                    existing.* = assignment;
                    replaced = true;
                    break;
                }
                if (!replaced) draft.environment.append(allocator, assignment) catch |err| {
                    allocator.free(assignment);
                    return err;
                };
            }
            if (!found_assignment) return error.InvalidDockerfile;
        } else if (std.ascii.eqlIgnoreCase(instruction, "USER")) {
            if (draft.base == null) return error.InvalidDockerfile;
            const value = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.InvalidDockerfile;
            const owned = try allocator.dupe(u8, value);
            if (draft.user) |previous| allocator.free(previous);
            draft.user = owned;
        } else if (std.ascii.eqlIgnoreCase(instruction, "WORKDIR")) {
            if (draft.base == null) return error.InvalidDockerfile;
            const raw_path = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null) return error.InvalidDockerfile;
            const path = normalizeWorkingDirectory(raw_path) orelse return error.UnsupportedBuildWorkingDirectory;
            const config_path = try allocator.dupe(u8, path);
            if (draft.working_dir) |previous| allocator.free(previous);
            draft.working_dir = config_path;
        } else if (std.ascii.eqlIgnoreCase(instruction, "ENTRYPOINT")) {
            if (draft.base == null) return error.InvalidDockerfile;
            const value = try parseCommand(allocator, line[offset..]) orelse return error.InvalidDockerfile;
            if (draft.entrypoint) |previous| freeArguments(allocator, previous);
            draft.entrypoint = value;
        } else if (std.ascii.eqlIgnoreCase(instruction, "CMD")) {
            if (draft.base == null) return error.InvalidDockerfile;
            const value = try parseCommand(allocator, line[offset..]) orelse return error.InvalidDockerfile;
            if (draft.command) |previous| freeArguments(allocator, previous);
            draft.command = value;
        } else if (std.ascii.eqlIgnoreCase(instruction, "STOPSIGNAL")) {
            if (draft.base == null) return error.InvalidDockerfile;
            const value = try nextWord(line, &offset) orelse return error.InvalidDockerfile;
            if (try nextWord(line, &offset) != null or config.stopSignalNumber(value) == null) return error.InvalidDockerfile;
            const owned = try allocator.dupe(u8, value);
            if (draft.stop_signal) |previous| allocator.free(previous);
            draft.stop_signal = owned;
        } else {
            return error.UnsupportedDockerfileInstruction;
        }
    }
    if (draft.base == null) return error.InvalidDockerfile;
    try finishStage(allocator, &stages, &draft, instructions.items.len);
    const owned_context_path = try allocator.dupe(u8, context_path);
    errdefer allocator.free(owned_context_path);
    const owned_stages = try stages.toOwnedSlice(allocator);
    errdefer {
        for (owned_stages) |stage| deinitStage(allocator, stage);
        allocator.free(owned_stages);
    }
    const owned_instructions = try instructions.toOwnedSlice(allocator);
    return .{
        .context_path = owned_context_path,
        .stages = owned_stages,
        .instructions = owned_instructions,
    };
}

fn finishStage(allocator: std.mem.Allocator, stages: *std.ArrayList(Stage), draft: *StageDraft, instruction_end: usize) !void {
    const base: StageBase = switch (draft.base.?) {
        .image => |value| .{ .image = try allocator.dupe(u8, value) },
        .stage => |index| .{ .stage = index },
    };
    errdefer switch (base) {
        .image => |value| allocator.free(value),
        .stage => {},
    };
    const name = if (draft.name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (name) |value| allocator.free(value);
    const config_value = try duplicateBuildConfig(allocator, draft.buildConfig());
    errdefer deinitBuildConfig(allocator, config_value);
    try stages.append(allocator, .{
        .base = base,
        .name = name,
        .instruction_start = draft.instruction_start,
        .instruction_count = instruction_end - draft.instruction_start,
        .config = config_value,
    });
    draft.deinit(allocator);
}

fn deinitStage(allocator: std.mem.Allocator, stage: Stage) void {
    switch (stage.base) {
        .image => |value| allocator.free(value),
        .stage => {},
    }
    if (stage.name) |value| allocator.free(value);
    deinitBuildConfig(allocator, stage.config);
}

fn duplicateBuildConfig(allocator: std.mem.Allocator, source: BuildConfig) !BuildConfig {
    var environment = try allocator.alloc([]const u8, source.env.len);
    var copied: usize = 0;
    errdefer {
        for (environment[0..copied]) |entry| allocator.free(entry);
        allocator.free(environment);
    }
    for (source.env) |entry| {
        environment[copied] = try allocator.dupe(u8, entry);
        copied += 1;
    }
    const user = if (source.user) |value| try allocator.dupe(u8, value) else null;
    errdefer if (user) |value| allocator.free(value);
    const working_dir = if (source.working_dir) |value| try allocator.dupe(u8, value) else null;
    errdefer if (working_dir) |value| allocator.free(value);
    const entrypoint = if (source.entrypoint) |value| try duplicateArguments(allocator, value) else null;
    errdefer if (entrypoint) |value| freeArguments(allocator, value);
    const cmd = if (source.cmd) |value| try duplicateArguments(allocator, value) else null;
    errdefer if (cmd) |value| freeArguments(allocator, value);
    const stop_signal = if (source.stop_signal) |value| try allocator.dupe(u8, value) else null;
    errdefer if (stop_signal) |value| allocator.free(value);
    return .{ .env = environment, .user = user, .working_dir = working_dir, .entrypoint = entrypoint, .cmd = cmd, .stop_signal = stop_signal };
}

fn findStage(stages: []const Stage, name: []const u8, allow_index: bool) ?usize {
    if (allow_index) {
        const index = std.fmt.parseInt(usize, name, 10) catch null;
        if (index) |value| if (value < stages.len) return value;
    }
    for (stages, 0..) |stage, index| {
        if (stage.name) |stage_name| if (std.ascii.eqlIgnoreCase(stage_name, name)) return index;
    }
    return null;
}

fn validStageName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '.' and character != '-') return false;
    }
    return true;
}

fn lowerStageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*character| character.* = std.ascii.toLower(character.*);
    return result;
}

fn duplicateArguments(allocator: std.mem.Allocator, arguments: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, arguments.len);
    var copied: usize = 0;
    errdefer {
        for (result[0..copied]) |argument| allocator.free(argument);
        allocator.free(result);
    }
    for (arguments) |argument| {
        result[copied] = try allocator.dupe(u8, argument);
        copied += 1;
    }
    return result;
}

fn deinitBuildConfig(allocator: std.mem.Allocator, value: BuildConfig) void {
    for (value.env) |entry| allocator.free(entry);
    allocator.free(value.env);
    if (value.user) |entry| allocator.free(entry);
    if (value.working_dir) |entry| allocator.free(entry);
    if (value.entrypoint) |entry| freeArguments(allocator, entry);
    if (value.cmd) |entry| freeArguments(allocator, entry);
    if (value.stop_signal) |entry| allocator.free(entry);
}

fn deinitRun(allocator: std.mem.Allocator, run: Run) void {
    freeArguments(allocator, run.command);
    deinitBuildConfig(allocator, run.config);
}

fn deinitInstruction(allocator: std.mem.Allocator, instruction: Instruction) void {
    switch (instruction) {
        .copy => |copy| {
            allocator.free(copy.source);
            allocator.free(copy.target);
        },
        .run => |run| deinitRun(allocator, run),
    }
}

fn duplicateRunConfig(
    allocator: std.mem.Allocator,
    environment: []const []const u8,
    user: ?[]const u8,
    working_dir: ?[]const u8,
) !BuildConfig {
    const env = try allocator.alloc([]const u8, environment.len);
    var copied: usize = 0;
    errdefer {
        for (env[0..copied]) |entry| allocator.free(entry);
        allocator.free(env);
    }
    for (environment) |entry| {
        env[copied] = try allocator.dupe(u8, entry);
        copied += 1;
    }
    const owned_user = if (user) |entry| try allocator.dupe(u8, entry) else null;
    errdefer if (owned_user) |entry| allocator.free(entry);
    const owned_working_dir = if (working_dir) |entry| try allocator.dupe(u8, entry) else null;
    errdefer if (owned_working_dir) |entry| allocator.free(entry);
    return .{ .env = env, .user = owned_user, .working_dir = owned_working_dir };
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
    base_manifest_digests: []const ?[]const u8,
    store: storage.BlobStore,
) !Result {
    if (base_manifest_digests.len != plan.stages.len) return error.InvalidBuildPlan;
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const stage_digests = try scratch.alloc([]const u8, plan.stages.len);
    var copied_bytes: u64 = 0;
    var final_result: ?Result = null;
    for (plan.stages, 0..) |build_stage, index| {
        const base_digest = switch (build_stage.base) {
            .image => base_manifest_digests[index] orelse return error.BaseImageNotFound,
            .stage => |base_index| if (base_index < index) stage_digests[base_index] else return error.InvalidBuildPlan,
        };
        const stage_dir_name = try std.fmt.allocPrint(scratch, "stage-{d}", .{index});
        try stage.createDir(io, stage_dir_name, .fromMode(0o700));
        var stage_dir = try stage.openDir(io, stage_dir_name, .{ .iterate = true, .follow_symlinks = false });
        defer stage_dir.close(io);
        const start = build_stage.instruction_start;
        const end = start + build_stage.instruction_count;
        if (end > plan.instructions.len) return error.InvalidBuildPlan;
        final_result = try buildStage(scratch, io, data_dir, context, stage_dir, plan.instructions[start..end], build_stage, base_digest, stage_digests[0..index], store, &copied_bytes);
        stage_digests[index] = final_result.?.digest;
    }
    const result = final_result orelse return error.InvalidDockerfile;
    return .{ .digest = try allocator.dupe(u8, result.digest), .layer_count = result.layer_count };
}

fn buildStage(
    allocator: std.mem.Allocator,
    io: Io,
    data_dir: Io.Dir,
    context: Io.Dir,
    stage: Io.Dir,
    instructions: []const Instruction,
    build_stage: Stage,
    base_manifest_digest: []const u8,
    previous_stage_digests: []const []const u8,
    store: storage.BlobStore,
    copied_bytes: *u64,
) !Result {
    const base_body = try store.readVerifiedAlloc(allocator, base_manifest_digest, 4 * 1024 * 1024);
    const base_manifest = try manifest.parseManifest(allocator, base_body);
    const base_config_body = try store.readVerifiedAlloc(allocator, base_manifest.config.digest, 4 * 1024 * 1024);
    if (base_config_body.len != base_manifest.config.size) return error.InvalidImageConfig;
    const base_image_config = try config.parse(allocator, base_config_body, base_manifest.layers.len);
    const base_process = base_image_config.config orelse config.Process{};

    var layers: std.ArrayList(manifest.Descriptor) = .empty;
    try layers.appendSlice(allocator, base_manifest.layers);
    var current_config: []const u8 = base_config_body;
    var current_manifest_digest = base_manifest_digest;
    var pending_copies: std.ArrayList(Copy) = .empty;
    defer pending_copies.deinit(allocator);
    var copy_batch: usize = 0;
    var run_index: usize = 0;
    var guest_dir: ?Io.Dir = null;
    defer if (guest_dir) |dir| dir.close(io);
    var kernel: ?Io.File = null;
    defer if (kernel) |file| file.close(io);
    var base_initramfs: ?Io.File = null;
    defer if (base_initramfs) |file| file.close(io);
    var guest_dir_path: ?[]u8 = null;
    defer if (guest_dir_path) |path| allocator.free(path);

    for (instructions) |instruction| switch (instruction) {
        .copy => |copy| {
            if (copy.from_stage) |from_index| {
                try flushCopyBatch(allocator, io, stage, context, &pending_copies, &copy_batch, &layers, &current_config, &current_manifest_digest, store, copied_bytes);
                if (from_index >= previous_stage_digests.len) return error.InvalidBuildPlan;
                const layer = try createStageCopyLayer(allocator, io, stage, previous_stage_digests[from_index], copy, copy_batch, store, copied_bytes);
                copy_batch += 1;
                try layers.append(allocator, layer);
                current_config = try appendDiffId(allocator, current_config, layer.digest, .{});
                current_manifest_digest = (try storeManifest(allocator, store, layers.items, current_config)).digest;
            } else {
                try pending_copies.append(allocator, copy);
            }
        },
        .run => |run| {
            try flushCopyBatch(allocator, io, stage, context, &pending_copies, &copy_batch, &layers, &current_config, &current_manifest_digest, store, copied_bytes);
            if (guest_dir == null) {
                try boot_assets.ensure(allocator, io, data_dir);
                guest_dir = try data_dir.openDir(io, "guest", .{ .follow_symlinks = false });
                kernel = try guest_dir.?.openFile(io, "Image", .{ .mode = .read_only, .follow_symlinks = false });
                base_initramfs = try guest_dir.?.openFile(io, "initramfs-virt", .{ .mode = .read_only, .follow_symlinks = false });
                if (!(try boot_assets.matchesSha256(io, kernel.?, boot_assets.kernel_sha256)) or
                    !(try boot_assets.matchesSha256(io, base_initramfs.?, boot_assets.initramfs_sha256))) return error.GuestAssetsCorrupt;
                var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
                const path_len = try guest_dir.?.realPath(io, &path_buffer);
                guest_dir_path = try allocator.dupe(u8, path_buffer[0..path_len]);
            }
            const snapshot = try runBuildInstruction(allocator, io, stage, store, current_manifest_digest, run, base_process, run_index, guest_dir_path.?);
            run_index += 1;
            layers.clearRetainingCapacity();
            try layers.append(allocator, snapshot);
            current_config = try replaceDiffIds(allocator, current_config, snapshot.digest);
            current_manifest_digest = (try storeManifest(allocator, store, layers.items, current_config)).digest;
        },
    };
    try flushCopyBatch(allocator, io, stage, context, &pending_copies, &copy_batch, &layers, &current_config, &current_manifest_digest, store, copied_bytes);

    const output_config = try applyBuildConfig(allocator, current_config, build_stage.config);
    const output_manifest = try storeManifest(allocator, store, layers.items, output_config);
    return .{ .digest = output_manifest.digest, .layer_count = layers.items.len };
}

fn flushCopyBatch(
    allocator: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    context: Io.Dir,
    pending: *std.ArrayList(Copy),
    batch: *usize,
    layers: *std.ArrayList(manifest.Descriptor),
    current_config: *[]const u8,
    current_manifest_digest: *[]const u8,
    store: storage.BlobStore,
    copied_bytes: *u64,
) !void {
    if (pending.items.len == 0) return;
    const layer = try createCopyLayer(allocator, io, stage, context, pending.items, batch.*, store, copied_bytes);
    batch.* += 1;
    try layers.append(allocator, layer);
    current_config.* = try appendDiffId(allocator, current_config.*, layer.digest, .{});
    current_manifest_digest.* = (try storeManifest(allocator, store, layers.items, current_config.*)).digest;
    pending.clearRetainingCapacity();
}

fn createStageCopyLayer(
    allocator: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    source_manifest_digest: []const u8,
    copy: Copy,
    index: usize,
    store: storage.BlobStore,
    copied_bytes: *u64,
) !manifest.Descriptor {
    const directory_name = try std.fmt.allocPrint(allocator, "from-{d}", .{index});
    defer allocator.free(directory_name);
    try stage.createDir(io, directory_name, .fromMode(0o700));
    var from_stage = try stage.openDir(io, directory_name, .{ .iterate = true, .follow_symlinks = false });
    defer from_stage.close(io);
    try from_stage.createDir(io, "rootfs", .fromMode(0o700));
    try from_stage.createDir(io, "control", .fromMode(0o700));
    var source_root = try from_stage.openDir(io, "rootfs", .{ .iterate = true, .follow_symlinks = false });
    defer source_root.close(io);
    var control = try from_stage.openDir(io, "control", .{ .iterate = true, .follow_symlinks = false });
    defer control.close(io);
    try rootfs.assemble(allocator, io, source_root, control, store, source_manifest_digest);
    return createCopyLayer(allocator, io, from_stage, source_root, &.{copy}, 0, store, copied_bytes);
}

fn createCopyLayer(
    allocator: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    context: Io.Dir,
    copies: []const Copy,
    batch: usize,
    store: storage.BlobStore,
    copied_bytes: *u64,
) !manifest.Descriptor {
    const directory_name = try std.fmt.allocPrint(allocator, "copy-{d}", .{batch});
    defer allocator.free(directory_name);
    try stage.createDir(io, directory_name, .fromMode(0o700));
    var copy_stage = try stage.openDir(io, directory_name, .{ .iterate = true, .follow_symlinks = false });
    defer copy_stage.close(io);
    try copy_stage.createDir(io, "layer", .fromMode(0o700));
    var layer_root = try copy_stage.openDir(io, "layer", .{ .iterate = true, .follow_symlinks = false });
    defer layer_root.close(io);
    var archive_paths = try copy_stage.createFile(io, "archive-paths.nul", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer archive_paths.close(io);
    var archive_paths_buffer: [32 * 1024]u8 = undefined;
    var archive_paths_writer = archive_paths.writerStreaming(io, &archive_paths_buffer);
    var accounting: BuildAccounting = .{};
    var directory_metadata: std.ArrayList(DirectoryMetadata) = .empty;
    defer {
        for (directory_metadata.items) |entry| allocator.free(entry.path);
        directory_metadata.deinit(allocator);
    }
    for (copies) |copy| try copySource(allocator, io, context, layer_root, copy, &archive_paths_writer.interface, &accounting, &directory_metadata);
    try archive_paths_writer.interface.flush();
    try applyDirectoryMetadata(io, layer_root, directory_metadata.items);
    if (copied_bytes.* > 32 * 1024 * 1024 * 1024 or accounting.input_bytes > 32 * 1024 * 1024 * 1024 - copied_bytes.*) return error.ImageLayersTooLarge;
    copied_bytes.* += accounting.input_bytes;

    var stage_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const stage_path_len = try copy_stage.realPath(io, &stage_path_buffer);
    const stage_path = stage_path_buffer[0..stage_path_len];
    const layer_path = try std.fmt.allocPrint(allocator, "{s}/layer", .{stage_path});
    defer allocator.free(layer_path);
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/layer.tar", .{stage_path});
    defer allocator.free(archive_path);
    const path_list_path = try std.fmt.allocPrint(allocator, "{s}/archive-paths.nul", .{stage_path});
    defer allocator.free(path_list_path);
    try createLayerArchive(allocator, io, archive_path, layer_path, path_list_path);
    const archive_info = try copy_stage.statFile(io, "layer.tar", .{ .follow_symlinks = false });
    if (archive_info.kind != .file or archive_info.size > build_layer_limit) return error.BuildLayerTooLarge;
    const digest = try hashFile(allocator, io, copy_stage, "layer.tar", archive_info.size);
    const layer_file = try copy_stage.openFile(io, "layer.tar", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer layer_file.close(io);
    var layer_reader_buffer: [32 * 1024]u8 = undefined;
    var layer_reader = layer_file.reader(io, &layer_reader_buffer);
    try store.writeVerified(digest, archive_info.size, &layer_reader.interface);
    return .{ .mediaType = "application/vnd.oci.image.layer.v1.tar", .digest = digest, .size = archive_info.size };
}

fn runBuildInstruction(
    allocator: std.mem.Allocator,
    io: Io,
    stage: Io.Dir,
    store: storage.BlobStore,
    manifest_digest: []const u8,
    run: Run,
    base_process: config.Process,
    index: usize,
    guest_dir_path: []const u8,
) !manifest.Descriptor {
    const directory_name = try std.fmt.allocPrint(allocator, "build-{d}", .{index});
    defer allocator.free(directory_name);
    try stage.createDir(io, directory_name, .fromMode(0o700));
    var run_stage = try stage.openDir(io, directory_name, .{ .iterate = true, .follow_symlinks = false });
    defer run_stage.close(io);
    try run_stage.createDir(io, "rootfs", .fromMode(0o700));
    try run_stage.createDir(io, "control", .fromMode(0o700));
    var image_root = try run_stage.openDir(io, "rootfs", .{ .iterate = true, .follow_symlinks = false });
    defer image_root.close(io);
    var control = try run_stage.openDir(io, "control", .{ .iterate = true, .follow_symlinks = false });
    defer control.close(io);
    try control.createDir(io, "exec", .fromMode(0o700));
    try rootfs.assemble(allocator, io, image_root, control, store, manifest_digest);

    const environment = try buildEnvironment(allocator, base_process.Env orelse &.{}, run.config.env);
    const working_dir = run.config.working_dir orelse base_process.WorkingDir orelse "/";
    const user = run.config.user orelse base_process.User orelse "";
    const initramfs_asset_path = try std.fmt.allocPrint(allocator, "{s}/initramfs-virt", .{guest_dir_path});
    defer allocator.free(initramfs_asset_path);
    const initramfs_asset = try Io.Dir.openFileAbsolute(io, initramfs_asset_path, .{ .mode = .read_only, .follow_symlinks = false });
    defer initramfs_asset.close(io);
    try guest.writeInitramfs(allocator, io, initramfs_asset, run_stage, run.command, environment, working_dir, user, 15, &.{}, false, true, false, false, true);

    var root_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var control_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var stage_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_path_buffer[0..try image_root.realPath(io, &root_path_buffer)];
    const control_path = control_path_buffer[0..try control.realPath(io, &control_path_buffer)];
    const run_path = stage_path_buffer[0..try run_stage.realPath(io, &stage_path_buffer)];
    const kernel_path = try std.fmt.allocPrint(allocator, "{s}/Image", .{guest_dir_path});
    defer allocator.free(kernel_path);
    const initramfs_path = try std.fmt.allocPrint(allocator, "{s}/initramfs", .{run_path});
    defer allocator.free(initramfs_path);
    try vm.run(allocator, kernel_path, initramfs_path, "console=hvc0 quiet loglevel=0 rdinit=/rift-init", root_path, control_path, null, null, &.{}, true, null, false, vm.default_cpu_count, vm.default_memory_bytes, 0, 2);
    const exit_file = try control.openFile(io, "exit", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer exit_file.close(io);
    const exit_size = (try exit_file.stat(io)).size;
    if (exit_size == 0 or exit_size > 4) return error.GuestStatusInvalid;
    var exit_buffer: [4]u8 = undefined;
    var exit_reader_buffer: [16]u8 = undefined;
    var exit_reader = exit_file.reader(io, &exit_reader_buffer);
    try exit_reader.interface.readSliceAll(exit_buffer[0..@intCast(exit_size)]);
    const exit_code = std.fmt.parseInt(u16, std.mem.trim(u8, exit_buffer[0..@intCast(exit_size)], "\r\n"), 10) catch return error.GuestStatusInvalid;
    if (exit_code != 0) return error.BuildRunFailed;

    const snapshot_info = try control.statFile(io, "snapshot.tar", .{ .follow_symlinks = false });
    if (snapshot_info.kind != .file or snapshot_info.size == 0 or snapshot_info.size > build_layer_limit) return error.BuildLayerTooLarge;
    const validation_file = try control.openFile(io, "snapshot.tar", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer validation_file.close(io);
    try layer_ops.validateUncompressedTar(allocator, io, validation_file);
    const digest = try hashFile(allocator, io, control, "snapshot.tar", snapshot_info.size);
    const snapshot = try control.openFile(io, "snapshot.tar", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false });
    defer snapshot.close(io);
    var snapshot_reader_buffer: [32 * 1024]u8 = undefined;
    var snapshot_reader = snapshot.reader(io, &snapshot_reader_buffer);
    try store.writeVerified(digest, snapshot_info.size, &snapshot_reader.interface);
    return .{ .mediaType = "application/vnd.oci.image.layer.v1.tar", .digest = digest, .size = snapshot_info.size };
}

fn buildEnvironment(allocator: std.mem.Allocator, base: []const []const u8, overrides: []const []const u8) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    for (base) |entry| try values.append(allocator, entry);
    for (overrides) |entry| {
        const key = environmentKey(entry);
        var index: usize = 0;
        while (index < values.items.len) {
            if (std.mem.eql(u8, environmentKey(values.items[index]), key)) {
                _ = values.orderedRemove(index);
            } else {
                index += 1;
            }
        }
        try values.append(allocator, entry);
    }
    return values.toOwnedSlice(allocator);
}

fn storeManifest(allocator: std.mem.Allocator, store: storage.BlobStore, layers: []const manifest.Descriptor, config_body: []const u8) !manifest.Descriptor {
    const config_descriptor = try storeBytes(allocator, store, "application/vnd.oci.image.config.v1+json", config_body);
    const body = try std.json.Stringify.valueAlloc(allocator, manifest.Manifest{
        .schemaVersion = 2,
        .mediaType = "application/vnd.oci.image.manifest.v1+json",
        .config = config_descriptor,
        .layers = layers,
    }, .{});
    defer allocator.free(body);
    return storeBytes(allocator, store, "application/vnd.oci.image.manifest.v1+json", body);
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

const DiffIdUpdate = union(enum) { keep, append: []const u8, replace: []const u8 };

fn appendDiffId(allocator: std.mem.Allocator, body: []const u8, digest: []const u8, changes: BuildConfig) ![]u8 {
    return updateConfig(allocator, body, .{ .append = digest }, changes);
}

fn replaceDiffIds(allocator: std.mem.Allocator, body: []const u8, digest: []const u8) ![]u8 {
    return updateConfig(allocator, body, .{ .replace = digest }, .{});
}

fn applyBuildConfig(allocator: std.mem.Allocator, body: []const u8, changes: BuildConfig) ![]u8 {
    return updateConfig(allocator, body, .keep, changes);
}

fn updateConfig(allocator: std.mem.Allocator, body: []const u8, diff_update: DiffIdUpdate, changes: BuildConfig) ![]u8 {
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

    const root_fs = image.object.getPtr("rootfs") orelse return error.InvalidImageConfig;
    if (root_fs.* != .object) return error.InvalidImageConfig;
    if (diff_update != .keep) {
        const diff_ids = root_fs.object.getPtr("diff_ids") orelse return error.InvalidImageConfig;
        if (diff_ids.* != .array) return error.InvalidImageConfig;
        switch (diff_update) {
            .keep => unreachable,
            .append => |digest| try diff_ids.array.append(.{ .string = digest }),
            .replace => |digest| {
                var replacement = std.json.Array.init(allocator);
                try replacement.append(.{ .string = digest });
                diff_ids.* = .{ .array = replacement };
            },
        }
    }

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
    if (changes.stop_signal) |value| try image_config.object.put(allocator, "StopSignal", .{ .string = value });
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

fn normalizeStageSource(source: []const u8) []const u8 {
    const start: usize = if (std.mem.startsWith(u8, source, "/")) 1 else if (std.mem.startsWith(u8, source, "./")) 2 else 0;
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
    try std.testing.expectEqual(@as(usize, 1), plan.stages.len);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:3.21", plan.stages[0].base.image);
    try std.testing.expectEqual(@as(usize, 2), plan.instructions.len);
    try std.testing.expectEqualStrings("hello world", plan.instructions[0].copy.source);
    try std.testing.expectEqualStrings("/app/hello", plan.instructions[0].copy.target);
    try std.testing.expectEqualStrings("folder", plan.instructions[1].copy.source);
    try std.testing.expectEqualStrings("/opt/app", plan.instructions[1].copy.target);
    try std.testing.expect(plan.instructions[1].copy.target_is_directory);
}

test "parses and owns common process config instructions" {
    var plan = try parseDockerfile(
        std.testing.allocator,
        "/tmp/context",
        "FROM alpine\nENV BUILD_MESSAGE=\"hello world\" BUILD_MODE=preview\nENV BUILD_MODE=local\nUSER 65534\nWORKDIR /tmp/rift-app/\nENTRYPOINT [\"/bin/sh\",\"-c\"]\nCMD [\"printf '%s:%s:%s\\\\n' \\\"$BUILD_MESSAGE\\\" \\\"$PWD\\\" \\\"$(id -u)\\\"\"]\nSTOPSIGNAL SIGUSR1\n",
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.instructions.len);
    try std.testing.expectEqualStrings("BUILD_MESSAGE=hello world", plan.stages[0].config.env[0]);
    try std.testing.expectEqualStrings("BUILD_MODE=local", plan.stages[0].config.env[1]);
    try std.testing.expectEqualStrings("65534", plan.stages[0].config.user.?);
    try std.testing.expectEqualStrings("/tmp/rift-app", plan.stages[0].config.working_dir.?);
    try std.testing.expectEqualStrings("/bin/sh", plan.stages[0].config.entrypoint.?[0]);
    try std.testing.expectEqualStrings("-c", plan.stages[0].config.entrypoint.?[1]);
    try std.testing.expectEqual(@as(usize, 1), plan.stages[0].config.cmd.?.len);
    try std.testing.expectEqualStrings("SIGUSR1", plan.stages[0].config.stop_signal.?);
}

test "parses named and indexed stage copies and inherited FROM stages" {
    const plan = try parseDockerfile(
        std.testing.allocator,
        "/tmp/context",
        "FROM alpine AS Build\nENV STAGE=builder\nCOPY file /tool\nFROM Build AS package\nCOPY --from=BUILD /tool /usr/bin/tool\nFROM package\nCOPY --from=1 /usr/bin/tool /tool\n",
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), plan.stages.len);
    try std.testing.expectEqualStrings("build", plan.stages[0].name.?);
    try std.testing.expectEqualStrings("STAGE=builder", plan.stages[0].config.env[0]);
    try std.testing.expectEqual(@as(usize, 0), plan.stages[1].base.stage);
    try std.testing.expectEqualStrings("package", plan.stages[1].name.?);
    try std.testing.expectEqual(@as(usize, 1), plan.stages[2].base.stage);
    try std.testing.expectEqual(@as(usize, 0), plan.instructions[1].copy.from_stage.?);
    try std.testing.expectEqualStrings("tool", plan.instructions[1].copy.source);
    try std.testing.expectEqual(@as(usize, 1), plan.instructions[2].copy.from_stage.?);
    try std.testing.expectEqualStrings("usr/bin/tool", plan.instructions[2].copy.source);
}

test "parses RUN commands in order with point-in-time process settings" {
    const plan = try parseDockerfile(
        std.testing.allocator,
        "/tmp/context",
        "FROM alpine\nENV MESSAGE=before\nUSER 1000\nWORKDIR /tmp/first\nRUN printf '%s' \"$MESSAGE\"\nENV MESSAGE=after\nWORKDIR /tmp/second\nRUN [\"/bin/echo\",\"json run\"]\n",
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.instructions.len);
    const shell_run = plan.instructions[0].run;
    try std.testing.expectEqual(@as(usize, 3), shell_run.command.len);
    try std.testing.expectEqualStrings("/bin/sh", shell_run.command[0]);
    try std.testing.expectEqualStrings("printf '%s' \"$MESSAGE\"", shell_run.command[2]);
    try std.testing.expectEqualStrings("MESSAGE=before", shell_run.config.env[0]);
    try std.testing.expectEqualStrings("1000", shell_run.config.user.?);
    try std.testing.expectEqualStrings("/tmp/first", shell_run.config.working_dir.?);
    const exec_run = plan.instructions[1].run;
    try std.testing.expectEqual(@as(usize, 2), exec_run.command.len);
    try std.testing.expectEqualStrings("/bin/echo", exec_run.command[0]);
    try std.testing.expectEqualStrings("json run", exec_run.command[1]);
    try std.testing.expectEqualStrings("MESSAGE=after", exec_run.config.env[0]);
    try std.testing.expectEqualStrings("/tmp/second", exec_run.config.working_dir.?);
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
        .stop_signal = "SIGUSR1",
    };
    const updated = try appendDiffId(arena.allocator(), body, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", changes);
    const image = try config.parse(arena.allocator(), updated, 1);
    const process = image.config.?;
    try std.testing.expectEqualStrings("65534", process.User.?);
    try std.testing.expectEqualStrings("/tmp/rift-app", process.WorkingDir.?);
    try std.testing.expectEqualStrings("/bin/sh", process.Entrypoint.?[0]);
    try std.testing.expectEqualStrings("printf ready", process.Cmd.?[0]);
    try std.testing.expectEqual(@as(?u8, 10), config.stopSignalNumber(process.StopSignal.?));
    try std.testing.expectEqual(@as(usize, 3), process.Env.?.len);
    try std.testing.expectEqualStrings("PATH=/bin", process.Env.?[0]);
    try std.testing.expectEqualStrings("BUILD_MODE=local", process.Env.?[1]);
    try std.testing.expectEqualStrings("BUILD_MESSAGE=hello", process.Env.?[2]);

    const dynamic = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), updated, .{});
    const config_value = dynamic.object.get("config").?.object;
    try std.testing.expectEqualStrings("kept", config_value.get("Labels").?.object.get("example").?.string);
}

test "rejects unsupported instructions, stages, and unsafe paths" {
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nRUN\n"));
    try std.testing.expectError(error.UnsupportedDockerfileInstruction, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nADD file /file\n"));
    try std.testing.expectError(error.UnknownBuildStage, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY --from=future /a /a\nFROM alpine AS future\n"));
    try std.testing.expectError(error.DuplicateBuildStage, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine AS build\nFROM alpine AS BUILD\n"));
    try std.testing.expectError(error.InvalidBuildSource, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine AS build\nFROM alpine\nCOPY --from=build ../../etc/passwd /passwd\n"));
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nSTOPSIGNAL SIGKILL\n"));
    try std.testing.expectError(error.InvalidBuildSource, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY ../secret /secret\n"));
    try std.testing.expectError(error.InvalidBuildTarget, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCOPY file /../../secret\n"));
    try std.testing.expectError(error.UnsupportedBuildWorkingDirectory, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nWORKDIR relative\n"));
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nENV broken\n"));
    try std.testing.expectError(error.InvalidDockerfile, parseDockerfile(std.testing.allocator, "/tmp", "FROM alpine\nCMD [1]\n"));
}
