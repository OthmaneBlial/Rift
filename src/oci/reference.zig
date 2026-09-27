const std = @import("std");

pub const ParseError = std.mem.Allocator.Error || error{InvalidReference};

pub const Reference = struct {
    registry: []const u8,
    repository: []const u8,
    tag: ?[]const u8,
    digest: ?[]const u8,

    pub fn deinit(reference: *Reference, allocator: std.mem.Allocator) void {
        allocator.free(reference.registry);
        allocator.free(reference.repository);
        if (reference.tag) |tag| allocator.free(tag);
        if (reference.digest) |digest| allocator.free(digest);
        reference.* = undefined;
    }

    pub fn formatAlloc(reference: Reference, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        if (reference.digest) |digest| {
            return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ reference.registry, reference.repository, digest });
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}:{s}", .{ reference.registry, reference.repository, reference.tag.? });
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Reference {
    if (input.len == 0) return error.InvalidReference;

    var name_and_tag = input;
    var digest: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, input, '@')) |at| {
        if (std.mem.lastIndexOfScalar(u8, input, '@') != at) return error.InvalidReference;
        const value = input[at + 1 ..];
        if (!validDigest(value)) return error.InvalidReference;
        digest = value;
        name_and_tag = input[0..at];
    }

    var name = name_and_tag;
    var tag: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, name_and_tag, ':')) |colon| {
        const slash = std.mem.lastIndexOfScalar(u8, name_and_tag, '/') orelse 0;
        if (colon > slash) {
            const value = name_and_tag[colon + 1 ..];
            if (!validTag(value)) return error.InvalidReference;
            tag = value;
            name = name_and_tag[0..colon];
        }
    }
    if (name.len == 0) return error.InvalidReference;

    var registry: []const u8 = "registry-1.docker.io";
    var repository = name;
    var is_docker_hub = true;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const first = name[0..slash];
        if (looksLikeRegistry(first)) {
            if (!validRegistry(first)) return error.InvalidReference;
            registry = normalizeRegistry(first);
            repository = name[slash + 1 ..];
            is_docker_hub = std.mem.eql(u8, registry, "docker.io") or
                std.mem.eql(u8, registry, "index.docker.io") or
                std.mem.eql(u8, registry, "registry-1.docker.io");
        }
    }

    if (repository.len == 0) return error.InvalidReference;
    if (is_docker_hub and std.mem.indexOfScalar(u8, repository, '/') == null) {
        repository = try std.fmt.allocPrint(allocator, "library/{s}", .{repository});
    } else {
        repository = try allocator.dupe(u8, repository);
    }
    errdefer allocator.free(repository);

    if (!validRepository(repository) or repository.len + registry.len + 1 > 255) return error.InvalidReference;

    const owned_registry = try allocator.dupe(u8, registry);
    errdefer allocator.free(owned_registry);
    const owned_tag = if (tag) |value| try allocator.dupe(u8, value) else if (digest == null) try allocator.dupe(u8, "latest") else null;
    errdefer if (owned_tag) |value| allocator.free(value);
    const owned_digest = if (digest) |value| try allocator.dupe(u8, value) else null;

    return .{
        .registry = owned_registry,
        .repository = repository,
        .tag = owned_tag,
        .digest = owned_digest,
    };
}

fn looksLikeRegistry(first: []const u8) bool {
    return std.mem.indexOfAny(u8, first, ".:") != null or std.ascii.eqlIgnoreCase(first, "localhost");
}

fn normalizeRegistry(registry: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(registry, "docker.io") or
        std.ascii.eqlIgnoreCase(registry, "index.docker.io") or
        std.ascii.eqlIgnoreCase(registry, "registry-1.docker.io"))
    {
        return "registry-1.docker.io";
    }
    return registry;
}

fn validRegistry(registry: []const u8) bool {
    if (registry.len == 0) return false;
    const colon = std.mem.indexOfScalar(u8, registry, ':');
    const host = if (colon) |index| registry[0..index] else registry;
    if (colon) |index| {
        if (std.mem.indexOfScalarPos(u8, registry, index + 1, ':') != null) return false;
        const port = registry[index + 1 ..];
        if (port.len == 0) return false;
        for (port) |char| if (!std.ascii.isDigit(char)) return false;
        const number = std.fmt.parseInt(u16, port, 10) catch return false;
        if (number == 0) return false;
    }
    if (host.len == 0 or host.len > 253) return false;

    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
        }
    }
    return true;
}

