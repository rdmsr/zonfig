const std = @import("std");
const schema = @import("schema.zig");

pub const Error = error{
    UnknownKey,
    CyclicDependency,
    OutOfMemory,
};

const Node = struct {
    dependents: std.ArrayListUnmanaged([]const u8) = .empty,
    depends_on: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// A directed acyclic graph (DAG) to represent dependencies between configuration entries.
/// Each node is a configuration entry, and edges represent "depends_on" relationships.
/// The DAG allows us to efficiently determine if an entry is active based on its dependencies,
/// and to find all dependents of a given entry.
pub const Dag = struct {
    const Color = enum { white, grey, black };

    nodes: std.StringHashMap(Node),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dag {
        return .{
            .nodes = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dag) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.dependents.deinit(self.allocator);
            node.depends_on.deinit(self.allocator);
        }
        self.nodes.deinit();
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
            try self.nodes.put(key, .{});
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
                if (!self.nodes.contains(dep)) return error.UnknownKey;
                try self.nodes.getPtr(from).?.depends_on.append(self.allocator, dep);
                try self.nodes.getPtr(dep).?.dependents.append(self.allocator, from);
            },
            .key_eq => |kv| {
                if (!self.nodes.contains(kv.key)) return error.UnknownKey;
                try self.nodes.getPtr(from).?.depends_on.append(self.allocator, kv.key);
                try self.nodes.getPtr(kv.key).?.dependents.append(self.allocator, from);
            },
            .not => |c| try self.collectEdges(from, c.*),
            .all => |conds| for (conds) |c| try self.collectEdges(from, c),
            .any => |conds| for (conds) |c| try self.collectEdges(from, c),
        }
    }

    fn checkCycles(self: *Dag) Error!void {
        var colors = std.StringHashMap(Color).init(self.allocator);
        defer colors.deinit();

        var kit = self.nodes.keyIterator();
        while (kit.next()) |k| try colors.put(k.*, .white);

        var it = self.nodes.keyIterator();
        while (it.next()) |k| {
            if (colors.get(k.*).? == .white)
                try self.dfs(k.*, &colors);
        }
    }

    fn dfs(self: *Dag, key: []const u8, colors: *std.StringHashMap(Color)) Error!void {
        colors.put(key, .grey) catch return error.OutOfMemory;
        const node = self.nodes.get(key) orelse return;

        for (node.depends_on.items) |dep| {
            switch (colors.get(dep) orelse .white) {
                .grey => return error.CyclicDependency,
                .white => try self.dfs(dep, colors),
                .black => {},
            }
        }
        colors.put(key, .black) catch return error.OutOfMemory;
    }
};
