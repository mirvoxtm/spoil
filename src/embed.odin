// Programs embedded in Spoil's window.
//
// Viewer: opening a picture, a video or an audio file shows it inside the
// pane — mpv draws into a child window of Spoil (--wid) under a small header
// (name, previous/next, open externally, close). Without mpv the file opens in
// the default application instead.
//
// Terminal: "Abrir terminal aqui" (or F4) opens the terminal from milk.json
// (wm.terminal) in a column on the right of the window when it is Alacritty,
// embedded with --embed; any other terminal opens in its own window.
//
// Keyboard focus follows the pointer inside Spoil: over an embedded program it
// goes to that program (typing in the terminal, mpv's keys), back to Spoil
// when the pointer leaves it.
package spoil

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import tx "milk:tx"
import desktop "milk:desktop"

Embed_Kind :: enum { None, Viewer, Terminal }

Embed :: struct {
	kind:   Embed_Kind,
	holder: xlib.Window, // our child window the program draws into
	client: xlib.Window, // the program's own window inside the holder
	pid:    posix.pid_t,
	rect:   tx.Rect,     // holder geometry last applied (window coordinates)
	path:   string,      // viewer: the file shown; terminal: its folder (owned)
}

EMBED_HEADER :: 44 // viewer header / terminal title strip
EMBED_MASK :: xlib.EventMask{.EnterWindow, .LeaveWindow, .SubstructureNotify, .StructureNotify}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------
@(private)
g_mpv: int = -1 // -1 unknown, 0 missing, 1 present

has_mpv :: proc() -> bool {
	if g_mpv < 0 {
		_, found := desktop.find_executable("mpv")
		g_mpv = found ? 1 : 0
	}
	return g_mpv == 1
}

// Files the viewer shows (mpv plays or displays them).
viewable :: proc(e: ^Entry) -> bool {
	#partial switch e.kind {
	case .Image, .Video, .Audio: return !e.unreadable
	}
	return false
}

// ---------------------------------------------------------------------------
// Common
// ---------------------------------------------------------------------------
@(private)
embed_holder :: proc(a: ^App, r: tx.Rect) -> xlib.Window {
	c := a.c
	attrs: xlib.XSetWindowAttributes
	attrs.background_pixel = pixel_of(a.style.theme.bg)
	attrs.event_mask = EMBED_MASK
	w := xlib.CreateWindow(c.dpy, a.win, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)), 0, c.depth, .InputOutput,
	                       c.visual, {.CWBackPixel, .CWEventMask}, &attrs)
	xlib.MapWindow(c.dpy, w)
	return w
}

@(private)
pixel_of :: proc(col: tx.Color) -> uint {
	return uint(col.r) << 16 | uint(col.g) << 8 | uint(col.b)
}

@(private)
hex_of :: proc(col: tx.Color) -> string {
	return fmt.tprintf("#%02X%02X%02X", col.r, col.g, col.b)
}

// Stop the program and remove its window.
embed_close :: proc(a: ^App, e: ^Embed) {
	if e.kind == .None { return }
	if e.pid > 0 {
		posix.kill(e.pid, .SIGTERM)
		append(&a.children, e.pid) // reaped with the other children
	}
	if e.holder != 0 { xlib.DestroyWindow(a.c.dpy, e.holder) }
	delete(e.path)
	e^ = {}
	xlib.SetInputFocus(a.c.dpy, a.win, .RevertToParent, xlib.CurrentTime)
	a.base_dirty = true
	a.dirty = true
}

// Place the holder (and the program's window) at `r`.
@(private)
embed_place :: proc(a: ^App, e: ^Embed, r: tx.Rect) {
	if e.holder == 0 || r == e.rect { return }
	e.rect = r
	xlib.MoveResizeWindow(a.c.dpy, e.holder, r.x, r.y, u32(max(r.w, 1)), u32(max(r.h, 1)))
	if e.client != 0 { xlib.MoveResizeWindow(a.c.dpy, e.client, 0, 0, u32(max(r.w, 1)), u32(max(r.h, 1))) }
	tx.shape_rounded(a.c, e.holder, r.w, r.h, f32(max(a.style.radius - 4, 4)))
}

// Every embed, for event routing.
@(private)
embeds :: proc(a: ^App, allocator := context.temp_allocator) -> []^Embed {
	list := make([dynamic]^Embed, allocator)
	if a.term.kind != .None { append(&list, &a.term) }
	for p in a.panes { if p.viewer.kind != .None { append(&list, &p.viewer) } }
	return list[:]
}

