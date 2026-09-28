const std = @import("std");
const rootfs = @import("oci/rootfs.zig");
const storage = @import("storage.zig");
const vm = @import("vm.zig");

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const args = init.minimal.args.toSlice(allocator) catch {
        std.debug.print("rift-vm-probe: could not read arguments\n", .{});
        std.process.exit(1);
    };
    if (args.len == 5 and std.mem.eql(u8, args[3], "--oci")) {
        runOci(init, args[1], args[2], args[4]) catch |err| {
            std.debug.print("rift-vm-probe: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (args.len != 3 and args.len != 4) {
        std.debug.print("usage: rift-vm-probe <ARM64 Image> <initramfs> [read-only share | --network | --oci <pulled reference>]\n", .{});
        std.process.exit(2);
    }
    const network = args.len == 4 and std.mem.eql(u8, args[3], "--network");
    vm.run(allocator, args[1], args[2], "console=hvc0 rdinit=/usr/bin/sh", if (args.len == 4 and !network) args[3] else null, null, null, null, &.{}, network, null, false, vm.default_cpu_count, vm.default_memory_bytes, 0, 1) catch |err| {
        std.debug.print("rift-vm-probe: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn runOci(init: std.process.Init, kernel: []const u8, initramfs: []const u8, image: []const u8) !void {
    const allocator = init.arena.allocator();
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var data_dir = try storage.ensureDataDir(init.io, home);
    defer data_dir.close(init.io);
    var store = try storage.BlobStore.init(init.io, data_dir);
    defer store.deinit();
    const records = try store.listImages(allocator);
    defer storage.deinitImageRecords(allocator, records);
    const digest = for (records) |record| {
        if (std.mem.eql(u8, record.reference, image)) break record.digest;
    } else return error.ImageNotFound;

    var random: [8]u8 = undefined;
    init.io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const directory = try std.fmt.allocPrint(allocator, ".zig-cache/oci-vm-{s}", .{hex});
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    defer std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
    var run_dir = try std.Io.Dir.cwd().openDir(init.io, directory, .{});
    defer run_dir.close(init.io);
    try run_dir.createDir(init.io, "rootfs", .default_dir);
    try run_dir.createDir(init.io, "control", .default_dir);
    var root = try run_dir.openDir(init.io, "rootfs", .{});
    defer root.close(init.io);
    var control = try run_dir.openDir(init.io, "control", .{});
    defer control.close(init.io);
    try rootfs.assemble(allocator, init.io, root, control, store, digest);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_size = try root.realPath(init.io, &path_buffer);
    try vm.run(allocator, kernel, initramfs, "console=hvc0 rdinit=/usr/bin/sh", path_buffer[0..path_size], null, null, null, &.{}, false, null, false, vm.default_cpu_count, vm.default_memory_bytes, 0, 1);
}
