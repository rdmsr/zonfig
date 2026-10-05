const std = @import("std");
const zonfig = @import("zonfig");

const Config = struct {
    build_mode: std.builtin.OptimizeMode,
};

fn parseConfig(b: *std.Build, file_path: []const u8) !Config {
    const config_text = b.root.root_dir.handle.readFileAllocOptions(b.graph.io, file_path, b.allocator, .unlimited, .@"1", 0) catch |err| {
        return err;
    };

    var diag: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(Config, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = config_text,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.ParseZon)
            std.debug.print("error: failed to parse ZON: {f}\n", .{diag.fmt(file_path)});
        return err;
    };

    return parsed;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const zonfig_dep = b.dependency("zonfig", .{
        .target = target,
    });

    zonfig.addConfigStep(b, zonfig_dep, "config.zon", ".config.zon");

    const config = parseConfig(b, ".config.zon") catch |err| {
        if (err == error.FileNotFound) {
            b.default_step.dependOn(
                &b.addFail("No .config.zon found, run `zig build config` first").step,
            );
        } else {
            b.default_step.dependOn(
                &b.addFail("Failed to parse .config.zon").step,
            );
        }
        return;
    };

    const optimize = config.build_mode;

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const config_mod = zonfig.createConfigModule(b, zonfig_dep, "config.zon", ".config.zon");
    exe.root_module.addImport("config", config_mod);

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run.step);
}
