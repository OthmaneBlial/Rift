const std = @import("std");
const Io = std.Io;

const max_layer_bytes = 8 * 1024 * 1024 * 1024;
const max_image_layer_bytes = 32 * 1024 * 1024 * 1024;
const max_pax_header_bytes = 1024 * 1024;
const max_owner_records = 1_000_000;
pub const max_owner_manifest_bytes = 64 * 1024 * 1024;
const max_owner_index_scan_visits = 10_000_000;

pub const ExpansionBudget = struct {
    // apply decompresses every layer once for whiteouts and again for entries.
    whiteouts: u64 = 0,
    entries: u64 = 0,
    owner_manifest_bytes: u64 = "RIFTOWN1".len,
    owner_index_scan_visits: u64 = 0,
};

pub const DirectoryMetadata = struct {
    mode: u32,
    mtime: Io.Timestamp,
};

pub const Ownership = struct {
    uid: u32,
    gid: u32,
};

/// Validate a guest-produced uncompressed layer without extracting it to the host filesystem.
pub fn validateUncompressedTar(allocator: std.mem.Allocator, io: Io, blob: Io.File) !void {
    var reader_buffer: [32 * 1024]u8 = undefined;
    var reader = blob.reader(io, &reader_buffer);
    var image_total: u64 = 0;
    var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var it = LayerTarIterator.init(allocator, &reader.interface, &image_total, &name_buffer, &link_buffer);
    var entry_count: usize = 0;
    var layer_total: u64 = 0;
    var discard_buffer: [4096]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buffer);
    while (true) {
        @memset(&name_buffer, 0);
        @memset(&link_buffer, 0);
        const entry = (try it.next()) orelse break;
        entry_count += 1;
        if (entry_count > 1_000_000 or layer_total > max_layer_bytes or entry.size > max_layer_bytes - layer_total) return error.LayerTooLarge;
        layer_total += entry.size;
        const path = try cleanPath(entry.name, &clean_buffer);
        if (path.len == 0 and entry.kind != .directory) return error.UnsafeLayerPath;
        const name = basename(path);
        if (std.mem.startsWith(u8, name, ".wh.")) {
            if (entry.kind != .file or entry.size != 0 or std.mem.eql(u8, name, ".wh.") or
                std.mem.eql(u8, name[4..], ".") or std.mem.eql(u8, name[4..], "..")) return error.InvalidWhiteout;
        } else switch (entry.kind) {
            .sym_link => try checkLink(path, entry.link_name),
            .hard_link => {
                const target = try cleanPath(entry.link_name, &clean_link_buffer);
                if (target.len == 0) return error.InvalidHardlink;
            },
            .device => if (entry.size != 0 or !std.mem.startsWith(u8, path, "dev/")) return error.UnsupportedLayerSpecialFile,
            .directory, .file => {},
        }
        try it.streamRemaining(entry, &discarding.writer);
    }
}

/// Apply a verified OCI layer to a private, unpublished root directory.
/// Whiteouts run first so they cannot delete files added by the same layer.
pub fn apply(
    allocator: std.mem.Allocator,
    io: Io,
    root: Io.Dir,
    blob: Io.File,
    media_type: []const u8,
    directory_metadata: *std.StringHashMap(DirectoryMetadata),
    ownership: *std.StringHashMap(Ownership),
    budget: *ExpansionBudget,
) !void {
    try pass(allocator, io, root, blob, media_type, directory_metadata, ownership, budget, .whiteouts);
    try pass(allocator, io, root, blob, media_type, directory_metadata, ownership, budget, .entries);
}

const Pass = enum { whiteouts, entries };

const LayerTarEntryKind = enum { directory, sym_link, file, hard_link, device };
const LayerTarEntry = struct {
    name: []const u8,
    link_name: []const u8,
    size: u64,
    mode: u32,
    kind: LayerTarEntryKind,
    mtime: Io.Timestamp,
    ownership: Ownership,
};

const PaxOverrides = struct {
    path: ?[]const u8 = null,
    linkpath: ?[]const u8 = null,
    size: ?u64 = null,
    has_mtime: bool = false,
    mtime: ?Io.Timestamp = null,
    has_uid: bool = false,
    uid: ?u32 = null,
    has_gid: bool = false,
    gid: ?u32 = null,
};

