const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const version = "0.1.2";

const manifest = @import("oci/manifest.zig");
const reference = @import("oci/reference.zig");
const storage = @import("storage.zig");
const registry = @import("oci/registry.zig");
const runtime = @import("run.zig");
const containers = @import("containers.zig");
const disk = @import("disk.zig");
const image_build = @import("oci/image_build.zig");

fn printHelp(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        "Rift — Ridiculously lightweight containers for macOS\n\n" ++
            "Usage: rift <command> [arguments]\n\n" ++
            "Commands:\n" ++
            "  help, --help       Show this help\n" ++
            "  version, --version Show version\n" ++
            "  system info        Show host information\n" ++
            "  system df          Show Rift storage usage\n" ++
            "  clean [--yes]      Preview or remove stale staging and unused image blobs\n" ++
            "  images             List locally pulled images\n" ++
            "  pull <image>       Pull an OCI image for this host\n" ++
            "  build -t IMAGE [context] Build a Dockerfile (one FROM; regular-file COPY)\n" ++
            "  rmi <image>        Remove a local image reference\n" ++
            "  run [options] <image> [command] [args...] Run in the foreground\n" ++
            "  run -d [options] <image> [command] [args...] Run detached\n" ++
            "    Options: --rm (foreground only), -p HOST:GUEST, -w DIR,\n" ++
            "             -e KEY=VALUE, -v HOST:TARGET[:ro|rw]\n" ++
            "  ps                 List detached containers\n" ++
            "  inspect <id>       Show detached container details\n" ++
            "  logs <id>          Show a detached container's output\n" ++
            "  exec [-it] <id> <cmd> Run a command in a running container (-i stdin, -t TTY)\n" ++
            "  stop <id>          Stop a detached container\n" ++
            "  kill <id>          Force-kill a detached container\n" ++
            "  rm <id>            Remove a stopped container\n",
    );
}

fn dispatch(args: []const []const u8, writer: *Io.Writer, init: ?std.process.Init) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        if (args.len > 1) return error.InvalidArguments;
        try printHelp(writer);
        return 0;
    }

    if (std.mem.eql(u8, args[0], "version") or std.mem.eql(u8, args[0], "--version")) {
        if (args.len != 1) return error.InvalidArguments;
        try writer.print("Rift {s}\n", .{version});
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "system")) {
        if (args.len != 2) return error.InvalidArguments;
        if (std.mem.eql(u8, args[1], "info")) {
            try writer.print(
                "Rift {s}\nHost OS: {s}\nHost architecture: {s}\n",
                .{ version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
            );
            return 0;
        }
        if (std.mem.eql(u8, args[1], "df")) {
            try reportDisk(init orelse return error.CommandUnavailable, writer);
            return 0;
        }
        return error.InvalidArguments;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "clean")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--yes"))) return error.InvalidArguments;
        try cleanDisk(init orelse return error.CommandUnavailable, args.len == 2, writer);
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "pull")) {
        if (args.len != 2) return error.InvalidArguments;
        try pullImage(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "build")) {
        const options = try parseBuildArguments(args[1..]);
        try buildImage(init orelse return error.CommandUnavailable, options, writer);
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "images")) {
        if (args.len != 1) return error.InvalidArguments;
        try listImages(init orelse return error.CommandUnavailable, writer);
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "rmi")) {
        if (args.len != 2) return error.InvalidArguments;
        try removeImage(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "run")) {
        const process = init orelse return error.CommandUnavailable;
        const detached = args.len > 1 and std.mem.eql(u8, args[1], "-d");
        const run_args = if (detached) args[2..] else args[1..];
        try ensurePulled(process, run_args, detached);
        if (detached) {
            try containers.spawn(process, run_args, writer);
            return 0;
        }
        return runtime.execute(process, run_args, null, null, null);
    }

    if (args.len > 0 and std.mem.eql(u8, args[0], "ps")) {
        if (args.len != 1) return error.InvalidArguments;
        try containers.list(init orelse return error.CommandUnavailable, writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "inspect")) {
        if (args.len != 2) return error.InvalidArguments;
        try containers.inspect(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "logs")) {
        if (args.len != 2) return error.InvalidArguments;
        try containers.logs(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "exec")) {
        const options = try parseExecOptions(args[1..]);
        return containers.exec(
            init orelse return error.CommandUnavailable,
            args[1 + options.id_index],
            args[2 + options.id_index ..],
            writer,
            options.interactive,
            options.tty,
        );
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "stop")) {
        if (args.len != 2) return error.InvalidArguments;
        try containers.stop(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "kill")) {
        if (args.len != 2) return error.InvalidArguments;
        try containers.kill(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "rm")) {
        if (args.len != 2) return error.InvalidArguments;
        try containers.remove(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "_worker")) {
        if (args.len < 2) return error.InvalidArguments;
        return containers.worker(init orelse return error.CommandUnavailable, args[1], args[2..]);
    }

    return error.UnknownCommand;
}

