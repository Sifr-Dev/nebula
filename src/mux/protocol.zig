//! Multiplexer wire protocol — the product contract between the terminal
//! (Janus) and the multiplexer engine (Nebula).
//!
//! Today the engine is the `rex` CLI over the framework's `term.server`
//! module; the names in this file describe the *contract*, not a rename of
//! the implementation. Both apps must go through these request builders and
//! reply readers so the two products cannot drift into two private dialects
//! of the same JSON-lines socket while they still share a wire format.
//!
//! Wire facts this module pins (verified against the framework server in
//! `src/term/server.zig` at the tested candidate):
//!   - one JSON object per line, `\n`-terminated
//!   - replies carry `ok` (bool), and `error` (string) when `ok == false`
//!   - `ls` replies carry `panes: [{id, title, alive, cols, rows}]`
//!   - `attach` replies carry `event: "attach"`, `pane`, `cols`, `rows`,
//!     `replay` (base64 raw bytes) and `alive`
//!   - streamed `output` events carry base64 `data` for exactly one pane
//!
//! Nothing here spawns processes or opens sockets: it is pure request/reply
//! logic, so it is unit-testable without a display, a GPU, or a live server.
const std = @import("std");
const term = @import("term");
const json = term.json;

/// Protocol version the engine reports in its `hello` reply.
pub const version: u32 = 1;

/// Engine identity reported by `hello`; the CLI is named `rex` today.
pub const server_name = "cipher-rex";

/// Environment variable that overrides the control socket path.
pub const socket_env = "CIPHER_REX_SOCK";

/// Socket file name used inside `$XDG_RUNTIME_DIR`.
pub const socket_basename = "cipher-rex.sock";

/// Last-resort path when neither the env override nor `$XDG_RUNTIME_DIR`
/// is set. Kept exactly as the two apps had it so this module is a
/// behaviour-preserving extraction.
pub const fallback_socket = "/run/user/1000/cipher-rex.sock";

/// Resolve the control socket path from already-read environment values.
///
/// Precedence (unchanged from both apps): `CIPHER_REX_SOCK`, then
/// `$XDG_RUNTIME_DIR/<socket_basename>`, then [`fallback_socket`].
/// Returns an empty slice when `buf` is too small for the runtime-dir form;
/// callers then fall back to [`fallback_socket`], which is what the previous
/// inline `bufPrint(...) catch` behaviour did in practice.
pub fn socketPath(env_socket: ?[]const u8, xdg_runtime_dir: ?[]const u8, buf: []u8) []const u8 {
    if (env_socket) |p| {
        if (p.len > 0) return p;
    }
    if (xdg_runtime_dir) |dir| {
        if (dir.len > 0) {
            const formatted = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, socket_basename }) catch return "";
            return formatted;
        }
    }
    return fallback_socket;
}

/// One request in the JSON-lines protocol.
pub const Request = union(enum) {
    hello,
    ls,
    spawn: SpawnArgs,
    split: SplitArgs,
    send: SendArgs,
    capture: CaptureArgs,
    run: RunArgs,
    resize: ResizeArgs,
    close: u32,
    attach: u32,
    detach,

    pub const SpawnArgs = struct {
        cols: u32 = 80,
        rows: u32 = 24,
        cmd: []const []const u8,
        cwd: ?[]const u8 = null,
    };

    pub const SplitArgs = struct {
        pane: u32,
        cols: u32 = 80,
        rows: u32 = 24,
        cmd: []const []const u8,
    };

    pub const SendArgs = struct {
        pane: u32,
        data: []const u8,
    };

    pub const CaptureArgs = struct {
        pane: u32,
        scrollback: bool = false,
        lines: ?u32 = null,
    };

    pub const RunArgs = struct {
        pane: u32,
        cmd: []const u8,
        wait: bool = false,
    };

    pub const ResizeArgs = struct {
        pane: u32,
        cols: u32,
        rows: u32,
    };
};

