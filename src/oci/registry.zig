const std = @import("std");
const manifest = @import("manifest.zig");
const reference = @import("reference.zig");
const storage = @import("../storage.zig");

const http = std.http;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest_accept = "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json";
const manifest_limit = 4 * 1024 * 1024;
const token_limit = 1024 * 1024;
// ponytail: fixed 16 GiB per-pull cap; add an opt-in override if larger images become a supported use case.
const image_download_limit: u64 = 16 * 1024 * 1024 * 1024;

pub const Registry = struct {
    allocator: Allocator,
    client: http.Client,
    token: ?[]const u8 = null,
    registry: []const u8,
    repository: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,

    pub fn init(allocator: Allocator, io: Io, registry: []const u8, repository: []const u8, username: ?[]const u8, password: ?[]const u8) Registry {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .registry = registry,
            .repository = repository,
            .username = username,
            .password = password,
        };
    }

    pub fn deinit(registry: *Registry) void {
        if (registry.token) |token| {
            wipeSecret(token);
            registry.allocator.free(token);
        }
        registry.client.deinit();
        registry.* = undefined;
    }

    pub fn pull(
        registry: *Registry,
        image: reference.Reference,
        store: storage.BlobStore,
        target: manifest.Target,
    ) anyerror!PullResult {
        try validateCredentials(registry.username, registry.password);
        const scheme = registryScheme(registry.registry);
        const selector = image.digest orelse image.tag.?;
        const root_url = try std.fmt.allocPrint(
            registry.allocator,
            "{s}://{s}/v2/{s}/manifests/{s}",
            .{ scheme, registry.registry, registry.repository, selector },
        );
        var root = try registry.getManifest(root_url);
        defer root.deinit(registry.allocator);

        const root_digest = try digestOf(registry.allocator, root.body);
        if (image.digest) |expected| if (!std.mem.eql(u8, expected, root_digest)) return error.BlobDigestMismatch;
        if (root.digest) |expected| if (!std.mem.eql(u8, expected, root_digest)) return error.BlobDigestMismatch;
        try writeBytes(store, root_digest, root.body);

        var selected_body = root.body;
        var selected_digest = root_digest;

        if (manifest.isIndexMediaType(root.media_type)) {
            var arena = std.heap.ArenaAllocator.init(registry.allocator);
            defer arena.deinit();
            const index = manifest.parseIndex(arena.allocator(), root.body) catch return error.InvalidManifest;
            const descriptor = try manifest.selectPlatform(index, target);
            const child_url = try std.fmt.allocPrint(
                registry.allocator,
                "{s}://{s}/v2/{s}/manifests/{s}",
                .{ scheme, registry.registry, registry.repository, descriptor.digest },
            );
            var child = try registry.getManifest(child_url);
            defer child.deinit(registry.allocator);
            if (!manifest.isManifestMediaType(child.media_type)) return error.UnsupportedManifestMediaType;
            if (child.body.len != descriptor.size) return error.BlobSizeMismatch;
            const actual = try digestOf(registry.allocator, child.body);
            if (!std.mem.eql(u8, descriptor.digest, actual)) return error.BlobDigestMismatch;
            if (child.digest) |expected| if (!std.mem.eql(u8, expected, descriptor.digest)) return error.BlobDigestMismatch;
            try writeBytes(store, descriptor.digest, child.body);
            selected_body = try registry.allocator.dupe(u8, child.body);
            selected_digest = try registry.allocator.dupe(u8, descriptor.digest);
        } else if (!manifest.isManifestMediaType(root.media_type)) {
            return error.UnsupportedManifestMediaType;
        }

        var arena = std.heap.ArenaAllocator.init(registry.allocator);
        defer arena.deinit();
        const parsed = manifest.parseManifest(arena.allocator(), selected_body) catch return error.InvalidManifest;
        const plan = try planMissingBlobs(arena.allocator(), store, parsed);
        for (plan.blobs) |blob| try registry.downloadBlob(store, blob.digest, blob.size);

        return .{
            .digest = try registry.allocator.dupe(u8, selected_digest),
            .layer_count = parsed.layers.len,
        };
    }

    fn getManifest(registry: *Registry, url: []const u8) anyerror!SmallResponse {
        const pending = try registry.openAuthenticated(url, manifest_accept);
        defer registry.destroyPending(pending);
        if (pending.response.head.status != .ok) return statusError(pending.response.head.status);

        const media_type = try registry.headerCopy(pending, "content-type") orelse return error.MissingManifestMediaType;
        const digest = try registry.headerCopy(pending, "docker-content-digest");
        const body = try registry.readBody(pending, manifest_limit);
        const normalized_media_type = try baseMediaType(registry.allocator, media_type);
        return .{ .body = body, .media_type = normalized_media_type, .digest = digest };
    }

    fn downloadBlob(registry: *Registry, store: storage.BlobStore, digest: []const u8, size: u64) anyerror!void {
        const url = try std.fmt.allocPrint(registry.allocator, "{s}://{s}/v2/{s}/blobs/{s}", .{ registryScheme(registry.registry), registry.registry, registry.repository, digest });
        const pending = try registry.openAuthenticated(url, "application/octet-stream");
        defer registry.destroyPending(pending);
        if (pending.response.head.status != .ok) return statusError(pending.response.head.status);
        if (pending.response.head.content_length) |length| if (length != size) return error.BlobSizeMismatch;

        var transfer_buffer: [32 * 1024]u8 = undefined;
        const body = pending.response.reader(&transfer_buffer);
        try store.writeVerified(digest, size, body);
    }

    fn openAuthenticated(registry: *Registry, url: []const u8, accept: []const u8) anyerror!*Pending {
        var pending = try registry.openRaw(url, accept, registry.token, null);
        if (pending.response.head.status == .unauthorized) {
            const challenge = try registry.headerCopy(pending, "www-authenticate") orelse {
                registry.destroyPending(pending);
                return error.UnsupportedRegistryAuth;
            };
            registry.destroyPending(pending);
            if (registry.token) |token| {
                wipeSecret(token);
                registry.allocator.free(token);
            }
            registry.token = try registry.obtainToken(challenge);
            pending = try registry.openRaw(url, accept, registry.token, null);
        }

        pending = try registry.followRedirects(pending, accept);
        if (pending.response.head.status == .unauthorized) {
            registry.destroyPending(pending);
            return error.RegistryUnauthorized;
        }
        return pending;
    }

    fn followRedirects(registry: *Registry, initial: *Pending, accept: []const u8) anyerror!*Pending {
        var pending = initial;
        var redirects: u8 = 0;
        while (isRedirect(pending.response.head.status)) {
            if (redirects == 5) {
                registry.destroyPending(pending);
                return error.TooManyRegistryRedirects;
            }
            const location = try registry.headerCopy(pending, "location") orelse {
                registry.destroyPending(pending);
                return error.RegistryRedirectMissingLocation;
            };
            const resolved = resolveRedirectUrl(registry.allocator, pending.request.uri, location) catch |err| {
                registry.destroyPending(pending);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidRegistryRedirect,
                };
            };
            const uri = resolved.uri;
            if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) {
                registry.destroyPending(pending);
                return error.InsecureRegistryRedirect;
            }
            registry.destroyPending(pending);
            pending = try registry.openRaw(resolved.url, accept, null, null);
            redirects += 1;
        }
        return pending;
    }

    fn openRaw(registry: *Registry, url: []const u8, accept: []const u8, token: ?[]const u8, basic_authorization: ?[]const u8) anyerror!*Pending {
        const pending = try registry.allocator.create(Pending);
        errdefer registry.allocator.destroy(pending);
        pending.* = undefined;
        pending.authorization = null;

        pending.extra_headers[0] = .{ .name = "Accept", .value = accept };
        if (token) |value| {
            pending.authorization = try std.fmt.allocPrint(registry.allocator, "Bearer {s}", .{value});
        } else if (basic_authorization) |value| {
            pending.authorization = try registry.allocator.dupe(u8, value);
        }
        errdefer if (pending.authorization) |value| {
            wipeSecret(value);
            registry.allocator.free(value);
        };
        const headers: []const http.Header = if (pending.authorization != null) blk: {
            pending.extra_headers[1] = .{ .name = "Authorization", .value = pending.authorization.? };
            break :blk pending.extra_headers[0..2];
        } else pending.extra_headers[0..1];

        pending.request = try registry.client.request(.GET, try std.Uri.parse(url), .{
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        });
        errdefer pending.request.deinit();
        try pending.request.sendBodiless();
        pending.response = try pending.request.receiveHead(&pending.redirect_buffer);
        return pending;
    }

    fn obtainToken(registry: *Registry, raw_challenge: []const u8) anyerror![]const u8 {
        const challenge = parseBearerChallenge(raw_challenge) orelse return error.UnsupportedRegistryAuth;
        const expected_scope = try std.fmt.allocPrint(registry.allocator, "repository:{s}:pull", .{registry.repository});
        const scope = challenge.scope orelse expected_scope;
        const scope_kind = authScopeKind(registry.registry, scope, expected_scope) orelse return error.UnsupportedRegistryAuth;

        const realm = try std.Uri.parse(challenge.realm);
        if (!allowedTokenRealm(realm, isLoopbackRegistry(registry.registry))) {
            return error.InsecureTokenRealm;
        }
        const token_url = try buildTokenUrl(registry.allocator, challenge.realm, challenge.service, scope);
        const basic_authorization = if (scope_kind == .repository) blk: {
            if (registry.username) |username| break :blk try buildBasicAuthorization(registry.allocator, username, registry.password.?);
            break :blk null;
        } else null;
        defer if (basic_authorization) |value| {
            wipeSecret(value);
            registry.allocator.free(value);
        };
        const pending = try registry.openRaw(token_url, "application/json", null, basic_authorization);
        defer registry.destroyPending(pending);
        if (pending.response.head.status != .ok) return error.TokenRequestFailed;

        const body = try registry.readBody(pending, token_limit);
        defer {
            wipeSecret(body);
            registry.allocator.free(body);
        }
        const parsed = try std.json.parseFromSlice(TokenResponse, registry.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value.token orelse parsed.value.access_token orelse return error.InvalidTokenResponse;
        if (value.len == 0 or value.len > 16 * 1024 or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidTokenResponse;
        return registry.allocator.dupe(u8, value);
    }

    fn readBody(registry: *Registry, pending: *Pending, limit: usize) anyerror![]u8 {
        if (pending.response.head.content_length) |length| if (length > limit) return error.ResponseTooLarge;
        var body: std.ArrayList(u8) = .empty;
        var transfer_buffer: [32 * 1024]u8 = undefined;
        var read_buffer: [32 * 1024]u8 = undefined;
        const reader = pending.response.reader(&transfer_buffer);
        while (true) {
            const count = reader.readSliceShort(&read_buffer) catch return error.RegistryBodyReadFailed;
            if (count == 0) break;
            if (count > limit - body.items.len) return error.ResponseTooLarge;
            try body.appendSlice(registry.allocator, read_buffer[0..count]);
            if (count < read_buffer.len) break;
        }
        return body.toOwnedSlice(registry.allocator);
    }

    fn headerCopy(registry: *Registry, pending: *Pending, name: []const u8) Allocator.Error!?[]u8 {
        var headers = pending.response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return try registry.allocator.dupe(u8, header.value);
        }
        return null;
    }

    fn destroyPending(registry: *Registry, pending: *Pending) void {
        pending.request.deinit();
        if (pending.authorization) |value| {
            wipeSecret(value);
            registry.allocator.free(value);
        }
        registry.allocator.destroy(pending);
    }
};

