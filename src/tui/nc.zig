const std = @import("std");

pub const WINDOW = opaque {};
pub const ITEM = opaque {};
pub const MENU = opaque {};

pub extern fn initscr() ?*WINDOW;
pub extern fn endwin() c_int;
pub extern fn cbreak() c_int;
pub extern fn noecho() c_int;
pub extern fn keypad(win: ?*WINDOW, bf: c_int) c_int;
pub extern fn curs_set(visibility: c_int) c_int;
pub extern fn getch() c_int;
pub extern fn wgetch(win: ?*WINDOW) c_int;
pub extern fn clear() c_int;
pub extern fn erase() c_int;
pub extern fn refresh() c_int;
pub extern fn wrefresh(win: ?*WINDOW) c_int;
pub extern fn wnoutrefresh(win: ?*WINDOW) c_int;
pub extern fn doupdate() c_int;
pub extern fn touchwin(win: ?*WINDOW) c_int;

pub extern fn werase(win: ?*WINDOW) c_int;
pub extern fn newwin(nlines: c_int, ncols: c_int, begin_y: c_int, begin_x: c_int) ?*WINDOW;
pub extern fn derwin(orig: ?*WINDOW, nlines: c_int, ncols: c_int, begin_y: c_int, begin_x: c_int) ?*WINDOW;
pub extern fn delwin(win: ?*WINDOW) c_int;

pub extern fn mvaddstr(y: c_int, x: c_int, str: [*:0]const u8) c_int;
pub extern fn mvwaddstr(win: ?*WINDOW, y: c_int, x: c_int, str: [*:0]const u8) c_int;
pub extern fn mvhline(y: c_int, x: c_int, ch: c_uint, n: c_int) c_int;
pub extern fn whline(win: ?*WINDOW, ch: c_uint, n: c_int) c_int;

pub extern fn attron(attrs: c_int) c_int;
pub extern fn attroff(attrs: c_int) c_int;
pub extern fn wattron(win: ?*WINDOW, attrs: c_int) c_int;
pub extern fn wattroff(win: ?*WINDOW, attrs: c_int) c_int;
pub extern fn attrset(attrs: c_int) c_int;

pub extern fn getmaxy(win: ?*WINDOW) c_int;
pub extern fn getmaxx(win: ?*WINDOW) c_int;

pub extern fn box(win: ?*WINDOW, verch: c_uint, horch: c_uint) c_int;
pub extern fn wborder(
    win: ?*WINDOW,
    ls: c_uint,
    rs: c_uint,
    ts: c_uint,
    bs: c_uint,
    tl: c_uint,
    tr: c_uint,
    bl: c_uint,
    br: c_uint,
) c_int;

pub extern fn move(y: c_int, x: c_int) c_int;
pub extern fn wmove(win: ?*WINDOW, y: c_int, x: c_int) c_int;
pub extern fn waddch(win: ?*WINDOW, ch: c_uint) c_int;
pub extern fn wbkgd(win: ?*WINDOW, ch: c_uint) c_int;
pub extern fn napms(ms: c_int) c_int;

pub extern fn start_color() c_int;
pub extern fn use_default_colors() c_int;
pub extern fn has_colors() c_int;
pub extern fn init_pair(pair: c_short, f: c_short, b: c_short) c_int;

pub extern fn new_item(name: [*:0]const u8, description: [*:0]const u8) ?*ITEM;
pub extern fn free_item(item: ?*ITEM) c_int;

pub extern fn new_menu(items: [*]?*ITEM) ?*MENU;
pub extern fn free_menu(menu: ?*MENU) c_int;
pub extern fn post_menu(menu: ?*MENU) c_int;
pub extern fn unpost_menu(menu: ?*MENU) c_int;
pub extern fn menu_driver(menu: ?*MENU, c: c_int) c_int;

pub extern fn current_item(menu: ?*MENU) ?*ITEM;
pub extern fn set_current_item(menu: ?*MENU, item: ?*ITEM) c_int;
pub extern fn item_userptr(item: ?*ITEM) ?*anyopaque;
pub extern fn set_item_userptr(item: ?*ITEM, userptr: ?*anyopaque) c_int;