const ExecOptions = struct { id_index: usize, interactive: bool, tty: bool };

fn parseExecOptions(arguments: []const []const u8) !ExecOptions {
    var id_index: usize = 0;
    var interactive = false;
    var tty = false;
    while (id_index < arguments.len and arguments[id_index].len > 1 and arguments[id_index][0] == '-') : (id_index += 1) {
        for (arguments[id_index][1..]) |flag| switch (flag) {
            'i' => {
                if (interactive) return error.InvalidArguments;
                interactive = true;
            },
            't' => {
                if (tty) return error.InvalidArguments;
                tty = true;
            },
            else => return error.InvalidArguments,
        };
    }
    if (tty and !interactive) return error.InvalidArguments;
    if (arguments.len < id_index + 2) return error.InvalidArguments;
    return .{ .id_index = id_index, .interactive = interactive, .tty = tty };
}

fn pullImage(init: std.process.Init, image_name: []const u8, writer: *Io.Writer) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedHost;
    const target = switch (builtin.cpu.arch) {
        .aarch64 => manifest.Target{ .os = "linux", .architecture = "arm64", .variant = "v8" },
        .x86_64 => manifest.Target{ .os = "linux", .architecture = "amd64" },
        else => return error.UnsupportedHostArchitecture,
    };
    var store = try openImageStore(init);
    defer store.deinit();
    try store.lockExclusive();
    defer store.unlock();
    var image = try reference.parse(init.arena.allocator(), image_name);
    defer image.deinit(init.arena.allocator());
    var client = registry.Registry.init(
        init.arena.allocator(),
        init.io,
        image.registry,
        image.repository,
        init.environ_map.get("RIFT_REGISTRY_USERNAME"),
        init.environ_map.get("RIFT_REGISTRY_PASSWORD"),
    );
    defer client.deinit();

    const result = try client.pull(image, store, target);
    const canonical_reference = try image.formatAlloc(init.arena.allocator());
    const platform = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ target.os, target.architecture });
    try store.recordImage(init.arena.allocator(), .{
        .reference = canonical_reference,
        .digest = result.digest,
        .platform = platform,
        .layer_count = result.layer_count,
    });
    try writer.print("Pulled {s} for {s}/{s}: {s} ({d} layers)\n", .{
        image_name,
        target.os,
        target.architecture,
        result.digest,
        result.layer_count,
    });
}

fn ensurePulled(init: std.process.Init, arguments: []const []const u8, detached: bool) !void {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    const options = try runtime.parseOptions(init.arena.allocator(), arguments);
    if (detached and options.remove_after_exit) return error.DetachedAutoRemoveUnsupported;
    _ = try runtime.resolveVolumes(init, options.volumes);
    const image_name = arguments[options.image_index];
    try ensureImagePulled(init, image_name);
}