/// Serialize `req` as one protocol line (no trailing newline) into `out`.
pub fn writeRequest(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    req: Request,
) !void {
    switch (req) {
        .hello => try out.appendSlice(alloc, "{\"op\":\"hello\"}"),
        .ls => try out.appendSlice(alloc, "{\"op\":\"ls\"}"),
        .detach => try out.appendSlice(alloc, "{\"op\":\"detach\"}"),
        .spawn => |a| {
            try out.appendSlice(alloc, "{\"op\":\"spawn\"");
            try appendCmdArray(alloc, out, a.cols, a.rows, a.cmd);
            if (a.cwd) |cwd| {
                try out.appendSlice(alloc, ",\"cwd\":");
                try appendString(alloc, out, cwd);
            }
            try out.append(alloc, '}');
        },
        .split => |a| {
            try out.appendSlice(alloc, "{\"op\":\"split\"");
            try out.print(alloc, ",\"pane\":{d}", .{a.pane});
            try appendCmdArray(alloc, out, a.cols, a.rows, a.cmd);
            try out.append(alloc, '}');
        },
        .send => |a| {
            try out.print(alloc, "{{\"op\":\"send\",\"pane\":{d},\"data\":", .{a.pane});
            try appendString(alloc, out, a.data);
            try out.append(alloc, '}');
        },
        .capture => |a| {
            try out.print(
                alloc,
                "{{\"op\":\"capture\",\"pane\":{d},\"scrollback\":{s}",
                .{ a.pane, if (a.scrollback) "true" else "false" },
            );
            if (a.lines) |n| try out.print(alloc, ",\"lines\":{d}", .{n});
            try out.append(alloc, '}');
        },
        .run => |a| {
            try out.print(
                alloc,
                "{{\"op\":\"run\",\"pane\":{d},\"wait\":{s},\"cmd\":",
                .{ a.pane, if (a.wait) "true" else "false" },
            );
            try appendString(alloc, out, a.cmd);
            try out.append(alloc, '}');
        },
        .resize => |a| try out.print(
            alloc,
            "{{\"op\":\"resize\",\"pane\":{d},\"cols\":{d},\"rows\":{d}}}",
            .{ a.pane, a.cols, a.rows },
        ),
        .close => |pane| try out.print(alloc, "{{\"op\":\"close\",\"pane\":{d}}}", .{pane}),
        .attach => |pane| try out.print(alloc, "{{\"op\":\"attach\",\"pane\":{d}}}", .{pane}),
    }
}

fn appendCmdArray(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cols: u32,
    rows: u32,
    cmd: []const []const u8,
) !void {
    try out.print(alloc, ",\"cols\":{d},\"rows\":{d},\"cmd\":[", .{ cols, rows });
    for (cmd, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendString(alloc, out, arg);
    }
    try out.append(alloc, ']');
}

fn appendString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const encoded = try json.writeValue(alloc, .{ .str = s });
    defer alloc.free(encoded);
    try out.appendSlice(alloc, encoded);
}

/// Parsed view of the fields the client apps actually consume from a reply.
pub const Reply = struct {
    alloc: std.mem.Allocator,
    value: json.Value,

    pub fn parse(alloc: std.mem.Allocator, line: []const u8) !Reply {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyReply;
        return .{ .alloc = alloc, .value = try json.Parser.parse(alloc, trimmed) };
    }

    pub fn deinit(self: *Reply) void {
        json.freeValue(self.alloc, self.value);
        self.* = undefined;
    }

    /// Server-reported success flag (`ok`).
    pub fn ok(self: *const Reply) bool {
        const v = self.value.get("ok") orelse return false;
        return v.* == .bool and v.bool;
    }

    /// Error message for a failed reply, if the engine sent one.
    pub fn errText(self: *const Reply) ?[]const u8 {
        const e = self.value.get("error") orelse return null;
        return e.strOf();
    }

    /// Pane id on `spawn`, `split`, `attach` and run replies.
    pub fn paneId(self: *const Reply) ?u32 {
        return idOf(self.value);
    }

    /// Pane id in an `ls` element.
    fn idOf(v: json.Value) ?u32 {
        const idv = v.get("id") orelse v.get("pane") orelse return null;
        const n = idv.numOf() orelse return null;
        if (n < 0) return null;
        return @intFromFloat(n);
    }

    /// First pane in an `ls` reply that the engine still reports alive.
    pub fn firstAlivePane(self: *const Reply) ?u32 {
        const pv = self.value.get("panes") orelse return null;
        if (pv.* != .arr) return null;
        for (pv.arr) |entry| {
            const alive = entry.get("alive") orelse continue;
            if (alive.* != .bool or !alive.bool) continue;
            return idOf(entry);
        }
        return null;
    }

    /// Number of panes listed by `ls` (including dead ones).
    pub fn paneCount(self: *const Reply) usize {
        const pv = self.value.get("panes") orelse return 0;
        if (pv.* != .arr) return 0;
        return pv.arr.len;
    }

    /// `true` for a reply that is a streamed event rather than an op reply.
    pub fn isEvent(self: *const Reply) bool {
        return self.value.get("event") != null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn serialize(alloc: std.mem.Allocator, req: Request) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try writeRequest(alloc, &out, req);
    return out.toOwnedSlice(alloc);
}

fn roundTrip(alloc: std.mem.Allocator, req: Request) !Reply {
    const line = try serialize(alloc, req);
    defer alloc.free(line);
    return Reply.parse(alloc, line);
}

test "socket path precedence: env override wins" {
    var buf: [256]u8 = undefined;
    const got = socketPath("/tmp/from-env.sock", "/run/user/1000", &buf);
    try testing.expectEqualStrings("/tmp/from-env.sock", got);
}

test "socket path falls back to XDG_RUNTIME_DIR" {
    var buf: [256]u8 = undefined;
    const got = socketPath(null, "/run/user/1000", &buf);
    try testing.expectEqualStrings("/run/user/1000/cipher-rex.sock", got);
}

test "socket path ignores empty values and uses the documented fallback" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(fallback_socket, socketPath("", "", &buf));
    try testing.expectEqualStrings(fallback_socket, socketPath(null, null, &buf));
}

