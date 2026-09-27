const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const version = "0.1.0";

const manifest = @import("oci/manifest.zig");
const reference = @import("oci/reference.zig");
const storage = @import("storage.zig");
const registry = @import("oci/registry.zig");
const runtime = @import("run.zig");
const containers = @import("containers.zig");
const disk = @import("disk.zig");

fn printHelp(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        "Rift — Ridiculously lightweight containers for macOS\n\n" ++
            "Usage: rift <command> [arguments]\n\n" ++
            "Commands:\n" ++
            "  help, --help       Show this help\n" ++
            "  version, --version Show version\n" ++
            "  system info        Show host information\n" ++
            "  system df          Show Rift storage usage\n" ++
            "  clean [--yes]      Preview or remove stale runtime staging\n" ++
            "  images             List locally pulled images\n" ++
            "  pull <image>       Pull an OCI image for this host\n" ++
            "  run [-d] [--rm] [-p HOST:GUEST] [-w DIR] <image> [command] [args...] Run an image\n" ++
            "  ps                 List detached containers\n" ++
            "  logs <id>          Show a detached container's output\n" ++
            "  stop <id>          Stop a detached container\n" ++
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

    if (args.len == 2 and std.mem.eql(u8, args[0], "system") and std.mem.eql(u8, args[1], "info")) {
        try writer.print(
            "Rift {s}\nHost OS: {s}\nHost architecture: {s}\n",
            .{ version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
        );
        return 0;
    }

    if (args.len == 2 and std.mem.eql(u8, args[0], "system") and std.mem.eql(u8, args[1], "df")) {
        try reportDisk(init orelse return error.CommandUnavailable, writer);
        return 0;
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

    if (args.len > 0 and std.mem.eql(u8, args[0], "images")) {
        if (args.len != 1) return error.InvalidArguments;
        try listImages(init orelse return error.CommandUnavailable, writer);
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
        return runtime.execute(process, run_args, null);
    }

    if (args.len == 1 and std.mem.eql(u8, args[0], "ps")) {
        try containers.list(init orelse return error.CommandUnavailable, writer);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "logs")) {
        try containers.logs(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "stop")) {
        try containers.stop(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "rm")) {
        try containers.remove(init orelse return error.CommandUnavailable, args[1], writer);
        return 0;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[0], "_worker")) {
        return containers.worker(init orelse return error.CommandUnavailable, args[1], args[2..]);
    }

    return error.CommandUnavailable;
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
    var image = try reference.parse(init.arena.allocator(), image_name);
    defer image.deinit(init.arena.allocator());
    var client = registry.Registry.init(init.arena.allocator(), init.io, image.registry, image.repository);
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
    const options = try runtime.parseOptions(arguments);
    if (detached and options.remove_after_exit) return error.DetachedAutoRemoveUnsupported;
    const allocator = init.arena.allocator();
    const image_name = arguments[options.image_index];
    var image = try reference.parse(allocator, image_name);
    defer image.deinit(allocator);
    const canonical = try image.formatAlloc(allocator);
    var store = try openImageStore(init);
    defer store.deinit();
    const records = try store.listImages(allocator);
    defer storage.deinitImageRecords(allocator, records);
    for (records) |record| {
        if (std.mem.eql(u8, record.reference, canonical)) return;
    }

    std.debug.print("rift: pulling {s} (not cached)\n", .{image_name});
    var buffer: [512]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    try pullImage(init, image_name, &stderr.interface);
    try stderr.interface.flush();
}

fn listImages(init: std.process.Init, writer: *Io.Writer) !void {
    var store = try openImageStore(init);
    defer store.deinit();
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

fn openImageStore(init: std.process.Init) !storage.BlobStore {
    const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
    var home_dir = try Io.Dir.openDirAbsolute(init.io, home, .{});
    defer home_dir.close(init.io);
    try home_dir.createDirPath(init.io, "Library/Application Support/Rift");
    var data_dir = try home_dir.openDir(init.io, "Library/Application Support/Rift", .{});
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
    try disk.clean(init.arena.allocator(), init.io, data_dir, confirmed, writer);
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
            error.CommandUnavailable => std.debug.print("rift: command '{s}' is not available yet; run 'rift --help'\n", .{if (args.len == 0) "" else args[0]}),
            error.UnsupportedHost => std.debug.print("rift: this command requires a supported Mac\n", .{}),
            error.UnsupportedHostArchitecture => std.debug.print("rift: OCI pulls currently support Apple Silicon and Intel Macs\n", .{}),
            error.HomeDirectoryUnavailable => std.debug.print("rift: HOME is not set\n", .{}),
            error.InvalidReference => std.debug.print("rift: invalid OCI image reference\n", .{}),
            error.ImageNotFound => std.debug.print("rift: image reference was not found\n", .{}),
            error.RegistryUnauthorized, error.RegistryForbidden => std.debug.print("rift: registry denied anonymous pull access\n", .{}),
            error.NoMatchingPlatform => std.debug.print("rift: image has no manifest for this Mac's Linux architecture\n", .{}),
            error.UnsupportedRegistryAuth => std.debug.print("rift: registry uses an unsupported authentication challenge\n", .{}),
            error.TokenRequestFailed, error.InvalidTokenResponse => std.debug.print("rift: registry authentication failed\n", .{}),
            error.InsecureTokenRealm, error.InsecureRegistryRedirect => std.debug.print("rift: registry requested an insecure URL\n", .{}),
            error.InvalidManifest, error.MissingManifestMediaType, error.UnsupportedManifestMediaType => std.debug.print("rift: registry returned an invalid or unsupported image manifest\n", .{}),
            error.BlobDigestMismatch => std.debug.print("rift: downloaded blob failed SHA-256 verification\n", .{}),
            error.BlobSizeMismatch => std.debug.print("rift: downloaded blob size did not match its descriptor\n", .{}),
            error.UnsupportedDigestAlgorithm => std.debug.print("rift: image uses an unsupported digest algorithm\n", .{}),
            error.InvalidImageMetadata => std.debug.print("rift: local image metadata is corrupt\n", .{}),
            error.CorruptCachedBlob => std.debug.print("rift: cached image blob failed verification\n", .{}),
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
            error.ContainerRunning => std.debug.print("rift: stop the container before removing it\n", .{}),
            error.ContainerStopTimedOut => std.debug.print("rift: timed out waiting for the container to stop\n", .{}),
            error.DetachedAutoRemoveUnsupported => std.debug.print("rift: --rm is not available with detached runs yet\n", .{}),
            error.InvalidImageConfig => std.debug.print("rift: image configuration is invalid or mismatches its layers\n", .{}),
            error.ImageHasNoCommand => std.debug.print("rift: image has no default command; specify one after the image\n", .{}),
            error.UnsupportedWorkingDirectory => std.debug.print("rift: image working directory must be an absolute path\n", .{}),
            else => std.debug.print("rift: output failed: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(if (err == error.InvalidArguments or err == error.CommandUnavailable) 2 else 1);
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
}

test "version prints the package version" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try dispatch(&.{"version"}, &output.writer, null);
    try std.testing.expectEqualStrings("Rift 0.1.0\n", output.written());
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

test {
    _ = @import("oci/reference.zig");
    _ = @import("oci/manifest.zig");
    _ = @import("oci/registry.zig");
    _ = @import("oci/layers.zig");
    _ = @import("oci/rootfs.zig");
    _ = @import("oci/config.zig");
    _ = @import("guest.zig");
    _ = @import("boot_assets.zig");
    _ = @import("disk.zig");
    _ = @import("containers.zig");
    _ = @import("storage.zig");
}
