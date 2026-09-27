const std = @import("std");

const Share = extern struct { path: [*:0]const u8, read_only: c_int };

extern fn rift_vm_run(
    kernel: [*:0]const u8,
    initramfs: [*:0]const u8,
    command_line: [*:0]const u8,
    share_path: ?[*:0]const u8,
    control_path: ?[*:0]const u8,
    stop_path: ?[*:0]const u8,
    kill_path: ?[*:0]const u8,
    volumes: ?[*]const Share,
    volume_count: usize,
    network_enabled: c_int,
    host_port: c_int,
    guest_port: c_int,
    input_fd: c_int,
    output_fd: c_int,
) c_int;

pub const PortMapping = struct { host: u16, guest: u16 };
pub const Volume = struct { source: []const u8, target: []const u8, read_only: bool, is_file: bool = false };

pub fn run(
    allocator: std.mem.Allocator,
    kernel: []const u8,
    initramfs: []const u8,
    command_line: []const u8,
    share_path: ?[]const u8,
    control_path: ?[]const u8,
    stop_path: ?[]const u8,
    kill_path: ?[]const u8,
    volumes: []const Volume,
    network_enabled: bool,
    port: ?PortMapping,
    input_fd: c_int,
    output_fd: c_int,
) !void {
    if (volumes.len > 16) return error.TooManyVolumes;
    const kernel_z = try allocator.dupeZ(u8, kernel);
    defer allocator.free(kernel_z);
    const initramfs_z = try allocator.dupeZ(u8, initramfs);
    defer allocator.free(initramfs_z);
    const command_line_z = try allocator.dupeZ(u8, command_line);
    defer allocator.free(command_line_z);
    const share_path_z = if (share_path) |path| try allocator.dupeZ(u8, path) else null;
    defer if (share_path_z) |path| allocator.free(path);
    const control_path_z = if (control_path) |path| try allocator.dupeZ(u8, path) else null;
    defer if (control_path_z) |path| allocator.free(path);
    const stop_path_z = if (stop_path) |path| try allocator.dupeZ(u8, path) else null;
    defer if (stop_path_z) |path| allocator.free(path);
    const kill_path_z = if (kill_path) |path| try allocator.dupeZ(u8, path) else null;
    defer if (kill_path_z) |path| allocator.free(path);
    const volume_paths = try allocator.alloc([:0]u8, volumes.len);
    defer allocator.free(volume_paths);
    var converted: usize = 0;
    defer for (volume_paths[0..converted]) |path| allocator.free(path);
    const shares = try allocator.alloc(Share, volumes.len);
    defer allocator.free(shares);
    for (volumes, 0..) |volume, index| {
        volume_paths[index] = try allocator.dupeZ(u8, volume.source);
        converted += 1;
        shares[index] = .{ .path = volume_paths[index].ptr, .read_only = @intFromBool(volume.read_only) };
    }

    return switch (rift_vm_run(kernel_z.ptr, initramfs_z.ptr, command_line_z.ptr, if (share_path_z) |path| path.ptr else null, if (control_path_z) |path| path.ptr else null, if (stop_path_z) |path| path.ptr else null, if (kill_path_z) |path| path.ptr else null, if (shares.len == 0) null else shares.ptr, shares.len, @intFromBool(network_enabled), if (port) |mapping| mapping.host else 0, if (port) |mapping| mapping.guest else 0, input_fd, output_fd)) {
        0 => {},
        2 => error.VirtualizationUnavailable,
        3 => error.HostPortUnavailable,
        4 => error.ContainerStopped,
        5 => error.ContainerKilled,
        else => error.VirtualMachineFailed,
    };
}
