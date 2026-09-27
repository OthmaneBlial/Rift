#!/usr/bin/env python3
"""Exercise a credentialed OCI pull against a local Bearer-auth registry."""

from __future__ import annotations

import base64
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit


USERNAME = "rift-check-user"
PASSWORD = "rift-check-password"
TOKEN = "rift-check-token"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_registry_auth.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    config = b'{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}'
    layer = b"local registry auth fixture"
    blobs = {hashlib.sha256(value).hexdigest(): value for value in (config, layer)}
    config_digest, layer_digest = blobs
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": f"sha256:{config_digest}",
                "size": len(config),
            },
            "layers": [
                {
                    "mediaType": "application/vnd.oci.image.layer.v1.tar",
                    "digest": f"sha256:{layer_digest}",
                    "size": len(layer),
                }
            ],
        },
        separators=(",", ":"),
    ).encode()
    oversized_manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": "sha256:" + "a" * 64,
                "size": 8 * 1024**3 + 1,
            },
            "layers": [
                {
                    "mediaType": "application/vnd.oci.image.layer.v1.tar",
                    "digest": "sha256:" + "b" * 64,
                    "size": 8 * 1024**3 + 1,
                }
            ],
        },
        separators=(",", ":"),
    ).encode()
    events = {"challenge": 0, "token": 0, "manifest": 0, "blobs": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:
            pass

        def respond(self, status: int, body: bytes, content_type: str, headers: dict[str, str] | None = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            if parsed.path == "/token":
                events["token"] += 1
                expected_basic = "Basic " + base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()
                query = parse_qs(parsed.query)
                if self.headers.get("Authorization") != expected_basic:
                    self.respond(401, b"", "application/json")
                    return
                if query.get("service") != ["rift-check"] or query.get("scope") != ["repository:team/app:pull"]:
                    self.respond(400, b"", "application/json")
                    return
                self.respond(200, json.dumps({"token": TOKEN}).encode(), "application/json")
                return

            if parsed.path in ("/v2/team/app/manifests/latest", "/v2/team/app/manifests/oversized"):
                events["manifest"] += 1
                if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                    events["challenge"] += 1
                    realm = f"http://127.0.0.1:{self.server.server_port}/token"
                    self.respond(
                        401,
                        b"",
                        "application/json",
                        {"WWW-Authenticate": f'Bearer realm="{realm}",service="rift-check",scope="repository:team/app:pull"'},
                    )
                    return
                body = oversized_manifest if parsed.path.endswith("/oversized") else manifest
                self.respond(200, body, "application/vnd.oci.image.manifest.v1+json")
                return

            if parsed.path.startswith("/v2/team/app/blobs/"):
                events["blobs"] += 1
                digest = parsed.path.rsplit("/", 1)[-1].removeprefix("sha256:")
                body = blobs.get(digest)
                if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                    self.respond(401, b"", "application/json")
                elif body is None:
                    self.respond(404, b"", "application/json")
                else:
                    self.respond(200, body, "application/octet-stream")
                return

            self.respond(404, b"", "text/plain")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="rift-registry-auth-") as temporary:
            environment = os.environ.copy()
            environment.update(
                HOME=temporary,
                RIFT_REGISTRY_USERNAME=USERNAME,
                RIFT_REGISTRY_PASSWORD=PASSWORD,
            )
            image = f"127.0.0.1:{server.server_port}/team/app:latest"
            pulled = subprocess.run([binary, "pull", image], capture_output=True, text=True, timeout=30, env=environment)
            if pulled.returncode != 0 or f"Pulled {image}" not in pulled.stdout:
                raise RuntimeError(f"authenticated pull failed: {pulled!r}")
            if any(secret in pulled.stdout + pulled.stderr for secret in (USERNAME, PASSWORD, TOKEN)):
                raise RuntimeError("registry credentials or token appeared in pull output")
            listed = subprocess.run([binary, "images"], capture_output=True, text=True, timeout=15, env=environment)
            if listed.returncode != 0 or image not in listed.stdout:
                raise RuntimeError(f"authenticated image was not recorded: {listed!r}")

            oversized_image = f"127.0.0.1:{server.server_port}/team/app:oversized"
            rejected = subprocess.run([binary, "pull", oversized_image], capture_output=True, text=True, timeout=30, env=environment)
            if rejected.returncode == 0 or "16 GiB" not in rejected.stderr:
                raise RuntimeError(f"oversized image was not rejected with the pull limit: {rejected!r}")
            listed = subprocess.run([binary, "images"], capture_output=True, text=True, timeout=15, env=environment)
            if listed.returncode != 0 or oversized_image in listed.stdout:
                raise RuntimeError(f"oversized image was recorded after rejection: {listed!r}")

        if events != {"challenge": 2, "token": 2, "manifest": 4, "blobs": 2}:
            raise RuntimeError(f"unexpected registry request flow: {events}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("Rift registry check passed: Bearer auth, verified blob pulls, metadata, and pre-download 16 GiB limit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
