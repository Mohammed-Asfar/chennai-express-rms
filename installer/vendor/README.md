# Vendored binaries

## chennai-service.exe — WinSW v2.12.0 (x64)

A service wrapper, renamed.

`node.exe` never calls `StartServiceCtrlDispatcher`, so registering it directly
with `sc.exe` produces a service the Service Control Manager kills after waiting
90 seconds for a handshake that never arrives — **error 1053**, "the service did
not respond to the start or control request in a timely fashion". The binary is
fine; it simply does not speak the SCM protocol, and no amount of correcting the
`binPath` quoting changes that.

WinSW does speak it, and runs `node.exe server.mjs` as a child process. It also
provides restart-on-crash and log rotation, which a bare `sc.exe create` does
not.

This is the .NET-bundled build (18 MB). The smaller 5 MB release requires .NET
Framework to be present on the till, which is not a dependency worth adding to a
billing PC.

Configuration lives in `chennai-service.xml` beside it, written by the installer.

Upstream: https://github.com/winsw/winsw/releases/tag/v2.12.0
Licence: MIT
