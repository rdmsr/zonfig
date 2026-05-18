// This is mostly boring UI code
const std = @import("std");
const zz = @import("zigzag");
const zc = @import("zonfig");
const Engine = zc.Engine;
const Schema = zc.Schema;

const EntryList = zz.List(*const Schema.Entry);
const ChoiceList = zz.List(usize);

const QuitChoice = enum { yes, no };

const Mode = union(enum) {
    menu,
    edit_string: EditCtx,
    edit_int: EditCtx,
    choose: ChooseCtx,
    help: HelpCtx,
    quit_confirm: QuitChoice,
};

const EditCtx = struct {
    key: []const u8,
    entry_label: []const u8,
    range: ?Schema.Range,
};

const ChooseCtx = struct {
    key: []const u8,
};

const HelpCtx = struct {
    title: []const u8,
    text: []const u8,
};

const StatusTone = enum { info, success, warning, danger };

const Status = struct {
    tone: StatusTone,
    text: []const u8,
};

// It would be nice to maybe provide theming in the future...
// we'll see.
const Theme = struct {
    fn base() zz.Style {
        var s = zz.Style{};
        return s.inline_style(true);
    }

    fn titleStyle() zz.Style {
        var s = base();
        s = s.bold(true);
        s = s.fg(zz.Color.white);
        return s;
    }

    fn sectionStyle() zz.Style {
        var s = base();
        s = s.fg(zz.Color.gray(14));
        return s;
    }

    fn subtleStyle() zz.Style {
        var s = base();
        s = s.fg(zz.Color.gray(10));
        return s;
    }

    fn accentStyle() zz.Style {
        var s = base();
        s = s.fg(zz.Color.cyan);
        return s;
    }

    fn highlightStyle() zz.Style {
        var s = base();
        s = s.bold(true);
        s = s.fg(zz.Color.cyan);
        return s;
    }

    fn keyStyle() zz.Style {
        return highlightStyle();
    }

    fn successStyle() zz.Style {
        var s = base();
        s = s.bold(true);
        s = s.fg(zz.Color.green);
        return s;
    }

    fn warningStyle() zz.Style {
        return titleStyle();
    }

    fn dangerStyle() zz.Style {
        var s = base();
        s = s.bold(true);
        s = s.fg(zz.Color.red);
        return s;
    }

    fn plainStyle() zz.Style {
        return base();
    }

    fn dialogStyle(width: u16, tone: StatusTone) zz.Style {
        var s = zz.Style{};
        s = s.borderAll(zz.Border.rounded);
        s = s.borderForeground(borderColor(tone));
        s = s.paddingAll(1);
        s = s.width(width);
        s = s.overflow(.hidden);
        return s;
    }

    fn statusStyle(tone: StatusTone) zz.Style {
        return switch (tone) {
            .info => accentStyle(),
            .success => successStyle(),
            .warning => warningStyle(),
            .danger => dangerStyle(),
        };
    }

    fn borderColor(tone: StatusTone) zz.Color {
        return switch (tone) {
            .info => zz.Color.cyan,
            .success => zz.Color.green,
            .warning => zz.Color.cyan,
            .danger => zz.Color.red,
        };
    }

    fn render(alloc: std.mem.Allocator, s: zz.Style, text: []const u8) []const u8 {
        return s.render(alloc, text) catch text;
    }
};

