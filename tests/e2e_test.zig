//! Headless end-to-end check of the multiplexer product surface.
//!
//! This test drives the *shipped* CLI (`rex`, the Nebula engine front end)
//! against a live engine on a private unix socket. It needs no display, no
//! compositor and no GPU: it is the cheapest honest evidence that the
//! spawn / run / capture / split / close lifecycle still works as a product,
//! and it exercises the same `protocol.zig` request builders the terminal
//! uses, so a wire-format drift fails here instead of in a demo.
//!
//! The engine binary path is injected by `build.zig` through the
//! `build_options` module (`rex_exe`), so the test always runs the artifact
//! built from this checkout rather than whatever happens to be on PATH.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const protocol = @import("protocol");

const testing = std.testing;
const io = testing.io;

/// Total budget for one CLI call; a hung engine must fail the test, not hang CI.
const cli_timeout_ns: u64 = 20 * std.time.ns_per_s;
const server_start_budget_ns: u64 = 5 * std.time.ns_per_s;

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * std.time.ns_per_s + ts.nsec;
}

/// One `rex` invocation against `socket_path`. Owns the returned stdout.
const Cli = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *Cli) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
        self.* = undefined;
    }

    fn crashed(self: *const Cli) bool {
        return self.term != .exited;
    }
};

fn cli(socket_path: []const u8, args: []const []const u8) !Cli {
    // Subcommand first, then the socket override, then subcommand arguments:
    // the CLI consumes `--socket PATH` immediately after the subcommand.
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, build_options.rex_exe);
    try argv.append(testing.allocator, args[0]);
    try argv.appendSlice(testing.allocator, &.{ "--socket", socket_path });
    try argv.appendSlice(testing.allocator, args[1..]);

    const res = try std.process.run(testing.allocator, io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(cli_timeout_ns), .clock = .boot } },
    });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .term = res.term };
}

fn expectOk(c: *const Cli, what: []const u8) !void {
    if (c.crashed()) {
        std.debug.print("{s}: engine CLI terminated abnormally: {any}\n", .{ what, c.term });
        return error.CliCrashed;
    }
    const exited = c.term.exited;
    if (exited != 0) {
        std.debug.print("{s}: exit {d}\nstderr:\n{s}\nstdout:\n{s}\n", .{ what, exited, c.stderr, c.stdout });
        return error.CliFailed;
    }
}

/// Parse one CLI reply line. `rex ls/spawn/...` pretty-prints JSON, which the
/// protocol parser accepts because JSON allows interior whitespace.
fn parseReply(alloc: std.mem.Allocator, text: []const u8) !protocol.Reply {
    return protocol.Reply.parse(alloc, text);
}

fn socketConnectable(path: [:0]const u8) bool {
    const fd_rc = std.os.linux.socket(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | std.os.linux.SOCK.NONBLOCK,
        0,
    );
    if (@as(i64, @bitCast(fd_rc)) < 0) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    var addr: std.os.linux.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.os.linux.AF.UNIX;
    if (path.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path.len], path);
    const rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
    if (@as(i64, @bitCast(rc)) == 0) return true;
    const e = std.os.linux.errno(rc);
    return e == .AGAIN or e == .INPROGRESS;
}

