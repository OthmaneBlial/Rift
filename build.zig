const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const guest_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl });
    const guest_exec = b.addExecutable(.{
        .name = "rift-guest-exec",
        .root_module = b.createModule(.{ .target = guest_target, .optimize = .ReleaseSmall, .link_libc = true }),
        .linkage = .static,
    });
    guest_exec.root_module.addCSourceFile(.{ .file = b.path("src/guest_exec.c"), .flags = &.{"-Os"} });
    const guest_files = b.addWriteFiles();
    _ = guest_files.addCopyFile(guest_exec.getEmittedBin(), "rift-guest-exec");
    const guest_module = b.createModule(.{
        .root_source_file = guest_files.add("guest_binary.zig", "pub const bytes = @embedFile(\"rift-guest-exec\");\n"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "rift",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("guest_binary", guest_module);
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);

    if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) {
        const sdk_path = std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\r\n");
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "include" }) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "lib" }) });
        exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }) });
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

        const check_detached = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_detached.addFileArg(b.path("scripts/check_detached.py"));
        check_detached.addArg(exe_path);
        check_detached.step.dependOn(&sign_exe.step);
        b.step("run-detached-check", "Start, inspect, stop, and remove a detached Alpine container").dependOn(&check_detached.step);

        const check_exec = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_exec.addFileArg(b.path("scripts/check_exec.py"));
        check_exec.addArg(exe_path);
        check_exec.step.dependOn(&sign_exe.step);
        b.step("run-exec-check", "Run commands inside an existing detached Alpine container").dependOn(&check_exec.step);

        const check_auto_pull = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_auto_pull.addFileArg(b.path("scripts/check_auto_pull.py"));
        check_auto_pull.addArg(exe_path);
        check_auto_pull.step.dependOn(&sign_exe.step);
        b.step("run-auto-pull-check", "Run Alpine from an empty HOME without a separate pull").dependOn(&check_auto_pull.step);

        const check_cache_lock = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_cache_lock.addFileArg(b.path("scripts/check_cache_lock.py"));
        check_cache_lock.addArg(exe_path);
        check_cache_lock.step.dependOn(&sign_exe.step);
        b.step("cache-lock-check", "Check cross-process image cache locking").dependOn(&check_cache_lock.step);

        const check_cache_prune = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_cache_prune.addFileArg(b.path("scripts/check_cache_prune.py"));
        check_cache_prune.addArg(exe_path);
        check_cache_prune.step.dependOn(&sign_exe.step);
        b.step("cache-prune-check", "Preview and reclaim unreferenced cached blobs").dependOn(&check_cache_prune.step);

        const check_process = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_process.addFileArg(b.path("scripts/check_process.py"));
        check_process.addArg(exe_path);
        check_process.step.dependOn(&sign_exe.step);
        b.step("run-process-check", "Apply OCI working directory and user settings").dependOn(&check_process.step);

        const check_volume = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_volume.addFileArg(b.path("scripts/check_volume.py"));
        check_volume.addArg(exe_path);
        check_volume.step.dependOn(&sign_exe.step);
        b.step("run-volume-check", "Check explicit read-only and writable file and directory volumes").dependOn(&check_volume.step);

        const check_registry_auth = b.addSystemCommand(&.{"/usr/bin/python3"});
        check_registry_auth.addFileArg(b.path("scripts/check_registry_auth.py"));
        check_registry_auth.addArg(exe_path);
        check_registry_auth.step.dependOn(&sign_exe.step);
        b.step("registry-auth-check", "Check a private Bearer-authenticated pull against a local registry fixture").dependOn(&check_registry_auth.step);

        const benchmark = b.addSystemCommand(&.{"/usr/bin/python3"});
        benchmark.addFileArg(b.path("scripts/benchmark.py"));
        benchmark.addArg(exe_path);
        benchmark.step.dependOn(&sign_exe.step);
        b.step("benchmark", "Measure the signed Rift binary with cached Alpine").dependOn(&benchmark.step);

        const probe = b.addExecutable(.{
            .name = "rift-vm-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/vm_probe.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        probe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "include" }) });
        probe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "lib" }) });
        probe.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }) });
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
