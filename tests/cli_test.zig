const std = @import("std");
const options = @import("build_options");

fn run(allocator: std.mem.Allocator, args: []const []const u8) !std.process.RunResult {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.nebula_exe);
    try argv.appendSlice(allocator, args);
    return try std.process.run(allocator, std.testing.io, .{ .argv = argv.items });
}

test "help is printed without a stack trace" {
    const result = try run(std.testing.allocator, &.{"--help"});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "nebula — native terminal multiplexer") != null);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}

test "version is reported without a stack trace" {
    const result = try run(std.testing.allocator, &.{"--version"});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("nebula 0.1.0\n", result.stdout);
}

test "unknown commands have a concise diagnostic" {
    const result = try run(std.testing.allocator, &.{"not-a-command"});
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 2), result.term.exited);
    try std.testing.expectEqualStrings("nebula: unknown command\n", result.stderr);
}

test "serve refuses to destroy a non-socket path and says why" {
    var tmp_buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/nebula-cli-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.createDirAbsolute(std.testing.io, dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), std.testing.io, dir) catch {};

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/not-a-socket.txt", .{dir});
    const f = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{});
    try f.writeStreamingAll(std.testing.io, "keep me");
    f.close(std.testing.io);

    const result = try run(std.testing.allocator, &.{ "serve", "--socket", path });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 3), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "not a socket") != null);
    // The diagnostic is one line, not a stack trace.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "panic") == null);
}