fn validRepository(repository: []const u8) bool {
    if (repository.len == 0 or repository.len > 255) return false;
    var components = std.mem.splitScalar(u8, repository, '/');
    while (components.next()) |component| {
        if (!validNameComponent(component)) return false;
    }
    return true;
}

fn validNameComponent(component: []const u8) bool {
    var index: usize = 0;
    if (!consumeNameRun(component, &index)) return false;

    while (index < component.len) {
        switch (component[index]) {
            '.' => index += 1,
            '_' => {
                index += 1;
                if (index < component.len and component[index] == '_') index += 1;
                if (index < component.len and component[index] == '_') return false;
            },
            '-' => {
                while (index < component.len and component[index] == '-') : (index += 1) {}
            },
            else => return false,
        }
        if (!consumeNameRun(component, &index)) return false;
    }
    return true;
}

fn consumeNameRun(value: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < value.len) : (index.* += 1) {
        const char = value[index.*];
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char)) break;
    }
    return index.* > start;
}

fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 128) return false;
    if (!std.ascii.isAlphanumeric(tag[0]) and tag[0] != '_') return false;
    for (tag[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '.' and char != '-') return false;
    }
    return true;
}

fn validDigest(digest: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, digest, ':') orelse return false;
    if (colon == 0 or colon + 1 == digest.len or std.mem.indexOfScalarPos(u8, digest, colon + 1, ':') != null) return false;

    var separator_expected = false;
    for (digest[0..colon]) |char| {
        if (std.ascii.isLower(char) or std.ascii.isDigit(char)) {
            separator_expected = false;
        } else if ((char == '+' or char == '.' or char == '_' or char == '-') and !separator_expected) {
            separator_expected = true;
        } else {
            return false;
        }
    }
    if (separator_expected) return false;

    for (digest[colon + 1 ..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '=' and char != '_' and char != '-') return false;
    }
    if (std.mem.eql(u8, digest[0..colon], "sha256")) {
        if (digest.len - colon - 1 != 64) return false;
        for (digest[colon + 1 ..]) |char| {
            if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
        }
    }
    return true;
}

test "normalizes Docker Hub image references" {
    const allocator = std.testing.allocator;
    var image = try parse(allocator, "alpine");
    defer image.deinit(allocator);
    try std.testing.expectEqualStrings("registry-1.docker.io", image.registry);
    try std.testing.expectEqualStrings("library/alpine", image.repository);
    try std.testing.expectEqualStrings("latest", image.tag.?);
}

test "normalizes explicit Docker Hub references and keeps tags" {
    const allocator = std.testing.allocator;
    var image = try parse(allocator, "docker.io/nginx:1.29");
    defer image.deinit(allocator);
    try std.testing.expectEqualStrings("registry-1.docker.io", image.registry);
    try std.testing.expectEqualStrings("library/nginx", image.repository);
    try std.testing.expectEqualStrings("1.29", image.tag.?);
}

test "preserves registry ports and digest references" {
    const allocator = std.testing.allocator;
    var image = try parse(allocator, "localhost:5000/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    defer image.deinit(allocator);
    try std.testing.expectEqualStrings("localhost:5000", image.registry);
    try std.testing.expectEqualStrings("team/app", image.repository);
    try std.testing.expectEqualStrings("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", image.digest.?);
    try std.testing.expect(image.tag == null);
}

test "rejects malformed image references" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "Upper/image", "repo/", "name:", "host:0/repo", "host:65536/repo", "repo@sha256:ABCDEF" }) |invalid| {
        try std.testing.expectError(error.InvalidReference, parse(allocator, invalid));
    }
}

test "accepts standard repository separators and 128-character tags" {
    const allocator = std.testing.allocator;
    const tag = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const input = try std.fmt.allocPrint(allocator, "registry.example.com/team/name__part:{s}", .{tag});
    defer allocator.free(input);
    var image = try parse(allocator, input);
    defer image.deinit(allocator);
    try std.testing.expectEqualStrings(tag, image.tag.?);
}

test "formats the normalized reference" {
    const allocator = std.testing.allocator;
    var image = try parse(allocator, "alpine");
    defer image.deinit(allocator);
    const formatted = try image.formatAlloc(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("registry-1.docker.io/library/alpine:latest", formatted);
}
