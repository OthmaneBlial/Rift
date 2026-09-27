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

fn scanCategory(io: Io, root: Io.Dir, name: []const u8) !Usage {
    var dir = root.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);
    return scanDir(io, dir, 0);
}

fn scanDir(io: Io, dir: Io.Dir, depth: usize) anyerror!Usage {
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
