const std = @import("std");
const Io = std.Io;
const vm = @import("vm.zig");
const executor = @import("guest_binary").bytes;
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/clonefile.h");
    @cInclude("unistd.h");
});

pub fn writeInitramfs(allocator: std.mem.Allocator, io: Io, base: Io.File, output_dir: Io.Dir, command: []const []const u8, environment: []const []const u8, working_dir: []const u8, user: []const u8, stop_signal: u8, volumes: []const vm.Volume, interactive: bool, network_enabled: bool, require_network: bool, measure_guest_boot: bool, export_snapshot: bool, pids_limit: ?u32, capabilities_none: bool) !void {
    const script = try makeScript(allocator, command, environment, working_dir, user, stop_signal, volumes, interactive, network_enabled, require_network, measure_guest_boot, export_snapshot, pids_limit, capabilities_none);
    defer allocator.free(script);
    const cloned = c.fclonefileat(base.handle, output_dir.handle, "initramfs", 0) == 0;
    var output = if (cloned)
        try output_dir.openFile(io, "initramfs", .{ .mode = .write_only, .follow_symlinks = false })
    else
        try output_dir.createFile(io, "initramfs", .{ .exclusive = true });
    defer output.close(io);
    var output_buffer: [32 * 1024]u8 = undefined;
    var writer = output.writerStreaming(io, &output_buffer);
    const copied = if (cloned) blk: {
        const end = c.lseek(output.handle, 0, c.SEEK_END);
        if (end < 0) return error.SeekFailed;
        break :blk @as(usize, @intCast(end));
    } else blk: {
        var input_buffer: [32 * 1024]u8 = undefined;
        var reader = base.reader(io, &input_buffer);
        break :blk try reader.interface.streamRemaining(&writer.interface);
    };
    try writer.interface.splatByteAll(0, (4 - copied % 4) % 4);
    try writeNewc(&writer.interface, "rift-init", 0o100755, script);
    try writeNewc(&writer.interface, "rift-exec", 0o100755, executor);
    try writeNewc(&writer.interface, "TRAILER!!!", 0, "");
    try writer.interface.flush();
}