pub const PullResult = struct {
    digest: []const u8,
    layer_count: usize,
};

const BlobPlan = struct {
    blobs: []manifest.Descriptor,
    total_size: u64,
};

fn planMissingBlobs(allocator: Allocator, store: storage.BlobStore, image: manifest.Manifest) !BlobPlan {
    var seen = std.StringHashMap(u64).init(allocator);
    defer seen.deinit();
    var blobs: std.ArrayList(manifest.Descriptor) = .empty;
    errdefer blobs.deinit(allocator);
    var total_size: u64 = 0;

    try addMissingBlob(allocator, store, &seen, &blobs, &total_size, image.config);
    for (image.layers) |layer| {
        try addMissingBlob(allocator, store, &seen, &blobs, &total_size, layer);
    }
    return .{ .blobs = try blobs.toOwnedSlice(allocator), .total_size = total_size };
}

fn addMissingBlob(
    allocator: Allocator,
    store: storage.BlobStore,
    seen: *std.StringHashMap(u64),
    blobs: *std.ArrayList(manifest.Descriptor),
    total_size: *u64,
    descriptor: manifest.Descriptor,
) !void {
    if (seen.get(descriptor.digest)) |known_size| {
        if (known_size != descriptor.size) return error.BlobSizeMismatch;
        return;
    }
    try seen.put(descriptor.digest, descriptor.size);
    if (try store.containsVerified(descriptor.digest, descriptor.size)) return;

    total_size.* = try nextDownloadSize(total_size.*, descriptor.size);
    try blobs.append(allocator, descriptor);
}