// X events for the holders: the program's window appearing or going away,
// and focus following the pointer. True when the event was ours.
embed_event :: proc(a: ^App, ev: ^xlib.XEvent) -> bool {
	win := ev.xany.window
	for e in embeds(a) {
		if win != e.holder { continue }
		#partial switch ev.type {
		case .MapNotify:
			if ev.xmap.window != e.holder && e.client == 0 {
				e.client = ev.xmap.window
				r := e.rect
				xlib.MoveResizeWindow(a.c.dpy, e.client, 0, 0, u32(max(r.w, 1)), u32(max(r.h, 1)))
				if pointer_inside(a, e.rect) { focus_embed(a, e) }
			}
		case .DestroyNotify:
			if ev.xdestroywindow.window == e.client && e.client != 0 {
				e.client = 0
				embed_close(a, e) // the program quit (mpv's q, the shell's exit)
			}
		case .EnterNotify:
			focus_embed(a, e)
		case .LeaveNotify:
			if ev.xcrossing.detail != .NotifyInferior {
				xlib.SetInputFocus(a.c.dpy, a.win, .RevertToParent, xlib.CurrentTime)
			}
		}
		return true
	}
	return false
}

@(private)
focus_embed :: proc(a: ^App, e: ^Embed) {
	target := e.client != 0 ? e.client : e.holder
	xlib.SetInputFocus(a.c.dpy, target, .RevertToParent, xlib.CurrentTime)
}

@(private)
pointer_inside :: proc(a: ^App, r: tx.Rect) -> bool {
	root, child: xlib.Window
	rx, ry, wx, wy: i32
	mask: xlib.KeyMask
	if !bool(xlib.QueryPointer(a.c.dpy, a.win, &root, &child, &rx, &ry, &wx, &wy, &mask)) { return false }
	return tx.rect_contains(r, wx, wy)
}

// A program that exited on its own (checked in tick).
embeds_tick :: proc(a: ^App) {
	for e in embeds(a) {
		if e.pid > 0 && posix.waitpid(e.pid, nil, {.NOHANG}) != 0 {
			e.pid = 0
			embed_close(a, e)
		}
	}
}

embeds_destroy :: proc(a: ^App) {
	embed_close(a, &a.term)
	for p in a.panes { embed_close(a, &p.viewer) }
}

// ---------------------------------------------------------------------------
// Viewer
// ---------------------------------------------------------------------------
// Show `path` in pane `pi` (replacing what the viewer shows); false = no mpv.
viewer_open :: proc(a: ^App, pi: int, path: string) -> bool {
	if !has_mpv() { return false }
	p := a.panes[pi]
	v := &p.viewer
	if v.kind == .Viewer && v.pid > 0 {
		posix.kill(v.pid, .SIGTERM)
		append(&a.children, v.pid)
		v.pid = 0
		if v.client != 0 { xlib.DestroyWindow(a.c.dpy, v.client) }
		v.client = 0
	}
	if v.holder == 0 {
		v.kind = .Viewer
		v.holder = embed_holder(a, viewer_rect(a, pi))
		v.rect = {}
	}
	delete(v.path)
	v.path = strings.clone(path)
	argv := []string{
		"mpv", fmt.tprintf("--wid=%d", u64(v.holder)), "--keep-open=yes", "--no-terminal",
		"--force-window=immediate", "--image-display-duration=inf", "--osc=yes", "--loop-file=inf",
		fmt.tprintf("--background-color=%s", hex_of(a.style.theme.bg)), "--", path,
	}
	pid, ok := desktop.spawn_detached(argv, cur_tab(a).dir)
	if !ok {
		log.warnf("Could not start mpv for %s", path)
		embed_close(a, v)
		return false
	}
	v.pid = pid
	embed_place(a, v, viewer_rect(a, pi))
	a.base_dirty = true
	a.dirty = true
	return true
}

// The next/previous viewable file of the pane's folder (`step` = ±1).
viewer_step :: proc(a: ^App, pi: int, step: int) {
	p := a.panes[pi]
	if p.viewer.kind != .Viewer { return }
	t := p.tabs[p.active]
	current := p.viewer.path
	list := make([dynamic]int, context.temp_allocator)
	at := -1
	for vi, i in t.view {
		e := &t.entries[vi]
		if !viewable(e) { continue }
		if entry_path(t, e) == current { at = len(list) }
		append(&list, i)
	}
	if len(list) == 0 { return }
	next := at < 0 ? 0 : (at + step + len(list)) % len(list)
	e := &t.entries[t.view[list[next]]]
	t.cursor = list[next]
	viewer_open(a, pi, entry_path(t, e))
}

viewer_close :: proc(a: ^App, pi: int) {
	embed_close(a, &a.panes[pi].viewer)
}

// The viewer occupies the pane's card below its header strip.
viewer_rect :: proc(a: ^App, pi: int) -> tx.Rect {
	L := pane_layout(a, pi)
	top := L.card.y + EMBED_HEADER
	return {L.card.x + 8, top, max(L.card.w - 16, 1), max(L.status.y - top - 4, 1)}
}