fn ensureImagePulled(init: std.process.Init, image_name: []const u8) !void {
    const allocator = init.arena.allocator();
    var image = try reference.parse(allocator, image_name);
    defer image.deinit(allocator);
    const canonical = try image.formatAlloc(allocator);
    var store = try openImageStore(init);
    defer store.deinit();
    const cached = blk: {
        try store.lockShared();
        defer store.unlock();
        const records = try store.listImages(allocator);
        defer storage.deinitImageRecords(allocator, records);
        for (records) |record| {
            if (std.mem.eql(u8, record.reference, canonical)) break :blk true;
        }
        break :blk false;
    };
    if (cached) return;

    std.debug.print("rift: pulling {s} (not cached)\n", .{image_name});
    var buffer: [512]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    try pullImage(init, image_name, &stderr.interface);
    try stderr.interface.flush();
}

const BuildArguments = struct { tag: []const u8, context: []const u8 };

fn parseBuildArguments(arguments: []const []const u8) !BuildArguments {
    var tag: ?[]const u8 = null;
    var context: ?[]const u8 = null;
    var offset: usize = 0;
    while (offset < arguments.len) {
        if (std.mem.eql(u8, arguments[offset], "-t") or std.mem.eql(u8, arguments[offset], "--tag")) {
            if (tag != null or offset + 1 >= arguments.len or arguments[offset + 1].len == 0) return error.InvalidBuildArguments;
            tag = arguments[offset + 1];
            offset += 2;
        } else if (arguments[offset].len > 0 and arguments[offset][0] == '-') {
            return error.InvalidBuildArguments;
        } else {
            if (context != null) return error.InvalidBuildArguments;
            context = arguments[offset];
            offset += 1;
        }
    }
    return .{ .tag = tag orelse return error.InvalidBuildArguments, .context = context orelse "." };
}

fn buildImage(init: std.process.Init, options: BuildArguments, writer: *Io.Writer) !void {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
    const allocator = init.arena.allocator();
    const plan = try image_build.readPlan(allocator, init.io, options.context);
    var output_image = reference.parse(allocator, options.tag) catch return error.InvalidBuildTag;
    defer output_image.deinit(allocator);
    if (output_image.digest != null) return error.InvalidBuildTag;
    const canonical_output = try output_image.formatAlloc(allocator);

    try ensureImagePulled(init, plan.base_reference);
    var data_dir = (try openDataDir(init)) orelse return error.BaseImageNotFound;
    defer data_dir.close(init.io);
    var store = try storage.BlobStore.init(init.io, data_dir);
    defer store.deinit();
    try store.lockExclusive();
    defer store.unlock();
    const records = try store.listImages(allocator);
    defer storage.deinitImageRecords(allocator, records);
    const base_digest = for (records) |record| {
        if (!std.mem.eql(u8, record.reference, plan.base_reference)) continue;
        if (!std.mem.eql(u8, record.platform, "linux/arm64")) return error.UnsupportedHostArchitecture;
        break record.digest;
    } else return error.BaseImageNotFound;

    const result = try image_build.build(allocator, init.io, data_dir, plan, base_digest, store);
    try store.recordImage(allocator, .{
        .reference = canonical_output,
        .digest = result.digest,
        .platform = "linux/arm64",
        .layer_count = result.layer_count,
    });
    try writer.print("Built {s}: {s} ({d} layers)\n", .{ canonical_output, result.digest, result.layer_count });
}

fn listImages(init: std.process.Init, writer: *Io.Writer) !void {
    var store = try openImageStore(init);
    defer store.deinit();
    try store.lockShared();
    defer store.unlock();
    const allocator = init.arena.allocator();
    const records = try store.listImages(allocator);
    defer storage.deinitImageRecords(allocator, records);
    if (records.len == 0) return writer.writeAll("No images pulled yet.\n");
    for (records) |record| {
        try writer.print("{s}  {s}  {s} ({d} layers)\n", .{
            record.reference,
            record.platform,
            record.digest,
            record.layer_count,
        });
    }
}

fn removeImage(init: std.process.Init, image_name: []const u8, writer: *Io.Writer) !void {
    const allocator = init.arena.allocator();
    var image = try reference.parse(allocator, image_name);
    defer image.deinit(allocator);
    const canonical = try image.formatAlloc(allocator);
    var store = try openImageStore(init);
    defer store.deinit();
    try store.lockExclusive();
    defer store.unlock();
    try store.removeImage(allocator, canonical);
    try writer.print("Removed local image reference {s}. Run 'rift clean' to preview unused blobs.\n", .{canonical});
}

