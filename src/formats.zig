const Engine = @import("engine.zig").Engine;
const Schema = @import("schema.zig");
const std = @import("std");

pub const Error = error{ InvalidFormat, OutOfMemory } || std.Io.Writer.Error;

pub const Format = struct {
    serialize: *const fn (self: *Engine, w: *std.Io.Writer) Error!void,
    deserialize: *const fn (self: *Engine, source: [:0]const u8) Error!void,
};

pub const Zon = Format{
    .serialize = serializeZon,
    .deserialize = deserializeZon,
};

pub const Json = Format{
    .serialize = seralizeJson,
    .deserialize = deserializeJson,
};

/// Serialize the current state to a ZON format.
fn serializeZon(self: *Engine, w: *std.Io.Writer) Error!void {
    // Note: we can't use zon serialize directly because values might be multiple types.
    try w.print(".{{", .{});

    var it = self.state.iterator();
    var first = true;

    while (it.next()) |entry| {
        if (!first) {
            try w.print(",", .{});
        }
        first = false;

        try w.print(".{s} = ", .{entry.key_ptr.*});
        switch (std.meta.activeTag(entry.value_ptr.*)) {
            .bool => try w.print("{}", .{entry.value_ptr.*.bool}),
            .int => try w.print("{d}", .{entry.value_ptr.*.int}),
            .string => try w.print("\"{s}\"", .{entry.value_ptr.*.string}),
            .choice => try w.print(".{s}", .{entry.value_ptr.*.choice}),
            else => {},
        }
    }

    try w.print("}}", .{});
}

/// Deserialize state from a ZON format.
// TODO: do proper validation
fn deserializeZon(self: *Engine, source: [:0]const u8) Error!void {
    var ast = std.zig.Ast.parse(self.allocator, source, .zon) catch |err| {
        std.debug.print("error: failed to parse ZON: {any}\n", .{err});
        return Error.InvalidFormat;
    };

    defer ast.deinit(self.allocator);

    if (ast.errors.len > 0) {
        std.debug.print("error: failed to parse ZON:\n", .{});
        for (ast.errors) |err| {
            std.debug.print("  - {any}\n", .{err});
        }
        return Error.InvalidFormat;
    }

    const root = ast.nodes.items(.data)[0].node;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const full = ast.fullStructInit(&buf, root) orelse return Error.InvalidFormat;

    for (full.ast.fields) |field_node| {
        const val_node = @intFromEnum(field_node);
        const val_tag = ast.nodes.items(.tag)[val_node];

        // Get the key
        const val_first_tok = ast.firstToken(field_node);
        const key_tok = val_first_tok - 2;
        const key = ast.tokenSlice(key_tok);

        const val_main_tok = ast.nodes.items(.main_token)[val_node];
        const val_raw = ast.tokenSlice(val_main_tok);

        const entry = self.schema.entries_by_key.get(key) orelse continue;

        const new_val: Schema.Value = switch (entry.kind) {
            .bool => blk: {
                if (val_tag != .identifier) continue;
                if (std.mem.eql(u8, val_raw, "true")) break :blk .{ .bool = true };
                if (std.mem.eql(u8, val_raw, "false")) break :blk .{ .bool = false };
                continue;
            },
            .int => blk: {
                if (val_tag != .number_literal) continue;
                const v = std.zig.parseNumberLiteral(val_raw).int;
                break :blk .{ .int = @intCast(v) };
            },
            .string => blk: {
                if (val_tag != .string_literal) continue;

                var writer: std.Io.Writer.Allocating = .init(self.allocator);
                _ = std.zig.ZonGen.parseStrLit(ast, field_node, &writer.writer) catch continue;

                break :blk if (entry.kind == .string)
                    .{ .string = writer.written() }
                else
                    .{ .choice = writer.written() };
            },
            .choice => blk: {
                if (val_tag != .enum_literal) continue;
                break :blk .{ .choice = val_raw };
            },
            .menu => continue,
            .import => continue,
        };

        try self.state.put(key, new_val);
    }
}

/// Serialize the current state to JSON.
fn seralizeJson(self: *Engine, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var it = self.state.iterator();
    var first = true;

    try w.print("{{", .{});

    while (it.next()) |entry| {
        if (!first) {
            try w.print(",\n", .{});
        }
        first = false;

        try w.print("\"{s}\": ", .{entry.key_ptr.*});
        switch (std.meta.activeTag(entry.value_ptr.*)) {
            .bool => try w.print("{}", .{entry.value_ptr.*.bool}),
            .int => try w.print("{d}", .{entry.value_ptr.*.int}),
            .string => try w.print("\"{s}\"", .{entry.value_ptr.*.string}),
            .choice => try w.print("\"{s}\"", .{entry.value_ptr.*.choice}),
            else => {},
        }
    }

    try w.print("}}", .{});
}

fn deserializeJson(self: *Engine, source: [:0]const u8) Error!void {
    const MapType = std.json.ArrayHashMap(std.json.Value);

    const parsed = std.json.parseFromSlice(MapType, self.allocator, source, .{}) catch |err| {
        std.debug.print("error: failed to parse JSON: {any}\n", .{err});
        return Error.InvalidFormat;
    };
    defer parsed.deinit();

    var it = parsed.value.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        const schema_entry = self.schema.entries_by_key.get(key) orelse continue;

        const kind = std.meta.activeTag(val);

        switch (kind) {
            .string => {
                const str = try self.allocator.dupe(u8, val.string);
                const new_val: Schema.Value = if (schema_entry.kind == .string)
                    .{ .string = str }
                else if (schema_entry.kind == .choice)
                    .{ .choice = str }
                else
                    return Error.InvalidFormat;

                try self.state.put(key, new_val);
            },

            .integer => {
                if (schema_entry.kind != .int) return Error.InvalidFormat;
                const num = val.integer;
                try self.state.put(key, .{ .int = @intCast(num) });
            },

            .bool => {
                if (schema_entry.kind != .bool) return Error.InvalidFormat;
                const b = val.bool;
                try self.state.put(key, .{ .bool = b });
            },

            else => {
                return Error.InvalidFormat;
            },
        }
    }
}
