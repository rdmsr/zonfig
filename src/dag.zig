const std = @import("std");
const schema = @import("schema.zig");

pub const Error = error{
    UnknownKey,
    CyclicDependency,
    OutOfMemory,
};

/// A directed acyclic graph (DAG) to represent dependencies between configuration entries.
/// Each node is a configuration entry, and edges represent "depends_on" relationships.
/// The DAG allows us to efficiently determine if an entry is active based on its dependencies,
/// and to find all dependents of a given entry.
pub const Dag = struct {
    const Color = enum { white, grey, black };

    /// Map from a key to the list of keys that depend on it.
    dependents: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    /// Map from a key to the keys it depends on (if any).
    depends_on: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dag {
        return .{
            .dependents = .init(allocator),
            .depends_on = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dag) void {
        var it = self.dependents.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.dependents.deinit();
        var it2 = self.depends_on.valueIterator();
        while (it2.next()) |list| list.deinit(self.allocator);
        self.depends_on.deinit();
    }

    pub fn build(self: *Dag, entries: []const schema.Entry) Error!void {
        try self.registerKeys(entries);
        try self.registerEdges(entries);
        try self.checkCycles();
    }

    fn registerKeys(self: *Dag, entries: []const schema.Entry) Error!void {
        for (entries) |entry| {
            if (entry.kind == .menu) {
                if (entry.entries) |sub| try self.registerKeys(sub);
                continue;
            }
            const key = entry.key orelse continue;
            try self.depends_on.put(key, .empty);
            try self.dependents.put(key, .empty);
        }
    }

    fn registerEdges(self: *Dag, entries: []const schema.Entry) Error!void {
        for (entries) |entry| {
            if (entry.kind == .menu) {
                if (entry.entries) |sub| try self.registerEdges(sub);
                continue;
            }
            const key = entry.key orelse continue;
            const cond = entry.depends_on orelse continue;
            try self.collectEdges(key, cond);
        }
    }

    fn collectEdges(self: *Dag, from: []const u8, cond: schema.Condition) Error!void {
        switch (cond) {
            .key => |dep| {
                if (!self.depends_on.contains(dep)) return error.UnknownKey;
                const fwd = self.depends_on.getPtr(from).?;
                try fwd.append(self.allocator, dep);
                const rev = self.dependents.getPtr(dep).?;
                try rev.append(self.allocator, from);
            },
            .not => |c| try self.collectEdges(from, c.*),
            .all => |conds| for (conds) |c| try self.collectEdges(from, c),
            .any => |conds| for (conds) |c| try self.collectEdges(from, c),
        }
    }

    fn checkCycles(self: *Dag) Error!void {
        var colors = std.StringHashMap(Color).init(self.allocator);
        defer colors.deinit();

        var kit = self.depends_on.keyIterator();
        while (kit.next()) |k| try colors.put(k.*, .white);

        var it = self.depends_on.keyIterator();
        while (it.next()) |k| {
            if (colors.get(k.*).? == .white)
                try self.dfs(k.*, &colors);
        }
    }

    fn dfs(self: *Dag, key: []const u8, colors: *std.StringHashMap(Color)) Error!void {
        colors.put(key, .grey) catch return error.OutOfMemory;
        const deps = self.depends_on.get(key) orelse return;
        for (deps.items) |dep| {
            switch (colors.get(dep) orelse .white) {
                .grey => return error.CyclicDependency,
                .white => try self.dfs(dep, colors),
                .black => {},
            }
        }
        colors.put(key, .black) catch return error.OutOfMemory;
    }
};