fn nextDownloadSize(total: u64, size: u64) error{ImageDownloadTooLarge}!u64 {
    const next = std.math.add(u64, total, size) catch return error.ImageDownloadTooLarge;
    if (next > image_download_limit) return error.ImageDownloadTooLarge;
    return next;
}

const Pending = struct {
    request: http.Client.Request,
    response: http.Client.Response,
    redirect_buffer: [8192]u8,
    extra_headers: [2]http.Header,
    authorization: ?[]const u8 = null,
};

const SmallResponse = struct {
    body: []u8,
    media_type: []u8,
    digest: ?[]u8,

    fn deinit(response: *SmallResponse, allocator: Allocator) void {
        allocator.free(response.body);
        allocator.free(response.media_type);
        if (response.digest) |value| allocator.free(value);
        response.* = undefined;
    }
};

const TokenResponse = struct {
    token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
};

const BearerChallenge = struct {
    realm: []const u8,
    service: ?[]const u8,
    scope: ?[]const u8,
};

const AuthScopeKind = enum { repository, public_ecr };

const ResolvedRedirect = struct { url: []u8, uri: std.Uri };

fn resolveRedirectUrl(allocator: Allocator, base: std.Uri, location: []const u8) !ResolvedRedirect {
    const base_path_len = switch (base.path) {
        .raw => |path| path.len,
        .percent_encoded => |path| path.len,
    };
    const buffer = try allocator.alloc(u8, location.len + base_path_len + 1);
    defer allocator.free(buffer);
    @memcpy(buffer[0..location.len], location);
    var redirect_buffer = buffer[0..];
    const uri = std.Uri.resolveInPlace(base, location.len, &redirect_buffer) catch return error.InvalidRegistryRedirect;
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try uri.writeToStream(&output.writer, .all);
    const url = try allocator.dupe(u8, output.written());
    errdefer allocator.free(url);
    return .{ .url = url, .uri = try std.Uri.parse(url) };
}

