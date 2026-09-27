const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "rift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Rift").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);

    if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) {
        const probe = b.addExecutable(.{
            .name = "rift-vm-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vm_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        probe.root_module.addCSourceFile(.{
            .file = b.path("src/vm/bridge.m"),
            .language = .objective_c,
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        probe.root_module.linkFramework("Foundation", .{});
        probe.root_module.linkFramework("Virtualization", .{});
        probe.root_module.linkSystemLibrary("objc", .{});

        const install_probe = b.addInstallArtifact(probe, .{});
        const probe_path = b.getInstallPath(.bin, "rift-vm-probe");
        const sign = b.addSystemCommand(&.{ "/usr/bin/codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("src/vm/entitlements.plist"));
        sign.addArg(probe_path);
        sign.step.dependOn(&install_probe.step);

        const run_probe = b.addSystemCommand(&.{probe_path});
        run_probe.step.dependOn(&sign.step);
        if (b.args) |args| run_probe.addArgs(args);
        b.step("vm-probe", "Boot a local Linux guest for development").dependOn(&run_probe.step);

        const check_vm = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_vm.addFileArg(b.path("scripts/check_vm.py"));
        check_vm.addArgs(&.{
            probe_path,
            b.pathFromRoot(".zig-cache/guest/Image"),
            b.pathFromRoot(".zig-cache/guest/initramfs-virt"),
        });
        check_vm.step.dependOn(&sign.step);
        b.step("vm-check", "Boot Alpine, run a guest command, and shut down").dependOn(&check_vm.step);
    }
}
