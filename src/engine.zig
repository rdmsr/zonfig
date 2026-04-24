const dag = @import("dag.zig");
const Schema = @import("schema.zig");
const formats = @import("formats.zig");
const std = @import("std");

fn evalCondition(
    cond: Schema.Condition,
    isTrue: anytype,
    ctx: anytype,
) bool {
    return switch (cond) {
        .key => |k| isTrue(ctx, k),
        .not => |c| !evalCondition(c.*, isTrue, ctx),
        .all => |conds| {
            for (conds) |c| {
                if (!evalCondition(c, isTrue, ctx)) return false;
            }
            return true;
        },
        .any => |conds| {
            for (conds) |c| {
                if (evalCondition(c, isTrue, ctx)) return true;
            }
            return false;
        },
        .key_eq => |kv| blk: {
            const val = ctx.state.get(kv.key) orelse break :blk false;
            break :blk switch (val) {
                .choice => |c| std.mem.eql(u8, c, kv.value),
                .string => |s| std.mem.eql(u8, s, kv.value),
                else => false,
            };
        },
    };
}

/// Represents the current state of the configuration.
const State = struct {
    values: std.StringHashMap(Schema.Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .values = std.StringHashMap(Schema.Value).init(allocator),
            .allocator = allocator,
        };
    }

    /// Recursively set all keys to their default values.
    pub fn buildDefault(self: *State, entries: []const Schema.Entry) !void {
        for (entries) |entry| {
            if (entry.kind == .menu) {
                if (entry.entries) |sub| try self.buildDefault(sub);
                continue;
            }
            const key = entry.key orelse continue;
            try self.set(key, entry.getDefault());
        }
    }

    pub fn deinit(self: *State) void {
        self.values.deinit();
    }

    /// Set the value of a key.
    pub fn set(self: *State, key: []const u8, value: Schema.Value) !void {
        try self.values.put(key, value);
    }

    /// Get the value of a key, or null if not set.
    pub fn get(self: *const State, key: []const u8) ?Schema.Value {
        return self.values.get(key);
    }

    /// Check if a key is true (i.e. all its dependencies are true).
    pub fn isTrue(self: *const State, key: []const u8) bool {
        const val = self.get(key) orelse return false;
        return switch (val) {
            .bool => |b| b,
            else => true,
        };
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    schema: Schema,
    dag: dag.Dag,
    state: State,
    entries_by_key: std.StringHashMap(*const Schema.Entry),
    dirty: bool,
    save_file: ?*std.Io.File,
    save_io: ?std.Io,
    format: formats.Format,

    const Self = @This();

    pub const SetError = error{
        UnknownKey,
        InactiveKey,
        TypeMismatch,
        ChoiceInvalidOption,
        IntOutOfRange,
        OutOfMemory,
    };

    pub const Options = struct {
        format: formats.Format = formats.Zon,
    };

    pub fn init(allocator: std.mem.Allocator, sch: Schema, options: Options) !Self {
        var e = Self{
            .allocator = allocator,
            .schema = sch,
            .dag = .init(allocator),
            .state = .init(allocator),
            .entries_by_key = .init(allocator),
            .dirty = true,
            .format = options.format,
            .save_file = null,
            .save_io = null,
        };
        errdefer e.deinit();

        try e.buildEntryIndex(e.schema.entries);
        try e.dag.build(e.schema.entries);
        try e.state.buildDefault(e.schema.entries);

        return e;
    }

    pub fn deinit(self: *Self) void {
        self.dag.deinit();
        self.state.deinit();
        self.entries_by_key.deinit();
    }

    /// Check if a key is active by recursively evaluating its condition,
    /// and the conditions of anything it depends on.
    pub fn isActive(self: *const Self, key: []const u8) bool {
        const entry = self.getEntry(key) orelse return false;
        const cond = entry.depends_on orelse return true;
        return evalCondition(cond, isActiveTrampoline, self);
    }

    /// Trampoline so evalCondition can call back into isActive recursively,
    /// giving us full transitive dependency evaluation for free.
    fn isActiveTrampoline(self: *const Self, key: []const u8) bool {
        if (!self.isActive(key)) {
            return false;
        }

        return self.state.isTrue(key);
    }

    pub fn isOptionActive(self: *const Self, opt: *const Schema.Option) bool {
        const cond = opt.depends_on orelse return true;
        return evalCondition(cond, isActiveTrampoline, self);
    }

    /// Set the value of a key, with validation against the schema.
    pub fn set(self: *Self, key: []const u8, value: Schema.Value) SetError!void {
        const entry = self.getEntry(key) orelse return error.UnknownKey;

        if (!self.isActive(key)) return error.InactiveKey;
        if (std.meta.activeTag(value) != entry.kind) return error.TypeMismatch;

        switch (entry.kind) {
            .int => {
                if (entry.range) |r| {
                    const v = value.int;
                    if (v < r.min or v > r.max) return error.IntOutOfRange;
                }
            },
            .choice => {
                const opts = entry.options orelse return error.ChoiceInvalidOption;
                var found = false;
                for (opts) |*opt| {
                    if (std.mem.eql(u8, opt.value, value.choice) and self.isOptionActive(opt)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.ChoiceInvalidOption;
            },
            else => {},
        }

        try self.state.set(key, value);

        self.dirty = true;
    }

    pub fn setSaveFile(self: *Self, io: std.Io, file: *std.Io.File) void {
        self.save_io = io;
        self.save_file = file;
    }

    /// Get the value of a key, or null if not set.
    pub fn get(self: *const Self, key: []const u8) ?Schema.Value {
        return self.state.get(key);
    }

    /// Get the schema entry for a key, or null if not found.
    pub fn getEntry(self: *const Self, key: []const u8) ?*const Schema.Entry {
        return self.entries_by_key.get(key);
    }

    /// Collect all entries that are active in the given menu.
    pub fn collectActive(
        self: *const Engine,
        allocator: std.mem.Allocator,
        entries: []const Schema.Entry,
        out: *std.ArrayListUnmanaged(*const Schema.Entry),
    ) !void {
        for (entries) |*e| {
            if (e.kind == .menu) {
                // Only append a menu if it has any visible children.
                const sub = e.entries orelse continue;
                if (!self.hasAnyActive(sub)) continue;
                try out.append(allocator, e);
                continue;
            }

            const key = e.key orelse continue;
            if (!self.isActive(key)) continue;
            try out.append(allocator, e);
        }
    }

    pub fn collectActiveOptions(
        self: *const Self,
        allocator: std.mem.Allocator,
        key: []const u8,
        out: *std.ArrayListUnmanaged(*const Schema.Option),
    ) !void {
        const entry = self.getEntry(key) orelse return;
        const opts = entry.options orelse return;
        for (opts) |*opt| {
            if (self.isOptionActive(opt)) try out.append(allocator, opt);
        }
    }

    /// Save the current state to disk if dirty.
    pub fn save(self: *Engine) !void {
        if (!self.dirty) return;

        if (self.save_file == null or self.save_io == null) {
            return error.NoSaveFile;
        }

        var writer = self.save_file.?.writer(self.save_io.?, &.{});
        try self.save_file.?.setLength(self.save_io.?, 0);

        try self.format.serialize(self, &writer.interface);

        self.dirty = false;
    }

    /// Load state from a slice, replacing the current state.
    pub fn load(self: *Engine, source: [:0]const u8) !void {
        try self.format.deserialize(self, source);
        self.dirty = false;
    }

    pub fn generateZig(self: *const Self) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        var it = self.state.values.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            try buf.appendSlice(self.allocator, "pub const ");
            try buf.appendSlice(self.allocator, key);

            if (std.meta.activeTag(val) == .choice) {
                const entry = self.getEntry(key) orelse continue;
                try buf.appendSlice(
                    self.allocator,
                    ": enum {",
                );

                const opts = entry.options orelse continue;

                for (opts, 0..opts.len) |*opt, i| {
                    try buf.appendSlice(self.allocator, opt.value);
                    if (i != opts.len - 1) {
                        try buf.appendSlice(self.allocator, ",");
                    }
                }
                try buf.appendSlice(self.allocator, "}");
            }

            try buf.appendSlice(self.allocator, " = ");
            switch (val) {
                .bool => |b| try buf.print(self.allocator, "{s}", .{if (b) "true" else "false"}),
                .int => |i| try buf.print(self.allocator, "{d}", .{i}),
                .choice => |c| try buf.print(self.allocator, ".{s}", .{c}),
                .string => |s| try buf.print(self.allocator, "\"{s}\"", .{s}),
                else => try buf.appendSlice(self.allocator, "null"),
            }
            try buf.appendSlice(self.allocator, ";\n");
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn buildEntryIndex(self: *Engine, entries: []const Schema.Entry) !void {
        for (entries) |*entry| {
            if (entry.kind == .menu) {
                if (entry.entries) |sub| try self.buildEntryIndex(sub);
                continue;
            }
            const key = entry.key orelse continue;
            try self.entries_by_key.put(key, entry);
        }
    }

    fn hasAnyActive(self: *const Engine, entries: []const Schema.Entry) bool {
        for (entries) |e| {
            if (e.kind == .menu) {
                if (e.entries) |sub| {
                    if (self.hasAnyActive(sub)) return true;
                }
                continue;
            }
            const key = e.key orelse continue;
            if (self.isActive(key)) return true;
        }
        return false;
    }
};

fn containsString(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}