fn makeScript(allocator: std.mem.Allocator, command: []const []const u8, environment: []const []const u8, working_dir: []const u8, user: []const u8, stop_signal: u8, volumes: []const vm.Volume, interactive: bool, network_enabled: bool, require_network: bool, measure_guest_boot: bool, export_snapshot: bool, pids_limit: ?u32, capabilities_none: bool) ![]u8 {
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
            "/usr/bin/busybox mkdir -p /mnt/rift /mnt/control /mnt/state /mnt/root\n" ++
            "status=125\n" ++
            "if /usr/bin/busybox mount -t virtiofs -o ro rift-rootfs /mnt/rift &&\n" ++
            "   /usr/bin/busybox mount -t virtiofs rift-control /mnt/control; then\n",
    );
    if (network_enabled) try writer.writeAll("  /usr/sbin/modprobe virtio_net >/dev/null 2>&1\n");
    if (measure_guest_boot) try writer.writeAll("  : > /mnt/control/guest-boot-ready\n");
    try writer.writeAll(
        "  if /usr/bin/busybox mount -t tmpfs -o size=256m tmpfs /mnt/state &&\n" ++
            "     /usr/bin/busybox mkdir -p /mnt/state/upper /mnt/state/work &&\n",
    );
    if (pids_limit) |limit| {
        try writer.writeAll(
            "     /usr/bin/busybox mkdir /mnt/state/cgroup &&\n" ++
                "     /usr/bin/busybox mount -t cgroup2 none /mnt/state/cgroup &&\n" ++
                "     echo +pids > /mnt/state/cgroup/cgroup.subtree_control &&\n" ++
                "     /usr/bin/busybox mkdir /mnt/state/cgroup/rift &&\n",
        );
        try writer.print("     echo {d} > /mnt/state/cgroup/rift/pids.max &&\n", .{@as(u64, limit) + 1});
    }
    try writer.writeAll(
        "     /rift-exec --copy-root-xattrs /mnt/rift /mnt/state/upper &&\n" ++
            "     /usr/bin/busybox mount -t overlay overlay -o metacopy=on,lowerdir=/mnt/rift,upperdir=/mnt/state/upper,workdir=/mnt/state/work /mnt/root; then\n" ++
            "    /usr/bin/busybox --install -s /usr/bin >/dev/null 2>&1\n",
    );
    if (network_enabled) {
        try writer.writeAll(
            "    /usr/bin/busybox ip link set eth0 up >/dev/null 2>&1\n" ++
                "    if /usr/bin/busybox udhcpc -i eth0 -q -n -t 3 -T 1 >/dev/null 2>&1; then\n" ++
                "      /usr/bin/busybox mkdir -p /mnt/root/etc\n",
        );
        if (export_snapshot) {
            try writer.writeAll(
                "      resolver_created=0\n" ++
                    "      resolver_mounted=0\n" ++
                    "      if [ ! -e /mnt/root/etc/resolv.conf ] && [ ! -L /mnt/root/etc/resolv.conf ]; then : > /mnt/root/etc/resolv.conf; resolver_created=1; fi\n" ++
                    "      if /usr/bin/busybox mount --bind /etc/resolv.conf /mnt/root/etc/resolv.conf; then resolver_mounted=1; fi\n",
            );
        } else {
            try writer.writeAll(
                "      /usr/bin/busybox rm -f /mnt/root/etc/resolv.conf\n" ++
                    "      /usr/bin/busybox cp /etc/resolv.conf /mnt/root/etc/resolv.conf\n",
            );
        }
        try writer.writeAll(
            "      guest_ip=$(/usr/bin/busybox ip -4 -o addr show eth0 | /usr/bin/busybox awk '$3 == \"inet\" {print $4}' | /usr/bin/busybox cut -d/ -f1)\n" ++
                "      if [ -n \"$guest_ip\" ]; then printf '%s\\n' \"$guest_ip\" > /mnt/control/guest-ip; fi\n" ++
                "    fi\n",
        );
    }
    if (require_network) try writer.writeAll("    if [ -s /mnt/control/guest-ip ]; then\n");
    try writer.writeAll("    /usr/bin/busybox env -i");
    for (environment) |variable| {
        if (std.mem.indexOfScalar(u8, variable, 0) != null) return error.InvalidArguments;
        try writer.writeByte(' ');
        try quote(writer, variable);
        if (output.written().len > 64 * 1024) return error.CommandTooLong;
    }
    try writer.writeAll(" /rift-exec ");
    if (pids_limit) |limit| try writer.print("--pids-limit {d} ", .{limit});
    if (capabilities_none) try writer.writeAll("--cap-profile none ");
    try writer.writeAll("/mnt/root ");
    try quote(writer, working_dir);
    try writer.writeByte(' ');
    try quote(writer, user);
    try writer.print(" {d} {d}", .{ stop_signal, volumes.len });
    for (volumes, 0..) |volume, index| {
        try writer.print(" 'rift-volume-{d}' ", .{index});
        try quote(writer, volume.target);
        try writer.writeAll(if (volume.read_only) " ro" else " rw");
        try writer.writeAll(if (volume.is_file) " file" else " directory");
        if (output.written().len > 64 * 1024) return error.CommandTooLong;
    }
    if (command[0].len == 0) return error.InvalidArguments;
    for (command) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArguments;
        try writer.writeByte(' ');
        try quote(writer, argument);
        if (output.written().len > 64 * 1024) return error.CommandTooLong;
    }
    if (!interactive) try writer.writeAll(" < /dev/null");
    try writer.print(
        " &\n" ++
            "    workload_pid=$!\n" ++
            "    (\n" ++
            "      while /usr/bin/busybox kill -0 \"$workload_pid\" 2>/dev/null; do\n" ++
            "        if [ -e /mnt/control/stop ]; then\n" ++
            "          /usr/bin/busybox kill -s {d} \"$workload_pid\" 2>/dev/null\n" ++
            "          exit\n" ++
            "        fi\n" ++
            "        /usr/bin/busybox sleep 1\n" ++
            "      done\n" ++
            "    ) &\n" ++
            "    watcher_pid=$!\n" ++
            "    wait \"$workload_pid\"\n" ++
            "    status=$?\n" ++
            "    /usr/bin/busybox kill \"$watcher_pid\" 2>/dev/null || true\n" ++
            "    wait \"$watcher_pid\" 2>/dev/null || true\n",
        .{stop_signal},
    );
    if (export_snapshot) try writer.writeAll(
        "    if [ \"${resolver_mounted:-0}\" = 1 ]; then /usr/bin/busybox umount /mnt/root/etc/resolv.conf || status=125; fi\n" ++
            "    if [ \"${resolver_created:-0}\" = 1 ]; then /usr/bin/busybox rm -f /mnt/root/etc/resolv.conf || status=125; fi\n" ++
            "    if [ \"$status\" = 0 ]; then /usr/bin/busybox tar -cpf /mnt/control/snapshot.tar -C /mnt/root . || status=125; fi\n",
    );
    if (require_network) try writer.writeAll("    fi\n");
    try writer.writeAll(
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
    const volumes = [_]vm.Volume{.{ .source = "/host", .target = "/tmp/a'b", .read_only = true }};
    const script = try makeScript(std.testing.allocator, &.{ "/bin/echo", "a'b", "$(touch /tmp/host)" }, &.{"PATH=/bin"}, "/", "1000:1000", 15, &volumes, false, true, true, true, false, null, false);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "env -i 'PATH=/bin' /rift-exec /mnt/root '/' '1000:1000' 15 1 'rift-volume-0' '/tmp/a'\"'\"'b' ro directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "'/bin/echo' 'a'\"'\"'b' '$(touch /tmp/host)'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "< /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, ": > /mnt/control/guest-boot-ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, ": > /mnt/control/guest-boot-ready").? < std.mem.indexOf(u8, script, "mount -t tmpfs -o size=256m").?);
    try std.testing.expect(std.mem.indexOf(u8, script, "if [ -s /mnt/control/guest-ip ]; then") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "udhcpc -i eth0") != null);
    const bare = try makeScript(std.testing.allocator, &.{ "echo", "hello" }, &.{}, "/", "", 15, &.{}, true, false, false, false, false, null, false);
    defer std.testing.allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "/rift-exec /mnt/root '/' '' 15 0 'echo' 'hello'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "mount -t overlay overlay -o metacopy=on,lowerdir=/mnt/rift") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "--copy-root-xattrs /mnt/rift /mnt/state/upper") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "if [ -e /mnt/control/stop ]; then") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "virtio_net") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "udhcpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "guest-boot-ready") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "/usr/bin/busybox kill -s 15 \"$workload_pid\"") != null);
    const workdir = try makeScript(std.testing.allocator, &.{"/bin/pwd"}, &.{}, "/tmp/a'b", "nobody", 15, &.{}, false, false, false, false, false, null, false);
    defer std.testing.allocator.free(workdir);
    try std.testing.expect(std.mem.indexOf(u8, workdir, "/rift-exec /mnt/root '/tmp/a'\"'\"'b' 'nobody' 15 0 '/bin/pwd'") != null);

    const snapshot = try makeScript(std.testing.allocator, &.{"/bin/true"}, &.{}, "/", "", 15, &.{}, false, true, false, false, true, null, false);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "mount --bind /etc/resolv.conf /mnt/root/etc/resolv.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "tar -cpf /mnt/control/snapshot.tar -C /mnt/root .") != null);
}

