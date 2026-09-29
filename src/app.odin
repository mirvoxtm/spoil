// The Spoil window: a normal managed top-level (WM_CLASS spoil/Spoil) with
// milk's look, its state, and the event loop (one X connection, poll() on the
// X fd and the thumbnail and search wake-up pipes, a timeout for animations
// and timers).
package spoil

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import config "milk:config"
import tx "milk:tx"

Focus :: enum { View, Search, Path, Rename }
View_Mode :: enum { Grid, List }

Action :: enum {
	None,
	Back, Forward, Up,
	Crumb,       // arg = crumb index
	Crumb_Bar,   // empty space next to the crumbs: edit the path
	Search,      // the search field
	Clear_Search,
	Path_Field,
	View_Grid, View_List,
	Hidden,
	Place,       // arg = sidebar index
	Item,        // arg = view index
	Empty,       // the item area outside any item
	Scrollbar,
	Rename_Field,
	Tab,         // arg = tab index
	Tab_Close,   // arg = tab index
	Tab_New,
	Tab_Strip,   // empty space of a tab strip
	Divider,     // arg = index of the pane on its left
	Pane,        // anything else inside a pane (activates it)
	Card_Field, Card_Format, Card_Cancel, Card_Ok, // the "Comprimir…" card
	Viewer_Prev, Viewer_Next, Viewer_External, Viewer_Close, // the embedded viewer (see embed.odin)
	Term_Close, // the embedded terminal
	Search_Tab,  // the magnifier next to a tab strip: search the disk
	Sort_Column, // arg = Search_Sort (a search tab's column titles)
	Reindex,
}

Hit :: struct {
	r:      tx.Rect,
	action: Action,
	pane:   int,
	arg:    int,
	clip:   tx.Rect, // hits inside a scrolled area only count inside it
}

Text_Item :: struct {
	font:     ^tx.Font,
	x:        i32,
	baseline: i32,
	s:        string,
	color:    tx.Color,
	clip:     tx.Rect,
}

App :: struct {
	c:            ^tx.Connection,
	win:          xlib.Window,
	w, h:         i32,
	pixmap:       xlib.Pixmap,
	base:         tx.Canvas, // backdrop, toolbar strips and cards (rebuilt on resize/restyle/layout)
	base_dirty:   bool,
	frame:        tx.Canvas,
	cursors:      [4]xlib.Cursor, // arrow, text, busy, resize
	cursor_shape: int,
	input:        tx.Input,
	has_focus:    bool,
	running:      bool,
	pt:           bool, // Portuguese labels

	// milk.json
	cfg_path:     string,
	cfg:          ^config.Config, // nil = milk's defaults
	cfg_mtime:    i64,
	next_check:   f64,
	style:        Style,
	look:         string, // look_signature of the style in use (owned)
	icons:        Icon_Set,
	thumbs:       Thumbs,
	search:       Search_Service, // the disk index and its searches (search.odin)

	// Panes and tabs
	panes:        [dynamic]^Pane,
	active_pane:  int,
	side_scroll:  i32,
	side_max:     i32,

	// Text fields (the search field lives in each tab, the path field in each pane)
	focus:        Focus,
	rename:       Field,
	rename_name:  string, // the entry being renamed in the active tab (owned)
	rename_index: int,    // its index in the tab's entries

	// Pointer
	hits:         [dynamic]Hit,
	texts:        [dynamic]Text_Item, // temp, rebuilt every frame
	crumbs:       [MAX_PANES][dynamic]string, // paths of the crumbs drawn last, per pane (owned)
	sub_origin:   [2]i32,             // window position of the item canvas being drawn
	sub_clip:     tx.Rect,
	hover:        Hit,
	pointer:      [2]i32,
	last_click:   xlib.Time,
	last_item:    int,
	last_pane:    int,
	drag:         Drag,

	term:         Embed, // the terminal column on the right (embed.odin)
	menu:         Menu,
	card:         Card, // the "Comprimir…" dialog
	clip:         Clip,
	jobs:         [dynamic]Job,
	children:     [dynamic]posix.pid_t,
	spin_at:      f64,

	notice:       string, // owned
	notice_until: f64,
	notice_warn:  bool,
	dirty:        bool,
}

