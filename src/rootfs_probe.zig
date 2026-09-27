const std = @import("std");
const rootfs = @import("oci/rootfs.zig");
const storage = @import("storage.zig");

pub fn main(init: std.process.Init) void {
    check(init) catch |err| {
        std.debug.print("rift-rootfs-probe: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn check(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    var data_dir = try std.Io.Dir.openDirAbsolute(init.io, args[1], .{ .follow_symlinks = false });
    defer data_dir.close(init.io);
    var store = try storage.BlobStore.init(init.io, data_dir);
    defer store.deinit();

    var random: [8]u8 = undefined;
    init.io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const directory = try std.fmt.allocPrint(allocator, ".zig-cache/layer-smoke-{s}", .{hex});
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    defer std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    var root = try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer root.close(init.io);

    try rootfs.assemble(allocator, init.io, root, store, args[2]);
    const busybox = try root.statFile(init.io, "bin/busybox", .{ .follow_symlinks = false });
    if (busybox.kind != .file or busybox.size < 1000) return error.InvalidAlpineRoot;
    var link_buffer: [256]u8 = undefined;
    const link_length = try root.readLink(init.io, "bin/echo", &link_buffer);
    if (!std.mem.eql(u8, link_buffer[0..link_length], "/bin/busybox")) return error.InvalidAlpineRoot;
    std.debug.print("Alpine root filesystem smoke passed: busybox {d} bytes, bin/echo link\n", .{busybox.size});
}