test "socket path returns empty when the buffer cannot hold the runtime path" {
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", socketPath(null, "/run/user/1000", &tiny));
}

test "ls request is a single parseable object" {
    var reply = try roundTrip(testing.allocator, .ls);
    defer reply.deinit();
    try testing.expectEqualStrings("ls", reply.value.get("op").?.strOf().?);
}

test "spawn encodes cols/rows/cmd as a JSON array" {
    var reply = try roundTrip(testing.allocator, .{ .spawn = .{
        .cols = 100,
        .rows = 30,
        .cmd = &.{ "/bin/sh", "-l" },
    } });
    defer reply.deinit();
    try testing.expectEqualStrings("spawn", reply.value.get("op").?.strOf().?);
    try testing.expectEqual(100.0, reply.value.get("cols").?.numOf().?);
    try testing.expectEqual(30.0, reply.value.get("rows").?.numOf().?);
    const cmd = reply.value.get("cmd").?.arr;
    try testing.expectEqual(@as(usize, 2), cmd.len);
    try testing.expectEqualStrings("/bin/sh", cmd[0].strOf().?);
    try testing.expectEqualStrings("-l", cmd[1].strOf().?);
}

test "spawn carries an optional cwd without corrupting the cmd array" {
    var reply = try roundTrip(testing.allocator, .{ .spawn = .{
        .cmd = &.{"/bin/sh"},
        .cwd = "/tmp/a b",
    } });
    defer reply.deinit();
    try testing.expectEqualStrings("/tmp/a b", reply.value.get("cwd").?.strOf().?);
    try testing.expectEqual(@as(usize, 1), reply.value.get("cmd").?.arr.len);
}

test "send escapes quotes, backslashes, newlines and control bytes" {
    const payload = "a\"b\\c\nd\te\x01f";
    var reply = try roundTrip(testing.allocator, .{ .send = .{ .pane = 3, .data = payload } });
    defer reply.deinit();
    try testing.expectEqual(3.0, reply.value.get("pane").?.numOf().?);
    try testing.expectEqualStrings(payload, reply.value.get("data").?.strOf().?);
}

test "send escapes a UTF-8 payload byte-for-byte" {
    const payload = "héllo — 世界";
    var reply = try roundTrip(testing.allocator, .{ .send = .{ .pane = 1, .data = payload } });
    defer reply.deinit();
    try testing.expectEqualStrings(payload, reply.value.get("data").?.strOf().?);
}

test "capture toggles scrollback and omits lines when unset" {
    {
        var reply = try roundTrip(testing.allocator, .{ .capture = .{ .pane = 7 } });
        defer reply.deinit();
        try testing.expect(reply.value.get("scrollback").?.* == .bool);
        try testing.expect(!reply.value.get("scrollback").?.bool);
        try testing.expect(reply.value.get("lines") == null);
    }
    {
        var reply = try roundTrip(testing.allocator, .{ .capture = .{
            .pane = 7,
            .scrollback = true,
            .lines = 50,
        } });
        defer reply.deinit();
        try testing.expect(reply.value.get("scrollback").?.bool);
        try testing.expectEqual(50.0, reply.value.get("lines").?.numOf().?);
    }
}

