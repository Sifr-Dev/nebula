# Nebula

Nebula is a native terminal multiplexer built with Cipher. It owns PTYs, serves a JSON-lines control protocol over a private Unix socket, and supports pane creation, splitting, execution, capture, resizing, attachment, and closing.

**Nebula is the product name.** Rex is an external competitor to evaluate, not a SIFR project or internal codename. The current implementation retains `cipher-rex` in its legacy protocol identity and `CIPHER_REX_SOCK` for compatibility; changing those requires a versioned migration, not a text replacement.

## Requirements

- Zig 0.17.1 and a Cipher checkout at `../Cipher`, or pass `-Dcipher-root=/path/to/Cipher`.
- A Unix-like system with PTYs. The multiplexer tests do not require a display, compositor, or GPU.

## Build and test

```sh
zig build -Dcipher-root=/path/to/Cipher
zig build test -Dcipher-root=/path/to/Cipher
zig build test-e2e -Dcipher-root=/path/to/Cipher
zig build dist -Dcipher-root=/path/to/Cipher -Doptimize=ReleaseSafe
```

`zig build dist` installs the actual compiled `nebula` executable at
`zig-out/bin/nebula`. It is a standalone application binary with the framework
code compiled in; no separately installed Cipher runtime is needed. A Unix-like
system with PTYs is required for the engine and CLI. The multiplexer tests do
not require a display, compositor, or GPU.

The protocol tests cover request encoding and reply parsing. The end-to-end tests start the actual engine and exercise spawn, run/wait, capture, resize, split, list, and close over a real socket.

## Current boundary

This is an independently maintained application repository with its own CI and release lifecycle. It is not a claim that every terminal user workflow is complete. The server implementation currently comes from Cipher's `term.server` module; a future product decision may move it into Nebula while preserving the tested protocol contract.

The CLI implementation in `src/main.zig` uses the legacy `rex` entrypoint internally but produces a `nebula` executable. A deliberate CLI compatibility and migration pass is still required before describing every command as stable Nebula product behavior.
