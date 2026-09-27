const std = @import("std");
const Io = std.Io;

pub fn writeInitramfs(allocator: std.mem.Allocator, io: Io, base: Io.File, output_dir: Io.Dir, command: []const []const u8, environment: []const []const u8, interactive: bool) !void {
    const script = try makeScript(allocator, command, environment, interactive);
    defer allocator.free(script);
    var output = try output_dir.createFile(io, "initramfs", .{ .exclusive = true });
    defer output.close(io);
    var output_buffer: [32 * 1024]u8 = undefined;
    var writer = output.writerStreaming(io, &output_buffer);
    var input_buffer: [32 * 1024]u8 = undefined;
    var reader = base.reader(io, &input_buffer);
    const copied = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.splatByteAll(0, (4 - copied % 4) % 4);
    try writeNewc(&writer.interface, "rift-init", 0o100755, script);
    try writeNewc(&writer.interface, "TRAILER!!!", 0, "");
    try writer.interface.flush();
}

fn makeScript(allocator: std.mem.Allocator, command: []const []const u8, environment: []const []const u8, interactive: bool) ![]u8 {
    if (command.len == 0 or command.len > 256) return error.InvalidArguments;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(
        "#!/usr/bin/busybox sh\n" ++
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin\n" ++
            "/usr/bin/busybox mount -t devtmpfs devtmpfs /dev || /usr/bin/busybox poweroff -f\n" ++
            "/usr/sbin/modprobe virtiofs >/dev/null 2>&1\n" ++
            "/usr/sbin/modprobe overlay >/dev/null 2>&1\n" ++
            "/usr/sbin/modprobe virtio_net >/dev/null 2>&1\n" ++
            "/usr/bin/busybox mkdir -p /mnt/rift /mnt/control /mnt/state /mnt/root\n" ++
            "status=125\n" ++
            "if /usr/bin/busybox mount -t virtiofs -o ro rift-rootfs /mnt/rift &&\n" ++
            "   /usr/bin/busybox mount -t virtiofs rift-control /mnt/control; then\n" ++
            "  if /usr/bin/busybox mount -t tmpfs -o size=256m tmpfs /mnt/state &&\n" ++
            "     /usr/bin/busybox mkdir -p /mnt/state/upper /mnt/state/work &&\n" ++
            "     /usr/bin/busybox mount -t overlay overlay -o lowerdir=/mnt/rift,upperdir=/mnt/state/upper,workdir=/mnt/state/work /mnt/root; then\n" ++
            "    /usr/bin/busybox --install -s /usr/bin >/dev/null 2>&1\n" ++
            "    /usr/bin/busybox ip link set eth0 up >/dev/null 2>&1\n" ++
            "    if /usr/bin/busybox udhcpc -i eth0 -q -n -t 3 -T 1 >/dev/null 2>&1; then\n" ++
            "      /usr/bin/busybox mkdir -p /mnt/root/etc\n" ++
            "      /usr/bin/busybox rm -f /mnt/root/etc/resolv.conf\n" ++
            "      /usr/bin/busybox cp /etc/resolv.conf /mnt/root/etc/resolv.conf\n" ++
            "    fi\n" ++
            "    /usr/bin/busybox env -i",
    );
    for (environment) |variable| {
        if (std.mem.indexOfScalar(u8, variable, 0) != null) return error.InvalidArguments;
        try writer.writeByte(' ');
        try quote(writer, variable);
        if (output.written().len > 64 * 1024) return error.CommandTooLong;
    }
    try writer.writeAll(" /usr/bin/busybox chroot /mnt/root");
    if (command[0].len == 0) return error.InvalidArguments;
    if (command[0][0] != '/') try writer.writeAll(" /bin/sh -c 'exec \"$@\"' rift-sh");
    for (command) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArguments;
        try writer.writeByte(' ');
        try quote(writer, argument);
        if (output.written().len > 64 * 1024) return error.CommandTooLong;
    }
    if (!interactive) try writer.writeAll(" < /dev/null");
    try writer.writeAll(
        "\n    status=$?\n" ++
            "  fi\n" ++
            "  printf '%s\\n' \"$status\" > /mnt/control/exit\n" ++
            "  /usr/bin/busybox sync\n" ++
            "fi\n" ++
            "/usr/bin/busybox poweroff -f\n",
    );
    return output.toOwnedSlice();
}

fn quote(writer: *Io.Writer, argument: []const u8) Io.Writer.Error!void {
    try writer.writeByte('\'');
    for (argument) |character| {
        if (character == '\'') {
            try writer.writeAll("'\"'\"'");
        } else {
            try writer.writeByte(character);
        }
    }
    try writer.writeByte('\'');
}

fn writeNewc(writer: *Io.Writer, name: []const u8, mode: u32, data: []const u8) Io.Writer.Error!void {
    try writer.writeAll("070701");
    const fields = [_]u32{
        1, mode, 0, 0, 1,                      0, @intCast(data.len),
        0, 0,    0, 0, @intCast(name.len + 1), 0,
    };
    for (fields) |field| try writer.print("{x:0>8}", .{field});
    try writer.writeAll(name);
    try writer.writeByte(0);
    try writer.splatByteAll(0, (4 - (110 + name.len + 1) % 4) % 4);
    try writer.writeAll(data);
    try writer.splatByteAll(0, (4 - data.len % 4) % 4);
}

test "shell arguments remain quoted" {
    const script = try makeScript(std.testing.allocator, &.{ "/bin/echo", "a'b", "$(touch /tmp/host)" }, &.{"PATH=/bin"}, false);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "env -i 'PATH=/bin' /usr/bin/busybox chroot") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "'/bin/echo' 'a'\"'\"'b' '$(touch /tmp/host)'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "< /dev/null") != null);
    const bare = try makeScript(std.testing.allocator, &.{ "echo", "hello" }, &.{}, true);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "/bin/sh -c 'exec \"$@\"' rift-sh 'echo' 'hello'") != null);
}