WINDOW_MASK :: xlib.EventMask{.KeyPress, .ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .Exposure,
                               .StructureNotify, .FocusChange, .PropertyChange}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
app_create :: proc(c: ^tx.Connection, start_dir: string) -> (^App, bool) {
	a := new(App)
	a.c = c
	a.last_item = -1
	a.cfg_path = find_config()
	load_config(a, true)
	detect_tools()
	detect_archive_tools()
	apply_style(a)
	if a.style.font == nil {
		log.error("No usable font")
		return a, false
	}
	thumbs_init(a)
	search_init(a)
	t := tab_create(.Grid, false)
	if !navigate(a, t, start_dir, false) {
		log.warnf("Cannot open %s; showing the home folder", start_dir)
		if !navigate(a, t, home_dir(), false) { navigate(a, t, "/", false) }
	}
	p := pane_create()
	append(&p.tabs, t)
	append(&a.panes, p)
	if !open_window(a) { return a, false }
	set_title(a)
	a.running = true
	return a, true
}

app_destroy :: proc(a: ^App) {
	if a == nil { return }
	search_destroy(a)
	embeds_destroy(a)
	card_close(a)
	card_destroy(a)
	menu_destroy(a)
	clip_destroy(a)
	jobs_destroy(a)
	drag_reset(a)
	thumbs_destroy(a)
	icons_reset(a)
	release_style(a)
	tx.input_close(&a.input)
	if a.win != 0 { tx.destroy_window(a.c, a.win) }
	tx.pixmap_free(a.c, a.pixmap)
	for cur in a.cursors { if cur != 0 { xlib.FreeCursor(a.c.dpy, cur) } }
	tx.canvas_destroy(&a.base)
	tx.canvas_destroy(&a.frame)
	for p in a.panes { pane_destroy(p) }
	delete(a.panes)
	field_destroy(&a.rename)
	delete(a.rename_name)
	delete(a.hits)
	for &list in a.crumbs {
		for p in list { delete(p) }
		delete(list)
	}
	delete(a.children)
	delete(a.notice)
	delete(a.cfg_path)
	delete(a.look)
	if a.cfg != nil { config.destroy(a.cfg) }
	tx.sync(a.c)
	free(a)
}

@(private)
open_window :: proc(a: ^App) -> bool {
	c := a.c
	mon := tx.monitor_rect(c, "primary")
	work := tx.subtract_bars(c, mon)
	a.w = min(i32(1000), work.w - 40)
	a.h = min(i32(640), work.h - 40)
	a.w = max(a.w, 480)
	a.h = max(a.h, 320)
	x := work.x + (work.w - a.w) / 2
	y := work.y + (work.h - a.h) / 2

	attrs: xlib.XSetWindowAttributes
	bg := a.style.theme.backdrop
	attrs.background_pixel = uint(bg.r) << 16 | uint(bg.g) << 8 | uint(bg.b)
	attrs.event_mask = WINDOW_MASK
	a.win = xlib.CreateWindow(c.dpy, c.root, x, y, u32(a.w), u32(a.h), 0, c.depth, .InputOutput, c.visual,
	                          {.CWBackPixel, .CWEventMask}, &attrs)
	if a.win == 0 { return false }
	hint := xlib.XClassHint{res_name = "spoil", res_class = "Spoil"}
	xlib.SetClassHint(c.dpy, a.win, &hint)
	xlib.StoreName(c.dpy, a.win, "Spoil") // legacy Latin-1 title; _NET_WM_NAME carries the real one
	tx.set_atom_list(c, a.win, "_NET_WM_WINDOW_TYPE", {tx.atom(c, "_NET_WM_WINDOW_TYPE_NORMAL")})
	tx.set_cardinals(c, a.win, "_NET_WM_PID", {uint(posix.getpid())})
	protocols := [1]xlib.Atom{tx.atom(c, "WM_DELETE_WINDOW")}
	xlib.SetWMProtocols(c.dpy, a.win, &protocols[0], 1)
	if sh := xlib.AllocSizeHints(); sh != nil {
		sh.flags = {.PMinSize, .PPosition, .PSize}
		sh.x, sh.y, sh.width, sh.height = x, y, a.w, a.h
		sh.min_width, sh.min_height = 460, 300
		xlib.SetWMNormalHints(c.dpy, a.win, sh)
		xlib.Free(sh)
	}
	if wmh := xlib.AllocWMHints(); wmh != nil {
		wmh.flags = {.InputHint}
		wmh.input = true
		xlib.SetWMHints(c.dpy, a.win, wmh)
		xlib.Free(wmh)
	}
	a.cursors[0] = xlib.CreateFontCursor(c.dpy, .XC_left_ptr)
	a.cursors[1] = xlib.CreateFontCursor(c.dpy, .XC_xterm)
	a.cursors[2] = xlib.CreateFontCursor(c.dpy, .XC_watch)
	a.cursors[3] = xlib.CreateFontCursor(c.dpy, .XC_sb_h_double_arrow)
	xlib.DefineCursor(c.dpy, a.win, a.cursors[0])
	a.input = tx.input_open(c, a.win)
	a.base_dirty = true
	a.dirty = true
	render(a) // first frame before mapping: no blank flash
	tx.map_window(c, a.win)
	tx.flush(c)
	return true
}