/// std.tar.Iterator drops PAX mtime records and global PAX headers. Keep its
/// supported entry behavior while retaining the timestamps needed by OCI layers.
const LayerTarIterator = struct {
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    image_total: *u64,
    layer_total: u64 = 0,
    file_name_buffer: []u8,
    link_name_buffer: []u8,
    global_file_name_buffer: [Io.Dir.max_path_bytes]u8 = undefined,
    global_link_name_buffer: [Io.Dir.max_path_bytes]u8 = undefined,
    header_buffer: [512]u8 = undefined,
    padding: usize = 0,
    unread_file_bytes: u64 = 0,
    global_path: ?[]const u8 = null,
    global_linkpath: ?[]const u8 = null,
    global_size: ?u64 = null,
    global_mtime: ?Io.Timestamp = null,
    global_uid: ?u32 = null,
    global_gid: ?u32 = null,

    fn init(allocator: std.mem.Allocator, reader: *Io.Reader, image_total: *u64, file_name_buffer: []u8, link_name_buffer: []u8) LayerTarIterator {
        return .{
            .allocator = allocator,
            .reader = reader,
            .image_total = image_total,
            .file_name_buffer = file_name_buffer,
            .link_name_buffer = link_name_buffer,
        };
    }

    fn account(self: *LayerTarIterator, amount: u64) !void {
        const layer_total = std.math.add(u64, self.layer_total, amount) catch return error.LayerTooLarge;
        if (layer_total > max_layer_bytes) return error.LayerTooLarge;
        const image_total = std.math.add(u64, self.image_total.*, amount) catch return error.ImageLayersTooLarge;
        if (image_total > max_image_layer_bytes) return error.ImageLayersTooLarge;
        self.layer_total = layer_total;
        self.image_total.* = image_total;
    }

    fn next(self: *LayerTarIterator) !?LayerTarEntry {
        if (self.unread_file_bytes > 0) {
            try self.account(self.unread_file_bytes);
            try self.reader.discardAll64(self.unread_file_bytes);
            self.unread_file_bytes = 0;
        }

        var pax: PaxOverrides = .{};
        var gnu_name: ?[]const u8 = null;
        var gnu_link_name: ?[]const u8 = null;
        while (try self.readHeader()) {
            const header = &self.header_buffer;
            const kind = header[156];
            const size = try tarHeaderSize(header);
            switch (kind) {
                'g' => try self.readPaxHeader(size, &pax, true),
                'x' => {
                    pax = .{};
                    gnu_name = null;
                    gnu_link_name = null;
                    try self.readPaxHeader(size, &pax, false);
                },
                'L' => gnu_name = try self.readGnuString(size, self.file_name_buffer),
                'K' => gnu_link_name = try self.readGnuString(size, self.link_name_buffer),
                '0', 0, '1', '2', '3', '4', '5' => {
                    const entry_size = pax.size orelse self.global_size orelse size;
                    if (entry_size > max_layer_bytes) return error.LayerTooLarge;
                    const mtime = if (pax.has_mtime)
                        pax.mtime orelse try tarMtime(header)
                    else
                        self.global_mtime orelse try tarMtime(header);
                    var raw_name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
                    const raw_name = try tarHeaderName(header, &raw_name_buffer);
                    const name = pax.path orelse gnu_name orelse self.global_path orelse try copyTarString(self.file_name_buffer, raw_name);
                    const raw_link_name = std.mem.sliceTo(header[157..257], 0);
                    const link_name = pax.linkpath orelse gnu_link_name orelse self.global_linkpath orelse try copyTarString(self.link_name_buffer, raw_link_name);
                    const entry_kind: LayerTarEntryKind = switch (kind) {
                        '5' => .directory,
                        '2' => .sym_link,
                        '1' => .hard_link,
                        '3', '4' => .device,
                        else => .file,
                    };
                    const ownership: Ownership = .{
                        .uid = if (pax.has_uid) pax.uid orelse try tarHeaderId(header[108..116]) else self.global_uid orelse try tarHeaderId(header[108..116]),
                        .gid = if (pax.has_gid) pax.gid orelse try tarHeaderId(header[116..124]) else self.global_gid orelse try tarHeaderId(header[116..124]),
                    };
                    self.padding = tarBlockPadding(entry_size);
                    self.unread_file_bytes = entry_size;
                    return .{
                        .name = name,
                        .link_name = link_name,
                        .size = entry_size,
                        .mode = try tarHeaderMode(header),
                        .kind = entry_kind,
                        .mtime = mtime,
                        .ownership = ownership,
                    };
                },
                else => return error.TarUnsupportedHeader,
            }
        }
        return null;
    }

    fn streamRemaining(self: *LayerTarIterator, entry: LayerTarEntry, writer: *Io.Writer) !void {
        try self.account(entry.size);
        try self.reader.streamExact64(writer, entry.size);
        self.unread_file_bytes = 0;
    }

    fn readHeader(self: *LayerTarIterator) !bool {
        if (self.padding > 0) {
            try self.account(self.padding);
            try self.reader.discardAll(self.padding);
            self.padding = 0;
        }
        const count = try self.reader.readSliceShort(&self.header_buffer);
        try self.account(count);
        if (count == 0) return false;
        if (count < self.header_buffer.len) return error.UnexpectedEndOfStream;

        const expected = try tarHeaderOctal(self.header_buffer[148..156]);
        var unsigned: u64 = 0;
        var signed: i64 = 0;
        for (self.header_buffer, 0..) |byte, index| {
            const value = if (index >= 148 and index < 156) 32 else byte;
            unsigned += value;
            signed += @as(i8, @bitCast(value));
        }
        if (expected == 0 and unsigned == 256) return false;
        if (expected != unsigned and expected != signed) return error.TarHeaderChksum;
        return true;
    }

    fn readPaxHeader(self: *LayerTarIterator, size: u64, pax: *PaxOverrides, global: bool) !void {
        if (size > max_pax_header_bytes) return error.TarHeadersTooBig;
        try self.account(size);
        const body = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(body);
        try self.reader.readSliceAll(body);
        self.padding = tarBlockPadding(size);
        var offset: usize = 0;
        while (offset < body.len) {
            const separator = std.mem.indexOfScalarPos(u8, body, offset, ' ') orelse return error.PaxInvalidAttribute;
            const length = std.fmt.parseInt(usize, body[offset..separator], 10) catch return error.PaxInvalidAttribute;
            if (length == 0 or length > body.len - offset) return error.PaxInvalidAttribute;
            const end = offset + length;
            const record = body[offset..end];
            if (record.len < separator - offset + 4 or record[record.len - 1] != '\n') return error.PaxInvalidAttribute;
            const equals = std.mem.indexOfScalar(u8, record, '=') orelse return error.PaxInvalidAttribute;
            const key_start = separator - offset + 1;
            if (equals <= key_start or std.mem.indexOfScalar(u8, record, 0) != null) return error.PaxInvalidAttribute;
            const key = record[key_start..equals];
            const value = record[equals + 1 .. record.len - 1];

            if (global) {
                if (std.mem.eql(u8, key, "mtime")) {
                    self.global_mtime = if (value.len == 0) null else try parsePaxMtime(value);
                    pax.has_mtime = false;
                    pax.mtime = null;
                } else if (std.mem.eql(u8, key, "uid")) {
                    self.global_uid = if (value.len == 0) null else try parsePaxId(value);
                } else if (std.mem.eql(u8, key, "gid")) {
                    self.global_gid = if (value.len == 0) null else try parsePaxId(value);
                } else if (std.mem.eql(u8, key, "path")) {
                    self.global_path = if (value.len == 0) null else try copyTarString(&self.global_file_name_buffer, value);
                } else if (std.mem.eql(u8, key, "linkpath")) {
                    self.global_linkpath = if (value.len == 0) null else try copyTarString(&self.global_link_name_buffer, value);
                } else if (std.mem.eql(u8, key, "size")) {
                    self.global_size = if (value.len == 0) null else std.fmt.parseInt(u64, value, 10) catch return error.PaxInvalidAttribute;
                }
            } else if (std.mem.eql(u8, key, "path")) {
                pax.path = try copyTarString(self.file_name_buffer, value);
            } else if (std.mem.eql(u8, key, "linkpath")) {
                pax.linkpath = try copyTarString(self.link_name_buffer, value);
            } else if (std.mem.eql(u8, key, "size")) {
                pax.size = std.fmt.parseInt(u64, value, 10) catch return error.PaxInvalidAttribute;
            } else if (std.mem.eql(u8, key, "mtime")) {
                pax.has_mtime = true;
                pax.mtime = if (value.len == 0) null else try parsePaxMtime(value);
            } else if (std.mem.eql(u8, key, "uid")) {
                pax.has_uid = true;
                pax.uid = if (value.len == 0) null else try parsePaxId(value);
            } else if (std.mem.eql(u8, key, "gid")) {
                pax.has_gid = true;
                pax.gid = if (value.len == 0) null else try parsePaxId(value);
            }
            offset = end;
        }
    }

    fn readGnuString(self: *LayerTarIterator, size: u64, buffer: []u8) ![]const u8 {
        if (size > buffer.len) return error.TarInsufficientBuffer;
        try self.account(size);
        const value = buffer[0..@intCast(size)];
        try self.reader.readSliceAll(value);
        self.padding = tarBlockPadding(size);
        return std.mem.sliceTo(value, 0);
    }
};

