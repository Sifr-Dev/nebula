# Nebula

Nebula is a native terminal multiplexer built with Cipher. It owns PTYs, serves a JSON-lines control protocol over a private Unix socket, and supports pane creation, splitting, execution, capture, resizing, attachment, and closing.

**Pinned Cipher:** `fca41d8` (CI checks out this exact commit).

The CLI also exposes `hello` for the protocol handshake and `detach` for cleanly ending a client attachment session. These use the existing version-1 wire contract; the legacy `cipher-rex` identity remains unchanged.

**Nebula is the product name.** Rex is an external competitor to evaluate, not a SIFR project or internal codename. The current implementation retains `cipher-rex` in its legacy protocol identity and `CIPHER_REX_SOCK` for compatibility; changing those requires a versioned migration, not a text replacement.

## Requirements

- Zig 0.17.1 and a Cipher checkout at `../Cipher`, or pass `-Dcipher-root=/path/to/Cipher`.
- A Unix-like system with PTYs. The multiplexer tests do not require a display, compositor, or GPU.

## Build and test

```sh
zig build -Dcipher-root=/path/to/Cipher
zig build test -Dcipher-root=/path/to/Cipher
zig build test-e2e -Dcipher-root=/path/to/Cipher
zig build test-lifecycle -Dcipher-root=/path/to/Cipher
zig build dist -Dcipher-root=/path/to/Cipher -Doptimize=ReleaseSafe
```

`zig build dist` installs the actual compiled `nebula` executable at
`zig-out/bin/nebula`. It is a standalone application binary with the framework
code compiled in; no separately installed Cipher runtime is needed. A Unix-like
system with PTYs is required for the engine and CLI. The multiplexer tests do
not require a display, compositor, or GPU.

The protocol tests cover request encoding and reply parsing. The end-to-end tests start the actual engine and exercise spawn, run/wait, capture, resize, split, list, and close over a real socket.

## Control-socket lifecycle

The engine owns one Unix socket, and that socket is a control surface: anything that can connect to it can drive panes. `serve` therefore makes an explicit start-up decision instead of blindly unlinking whatever is at the configured path (`src/lifecycle/socket.zig`).

| What is at the path | What `serve` does |
| --- | --- |
| Nothing | Binds and serves. |
| A socket with no listener behind it | Unlinks the dead socket, then binds. |
| A socket with a live listener | **Refuses**; a running engine is never hijacked. |
| A regular file, directory, symlink, FIFO or device | **Refuses**; never deletes a path it did not create. |

Exit codes are distinct so a supervisor can act on them: `3` unsafe socket path, `4` address already in use, `5` could not take the lifetime lock. `2` remains the generic usage error.

A second engine is also stopped by an advisory `flock` on `<socket>.lock`, held for the whole serving lifetime, which closes the race between two engines that inspect the path at the same instant. `flock` belongs to the open file description, so the lock dies with the process even after `SIGKILL` — there is no stale-lock cleanup problem, and the lock file is removed on clean shutdown.

`SIGTERM`, `SIGINT` and `SIGHUP` shut the engine down gracefully: panes are killed, clients are closed, and the listening socket is closed **and unlinked**, so a stopped engine never leaves behind a path that looks live. A socket left by `SIGKILL` is reclaimed by the next `serve`.

## Current boundary

This is an independently maintained application repository with its own CI and release lifecycle. It is not a claim that every terminal user workflow is complete. The server implementation currently comes from Cipher's `term.server` module; a future product decision may move it into Nebula while preserving the tested protocol contract.

The CLI implementation in `src/main.zig` uses the legacy `rex` entrypoint internally but produces a `nebula` executable. A deliberate CLI compatibility and migration pass is still required before describing every command as stable Nebula product behavior. `hello` and `detach` are covered by the same real-engine end-to-end test as pane lifecycle operations.
