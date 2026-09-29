// Spoil: milk's file manager.
//
// A small, fast file browser that wears milk's look (colours, fonts, the
// Tabler icon font, the bar's pills and radii from milk.json) and knows milk's
// folders (the runtime Common/AreaN shortcut folders and the wallpapers).
// Built on milk's own X11 layer (package tx), configuration loader (package
// config) and icon-theme loader (package desktop).
//
// Usage: spoil [folder or file]   (a file opens its folder with it selected)
package spoil

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"
import tx "milk:tx"

VERSION :: "1.0.0"

// SIGTERM/SIGINT/SIGHUP end the event loop, so the normal cleanup stops the
// embedded terminal and viewer instead of leaving them running.
g_quit: bool

on_quit_signal :: proc "c" (sig: posix.Signal) { g_quit = true }

main :: proc() {
	verbose := false
	start := ""
	for arg in os.args[1:] {
		switch arg {
		case "-v", "--verbose":
			verbose = true
		case "-h", "--help":
			fmt.println("usage: spoil [-v] [folder]\n\nmilk's file manager. Opens the folder given (or a file's folder), else $HOME.")
			return
		case "--version":
			fmt.printfln("spoil %s", VERSION)
			return
		case:
			if start == "" { start = arg }
		}
	}
	context.logger = log.create_console_logger(verbose ? .Debug : .Info, {.Level, .Terminal_Color})
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	quit_action: posix.sigaction_t
	quit_action.sa_handler = on_quit_signal
	posix.sigemptyset(&quit_action.sa_mask)
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) { posix.sigaction(sig, &quit_action, nil) }

	cwd, _ := os.get_working_directory(context.temp_allocator)
	if cwd == "" { cwd = home_dir() }
	select := ""
	dir := start == "" ? home_dir() : absolute_path(start, cwd)
	if start != "" && path_exists(dir) && !is_directory(dir) {
		select = base_name(dir)
		dir = parent_dir(dir)
	}

	c, ok := tx.connect()
	if !ok {
		fmt.eprintln("spoil: cannot open the X display")
		os.exit(1)
	}
	a, created := app_create(c, dir)
	if created {
		if select != "" { select_by_name(a, cur_tab(a), select) }
		run(a)
	}
	app_destroy(a)
	tx.disconnect(c)
}
