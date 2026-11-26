//! Real socket-lifecycle integration tests for the Nebula engine.
//!
//! These drive the *shipped* `nebula` binary (path injected by `build.zig` via
//! `build_options.nebula_exe`), not a unit-test double. Every assertion below
//! is about a failure mode that used to be silent:
//!
//!   - a second `serve` used to unlink a live engine's socket and bind over
//!     it, leaving two engines on one address;
//!   - `serve --socket <regular file>` used to delete that file;
//!   - `SIGTERM` used to kill the engine without unlinking the socket, leaving
//!     a path that looked live to any `exists()`-based check;
//!   - a stale socket left by `SIGKILL` must still be reclaimable.
//!
//! They run headless: no display, no compositor, no GPU.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lifecycle = @import("socket_lifecycle");

const testing = std.testing;
const io = testing.io;
const linux = std.os.linux;

const start_budget_ns: u64 = 5 * std.time.ns_per_s;

fn sleepMs(ms: u64) void {
    var ts = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&ts, null);
}

fn nowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

/// Short, unique, per-process directory: Unix socket paths cap at 108 bytes,
/// far less than `.zig-cache` test temp paths.
fn makeDir(buf: []u8, tag: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrint(buf, "/tmp/nebula-live-{d}-{s}", .{ linux.getpid(), tag });
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return path;
}

fn removeDir(path: []const u8) void {
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, path) catch {};
}

/// Wait until the engine accepts a connection, or fail.
fn waitListening(path: []const u8, budget_ns: u64) !void {
    const deadline = nowNs() + @as(i64, @intCast(budget_ns));
    while (nowNs() < deadline) {
        if (lifecycle.isListening(path)) return;
        sleepMs(20);
    }
    std.debug.print("engine never accepted on {s}\n", .{path});
    return error.EngineDidNotStart;
}

fn waitAbsent(path: []const u8, budget_ns: u64) !void {
    const deadline = nowNs() + @as(i64, @intCast(budget_ns));
    while (nowNs() < deadline) {
        if (lifecycle.kindOf(path) == .absent) return;
        sleepMs(20);
    }
    std.debug.print("{s} was not removed\n", .{path});
    return error.SocketNotRemoved;
}

fn spawnServe(sock_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ build_options.nebula_exe, "serve", "--socket", sock_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

/// Best-effort teardown. `Child.kill` reaps the process itself and nulls `id`,
/// so calling `wait` afterwards is a programmer error.
fn stopEngine(engine: *std.process.Child) void {
    if (engine.id != null) engine.kill(io);
}

/// Send SIGTERM and reap, returning the exit status.
fn terminate(engine: *std.process.Child) !std.process.Child.Term {
    const pid = engine.id orelse return error.NoPid;
    try std.posix.kill(pid, .TERM);
    return engine.wait(io);
}

test "a second serve is refused and never hijacks a live engine" {
    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "hijack");
    defer removeDir(dir);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/ctl.sock", .{dir});

    var first = try spawnServe(sock);
    defer stopEngine(&first);
    try waitListening(sock, start_budget_ns);

    // The engine is live: start-up must refuse, with the documented exit code.
    const res = try std.process.run(testing.allocator, io, .{
        .argv = &.{ build_options.nebula_exe, "serve", "--socket", sock },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(.exited, std.meta.activeTag(res.term));
    try testing.expectEqual(lifecycle.exit_address_in_use, res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stderr, "already serving") != null);

    // The original engine is untouched and still owns the address.
    try testing.expect(first.id != null);
    try testing.expect(lifecycle.isListening(sock));
    try testing.expectEqual(lifecycle.Kind.socket, lifecycle.kindOf(sock));

    std.debug.print("NEBULA_LIFECYCLE_HIJACK_REFUSED\n", .{});
}

test "serve refuses to delete a regular file named by --socket" {
    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "file");
    defer removeDir(dir);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/precious.txt", .{dir});

    const payload = "IMPORTANT USER DATA";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, payload);
    f.close(io);

    const res = try std.process.run(testing.allocator, io, .{
        .argv = &.{ build_options.nebula_exe, "serve", "--socket", path },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(.exited, std.meta.activeTag(res.term));
    try testing.expectEqual(lifecycle.exit_unsafe_path, res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stderr, "not a socket") != null);

    // The file is untouched, still a regular file, with its bytes intact.
    try testing.expectEqual(lifecycle.Kind.regular, lifecycle.kindOf(path));
    const contents = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        testing.allocator,
        .limited(4096),
    );
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(payload, contents);

    std.debug.print("NEBULA_LIFECYCLE_FILE_PRESERVED\n", .{});
}

