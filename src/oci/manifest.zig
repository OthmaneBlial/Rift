const std = @import("std");
const reference = @import("reference.zig");

pub const ParseError = std.json.ParseError(std.json.Scanner) || error{
    InvalidManifest,
    NoMatchingPlatform,
};

pub const Platform = struct {
    architecture: []const u8,
    os: []const u8,
    variant: ?[]const u8 = null,
};

pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    platform: ?Platform = null,
};

pub const Index = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    manifests: []const Descriptor,
};

pub const Manifest = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    config: Descriptor,
    layers: []const Descriptor,
};

pub const Target = struct {
    os: []const u8,
    architecture: []const u8,
    variant: ?[]const u8 = null,
};

pub fn parseIndex(allocator: std.mem.Allocator, body: []const u8) ParseError!Index {
    const index = try std.json.parseFromSliceLeaky(Index, allocator, body, .{ .ignore_unknown_fields = true });
    if (index.schemaVersion != 2 or index.manifests.len == 0) return error.InvalidManifest;
    if (index.mediaType) |media_type| if (!isIndexMediaType(media_type)) return error.InvalidManifest;
    for (index.manifests) |descriptor| {
        if (!validDescriptor(descriptor)) return error.InvalidManifest;
    }
    return index;
}

pub fn parseManifest(allocator: std.mem.Allocator, body: []const u8) ParseError!Manifest {
    const manifest = try std.json.parseFromSliceLeaky(Manifest, allocator, body, .{ .ignore_unknown_fields = true });
    if (manifest.schemaVersion != 2) return error.InvalidManifest;
    if (manifest.mediaType) |media_type| if (!isManifestMediaType(media_type)) return error.InvalidManifest;
    if (!validDescriptor(manifest.config) or !isImageConfigMediaType(manifest.config.mediaType)) return error.InvalidManifest;
    for (manifest.layers) |descriptor| {
        if (!validDescriptor(descriptor) or !isLayerMediaType(descriptor.mediaType)) return error.InvalidManifest;
    }
    return manifest;
}

pub fn selectPlatform(index: Index, target: Target) ParseError!Descriptor {
    var fallback: ?Descriptor = null;
    for (index.manifests) |descriptor| {
        const platform = descriptor.platform orelse continue;
        if (!std.mem.eql(u8, platform.os, target.os) or !std.mem.eql(u8, platform.architecture, target.architecture)) continue;
        if (!isManifestMediaType(descriptor.mediaType) and !isIndexMediaType(descriptor.mediaType)) continue;

        if (target.variant) |variant| {
            if (platform.variant) |candidate| {
                if (std.mem.eql(u8, candidate, variant)) return descriptor;
            } else if (fallback == null) {
                fallback = descriptor;
            }
        } else {
            return descriptor;
        }
    }
    return fallback orelse error.NoMatchingPlatform;
}

fn validDescriptor(descriptor: Descriptor) bool {
    return descriptor.mediaType.len != 0 and reference.isValidDigest(descriptor.digest);
}

pub fn isIndexMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.index.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.distribution.manifest.list.v2+json");
}

pub fn isManifestMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.manifest.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.distribution.manifest.v2+json");
}

fn isImageConfigMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.config.v1+json") or
        std.mem.eql(u8, media_type, "application/vnd.docker.container.image.v1+json");
}

fn isLayerMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+gzip") or
        std.mem.eql(u8, media_type, "application/vnd.oci.image.layer.v1.tar+zstd") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar.gzip") or
        std.mem.eql(u8, media_type, "application/vnd.docker.image.rootfs.diff.tar");
}

test "selects the requested platform and skips unrelated entries" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
        \\{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42,"platform":{"os":"linux","architecture":"amd64"}},
        \\{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":42,"platform":{"os":"linux","architecture":"arm64","variant":"v8"}},
        \\{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":42,"platform":{"os":"unknown","architecture":"unknown"}}]}
    ;
    const index = try parseIndex(arena.allocator(), body);
    const selected = try selectPlatform(index, .{ .os = "linux", .architecture = "arm64", .variant = "v8" });
    try std.testing.expectEqualStrings("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", selected.digest);
}

test "falls back to an unqualified architecture variant" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body =
        \\{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42,"platform":{"os":"linux","architecture":"arm64"}}]}
    ;
    const index = try parseIndex(arena.allocator(), body);
    const selected = try selectPlatform(index, .{ .os = "linux", .architecture = "arm64", .variant = "v8" });
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", selected.digest);
}

test "rejects indexes without the requested platform" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body =
        \\{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42,"platform":{"os":"linux","architecture":"amd64"}}]}
    ;
    const index = try parseIndex(arena.allocator(), body);
    try std.testing.expectError(error.NoMatchingPlatform, selectPlatform(index, .{ .os = "linux", .architecture = "arm64" }));
}

test "parses OCI and Docker image manifests while ignoring extensions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","artifactType":"unused","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":3}]}
    ;
    const manifest = try parseManifest(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 1), manifest.layers.len);
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", manifest.config.digest);
}

test "rejects invalid manifest descriptors" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body =
        \\{"schemaVersion":2,"config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:bad","size":2},"layers":[]}
    ;
    try std.testing.expectError(error.InvalidManifest, parseManifest(arena.allocator(), body));
}
