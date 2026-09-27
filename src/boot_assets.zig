const std = @import("std");
const Io = std.Io;

const iso_url = "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.2-aarch64.iso";
const iso_sha256 = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6";
pub const kernel_sha256 = "e698a107e4d04117db1a7b0daee99bdae5f0647fba2af50f3cd020a666950ab9";
pub const initramfs_sha256 = "5b9de8ff7b4f3055f6cf940e1ff869790415cf81b7ea1e399ee60448bc1a2c4d";

/// A fresh binary fetches its pinned guest files on first use. The ISO is discarded afterward.
pub fn ensure(allocator: std.mem.Allocator, io: Io, data_dir: Io.Dir) !void {
    data_dir.createDir(io, "guest", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var guest = try data_dir.openDir(io, "guest", .{ .follow_symlinks = false });
    defer guest.close(io);
    const lock = try guest.createFile(io, "install.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    if (try exists(io, guest, "Image") and try exists(io, guest, "initramfs-virt")) return;

    std.debug.print("rift: downloading verified Alpine guest boot files (first run)\n", .{});
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(allocator, ".alpine-iso-{s}", .{hex});
    defer allocator.free(temporary);
    defer guest.deleteFile(io, temporary) catch {};
    try downloadIso(allocator, io, guest, temporary);
    var guest_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const guest_path = guest_path_buffer[0..try guest.realPath(io, &guest_path_buffer)];
    const iso_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ guest_path, temporary });
    defer allocator.free(iso_path);
    try installFromIso(allocator, io, guest, iso_path);
}

fn exists(io: Io, dir: Io.Dir, name: []const u8) !bool {
    const file = dir.openFile(io, name, .{ .mode = .read_only, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn downloadIso(allocator: std.mem.Allocator, io: Io, guest: Io.Dir, name: []const u8) !void {
    const output = try guest.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer output.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = output.writerStreaming(io, &buffer);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(iso_url), .{
        .headers = .{ .accept_encoding = .omit },
        .redirect_behavior = @enumFromInt(3),
    });
    defer request.deinit();
    try request.sendBodiless();
    var header_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);
    if (!std.mem.eql(u8, request.uri.scheme, "https")) return error.InsecureGuestRedirect;
    if (response.head.status != .ok) return error.GuestDownloadFailed;
    const max_size = 128 * 1024 * 1024;
    if (response.head.content_length) |length| if (length > max_size) return error.GuestArchiveTooLarge;
    var transfer_buffer: [32 * 1024]u8 = undefined;
    try copyBounded(response.reader(&transfer_buffer), &writer.interface, max_size);
    try writer.interface.flush();
}

fn copyBounded(reader: *Io.Reader, writer: *Io.Writer, limit: usize) !void {
    var chunk: [32 * 1024]u8 = undefined;
    var copied: usize = 0;
    while (true) {
        const count = try reader.readSliceShort(&chunk);
        if (count == 0) return;
        if (count > limit - copied) return error.GuestArchiveTooLarge;
        try writer.writeAll(chunk[0..count]);
        copied += count;
    }
}

pub fn installFromIso(allocator: std.mem.Allocator, io: Io, guest: Io.Dir, iso_path: []const u8) !void {
    const iso = try Io.Dir.openFileAbsolute(io, iso_path, .{ .mode = .read_only, .follow_symlinks = false });
    defer iso.close(io);
    if (!(try matchesSha256(io, iso, iso_sha256))) return error.GuestArchiveDigestMismatch;

    const zboot = try extract(allocator, io, iso_path, "boot/vmlinuz-virt");
    defer allocator.free(zboot);
    const initramfs = try extract(allocator, io, iso_path, "boot/initramfs-virt");
    defer allocator.free(initramfs);
    if (initramfs.len < 2 or initramfs[0] != 0x1f or initramfs[1] != 0x8b or
        !bytesMatchSha256(initramfs, initramfs_sha256)) return error.GuestAssetsCorrupt;

    if (zboot.len < 64 or !std.mem.eql(u8, zboot[0..2], "MZ") or !std.mem.eql(u8, zboot[4..8], "zimg") or
        !std.mem.startsWith(u8, zboot[24..56], "gzip\x00")) return error.UnsupportedGuestKernel;
    const offset = std.mem.readInt(u32, zboot[8..12], .little);
    const size = std.mem.readInt(u32, zboot[12..16], .little);
    if (offset < 64 or offset > zboot.len or size == 0 or size > zboot.len - offset) return error.UnsupportedGuestKernel;
    var source = Io.Reader.fixed(zboot[offset..][0..size]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&source, .gzip, &window);
    const kernel = try decompressor.reader.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(kernel);
    if (kernel.len < 64 or !std.mem.eql(u8, kernel[56..60], "ARMd") or
        std.mem.readInt(u64, kernel[16..24], .little) != kernel.len or
        !bytesMatchSha256(kernel, kernel_sha256)) return error.GuestAssetsCorrupt;

    try writeAtomic(io, guest, "Image", kernel);
    try writeAtomic(io, guest, "initramfs-virt", initramfs);
}

fn extract(allocator: std.mem.Allocator, io: Io, iso_path: []const u8, member: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/tar", "-xOf", iso_path, member },
        .stdout_limit = .limited(20 * 1024 * 1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.GuestArchiveInvalid;
    return result.stdout;
}

fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = true, .permissions = .fromMode(0o600) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn matchesSha256(io: Io, file: Io.File, expected: []const u8) !bool {
    var input_buffer: [32 * 1024]u8 = undefined;
    var chunk: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &input_buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hash.update(chunk[0..count]);
    }
    const actual = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.mem.eql(u8, &actual, expected);
}

fn bytesMatchSha256(bytes: []const u8, expected: []const u8) bool {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const actual = std.fmt.bytesToHex(hash, .lower);
    return std.mem.eql(u8, &actual, expected);
}

test "guest ISO download stops at the size bound" {
    var source = Io.Reader.fixed("123456789");
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.GuestArchiveTooLarge, copyBounded(&source, &output.writer, 8));
    try std.testing.expectEqualStrings("", output.written());
}
