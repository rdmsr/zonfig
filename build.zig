const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zonfig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zonfig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zonfig", .module = mod },
            },
            .link_libc = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    exe.root_module.addCSourceFile(.{
        .file = b.path("src/tui/shim.c"),
        .flags = &.{"-std=c99"},
    });

    exe.root_module.linkSystemLibrary("ncurses", .{});
    exe.root_module.linkSystemLibrary("menu", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

pub fn addConfigStep(b: *std.Build, dep: *std.Build.Dependency, schema_path: []const u8, config_path: []const u8) void {
    const config_step = b.step("config", "Edit build configuration");
    const run_config = b.addRunArtifact(dep.artifact("zonfig"));
    run_config.addArgs(&.{ "--schema", schema_path, "--config", config_path });
    config_step.dependOn(&run_config.step);
}

pub fn createConfigModule(b: *std.Build, dep: *std.Build.Dependency, schema_path: []const u8, config_path: []const u8) *std.Build.Module {
    const run = b.addRunArtifact(dep.artifact("zonfig"));
    run.addArgs(&.{ "--schema", schema_path, "--config", config_path, "--output-zig" });
    run.addFileInput(b.path(schema_path));
    run.addFileInput(b.path(config_path));
    const output = run.captureStdOut(.{ .basename = "zonfig.gen.zig" });
    return b.createModule(.{ .root_source_file = output });
}