test "SIGTERM shuts down cleanly and removes the socket" {
    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "term");
    defer removeDir(dir);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/ctl.sock", .{dir});

    var engine = try spawnServe(sock);
    defer stopEngine(&engine);
    try waitListening(sock, start_budget_ns);

    const term = try terminate(&engine);
    try testing.expectEqual(.exited, std.meta.activeTag(term));
    try testing.expectEqual(@as(u8, 0), term.exited);

    // Graceful shutdown means the socket file and its lease are gone, not just
    // that the process exited.
    try waitAbsent(sock, start_budget_ns);
    var lock_buf: [160]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{sock});
    try waitAbsent(lock_path, start_budget_ns);

    std.debug.print("NEBULA_LIFECYCLE_SIGTERM_CLEAN\n", .{});
}

test "auto-spawned panes inherit the caller's shell environment" {
    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "environment");
    defer removeDir(dir);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/ctl.sock", .{dir});
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", "/tmp/nebula-environment-home");
    try env.put("NEBULA_TEST_SENTINEL", "preserved");
    try env.put("CIPHER_REX_SOCK", sock);

    const spawned = try std.process.run(testing.allocator, io, .{
        .argv = &.{ build_options.nebula_exe, "spawn", "--", "/bin/sh" },
        .environ_map = &env,
    });
    defer testing.allocator.free(spawned.stdout);
    defer testing.allocator.free(spawned.stderr);
    try testing.expectEqual(.exited, std.meta.activeTag(spawned.term));
    try testing.expectEqual(@as(u8, 0), spawned.term.exited);

    const command = "printf 'PANE_HOME=%s PANE_SENTINEL=%s\\n' \"$HOME\" \"$NEBULA_TEST_SENTINEL\"\n";
    const res = try std.process.run(testing.allocator, io, .{
        .argv = &.{ build_options.nebula_exe, "run", "--wait", "1", command },
        .environ_map = &env,
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(.exited, std.meta.activeTag(res.term));
    try testing.expectEqual(@as(u8, 0), res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "PANE_HOME=/tmp/nebula-environment-home PANE_SENTINEL=preserved") != null);

    const pid = try std.process.run(testing.allocator, io, .{
        .argv = &.{ "/usr/bin/lsof", "-t", sock },
        .environ_map = &env,
    });
    defer testing.allocator.free(pid.stdout);
    defer testing.allocator.free(pid.stderr);
    const engine_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid.stdout, " \n"), 10);
    try std.posix.kill(engine_pid, .TERM);
    try waitAbsent(sock, start_budget_ns);
    std.debug.print("NEBULA_ENVIRONMENT_PRESERVED\n", .{});
}

test "a stale socket left by SIGKILL is reclaimed by the next serve" {

    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "stale");
    defer removeDir(dir);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/ctl.sock", .{dir});

    var victim = try spawnServe(sock);
    try waitListening(sock, start_budget_ns);
    // SIGKILL cannot run the shutdown path, which is exactly how a stale
    // socket file is produced in the field. `Child.kill` is not usable here:
    // it sends SIGTERM, which this engine now handles gracefully.
    const victim_pid = victim.id orelse return error.NoPid;
    try std.posix.kill(victim_pid, .KILL);
    _ = try victim.wait(io);

    try testing.expectEqual(lifecycle.Kind.socket, lifecycle.kindOf(sock));
    try testing.expect(!lifecycle.isListening(sock));

    var replacement = try spawnServe(sock);
    defer stopEngine(&replacement);
    try waitListening(sock, start_budget_ns);
    try testing.expectEqual(lifecycle.Kind.socket, lifecycle.kindOf(sock));

    // The reclaimed engine is fully functional, not just bound.
    const res = try std.process.run(testing.allocator, io, .{
        .argv = &.{ build_options.nebula_exe, "hello", "--socket", sock },
    });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(.exited, std.meta.activeTag(res.term));
    try testing.expectEqual(@as(u8, 0), res.term.exited);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "cipher-rex") != null);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "\"version\": 1") != null);

    std.debug.print("NEBULA_LIFECYCLE_STALE_RECLAIMED\n", .{});
}

test "a clean shutdown is immediately restartable on the same path" {
    var dir_buf: [96]u8 = undefined;
    const dir = try makeDir(&dir_buf, "restart");
    defer removeDir(dir);
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/ctl.sock", .{dir});

    inline for (0..2) |round| {
        var engine = try spawnServe(sock);
        defer stopEngine(&engine);
        try waitListening(sock, start_budget_ns);

        const res = try std.process.run(testing.allocator, io, .{
            .argv = &.{ build_options.nebula_exe, "hello", "--socket", sock },
        });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        try testing.expectEqual(.exited, std.meta.activeTag(res.term));
        try testing.expectEqual(@as(u8, 0), res.term.exited);

        const term = try terminate(&engine);
        try testing.expectEqual(@as(u8, 0), term.exited);
        try waitAbsent(sock, start_budget_ns);
        _ = round;
    }

    std.debug.print("NEBULA_LIFECYCLE_RESTART_OK\n", .{});
}