fn copyTarString(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.TarInsufficientBuffer;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn tarBlockPadding(size: u64) usize {
    return @intCast((512 - size % 512) % 512);
}

fn tarHeaderOctal(field: []const u8) !u64 {
    const value = std.mem.trim(u8, field, " \x00");
    if (value.len == 0) return 0;
    return std.fmt.parseInt(u64, value, 8) catch return error.TarHeader;
}

fn tarHeaderSize(header: *const [512]u8) !u64 {
    const field = header[124..136];
    if (field[0] == 0xff) return error.TarNumericValueNegative;
    if (field[0] == 0x80) {
        if (field[1] != 0 or field[2] != 0 or field[3] != 0) return error.TarNumericValueTooBig;
        return std.mem.readInt(u64, field[4..12], .big);
    }
    return tarHeaderOctal(field);
}

fn tarHeaderMode(header: *const [512]u8) !u32 {
    return @intCast(try tarHeaderOctal(header[100..108]));
}

fn tarHeaderId(field: []const u8) !u32 {
    if (field.len == 0 or field[0] == 0xff) return error.TarNumericValueNegative;
    var value: u64 = 0;
    if (field[0] & 0x80 != 0) {
        if (field[0] & 0x40 != 0) return error.TarNumericValueNegative;
        value = field[0] & 0x3f;
        for (field[1..]) |byte| {
            value = std.math.mul(u64, value, 256) catch return error.TarNumericValueTooBig;
            value = std.math.add(u64, value, byte) catch return error.TarNumericValueTooBig;
        }
    } else {
        const text = std.mem.trim(u8, field, " \x00");
        value = if (text.len == 0) 0 else std.fmt.parseInt(u64, text, 8) catch return error.TarHeader;
    }
    const id = std.math.cast(u32, value) orelse return error.TarNumericValueTooBig;
    if (id == std.math.maxInt(u32)) return error.TarNumericValueTooBig;
    return id;
}

fn parsePaxId(value: []const u8) !u32 {
    if (value.len == 0) return error.PaxInvalidAttribute;
    for (value) |digit| if (digit < '0' or digit > '9') return error.PaxInvalidAttribute;
    const id = std.fmt.parseInt(u32, value, 10) catch return error.PaxInvalidAttribute;
    if (id == std.math.maxInt(u32)) return error.PaxInvalidAttribute;
    return id;
}

fn parsePaxMtime(value: []const u8) !Io.Timestamp {
    if (value.len == 0) return error.InvalidLayerTimestamp;
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
    if (dot == 0 or (dot < value.len and dot + 1 == value.len)) return error.InvalidLayerTimestamp;
    const seconds_text = value[0..dot];
    const digit_start: usize = if (seconds_text[0] == '-' or seconds_text[0] == '+') 1 else 0;
    if (digit_start == seconds_text.len) return error.InvalidLayerTimestamp;
    for (seconds_text[digit_start..]) |digit| if (digit < '0' or digit > '9') return error.InvalidLayerTimestamp;
    const seconds = std.fmt.parseInt(i96, seconds_text, 10) catch return error.InvalidLayerTimestamp;
    const negative = value[0] == '-';
    var nanoseconds = std.math.mul(i96, seconds, std.time.ns_per_s) catch return error.InvalidLayerTimestamp;
    if (dot < value.len) {
        const fraction = value[dot + 1 ..];
        // Io.Timestamp has nanosecond precision; finer PAX fractions are truncated.
        for (fraction) |digit| if (digit < '0' or digit > '9') return error.InvalidLayerTimestamp;
        const precision = @min(fraction.len, 9);
        var fractional_ns = std.fmt.parseInt(i96, fraction[0..precision], 10) catch return error.InvalidLayerTimestamp;
        for (precision..9) |_| fractional_ns *= 10;
        nanoseconds = if (negative)
            std.math.sub(i96, nanoseconds, fractional_ns) catch return error.InvalidLayerTimestamp
        else
            std.math.add(i96, nanoseconds, fractional_ns) catch return error.InvalidLayerTimestamp;
    }
    return .fromNanoseconds(nanoseconds);
}

fn pass(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8, directory_metadata: *std.StringHashMap(DirectoryMetadata), ownership: *std.StringHashMap(Ownership), budget: *ExpansionBudget, phase: Pass) !void {
    var input_buffer: [32 * 1024]u8 = undefined;
    var input = blob.reader(io, &input_buffer);
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar"))
    {
        return applyTar(allocator, io, root, &input.interface, directory_metadata, ownership, budget, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip"))
    {
        var output_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&input.interface, .gzip, &output_buffer);
        return applyTar(allocator, io, root, &decompressor.reader, directory_metadata, ownership, budget, phase);
    }
    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+zstd")) {
        const output_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer allocator.free(output_buffer);
        var decompressor = std.compress.zstd.Decompress.init(&input.interface, output_buffer, .{});
        return applyTar(allocator, io, root, &decompressor.reader, directory_metadata, ownership, budget, phase);
    }
    return error.UnsupportedLayerMediaType;
}

fn applyTar(allocator: std.mem.Allocator, io: Io, root: Io.Dir, reader: *Io.Reader, directory_metadata: *std.StringHashMap(DirectoryMetadata), ownership: *std.StringHashMap(Ownership), budget: *ExpansionBudget, phase: Pass) !void {
    var name_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    var clean_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const image_total = if (phase == .whiteouts) &budget.whiteouts else &budget.entries;
    var it = LayerTarIterator.init(allocator, reader, image_total, &name_buffer, &link_buffer);
    var total: u64 = 0;
    var count: usize = 0;
    while (true) {
        @memset(&name_buffer, 0);
        @memset(&link_buffer, 0);
        const next = try it.next();
        const entry = next orelse break;
        count += 1;
        if (count > 1_000_000 or entry.size > max_layer_bytes - total) return error.LayerTooLarge;
        total += entry.size;
        const path = try cleanPath(entry.name, &clean_buffer);
        if (path.len == 0 and entry.kind != .directory) return error.UnsafeLayerPath;

        const name = basename(path);
        const is_whiteout = std.mem.startsWith(u8, name, ".wh.");
        if (is_whiteout) {
            if (entry.kind != .file or entry.size != 0) return error.InvalidWhiteout;
            if (std.mem.eql(u8, name, ".wh.") or std.mem.eql(u8, name[4..], ".") or
                std.mem.eql(u8, name[4..], "..")) return error.InvalidWhiteout;
            if (phase == .whiteouts) {
                try applyWhiteout(allocator, io, root, path, name);
                if (std.mem.eql(u8, name, ".wh..wh..opq")) {
                    try removeOwnerDescendants(allocator, ownership, parentPath(path), budget);
                } else {
                    const parent_path = parentPath(path);
                    const target = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ parent_path, if (parent_path.len == 0) "" else "/", name[4..] });
                    defer allocator.free(target);
                    try removeOwnerSubtree(allocator, ownership, target, budget);
                }
            }
            continue;
        }
        if (entry.kind == .device) {
            if (entry.size != 0 or !std.mem.startsWith(u8, path, "dev/")) return error.UnsupportedLayerSpecialFile;
            continue;
        }
        if (path.len == 0) {
            if (phase == .entries and entry.kind == .directory) try setOwnership(ownership, path, entry.ownership, budget);
            continue;
        }
        if (phase == .whiteouts) {
            if (entry.kind == .hard_link) try applyHardlink(allocator, io, root, path, entry.link_name, entry.size, entry.mtime, entry.ownership, ownership, budget, phase);
            continue;
        }
        if (entry.kind == .hard_link) {
            try applyHardlink(allocator, io, root, path, entry.link_name, entry.size, entry.mtime, entry.ownership, ownership, budget, phase);
            continue;
        }

        var parent = (try openParent(io, root, parentPath(path), true)).?;
        defer parent.close(io);
        switch (entry.kind) {
            .directory => {
                const mode: u32 = @intCast(entry.mode & 0o7777);
                const metadata: DirectoryMetadata = .{ .mode = mode, .mtime = entry.mtime };
                if (directory_metadata.getPtr(path)) |stored_metadata| {
                    stored_metadata.* = metadata;
                } else {
                    try directory_metadata.put(try directory_metadata.allocator.dupe(u8, path), metadata);
                }
                const existing = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (existing) |stat| {
                    if (stat.kind == .directory) {
                        try setOwnership(ownership, path, entry.ownership, budget);
                        continue;
                    }
                    try parent.deleteTree(io, name);
                    try removeOwnerSubtree(allocator, ownership, path, budget);
                }
                try parent.createDirPath(io, name);
                try setOwnership(ownership, path, entry.ownership, budget);
            },
            .file => {
                try parent.deleteTree(io, name);
                try removeOwnerSubtree(allocator, ownership, path, budget);
                var output = try parent.createFile(io, name, .{
                    .exclusive = true,
                    .permissions = .fromMode(@intCast(entry.mode & 0o777)),
                });
                defer output.close(io);
                var output_buffer: [32 * 1024]u8 = undefined;
                var writer = output.writerStreaming(io, &output_buffer);
                try it.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
                try output.setPermissions(io, .fromMode(@intCast(entry.mode & 0o777)));
                try output.setTimestamps(io, .{ .modify_timestamp = .init(entry.mtime) });
                try setOwnership(ownership, path, entry.ownership, budget);
            },
            .sym_link => {
                try checkLink(path, entry.link_name);
                try parent.deleteTree(io, name);
                try removeOwnerSubtree(allocator, ownership, path, budget);
                try parent.symLink(io, entry.link_name, name, .{});
                try parent.setTimestamps(io, name, .{
                    .follow_symlinks = false,
                    .modify_timestamp = .init(entry.mtime),
                });
                try setOwnership(ownership, path, entry.ownership, budget);
            },
            .hard_link => unreachable,
            .device => unreachable,
        }
    }
}

