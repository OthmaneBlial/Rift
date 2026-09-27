const std = @import("std");
const vm = @import("vm.zig");

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const args = init.minimal.args.toSlice(allocator) catch {
        std.debug.print("rift-vm-probe: could not read arguments\n", .{});
        std.process.exit(1);
    };
    if (args.len != 3) {
        std.debug.print("usage: rift-vm-probe <ARM64 Image> <initramfs>\n", .{});
        std.process.exit(2);
    }
    vm.run(allocator, args[1], args[2], "console=hvc0 rdinit=/usr/bin/sh", 0, 1) catch |err| {
        std.debug.print("rift-vm-probe: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