fn authScopeKind(registry: []const u8, scope: []const u8, expected_scope: []const u8) ?AuthScopeKind {
    if (std.mem.eql(u8, scope, expected_scope)) return .repository;
    if (std.ascii.eqlIgnoreCase(registry, "public.ecr.aws") and std.mem.eql(u8, scope, "aws")) return .public_ecr;
    return null;
}

pub fn parseBearerChallenge(input: []const u8) ?BearerChallenge {
    const text = std.mem.trim(u8, input, " \t");
    const separator = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    if (!std.ascii.eqlIgnoreCase(text[0..separator], "Bearer")) return null;

    var result: BearerChallenge = .{ .realm = "", .service = null, .scope = null };
    var index = separator;
    while (index < text.len) {
        while (index < text.len and (text[index] == ',' or text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
        if (index == text.len) break;
        const key_start = index;
        while (index < text.len and (std.ascii.isAlphanumeric(text[index]) or text[index] == '_' or text[index] == '-')) : (index += 1) {}
        if (key_start == index) return null;
        const key = text[key_start..index];
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
        if (index == text.len or text[index] != '=') return null;
        index += 1;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}

        var value: []const u8 = undefined;
        if (index < text.len and text[index] == '"') {
            index += 1;
            const start = index;
            while (index < text.len and text[index] != '"') : (index += 1) {
                if (text[index] == '\\' or text[index] == '\r' or text[index] == '\n') return null;
            }
            if (index == text.len) return null;
            value = text[start..index];
            index += 1;
        } else {
            const start = index;
            while (index < text.len and text[index] != ',') : (index += 1) {}
            value = std.mem.trim(u8, text[start..index], " \t");
        }

        if (std.ascii.eqlIgnoreCase(key, "realm")) result.realm = value else if (std.ascii.eqlIgnoreCase(key, "service")) result.service = value else if (std.ascii.eqlIgnoreCase(key, "scope")) result.scope = value;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
        if (index < text.len and text[index] != ',') return null;
    }
    if (result.realm.len == 0) return null;
    return result;
}

fn buildTokenUrl(allocator: Allocator, realm: []const u8, service: ?[]const u8, scope: []const u8) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const separator: u8 = if (std.mem.indexOfScalar(u8, realm, '?') == null) '?' else '&';
    try output.writer.print("{s}{c}", .{ realm, separator });
    var has_parameter = false;
    if (service) |value| {
        try output.writer.writeAll("service=");
        try percentEncodeQuery(&output.writer, value);
        has_parameter = true;
    }
    if (has_parameter) try output.writer.writeByte('&');
    try output.writer.writeAll("scope=");
    try percentEncodeQuery(&output.writer, scope);
    return allocator.dupe(u8, output.written());
}