// Header drawn above the viewer: name, previous/next, open externally, close.
draw_viewer_header :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	v := &a.panes[pi].viewer
	r := tx.Rect{L.card.x + 8, L.card.y + 6, L.card.w - 16, EMBED_HEADER - 12}
	b: i32 = r.h
	close_r := tx.Rect{r.x + r.w - b, r.y, b, b}
	ext_r := tx.Rect{close_r.x - b - 4, r.y, b, b}
	next_r := tx.Rect{ext_r.x - b - 10, r.y, b, b}
	prev_r := tx.Rect{next_r.x - b - 4, r.y, b, b}
	icon_button(a, cv, prev_r, .Arrow_Left, .Viewer_Prev, pi, true)
	icon_button(a, cv, next_r, .Arrow_Right, .Viewer_Next, pi, true)
	icon_button(a, cv, ext_r, .External, .Viewer_External, pi, true)
	icon_button(a, cv, close_r, .X, .Viewer_Close, pi, true)
	name := v.path
	if i := strings.last_index_byte(name, '/'); i >= 0 { name = name[i + 1:] }
	glyph(a, a.style.icon_small, {r.x + 4, r.y, 24, r.h}, .Photo, th.accent)
	label := tx.text_ellipsize(a.c, a.style.font_bold, name, prev_r.x - r.x - 44)
	text_box(a, a.style.font_bold, r.x + 32, r.y, r.h, label, th.fg)
}

// ---------------------------------------------------------------------------
// Terminal (right column)
// ---------------------------------------------------------------------------
term_width :: proc(a: ^App) -> i32 {
	if a.term.kind == .None { return 0 }
	return clamp(a.w * 38 / 100, 360, max(a.w - SIDEBAR_W - 420, 360))
}

// The terminal card on the right of the panes.
term_card :: proc(a: ^App) -> tx.Rect {
	w := term_width(a)
	return {a.w - MARGIN - w, MARGIN, w, a.h - 2 * MARGIN}
}

term_rect :: proc(a: ^App) -> tx.Rect {
	card := term_card(a)
	return {card.x + 8, card.y + EMBED_HEADER, card.w - 16, card.h - EMBED_HEADER - 8}
}

// Open (or move to `dir`) the embedded terminal; false = not Alacritty (the
// caller opens the terminal in its own window).
term_open :: proc(a: ^App, dir: string) -> bool {
	cmd := strings.trim_space(terminal_command(a))
	if !strings.contains(cmd, "alacritty") { return false }
	if a.term.kind == .Terminal { embed_close(a, &a.term) }
	a.term.kind = .Terminal
	a.term.path = strings.clone(dir)
	a.term.holder = embed_holder(a, term_rect(a))
	quoted, _ := strings.replace_all(dir, "'", `'\''`, context.temp_allocator)
	line := fmt.tprintf("%s --embed %d --working-directory '%s'", cmd, u64(a.term.holder), quoted)
	pid, ok := desktop.spawn_detached({"sh", "-c", line}, dir)
	if !ok {
		embed_close(a, &a.term)
		return false
	}
	a.term.pid = pid
	a.base_dirty = true // the panes shrink: rebuild the cards
	a.dirty = true
	return true
}

term_toggle :: proc(a: ^App) {
	if a.term.kind != .None {
		embed_close(a, &a.term)
		return
	}
	dir := cur_tab(a).dir
	if !term_open(a, dir) { open_terminal(a, dir) }
}

draw_term_card :: proc(a: ^App, cv: ^tx.Canvas) {
	if a.term.kind == .None { return }
	th := &a.style.theme
	card := term_card(a)
	rad := f32(a.style.radius)
	soft_shadow(cv, card, rad, 10, th.dark ? 0.35 : 0.10, 2)
	fill_rounded(cv, card, rad, th.bg)
	stroke_rounded(cv, card, rad, 1, tx.color_with_alpha(th.muted, th.dark ? 45 : 60))
	r := tx.Rect{card.x + 8, card.y + 6, card.w - 16, EMBED_HEADER - 12}
	close_r := tx.Rect{r.x + r.w - r.h, r.y, r.h, r.h}
	icon_button(a, cv, close_r, .X, .Term_Close, 0, true)
	glyph(a, a.style.icon_small, {r.x + 4, r.y, 24, r.h}, .Terminal, th.accent)
	label := tx.text_ellipsize(a.c, a.style.font_bold, dir_label(a, a.term.path), close_r.x - r.x - 44)
	text_box(a, a.style.font_bold, r.x + 32, r.y, r.h, label, th.fg)
}

// Keep every holder where the layout wants it (called after each render).
embeds_sync :: proc(a: ^App) {
	if a.term.kind != .None { embed_place(a, &a.term, term_rect(a)) }
	for p, pi in a.panes {
		if p.viewer.kind != .None { embed_place(a, &p.viewer, viewer_rect(a, pi)) }
	}
}
