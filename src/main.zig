//! rex — scriptable CLI for the cipher-rex multiplexer server.
//!
//!   rex serve [--socket PATH]                  run the server (foreground)
//!   rex ls                                      list panes (JSON)
//!   rex spawn [--cols N] [--rows N] [-- cmd…]   spawn a pane (JSON with id)
//!   rex split <pane> [-- cmd…]                  new pane split from <pane>
//!   rex send <pane> <text>                      send input bytes to a pane
//!   rex capture <pane> [--scrollback] [-n N]    capture text (raw text out)
//!   rex run [--wait] <pane> <cmd…>              run a command in a pane
//!   rex resize <pane> <cols> <rows>
//!   rex close <pane>
//!   rex attach <pane>                           stream attach + output events
//!
//! If the socket does not exist, the server is auto-spawned (fork+exec self).
const std = @import("std");
const term = @import("term");
const mux = @import("mux");
const socket_lifecycle = @import("socket_lifecycle");
const json = term.json;
const server_mod = term.server;
const pty_mod = term.pty;

fn connect(path: []const u8) !i32 {
    const fd_rc = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_rc);
    var addr: std.os.linux.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.os.linux.AF.UNIX;
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    const rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
    if (@as(i64, @bitCast(rc)) < 0) {
        _ = std.os.linux.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

fn writeAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

fn readLine(fd: i32, allocator: std.mem.Allocator, max: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (out.items.len < max) {
        const rc = std.os.linux.read(fd, &buf, buf.len);
        if (@as(i64, @bitCast(rc)) < 0) return error.ReadFailed;
        const n: usize = @intCast(rc);
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl| {
            try out.appendSlice(allocator, buf[0..nl]);
            return out.toOwnedSlice(allocator);
        }
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn childFail() noreturn {
    _ = std.os.linux.exit(127);
}

fn z(alloc: std.mem.Allocator, s: []const u8) ![*:0]u8 {
    const b = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(b, s);
    return b.ptr;
}

/// Ensure a server is listening; auto-spawn if not.
fn ensureServer(path: []const u8) !void {
    if (connect(path)) |fd| {
        _ = std.os.linux.close(fd);
        return;
    } else |_| {}
    const pid_rc = std.os.linux.fork();
    if (@as(i64, @bitCast(pid_rc)) < 0) return error.ForkFailed;
    if (pid_rc == 0) {
        // child: detach, silence stdio, exec self as "serve --socket path"
        _ = std.os.linux.setsid();
        const devnull = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch childFail();
        _ = std.os.linux.dup2(devnull, 0);
        _ = std.os.linux.dup2(devnull, 1);
        _ = std.os.linux.dup2(devnull, 2);
        var exe_buf: [4096]u8 = undefined;
        const n = std.os.linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        if (@as(i64, @bitCast(n)) <= 0) childFail();
        const exe_len: usize = @intCast(n);
        const alloc = std.heap.page_allocator;
        const p0 = z(alloc, exe_buf[0..exe_len]) catch childFail();
        const p1 = z(alloc, "serve") catch childFail();
        const p2 = z(alloc, "--socket") catch childFail();
        const p3 = z(alloc, path) catch childFail();
        var av = [_]?[*:0]const u8{ p0, p1, p2, p3, null };
        // Auto-spawned servers must retain the user's environment: HOME,
        // PATH, locale and XDG_RUNTIME_DIR are needed by programs in panes.
        _ = std.os.linux.execve(p0, @ptrCast(av[0..].ptr), @ptrCast(std.c.environ));
        childFail();
    }
    // parent: wait for the socket (up to 3 s)
    const deadline = pty_mod.nowNs() + 3 * 1_000_000_000;
    while (pty_mod.nowNs() < deadline) {
        if (connect(path)) |fd| {
            _ = std.os.linux.close(fd);
            return;
        } else |_| {}
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50 * 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.ServerDidNotStart;
}

/// Send one request line, read one reply line.
fn rpc(allocator: std.mem.Allocator, path: []const u8, req: []const u8) ![]u8 {
    try ensureServer(path);
    const fd = try connect(path);
    defer _ = std.os.linux.close(fd);
    try writeAll(fd, req);
    try writeAll(fd, "\n");
    return try readLine(fd, allocator, 16 * 1024 * 1024);
}

/// Send one structured request and read one reply line. Request bytes are
/// produced by the shared contract module so both products speak one dialect.
fn rpcRequest(allocator: std.mem.Allocator, path: []const u8, req: mux.Request) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try mux.writeRequest(allocator, &buf, req);
    return rpc(allocator, path, buf.items);
}

fn appendPad(out: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    var k: usize = 0;
    while (k < depth) : (k += 1) try out.appendSlice(allocator, "  ");
}

fn prettyInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: json.Value, depth: usize) !void {
    switch (v) {
        .obj => |o| {
            if (o.len == 0) return out.appendSlice(allocator, "{}");
            try out.append(allocator, '{');
            for (o, 0..) |e, i| {
                if (i > 0) try out.append(allocator, ',');
                try out.append(allocator, '\n');
                try appendPad(out, allocator, depth + 1);
                try json.writeStrInto(out, allocator, e.key);
                try out.appendSlice(allocator, ": ");
                try prettyInto(out, allocator, e.value, depth + 1);
            }
            try out.append(allocator, '\n');
            try appendPad(out, allocator, depth);
            try out.append(allocator, '}');
        },
        .arr => |a| {
            if (a.len == 0) return out.appendSlice(allocator, "[]");
            try out.append(allocator, '[');
            for (a, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try out.append(allocator, '\n');
                try appendPad(out, allocator, depth + 1);
                try prettyInto(out, allocator, item, depth + 1);
            }
            try out.append(allocator, '\n');
            try appendPad(out, allocator, depth);
            try out.append(allocator, ']');
        },
        else => try json.writeValueIntoPub(out, allocator, v),
    }
}

fn printJson(allocator: std.mem.Allocator, line: []const u8) !void {
    const v = try json.Parser.parse(allocator, line);
    defer json.freeValue(allocator, v);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try prettyInto(&out, allocator, v, 0);
    try out.append(allocator, '\n');
    _ = std.c.write(1, out.items.ptr, out.items.len);
}

fn usage() void {
    const msg =
        \\nebula — native terminal multiplexer
        \\  nebula serve [--socket PATH]
        \\  nebula hello
        \\  nebula detach
        \\  nebula ls
        \\  nebula spawn [--cols N] [--rows N] [-- cmd...]
        \\  nebula split <pane> [-- cmd...]
        \\  nebula send <pane> <text>
        \\  nebula capture <pane> [--scrollback] [-n N]
        \\  nebula run [--wait] <pane> <cmd...>
        \\  nebula resize <pane> <cols> <rows>
        \\  nebula close <pane>
        \\  nebula attach <pane>
        \\
        \\The legacy cipher-rex protocol and CIPHER_REX_SOCK are preserved for
        \\compatibility. Nebula is the product name; Rex is an external competitor.
        \\
    ;
    _ = std.c.write(1, msg.ptr, msg.len);
}

fn usageError(message: []const u8) u8 {
    _ = std.c.write(2, message.ptr, message.len);
    _ = std.c.write(2, "\n", 1);
    return 2;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

/// Apply [`socket_lifecycle.decide`] to the live filesystem and either prepare
/// the path for binding or exit with a documented code and diagnostic.
///
/// Split out of `main` so the start-up policy is readable in one place, and so
/// the same check can run both before and after taking the lifetime lease.
/// This never returns on a refusal: it exits the process, so a caller cannot
/// accidentally continue past an unsafe path.
fn bindOrExit(sock: []const u8) void {
    const observed = socket_lifecycle.probe(sock);
    switch (socket_lifecycle.decide(observed.kind, observed.listening)) {
        .start => return,
        .reclaim => {
            socket_lifecycle.reclaim(sock) catch {
                std.debug.print("nebula: cannot reclaim stale socket {s}\n", .{sock});
                std.process.exit(socket_lifecycle.exit_unsafe_path);
            };
            return;
        },
        .refuse_live => {
            std.debug.print(
                "nebula: refusing to hijack the live engine already serving on {s}\n",
                .{sock},
            );
            std.process.exit(socket_lifecycle.exit_address_in_use);
        },
        .refuse_non_socket => {
            std.debug.print(
                "nebula: refusing to use {s}: it exists and is not a socket\n",
                .{sock},
            );
            std.process.exit(socket_lifecycle.exit_unsafe_path);
        },
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    // args: []const [*:0]const u8 -> [][]const u8
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    for (init.args.vector) |a| try arg_list.append(allocator, std.mem.span(a));
    const args = arg_list.items;

    if (args.len == 1 or (args.len == 2 and isHelpFlag(args[1]))) {
        usage();
        return;
    }
    if (args.len == 2 and isVersionFlag(args[1])) {
        _ = std.c.write(1, "nebula 0.1.0\n", 13);
        return;
    }
    if (args.len < 2) {
        _ = usageError("nebula: a command is required");
        return;
    }
    const cmd = args[1];
    if (isHelpFlag(cmd)) {
        usage();
        return;
    }
    if (isVersionFlag(cmd)) {
        _ = std.c.write(1, "nebula 0.1.0\n", 13);
        return;
    }
    // Socket path comes from the shared contract module, so the engine and
    // the terminal cannot disagree about where the control socket lives.
    var socket_buf: [256]u8 = undefined;
    const env_sock: ?[]const u8 = if (std.c.getenv(mux.socket_env)) |p| std.mem.span(p) else null;
    const env_runtime: ?[]const u8 = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else null;
    const resolved = mux.socketPath(env_sock, env_runtime, &socket_buf);
    const socket_path: []const u8 = if (resolved.len > 0) resolved else mux.fallback_socket;
    var i: usize = 2;
    var sock_override: ?[]const u8 = null;
    while (i + 1 < args.len and std.mem.eql(u8, args[i], "--socket")) {
        sock_override = args[i + 1];
        i += 2;
    }
    const sock: []const u8 = sock_override orelse socket_path;

    if (std.mem.eql(u8, cmd, "serve")) {
        // Start-up is a product decision, not a blind unlink: refuse to steal a
        // live engine's socket, refuse to delete a path that is not a socket,
        // and reclaim only a socket that provably has no listener behind it.
        if (sock.len >= socket_lifecycle.max_socket_path) {
            std.debug.print("nebula: socket path is too long for a unix socket: {s}\n", .{sock});
            std.process.exit(socket_lifecycle.exit_unsafe_path);
        }

        // Refuse on the first observation, before creating a lock file, so a
        // rejected start never litters the directory the user pointed at.
        bindOrExit(sock);

        // Only now create the lifetime lease. It closes the race between two
        // engines that observed the same path at the same instant.
        var lease = socket_lifecycle.Lock.acquire(sock) catch |e| {
            switch (e) {
                error.AlreadyServing => {
                    std.debug.print("nebula: another engine is already serving on {s}\n", .{sock});
                    std.process.exit(socket_lifecycle.exit_address_in_use);
                },
                error.DirectoryMissing => {
                    std.debug.print("nebula: socket directory does not exist for {s}\n", .{sock});
                    std.process.exit(socket_lifecycle.exit_unsafe_path);
                },
                error.PermissionDenied => {
                    std.debug.print("nebula: no permission to lock {s}.lock\n", .{sock});
                    std.process.exit(socket_lifecycle.exit_lock_failed);
                },
                else => {
                    std.debug.print("nebula: cannot lock {s}.lock\n", .{sock});
                    std.process.exit(socket_lifecycle.exit_lock_failed);
                },
            }
        };
        // Re-observe under the lease: an engine may have bound between the
        // first probe and the lock. Reclaim or refuse with the fresh facts.
        bindOrExit(sock);

        // The signal handler must target a value with a stable address for the
        // whole serving lifetime. `srv` is declared before any handler is
        // installed and is not moved afterwards, so its `running` field is the
        // one the handler flips; `srv.run()` re-reads it every poll iteration.
        var srv = try server_mod.Server.init(allocator, sock);
        defer {
            srv.deinit();
            // Socket is closed and unlinked by now, so releasing the lease
            // cannot admit a successor that binds underneath this engine.
            lease.release();
        }
        socket_lifecycle.installShutdownHandlers(&srv.running);
        std.debug.print("nebula: serving on {s}\n", .{sock});
        try srv.run();
        return;
    }

    if (std.mem.eql(u8, cmd, "hello")) {
        const line = try rpcRequest(allocator, sock, .hello);
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "detach")) {
        const line = try rpcRequest(allocator, sock, .detach);
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "ls")) {
        const line = try rpcRequest(allocator, sock, .ls);
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "spawn") or std.mem.eql(u8, cmd, "split")) {
        const is_split = std.mem.eql(u8, cmd, "split");
        var cols: u32 = 80;
        var rows: u32 = 24;
        var cmd_args = std.ArrayList([]const u8).empty;
        defer cmd_args.deinit(allocator);
        var pane: ?u32 = null;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--cols") and i + 1 < args.len) {
                cols = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, a, "--rows") and i + 1 < args.len) {
                rows = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            } else if (std.mem.eql(u8, a, "--")) {
                i += 1;
                while (i < args.len) : (i += 1) try cmd_args.append(allocator, args[i]);
                break;
            } else if (is_split and pane == null) {
                pane = try std.fmt.parseInt(u32, a, 10);
            } else {
                try cmd_args.append(allocator, a);
            }
        }
        if (is_split and pane == null) return error.Usage;
        if (cmd_args.items.len == 0) try cmd_args.append(allocator, "/bin/sh");
        var req = std.ArrayList(u8).empty;
        defer req.deinit(allocator);
        if (is_split) {
            try mux.writeRequest(allocator, &req, .{ .split = .{
                .pane = pane.?,
                .cols = cols,
                .rows = rows,
                .cmd = cmd_args.items,
            } });
        } else {
            try mux.writeRequest(allocator, &req, .{ .spawn = .{
                .cols = cols,
                .rows = rows,
                .cmd = cmd_args.items,
            } });
        }
        const line = try rpc(allocator, sock, req.items);
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "send")) {
        if (i + 1 >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        const text = args[i + 1];
        var req = std.ArrayList(u8).empty;
        defer req.deinit(allocator);
        try mux.writeRequest(allocator, &req, .{ .send = .{ .pane = pane, .data = text } });
        const line = try rpc(allocator, sock, req.items);
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "capture")) {
        if (i >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        i += 1;
        var scrollback = false;
        var lines: ?u32 = null;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--scrollback")) scrollback = true;
            if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
                lines = try std.fmt.parseInt(u32, args[i + 1], 10);
                i += 1;
            }
        }
        var req = std.ArrayList(u8).empty;
        defer req.deinit(allocator);
        try mux.writeRequest(allocator, &req, .{ .capture = .{
            .pane = pane,
            .scrollback = scrollback,
            .lines = lines,
        } });
        const line = try rpc(allocator, sock, req.items);
        defer allocator.free(line);
        const v = json.Parser.parse(allocator, line) catch {
            try printJson(allocator, line);
            return;
        };
        defer json.freeValue(allocator, v);
        if (v.get("text")) |t| {
            if (t.strOf()) |str| {
                _ = std.c.write(1, str.ptr, str.len);
                return;
            }
        }
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        var wait = false;
        if (i < args.len and std.mem.eql(u8, args[i], "--wait")) {
            wait = true;
            i += 1;
        }
        if (i >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        i += 1;
        var cmd_str = std.ArrayList(u8).empty;
        defer cmd_str.deinit(allocator);
        while (i < args.len) : (i += 1) {
            if (cmd_str.items.len > 0) try cmd_str.append(allocator, ' ');
            try cmd_str.appendSlice(allocator, args[i]);
        }
        var req = std.ArrayList(u8).empty;
        defer req.deinit(allocator);
        try mux.writeRequest(allocator, &req, .{ .run = .{
            .pane = pane,
            .cmd = cmd_str.items,
            .wait = wait,
        } });
        const line = try rpc(allocator, sock, req.items);
        defer allocator.free(line);
        if (wait) {
            const v = try json.Parser.parse(allocator, line);
            defer json.freeValue(allocator, v);
            if (v.get("output")) |o| {
                if (o.strOf()) |str| _ = std.c.write(1, str.ptr, str.len);
            }
            if (v.get("exit_code")) |ec| {
                if (ec.numOf()) |n| std.debug.print("[exit_code={d:.0}]\n", .{n});
            }
        } else {
            try printJson(allocator, line);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "resize")) {
        if (i + 2 >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        const cols = try std.fmt.parseInt(u32, args[i + 1], 10);
        const rows = try std.fmt.parseInt(u32, args[i + 2], 10);
        const line = try rpcRequest(allocator, sock, .{ .resize = .{ .pane = pane, .cols = cols, .rows = rows } });
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "close")) {
        if (i >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        const line = try rpcRequest(allocator, sock, .{ .close = pane });
        defer allocator.free(line);
        try printJson(allocator, line);
        return;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (i >= args.len) return error.Usage;
        const pane = try std.fmt.parseInt(u32, args[i], 10);
        try ensureServer(sock);
        const fd = try connect(sock);
        defer _ = std.os.linux.close(fd);
        var req = std.ArrayList(u8).empty;
        defer req.deinit(allocator);
        try mux.writeRequest(allocator, &req, .{ .attach = pane });
        try writeAll(fd, req.items);
        try writeAll(fd, "\n");
        var pending = std.ArrayList(u8).empty;
        defer pending.deinit(allocator);
        var buf: [65536]u8 = undefined;
        var first = true;
        while (true) {
            const rc = std.os.linux.read(fd, &buf, buf.len);
            if (@as(i64, @bitCast(rc)) < 0) {
                if (std.os.linux.errno(rc) == .INTR) continue;
                break;
            }
            const n: usize = @intCast(rc);
            if (n == 0) break;
            try pending.appendSlice(allocator, buf[0..n]);
            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
                const line = pending.items[0..nl];
                std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - nl - 1], pending.items[nl + 1 ..]);
                pending.items = pending.items[0 .. pending.items.len - nl - 1];
                if (first) {
                    first = false;
                    _ = std.c.write(1, line.ptr, line.len);
                    _ = std.c.write(1, "\n", 1);
                    continue;
                }
                const v = json.Parser.parse(allocator, line) catch continue;
                defer json.freeValue(allocator, v);
                if (v.get("event")) |ev| {
                    if (std.mem.eql(u8, ev.strOf() orelse "", "output")) {
                        if (v.get("data")) |d| {
                            if (d.strOf()) |b64| {
                                const raw = json.base64Decode(allocator, b64) catch continue;
                                defer allocator.free(raw);
                                _ = std.c.write(1, raw.ptr, raw.len);
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    std.process.exit(usageError("nebula: unknown command"));
}
