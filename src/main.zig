const std = @import("std");
const zonfig = @import("zonfig");
const app = @import("tui/app.zig");

pub fn printValidationReport(
    writer: anytype,
    report: zonfig.Schema.ValidateReport,
) !void {
    try writer.print(
        "error: schema validation failed ({d} issue{s})\n",
        .{
            report.issues.items.len,
            if (report.issues.items.len == 1) "" else "s",
        },
    );

    for (report.issues.items) |issue| {
        try writer.print("  - {s}", .{@tagName(issue.code)});
        if (issue.key) |k| try writer.print(" key='{s}'", .{k});
        if (issue.other) |o| try writer.print(" other='{s}'", .{o});
        if (issue.msg.len != 0) try writer.print(": {s}", .{issue.msg});
        try writer.print("\n", .{});
    }
}

const Format = enum {
    Zon,
    Json,
};
const Args = struct {
    schema_path: []const u8 = "schema/config.zon",
    config_path: []const u8 = "config.zon",
    format: Format = .Zon,
    output_zig: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !Args {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    const exe = args.next().?;

    var result = Args{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: {s} [options]
                \\
                \\Options:
                \\  --schema <path>   Path to schema file (default: zonfig.zon)
                \\  --config <path>   Path to config file (default: .config.zon)
                \\  --format <fmt>    Config file format (zon or json, default: zon)
                \\  --output-zig      Generate Zig code for the schema and config and print to stdout
                \\  --help            Print this message
                \\
            , .{exe});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--schema")) {
            const path = args.next() orelse {
                std.debug.print("error: --schema requires a path\n", .{});
                std.process.exit(1);
            };
            result.schema_path = try allocator.dupe(u8, path);
        } else if (std.mem.eql(u8, arg, "--output-zig")) {
            result.output_zig = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            const path = args.next() orelse {
                std.debug.print("error: --config requires a path\n", .{});
                std.process.exit(1);
            };
            result.config_path = try allocator.dupe(u8, path);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const fmt = args.next() orelse {
                std.debug.print("error: --format requires a value\n", .{});
                std.process.exit(1);
            };
            if (std.mem.eql(u8, fmt, "zon")) {
                result.format = .Zon;
            } else if (std.mem.eql(u8, fmt, "json")) {
                result.format = .Json;
            } else {
                std.debug.print("error: unknown format: {s}\n", .{fmt});
                std.process.exit(1);
            }
        } else {
            std.debug.print("error: unknown argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    var stderr = std.Io.File.stderr().writer(io, &.{});
    var errw = &stderr.interface;

    const args = try parseArgs(allocator, init);

    const source = dir.readFileAllocOptions(
        io,
        args.schema_path,
        allocator,
        .unlimited,
        .@"1",
        0,
    ) catch |err| {
        std.debug.print("error: reading config.zon failed: {any}\n", .{err});
        return err;
    };
    defer allocator.free(source);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    var report: zonfig.Schema.ValidateReport = .{};
    defer report.deinit(allocator);

    const schema = zonfig.Schema.parseAndValidate(allocator, init.io, source, &diag, &report) catch |err| {
        switch (err) {
            error.ValidationFailed => try printValidationReport(errw, report),
            else => {
                try errw.print("parse failed: {any}\n", .{err});
                try errw.print("{f}\n", .{diag});
            },
        }
        std.process.exit(1);
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var config_file = try dir.createFile(init.io, args.config_path, .{ .truncate = false, .read = true });
    defer config_file.close(init.io);

    const file_size = (try config_file.stat(init.io)).size;
    const curr_cfg = try allocator.allocSentinel(u8, file_size, 0);
    defer allocator.free(curr_cfg);
    var config_reader = config_file.reader(init.io, curr_cfg);
    try config_reader.interface.fill(file_size);

    var engine = zonfig.Engine.init(allocator, schema, .{
        .format = switch (args.format) {
            .Zon => zonfig.formats.Zon,
            .Json => zonfig.formats.Json,
        },
    }) catch |err| {
        try errw.print("error: engine init failed: {any}\n", .{err});
        std.process.exit(1);
    };

    if (curr_cfg.len > 0) {
        try engine.load(curr_cfg);
    }

    if (args.output_zig) {
        const zig = try engine.generateZig();
        var stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &.{});

        try writer.interface.print("{s}", .{zig});
        return;
    }

    engine.setSaveFile(init.io, &config_file);

    defer engine.deinit();

    try app.run(allocator, &engine);
}