pub fn applyDirectoryMetadata(io: Io, root: Io.Dir, directory_metadata: *std.StringHashMap(DirectoryMetadata)) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(directory_metadata.allocator);
    var entries = directory_metadata.iterator();
    while (entries.next()) |entry| try paths.append(directory_metadata.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return lhs.len > rhs.len;
        }
    }.lessThan);
    for (paths.items) |path| try applyDirectoryMetadataEntry(io, root, path, directory_metadata.get(path).?);
}

fn applyDirectoryMetadataEntry(io: Io, root: Io.Dir, path: []const u8, metadata: DirectoryMetadata) !void {
    var parent = openParent(io, root, parentPath(path), false) catch |err| switch (err) {
        error.UnsafeLayerPath => return,
        else => return err,
    } orelse return;
    defer parent.close(io);
    const name = basename(path);
    const stat = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return;
    var directory = parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return,
        else => return err,
    };
    defer directory.close(io);
    try directory.setPermissions(io, .fromMode(@intCast(metadata.mode)));
    try parent.setTimestamps(io, name, .{
        .follow_symlinks = false,
        .modify_timestamp = .init(metadata.mtime),
    });
}

fn setOwnership(ownership: *std.StringHashMap(Ownership), path: []const u8, value: Ownership, budget: *ExpansionBudget) !void {
    if (value.uid == 0 and value.gid == 0) {
        if (ownership.count() == 0) return;
        if (ownership.fetchRemove(path)) |removed| {
            budget.owner_manifest_bytes -= @as(u64, 12) + @as(u64, @intCast(removed.key.len));
            ownership.allocator.free(removed.key);
        }
        return;
    }
    if (ownership.getPtr(path)) |stored| {
        stored.* = value;
        return;
    }
    if (ownership.count() >= max_owner_records) return error.TooManyOwnedImageEntries;
    try accountOwnerManifestRecord(budget, path.len);
    try ownership.put(try ownership.allocator.dupe(u8, path), value);
}

fn removeOwnerSubtree(allocator: std.mem.Allocator, ownership: *std.StringHashMap(Ownership), prefix: []const u8, budget: *ExpansionBudget) !void {
    try removeOwnerEntries(allocator, ownership, prefix, true, budget);
}

fn removeOwnerDescendants(allocator: std.mem.Allocator, ownership: *std.StringHashMap(Ownership), prefix: []const u8, budget: *ExpansionBudget) !void {
    try removeOwnerEntries(allocator, ownership, prefix, false, budget);
}

fn removeOwnerEntries(allocator: std.mem.Allocator, ownership: *std.StringHashMap(Ownership), prefix: []const u8, include_self: bool, budget: *ExpansionBudget) !void {
    try accountOwnerIndexScan(budget, ownership.count());
    var removed_paths: std.ArrayList([]const u8) = .empty;
    defer removed_paths.deinit(allocator);
    var entries = ownership.iterator();
    while (entries.next()) |entry| {
        const path = entry.key_ptr.*;
        const is_self = std.mem.eql(u8, path, prefix);
        const is_descendant = if (prefix.len == 0)
            path.len != 0
        else
            path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
        if ((include_self and is_self) or is_descendant) try removed_paths.append(allocator, path);
    }
    for (removed_paths.items) |path| {
        if (ownership.fetchRemove(path)) |removed| {
            budget.owner_manifest_bytes -= @as(u64, 12) + @as(u64, @intCast(removed.key.len));
            ownership.allocator.free(removed.key);
        }
    }
}

fn applyHardlink(allocator: std.mem.Allocator, io: Io, root: Io.Dir, path: []const u8, raw_target: []const u8, size: u64, mtime: Io.Timestamp, entry_ownership: Ownership, ownership: *std.StringHashMap(Ownership), budget: *ExpansionBudget, phase: Pass) !void {
    if (size != 0) return error.TarUnsupportedHeader;
    var clean_target_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const target = try cleanPath(raw_target, &clean_target_buffer);
    if (path.len == 0 or target.len == 0 or std.mem.eql(u8, path, target)) return error.UnsafeLayerLink;
    const target_ownership = ownership.get(target) orelse entry_ownership;
    if (std.mem.startsWith(u8, basename(path), ".wh.")) return error.InvalidWhiteout;
    if (phase == .whiteouts) return;
    var source = (try openParent(io, root, parentPath(target), false)) orelse return error.InvalidHardlink;
    defer source.close(io);
    if ((try source.statFile(io, basename(target), .{ .follow_symlinks = false })).kind != .file) return error.InvalidHardlink;
    var parent = (try openParent(io, root, parentPath(path), true)).?;
    defer parent.close(io);
    try parent.deleteTree(io, basename(path));
    try removeOwnerSubtree(allocator, ownership, path, budget);
    try source.hardLink(basename(target), parent, basename(path), io, .{ .follow_symlinks = false });
    try parent.setTimestamps(io, basename(path), .{
        .follow_symlinks = false,
        .modify_timestamp = .init(mtime),
    });
    try setOwnership(ownership, path, target_ownership, budget);
}

fn accountOwnerManifestRecord(budget: *ExpansionBudget, path_length: usize) !void {
    const record_bytes = std.math.add(u64, 12, @intCast(path_length)) catch return error.OwnershipManifestTooLarge;
    const total = std.math.add(u64, budget.owner_manifest_bytes, record_bytes) catch return error.OwnershipManifestTooLarge;
    if (total > max_owner_manifest_bytes) return error.OwnershipManifestTooLarge;
    budget.owner_manifest_bytes = total;
}

fn accountOwnerIndexScan(budget: *ExpansionBudget, entry_count: usize) !void {
    const total = std.math.add(u64, budget.owner_index_scan_visits, @intCast(entry_count)) catch return error.LayerOwnershipIndexTooComplex;
    if (total > max_owner_index_scan_visits) return error.LayerOwnershipIndexTooComplex;
    budget.owner_index_scan_visits = total;
}

test "bounds ownership metadata bytes and repeated index scans" {
    var budget: ExpansionBudget = .{};
    try accountOwnerManifestRecord(&budget, 4);
    try std.testing.expectEqual(@as(u64, 24), budget.owner_manifest_bytes);
    try std.testing.expectError(error.OwnershipManifestTooLarge, accountOwnerManifestRecord(&budget, max_owner_manifest_bytes));
    try std.testing.expectEqual(@as(u64, 24), budget.owner_manifest_bytes);

    var scan_budget: ExpansionBudget = .{ .owner_index_scan_visits = max_owner_index_scan_visits - 1 };
    try accountOwnerIndexScan(&scan_budget, 1);
    try std.testing.expectEqual(@as(u64, max_owner_index_scan_visits), scan_budget.owner_index_scan_visits);
    try std.testing.expectError(error.LayerOwnershipIndexTooComplex, accountOwnerIndexScan(&scan_budget, 1));
    try std.testing.expectEqual(@as(u64, max_owner_index_scan_visits), scan_budget.owner_index_scan_visits);
}

test "ownership removals keep the bounded manifest size in sync" {
    const allocator = std.testing.allocator;
    var ownership = std.StringHashMap(Ownership).init(allocator);
    defer {
        var entries = ownership.iterator();
        while (entries.next()) |entry| allocator.free(entry.key_ptr.*);
        ownership.deinit();
    }
    var budget: ExpansionBudget = .{};
    try setOwnership(&ownership, "owned", .{ .uid = 1000, .gid = 1000 }, &budget);
    try std.testing.expectEqual(@as(u64, 25), budget.owner_manifest_bytes);
    try setOwnership(&ownership, "owned", .{ .uid = 2000, .gid = 2000 }, &budget);
    try std.testing.expectEqual(@as(u64, 25), budget.owner_manifest_bytes);
    try setOwnership(&ownership, "owned", .{ .uid = 0, .gid = 0 }, &budget);
    try std.testing.expectEqual(@as(u64, "RIFTOWN1".len), budget.owner_manifest_bytes);
}

