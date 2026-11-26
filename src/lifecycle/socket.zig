//! Control-socket lifecycle for the Nebula engine.
//!
//! The engine owns a Unix socket, and that socket is a product surface: the
//! CLI and the terminal connect to it, and anything else that finds it can
//! drive panes. Three failure modes are therefore not acceptable:
//!
//!   1. A second `serve` silently *unlinking a live engine's socket*. The
//!      framework server calls `unlink()` before `bind()`, so a second engine
//!      used to steal the address while the first kept running invisibly: two
//!      engines, two PTY trees, one address, and clients split across them.
//!   2. `serve --socket <regular file>` deleting that file. The same
//!      unconditional `unlink()` turned a typo in `--socket` into silent data
//!      loss for whatever path the user named.
//!   3. A stale socket left behind after the engine is killed, which then
//!      looks like a live engine to any tooling that only checks `exists()`.
//!
//! This module makes the start-up decision explicit and testable:
//!
//!   - [`kindOf`] asks the kernel what the path actually is (via `statx`, so a
//!     symlink is not followed and a directory is never mistaken for a file);
//!   - [`isListening`] proves whether a real listener accepts connections,
//!     which is the only honest test for "an engine is running";
//!   - [`decide`] is the pure policy over those two facts;
//!   - [`Lock`] closes the remaining race between two engines that start at
//!     the same instant, with an advisory `flock` held for the whole serving
//!     lifetime.
//!
//! Nothing here starts a server. The syscall surface is deliberately narrow so
//! that it is unit-testable, and the integration behaviour is covered by
//! `tests/lifecycle_test.zig` against the real binary and real sockets.

const std = @import("std");
const linux = std.os.linux;

/// Longest usable path for an `AF.UNIX` address, excluding the terminator.
pub const max_socket_path: usize = 107;

/// Exit codes the CLI uses when it refuses to start. Kept distinct from the
/// generic usage error (2) so a supervisor can tell "bad arguments" from
/// "address already taken" and "refusing to destroy a file".
pub const exit_address_in_use: u8 = 4;
pub const exit_unsafe_path: u8 = 3;
pub const exit_lock_failed: u8 = 5;

/// What the filesystem reports at the socket path.
pub const Kind = enum {
    /// Nothing is there (ENOENT).
    absent,
    /// A Unix socket file.
    socket,
    /// A regular file — never ours to delete.
    regular,
    /// A directory — never ours to delete.
    directory,
    /// A symlink, FIFO, device, or an unreadable/inspectable path.
    other,
};

/// Facts gathered about the configured socket path before binding.
pub const Probe = struct {
    kind: Kind,
    /// True only when a `connect()` to the path actually succeeded.
    listening: bool,
};

/// The policy decision. Pure function of [`Probe`], so it is unit-testable
/// without touching a filesystem.
pub const Decision = enum {
    /// Nothing at the path: bind normally.
    start,
    /// A socket file with no listener behind it: unlink it, then bind.
    reclaim,
    /// A live listener: refuse. Starting would hijack a running engine.
    refuse_live,
    /// Something that is not a socket: refuse. Starting would delete it.
    refuse_non_socket,
};

/// Decide what start-up should do, given what was observed.
pub fn decide(kind: Kind, listening: bool) Decision {
    return switch (kind) {
        .absent => .start,
        // A socket is only reclaimable when provably dead. "Exists" is not
        // evidence of a live engine — an accepted connection is.
        .socket => if (listening) .refuse_live else .reclaim,
        .regular, .directory, .other => .refuse_non_socket,
    };
}

fn toCstr(buf: []u8, path: []const u8) ?[*:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0].ptr);
}

/// Ask the kernel what `path` is, without following a final symlink.
pub fn kindOf(path: []const u8) Kind {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = toCstr(&path_buf, path) orelse return .other;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, c_path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    return switch (linux.errno(rc)) {
        .SUCCESS => switch (stx.mode & linux.S.IFMT) {
            linux.S.IFSOCK => .socket,
            linux.S.IFREG => .regular,
            linux.S.IFDIR => .directory,
            else => .other,
        },
        .NOENT, .NOTDIR => .absent,
        // Unreadable or otherwise uninspectable: treat as not-ours so we never
        // unlink something we could not identify.
        else => .other,
    };
}

/// True when a `connect()` to `path` is accepted. A refused or ENOENT connect
/// means the socket file is dead. `EAGAIN`/`EINPROGRESS` on a non-blocking
/// socket count as listening: the listener queued us.
pub fn isListening(path: []const u8) bool {
    const fd_rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (@as(isize, @bitCast(fd_rc)) < 0) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = linux.AF.UNIX;
    if (path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path.len], path);

    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    return switch (linux.errno(rc)) {
        .SUCCESS, .AGAIN, .INPROGRESS => true,
        else => false,
    };
}

/// Observe the socket path once, before deciding what to do.
pub fn probe(path: []const u8) Probe {
    const kind = kindOf(path);
    return .{ .kind = kind, .listening = kind == .socket and isListening(path) };
}

