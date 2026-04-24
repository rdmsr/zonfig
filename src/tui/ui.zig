const std = @import("std");
const nc = @import("nc.zig");

/// A centered bordered window with a title.
/// Used for all pop-ups.
pub const Dialog = struct {
    win: ?*nc.WINDOW,
    h: i32,
    w: i32,

    pub fn open(title: []const u8, h: i32, w: i32) Dialog {
        const scr_rows = nc.getmaxy(nc.stdscr());
        const scr_cols = nc.getmaxx(nc.stdscr());
        const win = nc.newwin(
            h,
            w,
            @divTrunc(scr_rows - h, 2),
            @divTrunc(scr_cols - w, 2),
        );
        _ = nc.keypad(win, 1);
        const d = Dialog{ .win = win, .h = h, .w = w };
        d.drawFrame(title);
        return d;
    }

    pub fn close(self: Dialog) void {
        _ = nc.delwin(self.win);
    }

    pub fn refresh(self: Dialog) void {
        _ = nc.wrefresh(self.win);
    }

    pub fn drawFrame(self: Dialog, title: []const u8) void {
        _ = nc.werase(self.win);
        _ = nc.wattron(self.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
        _ = nc.box(self.win, 0, 0);
        _ = nc.wattroff(self.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
        _ = nc.wattron(self.win, nc.COLOR_PAIR(nc.PAIR_TITLE) | nc.A_BOLD);
        nc.mvwprint(self.win, 0, 2, " {s} ", .{title});
        _ = nc.wattroff(self.win, nc.COLOR_PAIR(nc.PAIR_TITLE) | nc.A_BOLD);
    }

    pub fn print(self: Dialog, row: i32, col: i32, comptime fmt: []const u8, args: anytype) void {
        nc.mvwprint(self.win, row, col, fmt, args);
    }

    pub fn printColored(self: Dialog, row: i32, col: i32, pair: c_short, comptime fmt: []const u8, args: anytype) void {
        _ = nc.wattron(self.win, nc.COLOR_PAIR(pair));
        nc.mvwprint(self.win, row, col, fmt, args);
        _ = nc.wattroff(self.win, nc.COLOR_PAIR(pair));
    }

    pub fn printAttr(self: Dialog, row: i32, col: i32, attr: c_int, comptime fmt: []const u8, args: anytype) void {
        _ = nc.wattron(self.win, attr);
        nc.mvwprint(self.win, row, col, fmt, args);
        _ = nc.wattroff(self.win, attr);
    }

    pub fn hint(self: Dialog, msg: []const u8) void {
        self.printColored(self.h - 2, 2, nc.PAIR_HINT, "{s}", .{msg});
    }

    pub fn inputField(self: Dialog, row: i32, text: []const u8) void {
        _ = nc.wattron(self.win, nc.A_UNDERLINE);
        _ = nc.wmove(self.win, row, 2);
        _ = nc.whline(self.win, ' ', self.w - 4);
        nc.mvwprint(self.win, row, 2, "{s}", .{text});
        _ = nc.wattroff(self.win, nc.A_UNDERLINE);
    }

    pub fn setCursor(self: Dialog, row: i32, col: i32) void {
        _ = nc.wmove(self.win, row, col);
    }

    pub fn getch(self: Dialog) c_int {
        return nc.wgetch(self.win);
    }

    pub fn showError(self: Dialog, msg: []const u8) void {
        _ = nc.werase(self.win);
        _ = nc.wattron(self.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
        _ = nc.box(self.win, 0, 0);
        _ = nc.wattroff(self.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
        const mlen: i32 = @intCast(msg.len);
        _ = nc.wattron(self.win, nc.COLOR_PAIR(nc.PAIR_ERROR) | nc.A_BOLD);
        nc.mvwprint(self.win, @divTrunc(self.h, 2), @divTrunc(self.w - mlen, 2), "{s}", .{msg});
        _ = nc.wattroff(self.win, nc.COLOR_PAIR(nc.PAIR_ERROR) | nc.A_BOLD);
        self.hint("Enter / Esc to continue");
        _ = nc.wrefresh(self.win);
        while (true) {
            switch (self.getch()) {
                '\n', '\r', 27 => break,
                else => {},
            }
        }
    }
};

/// Fixed capacity input buffer for text fields in dialogs.
pub fn InputBuffer(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn initFrom(text: []const u8) Self {
            var self = Self{};
            self.len = @min(text.len, capacity - 1);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
            return self;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn append(self: *Self, ch: u8) void {
            if (self.len < capacity - 1) {
                self.buf[self.len] = ch;
                self.len += 1;
            }
        }

        pub fn backspace(self: *Self) void {
            if (self.len > 0) self.len -= 1;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

/// Word-wrap a string into lines of a given width.
pub const WrapIter = struct {
    src: []const u8,
    width: usize,
    pos: usize = 0,

    pub fn next(self: *WrapIter) ?[]const u8 {
        if (self.pos >= self.src.len) return null;
        const rem = self.src[self.pos..];
        if (rem.len <= self.width) {
            self.pos = self.src.len;
            return rem;
        }
        var cut = self.width;
        while (cut > 0 and rem[cut] != ' ') cut -= 1;
        if (cut == 0) cut = self.width;
        const line = rem[0..cut];
        self.pos += cut;
        if (self.pos < self.src.len and self.src[self.pos] == ' ')
            self.pos += 1;
        return line;
    }

    pub fn countLines(src: []const u8, width: usize) i32 {
        var it = WrapIter{ .src = src, .width = width };
        var n: i32 = 0;
        while (it.next()) |_| n += 1;
        return n;
    }
};

pub fn helpDialog(title: []const u8, help: []const u8) void {
    const w: i32 = 60;
    const inner: usize = @intCast(w - 4);
    const lines = WrapIter.countLines(help, inner);
    const h: i32 = lines + 5;
    const d = Dialog.open(title, h, w);
    defer d.close();

    d.drawFrame(title);

    var row: i32 = 2;
    var it = WrapIter{ .src = help, .width = inner };
    while (it.next()) |line| {
        d.print(row, 2, "{s}", .{line});
        row += 1;
    }

    d.hint("<Enter> / <Esc> to close");
    d.refresh();

    while (true) {
        switch (d.getch()) {
            '\n', '\r', 27, '?' => break,
            else => {},
        }
    }
}

/// A dialog with a message and a horizontal list of buttons at the bottom.
pub const ButtonDialog = struct {
    dialog: Dialog,
    buttons: []const []const u8,
    selected: usize = 0,

    pub fn open(title: []const u8, message: []const u8, buttons: []const []const u8, cancellable: bool) ButtonDialog {
        const w: i32 = @max(44, @as(i32, @intCast(message.len)) + 8);
        const h: i32 = 7;
        const d = Dialog.open(title, h, w);
        const mlen: i32 = @intCast(message.len);
        d.print(2, @divTrunc(w - mlen, 2), "{s}", .{message});

        if (cancellable) {
            d.printColored(3, 2, nc.PAIR_HINT, "<Esc> to cancel and resume configuration", .{});
        }

        return .{ .dialog = d, .buttons = buttons };
    }

    pub fn close(self: ButtonDialog) void {
        self.dialog.close();
    }

    /// Run the dialog to completion, returns index of selected button.
    /// Esc returns null (cancelled).
    pub fn run(self: *ButtonDialog) ?usize {
        while (true) {
            self.draw();
            switch (self.dialog.getch()) {
                nc.KEY_LEFT, 'h' => {
                    if (self.selected > 0) self.selected -= 1;
                },
                nc.KEY_RIGHT, 'l' => {
                    if (self.selected + 1 < self.buttons.len) self.selected += 1;
                },
                '\n', '\r' => return self.selected,
                27 => return null,
                else => {},
            }
        }
    }

    fn draw(self: *ButtonDialog) void {
        var total: i32 = 0;
        for (self.buttons) |b| total += @as(i32, @intCast(b.len)) + 4;
        total += @as(i32, @intCast(self.buttons.len - 1)) * 2;

        const w = nc.getmaxx(self.dialog.win);
        var col = @divTrunc(w - total, 2);
        const row: i32 = 5;

        for (self.buttons, 0..) |b, i| {
            if (i == self.selected) {
                _ = nc.wattron(self.dialog.win, nc.A_REVERSE);
            } else {
                _ = nc.wattron(self.dialog.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
            }
            nc.mvwprint(self.dialog.win, row, col, "< {s} >", .{b});
            if (i == self.selected) {
                _ = nc.wattroff(self.dialog.win, nc.A_REVERSE);
            } else {
                _ = nc.wattroff(self.dialog.win, nc.COLOR_PAIR(nc.PAIR_PANEL));
            }
            col += @as(i32, @intCast(b.len)) + 4 + 2;
        }

        self.dialog.refresh();
    }
};
