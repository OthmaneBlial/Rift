const std = @import("std");
const Io = std.Io;

pub const Usage = struct {
    bytes: u64 = 0,
    files: u64 = 0,

    fn add(self: *Usage, other: Usage) !void {
        self.bytes = std.math.add(u64, self.bytes, other.bytes) catch return error.StoreTooLarge;
        self.files = std.math.add(u64, self.files, other.files) catch return error.StoreTooLarge;
    }
};

pub const Report = struct {
    blobs: Usage = .{},
    images: Usage = .{},
    guest: Usage = .{},
    containers: Usage = .{},
    runtime: Usage = .{},

    pub fn print(report: Report, writer: *Io.Writer) !void {
        try writer.writeAll("CATEGORY\tBYTES\tFILES\n");
        try row(writer, "Image blobs", report.blobs);
        try row(writer, "Image records", report.images);
        try row(writer, "Guest boot", report.guest);
        try row(writer, "Container state and logs", report.containers);
        try row(writer, "Runtime staging", report.runtime);
        var total: Usage = .{};
        for ([_]Usage{ report.blobs, report.images, report.guest, report.containers, report.runtime }) |usage| try total.add(usage);
        try row(writer, "TOTAL", total);
        try writer.writeAll("Logical file bytes; filesystem allocation and compression may differ.\n");
    }
};

fn row(writer: *Io.Writer, label: []const u8, usage: Usage) !void {
    try writer.print("{s}\t{d}\t{d}\n", .{ label, usage.bytes, usage.files });
}

pub fn scan(io: Io, root: Io.Dir) !Report {
    return .{
        .blobs = try scanCategory(io, root, "blobs"),
        .images = try scanCategory(io, root, "images"),
        .guest = try scanCategory(io, root, "guest"),
        .containers = try scanCategory(io, root, "containers"),
        .runtime = try scanCategory(io, root, "runtime"),
    };
}

/// Only stale staging with a released Rift lock is eligible. Cache pruning runs separately.
pub fn clean(allocator: std.mem.Allocator, io: Io, root: Io.Dir, confirmed: bool, writer: *Io.Writer) !void {
    var runtime = root.openDir(io, "runtime", .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return writer.writeAll("No stale runtime staging found.\n"),
        else => return err,
    };
    defer runtime.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var entries = runtime.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .directory and validRunName(entry.name)) try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    var total: Usage = .{};
    var count: usize = 0;
    for (names.items) |name| {
        var state = runtime.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer state.close(io);
        const lock_info = state.statFile(io, "active.lock", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (lock_info.kind != .file) continue;
        const lock = try state.openFile(io, "active.lock", .{ .mode = .read_write, .follow_symlinks = false });
        defer lock.close(io);
        if (!(try lock.tryLock(io, .shared))) continue;
        defer lock.unlock(io);

        const usage = try scanDir(io, state, 0);
        try writer.print("{s}: {d} logical bytes in {d} files\n", .{ name, usage.bytes, usage.files });
        if (confirmed) try runtime.deleteTree(io, name);
        try total.add(usage);
        count += 1;
    }
    if (count == 0) return writer.writeAll("No stale runtime staging found.\n");
    if (confirmed) {
        try writer.print("Removed {d} stale staging directories ({d} logical bytes).\n", .{ count, total.bytes });
    } else {
        try writer.print("Would remove {d} stale staging directories ({d} logical bytes). Run 'rift clean --yes' to confirm.\n", .{ count, total.bytes });
    }
}

fn validRunName(name: []const u8) bool {
    if (name.len != 36 or !std.mem.startsWith(u8, name, "run-")) return false;
    for (name[4..]) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn scanCategory(io: Io, root: Io.Dir, name: []const u8) !Usage {
    var dir = root.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);
    return scanDir(io, dir, 0);
}

fn scanDir(io: Io, dir: Io.Dir, depth: usize) anyerror!Usage {
    // ponytail: A 128-level cap keeps this scan simple; use an iterative walk if real stores exceed it.
    if (depth > 128) return error.StoreTooDeep;
    var usage: Usage = .{};
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .directory) {
            var child = dir.openDir(io, entry.name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer child.close(io);
            try usage.add(try scanDir(io, child, depth + 1));
        } else {
            const file = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (file.kind == .directory) continue;
            try usage.add(.{ .bytes = file.size, .files = 1 });
        }
    }
    return usage;
}

test "disk report counts only Rift categories without following links" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try temp.dir.createDirPath(io, "blobs/sha256");
    try temp.dir.writeFile(io, .{ .sub_path = "blobs/sha256/a", .data = "blob" });
    try temp.dir.createDir(io, "images", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "images/a.rift", .data = "ref" });
    try temp.dir.createDir(io, "runtime", .default_dir);
    try temp.dir.symLink(io, "../blobs", "runtime/link", .{});
    const report = try scan(io, temp.dir);
    try std.testing.expectEqual(@as(u64, 4), report.blobs.bytes);
    try std.testing.expectEqual(@as(u64, 3), report.images.bytes);
    try std.testing.expectEqual(@as(u64, 1), report.runtime.files);
    try std.testing.expectEqual(@as(u64, 0), report.guest.bytes);
}

test "cleanup previews stale staging and leaves running or unknown directories" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    const stale = "run-0123456789abcdef0123456789abcdef";
    const active = "run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try temp.dir.createDirPath(io, "runtime/run-0123456789abcdef0123456789abcdef");
    try temp.dir.createDir(io, "runtime/run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .default_dir);
    try temp.dir.createDir(io, "runtime/other", .default_dir);
    var stale_dir = try temp.dir.openDir(io, "runtime/run-0123456789abcdef0123456789abcdef", .{});
    defer stale_dir.close(io);
    const stale_lock = try stale_dir.createFile(io, "active.lock", .{});
    stale_lock.close(io);
    try stale_dir.writeFile(io, .{ .sub_path = "leftover", .data = "data" });
    var active_dir = try temp.dir.openDir(io, "runtime/run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .{});
    defer active_dir.close(io);
    const active_lock = try active_dir.createFile(io, "active.lock", .{ .lock = .exclusive });
    defer active_lock.close(io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try clean(std.testing.allocator, io, temp.dir, false, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Would remove 1 stale staging") != null);
    try std.testing.expect((try temp.dir.statFile(io, "runtime/run-0123456789abcdef0123456789abcdef/leftover", .{})).size == 4);
    try clean(std.testing.allocator, io, temp.dir, true, &output.writer);
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(io, "runtime/run-0123456789abcdef0123456789abcdef", .{}));
    try std.testing.expect((try temp.dir.statFile(io, "runtime/run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .{})).kind == .directory);
    try std.testing.expect((try temp.dir.statFile(io, "runtime/other", .{})).kind == .directory);
    try std.testing.expect(validRunName(stale) and validRunName(active));
}
