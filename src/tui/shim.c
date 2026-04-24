#include <ncurses.h>
#include <menu.h>

WINDOW *nc_stdscr(void) { return stdscr; }
int     nc_LINES(void)  { return LINES;  }
int     nc_COLS(void)   { return COLS;   }