test "pids limit configures an isolated cgroup for the workload" {
    const script = try makeScript(std.testing.allocator, &.{"/bin/true"}, &.{}, "/", "", 15, &.{}, false, false, false, false, false, 8, false);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "mount -t cgroup2 none /mnt/state/cgroup") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "echo 9 > /mnt/state/cgroup/rift/pids.max") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/rift-exec --pids-limit 8 /mnt/root") != null);
}

test "capability profile none reaches the guest executor" {
    const script = try makeScript(std.testing.allocator, &.{"/bin/true"}, &.{}, "/", "", 15, &.{}, false, false, false, false, false, null, true);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "/rift-exec --cap-profile none /mnt/root") != null);
}

test "writeInitramfs preserves base bytes and appends runtime files" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base_bytes = "base-initramfs";
    try temp.dir.writeFile(io, .{ .sub_path = "base", .data = base_bytes });
    const base = try temp.dir.openFile(io, "base", .{ .mode = .read_only, .follow_symlinks = false });
    defer base.close(io);

    try writeInitramfs(std.testing.allocator, io, base, temp.dir, &.{"/bin/true"}, &.{}, "/", "", 15, &.{}, false, false, false, false, false, null, false);

    const output = try temp.dir.readFileAlloc(io, "initramfs", std.testing.allocator, .limited(base_bytes.len + executor.len + 128 * 1024));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, base_bytes, output[0..base_bytes.len]);
    const aligned_base_len = base_bytes.len + (4 - base_bytes.len % 4) % 4;
    for (output[base_bytes.len..aligned_base_len]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualStrings("070701", output[aligned_base_len .. aligned_base_len + 6]);
    try std.testing.expect(std.mem.indexOf(u8, output[aligned_base_len..], "rift-init\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[aligned_base_len..], "rift-exec\x00") != null);
    const original = try temp.dir.readFileAlloc(io, "base", std.testing.allocator, .limited(base_bytes.len + 1));
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualSlices(u8, base_bytes, original);
}
