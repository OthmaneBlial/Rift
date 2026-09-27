const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const version = "0.1.0";

fn printHelp(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        "Rift — Ridiculously lightweight containers for macOS\n\n" ++
            "Usage: rift <command> [arguments]\n\n" ++
            "Commands:\n" ++
            "  help, --help       Show this help\n" ++
            "  version, --version Show version\n" ++
            "  system info        Show host information\n",
    );
}

fn dispatch(args: []const []const u8, writer: *Io.Writer) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        if (args.len > 1) return error.InvalidArguments;
        return printHelp(writer);
    }

    if (std.mem.eql(u8, args[0], "version") or std.mem.eql(u8, args[0], "--version")) {
        if (args.len != 1) return error.InvalidArguments;
        return writer.print("Rift {s}\n", .{version});
    }

    if (args.len == 2 and std.mem.eql(u8, args[0], "system") and std.mem.eql(u8, args[1], "info")) {
        return writer.print(
            "Rift {s}\nHost OS: {s}\nHost architecture: {s}\n",
            .{ version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
        );
    }

    return error.CommandUnavailable;
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
    dispatch(args, &stdout.interface) catch |err| {
        stdout.interface.flush() catch {};
        switch (err) {
            error.InvalidArguments => std.debug.print("rift: invalid arguments; run 'rift --help'\n", .{}),
            error.CommandUnavailable => std.debug.print("rift: command '{s}' is not available yet; run 'rift --help'\n", .{if (args.len == 0) "" else args[0]}),
            else => std.debug.print("rift: output failed: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(if (err == error.InvalidArguments or err == error.CommandUnavailable) 2 else 1);
    };
    stdout.interface.flush() catch |err| {
        std.debug.print("rift: output failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

test "help is available without a command" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try dispatch(&.{}, &output.writer);
    try std.testing.expect(std.mem.startsWith(u8, output.written(), "Rift — Ridiculously lightweight containers for macOS\n"));
}

test "version prints the package version" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try dispatch(&.{"version"}, &output.writer);
    try std.testing.expectEqualStrings("Rift 0.1.0\n", output.written());
}

test "system info reports the compiled host target" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try dispatch(&.{ "system", "info" }, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), @tagName(builtin.os.tag)) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), @tagName(builtin.cpu.arch)) != null);
}

test "unfinished commands are not advertised as available" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.CommandUnavailable, dispatch(&.{"run"}, &output.writer));
}

test {
    _ = @import("oci/reference.zig");
    _ = @import("oci/manifest.zig");
}