fn openImageStore(init: std.process.Init) !storage.BlobStore {
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    try home_dir.createDirPath(init.io, "Library/Application Support/Rift");
    var data_dir = try home_dir.openDir(init.io, "Library/Application Support/Rift", .{ .follow_symlinks = false });
    defer data_dir.close(init.io);
    return storage.BlobStore.init(init.io, data_dir);
}

fn reportDisk(init: std.process.Init, writer: *Io.Writer) !void {
    var data_dir = (try openDataDir(init)) orelse return (disk.Report{}).print(writer);
    defer data_dir.close(init.io);
    try (try disk.scan(init.io, data_dir)).print(writer);
}

fn cleanDisk(init: std.process.Init, confirmed: bool, writer: *Io.Writer) !void {
    var data_dir = (try openDataDir(init)) orelse return writer.writeAll("No stale runtime staging found.\n");
    defer data_dir.close(init.io);
    const allocator = init.arena.allocator();
    try disk.clean(allocator, init.io, data_dir, confirmed, writer);
    var store = try storage.BlobStore.init(init.io, data_dir);
    defer store.deinit();
    try store.lockExclusive();
    defer store.unlock();
    const plan = try store.planPrune(allocator);
    defer plan.deinit(allocator);
    if (plan.candidates.len == 0) return writer.writeAll("No unreferenced image blobs found.\n");
    if (confirmed) {
        try store.applyPrune(plan);
        try writer.print("Removed {d} unreferenced image blobs ({d} logical bytes).\n", .{ plan.candidates.len, plan.bytes });
    } else {
        for (plan.candidates) |candidate| {
            try writer.print("blobs/sha256/{s}: {d} logical bytes\n", .{ candidate.filename, candidate.bytes });
        }
        try writer.print("Would remove {d} unreferenced image blobs ({d} logical bytes). Run 'rift clean --yes' to confirm.\n", .{ plan.candidates.len, plan.bytes });
    }
}