const Model = struct {
    engine: *Engine,
    gpa: std.mem.Allocator,

    root_entry: Schema.Entry,
    stack: std.ArrayListUnmanaged(*const Schema.Entry),
    entries: std.ArrayListUnmanaged(*const Schema.Entry),
    item_strings: std.ArrayListUnmanaged([]u8),
    list: EntryList,
    text_input: zz.TextInput,
    choice_list: ChoiceList,
    active_opts: std.ArrayListUnmanaged(*const Schema.Option),
    mode: Mode,
    status: ?Status,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        window_size: struct { width: u16, height: u16 },
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.root_entry = Schema.Entry{
            .kind = .menu,
            .label = self.engine.schema.title orelse "Configuration",
            .entries = self.engine.schema.entries,
        };
        self.stack = .empty;
        self.entries = .empty;
        self.item_strings = .empty;
        self.active_opts = .empty;
        self.mode = .menu;
        self.status = null;

        self.stack.append(self.gpa, &self.root_entry) catch return .quit;

        self.list = EntryList.init(self.gpa);
        self.list.height = menuListHeight(ctx.height);
        self.list.focused = true;
        self.list.wrap_around = true;
        self.list.item_style = Theme.plainStyle();
        self.list.cursor_style = Theme.highlightStyle();
        self.list.selected_style = Theme.accentStyle();
        self.list.filter_style = Theme.warningStyle();
        self.list.cursor_symbol = "> ";

        self.text_input = zz.TextInput.init(self.gpa);
        self.text_input.setPrompt("value: ");

        var cur_sty = zz.Style{};
        cur_sty = cur_sty.inline_style(true);
        cur_sty = cur_sty.reverse(true);
        cur_sty = cur_sty.bold(true);
        self.text_input.cursor_style = cur_sty;
        self.text_input.placeholder = "(empty)";

        var prompt_sty = zz.Style{};
        prompt_sty = prompt_sty.inline_style(true);
        prompt_sty = prompt_sty.fg(zz.Color.gray(14));
        self.text_input.prompt_style = prompt_sty;

        self.choice_list = ChoiceList.init(self.gpa);
        self.choice_list.wrap_around = true;
        self.choice_list.item_style = Theme.plainStyle();
        self.choice_list.cursor_style = Theme.highlightStyle();
        self.choice_list.selected_style = Theme.accentStyle();
        self.choice_list.cursor_symbol = "> ";

        self.rebuildMenu() catch return .quit;

        return .none;
    }

    pub fn deinit(self: *Model) void {
        self.freeItemStrings();
        self.item_strings.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.active_opts.deinit(self.gpa);
        self.list.deinit();
        self.text_input.deinit();
        self.choice_list.deinit();
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .window_size => |sz| self.list.height = menuListHeight(sz.height),
            .key => |k| return self.handleKey(k),
        }
        return .none;
    }

    fn menuListHeight(term_h: u16) u16 {
        // title + breadcrumb + separator + status + footer = 5 rows
        return if (term_h > 6) term_h - 6 else 1;
    }

    fn setStatus(self: *Model, tone: StatusTone, text: []const u8) void {
        self.status = .{ .tone = tone, .text = text };
    }

    fn clearStatus(self: *Model) void {
        self.status = null;
    }

    fn saveConfiguration(self: *Model, success_text: ?[]const u8, failure_text: []const u8) bool {
        self.engine.save() catch {
            self.setStatus(.danger, failure_text);
            return false;
        };
        if (success_text) |text| self.setStatus(.success, text);
        return true;
    }

    fn finishTextEdit(self: *Model) void {
        self.clearStatus();
        self.mode = .menu;
        self.text_input.blur();
        self.rebuildMenu() catch {};
    }

    fn cancelTextEdit(self: *Model) void {
        self.clearStatus();
        self.mode = .menu;
        self.text_input.blur();
    }

    fn finishChoiceSelection(self: *Model) void {
        self.clearStatus();
        self.mode = .menu;
        self.choice_list.blur();
        self.rebuildMenu() catch {};
    }

    fn cancelChoiceSelection(self: *Model) void {
        self.mode = .menu;
        self.choice_list.blur();
    }

    fn handleKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        return switch (self.mode) {
            .menu => self.handleMenuKey(k),
            .edit_string, .edit_int => self.handleEditKey(k),
            .choose => self.handleChooseKey(k),
            .help => blk: {
                self.mode = .menu;
                break :blk .none;
            },
            .quit_confirm => self.handleQuitKey(k),
        };
    }

    fn handleMenuKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        self.clearStatus();
        switch (k.key) {
            .up => self.list.cursorUp(),
            .down => self.list.cursorDown(),
            .page_up => self.list.pageUp(),
            .page_down => self.list.pageDown(),
            .home => self.list.gotoFirst(),
            .end => self.list.gotoLast(),
            .enter, .right => self.activate(),
            .left, .escape => self.pop(),
            .char => |c| switch (c) {
                'k' => self.list.cursorUp(),
                'j' => self.list.cursorDown(),
                's' => {
                    _ = self.saveConfiguration("Configuration saved.", "Couldn't save the configuration.");
                },
                'q' => {
                    if (self.engine.dirty) {
                        self.mode = .{ .quit_confirm = .yes };
                    } else {
                        return .quit;
                    }
                },
                '?' => self.showHelp(),
                else => {},
            },
            else => {},
        }
        return .none;
    }

    fn handleEditKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .enter => {
                switch (self.mode) {
                    .edit_int => |ec| self.submitIntEdit(ec),
                    .edit_string => |ec| self.submitStringEdit(ec),
                    else => unreachable,
                }
            },
            .escape => self.cancelTextEdit(),
            else => self.text_input.handleKey(k),
        }
        return .none;
    }

    fn handleChooseKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .enter => {
                const cc = self.mode.choose;
                const idx = self.choice_list.selectedValue() orelse 0;
                if (idx < self.active_opts.items.len) {
                    self.engine.set(cc.key, .{ .choice = self.active_opts.items[idx].value }) catch {
                        self.setStatus(.danger, "Couldn't apply that selection.");
                        return .none;
                    };
                }
                self.finishChoiceSelection();
            },
            .escape => self.cancelChoiceSelection(),
            else => self.choice_list.handleKey(k),
        }
        return .none;
    }

    fn handleQuitKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        const selected = self.mode.quit_confirm;
        switch (k.key) {
            .up, .left => self.mode = .{ .quit_confirm = .yes },
            .down, .right => self.mode = .{ .quit_confirm = .no },
            .tab => self.mode = .{ .quit_confirm = if (selected == .yes) .no else .yes },
            .char => |c| switch (c) {
                'k' => self.mode = .{ .quit_confirm = .yes },
                'j' => self.mode = .{ .quit_confirm = .no },
                'y', 'Y' => {
                    if (!self.saveConfiguration(null, "Couldn't save before quitting.")) {
                        self.mode = .menu;
                        return .none;
                    }
                    return .quit;
                },
                'n', 'N' => return .quit,
                else => {},
            },
            .enter => {
                if (selected == .yes) {
                    if (!self.saveConfiguration(null, "Couldn't save before quitting.")) {
                        self.mode = .menu;
                        return .none;
                    }
                }
                return .quit;
            },
            .escape => self.mode = .menu,
            else => {},
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        return switch (self.mode) {
            .menu => self.viewMenu(ctx, alloc),
            .edit_string => |ec| self.viewEditDialog(alloc, ec, false, ctx.width, ctx.height),
            .edit_int => |ec| self.viewEditDialog(alloc, ec, true, ctx.width, ctx.height),
            .choose => |cc| self.viewChooseDialog(alloc, cc, ctx.width, ctx.height),
            .help => |hc| self.viewHelpDialog(alloc, hc, ctx.width, ctx.height),
            .quit_confirm => |sel| viewQuitDialog(alloc, sel, ctx.width, ctx.height),
        };
    }

    fn makeSep(alloc: std.mem.Allocator, w: u16) []const u8 {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        var i: u16 = 0;
        // Maybe we shouldn't rely on this character being present?
        // I guess since the rest of the UI renders, this should be fine?
        while (i < w) : (i += 1) buf.writer.writeAll("─") catch break;
        return Theme.render(alloc, Theme.subtleStyle(), buf.toOwnedSlice() catch return "");
    }

    fn viewMenu(self: *const Model, ctx: *const zz.Context, alloc: std.mem.Allocator) []const u8 {
        // Header with title and breadcrumb
        const title_raw = self.engine.schema.title orelse "Configuration";
        const header = zz.place.place(
            alloc,
            ctx.width,
            1,
            .center,
            .top,
            Theme.render(alloc, Theme.titleStyle(), title_raw),
        ) catch Theme.render(alloc, Theme.titleStyle(), title_raw);

        // Breadcrumb, each menu is separated by " > ".
        var labels: std.ArrayListUnmanaged([]const u8) = .empty;
        defer labels.deinit(alloc);
        for (self.stack.items) |e| labels.append(alloc, e.label) catch break;
        const breadcrumb = Theme.render(
            alloc,
            Theme.sectionStyle(),
            std.mem.join(alloc, " > ", labels.items) catch "",
        );

        const list_content = if (self.entries.items.len == 0)
            Theme.render(alloc, Theme.subtleStyle(), "  (no visible entries)")
        else
            self.list.view(alloc) catch "(error)";

        // Status line in the bottom, shows current status or unsaved changes notice.
        const status_line = if (self.status) |s|
            Theme.render(alloc, Theme.statusStyle(s.tone), s.text)
        else if (self.engine.dirty)
            Theme.render(alloc, Theme.subtleStyle(), "* unsaved changes  (s to save)")
        else
            "";

        // In the bottom is a footer with key hints.
        // See viewFooter for details.

        return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            header,
            breadcrumb,
            makeSep(alloc, ctx.width),
            list_content,
            status_line,
            viewFooter(alloc),
        }) catch "";
    }

    fn viewEditDialog(self: *const Model, alloc: std.mem.Allocator, ec: EditCtx, is_int: bool, term_w: u16, term_h: u16) []const u8 {
        const title = Theme.render(alloc, Theme.titleStyle(), ec.entry_label);

        const type_hint: []const u8 = if (is_int) blk: {
            if (ec.range) |r| {
                const s = std.fmt.allocPrint(alloc, "integer  {d}..{d}", .{ r.min, r.max }) catch "integer";
                break :blk Theme.render(alloc, Theme.accentStyle(), s);
            }
            break :blk Theme.render(alloc, Theme.accentStyle(), "integer");
        } else Theme.render(alloc, Theme.accentStyle(), "string");

        const status_part: []const u8 = if (self.status) |s| blk: {
            break :blk std.fmt.allocPrint(
                alloc,
                "\n{s}",
                .{Theme.render(alloc, Theme.statusStyle(s.tone), s.text)},
            ) catch "";
        } else "";

        const body = std.fmt.allocPrint(alloc, "{s}\n{s}\n\n{s}\n\n{s}{s}", .{
            title,
            type_hint,
            self.text_input.view(alloc) catch "",
            Theme.render(alloc, Theme.subtleStyle(), "Enter: confirm    Esc: cancel"),
            status_part,
        }) catch "";

        const tone: StatusTone = if (self.status) |s| s.tone else .info;
        return viewDialogStatic(alloc, body, tone, 52, term_w, term_h);
    }

    fn viewChooseDialog(self: *const Model, alloc: std.mem.Allocator, cc: ChooseCtx, term_w: u16, term_h: u16) []const u8 {
        const label = if (self.engine.getEntry(cc.key)) |e| e.label else cc.key;
        const body = std.fmt.allocPrint(alloc, "{s}\n\n{s}\n\n{s}", .{
            Theme.render(alloc, Theme.titleStyle(), label),
            self.choice_list.view(alloc) catch "",
            Theme.render(alloc, Theme.subtleStyle(), "Enter: select    Esc: cancel"),
        }) catch "";
        return viewDialogStatic(alloc, body, .info, 44, term_w, term_h);
    }

    fn viewHelpDialog(_: *const Model, alloc: std.mem.Allocator, hc: HelpCtx, term_w: u16, term_h: u16) []const u8 {
        const body = std.fmt.allocPrint(alloc, "{s}\n\n{s}\n\n{s}", .{
            Theme.render(alloc, Theme.titleStyle(), hc.title),
            hc.text,
            Theme.render(alloc, Theme.subtleStyle(), "Enter / Esc: close"),
        }) catch hc.text;
        return viewDialogStatic(alloc, body, .info, 62, term_w, term_h);
    }

    fn viewQuitDialog(alloc: std.mem.Allocator, selected: QuitChoice, term_w: u16, term_h: u16) []const u8 {
        const cur = Theme.render(alloc, Theme.highlightStyle(), ">");

        const save_line = std.fmt.allocPrint(alloc, "{s} {s}", .{
            if (selected == .yes) cur else " ",
            Theme.render(alloc, if (selected == .yes) Theme.warningStyle() else Theme.sectionStyle(), "Save & Quit"),
        }) catch "";

        const discard_line = std.fmt.allocPrint(alloc, "{s} {s}", .{
            if (selected == .no) cur else " ",
            Theme.render(alloc, if (selected == .no) Theme.dangerStyle() else Theme.sectionStyle(), "Discard changes"),
        }) catch "";

        const body = std.fmt.allocPrint(alloc, "{s}\n{s}\n\n{s}\n{s}\n\n{s}", .{
            Theme.render(alloc, Theme.warningStyle(), "Unsaved Changes"),
            Theme.render(alloc, Theme.sectionStyle(), "You have unsaved changes."),
            save_line,
            discard_line,
            Theme.render(alloc, Theme.subtleStyle(), "j/k: move  Enter: confirm  Esc: back"),
        }) catch "";
        return viewDialogStatic(alloc, body, .warning, 42, term_w, term_h);
    }

    fn viewFooter(alloc: std.mem.Allocator) []const u8 {
        // Key hints shown in the footer.
        const Hint = struct { key: []const u8, desc: []const u8 };
        const hints = [_]Hint{
            .{ .key = "Enter", .desc = "open" },
            .{ .key = "Esc", .desc = "back" },
            .{ .key = "j/k", .desc = "move" },
            .{ .key = "?", .desc = "help" },
            .{ .key = "s", .desc = "save" },
            .{ .key = "q", .desc = "quit" },
        };
        var out: std.Io.Writer.Allocating = .init(alloc);
        const w = &out.writer;
        for (hints, 0..) |h, i| {
            if (i > 0) w.writeAll("  ") catch return "";
            w.writeAll(Theme.render(alloc, Theme.keyStyle(), h.key)) catch return "";
            w.writeAll(Theme.render(alloc, Theme.subtleStyle(), ":")) catch return "";
            w.writeAll(Theme.render(alloc, Theme.accentStyle(), h.desc)) catch return "";
        }
        return out.toOwnedSlice() catch "";
    }

    fn viewDialogStatic(
        alloc: std.mem.Allocator,
        body: []const u8,
        tone: StatusTone,
        preferred_width: u16,
        term_w: u16,
        term_h: u16,
    ) []const u8 {
        const max_w = if (term_w > 4) term_w - 4 else term_w;
        const body_w: u16 = @intCast(@min(zz.width(body), std.math.maxInt(u16)));
        const target_w = @min(@max(preferred_width, body_w), max_w);
        const dialog = Theme.dialogStyle(target_w, tone).render(alloc, body) catch body;
        return zz.place.place(alloc, term_w, term_h, .center, .middle, dialog) catch dialog;
    }

    fn rebuildMenu(self: *Model) !void {
        const saved_cursor = self.list.cursor;
        // Rebuilding can invalidate the current selection if dependencies hide options
        // or entire entries, so we normalize choice values first and then restore the
        // cursor as best we can.
        try self.ensureChoiceValuesAreActive();
        try self.rebuildVisibleEntries(saved_cursor);
    }

    fn ensureChoiceValuesAreActive(self: *Model) !void {
        // Go through all choice entries and check if their currently selected value is still active.
        var it = self.engine.schema.entries_by_key.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (entry.kind != .choice) continue;
            const key = kv.key_ptr.*;
            if (!self.engine.isActive(key)) continue;
            const opts = entry.options orelse continue;
            const cur_val = (self.engine.get(key) orelse continue).choice;

            const still_active = for (opts) |*opt| {
                if (std.mem.eql(u8, opt.value, cur_val) and self.engine.isOptionActive(opt)) break true;
            } else false;

            if (!still_active) {
                // When dependencies hide the currently selected choice, keep the engine
                // in a valid state by falling back to the first visible option.
                const new_val = for (opts) |*opt| {
                    if (self.engine.isOptionActive(opt)) break opt.value;
                } else "";
                try self.engine.set(key, .{ .choice = new_val });
            }
        }
    }

    fn rebuildVisibleEntries(self: *Model, saved_cursor: usize) !void {
        if (self.stack.items.len == 0) return;

        const menu_entry = self.stack.getLast() orelse return;
        self.entries.clearRetainingCapacity();
        try self.engine.collectActive(self.gpa, menu_entry.entries orelse &.{}, &self.entries);

        self.freeItemStrings();
        self.list.clear();

        for (self.entries.items) |entry| {
            const label = try self.getLabelForEntry(entry);
            try self.item_strings.append(self.gpa, label);
            try self.list.addItem(EntryList.Item.init(entry, label));
        }

        if (self.entries.items.len > 0)
            self.list.cursor = @min(saved_cursor, self.entries.items.len - 1);
    }

    fn freeItemStrings(self: *Model) void {
        // List items borrow these rendered labels, so we free them only when the whole
        // menu snapshot is being rebuilt or torn down.
        for (self.item_strings.items) |s| self.gpa.free(s);
        self.item_strings.clearRetainingCapacity();
    }

    fn getLabelForEntry(self: *const Model, entry: *const Schema.Entry) ![]u8 {
        return switch (entry.kind) {
            .menu => std.fmt.allocPrint(self.gpa, "{s}  --->", .{entry.label}),
            .bool => blk: {
                const key = entry.key orelse return error.InvalidEntryKind;
                const value = self.engine.get(key) orelse return error.InvalidEntryKind;
                break :blk std.fmt.allocPrint(self.gpa, "[{s}] {s}", .{
                    if (value.bool) "*" else " ",
                    entry.label,
                });
            },
            .int => blk: {
                const key = entry.key orelse return error.InvalidEntryKind;
                const value = self.engine.get(key) orelse return error.InvalidEntryKind;
                break :blk std.fmt.allocPrint(self.gpa, "({d}) {s}", .{ value.int, entry.label });
            },
            .choice => blk: {
                const key = entry.key orelse return error.InvalidEntryKind;
                const value = self.engine.get(key) orelse return error.InvalidEntryKind;
                break :blk std.fmt.allocPrint(self.gpa, "({s}) {s}", .{ value.choice, entry.label });
            },
            .string => blk: {
                const key = entry.key orelse return error.InvalidEntryKind;
                const value = self.engine.get(key) orelse return error.InvalidEntryKind;
                break :blk std.fmt.allocPrint(self.gpa, "({s}) {s}", .{ value.string, entry.label });
            },
            .import => error.InvalidEntryKind,
        };
    }

    fn activate(self: *Model) void {
        self.clearStatus();
        const entry = self.list.selectedValue() orelse return;
        switch (entry.kind) {
            .menu => self.openMenu(entry),
            .bool => self.toggleBoolEntry(entry),
            .int => self.beginIntEdit(entry),
            .choice => self.beginChoiceSelection(entry),
            .string => self.beginStringEdit(entry),
            .import => return,
        }
    }

    fn pop(self: *Model) void {
        if (self.stack.items.len > 1) {
            _ = self.stack.pop();
            self.rebuildMenu() catch return;
        }
    }

    fn showHelp(self: *Model) void {
        const item = self.list.selectedItem() orelse return;
        const entry = item.value;
        self.mode = .{ .help = .{
            .title = entry.label,
            .text = entry.help orelse "(no help available)",
        } };
    }

    fn submitIntEdit(self: *Model, ec: EditCtx) void {
        const raw_value = self.text_input.getValue();
        const value = std.fmt.parseInt(i64, raw_value, 10) catch {
            self.setStatus(.danger, "Enter a valid integer.");
            return;
        };
        if (ec.range) |range| if (value < range.min or value > range.max) {
            self.setStatus(.danger, "Value is outside the allowed range.");
            return;
        };
        self.engine.set(ec.key, .{ .int = value }) catch {
            self.setStatus(.danger, "Couldn't update that number.");
            return;
        };
        self.finishTextEdit();
    }

    fn submitStringEdit(self: *Model, ec: EditCtx) void {
        self.engine.set(ec.key, .{ .string = self.text_input.getValue() }) catch {
            self.setStatus(.danger, "Couldn't update that text value.");
            return;
        };
        self.finishTextEdit();
    }

    fn openMenu(self: *Model, entry: *const Schema.Entry) void {
        self.stack.append(self.gpa, entry) catch return;
        self.rebuildMenu() catch return;
    }

    fn toggleBoolEntry(self: *Model, entry: *const Schema.Entry) void {
        const key = entry.key orelse return;
        const value = self.engine.get(key) orelse return;
        self.engine.set(key, .{ .bool = !value.bool }) catch {
            self.setStatus(.danger, "Couldn't toggle that option.");
            return;
        };
        self.rebuildMenu() catch return;
    }

    fn beginIntEdit(self: *Model, entry: *const Schema.Entry) void {
        const key = entry.key orelse return;
        const current_value = (self.engine.get(key) orelse Schema.Value{ .int = 0 }).int;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{current_value}) catch "";
        self.prepareTextInput(text) catch return;
        self.mode = .{ .edit_int = .{
            .key = key,
            .entry_label = entry.label,
            .range = entry.range,
        } };
    }

    fn beginChoiceSelection(self: *Model, entry: *const Schema.Entry) void {
        const key = entry.key orelse return;
        const current_value = (self.engine.get(key) orelse Schema.Value{ .choice = "" }).choice;

        self.active_opts.clearRetainingCapacity();
        self.engine.collectActiveOptions(self.gpa, key, &self.active_opts) catch return;

        self.choice_list.clear();
        for (self.active_opts.items, 0..) |opt, i| {
            self.choice_list.addItem(ChoiceList.Item.init(i, opt.label orelse opt.value)) catch return;
        }

        self.choice_list.cursor = self.findChoiceIndex(current_value);
        self.choice_list.height = @intCast(@max(@min(self.active_opts.items.len, 10), 1));
        self.choice_list.focus();
        self.mode = .{ .choose = .{ .key = key } };
    }

    fn beginStringEdit(self: *Model, entry: *const Schema.Entry) void {
        const key = entry.key orelse return;
        const current_value = (self.engine.get(key) orelse Schema.Value{ .string = "" }).string;
        self.prepareTextInput(current_value) catch return;
        self.mode = .{ .edit_string = .{
            .key = key,
            .entry_label = entry.label,
            .range = null,
        } };
    }

    fn prepareTextInput(self: *Model, value: []const u8) !void {
        // Editing reuses a single widget instance, so each mode swap needs to fully
        // repopulate its contents and cursor position.
        try self.text_input.setValue(value);
        self.text_input.cursor = value.len;
        self.text_input.focus();
    }

    fn findChoiceIndex(self: *const Model, current_value: []const u8) usize {
        for (self.active_opts.items, 0..) |opt, i| {
            if (std.mem.eql(u8, opt.value, current_value)) {
                return i;
            }
        }
        return 0;
    }
};

pub fn run(init: std.process.Init, engine: *Engine) !void {
    var program = zz.Program(Model).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    program.model.engine = engine;
    program.model.gpa = init.gpa;
    try program.run();
}
