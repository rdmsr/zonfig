const std = @import("std");

title: ?[]const u8,
entries: []Entry,
entries_by_key: std.StringHashMap(*const Entry),

const Self = @This();

pub const EntryKind = enum { bool, int, string, choice, menu };
pub const Range = struct { min: i64, max: i64 };

pub const Condition = union(enum) {
    /// Depends on another key being true
    key: []const u8,
    /// Key equals another value (only for choice/string keys)
    key_eq: struct {
        key: []const u8,
        value: []const u8,
    },
    /// Negation of another condition
    not: *const Condition,
    /// All sub-conditions must be true (AND)
    all: []const Condition,
    /// Any sub-condition must be true (OR)
    any: []const Condition,
};

pub const Option = struct {
    value: []const u8,
    label: ?[]const u8 = null,
    depends_on: ?Condition = null,
};

pub const Value = union(EntryKind) {
    bool: bool,
    int: i64,
    string: []const u8,
    choice: []const u8,
    menu: void,
};

pub const Entry = struct {
    kind: EntryKind,
    key: ?[]const u8 = null,
    label: []const u8 = "",
    help: ?[]const u8 = null,
    depends_on: ?Condition = null,
    default: ?Value = null,
    options: ?[]const Option = null,
    range: ?Range = null,
    entries: ?[]Entry = null,

    pub fn getDefault(self: *const Entry) Value {
        return self.default orelse switch (self.kind) {
            .bool => .{ .bool = false },
            .int => .{ .int = 0 },
            .string => .{ .string = "" },
            .choice => .{ .choice = if (self.options) |o| o[0].value else "" },
            .menu => .{ .menu = {} },
        };
    }
};

pub const ValidateError = error{
    OutOfMemory,
    ValidationFailed,
};

pub const ValidateCode = enum {
    DuplicateKey,
    MissingKey,
    InvalidKeyName,
    MenuHasKey,
    MenuHasValueFields,
    NonMenuHasEntries,
    DependsOnUnknownKey,
    DependsOnNonBool,
    DefaultTypeMismatch,
    ChoiceMissingOptions,
    ChoiceDefaultNotInOptions,
    IntRangeInvalid,
    IntDefaultOutOfRange,
    BoolHasRange,
    NonIntHasRange,
    NonChoiceHasOptions,
    DependsOnChoiceNoOptions,
    DependsOnInvalidOption,
    DependsOnNonChoiceEq,
};

pub const ValidateIssue = struct {
    code: ValidateCode,
    key: ?[]const u8 = null,
    other: ?[]const u8 = null,
    msg: []const u8 = "",
};

pub const ValidateReport = struct {
    issues: std.ArrayListUnmanaged(ValidateIssue) = .empty,

    pub fn deinit(self: *ValidateReport, allocator: std.mem.Allocator) void {
        self.issues.deinit(allocator);
    }

    pub fn add(self: *ValidateReport, allocator: std.mem.Allocator, iss: ValidateIssue) !void {
        try self.issues.append(allocator, iss);
    }

    pub fn hasErrors(self: *const ValidateReport) bool {
        return self.issues.items.len != 0;
    }
};

/// Parse a schema from a ZON source string, returning an error on failure.
/// `diagnostic` is populated on failure, and should be deallocated by the caller.
pub fn parse(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    diagnostic: *std.zon.parse.Diagnostics,
) !Self {
    const parsed = try std.zon.parse.fromSliceAlloc(
        struct { title: ?[]const u8, entries: []Entry },
        allocator,
        source,
        diagnostic,
        .{ .free_on_error = true },
    );
    return .{
        .title = parsed.title,
        .entries = parsed.entries,
        .entries_by_key = .init(allocator),
    };
}

/// Validate schema and collect all issues into report.
/// Returns error.ValidationFailed if any issue exists.
pub fn validate(
    self: *Self,
    allocator: std.mem.Allocator,
    report: *ValidateReport,
) ValidateError!void {
    var kinds = std.StringHashMap(EntryKind).init(allocator);
    defer kinds.deinit();

    try collectAndValidateShape(allocator, &kinds, &self.entries_by_key, self.entries, report);
    try validateRefsAndValues(allocator, &kinds, &self.entries_by_key, self.entries, report);

    if (report.hasErrors()) return error.ValidationFailed;
}