test "mux engine: spawn, run, capture, resize, split, close over a private socket" {
    const alloc = testing.allocator;

    // Unix socket paths cap at 107 bytes, so use a short /tmp directory with a
    // pid + clock suffix rather than the (long) .zig-cache test tmp dir.
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(
        &dir_buf,
        "/tmp/cipherdesk-mux-e2e-{d}-{d}",
        .{ std.os.linux.getpid(), @as(u64, @intCast(@mod(nowNs(), 1_000_000))) },
    );
    var path_buf: [128]u8 = @splat(0);
    const sock_plain = try std.fmt.bufPrint(&path_buf, "{s}/sock", .{dir});
    const sock_path = path_buf[0..sock_plain.len :0];

    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Start the engine ourselves (not via the CLI's auto-spawn) so the test
    // owns it and can always shut it down.
    var engine = try std.process.spawn(io, .{
        .argv = &.{ build_options.rex_exe, "serve", "--socket", sock_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        // kill() releases the handle (id becomes null), so wait only if the
        // engine has not already been reaped.
        engine.kill(io);
        if (engine.id != null) _ = engine.wait(io) catch {};
    }

    const deadline = nowNs() + @as(i64, @intCast(server_start_budget_ns));
    while (!socketConnectable(sock_path)) {
        if (nowNs() > deadline) {
            std.debug.print("engine did not create {s} within {d} ms\n", .{ sock_path, server_start_budget_ns / std.time.ns_per_ms });
            return error.EngineDidNotStart;
        }
        sleepMs(20);
    }

    // 1. Empty pane list on a fresh engine.
    {
        var c = try cli(sock_path, &.{"ls"});
        defer c.deinit();
        try expectOk(&c, "ls (fresh)");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expect(reply.ok());
        try testing.expectEqual(@as(usize, 0), reply.paneCount());
        std.debug.print("MUX_E2E_LS_EMPTY_OK\n", .{});
    }

    // 2. Spawn a pane; the id must come back from the real spawn reply.
    var first_pane: u32 = 0;
    {
        var c = try cli(sock_path, &.{ "spawn", "--cols", "100", "--rows", "30", "--", "/bin/sh" });
        defer c.deinit();
        try expectOk(&c, "spawn");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expect(reply.ok());
        first_pane = reply.paneId() orelse return error.NoPaneId;
        try testing.expect(first_pane > 0);
        std.debug.print("MUX_E2E_SPAWN_OK pane={d}\n", .{first_pane});
    }

    // 3. run --wait executes in the pane and returns its output.
    var run_cmd_buf: [96]u8 = undefined;
    const marker = "MUX_E2E_MARKER_1";
    const run_cmd = try std.fmt.bufPrint(&run_cmd_buf, "echo {s}", .{marker});
    {
        var id_buf: [16]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{first_pane});
        var c = try cli(sock_path, &.{ "run", "--wait", id_str, run_cmd });
        defer c.deinit();
        try expectOk(&c, "run --wait");
        try testing.expect(std.mem.indexOf(u8, c.stdout, marker) != null);
        std.debug.print("MUX_E2E_RUN_WAIT_OK output carries {s}\n", .{marker});
    }

    // 4. capture returns the same visible screen text as raw output.
    {
        var id_buf: [16]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{first_pane});
        var c = try cli(sock_path, &.{ "capture", id_str });
        defer c.deinit();
        try expectOk(&c, "capture");
        try testing.expect(std.mem.indexOf(u8, c.stdout, marker) != null);
        std.debug.print("MUX_E2E_CAPTURE_OK\n", .{});
    }

    // 5. resize is acknowledged with the geometry the engine will use.
    {
        var id_buf: [16]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{first_pane});
        var c = try cli(sock_path, &.{ "resize", id_str, "132", "43" });
        defer c.deinit();
        try expectOk(&c, "resize");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expect(reply.ok());
        try testing.expectEqual(132.0, reply.value.get("cols").?.numOf().?);
        try testing.expectEqual(43.0, reply.value.get("rows").?.numOf().?);
        std.debug.print("MUX_E2E_RESIZE_OK\n", .{});
    }

    // 6. split creates a distinct pane from the first one.
    var second_pane: u32 = 0;
    {
        var id_buf: [16]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{first_pane});
        var c = try cli(sock_path, &.{ "split", id_str, "--", "/bin/sh" });
        defer c.deinit();
        try expectOk(&c, "split");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expect(reply.ok());
        second_pane = reply.paneId() orelse return error.NoPaneId;
        try testing.expect(second_pane != first_pane);
        std.debug.print("MUX_E2E_SPLIT_OK pane={d}\n", .{second_pane});
    }

    // 7. ls reports both panes alive, and the first-alive helper agrees.
    {
        var c = try cli(sock_path, &.{"ls"});
        defer c.deinit();
        try expectOk(&c, "ls (two panes)");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expectEqual(@as(usize, 2), reply.paneCount());
        try testing.expect(reply.firstAlivePane() != null);
        std.debug.print("MUX_E2E_LS_TWO_OK\n", .{});
    }

    // 8. Close both panes; ls must show none alive and the engine must survive
    //    (this is the regression the framework's own zombie-pane test guards).
    {
        var id_buf: [16]u8 = undefined;
        inline for (.{ first_pane, second_pane }) |pane| {
            const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{pane});
            var c = try cli(sock_path, &.{ "close", id_str });
            defer c.deinit();
            try expectOk(&c, "close");
            var reply = try parseReply(alloc, c.stdout);
            defer reply.deinit();
            try testing.expect(reply.ok());
        }
        var c = try cli(sock_path, &.{"ls"});
        defer c.deinit();
        try expectOk(&c, "ls (after close)");
        var reply = try parseReply(alloc, c.stdout);
        defer reply.deinit();
        try testing.expect(reply.ok());
        try testing.expect(reply.firstAlivePane() == null);
        std.debug.print("MUX_E2E_CLOSE_OK engine alive, no panes\n", .{});
    }
}