pub extern fn set_menu_win(menu: ?*MENU, win: ?*WINDOW) c_int;
pub extern fn set_menu_sub(menu: ?*MENU, win: ?*WINDOW) c_int;
pub extern fn set_menu_format(menu: ?*MENU, rows: c_int, cols: c_int) c_int;
pub extern fn set_menu_mark(menu: ?*MENU, mark: [*:0]const u8) c_int;

pub extern fn set_menu_fore(menu: ?*MENU, attr: c_int) c_int;
pub extern fn set_menu_back(menu: ?*MENU, attr: c_int) c_int;
pub extern fn set_menu_grey(menu: ?*MENU, attr: c_int) c_int;
pub extern fn pos_menu_cursor(menu: ?*MENU) c_int;

pub extern fn set_escdelay(delay: c_int) c_int;

pub const A_UNDERLINE: c_int = 1 << 17;
pub const A_REVERSE: c_int = 1 << 18;
pub const A_DIM: c_int = 1 << 19;
pub const A_BOLD: c_int = 1 << 21;

pub const KEY_UP: c_int = 259;
pub const KEY_DOWN: c_int = 258;
pub const KEY_LEFT: c_int = 260;
pub const KEY_RIGHT: c_int = 261;
pub const KEY_HOME: c_int = 262;
pub const KEY_END: c_int = 360;
pub const KEY_PPAGE: c_int = 339;
pub const KEY_NPAGE: c_int = 338;
pub const KEY_BACKSPACE: c_int = 263;
pub const KEY_RESIZE: c_int = 410;
pub const KEY_ENTER: c_int = 343;

pub const REQ_UP_ITEM: c_int = 512 + 2;
pub const REQ_DOWN_ITEM: c_int = 512 + 3;
pub const REQ_SCR_UPAGE: c_int = 512 + 11;
pub const REQ_SCR_DPAGE: c_int = 512 + 12;
pub const REQ_FIRST_ITEM: c_int = 512 + 22;
pub const REQ_LAST_ITEM: c_int = 512 + 23;

pub const COLOR_BLACK: c_short = 0;
pub const COLOR_RED: c_short = 1;
pub const COLOR_GREEN: c_short = 2;
pub const COLOR_YELLOW: c_short = 3;
pub const COLOR_BLUE: c_short = 4;
pub const COLOR_MAGENTA: c_short = 5;
pub const COLOR_CYAN: c_short = 6;
pub const COLOR_WHITE: c_short = 7;

pub fn COLOR_PAIR(n: c_short) c_int {
    return @as(c_int, @intCast(n)) << 8;
}

pub const ACS_VLINE: c_uint = 'x' | 0x00400000;
pub const ACS_HLINE: c_uint = 'q' | 0x00400000;
pub const ACS_ULCORNER: c_uint = 'l' | 0x00400000;
pub const ACS_URCORNER: c_uint = 'k' | 0x00400000;
pub const ACS_LLCORNER: c_uint = 'm' | 0x00400000;
pub const ACS_LRCORNER: c_uint = 'j' | 0x00400000;
pub const ACS_LTEE: c_uint = 't' | 0x00400000;
pub const ACS_RTEE: c_uint = 'u' | 0x00400000;

pub const PAIR_HEADER: c_short = 1;
pub const PAIR_PANEL: c_short = 2;
pub const PAIR_TITLE: c_short = 3;
pub const PAIR_ERROR: c_short = 4;
pub const PAIR_HINT: c_short = 5;

pub extern fn nc_stdscr() ?*WINDOW;
pub extern fn nc_LINES() c_int;
pub extern fn nc_COLS() c_int;

pub fn stdscr() ?*WINDOW {
    return nc_stdscr();
}
pub fn rows() c_int {
    return nc_LINES();
}
pub fn cols() c_int {
    return nc_COLS();
}

pub fn mvprint(y: i32, x: i32, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    _ = mvaddstr(y, x, s.ptr);
}

pub fn mvwprint(win: ?*WINDOW, y: i32, x: i32, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    _ = mvwaddstr(win, y, x, s.ptr);
}
