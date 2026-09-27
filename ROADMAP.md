# Rift roadmap

Rift is an early source preview for Apple Silicon macOS. This document tracks the work required to make it reliable and straightforward to adopt. It has no promised dates.

## Working today

- Pull and verify public `linux/arm64` OCI images; optional environment credentials cover the tested Basic-to-Bearer flow.
- Run Alpine and nginx in isolated Linux VMs through Apple's Virtualization.framework.
- Use image command, environment, working directory, user, and group defaults, with `-e` and `-w` overrides.
- Use outbound networking, DNS, one localhost TCP port mapping, and explicit read-only or writable file and directory volumes.
- Manage detached containers with `ps`, `inspect`, `logs`, `stop`, `kill`, and `rm`.
- Inspect and clean local storage with `system df`, `rmi`, and `clean`.
- Run formatting, unit, build, and macOS integration checks locally with `scripts/check-local.sh`.

## Next

1. Broaden safe OCI layer support: ownership, PAX metadata, extended attributes, and supported special files.
2. Complete OCI process controls and isolation with focused threat-model review and regression checks.
3. Improve the detached workflow, including a secure command channel for `rift exec` and structured log options.
4. Expand registry compatibility tests beyond the local private-registry fixture.
5. Measure cold and cached startup, memory, binary size, and storage with reproducible methods.
6. Establish a Developer ID signing and notarization path before offering public macOS binaries.
7. Improve installation and upgrade paths after signed distribution is available.

## Adoption milestone

The main usability milestone is a verified local workflow without Docker:

```sh
rift pull alpine
rift run --rm alpine echo "Hello from Rift"
rift pull nginx
id=$(rift run -d -p 8080:80 nginx)
rift ps
rift logs "$id"
rift stop "$id"
rift rm "$id"
rift system df
rift clean
```

Before calling Rift ready for broad adoption, validate that workflow on a clean Apple Silicon Mac, close the documented OCI and isolation gaps that affect common images, and provide a signed, notarized installation path. Passing local checks alone does not prove those release and compatibility goals.
