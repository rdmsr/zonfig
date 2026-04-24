const std = @import("std");
const nc = @import("nc.zig");
const zc = @import("zonfig");
const MenuView = @import("menu.zig").MenuView;
const Engine = zc.Engine;

pub fn run(allocator: std.mem.Allocator, engine: *Engine) !void {
    _ = nc.initscr();
    _ = nc.cbreak();
    _ = nc.noecho();
    _ = nc.keypad(nc.stdscr(), 1);
    _ = nc.curs_set(0);
    _ = nc.set_escdelay(25);

    if (nc.has_colors() != 0) {
        _ = nc.start_color();
        _ = nc.use_default_colors();
        _ = nc.init_pair(nc.PAIR_HEADER, nc.COLOR_MAGENTA, -1);
        _ = nc.init_pair(nc.PAIR_PANEL, nc.COLOR_YELLOW, -1);
        _ = nc.init_pair(nc.PAIR_TITLE, nc.COLOR_GREEN, -1);
        _ = nc.init_pair(nc.PAIR_ERROR, nc.COLOR_RED, -1);
        _ = nc.init_pair(nc.PAIR_HINT, nc.COLOR_CYAN, -1);
    }
    defer _ = nc.endwin();

    var view = try MenuView.init(allocator, engine);
    defer view.deinit();

    view.draw();

    while (true) {
        const ch = nc.getch();
        const quit = try view.handleKey(ch);
        if (quit) break;
    }
}
