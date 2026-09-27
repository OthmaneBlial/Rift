const std = @import("std");

extern fn rift_vm_run(
    kernel: [*:0]const u8,
    initramfs: [*:0]const u8,
    command_line: [*:0]const u8,
    share_path: ?[*:0]const u8,
    control_path: ?[*:0]const u8,
    network_enabled: c_int,
    input_fd: c_int,
    output_fd: c_int,
) c_int;

pub fn run(
    allocator: std.mem.Allocator,
    kernel: []const u8,
    initramfs: []const u8,
    command_line: []const u8,
    share_path: ?[]const u8,
    control_path: ?[]const u8,
    network_enabled: bool,
    input_fd: c_int,
    output_fd: c_int,
) !void {
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

    return switch (rift_vm_run(kernel_z.ptr, initramfs_z.ptr, command_line_z.ptr, if (share_path_z) |path| path.ptr else null, if (control_path_z) |path| path.ptr else null, @intFromBool(network_enabled), input_fd, output_fd)) {
        0 => {},
        2 => error.VirtualizationUnavailable,
        else => error.VirtualMachineFailed,
    };
}