fn openDataDir(init: std.process.Init) !?Io.Dir {
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    return home_dir.openDir(init.io, "Library/Application Support/Rift", .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn main(init: std.process.Init) void {
    const allocator = init.arena.allocator();
    const argv = init.minimal.args.toSlice(allocator) catch {
        std.debug.print("rift: could not read command-line arguments\n", .{});
        std.process.exit(1);
    };
    const args = if (argv.len == 0) argv else argv[1..];

    var buffer: [512]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const exit_code = dispatch(args, &stdout.interface, init) catch |err| {
        stdout.interface.flush() catch {};
        switch (err) {
            error.InvalidArguments => std.debug.print("rift: invalid arguments; run 'rift --help'\n", .{}),
            error.CommandUnavailable => std.debug.print("rift: command '{s}' is not available in this context\n", .{if (args.len == 0) "" else args[0]}),
            error.UnknownCommand => std.debug.print("rift: unknown command '{s}'; run 'rift --help'\n", .{args[0]}),
            error.UnsupportedHost => std.debug.print("rift: this command requires a supported Mac\n", .{}),
            error.UnsupportedHostArchitecture => std.debug.print("rift: OCI pulls currently support Apple Silicon and Intel Macs\n", .{}),
            error.HomeDirectoryUnavailable => std.debug.print("rift: HOME is not set\n", .{}),
            error.InvalidReference => std.debug.print("rift: invalid OCI image reference\n", .{}),
            error.ImageNotFound => std.debug.print("rift: image reference was not found\n", .{}),
            error.RegistryUnauthorized, error.RegistryForbidden => std.debug.print("rift: registry rejected credentials or denied pull access\n", .{}),
            error.NoMatchingPlatform => std.debug.print("rift: image has no manifest for this Mac's Linux architecture\n", .{}),
            error.UnsupportedRegistryAuth => std.debug.print("rift: registry uses an unsupported authentication challenge\n", .{}),
            error.TokenRequestFailed, error.InvalidTokenResponse => std.debug.print("rift: registry authentication failed\n", .{}),
            error.IncompleteRegistryCredentials => std.debug.print("rift: set both RIFT_REGISTRY_USERNAME and RIFT_REGISTRY_PASSWORD\n", .{}),
            error.InvalidRegistryCredentials => std.debug.print("rift: registry credentials are malformed\n", .{}),
            error.InsecureTokenRealm, error.InsecureRegistryRedirect => std.debug.print("rift: registry requested an insecure URL\n", .{}),
            error.InvalidManifest, error.MissingManifestMediaType, error.UnsupportedManifestMediaType => std.debug.print("rift: registry returned an invalid or unsupported image manifest\n", .{}),
            error.BlobDigestMismatch => std.debug.print("rift: downloaded blob failed SHA-256 verification\n", .{}),
            error.BlobSizeMismatch => std.debug.print("rift: downloaded blob size did not match its descriptor\n", .{}),
            error.ImageDownloadTooLarge => std.debug.print("rift: image pull exceeds the 16 GiB uncached download limit\n", .{}),
            error.LayerTooLarge => std.debug.print("rift: OCI layer exceeds the 8 GiB decompressed limit\n", .{}),
            error.LayerOwnershipIndexTooComplex => std.debug.print("rift: OCI layer has too many ownership updates to process safely\n", .{}),
            error.OwnershipManifestTooLarge => std.debug.print("rift: OCI image ownership metadata exceeds the 64 MiB limit\n", .{}),
            error.UnsupportedDigestAlgorithm => std.debug.print("rift: image uses an unsupported digest algorithm\n", .{}),
            error.InvalidImageMetadata => std.debug.print("rift: local image metadata is corrupt\n", .{}),
            error.CorruptCachedBlob => std.debug.print("rift: cached image blob failed verification\n", .{}),
            error.ImageLayersTooLarge => std.debug.print("rift: image exceeds the 32 GiB decompressed layer limit\n", .{}),
            error.UnsupportedLayerSpecialFile => std.debug.print("rift: image contains a special file outside /dev that Rift does not support yet\n", .{}),
            error.GuestAssetsMissing => std.debug.print("rift: guest boot files are missing\n", .{}),
            error.GuestAssetsCorrupt => std.debug.print("rift: guest assets failed SHA-256 verification\n", .{}),
            error.GuestDownloadFailed => std.debug.print("rift: could not download the pinned Alpine guest ISO\n", .{}),
            error.GuestArchiveTooLarge => std.debug.print("rift: Alpine guest ISO exceeded the download limit\n", .{}),
            error.InsecureGuestRedirect => std.debug.print("rift: Alpine guest ISO redirect was not HTTPS\n", .{}),
            error.GuestArchiveDigestMismatch => std.debug.print("rift: Alpine guest ISO failed SHA-256 verification\n", .{}),
            error.GuestArchiveInvalid, error.UnsupportedGuestKernel => std.debug.print("rift: Alpine guest ISO has unsupported boot files\n", .{}),
            error.GuestStatusMissing, error.GuestStatusInvalid => std.debug.print("rift: guest did not report a valid exit status\n", .{}),
            error.HostPortUnavailable => std.debug.print("rift: requested localhost port is unavailable\n", .{}),
            error.InvalidContainerId => std.debug.print("rift: invalid container ID\n", .{}),
            error.ContainerNotFound => std.debug.print("rift: container not found\n", .{}),
            error.ContainerNotRunning => std.debug.print("rift: container is not running\n", .{}),
            error.ContainerExecRunning => std.debug.print("rift: wait for the active exec command before removing this container\n", .{}),
            error.ContainerRunning => std.debug.print("rift: stop the container before removing it\n", .{}),
            error.ContainerStopTimedOut => std.debug.print("rift: timed out waiting for the container to terminate\n", .{}),
            error.ExecAgentNotReady => std.debug.print("rift: container did not start its exec agent in time\n", .{}),
            error.ExecRequestTooLarge => std.debug.print("rift: exec request exceeds 64 KiB\n", .{}),
            error.InvalidExecStatus, error.ExecOutputMissing, error.ExecOutputTruncated, error.InvalidExecState => std.debug.print("rift: container returned an invalid exec response\n", .{}),
            error.DetachedAutoRemoveUnsupported => std.debug.print("rift: --rm is not available with detached runs yet\n", .{}),
            error.InvalidImageConfig => std.debug.print("rift: image configuration is invalid or mismatches its layers\n", .{}),
            error.ImageHasNoCommand => std.debug.print("rift: image has no default command; specify one after the image\n", .{}),
            error.UnsupportedWorkingDirectory => std.debug.print("rift: image working directory must be an absolute path\n", .{}),
            error.InvalidVolumeSpecification => std.debug.print("rift: volume must use absolute HOST:TARGET[:ro|rw] paths without . or .. components\n", .{}),
            error.ReservedVolumeTarget => std.debug.print("rift: volume target cannot be /dev or /proc\n", .{}),
            error.DuplicateVolumeTarget => std.debug.print("rift: each volume target must be unique\n", .{}),
            error.InvalidVolumeSource => std.debug.print("rift: volume source must be an existing directory or regular file, not a symlink\n", .{}),
            error.FileVolumeMustShareFilesystem => std.debug.print("rift: file volume must be on the same filesystem as Rift runtime storage\n", .{}),
            error.FileVolumeCannotContainTarget => std.debug.print("rift: a file volume target cannot contain another volume target\n", .{}),
            error.TooManyVolumes => std.debug.print("rift: at most 16 volumes are supported\n", .{}),
            error.InvalidBuildArguments, error.InvalidBuildTag => std.debug.print("rift: build syntax is 'rift build -t IMAGE [context]'\n", .{}),
            error.InvalidBuildContext => std.debug.print("rift: build context must contain a readable Dockerfile\n", .{}),
            error.InvalidDockerfile => std.debug.print("rift: invalid Dockerfile; expected FROM and one or more COPY instructions\n", .{}),
            error.UnsupportedDockerfileInstruction, error.UnsupportedBuildStages, error.UnsupportedCopyForm => std.debug.print("rift: this build preview supports one FROM and regular-file COPY instructions only\n", .{}),
            error.InvalidBuildSource => std.debug.print("rift: COPY source must be a regular file inside the build context\n", .{}),
            error.InvalidBuildTarget => std.debug.print("rift: COPY target must be an absolute file path without . or .. components\n", .{}),
            error.BuildLayerTooLarge => std.debug.print("rift: built image layer exceeds the 8 GiB limit\n", .{}),
            error.BuildArchiveFailed => std.debug.print("rift: could not create the OCI layer archive\n", .{}),
            error.BuildSourceChanged => std.debug.print("rift: a COPY source changed while it was being read\n", .{}),
            error.BuildStagingFailed => std.debug.print("rift: could not create private build staging\n", .{}),
            error.BaseImageNotFound => std.debug.print("rift: Dockerfile base image disappeared; pull it and retry the build\n", .{}),
            else => std.debug.print("rift: output failed: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(if (err == error.InvalidArguments or err == error.CommandUnavailable or err == error.UnknownCommand or
            err == error.InvalidVolumeSpecification or err == error.ReservedVolumeTarget or err == error.DuplicateVolumeTarget or
            err == error.InvalidVolumeSource or err == error.FileVolumeMustShareFilesystem or err == error.FileVolumeCannotContainTarget or err == error.TooManyVolumes or err == error.ExecRequestTooLarge or
            err == error.InvalidBuildArguments or err == error.InvalidBuildTag or err == error.InvalidBuildContext or err == error.InvalidDockerfile or
            err == error.UnsupportedDockerfileInstruction or err == error.UnsupportedBuildStages or err == error.UnsupportedCopyForm or err == error.InvalidBuildSource or err == error.InvalidBuildTarget) 2 else 1);
    };
    stdout.interface.flush() catch |err| {
        std.debug.print("rift: output failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

test "help is available without a command" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try dispatch(&.{}, &output.writer, null);
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "Rift — Ridiculously lightweight containers for macOS\n"));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "kill <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "inspect <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "exec [-it] <id> <cmd>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "--rm (foreground only)") != null);
}

test "exec parses stdin and TTY flags before the container ID" {
    const combined = try parseExecOptions(&.{ "-it", "0123456789abcdef0123456789abcdef", "/bin/sh" });
    try std.testing.expectEqual(@as(usize, 1), combined.id_index);
    try std.testing.expect(combined.interactive);
    try std.testing.expect(combined.tty);

    const separate = try parseExecOptions(&.{ "-i", "-t", "0123456789abcdef0123456789abcdef", "/bin/sh" });
    try std.testing.expect(separate.interactive and separate.tty);

    const plain = try parseExecOptions(&.{ "0123456789abcdef0123456789abcdef", "/bin/echo" });
    try std.testing.expect(!plain.interactive and !plain.tty);
    try std.testing.expectError(error.InvalidArguments, parseExecOptions(&.{ "-t", "0123456789abcdef0123456789abcdef", "/bin/sh" }));
    try std.testing.expectError(error.InvalidArguments, parseExecOptions(&.{ "-ii", "0123456789abcdef0123456789abcdef", "/bin/sh" }));
}

test "build accepts a tag and optional context in either order" {
    const default_context = try parseBuildArguments(&.{ "-t", "example:local" });
    try std.testing.expectEqualStrings("example:local", default_context.tag);
    try std.testing.expectEqualStrings(".", default_context.context);

    const explicit_context = try parseBuildArguments(&.{ "./app", "--tag", "example:local" });
    try std.testing.expectEqualStrings("example:local", explicit_context.tag);
    try std.testing.expectEqualStrings("./app", explicit_context.context);
}

test "build rejects missing, duplicate, or unknown arguments" {
    try std.testing.expectError(error.InvalidBuildArguments, parseBuildArguments(&.{}));
    try std.testing.expectError(error.InvalidBuildArguments, parseBuildArguments(&.{ "-t", "one", "-t", "two" }));
    try std.testing.expectError(error.InvalidBuildArguments, parseBuildArguments(&.{ "-f", "Dockerfile", "-t", "one" }));
    try std.testing.expectError(error.InvalidBuildArguments, parseBuildArguments(&.{ "-t", "one", "context-a", "context-b" }));
}

test "version prints the package version" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try dispatch(&.{"version"}, &output.writer, null);
    try std.testing.expectEqualStrings("Rift 0.1.2\n", output.written());
}

test "system info reports the compiled host target" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try dispatch(&.{ "system", "info" }, &output.writer, null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), @tagName(builtin.os.tag)) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), @tagName(builtin.cpu.arch)) != null);
}