set_title :: proc(a: ^App) {
	if a.win == 0 || len(a.panes) == 0 { return }
	name := tab_label(a, cur_tab(a))
	tx.set_utf8_string(a.c, a.win, "_NET_WM_NAME", fmt.tprintf("Spoil · %s", name))
	tx.set_utf8_string(a.c, a.win, "_NET_WM_ICON_NAME", "Spoil")
}

// "Início" for $HOME, "/" for the root, else the folder name.
dir_label :: proc(a: ^App, dir: string) -> string {
	if dir == clean_path(home_dir()) { return tr(a, "Início", "Home") }
	return base_name(dir)
}

set_notice :: proc(a: ^App, text: string, warn := false) {
	delete(a.notice)
	a.notice = strings.clone(text)
	a.notice_until = tx.now() + (warn ? 5 : 3)
	a.notice_warn = warn
	a.dirty = true
	if warn { log.warn(text) } else { log.info(text) }
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------
run :: proc(a: ^App) {
	c := a.c
	for a.running && !g_quit {
		for tx.pending(c) > 0 && a.running {
			ev: xlib.XEvent
			tx.next_event(c, &ev)
			if tx.input_filter(&ev) { continue } // a dead key waiting for its letter
			handle_event(a, &ev)
		}
		if !a.running { break }
		now := tx.now()
		tick(a, now)
		if a.dirty || a.base_dirty { render(a) }
		free_all(context.temp_allocator)
		if tx.pending(c) > 0 { continue }

		timeout := next_timeout(a, tx.now())
		fds: [3]posix.pollfd
		fds[0] = {fd = posix.FD(c.fd), events = {.IN}}
		n := 1
		for fd in ([]posix.FD{a.thumbs.wake_r, a.search.wake_r}) {
			if fd < 0 { continue }
			fds[n] = {fd = fd, events = {.IN}}
			n += 1
		}
		ms: i32 = timeout < 0 ? -1 : i32(timeout * 1000) + 1
		posix.poll(&fds[0], posix.nfds_t(n), ms)
	}
}

tick :: proc(a: ^App, now: f64) {
	if thumbs_collect(a) { a.dirty = true }
	if search_tick(a) { a.dirty = true }
	jobs_tick(a)
	embeds_tick(a)
	reap_children(a)
	if now >= a.next_check {
		a.next_check = now + 1
		if check_config(a) { a.dirty = true }
		check_directories(a)
		search_keepalive(a)
	}
	if a.notice != "" && now >= a.notice_until {
		delete(a.notice)
		a.notice = ""
		a.dirty = true
	}
	// Smooth scrolling towards the target, in every visible tab.
	for p in a.panes {
		t := p.tabs[p.active]
		if t.scroll == t.scroll_to { continue }
		d := t.scroll_to - t.scroll
		if abs(d) < 0.75 || a.style.anim_scale <= 0 {
			t.scroll = t.scroll_to
		} else {
			t.scroll += d * 0.35
		}
		a.dirty = true
	}
	drag_tick(a, now)
	if len(a.jobs) > 0 && now - a.spin_at >= 1.0 / 15 {
		a.spin_at = now
		a.dirty = true // the progress spinner
	}
}

next_timeout :: proc(a: ^App, now: f64) -> f64 {
	if a.dirty || a.base_dirty { return 0 }
	t := max(a.next_check - now, 0)
	for p in a.panes {
		tb := p.tabs[p.active]
		if tb.scroll != tb.scroll_to { t = min(t, 1.0 / 60) }
	}
	if a.notice != "" { t = min(t, max(a.notice_until - now, 0)) }
	if len(a.jobs) > 0 { t = min(t, 1.0 / 15) }
	if len(a.children) > 0 { t = min(t, 0.25) }
	if drag_autoscrolling(a) { t = min(t, 1.0 / 60) }
	if busy, _ := search_indexing(a); busy { t = min(t, 0.5) } // the item counter
	return t
}

handle_event :: proc(a: ^App, ev: ^xlib.XEvent) {
	win := ev.xany.window
	if a.menu.win != 0 && win == a.menu.win {
		menu_event(a, ev)
		return
	}
	if a.card.win != 0 && win == a.card.win {
		card_event(a, ev)
		return
	}
	if embed_event(a, ev) { return }
	#partial switch ev.type {
	case .MappingNotify:
		xlib.RefreshKeyboardMapping(&ev.xmapping)
	case .MapNotify:
		if win == a.win && tx.wm_name(a.c) == "" {
			// No window manager (test displays): take the keyboard ourselves.
			xlib.SetInputFocus(a.c.dpy, a.win, .RevertToParent, xlib.CurrentTime)
		}
	case .FocusIn:
		if win == a.win {
			a.has_focus = true
			tx.input_focus(&a.input, true)
			a.dirty = true
		}
	case .FocusOut:
		if win == a.win && ev.xfocus.mode != .NotifyGrab {
			a.has_focus = false
			tx.input_focus(&a.input, false)
			a.dirty = true
		}
	case .ConfigureNotify:
		if win == a.win { resized(a, ev.xconfigure.width, ev.xconfigure.height) }
	case .ClientMessage:
		if win == a.win && xlib.Atom(ev.xclient.data.l[0]) == tx.atom(a.c, "WM_DELETE_WINDOW") { a.running = false }
	case .ButtonPress:
		if win == a.win { on_button_press(a, &ev.xbutton) }
	case .ButtonRelease:
		if win == a.win { on_button_release(a, &ev.xbutton) }
	case .MotionNotify:
		if win == a.win { on_motion(a, ev.xmotion.x, ev.xmotion.y, ev.xmotion.state) }
	case .LeaveNotify:
		if win == a.win && a.drag.kind == .None && a.hover.action != .None {
			a.hover = {}
			a.dirty = true
		}
	case .KeyPress:
		on_key(a, &ev.xkey)
	case .SelectionRequest:
		clip_request(a, &ev.xselectionrequest)
	case .SelectionClear:
		clip_cleared(a, &ev.xselectionclear)
	}
}

@(private)
resized :: proc(a: ^App, w, h: i32) {
	if w == a.w && h == a.h { return }
	a.w, a.h = w, h
	a.dirty = true // holders follow in embeds_sync
	a.base_dirty = true
	a.dirty = true
	for p in a.panes {
		t := p.tabs[p.active]
		clamp_scroll(a, t)
		t.scroll = t.scroll_to
	}
}