test "run encodes wait and a single command string" {
    var reply = try roundTrip(testing.allocator, .{ .run = .{
        .pane = 2,
        .cmd = "echo \"hi\" && exit 0",
        .wait = true,
    } });
    defer reply.deinit();
    try testing.expect(reply.value.get("wait").?.bool);
    try testing.expectEqualStrings("echo \"hi\" && exit 0", reply.value.get("cmd").?.strOf().?);
}

test "resize, close, attach and split carry their pane ids" {
    {
        var reply = try roundTrip(testing.allocator, .{ .resize = .{ .pane = 9, .cols = 120, .rows = 40 } });
        defer reply.deinit();
        try testing.expectEqual(9.0, reply.value.get("pane").?.numOf().?);
        try testing.expectEqual(120.0, reply.value.get("cols").?.numOf().?);
        try testing.expectEqual(40.0, reply.value.get("rows").?.numOf().?);
    }
    {
        var reply = try roundTrip(testing.allocator, .{ .close = 9 });
        defer reply.deinit();
        try testing.expectEqual(9.0, reply.value.get("pane").?.numOf().?);
    }
    {
        var reply = try roundTrip(testing.allocator, .{ .attach = 4 });
        defer reply.deinit();
        try testing.expectEqual(4.0, reply.value.get("pane").?.numOf().?);
    }
    {
        var reply = try roundTrip(testing.allocator, .{ .split = .{ .pane = 4, .cmd = &.{"/bin/sh"} } });
        defer reply.deinit();
        try testing.expectEqual(4.0, reply.value.get("pane").?.numOf().?);
        try testing.expectEqual(@as(usize, 1), reply.value.get("cmd").?.arr.len);
    }
}

test "Reply reads ok, error text and the pane id" {
    {
        var reply = try Reply.parse(testing.allocator, "{\"ok\":true,\"id\":12}");
        defer reply.deinit();
        try testing.expect(reply.ok());
        try testing.expect(reply.errText() == null);
        try testing.expectEqual(@as(?u32, 12), reply.paneId());
    }
    {
        var reply = try Reply.parse(testing.allocator, "{\"ok\":false,\"error\":\"unknown op\"}");
        defer reply.deinit();
        try testing.expect(!reply.ok());
        try testing.expectEqualStrings("unknown op", reply.errText().?);
        try testing.expect(reply.paneId() == null);
    }
}

test "Reply rejects an empty line instead of inventing a reply" {
    try testing.expectError(error.EmptyReply, Reply.parse(testing.allocator, "  \n"));
}

test "firstAlivePane skips dead panes and keeps engine order" {
    const ls =
        \\{"ok":true,"panes":[
        \\{"id":3,"title":"zsh","alive":false,"cols":80,"rows":24},
        \\{"id":5,"title":"sh","alive":true,"cols":80,"rows":24},
        \\{"id":6,"title":"sh","alive":true,"cols":80,"rows":24}]}
    ;
    var reply = try Reply.parse(testing.allocator, ls);
    defer reply.deinit();
    try testing.expectEqual(3, reply.paneCount());
    try testing.expectEqual(@as(?u32, 5), reply.firstAlivePane());
}

test "firstAlivePane returns null with no panes or none alive" {
    var empty = try Reply.parse(testing.allocator, "{\"ok\":true,\"panes\":[]}");
    defer empty.deinit();
    try testing.expect(empty.firstAlivePane() == null);

    var dead = try Reply.parse(
        testing.allocator,
        "{\"ok\":true,\"panes\":[{\"id\":1,\"alive\":false}]}",
    );
    defer dead.deinit();
    try testing.expect(dead.firstAlivePane() == null);

    var not_ls = try Reply.parse(testing.allocator, "{\"ok\":true}");
    defer not_ls.deinit();
    try testing.expect(not_ls.firstAlivePane() == null);
    try testing.expectEqual(@as(usize, 0), not_ls.paneCount());
}

test "attach event and output event are recognised as events" {
    var attach = try Reply.parse(
        testing.allocator,
        "{\"ok\":true,\"event\":\"attach\",\"pane\":1,\"cols\":100,\"rows\":30,\"replay\":\"\",\"alive\":true}",
    );
    defer attach.deinit();
    try testing.expect(attach.isEvent());
    try testing.expectEqual(@as(?u32, 1), attach.paneId());

    var output = try Reply.parse(testing.allocator, "{\"event\":\"output\",\"pane\":1,\"data\":\"aGk=\"}");
    defer output.deinit();
    try testing.expect(output.isEvent());
    try testing.expectEqualStrings("aGk=", output.value.get("data").?.strOf().?);
}
