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
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);

    if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) {
        exe.root_module.link_libc = true;
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/vm/bridge.m"),
            .language = .objective_c,
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/vm/forward.c") });
        exe.root_module.linkFramework("Foundation", .{});
        exe.root_module.linkFramework("Virtualization", .{});
        exe.root_module.linkSystemLibrary("objc", .{});
        const exe_path = b.getInstallPath(.bin, "rift");
        const sign_exe = b.addSystemCommand(&.{ "/usr/bin/codesign", "--force", "--sign", "-", "--entitlements" });
        sign_exe.addFileArg(b.path("src/vm/entitlements.plist"));
        sign_exe.addArg(exe_path);
        sign_exe.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign_exe.step);
        const run = b.addSystemCommand(&.{exe_path});
        run.step.dependOn(&sign_exe.step);
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run Rift").dependOn(&run.step);

        const check_run = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_run.addFileArg(b.path("scripts/check_run.py"));
        check_run.addArg(exe_path);
        check_run.step.dependOn(&sign_exe.step);
        b.step("run-check", "Run Alpine through the signed Rift CLI").dependOn(&check_run.step);

        const check_run_network = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_run_network.addFileArg(b.path("scripts/check_run.py"));
        check_run_network.addArgs(&.{ exe_path, "--network" });
        check_run_network.step.dependOn(&sign_exe.step);
        b.step("run-network-check", "Resolve DNS from a pulled Alpine container").dependOn(&check_run_network.step);

        const check_port = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_port.addFileArg(b.path("scripts/check_port.py"));
        check_port.addArg(exe_path);
        check_port.step.dependOn(&sign_exe.step);
        b.step("run-port-check", "Forward a localhost port to a pulled Alpine container").dependOn(&check_port.step);

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
        probe.root_module.addCSourceFile(.{ .file = b.path("src/vm/forward.c") });
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

        const check_share = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_share.addFileArg(b.path("scripts/check_vm.py"));
        check_share.addArgs(&.{
            probe_path,
            b.pathFromRoot(".zig-cache/guest/Image"),
            b.pathFromRoot(".zig-cache/guest/initramfs-virt"),
            b.pathFromRoot(".zig-cache/guest"),
        });
        check_share.step.dependOn(&sign.step);
        b.step("vm-share-check", "Mount a read-only host directory in Alpine").dependOn(&check_share.step);

        const check_network = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_network.addFileArg(b.path("scripts/check_vm.py"));
        check_network.addArgs(&.{
            probe_path,
            b.pathFromRoot(".zig-cache/guest/Image"),
            b.pathFromRoot(".zig-cache/guest/initramfs-virt"),
            "--network",
        });
        check_network.step.dependOn(&sign.step);
        b.step("vm-network-check", "Acquire an IPv4 address with guest DHCP").dependOn(&check_network.step);

        const check_oci = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_oci.addFileArg(b.path("scripts/check_vm.py"));
        check_oci.addArgs(&.{
            probe_path,
            b.pathFromRoot(".zig-cache/guest/Image"),
            b.pathFromRoot(".zig-cache/guest/initramfs-virt"),
            "--oci",
            "registry-1.docker.io/library/alpine:latest",
        });
        check_oci.step.dependOn(&sign.step);
        b.step("oci-vm-check", "Run pulled Alpine BusyBox inside a VM").dependOn(&check_oci.step);
    } else {
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run Rift").dependOn(&run.step);
    }
}