/// Convenience method to parse and validate.
/// Caller owns returned schema and report memory.
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    diagnostic: *std.zon.parse.Diagnostics,
    report: *ValidateReport,
) !Self {
    var parsed = try parse(allocator, source, diagnostic);
    errdefer parsed.deinit(allocator);

    try parsed.validate(allocator, report);
    return parsed;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.title) |t| allocator.free(t);
    deinitEntries(allocator, self.entries);
    allocator.free(self.entries);
    self.* = undefined;
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| {
        if (e.key) |k| allocator.free(k);
        allocator.free(e.label);
        if (e.help) |h| allocator.free(h);

        if (e.default) |d| {
            switch (d) {
                .string => |s| allocator.free(s),
                .choice => |s| allocator.free(s),
                else => {},
            }
        }

        if (e.options) |opts| {
            for (opts) |opt| allocator.free(opt.value);
            allocator.free(opts);
        }

        if (e.entries) |sub| {
            deinitEntries(allocator, sub);
            allocator.free(sub);
        }
    }
}

fn issue(
    allocator: std.mem.Allocator,
    report: *ValidateReport,
    code: ValidateCode,
    key: ?[]const u8,
    other: ?[]const u8,
    msg: []const u8,
) !void {
    try report.add(allocator, .{
        .code = code,
        .key = try allocator.dupe(u8, key orelse ""),
        .other = try allocator.dupe(u8, other orelse ""),
        .msg = msg,
    });
}

fn collectAndValidateShape(
    allocator: std.mem.Allocator,
    kinds: *std.StringHashMap(EntryKind),
    entries_by_key: *std.StringHashMap(*const Entry),
    entries: []const Entry,
    report: *ValidateReport,
) ValidateError!void {
    for (entries) |*e| {
        switch (e.kind) {
            .menu => {
                if (e.key != null)
                    try issue(allocator, report, .MenuHasKey, e.key, null, "menu entries must not have a key");

                if (e.default != null or e.options != null or e.range != null)
                    try issue(allocator, report, .MenuHasValueFields, e.key, null, "menu entries cannot have default/options/range");

                if (e.entries) |sub| {
                    try collectAndValidateShape(allocator, kinds, entries_by_key, sub, report);
                }
            },
            else => {
                const key = e.key orelse {
                    try issue(allocator, report, .MissingKey, null, null, "non-menu entry is missing key");
                    continue;
                };

                if (!isValidIdentifier(key)) {
                    try issue(allocator, report, .InvalidKeyName, key, null, "key must be a valid identifier");
                }

                if (e.entries != null)
                    try issue(allocator, report, .NonMenuHasEntries, key, null, "non-menu entry cannot contain nested entries");

                if (kinds.contains(key)) {
                    try issue(allocator, report, .DuplicateKey, key, null, "duplicate key");
                } else {
                    kinds.put(key, e.kind) catch return error.OutOfMemory;
                    entries_by_key.put(key, e) catch return error.OutOfMemory;
                }
            },
        }
    }
}

fn validateCondition(
    allocator: std.mem.Allocator,
    report: *ValidateReport,
    kinds: *const std.StringHashMap(EntryKind),
    entries_by_key: *const std.StringHashMap(*const Entry),
    owner_key: []const u8,
    cond: Condition,
) !void {
    switch (cond) {
        .key => |dep| {
            const dep_kind = kinds.get(dep);
            if (dep_kind == null) {
                try issue(allocator, report, .DependsOnUnknownKey, owner_key, dep, "depends_on references unknown key");
            } else if (dep_kind.? != .bool) {
                try issue(allocator, report, .DependsOnNonBool, owner_key, dep, "depends_on must reference a bool key");
            }
        },
        .key_eq => |kv| {
            const dep_kind = kinds.get(kv.key);
            if (dep_kind == null) {
                try issue(allocator, report, .DependsOnUnknownKey, owner_key, kv.key, "depends_on references unknown key");
            } else switch (dep_kind.?) {
                .choice => {
                    const entry = entries_by_key.get(kv.key) orelse return;
                    const opts = entry.options orelse {
                        try issue(allocator, report, .DependsOnChoiceNoOptions, owner_key, kv.key, "depends_on key_eq references choice with no options");
                        return;
                    };
                    if (!containsOption(opts, kv.value)) {
                        try issue(allocator, report, .DependsOnInvalidOption, owner_key, kv.value, "depends_on key_eq value is not a valid option");
                    }
                },
                .string => {},
                else => {
                    try issue(allocator, report, .DependsOnNonChoiceEq, owner_key, kv.key, "depends_on key_eq must reference a choice or string key");
                },
            }
        },

        .not => |c| try validateCondition(allocator, report, kinds, entries_by_key, owner_key, c.*),
        .all => |conds| for (conds) |c| try validateCondition(allocator, report, kinds, entries_by_key, owner_key, c),
        .any => |conds| for (conds) |c| try validateCondition(allocator, report, kinds, entries_by_key, owner_key, c),
    }
}