fn tarMtime(header: *const [512]u8) !Io.Timestamp {
    const field = header[136..148];
    var seconds: i96 = undefined;
    if (field[0] & 0x80 != 0) {
        var encoded: i96 = @intCast(field[0] & 0x7f);
        for (field[1..]) |byte| encoded = encoded * 256 + byte;
        seconds = if (field[0] & 0x40 != 0) encoded - (@as(i96, 1) << 95) else encoded;
    } else {
        const text = std.mem.trim(u8, field, " \x00");
        seconds = if (text.len == 0) 0 else std.fmt.parseInt(i96, text, 8) catch return error.InvalidLayerTimestamp;
    }
    const nanoseconds = std.math.mul(i96, seconds, std.time.ns_per_s) catch return error.InvalidLayerTimestamp;
    return .fromNanoseconds(nanoseconds);
}

fn tarHeaderName(header: *const [512]u8, buffer: []u8) ![]const u8 {
    const name = std.mem.sliceTo(header[0..100], 0);
    const prefix = std.mem.sliceTo(header[345..500], 0);
    if (!std.mem.eql(u8, header[257..262], "ustar") or prefix.len == 0) return name;
    if (prefix.len + 1 + name.len > buffer.len) return error.UnsafeLayerPath;
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = '/';
    @memcpy(buffer[prefix.len + 1 ..][0..name.len], name);
    return buffer[0 .. prefix.len + 1 + name.len];
}

fn applyWhiteout(allocator: std.mem.Allocator, io: Io, root: Io.Dir, path: []const u8, name: []const u8) !void {
    var parent = (try openParent(io, root, parentPath(path), false)) orelse return;
    defer parent.close(io);
    if (std.mem.eql(u8, name, ".wh..wh..opq")) {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |child| allocator.free(child);
            names.deinit(allocator);
        }
        var entries = parent.iterate();
        while (try entries.next(io)) |entry| {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        for (names.items) |child| try parent.deleteTree(io, child);
    } else {
        try parent.deleteTree(io, name[4..]);
    }
}

fn openParent(io: Io, root: Io.Dir, path: []const u8, create: bool) !?Io.Dir {
    var current = try root.openDir(io, ".", .{ .follow_symlinks = false, .iterate = true });
    errdefer current.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        const next = current.openDir(io, component, .{ .follow_symlinks = false, .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!create) {
                    current.close(io);
                    return null;
                }
                try current.createDirPath(io, component);
                break :blk try current.openDir(io, component, .{ .follow_symlinks = false, .iterate = true });
            },
            error.NotDir, error.SymLinkLoop => return error.UnsafeLayerPath,
            else => return err,
        };
        current.close(io);
        current = next;
    }
    return current;
}

fn cleanPath(raw: []const u8, buffer: []u8) ![]const u8 {
    if (raw.len == 0 or raw[0] == '/' or raw.len >= buffer.len) return error.UnsafeLayerPath;
    var length: usize = 0;
    var components = std.mem.splitScalar(u8, raw, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..") or std.mem.indexOfScalar(u8, component, 0) != null) return error.UnsafeLayerPath;
        if (length != 0) {
            buffer[length] = '/';
            length += 1;
        }
        if (component.len > buffer.len - length) return error.UnsafeLayerPath;
        @memcpy(buffer[length..][0..component.len], component);
        length += component.len;
    }
    return buffer[0..length];
}

fn checkLink(path: []const u8, target: []const u8) !void {
    if (target.len == 0 or std.mem.indexOfScalar(u8, target, 0) != null) return error.UnsafeLayerLink;
    var depth: usize = if (target[0] == '/') 0 else blk: {
        const parent = parentPath(path);
        if (parent.len == 0) break :blk 0;
        break :blk 1 + std.mem.count(u8, parent, "/");
    };
    var components = std.mem.tokenizeScalar(u8, target, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.UnsafeLayerLink;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

test "applies whiteouts before current layer entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root/sub");
    try temp.dir.writeFile(io, .{ .sub_path = "root/old", .data = "old" });
    try temp.dir.writeFile(io, .{ .sub_path = "root/sub/old", .data = "old" });
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeFileBytes("old", "new", .{});
    try tar.writeFileBytes("sub/new", "new", .{});
    try tar.writeFileBytes(".wh.old", "", .{});
    try tar.writeFileBytes("sub/.wh..wh..opq", "", .{});
    var output_blob = try temp.dir.createFile(io, "layer.tar", .{});
    defer output_blob.close(io);
    try output_blob.writeStreamingAll(io, archive.written());
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);

    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    const old = try root.readFileAlloc(io, "old", allocator, .limited(10));
    defer allocator.free(old);
    try std.testing.expectEqualStrings("new", old);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "sub/old", .{}));
    const newer = try root.readFileAlloc(io, "sub/new", allocator, .limited(10));
    defer allocator.free(newer);
    try std.testing.expectEqualStrings("new", newer);
}

test "rejects aggregate decompressed layer bytes before extracting entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeFileBytes("must-not-exist", "payload", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    var ownership = std.StringHashMap(Ownership).init(arena.allocator());
    defer ownership.deinit();
    var budget: ExpansionBudget = .{ .entries = max_image_layer_bytes - 1 };

    try std.testing.expectError(error.ImageLayersTooLarge, apply(
        allocator,
        io,
        root,
        blob,
        "application/vnd.oci.image.layer.v1.tar",
        &directory_metadata,
        &ownership,
        &budget,
    ));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "must-not-exist", .{ .follow_symlinks = false }));
}

test "applies final directory modes after all layers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    var ownership = std.StringHashMap(Ownership).init(arena.allocator());
    defer ownership.deinit();

    var first_archive: Io.Writer.Allocating = .init(allocator);
    defer first_archive.deinit();
    var first_tar: std.tar.Writer = .{ .underlying_writer = &first_archive.writer };
    try first_tar.writeDir("tmp", .{ .mode = 0o1777, .mtime = 1_600_000_000 });
    try temp.dir.writeFile(io, .{ .sub_path = "first.tar", .data = first_archive.written() });
    const first_blob = try temp.dir.openFile(io, "first.tar", .{ .mode = .read_only });
    defer first_blob.close(io);
    var budget: ExpansionBudget = .{};
    try apply(allocator, io, root, first_blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata, &ownership, &budget);

    var second_archive: Io.Writer.Allocating = .init(allocator);
    defer second_archive.deinit();
    var second_tar: std.tar.Writer = .{ .underlying_writer = &second_archive.writer };
    try second_tar.writeFileBytes("tmp/probe", "ok", .{ .mtime = 1_650_000_000 });
    try second_tar.writeLink("tmp/link", "probe", .{ .mtime = 1_550_000_000 });
    try temp.dir.writeFile(io, .{ .sub_path = "second.tar", .data = second_archive.written() });
    const second_blob = try temp.dir.openFile(io, "second.tar", .{ .mode = .read_only });
    defer second_blob.close(io);
    try apply(allocator, io, root, second_blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata, &ownership, &budget);

    try applyDirectoryMetadata(io, root, &directory_metadata);
    const stat = try root.statFile(io, "tmp", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o1777), @as(u32, @intCast(stat.permissions.toMode() & 0o7777)));
    try std.testing.expectEqual(@as(i64, 1_600_000_000), stat.mtime.toSeconds());
    const file_stat = try root.statFile(io, "tmp/probe", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(i64, 1_650_000_000), file_stat.mtime.toSeconds());
    const link_stat = try root.statFile(io, "tmp/link", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(i64, 1_550_000_000), link_stat.mtime.toSeconds());
    const contents = try root.readFileAlloc(io, "tmp/probe", allocator, .limited(4));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("ok", contents);
}