fn registryScheme(registry: []const u8) []const u8 {
    return if (isLoopbackRegistry(registry)) "http" else "https";
}

fn isLoopbackRegistry(registry: []const u8) bool {
    const host_end = std.mem.indexOfScalar(u8, registry, ':') orelse registry.len;
    return isLoopbackHost(registry[0..host_end]);
}

fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

fn allowedTokenRealm(realm: std.Uri, loopback_registry: bool) bool {
    if (realm.host == null or realm.user != null or realm.password != null or realm.fragment != null) return false;
    if (std.mem.eql(u8, realm.scheme, "https")) return true;
    if (!loopback_registry or !std.mem.eql(u8, realm.scheme, "http")) return false;
    return switch (realm.host.?) {
        .raw => |host| isLoopbackHost(host),
        .percent_encoded => |host| std.mem.indexOfScalar(u8, host, '%') == null and isLoopbackHost(host),
    };
}

fn percentEncodeQuery(writer: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

fn baseMediaType(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return allocator.dupe(u8, std.mem.trim(u8, value[0..semicolon], " \t"));
}

fn statusError(status: http.Status) anyerror {
    return switch (status) {
        .unauthorized => error.RegistryUnauthorized,
        .forbidden => error.RegistryForbidden,
        .not_found => error.ImageNotFound,
        else => error.RegistryRequestFailed,
    };
}

fn isRedirect(status: http.Status) bool {
    return status == .moved_permanently or status == .found or status == .see_other or
        status == .temporary_redirect or status == .permanent_redirect;
}

fn digestOf(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes);
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn validateCredentials(username: ?[]const u8, password: ?[]const u8) !void {
    if (username == null and password == null) return;
    if (username == null or password == null) return error.IncompleteRegistryCredentials;
    try validateBasicCredentials(username.?, password.?);
}

fn validateBasicCredentials(username: []const u8, password: []const u8) !void {
    if (username.len == 0 or password.len == 0 or username.len > 4096 or password.len > 4096 or
        std.mem.indexOfAny(u8, username, ":\r\n") != null or std.mem.indexOfAny(u8, password, "\r\n") != null)
        return error.InvalidRegistryCredentials;
}

fn buildBasicAuthorization(allocator: Allocator, username: []const u8, password: []const u8) ![]u8 {
    try validateBasicCredentials(username, password);
    const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer {
        wipeSecret(credentials);
        allocator.free(credentials);
    }
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(credentials.len));
    defer {
        wipeSecret(encoded);
        allocator.free(encoded);
    }
    const value = std.base64.standard.Encoder.encode(encoded, credentials);
    return std.fmt.allocPrint(allocator, "Basic {s}", .{value});
}