fn validateRefsAndValues(
    allocator: std.mem.Allocator,
    kinds: *const std.StringHashMap(EntryKind),
    entries_by_key: *const std.StringHashMap(*const Entry),
    entries: []const Entry,
    report: *ValidateReport,
) ValidateError!void {
    for (entries) |e| {
        if (e.kind == .menu) {
            if (e.entries) |sub| try validateRefsAndValues(allocator, kinds, entries_by_key, sub, report);
            continue;
        }

        const key = e.key;

        if (e.depends_on) |cond| {
            try validateCondition(allocator, report, kinds, entries_by_key, key.?, cond);
        }

        switch (e.kind) {
            .bool => {
                if (e.range != null) try issue(allocator, report, .BoolHasRange, key, null, "bool entries cannot have range");
                if (e.options != null) try issue(allocator, report, .NonChoiceHasOptions, key, null, "only choice entries can have options");
            },
            .int => {
                if (e.options != null) try issue(allocator, report, .NonChoiceHasOptions, key, null, "only choice entries can have options");
                if (e.range) |r| if (r.min > r.max)
                    try issue(allocator, report, .IntRangeInvalid, key, null, "int range min cannot exceed max");
            },
            .string => {
                if (e.range != null) try issue(allocator, report, .NonIntHasRange, key, null, "only int entries can have range");
                if (e.options != null) try issue(allocator, report, .NonChoiceHasOptions, key, null, "only choice entries can have options");
            },
            .choice => {
                if (e.range != null) try issue(allocator, report, .NonIntHasRange, key, null, "only int entries can have range");
                const opts = e.options;
                if (opts == null or opts.?.len == 0) {
                    try issue(allocator, report, .ChoiceMissingOptions, key, null, "choice entries must provide non-empty options");
                } else {
                    for (opts.?) |opt| {
                        if (opt.depends_on) |cond| {
                            try validateCondition(allocator, report, kinds, entries_by_key, key.?, cond);
                        }
                    }
                }
            },
            .menu => unreachable,
        }

        if (e.default) |d| {
            if (std.meta.activeTag(d) != e.kind) {
                try issue(allocator, report, .DefaultTypeMismatch, key, null, "default type does not match entry kind");
                continue;
            }

            switch (e.kind) {
                .int => {
                    if (e.range) |r| {
                        const v = d.int;
                        if (v < r.min or v > r.max)
                            try issue(allocator, report, .IntDefaultOutOfRange, key, null, "int default is outside declared range");
                    }
                },
                .choice => {
                    const opts = e.options;
                    if (opts == null or opts.?.len == 0) {
                        try issue(allocator, report, .ChoiceMissingOptions, key, null, "choice default present but options missing");
                    } else if (!containsOption(opts.?, d.choice)) {
                        try issue(allocator, report, .ChoiceDefaultNotInOptions, key, d.choice, "choice default is not in options");
                    }
                },
                else => {},
            }
        }
    }
}

fn containsString(haystack: [][]const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn containsOption(haystack: []const Option, needle: []const u8) bool {
    for (haystack) |opt| {
        if (std.mem.eql(u8, opt.value, needle)) return true;
    }
    return false;
}

fn isValidIdentifier(str: []const u8) bool {
    if (str.len == 0) return false;
    const first = str[0];
    if (!((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '_')) {
        return false;
    }
    for (str[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) {
            return false;
        }
    }
    return true;
}
