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
        var envp = [_]?[*:0]const u8{null};
        _ = std.os.linux.execve(p0, @ptrCast(av[0..].ptr), @ptrCast(envp[0..].ptr));
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
        \\rex — cipher-rex multiplexer CLI
        \\  rex serve [--socket PATH]
        \\  rex ls
        \\  rex spawn [--cols N] [--rows N] [-- cmd...]
        \\  rex split <pane> [-- cmd...]
        \\  rex send <pane> <text>
        \\  rex capture <pane> [--scrollback] [-n N]
        \\  rex run [--wait] <pane> <cmd...>
        \\  rex resize <pane> <cols> <rows>
        \\  rex close <pane>
        \\  rex attach <pane>
        \\
    ;
    _ = std.c.write(2, msg.ptr, msg.len);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    // args: []const [*:0]const u8 -> [][]const u8
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    for (init.args.vector) |a| try arg_list.append(allocator, std.mem.span(a));
    const args = arg_list.items;

    if (args.len < 2) {
        usage();
        return error.Usage;
    }
    const cmd = args[1];
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
        var srv = try server_mod.Server.init(allocator, sock);
        defer srv.deinit();
        std.debug.print("rex: serving on {s}\n", .{sock});
        try srv.run();
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

    usage();
    return error.Usage;
}