fn wipeSecret(bytes: []const u8) void {
    std.crypto.secureZero(u8, @ptrCast(@constCast(bytes)));
}

fn writeBytes(store: storage.BlobStore, digest: []const u8, bytes: []const u8) anyerror!void {
    var reader = Io.Reader.fixed(bytes);
    try store.writeVerified(digest, @intCast(bytes.len), &reader);
}

test "plans each missing image blob once and skips verified cached blobs" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try storage.BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    const cached_digest = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    var cached_body = Io.Reader.fixed("hello");
    try store.writeVerified(cached_digest, 5, &cached_body);

    const missing_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const image = manifest.Manifest{
        .schemaVersion = 2,
        .config = .{
            .mediaType = "application/vnd.oci.image.config.v1+json",
            .digest = cached_digest,
            .size = 5,
        },
        .layers = &.{
            .{ .mediaType = "application/vnd.oci.image.layer.v1.tar", .digest = cached_digest, .size = 5 },
            .{ .mediaType = "application/vnd.oci.image.layer.v1.tar", .digest = missing_digest, .size = 5 },
            .{ .mediaType = "application/vnd.oci.image.layer.v1.tar", .digest = missing_digest, .size = 5 },
        },
    };
    const plan = try planMissingBlobs(allocator, store, image);
    defer allocator.free(plan.blobs);

    try std.testing.expectEqual(@as(usize, 1), plan.blobs.len);
    try std.testing.expectEqual(@as(u64, 5), plan.total_size);
    try std.testing.expectEqualStrings(missing_digest, plan.blobs[0].digest);
}

test "caps aggregate uncached image downloads at 16 GiB" {
    try std.testing.expectEqual(image_download_limit, try nextDownloadSize(image_download_limit - 1, 1));
    try std.testing.expectError(error.ImageDownloadTooLarge, nextDownloadSize(image_download_limit, 1));
    try std.testing.expectError(error.ImageDownloadTooLarge, nextDownloadSize(std.math.maxInt(u64), 1));

    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var store = try storage.BlobStore.init(std.testing.io, temp.dir);
    defer store.deinit();

    const image = manifest.Manifest{
        .schemaVersion = 2,
        .config = .{
            .mediaType = "application/vnd.oci.image.config.v1+json",
            .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .size = image_download_limit / 2,
        },
        .layers = &.{.{
            .mediaType = "application/vnd.oci.image.layer.v1.tar",
            .digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .size = image_download_limit / 2 + 1,
        }},
    };
    try std.testing.expectError(error.ImageDownloadTooLarge, planMissingBlobs(allocator, store, image));
}