test "applies restrictive parent directory metadata after children" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena_allocator);
    defer directory_metadata.deinit();

    var parent_path: []const u8 = undefined;
    var child_path: []const u8 = undefined;
    var found_parent_first = false;
    for (0..512) |candidate| {
        parent_path = try std.fmt.allocPrint(arena_allocator, "locked-{d}", .{candidate});
        child_path = try std.fmt.allocPrint(arena_allocator, "{s}/child", .{parent_path});
        try directory_metadata.put(parent_path, .{ .mode = 0, .mtime = .fromNanoseconds(11 * std.time.ns_per_s) });
        try directory_metadata.put(child_path, .{ .mode = 0o700, .mtime = .fromNanoseconds(22 * std.time.ns_per_s) });

        var entries = directory_metadata.iterator();
        const first = entries.next().?.key_ptr.*;
        if (std.mem.eql(u8, first, parent_path)) {
            found_parent_first = true;
            break;
        }
        directory_metadata.clearRetainingCapacity();
    }
    try std.testing.expect(found_parent_first);

    try root.createDirPath(io, child_path);
    var parent = try root.openDir(io, parent_path, .{});
    defer parent.close(io);
    defer parent.setPermissions(io, .fromMode(0o700)) catch {};

    try applyDirectoryMetadata(io, root, &directory_metadata);
    const parent_stat = try root.statFile(io, parent_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(parent_stat.permissions.toMode() & 0o7777)));
    try std.testing.expectEqual(@as(i64, 11), parent_stat.mtime.toSeconds());

    try parent.setPermissions(io, .fromMode(0o700));
    const child_stat = try root.statFile(io, child_path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(child_stat.permissions.toMode() & 0o7777)));
    try std.testing.expectEqual(@as(i64, 22), child_stat.mtime.toSeconds());
}

test "honors local PAX path and size overrides and rejects unsafe overrides" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    const component = try allocator.alloc(u8, 160);
    defer allocator.free(component);
    @memset(component, 'p');
    const long_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ component, component });
    defer allocator.free(long_path);

    var valid_archive: Io.Writer.Allocating = .init(allocator);
    defer valid_archive.deinit();
    var valid_tar: std.tar.Writer = .{ .underlying_writer = &valid_archive.writer };
    try writeTestPaxHeader(allocator, &valid_archive, &valid_tar, &.{
        .{ .key = "path", .value = long_path },
        .{ .key = "size", .value = "5" },
    });
    const file_header_offset = valid_archive.written().len;
    try valid_tar.writeFileBytes("fallback", "hello", .{});
    const valid_bytes = @constCast(valid_archive.written());
    @memset(valid_bytes[file_header_offset + 124 .. file_header_offset + 136], 0);
    updateTestTarChecksum(valid_bytes[file_header_offset..][0..512]);
    try temp.dir.writeFile(io, .{ .sub_path = "valid-pax.tar", .data = valid_archive.written() });
    const valid_blob = try temp.dir.openFile(io, "valid-pax.tar", .{ .mode = .read_only });
    defer valid_blob.close(io);
    try validateUncompressedTar(allocator, io, valid_blob);
    try applyOne(allocator, io, root, valid_blob, "application/vnd.oci.image.layer.v1.tar");

    const contents = try root.readFileAlloc(io, long_path, allocator, .limited(8));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("hello", contents);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "fallback", .{}));

    var unsafe_path_archive: Io.Writer.Allocating = .init(allocator);
    defer unsafe_path_archive.deinit();
    var unsafe_path_tar: std.tar.Writer = .{ .underlying_writer = &unsafe_path_archive.writer };
    try writeTestPaxHeader(allocator, &unsafe_path_archive, &unsafe_path_tar, &.{.{ .key = "path", .value = "../outside" }});
    try unsafe_path_tar.writeFileBytes("fallback", "blocked", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe-path.tar", .data = unsafe_path_archive.written() });
    const unsafe_path_blob = try temp.dir.openFile(io, "unsafe-path.tar", .{ .mode = .read_only });
    defer unsafe_path_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, unsafe_path_blob, "application/vnd.oci.image.layer.v1.tar"));
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(io, "outside", .{}));

    var unsafe_link_archive: Io.Writer.Allocating = .init(allocator);
    defer unsafe_link_archive.deinit();
    var unsafe_link_tar: std.tar.Writer = .{ .underlying_writer = &unsafe_link_archive.writer };
    try writeTestPaxHeader(allocator, &unsafe_link_archive, &unsafe_link_tar, &.{.{ .key = "linkpath", .value = "../../outside" }});
    try unsafe_link_tar.writeLink("unsafe-link", "inside", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe-link.tar", .data = unsafe_link_archive.written() });
    const unsafe_link_blob = try temp.dir.openFile(io, "unsafe-link.tar", .{ .mode = .read_only });
    defer unsafe_link_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerLink, applyOne(allocator, io, root, unsafe_link_blob, "application/vnd.oci.image.layer.v1.tar"));
    try std.testing.expectError(error.UnsafeLayerLink, validateUncompressedTar(allocator, io, unsafe_link_blob));
}

test "honors global PAX path, linkpath, and size with local precedence and clearing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "global-target", .data = "global" });
    try root.writeFile(io, .{ .sub_path = "fallback-target", .data = "fallback" });

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{
        .{ .key = "path", .value = "global-name" },
        .{ .key = "size", .value = "5" },
    });
    const global_header_offset = archive.written().len;
    try tar.writeFileBytes("fallback", "hello", .{});
    const global_bytes = @constCast(archive.written());
    @memset(global_bytes[global_header_offset + 124 .. global_header_offset + 136], 0);
    updateTestTarChecksum(global_bytes[global_header_offset..][0..512]);

    try writeTestPaxHeader(allocator, &archive, &tar, &.{
        .{ .key = "path", .value = "local-name" },
        .{ .key = "size", .value = "2" },
    });
    try tar.writeFileBytes("fallback-local", "abc", .{});
    try tar.writeFileBytes("fallback-inherited", "again", .{});

    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{
        .{ .key = "path", .value = "" },
        .{ .key = "size", .value = "" },
    });
    try tar.writeFileBytes("reset-name", "r", .{});
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{.{ .key = "linkpath", .value = "global-target" }});
    try tar.writeLink("global-link", "fallback-target", .{});
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{.{ .key = "linkpath", .value = "" }});
    try tar.writeLink("reset-link", "fallback-target", .{});

    try temp.dir.writeFile(io, .{ .sub_path = "global-pax.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "global-pax.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try validateUncompressedTar(allocator, io, blob);
    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");

    const global_contents = try root.readFileAlloc(io, "global-name", allocator, .limited(8));
    defer allocator.free(global_contents);
    try std.testing.expectEqualStrings("again", global_contents);
    const local_contents = try root.readFileAlloc(io, "local-name", allocator, .limited(8));
    defer allocator.free(local_contents);
    try std.testing.expectEqualStrings("ab", local_contents);
    const reset_contents = try root.readFileAlloc(io, "reset-name", allocator, .limited(8));
    defer allocator.free(reset_contents);
    try std.testing.expectEqualStrings("r", reset_contents);
    const global_link_contents = try root.readFileAlloc(io, "global-link", allocator, .limited(8));
    defer allocator.free(global_link_contents);
    try std.testing.expectEqualStrings("global", global_link_contents);
    const reset_link_contents = try root.readFileAlloc(io, "reset-link", allocator, .limited(16));
    defer allocator.free(reset_link_contents);
    try std.testing.expectEqualStrings("fallback", reset_link_contents);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "fallback", .{}));
}

