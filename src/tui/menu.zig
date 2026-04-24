const std = @import("std");
const nc = @import("nc.zig");
const ui = @import("ui.zig");
const zc = @import("zonfig");
const prompt = @import("prompt.zig");
const Engine = zc.Engine;
const Schema = zc.Schema;

pub const MenuView = struct {
    allocator: std.mem.Allocator,
    engine: *Engine,

    entries: std.ArrayListUnmanaged(*const Schema.Entry) = .empty,
    items: []?*nc.ITEM = &.{},
    menu: ?*nc.MENU = null,
    win: ?*nc.WINDOW = null,
    sub: ?*nc.WINDOW = null,
    item_strings: std.ArrayListUnmanaged([:0]u8) = .empty,
    stack: std.ArrayListUnmanaged(*const Schema.Entry) = .empty,

    root_entry: *Schema.Entry = undefined,

    status: [256]u8 = [_]u8{0} ** 256,
    status_len: usize = 0,

    panel_y: i32 = 0,
    panel_x: i32 = 0,
    panel_h: i32 = 0,
    panel_w: i32 = 0,
    list_rows: i32 = 0,
    list_cols: i32 = 0,

    pub fn init(allocator: std.mem.Allocator, engine: *Engine) !MenuView {
        var self = MenuView{
            .allocator = allocator,
            .engine = engine,
        };

        self.root_entry = try allocator.create(Schema.Entry);

        self.root_entry.* = Schema.Entry{
            .kind = .menu,
            .label = engine.schema.title orelse "Configuration",
            .entries = engine.schema.entries,
        };

        try self.stack.append(self.allocator, self.root_entry);
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *MenuView) void {
        self.teardown();
        self.entries.deinit(self.allocator);
        self.item_strings.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    pub fn rebuild(self: *MenuView) !void {
        const saved = self.currentIndex();
        self.teardown();
        self.entries.clearRetainingCapacity();

        const cur = self.stack.getLast();
        const level = cur.entries orelse &.{};
        try self.engine.collectActive(self.allocator, level, &self.entries);

        // Reset stale choice entries to their default if their dependencies changed.
        var it = self.engine.entries_by_key.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (entry.kind != .choice) continue;
            if (!self.engine.isActive(kv.key_ptr.*)) continue;

            const opts = entry.options orelse continue;
            const cur_val = (self.engine.get(kv.key_ptr.*) orelse continue).choice;

            const still_active = for (opts) |*opt| {
                if (std.mem.eql(u8, opt.value, cur_val) and self.engine.isOptionActive(opt)) break true;
            } else false;

            if (!still_active) {
                const new_val = for (opts) |*opt| {
                    if (self.engine.isOptionActive(opt)) break opt.value;
                } else "";
                try self.engine.set(kv.key_ptr.*, .{ .choice = new_val });
            }
        }

        const scr_rows = nc.getmaxy(nc.stdscr());
        const scr_cols = nc.getmaxx(nc.stdscr());

        self.panel_w = scr_cols - 2;
        self.panel_h = scr_rows - 2;
        self.panel_y = @divTrunc(scr_rows - self.panel_h, 2) + 1;
        self.panel_x = @divTrunc(scr_cols - self.panel_w, 2);

        self.list_rows = self.panel_h - 4;
        self.list_cols = self.panel_w - 4;

        if (self.entries.items.len == 0) return;

        self.items = try self.allocator.alloc(?*nc.ITEM, self.entries.items.len + 1);
        @memset(self.items, null);

        for (self.entries.items, 0..) |entry, i| {
            const name = try self.getLabelForEntry(entry);
            const desc = try self.allocator.dupeSentinel(u8, "", 0);

            try self.item_strings.append(self.allocator, name);
            try self.item_strings.append(self.allocator, desc);

            const item = nc.new_item(name.ptr, desc.ptr) orelse return error.OutOfMemory;
            self.items[i] = item;
            _ = nc.set_item_userptr(item, @ptrCast(@constCast(entry)));
        }

        self.menu = nc.new_menu(self.items.ptr) orelse return error.OutOfMemory;

        self.win = nc.newwin(self.panel_h, self.panel_w, self.panel_y, self.panel_x);
        self.sub = nc.derwin(self.win, self.list_rows, self.list_cols, 2, 2);
        if (self.win == null or self.sub == null) return error.OutOfMemory;

        _ = nc.keypad(self.win, 1);
        _ = nc.keypad(self.sub, 1);

        _ = nc.set_menu_win(self.menu, self.win);
        _ = nc.set_menu_sub(self.menu, self.sub);
        _ = nc.set_menu_format(self.menu, self.list_rows, 1);

        _ = nc.set_menu_mark(self.menu, " ");
        _ = nc.set_menu_fore(self.menu, nc.A_REVERSE);
        _ = nc.set_menu_back(self.menu, 0);
        _ = nc.set_menu_grey(self.menu, nc.A_DIM);

        if (self.win) |w| {
            _ = nc.werase(w);
            self.drawPanelBorder(w);
            self.drawPanelTitle(w);
            self.drawPanelFooter(w);
        }

        const target = @min(saved, self.entries.items.len -| 1);
        if (self.items[target]) |item| {
            _ = nc.set_current_item(self.menu, item);
        }

        _ = nc.post_menu(self.menu);
        _ = nc.pos_menu_cursor(self.menu);
    }

    pub fn draw(self: *MenuView) void {
        const scr_rows = nc.getmaxy(nc.stdscr());
        const scr_cols = nc.getmaxx(nc.stdscr());

        _ = nc.erase();
        self.drawScreenHeader(scr_cols);
        _ = nc.wnoutrefresh(nc.stdscr());

        if (self.menu == null) {
            nc.mvprint(@divTrunc(scr_rows, 2), @divTrunc(scr_cols - 20, 2), "(no visible entries)", .{});
            _ = nc.doupdate();
            return;
        }

        if (self.win) |w| {
            _ = nc.touchwin(w);
            _ = nc.wnoutrefresh(w);
        }

        if (self.sub) |s| {
            _ = nc.touchwin(s);
            _ = nc.wnoutrefresh(s);
        }

        _ = nc.doupdate();
    }

    pub fn handleKey(self: *MenuView, ch: c_int) !bool {
        switch (ch) {
            nc.KEY_UP, 'k' => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_UP_ITEM);
            },
            nc.KEY_DOWN, 'j' => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_DOWN_ITEM);
            },
            nc.KEY_PPAGE => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_SCR_UPAGE);
            },
            nc.KEY_NPAGE => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_SCR_DPAGE);
            },
            nc.KEY_HOME => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_FIRST_ITEM);
            },
            nc.KEY_END => if (self.menu != null) {
                _ = nc.menu_driver(self.menu, nc.REQ_LAST_ITEM);
            },
            '?' => self.showHelp(),
            's' => {
                try self.engine.save();
                var d = ui.ButtonDialog.open("Save", "Configuration saved.", &.{"OK"}, false);
                _ = d.run();
            },
            '\n', nc.KEY_RIGHT => try self.activate(),
            nc.KEY_LEFT, 27 => try self.pop(),
            'q' => {
                switch (prompt.promptQuit(self.engine.dirty)) {
                    .save => {
                        try self.engine.save();
                        return true;
                    },
                    .discard => return true,
                    .cancel => {},
                }
            },
            nc.KEY_RESIZE => try self.rebuild(),
            else => {},
        }
        self.draw();
        return false;
    }

    fn activate(self: *MenuView) !void {
        if (self.menu == null) return;
        const item = nc.current_item(self.menu) orelse return;
        const entry: *const Schema.Entry = @ptrCast(@alignCast(nc.item_userptr(item)));
        switch (entry.kind) {
            .menu => {
                try self.stack.append(self.allocator, entry);
            },
            .bool => {
                const key = entry.key orelse return;
                const val = self.engine.get(key) orelse return;
                try self.engine.set(key, .{ .bool = !val.bool });
            },
            .int => {
                const key = entry.key orelse return;
                const cur = (self.engine.get(key) orelse Schema.Value{ .int = 0 }).int;
                const v = prompt.promptInt(entry.label, cur, entry.range) catch |err| {
                    if (err == error.Cancelled) return;
                    return err;
                };
                try self.engine.set(key, .{ .int = v });
            },
            .choice => {
                const k = entry.key orelse return;
                const cur_str = (self.engine.get(k) orelse Schema.Value{ .choice = "" }).choice;
                var active_opts: std.ArrayListUnmanaged(*const Schema.Option) = .empty;
                defer active_opts.deinit(self.allocator);
                try self.engine.collectActiveOptions(self.allocator, k, &active_opts);
                var opt_labels = try std.ArrayListUnmanaged([]const u8).initCapacity(self.allocator, active_opts.items.len);
                defer opt_labels.deinit(self.allocator);
                for (active_opts.items) |opt| {
                    try opt_labels.append(self.allocator, opt.label orelse opt.value);
                }
                var cur_idx: usize = 0;
                for (active_opts.items, 0..) |opt, i| {
                    if (std.mem.eql(u8, opt.value, cur_str)) {
                        cur_idx = i;
                        break;
                    }
                }
                const idx = prompt.promptChoice(entry.label, opt_labels.items, cur_idx) catch |err| {
                    if (err == error.Cancelled) return;
                    return err;
                };
                try self.engine.set(k, .{ .choice = active_opts.items[idx].value });
            },
            .string => {
                const k = entry.key orelse return;
                const cur_str = (self.engine.get(k) orelse Schema.Value{ .string = "" }).string;
                const new_str = prompt.promptString(self.allocator, entry.label, cur_str) catch |err| {
                    if (err == error.Cancelled) return;
                    return err;
                };
                try self.engine.set(k, .{ .string = new_str });
            },
        }

        try self.rebuild();
    }

    fn pop(self: *MenuView) !void {
        if (self.stack.items.len > 1) {
            _ = self.stack.pop();
            try self.rebuild();
        }
    }

    fn teardown(self: *MenuView) void {
        if (self.menu) |m| {
            _ = nc.unpost_menu(m);
            _ = nc.free_menu(m);
            self.menu = null;
        }
        if (self.items.len > 0) {
            for (self.items) |it| if (it) |i| {
                _ = nc.free_item(i);
            };
            self.allocator.free(self.items);
            self.items = &.{};
        }
        for (self.item_strings.items) |s| self.allocator.free(s);
        self.item_strings.clearRetainingCapacity();

        if (self.sub) |s| {
            _ = nc.delwin(s);
            self.sub = null;
        }
        if (self.win) |w| {
            _ = nc.delwin(w);
            self.win = null;
        }
    }

    fn drawScreenHeader(self: *MenuView, scr_cols: i32) void {
        _ = nc.mvhline(1, 0, ' ', scr_cols);

        const title = self.engine.schema.title orelse "Configuration";
        const tlen: i32 = @intCast(title.len);
        _ = nc.attron(nc.COLOR_PAIR(nc.PAIR_HEADER) | nc.A_BOLD | nc.A_UNDERLINE);
        nc.mvprint(1, @divTrunc(scr_cols - tlen, 2), "{s}", .{title});
        _ = nc.attroff(nc.COLOR_PAIR(nc.PAIR_HEADER) | nc.A_BOLD | nc.A_UNDERLINE);
    }

    fn drawPanelBorder(self: *MenuView, w: ?*nc.WINDOW) void {
        _ = nc.wattron(w, nc.COLOR_PAIR(nc.PAIR_PANEL));

        _ = nc.box(w, 0, 0);

        _ = nc.wattroff(w, nc.COLOR_PAIR(nc.PAIR_PANEL));
        _ = self;
    }

    fn drawPanelTitle(self: *MenuView, w: ?*nc.WINDOW) void {
        const cur = self.stack.getLast();
        const label = cur.label;
        _ = nc.wattron(w, nc.COLOR_PAIR(nc.PAIR_TITLE) | nc.A_BOLD);
        nc.mvwprint(w, 0, 5, " {s} ", .{label});
        _ = nc.wattroff(w, nc.COLOR_PAIR(nc.PAIR_TITLE) | nc.A_BOLD);
    }

    fn drawPanelFooter(self: *MenuView, w: ?*nc.WINDOW) void {
        const HelpKey = struct {
            key: []const u8,
            desc: []const u8,
        };

        const keys = [_]HelpKey{
            .{ .key = "<Enter>", .desc = "Select" },
            .{ .key = "j/k", .desc = "Down/Up" },
            .{ .key = "?", .desc = "Help" },
            .{ .key = "s", .desc = "Save" },
            .{ .key = "q", .desc = "Quit" },
        };

        _ = self;
        const h = nc.getmaxy(w);

        var cur_x: i32 = 2;

        for (keys) |k| {
            _ = nc.wattron(w, nc.A_BOLD);
            nc.mvwprint(w, h - 1, cur_x, "{s}", .{k.key});
            _ = nc.wattroff(w, nc.A_BOLD);
            cur_x += @intCast(k.key.len);

            _ = nc.wattron(w, nc.COLOR_PAIR(nc.PAIR_PANEL) | nc.A_REVERSE);
            nc.mvwprint(w, h - 1, cur_x, "{s}", .{k.desc});
            _ = nc.wattroff(w, nc.COLOR_PAIR(nc.PAIR_PANEL) | nc.A_REVERSE);

            cur_x += @intCast(k.desc.len + 1);
        }
    }

    fn getLabelForEntry(self: *MenuView, entry: *const Schema.Entry) ![:0]u8 {
        return switch (entry.kind) {
            .bool => std.fmt.allocPrintSentinel(self.allocator, "[{s}] {s}", .{ if (self.engine.get(entry.key.?).?.bool) "*" else " ", entry.label }, 0),
            .menu => std.fmt.allocPrintSentinel(self.allocator, "{s}  --->", .{entry.label}, 0),
            .int => std.fmt.allocPrintSentinel(self.allocator, "({d}) {s}", .{ (self.engine.get(entry.key.?).?).int, entry.label }, 0),
            .choice => std.fmt.allocPrintSentinel(self.allocator, "({s}) {s}", .{ (self.engine.get(entry.key.?).?).choice, entry.label }, 0),
            .string => std.fmt.allocPrintSentinel(self.allocator, "({s}) {s}", .{ (self.engine.get(entry.key.?).?).string, entry.label }, 0),
        };
    }

    fn currentIndex(self: *MenuView) usize {
        const item = nc.current_item(self.menu) orelse return 0;
        for (self.items, 0..) |it, i| {
            if (it == item) return i;
        }
        return 0;
    }

    fn showHelp(self: *MenuView) void {
        if (self.menu == null) return;
        const item = nc.current_item(self.menu) orelse return;
        const entry: *const Schema.Entry = @ptrCast(@alignCast(nc.item_userptr(item)));
        const help = entry.help orelse {
            ui.helpDialog(entry.label, "(no help available)");
            return;
        };
        ui.helpDialog(entry.label, help);
    }
};
