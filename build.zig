const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const framework = b.option([]const u8, "cipher-root", "Cipher framework checkout") orelse "../Cipher";

    const term = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/term_api.zig", .{framework}) },
        .target = target,
        .optimize = optimize,
    });
    term.link_libc = true;
    term.addAnonymousImport("resources", .{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{framework}) } });

    const mux = b.createModule(.{
        .root_source_file = b.path("src/mux/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    mux.link_libc = true;
    mux.addImport("term", term);

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.link_libc = true;
    app.addImport("term", term);
    app.addImport("mux", mux);
    const exe = b.addExecutable(.{ .name = "nebula", .root_module = app });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Nebula").dependOn(&run.step);

    const unit = b.addTest(.{
        .name = "nebula-protocol-tests",
        .root_module = mux,
    });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run protocol and CLI tests");
    test_step.dependOn(&run_unit.step);

    const cli_options = b.addOptions();
    cli_options.addOptionPath("nebula_exe", exe.getEmittedBin());
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.link_libc = true;
    cli_mod.addImport("build_options", cli_options.createModule());
    const cli_tests = b.addTest(.{ .name = "nebula-cli-tests", .root_module = cli_mod });
    cli_tests.step.dependOn(&exe.step);
    const run_cli = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli.step);

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("rex_exe", exe.getEmittedBin());
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.link_libc = true;
    e2e_mod.addImport("term", term);
    e2e_mod.addImport("build_options", e2e_options.createModule());
    e2e_mod.addImport("protocol", b.createModule(.{
        .root_source_file = b.path("src/mux/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "term", .module = term }},
    }));
    const e2e = b.addTest(.{ .name = "nebula-e2e", .root_module = e2e_mod });
    e2e.step.dependOn(&exe.step);
    const run_e2e = b.addRunArtifact(e2e);
    b.step("test-e2e", "Run real multiplexer lifecycle tests").dependOn(&run_e2e.step);
}