test "unfinished commands are not advertised as available" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.CommandUnavailable, dispatch(&.{"run"}, &output.writer, null));
}

test "unknown commands are distinguished from invalid arguments" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.UnknownCommand, dispatch(&.{"staart"}, &output.writer, null));
}

test "known commands reject malformed argument counts" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{"system"}, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "system", "version" }, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "ps", "extra" }, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "logs", "id", "extra" }, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "stop", "id", "extra" }, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{"kill"}, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "rm", "id", "extra" }, &output.writer, null));
}

test "inspect requires a container ID" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{"inspect"}, &output.writer, null));
}

test "exec requires a container ID and command" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{"exec"}, &output.writer, null));
    try std.testing.expectError(error.InvalidArguments, dispatch(&.{ "exec", "0123456789abcdef0123456789abcdef" }, &output.writer, null));
}

test {
    _ = @import("oci/reference.zig");
    _ = @import("oci/manifest.zig");
    _ = @import("oci/registry.zig");
    _ = @import("oci/layers.zig");
    _ = @import("oci/rootfs.zig");
    _ = @import("oci/config.zig");
    _ = @import("oci/image_build.zig");
    _ = @import("guest.zig");
    _ = @import("boot_assets.zig");
    _ = @import("disk.zig");
    _ = @import("containers.zig");
    _ = @import("storage.zig");
}