test "rejects unsafe global PAX paths and link targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var unsafe_path_archive: Io.Writer.Allocating = .init(allocator);
    defer unsafe_path_archive.deinit();
    var unsafe_path_tar: std.tar.Writer = .{ .underlying_writer = &unsafe_path_archive.writer };
    try writeTestPaxHeaderKind(allocator, &unsafe_path_archive, &unsafe_path_tar, 'g', &.{.{ .key = "path", .value = "../outside" }});
    try unsafe_path_tar.writeFileBytes("fallback", "blocked", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe-global-path.tar", .data = unsafe_path_archive.written() });
    const unsafe_path_blob = try temp.dir.openFile(io, "unsafe-global-path.tar", .{ .mode = .read_only });
    defer unsafe_path_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, unsafe_path_blob, "application/vnd.oci.image.layer.v1.tar"));
    try std.testing.expectError(error.FileNotFound, temp.dir.statFile(io, "outside", .{}));

    var unsafe_link_archive: Io.Writer.Allocating = .init(allocator);
    defer unsafe_link_archive.deinit();
    var unsafe_link_tar: std.tar.Writer = .{ .underlying_writer = &unsafe_link_archive.writer };
    try writeTestPaxHeaderKind(allocator, &unsafe_link_archive, &unsafe_link_tar, 'g', &.{.{ .key = "linkpath", .value = "../../outside" }});
    try unsafe_link_tar.writeLink("unsafe-link", "inside", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe-global-link.tar", .data = unsafe_link_archive.written() });
    const unsafe_link_blob = try temp.dir.openFile(io, "unsafe-global-link.tar", .{ .mode = .read_only });
    defer unsafe_link_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerLink, applyOne(allocator, io, root, unsafe_link_blob, "application/vnd.oci.image.layer.v1.tar"));
    try std.testing.expectError(error.UnsafeLayerLink, validateUncompressedTar(allocator, io, unsafe_link_blob));
}

test "honors local and global PAX modification times" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{.{ .key = "mtime", .value = "1234.125" }});
    try tar.writeFileBytes("global", "g", .{ .mtime = 1 });
    try tar.writeFileBytes("global-inherited", "gi", .{ .mtime = 3 });
    try writeTestPaxHeader(allocator, &archive, &tar, &.{.{ .key = "mtime", .value = "-1.75" }});
    try tar.writeFileBytes("local", "l", .{ .mtime = 2 });
    try writeTestPaxHeader(allocator, &archive, &tar, &.{.{ .key = "mtime", .value = "" }});
    try tar.writeFileBytes("base", "b", .{ .mtime = 42 });
    try writeTestPaxHeader(allocator, &archive, &tar, &.{.{ .key = "mtime", .value = "8.25" }});
    try tar.writeDir("dated-dir", .{ .mtime = 3 });
    try writeTestPaxHeader(allocator, &archive, &tar, &.{.{ .key = "mtime", .value = "-0.5" }});
    try tar.writeLink("dated-link", "global", .{ .mtime = 4 });
    try temp.dir.writeFile(io, .{ .sub_path = "pax-mtime.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "pax-mtime.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");

    const global_stat = try root.statFile(io, "global", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(1_234_125_000_000), global_stat.mtime);
    const inherited_stat = try root.statFile(io, "global-inherited", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(1_234_125_000_000), inherited_stat.mtime);
    const local_stat = try root.statFile(io, "local", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(-1_750_000_000), local_stat.mtime);
    const base_stat = try root.statFile(io, "base", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(42_000_000_000), base_stat.mtime);
    const directory_stat = try root.statFile(io, "dated-dir", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(8_250_000_000), directory_stat.mtime);
    const link_stat = try root.statFile(io, "dated-link", .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(-500_000_000), link_stat.mtime);
    try std.testing.expectEqual(Io.Timestamp.fromNanoseconds(7_123_456_789), try parsePaxMtime("7.1234567899"));
    try std.testing.expectError(error.InvalidLayerTimestamp, parsePaxMtime("7.-5"));
}

test "tracks tar and PAX ownership through overrides and whiteouts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    var ownership = std.StringHashMap(Ownership).init(arena.allocator());
    defer ownership.deinit();
    var budget: ExpansionBudget = .{};

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{
        .{ .key = "uid", .value = "1234" },
        .{ .key = "gid", .value = "2345" },
    });
    try tar.writeDir(".", .{});
    try tar.writeFileBytes("global-file", "g", .{});
    try writeTestPaxHeader(allocator, &archive, &tar, &.{
        .{ .key = "uid", .value = "7" },
        .{ .key = "gid", .value = "8" },
    });
    try tar.writeFileBytes("local-file", "l", .{});
    try writeTestPaxHeader(allocator, &archive, &tar, &.{
        .{ .key = "uid", .value = "" },
        .{ .key = "gid", .value = "" },
    });
    try tar.writeFileBytes("reset-file", "r", .{});
    try tar.writeDir("owned-dir", .{});
    try tar.writeFileBytes("owned-dir/child", "c", .{});
    try writeTestHardlink(&archive.writer, "owned-dir/hardlink", "owned-dir/child");
    try writeTestPaxHeaderKind(allocator, &archive, &tar, 'g', &.{
        .{ .key = "uid", .value = "" },
        .{ .key = "gid", .value = "" },
    });
    const header_offset = archive.written().len;
    try tar.writeFileBytes("header-file", "h", .{});
    const archive_bytes = @constCast(archive.written());
    setTestTarId(archive_bytes[header_offset + 108 ..][0..8], 4321);
    setTestTarId(archive_bytes[header_offset + 116 ..][0..8], 8765);
    updateTestTarChecksum(archive_bytes[header_offset..][0..512]);
    const base256_offset = archive.written().len;
    try tar.writeFileBytes("base256-file", "b", .{});
    const base256_bytes = @constCast(archive.written());
    setTestTarIdBase256(base256_bytes[base256_offset + 108 ..][0..8], 3_000_000);
    setTestTarIdBase256(base256_bytes[base256_offset + 116 ..][0..8], 4_000_000);
    updateTestTarChecksum(base256_bytes[base256_offset..][0..512]);
    try temp.dir.writeFile(io, .{ .sub_path = "ownership.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "ownership.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try apply(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata, &ownership, &budget);

    try std.testing.expectEqual(Ownership{ .uid = 1234, .gid = 2345 }, ownership.get("global-file").?);
    try std.testing.expectEqual(Ownership{ .uid = 1234, .gid = 2345 }, ownership.get("").?);
    try std.testing.expectEqual(Ownership{ .uid = 7, .gid = 8 }, ownership.get("local-file").?);
    try std.testing.expect(!ownership.contains("reset-file"));
    try std.testing.expectEqual(Ownership{ .uid = 1234, .gid = 2345 }, ownership.get("owned-dir").?);
    try std.testing.expectEqual(Ownership{ .uid = 1234, .gid = 2345 }, ownership.get("owned-dir/hardlink").?);
    try std.testing.expectEqual(Ownership{ .uid = 4321, .gid = 8765 }, ownership.get("header-file").?);
    try std.testing.expectEqual(Ownership{ .uid = 3_000_000, .gid = 4_000_000 }, ownership.get("base256-file").?);
    try std.testing.expectError(error.PaxInvalidAttribute, parsePaxId("4294967295"));

    var whiteouts: Io.Writer.Allocating = .init(allocator);
    defer whiteouts.deinit();
    var whiteout_tar: std.tar.Writer = .{ .underlying_writer = &whiteouts.writer };
    try whiteout_tar.writeFileBytes(".wh.global-file", "", .{});
    try whiteout_tar.writeFileBytes("owned-dir/.wh..wh..opq", "", .{});
    try temp.dir.writeFile(io, .{ .sub_path = "whiteouts.tar", .data = whiteouts.written() });
    const whiteout_blob = try temp.dir.openFile(io, "whiteouts.tar", .{ .mode = .read_only });
    defer whiteout_blob.close(io);
    try apply(allocator, io, root, whiteout_blob, "application/vnd.oci.image.layer.v1.tar", &directory_metadata, &ownership, &budget);

    try std.testing.expect(!ownership.contains("global-file"));
    try std.testing.expect(ownership.contains("owned-dir"));
    try std.testing.expect(!ownership.contains("owned-dir/child"));
    try std.testing.expect(!ownership.contains("owned-dir/hardlink"));
}

test "rejects paths through symlink parents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeLink("escape", "/tmp", .{});
    try tar.writeFileBytes("escape/payload", "bad", .{});
    var output_blob = try temp.dir.createFile(io, "layer.tar", .{});
    defer output_blob.close(io);
    try output_blob.writeStreamingAll(io, archive.written());
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar"));
    var path_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.UnsafeLayerPath, cleanPath("../host", &path_buffer));
    try std.testing.expectError(error.UnsafeLayerLink, checkLink("bin/tool", "../../host"));
}