/// Remove a dead socket file. Only call after [`decide`] returned `.reclaim`.
pub fn reclaim(path: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = toCstr(&path_buf, path) orelse return error.NameTooLong;
    const rc = linux.unlinkat(linux.AT.FDCWD, c_path, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS, .NOENT => {},
        .ACCES, .PERM => error.PermissionDenied,
        else => error.UnlinkFailed,
    };
}

/// Exclusive advisory lock held for the engine's whole lifetime.
///
/// `flock` is attached to the open file description, so the lock disappears
/// with the process even after `SIGKILL` — there is no stale-lock cleanup
/// problem, which is exactly why it is used instead of a PID file. The lock
/// file itself may be left on disk after a crash; that is inert.
pub const Lock = struct {
    fd: i32,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub const AcquireError = error{
        NameTooLong,
        DirectoryMissing,
        PermissionDenied,
        AlreadyServing,
        OpenFailed,
        LockFailed,
    };

    /// Take the exclusive lock guarding `socket_path`, derived as
    /// `<socket_path>.lock`. Returns `error.AlreadyServing` when another engine
    /// already holds it.
    pub fn acquire(socket_path: []const u8) AcquireError!Lock {
        var lock = Lock{ .fd = -1 };
        const lock_path = std.fmt.bufPrint(&lock.path_buf, "{s}.lock", .{socket_path}) catch
            return error.NameTooLong;
        lock.path_len = lock_path.len;
        // Terminate for the syscall while keeping `path_len` for later unlink.
        if (lock.path_len >= lock.path_buf.len) return error.NameTooLong;
        lock.path_buf[lock.path_len] = 0;
        const c_path: [*:0]const u8 = @ptrCast(lock.path_buf[0..lock.path_len :0].ptr);

        const fd_rc = linux.openat(
            linux.AT.FDCWD,
            c_path,
            .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
            0o600,
        );
        if (@as(isize, @bitCast(fd_rc)) < 0) {
            return switch (linux.errno(fd_rc)) {
                .NOENT, .NOTDIR => error.DirectoryMissing,
                .ACCES, .PERM => error.PermissionDenied,
                else => error.OpenFailed,
            };
        }
        lock.fd = @intCast(fd_rc);

        const rc = linux.flock(lock.fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(rc) != .SUCCESS) {
            _ = linux.close(lock.fd);
            lock.fd = -1;
            return switch (linux.errno(rc)) {
                .AGAIN => error.AlreadyServing,
                else => error.LockFailed,
            };
        }
        return lock;
    }

    /// Release the lock and remove the (now meaningless) lock file. Called
    /// after the listening socket is closed and unlinked, so a successor can
    /// never bind while this engine still owns the address.
    pub fn release(self: *Lock) void {
        if (self.fd < 0) return;
        _ = linux.close(self.fd);
        self.fd = -1;
        if (self.path_len > 0) {
            self.path_buf[self.path_len] = 0;
            _ = linux.unlinkat(linux.AT.FDCWD, @ptrCast(self.path_buf[0..self.path_len :0].ptr), 0);
        }
    }
};

// ------------------------------------------------------------- shutdown

/// Set by the signal handler; the engine loop's `running` flag also lives here
/// so the store is a single aligned write, which is async-signal-safe.
var shutdown_target: ?*bool = null;

fn onShutdownSignal(_: linux.SIG) callconv(.c) void {
    if (shutdown_target) |flag| flag.* = false;
}

/// Install graceful shutdown on SIGTERM/SIGINT/SIGHUP.
///
/// The engine's poll loop re-reads its `running` flag every iteration (the
/// `poll(2)` call in between is opaque to the optimizer, so the store is
/// observed), which lets `defer srv.deinit()` run: panes killed, clients
/// closed, listening socket closed *and unlinked*. Without this, `SIGTERM`
/// terminated the process outright and left a stale socket that looked live.
pub fn installShutdownHandlers(running: *bool) void {
    shutdown_target = running;
    const act = linux.Sigaction{
        .handler = .{ .handler = onShutdownSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    // Best-effort: a platform that refuses the handler keeps the old
    // terminate-immediately behaviour rather than failing to start.
    _ = linux.sigaction(.TERM, &act, null);
    _ = linux.sigaction(.INT, &act, null);
    _ = linux.sigaction(.HUP, &act, null);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a missing path starts cleanly" {
    try testing.expectEqual(Decision.start, decide(.absent, false));
}

test "a dead socket file is reclaimed, never treated as a live engine" {
    try testing.expectEqual(Decision.reclaim, decide(.socket, false));
}

test "a live listener is refused so a running engine is never hijacked" {
    try testing.expectEqual(Decision.refuse_live, decide(.socket, true));
}

test "a regular file is refused so --socket can never delete user data" {
    try testing.expectEqual(Decision.refuse_non_socket, decide(.regular, false));
}

test "a directory, symlink, FIFO or unreadable path is refused" {
    try testing.expectEqual(Decision.refuse_non_socket, decide(.directory, false));
    try testing.expectEqual(Decision.refuse_non_socket, decide(.other, false));
    // Even if an inspector somehow reported a listener, a non-socket path is
    // still not ours to unlink.
    try testing.expectEqual(Decision.refuse_non_socket, decide(.other, true));
}

/// Create a private short-path directory under /tmp. Unix socket paths cap at
/// 108 bytes, so the test dir must stay short and unique per process.
fn makeTestDir(buf: []u8, tag: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, "/tmp/nebula-lc-{d}-{s}", .{ linux.getpid(), tag });
    std.Io.Dir.createDirAbsolute(std.testing.io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return path;
}

fn removeTestDir(path: []const u8) void {
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), std.testing.io, path) catch {};
}