test "parses anonymous bearer token challenges with quoted parameters" {
    const challenge = parseBearerChallenge("Bearer realm=\"https://auth.example/token\",service=\"registry.example\",scope=\"repository:team/app:pull\"").?;
    try std.testing.expectEqualStrings("https://auth.example/token", challenge.realm);
    try std.testing.expectEqualStrings("registry.example", challenge.service.?);
    try std.testing.expectEqualStrings("repository:team/app:pull", challenge.scope.?);
}

test "supports ECR Public anonymous bearer scope without forwarding registry credentials" {
    const challenge = parseBearerChallenge("Bearer realm=\"https://public.ecr.aws/token/\",service=\"public.ecr.aws\",scope=\"aws\"").?;
    const expected_scope = "repository:amazonlinux/amazonlinux:pull";
    try std.testing.expectEqual(AuthScopeKind.public_ecr, authScopeKind("public.ecr.aws", challenge.scope.?, expected_scope).?);
    try std.testing.expectEqual(AuthScopeKind.repository, authScopeKind("registry.example", expected_scope, expected_scope).?);
    try std.testing.expect(authScopeKind("registry.example", "aws", expected_scope) == null);
    try std.testing.expect(authScopeKind("public.ecr.aws", "repository:someone/else:pull", expected_scope) == null);
}

test "rejects unsupported or malformed registry auth challenges" {
    try std.testing.expect(parseBearerChallenge("Basic realm=\"https://auth.example/token\"") == null);
    try std.testing.expect(parseBearerChallenge("Bearer realm=\"https://auth.example/token\\\"bad\"") == null);
    try std.testing.expect(parseBearerChallenge("Bearer service=\"registry.example\"") == null);
}

test "encodes registry token query values" {
    const url = try buildTokenUrl(std.testing.allocator, "https://auth.example/token", "registry.example", "repository:library/alpine:pull");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://auth.example/token?service=registry.example&scope=repository%3Alibrary%2Falpine%3Apull", url);
}

test "resolves root-relative registry redirects against the HTTPS origin" {
    const allocator = std.testing.allocator;
    const base = try std.Uri.parse("https://gcr.io/v2/example/image/blobs/sha256:abc");
    const redirect = try resolveRedirectUrl(allocator, base, "/artifacts-downloads/blob");
    defer allocator.free(redirect.url);
    try std.testing.expectEqualStrings("https://gcr.io/artifacts-downloads/blob", redirect.url);
    try std.testing.expectEqualStrings("https", redirect.uri.scheme);
}

test "allows plain HTTP only for explicit loopback registries and token realms" {
    try std.testing.expectEqualStrings("http", registryScheme("localhost:5000"));
    try std.testing.expectEqualStrings("http", registryScheme("127.0.0.1:5000"));
    try std.testing.expectEqualStrings("https", registryScheme("127.0.0.2:5000"));
    try std.testing.expect(allowedTokenRealm(try std.Uri.parse("https://auth.example/token"), false));
    try std.testing.expect(allowedTokenRealm(try std.Uri.parse("http://127.0.0.1:5000/token"), true));
    try std.testing.expect(!allowedTokenRealm(try std.Uri.parse("http://127.0.0.1:5000/token"), false));
    try std.testing.expect(!allowedTokenRealm(try std.Uri.parse("http://auth.example/token"), true));
}

test "validates paired registry credentials and builds Basic authorization" {
    const allocator = std.testing.allocator;
    try validateCredentials(null, null);
    try std.testing.expectError(error.IncompleteRegistryCredentials, validateCredentials("user", null));
    try std.testing.expectError(error.InvalidRegistryCredentials, validateCredentials("bad:user", "secret"));
    try std.testing.expectError(error.InvalidRegistryCredentials, validateCredentials("user", "line\nbreak"));
    const authorization = try buildBasicAuthorization(allocator, "rift-user", "rift-secret");
    defer {
        wipeSecret(authorization);
        allocator.free(authorization);
    }
    try std.testing.expectEqualStrings("Basic cmlmdC11c2VyOnJpZnQtc2VjcmV0", authorization);
}