test "applies hardlinks and rejects targets outside the root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeFileBytes("source", "shared", .{});
    try writeTestHardlink(&archive.writer, "linked", "source");
    try temp.dir.writeFile(io, .{ .sub_path = "layer.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "layer.tar", .{ .mode = .read_only });
    defer blob.close(io);
    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    const contents = try root.readFileAlloc(io, "linked", allocator, .limited(16));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("shared", contents);
    const source = try root.openFile(io, "source", .{ .mode = .read_write });
    defer source.close(io);
    try source.writeStreamingAll(io, "Shared");
    const linked_after_write = try root.readFileAlloc(io, "linked", allocator, .limited(16));
    defer allocator.free(linked_after_write);
    try std.testing.expectEqualStrings("Shared", linked_after_write);

    var unsafe: Io.Writer.Allocating = .init(allocator);
    defer unsafe.deinit();
    try writeTestHardlink(&unsafe.writer, "escape", "../outside");
    try temp.dir.writeFile(io, .{ .sub_path = "unsafe.tar", .data = unsafe.written() });
    const unsafe_blob = try temp.dir.openFile(io, "unsafe.tar", .{ .mode = .read_only });
    defer unsafe_blob.close(io);
    try std.testing.expectError(error.UnsafeLayerPath, applyOne(allocator, io, root, unsafe_blob, "application/vnd.oci.image.layer.v1.tar"));
}

test "ignores image device nodes under runtime-managed /dev" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &archive.writer };
    try tar.writeDir("dev", .{});
    try writeTestSpecial(&archive.writer, "dev/null", '3');
    try writeTestSpecial(&archive.writer, "dev/sda", '4');
    try temp.dir.writeFile(io, .{ .sub_path = "devices.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "devices.tar", .{ .mode = .read_only });
    defer blob.close(io);

    try applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar");
    try std.testing.expectEqual(.directory, (try root.statFile(io, "dev", .{ .follow_symlinks = false })).kind);
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dev/null", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, root.statFile(io, "dev/sda", .{ .follow_symlinks = false }));
}

test "rejects image device nodes outside runtime-managed /dev" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root");
    var root = try temp.dir.openDir(io, "root", .{});
    defer root.close(io);

    var archive: Io.Writer.Allocating = .init(allocator);
    defer archive.deinit();
    try writeTestSpecial(&archive.writer, "etc/device", '3');
    try temp.dir.writeFile(io, .{ .sub_path = "device.tar", .data = archive.written() });
    const blob = try temp.dir.openFile(io, "device.tar", .{ .mode = .read_only });
    defer blob.close(io);

    try std.testing.expectError(error.UnsupportedLayerSpecialFile, applyOne(allocator, io, root, blob, "application/vnd.oci.image.layer.v1.tar"));
}

fn applyOne(allocator: std.mem.Allocator, io: Io, root: Io.Dir, blob: Io.File, media_type: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var directory_metadata = std.StringHashMap(DirectoryMetadata).init(arena.allocator());
    defer directory_metadata.deinit();
    var ownership = std.StringHashMap(Ownership).init(arena.allocator());
    defer ownership.deinit();
    var budget: ExpansionBudget = .{};
    try apply(allocator, io, root, blob, media_type, &directory_metadata, &ownership, &budget);
    try applyDirectoryMetadata(io, root, &directory_metadata);
}

fn writeTestHardlink(writer: *Io.Writer, name: []const u8, target: []const u8) !void {
    var header = std.tar.Writer.Header.init(.regular);
    try header.setPath("", name);
    try header.setLinkname(target);
    const bytes = std.mem.asBytes(&header);
    bytes[156] = '1';
    updateTestTarChecksum(bytes);
    try writer.writeAll(bytes);
}

fn setTestTarId(field: []u8, value: u32) void {
    var text: [16]u8 = undefined;
    const encoded = std.fmt.bufPrint(&text, "{o}", .{value}) catch unreachable;
    @memset(field, '0');
    @memcpy(field[field.len - encoded.len - 1 ..][0..encoded.len], encoded);
    field[field.len - 1] = 0;
}

fn setTestTarIdBase256(field: []u8, value: u32) void {
    @memset(field, 0);
    var remaining: u64 = value;
    for (0..field.len) |offset| {
        const index = field.len - offset - 1;
        field[index] = @truncate(remaining);
        remaining >>= 8;
    }
    std.debug.assert(remaining == 0);
    field[0] |= 0x80;
}

fn writeTestSpecial(writer: *Io.Writer, name: []const u8, kind: u8) !void {
    var header = std.tar.Writer.Header.init(.regular);
    try header.setPath("", name);
    const bytes = std.mem.asBytes(&header);
    bytes[156] = kind;
    updateTestTarChecksum(bytes);
    try writer.writeAll(bytes);
}

const TestPaxAttribute = struct { key: []const u8, value: []const u8 };

fn writeTestPaxHeader(allocator: std.mem.Allocator, archive: *Io.Writer.Allocating, tar: *std.tar.Writer, attributes: []const TestPaxAttribute) !void {
    return writeTestPaxHeaderKind(allocator, archive, tar, 'x', attributes);
}

fn writeTestPaxHeaderKind(allocator: std.mem.Allocator, archive: *Io.Writer.Allocating, tar: *std.tar.Writer, kind: u8, attributes: []const TestPaxAttribute) !void {
    var record: Io.Writer.Allocating = .init(allocator);
    defer record.deinit();
    for (attributes) |attribute| try writeTestPaxRecord(&record.writer, attribute.key, attribute.value);

    const header_offset = archive.written().len;
    try tar.writeFileBytes("PaxHeaders.0/entry", record.written(), .{});
    const bytes = @constCast(archive.written());
    bytes[header_offset + 156] = kind;
    updateTestTarChecksum(bytes[header_offset..][0..512]);
}

fn writeTestPaxRecord(writer: *Io.Writer, key: []const u8, value: []const u8) !void {
    const without_length = key.len + value.len + 3;
    var length = without_length + 1;
    while (true) {
        var digits: usize = 1;
        var remaining = length;
        while (remaining >= 10) : (remaining /= 10) digits += 1;
        const next = without_length + digits;
        if (next == length) break;
        length = next;
    }
    try writer.print("{d} {s}={s}\n", .{ length, key, value });
}

fn updateTestTarChecksum(header: []u8) void {
    @memset(header[148..156], ' ');
    var checksum: usize = 0;
    for (header) |byte| checksum += byte;
    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum}) catch unreachable;
    header[154] = 0;
}
