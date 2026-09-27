const std = @import("std");

extern fn rift_vm_run(
    kernel: [*:0]const u8,
    initramfs: [*:0]const u8,
    command_line: [*:0]const u8,
    input_fd: c_int,
    output_fd: c_int,
) c_int;

pub fn run(
    allocator: std.mem.Allocator,
    kernel: []const u8,
    initramfs: []const u8,
    command_line: []const u8,
    input_fd: c_int,
    output_fd: c_int,
) !void {
    const kernel_z = try allocator.dupeZ(u8, kernel);
    defer allocator.free(kernel_z);
    const initramfs_z = try allocator.dupeZ(u8, initramfs);
    defer allocator.free(initramfs_z);
    const command_line_z = try allocator.dupeZ(u8, command_line);
    defer allocator.free(command_line_z);

    return switch (rift_vm_run(kernel_z.ptr, initramfs_z.ptr, command_line_z.ptr, input_fd, output_fd)) {
        0 => {},
        2 => error.VirtualizationUnavailable,
        else => error.VirtualMachineFailed,
    };
}
