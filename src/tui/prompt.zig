const std = @import("std");
const nc = @import("nc.zig");
const zc = @import("zonfig");
const ui = @import("ui.zig");

pub const PromptError = error{ Cancelled, InvalidInput };

pub fn promptInt(title: []const u8, current: i64, range: ?zc.Schema.Range) !i64 {
    const w: i32 = 44;
    const h: i32 = 7;
    const d = ui.Dialog.open(title, h, w);
    defer d.close();

    var init_buf: [32]u8 = undefined;
    const init = std.fmt.bufPrint(&init_buf, "{d}", .{current}) catch "";
    var buf = ui.InputBuffer(32).initFrom(init);

    _ = nc.curs_set(1);
    defer _ = nc.curs_set(0);

    while (true) {
        d.drawFrame(title);
        if (range) |r|
            d.printColored(2, 2, nc.PAIR_HINT, "range: {d}..{d}", .{ r.min, r.max });
        d.inputField(3, buf.slice());
        d.hint("<Enter> confirm  <Esc> cancel");
        d.setCursor(3, 2 + @as(i32, @intCast(buf.len)));
        d.refresh();

        switch (d.getch()) {
            '0'...'9' => |ch| buf.append(@intCast(ch)),
            '-' => {
                if (buf.len == 0) buf.append('-');
            },
            nc.KEY_BACKSPACE, 127 => buf.backspace(),
            '\n', '\r' => {
                const v = std.fmt.parseInt(i64, buf.slice(), 10) catch {
                    d.showError("invalid integer");
                    buf.clear();
                    continue;
                };
                if (range) |r| if (v < r.min or v > r.max) {
                    d.showError("out of range");
                    buf.clear();
                    continue;
                };
                return v;
            },
            27 => return error.Cancelled,
            else => {},
        }
    }
}

pub fn promptString(allocator: std.mem.Allocator, title: []const u8, current: []const u8) ![]u8 {
    const w: i32 = 52;
    const h: i32 = 6;
    const d = ui.Dialog.open(title, h, w);
    defer d.close();

    var buf = ui.InputBuffer(256).initFrom(current);

    _ = nc.curs_set(1);
    defer _ = nc.curs_set(0);

    while (true) {
        d.drawFrame(title);
        d.inputField(2, buf.slice());
        d.hint("<Enter> confirm  <Esc> cancel");
        d.setCursor(2, 2 + @as(i32, @intCast(buf.len)));
        d.refresh();

        switch (d.getch()) {
            32...126 => |ch| buf.append(@intCast(ch)),
            nc.KEY_BACKSPACE, 127 => buf.backspace(),
            '\n', '\r' => return allocator.dupe(u8, buf.slice()),
            27 => return error.Cancelled,
            else => {},
        }
    }
}

pub fn promptChoice(title: []const u8, options: []const []const u8, current: usize) !usize {
    const w: i32 = 44;
    const h: i32 = @intCast(options.len + 5);
    const d = ui.Dialog.open(title, h, w);
    defer d.close();

    var cur = current;

    while (true) {
        d.drawFrame(title);
        for (options, 0..) |opt, i| {
            const row: i32 = @intCast(i + 2);
            if (i == cur) {
                _ = nc.wattron(d.win, nc.A_REVERSE);
            }
            _ = nc.wmove(d.win, row, 2);
            _ = nc.whline(d.win, ' ', w - 4);

            d.print(row, 3, "{s}", .{opt});

            if (i == cur) {
                _ = nc.wattroff(d.win, nc.A_REVERSE);
            }
        }
        d.hint("<Enter> confirm  <Esc> cancel");
        d.refresh();

        switch (d.getch()) {
            nc.KEY_UP, 'k' => {
                if (cur > 0) cur -= 1;
            },
            nc.KEY_DOWN, 'j' => {
                if (cur + 1 < options.len) cur += 1;
            },
            '\n', '\r' => return cur,
            27 => return error.Cancelled,
            else => {},
        }
    }
}

pub const QuitAction = enum { save, discard, cancel };

pub fn promptQuit(dirty: bool) QuitAction {
    if (!dirty) return .discard;

    const buttons = [_][]const u8{ "Save", "Don't save" };
    var d = ui.ButtonDialog.open(
        "Quit",
        "You have unsaved changes.",
        &buttons,
        true,
    );
    defer d.close();

    return switch (d.run() orelse 2) {
        0 => .save,
        1 => .discard,
        else => .cancel,
    };
}