test "kindOf separates absent, regular, directory and socket paths" {
    var dir_buf: [96]u8 = undefined;
    const dir_path = try makeTestDir(&dir_buf, "kind");
    defer removeTestDir(dir_path);

    // Regular file inside the temp dir.
    {
        var file_buf: [128]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_buf, "{s}/plain.txt", .{dir_path});
        const f = try std.Io.Dir.createFileAbsolute(std.testing.io, file_path, .{});
        f.close(std.testing.io);
        try testing.expectEqual(Kind.regular, kindOf(file_path));
        try testing.expect(!isListening(file_path));
        try testing.expectEqual(Decision.refuse_non_socket, decide(kindOf(file_path), false));
    }

    // A directory is never mistaken for a socket.
    try testing.expectEqual(Kind.directory, kindOf(dir_path));

    // A real bound socket is recognised as a socket and, once listening,
    // proves that a live listener exists.
    {
        var sock_buf: [128]u8 = undefined;
        const sock_path = try std.fmt.bufPrint(&sock_buf, "{s}/probe.sock", .{dir_path});

        try testing.expectEqual(Kind.absent, kindOf(sock_path));
        try testing.expectEqual(Decision.start, decide(kindOf(sock_path), isListening(sock_path)));

        const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        try testing.expect(@as(isize, @bitCast(fd_rc)) >= 0);
        const fd: i32 = @intCast(fd_rc);
        var addr: linux.sockaddr.un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.family = linux.AF.UNIX;
        @memcpy(addr.path[0..sock_path.len], sock_path);
        try testing.expectEqual(@as(usize, 0), linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
        try testing.expectEqual(@as(usize, 0), linux.listen(fd, 4));

        try testing.expectEqual(Kind.socket, kindOf(sock_path));
        try testing.expect(isListening(sock_path));
        try testing.expectEqual(Decision.refuse_live, decide(kindOf(sock_path), isListening(sock_path)));

        // Close the listener: the file remains, but the engine behind it is
        // gone, so the path must be classified as reclaimable.
        _ = linux.close(fd);
        try testing.expectEqual(Kind.socket, kindOf(sock_path));
        try testing.expect(!isListening(sock_path));
        try testing.expectEqual(Decision.reclaim, decide(kindOf(sock_path), isListening(sock_path)));

        // Reclaiming removes exactly the dead socket and nothing else.
        try reclaim(sock_path);
        try testing.expectEqual(Kind.absent, kindOf(sock_path));
    }
}

test "kindOf does not follow a symlink into a regular file" {
    var dir_buf: [96]u8 = undefined;
    const dir_path = try makeTestDir(&dir_buf, "link");
    defer removeTestDir(dir_path);

    var target_buf: [128]u8 = undefined;
    const target_path = try std.fmt.bufPrint(&target_buf, "{s}/target.txt", .{dir_path});
    const f = try std.Io.Dir.createFileAbsolute(std.testing.io, target_path, .{});
    f.close(std.testing.io);

    var link_buf: [128]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/link.sock", .{dir_path});
    try std.Io.Dir.symLinkAbsolute(std.testing.io, target_path, link_path, .{});

    // Following the link would report a regular file; lstat semantics keep the
    // symlink itself visible, and start-up refuses either way.
    try testing.expectEqual(Kind.other, kindOf(link_path));
    try testing.expectEqual(Decision.refuse_non_socket, decide(kindOf(link_path), false));
}

test "the lifetime lock admits one holder and refuses a second" {
    var dir_buf: [96]u8 = undefined;
    const dir_path = try makeTestDir(&dir_buf, "lock");
    defer removeTestDir(dir_path);

    var sock_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&sock_buf, "{s}/lock.sock", .{dir_path});

    var first = try Lock.acquire(sock_path);
    defer first.release();

    try testing.expectError(error.AlreadyServing, Lock.acquire(sock_path));

    first.release();
    var second = try Lock.acquire(sock_path);
    second.release();
}

test "the lifetime lock reports a missing directory instead of crashing" {
    try testing.expectError(
        error.DirectoryMissing,
        Lock.acquire("/nonexistent-nebula-test-dir/ctl.sock"),
    );
}
