const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const guest = @import("guest.zig");
const reference = @import("oci/reference.zig");
const rootfs = @import("oci/rootfs.zig");
const storage = @import("storage.zig");
const vm = @import("vm.zig");

const kernel_sha256 = "e698a107e4d04117db1a7b0daee99bdae5f0647fba2af50f3cd020a666950ab9";
const initramfs_sha256 = "5b9de8ff7b4f3055f6cf940e1ff869790415cf81b7ea1e399ee60448bc1a2c4d";

pub fn execute(init: std.process.Init, arguments: []const []const u8) !u8 {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    const offset: usize = if (arguments.len > 0 and std.mem.eql(u8, arguments[0], "--rm")) 1 else 0;
    if (arguments.len < offset + 2) return error.InvalidArguments;
    const allocator = init.arena.allocator();
    var image = try reference.parse(allocator, arguments[offset]);
    defer image.deinit(allocator);
    const canonical = try image.formatAlloc(allocator);

    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    try home_dir.createDirPath(init.io, "Library/Application Support/Rift");
    var data_dir = try home_dir.openDir(init.io, "Library/Application Support/Rift", .{});
    defer data_dir.close(init.io);
    var store = try storage.BlobStore.init(init.io, data_dir);
    defer store.deinit();
    const records = try store.listImages(allocator);
    defer storage.deinitImageRecords(allocator, records);
    const manifest_digest = for (records) |record| {
        if (std.mem.eql(u8, record.reference, canonical)) break record.digest;
    } else return error.ImageNotFound;

    var guest_dir = data_dir.openDir(init.io, "guest", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.GuestAssetsMissing,
        else => return err,
    };
    defer guest_dir.close(init.io);
    const kernel = guest_dir.openFile(init.io, "Image", .{ .mode = .read_only, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.GuestAssetsMissing,
        else => return err,
    };
    defer kernel.close(init.io);
    const base_initramfs = guest_dir.openFile(init.io, "initramfs-virt", .{ .mode = .read_only, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.GuestAssetsMissing,
        else => return err,
    };
    defer base_initramfs.close(init.io);
    if (!(try matchesSha256(init.io, kernel, kernel_sha256)) or
        !(try matchesSha256(init.io, base_initramfs, initramfs_sha256))) return error.GuestAssetsCorrupt;

    try data_dir.createDirPath(init.io, "runtime");
    var runtime = try data_dir.openDir(init.io, "runtime", .{});
    defer runtime.close(init.io);
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(allocator, "run-{s}", .{hex});
    try runtime.createDir(init.io, name, .fromMode(0o700));
    defer runtime.deleteTree(init.io, name) catch {};
    var run_dir = try runtime.openDir(init.io, name, .{});
    defer run_dir.close(init.io);
    try run_dir.createDir(init.io, "rootfs", .default_dir);
    try run_dir.createDir(init.io, "control", .default_dir);
    var image_root = try run_dir.openDir(init.io, "rootfs", .{});
    defer image_root.close(init.io);
    var control = try run_dir.openDir(init.io, "control", .{});
    defer control.close(init.io);
    try rootfs.assemble(allocator, init.io, image_root, store, manifest_digest);
    try guest.writeInitramfs(allocator, init.io, base_initramfs, run_dir, arguments[offset + 1 ..]);

    var root_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var control_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var guest_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var run_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_path_buffer[0..try image_root.realPath(init.io, &root_path_buffer)];
    const control_path = control_path_buffer[0..try control.realPath(init.io, &control_path_buffer)];
    const guest_path = guest_path_buffer[0..try guest_dir.realPath(init.io, &guest_path_buffer)];
    const run_path = run_path_buffer[0..try run_dir.realPath(init.io, &run_path_buffer)];
    const kernel_path = try std.fmt.allocPrint(allocator, "{s}/Image", .{guest_path});
    const initramfs_path = try std.fmt.allocPrint(allocator, "{s}/initramfs", .{run_path});

    try vm.run(allocator, kernel_path, initramfs_path, "console=hvc0 quiet loglevel=0 rdinit=/rift-init", root_path, control_path, 0, 1);
    const status_file = control.openFile(init.io, "exit", .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.GuestStatusMissing,
        else => return err,
    };
    defer status_file.close(init.io);
    const status_size = (try status_file.stat(init.io)).size;
    if (status_size == 0 or status_size > 4) return error.GuestStatusInvalid;
    var status_reader_buffer: [16]u8 = undefined;
    var status_buffer: [4]u8 = undefined;
    var status_reader = status_file.reader(init.io, &status_reader_buffer);
    try status_reader.interface.readSliceAll(status_buffer[0..@intCast(status_size)]);
    const code = std.fmt.parseInt(u16, std.mem.trim(u8, status_buffer[0..@intCast(status_size)], "\r\n"), 10) catch return error.GuestStatusInvalid;
    if (code > 255) return error.GuestStatusInvalid;
    return @intCast(code);
}

fn matchesSha256(io: Io, file: Io.File, expected: []const u8) !bool {
    var input_buffer: [32 * 1024]u8 = undefined;
    var chunk: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &input_buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hash.update(chunk[0..count]);
    }
    const actual = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.mem.eql(u8, &actual, expected);
}
