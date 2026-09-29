// The right-click context card, in the look of the milk bar's popups: an
// override-redirect window cut round by the SHAPE extension, painted opaque
// with the theme background and a faint outline, rows with Tabler glyphs and
// hover pills. It grabs the pointer and the keyboard; a click elsewhere or
// Escape closes it.
package spoil

import "core:fmt"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

MENU_RADIUS :: 16
MENU_PAD    :: 6
MENU_ROW_H  :: 34
MENU_DIV_H  :: 9

Command :: enum {
	None, Open, Rename, Copy, Cut, Paste, Trash, Copy_Path, Terminal, Wallpaper, New_Folder, Select_All, Hidden,
	Compress, Extract_Here, Extract_Folder, New_Tab, New_Pane, Close_Tab, Close_Other_Tabs, Tab_To_Pane,
	Open_Folder, Search, Reindex,
}

Menu_Item :: struct {
	label:   string, // owned
	hint:    string, // literal
	icon:    Ic,
	cmd:     Command,
	danger:  bool,
	divider: bool,   // a divider above this row
	enabled: bool,
}

Menu :: struct {
	win:       xlib.Window,
	pixmap:    xlib.Pixmap,
	open:      bool,
	rect:      tx.Rect, // screen coordinates
	items:     [dynamic]Menu_Item,
	hover:     int,
	grab_ptr:  bool,
	grab_kb:   bool,
	shape_w:   i32,
	shape_h:   i32,
	opened_at: f64,
	on_item:   bool,
	area:      int,     // 1-based area for the wallpaper row
	tab_pane:  int,     // the tab a tab menu is about
	tab_index: int,
	pending_divider: bool,
}

@(private)
menu_add :: proc(m: ^Menu, cmd: Command, label: string, icon: Ic, hint := "", enabled := true, danger := false) {
	divider := m.pending_divider && len(m.items) > 0
	m.pending_divider = false
	append(&m.items, Menu_Item{label = strings.clone(label), hint = hint, icon = icon, cmd = cmd, enabled = enabled,
	                           danger = danger, divider = divider})
}

menu_open :: proc(a: ^App, x_root, y_root: i32, on_item: bool) {
	menu_close(a)
	m := &a.menu
	m.on_item = on_item
	m.hover = -1
	m.area = current_area(a)
	t := cur_tab(a)
	search := is_search(t)
	can_paste := len(a.clip.paths) > 0 && !search
	can_split := len(a.panes) < MAX_PANES
	sel := selected_entries(t)
	if on_item && len(sel) > 0 {
		single := len(sel) == 1
		e := &t.entries[sel[0]]
		all_archives := true
		same_dir := true // search results can come from many folders
		for idx in sel {
			if t.entries[idx].is_dir || archive_suffix(t.entries[idx].name) == "" { all_archives = false }
			if entry_dir(t, &t.entries[idx]) != entry_dir(t, e) { same_dir = false }
		}
		menu_add(m, .Open, tr(a, "Abrir", "Open"), e.is_dir && single ? .Folder_Open : .External, "Enter")
		if search {
			menu_add(m, .Open_Folder, tr(a, "Abrir pasta que contém", "Open containing folder"), .Folder_Search, "Ctrl+Enter")
		}
		if single && e.is_dir {
			menu_add(m, .New_Tab, tr(a, "Abrir em nova aba", "Open in new tab"), .App_Window, tr(a, "Botão do meio", "Middle click"))
			menu_add(m, .New_Pane, tr(a, "Abrir em novo painel", "Open in new pane"), .Columns, "", can_split)
			menu_add(m, .Terminal, tr(a, "Abrir terminal aqui", "Open terminal here"), .Terminal)
		}
		m.pending_divider = true
		menu_add(m, .Cut, tr(a, "Recortar", "Cut"), .Cut, "Ctrl+X")
		menu_add(m, .Copy, tr(a, "Copiar", "Copy"), .Copy, "Ctrl+C")
		if !search { menu_add(m, .Paste, tr(a, "Colar", "Paste"), .Clipboard, "Ctrl+V", can_paste) }
		menu_add(m, .Rename, tr(a, "Renomear", "Rename"), .Pencil, "F2", single)
		menu_add(m, .Copy_Path, tr(a, "Copiar caminho", "Copy path"), .Clipboard_Copy)
		m.pending_divider = true
		menu_add(m, .Compress, tr(a, "Comprimir…", "Compress…"), .Archive, "", same_dir && (format_available(.Zip) || format_available(.Seven_Z)))
		if all_archives {
			menu_add(m, .Extract_Here, tr(a, "Extrair aqui", "Extract here"), .Unarchive)
			menu_add(m, .Extract_Folder, tr(a, "Extrair para pasta", "Extract to folder"), .Folder_Down)
		}
		if single && e.kind == .Image && wallpaper_capable(e.name) && !e.unreadable {
			m.pending_divider = true
			menu_add(m, .Wallpaper, fmt.tprintf(tr(a, "Definir como papel de parede da área %d", "Set as wallpaper of area %d"), m.area), .Wallpaper)
		}
		m.pending_divider = true
		menu_add(m, .Trash, tr(a, "Mover para a lixeira", "Move to trash"), .Trash, "Delete", g_tools.gio, true)
	} else if search {
		indexing, _ := search_indexing(a)
		menu_add(m, .Reindex, tr(a, "Reindexar o disco", "Reindex the disk"), .Refresh, "", !indexing)
		menu_add(m, .Select_All, tr(a, "Selecionar tudo", "Select all"), .Check, "Ctrl+A", len(t.view) > 0)
		menu_add(m, .Hidden, t.show_hidden ? tr(a, "Esconder arquivos ocultos", "Hide hidden files") : tr(a, "Mostrar arquivos ocultos", "Show hidden files"),
		         t.show_hidden ? .Eye_Off : .Eye, "Ctrl+H")
		m.pending_divider = true
		menu_add(m, .New_Tab, tr(a, "Nova aba", "New tab"), .App_Window, "Ctrl+T")
	} else {
		menu_add(m, .New_Folder, tr(a, "Nova pasta", "New folder"), .Folder_Plus, "Ctrl+Shift+N")
		menu_add(m, .Paste, tr(a, "Colar", "Paste"), .Clipboard, "Ctrl+V", can_paste)
		m.pending_divider = true
		menu_add(m, .New_Tab, tr(a, "Nova aba", "New tab"), .App_Window, "Ctrl+T")
		menu_add(m, .New_Pane, tr(a, "Dividir painel", "Split pane"), .Columns, "Ctrl+\\", can_split)
		menu_add(m, .Terminal, tr(a, "Abrir terminal aqui", "Open terminal here"), .Terminal)
		menu_add(m, .Copy_Path, tr(a, "Copiar caminho", "Copy path"), .Clipboard_Copy)
		menu_add(m, .Search, tr(a, "Buscar em todo o disco", "Search the whole disk"), .Folder_Search, "Ctrl+Shift+F")
		m.pending_divider = true
		menu_add(m, .Select_All, tr(a, "Selecionar tudo", "Select all"), .Check, "Ctrl+A", len(t.view) > 0)
		menu_add(m, .Hidden, t.show_hidden ? tr(a, "Esconder arquivos ocultos", "Hide hidden files") : tr(a, "Mostrar arquivos ocultos", "Show hidden files"),
		         t.show_hidden ? .Eye_Off : .Eye, "Ctrl+H")
	}
	menu_show(a, x_root, y_root)
}

// The menu of a tab (right click on it).
menu_open_tab :: proc(a: ^App, x_root, y_root: i32, pi, ti: int) {
	menu_close(a)
	m := &a.menu
	m.hover = -1
	m.tab_pane, m.tab_index = pi, ti
	p := a.panes[pi]
	menu_add(m, .New_Tab, tr(a, "Nova aba", "New tab"), .Plus, "Ctrl+T")
	menu_add(m, .Tab_To_Pane, tr(a, "Mover para novo painel", "Move to new pane"), .Columns, "", len(p.tabs) > 1 && len(a.panes) < MAX_PANES)
	m.pending_divider = true
	menu_add(m, .Close_Other_Tabs, tr(a, "Fechar outras abas", "Close other tabs"), .X, "", len(p.tabs) > 1)
	menu_add(m, .Close_Tab, tr(a, "Fechar aba", "Close tab"), .X, "Ctrl+W")
	menu_show(a, x_root, y_root)
}

@(private)
menu_show :: proc(a: ^App, x_root, y_root: i32) {
	m := &a.menu
	// Size: the widest label and hint.
	w: i32 = 0
	for it in m.items {
		lw := tw(a, a.style.font, it.label)
		if it.hint != "" { lw += tw(a, a.style.font_tiny, it.hint) + 28 }
		w = max(w, lw)
	}
	w = clamp(w + 2 * MENU_PAD + 40 + 16, 220, 460)
	h: i32 = 2 * MENU_PAD
	for it in m.items {
		h += MENU_ROW_H
		if it.divider { h += MENU_DIV_H }
	}
	// Place it at the pointer, kept inside the monitor under it.
	mon := monitor_at(a, x_root, y_root)
	x := x_root + 2
	y := y_root + 2
	if x + w > mon.x + mon.w - 6 { x = max(mon.x + 6, x_root - w - 2) }
	if y + h > mon.y + mon.h - 6 { y = max(mon.y + 6, y_root - h - 2) }
	m.rect = {x, y, w, h}

	c := a.c
	if m.win == 0 {
		m.win = tx.create_overlay(c, m.rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress},
		                          "_NET_WM_WINDOW_TYPE_POPUP_MENU", "Spoil menu")
		hint := xlib.XClassHint{res_name = "spoil", res_class = "Spoil"}
		xlib.SetClassHint(c.dpy, m.win, &hint)
	} else {
		tx.move_resize(c, m.win, m.rect)
	}
	if m.shape_w != w || m.shape_h != h {
		tx.shape_rounded(c, m.win, w, h, MENU_RADIUS)
		m.shape_w, m.shape_h = w, h
	}
	menu_draw(a)
	tx.map_window(c, m.win)
	tx.raise_window(c, m.win)
	ps := xlib.GrabPointer(c.dpy, m.win, false, {.ButtonPress, .ButtonRelease, .PointerMotion},
	                       .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	ks := xlib.GrabKeyboard(c.dpy, m.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	m.grab_ptr, m.grab_kb = ps == 0, ks == 0
	m.open = true
	m.opened_at = tx.now()
	// Hover follows the pointer from the start.
	m.hover = menu_row_at(a, x_root - x, y_root - y)
	if m.hover >= 0 { menu_draw(a) }
	tx.flush(c)
	a.hover = {}
	a.dirty = true
}

menu_close :: proc(a: ^App) {
	m := &a.menu
	if m.open {
		if m.grab_ptr { xlib.UngrabPointer(a.c.dpy, xlib.CurrentTime) }
		if m.grab_kb { xlib.UngrabKeyboard(a.c.dpy, xlib.CurrentTime) }
		m.grab_ptr, m.grab_kb = false, false
		if m.win != 0 { tx.unmap_window(a.c, m.win) }
		m.open = false
		tx.flush(a.c)
		a.dirty = true
	}
	for it in m.items { delete(it.label) }
	clear(&m.items)
	m.pending_divider = false
}

menu_destroy :: proc(a: ^App) {
	menu_close(a)
	m := &a.menu
	if m.win != 0 { tx.destroy_window(a.c, m.win) }
	tx.pixmap_free(a.c, m.pixmap)
	delete(m.items)
	m^ = {}
}

menu_tick :: proc(a: ^App) {}

// Row under a point in menu coordinates (-1 = none or disabled).
@(private)
menu_row_at :: proc(a: ^App, x, y: i32) -> int {
	m := &a.menu
	if x < 0 || x >= m.rect.w { return -1 }
	yy := i32(MENU_PAD)
	for it, i in m.items {
		if it.divider { yy += MENU_DIV_H }
		if y >= yy && y < yy + MENU_ROW_H { return it.enabled ? i : -1 }
		yy += MENU_ROW_H
	}
	return -1
}

@(private)
menu_draw :: proc(a: ^App) {
	m := &a.menu
	th := &a.style.theme
	c := a.c
	cv := tx.canvas_make(m.rect.w, m.rect.h, context.temp_allocator)
	tx.canvas_fill(&cv, th.bg)
	stroke_rounded(&cv, {0, 0, cv.w, cv.h}, MENU_RADIUS, 1, tx.color_with_alpha(th.muted, 90))
	saved := a.texts
	a.texts = make([dynamic]Text_Item, context.temp_allocator)
	y := i32(MENU_PAD)
	for it, i in m.items {
		if it.divider {
			tx.canvas_fill_rect(&cv, {MENU_PAD + 10, y + MENU_DIV_H / 2, cv.w - 2 * MENU_PAD - 20, 1}, tx.color_with_alpha(th.muted, 60))
			y += MENU_DIV_H
		}
		row := tx.Rect{MENU_PAD, y, cv.w - 2 * MENU_PAD, MENU_ROW_H}
		if i == m.hover && it.enabled {
			fill_rounded(&cv, row, 10, it.danger ? mix(th.bg, th.warning, 0.16) : th.hover)
		}
		fg := th.fg
		icon_color := th.sub
		if it.danger { fg, icon_color = th.warning, th.warning }
		if !it.enabled { fg, icon_color = mix(th.fg, th.bg, 0.6), mix(th.muted, th.bg, 0.4) }
		glyph(a, a.style.icon_small, {row.x + 8, row.y, 22, row.h}, it.icon, icon_color)
		text_box(a, a.style.font, row.x + 40, row.y, row.h, it.label, fg)
		if it.hint != "" {
			hw := tw(a, a.style.font_tiny, it.hint)
			text_box(a, a.style.font_tiny, row.x + row.w - 10 - hw, row.y, row.h, it.hint, mix(th.muted, th.bg, it.enabled ? 0 : 0.4))
		}
		y += MENU_ROW_H
	}
	pm := tx.canvas_to_pixmap(c, cv)
	ts := tx.text_surface_make(c, xlib.Drawable(pm))
	for t in a.texts { tx.draw_text(&ts, t.font, t.x, t.baseline, t.s, t.color) }
	tx.text_surface_destroy(&ts)
	a.texts = saved
	tx.set_background(c, m.win, pm)
	tx.pixmap_free(c, m.pixmap)
	m.pixmap = pm
	tx.flush(c)
}

menu_event :: proc(a: ^App, ev: ^xlib.XEvent) {
	m := &a.menu
	if !m.open { return }
	#partial switch ev.type {
	case .MotionNotify:
		row := menu_row_at(a, ev.xmotion.x, ev.xmotion.y)
		if row != m.hover {
			m.hover = row
			menu_draw(a)
		}
	case .LeaveNotify:
		if m.hover >= 0 {
			m.hover = -1
			menu_draw(a)
		}
	case .ButtonPress:
		x, y := ev.xbutton.x, ev.xbutton.y
		if x < 0 || y < 0 || x >= m.rect.w || y >= m.rect.h {
			menu_close(a)
			return
		}
		if b := ev.xbutton.button; b == .Button4 || b == .Button5 { return }
		row := menu_row_at(a, x, y)
		if row >= 0 { menu_activate(a, row) }
	case .ButtonRelease:
		// Press-drag-release from the opening right click.
		if tx.now() - m.opened_at < 0.3 { return }
		row := menu_row_at(a, ev.xbutton.x, ev.xbutton.y)
		if row >= 0 { menu_activate(a, row) }
	case .KeyPress:
		raw, keysym := tx.input_lookup(nil, &ev.xkey)
		_ = raw
		switch uint(keysym) {
		case KS_ESCAPE, KS_MENU:
			menu_close(a)
		case KS_UP, KS_LEFT_TAB:
			menu_step(a, -1)
		case KS_DOWN, KS_TAB:
			menu_step(a, 1)
		case KS_HOME:
			m.hover = -1
			menu_step(a, 1)
		case KS_END:
			m.hover = len(m.items)
			menu_step(a, -1)
		case KS_RETURN, KS_KP_ENTER:
			if m.hover >= 0 { menu_activate(a, m.hover) }
		}
	}
}

@(private)
menu_step :: proc(a: ^App, dir: int) {
	m := &a.menu
	n := len(m.items)
	if n == 0 { return }
	i := m.hover
	for _ in 0 ..< n {
		i += dir
		if i < 0 { i = n - 1 }
		if i >= n { i = 0 }
		if m.items[i].enabled { break }
	}
	m.hover = i
	menu_draw(a)
}

@(private)
menu_activate :: proc(a: ^App, row: int) {
	m := &a.menu
	if row < 0 || row >= len(m.items) || !m.items[row].enabled { return }
	cmd := m.items[row].cmd
	on_item := m.on_item
	area := m.area
	menu_close(a)
	run_command(a, cmd, on_item, area)
}

// The RandR monitor containing a point (the whole screen without RandR).
monitor_at :: proc(a: ^App, x, y: i32) -> tx.Rect {
	for mon in tx.monitors(a.c) {
		if tx.rect_contains(mon.rect, x, y) { return mon.rect }
	}
	return tx.screen_rect(a.c)
}

// The current milk area: _NET_CURRENT_DESKTOP + 1 (1 without a window manager).
current_area :: proc(a: ^App) -> int {
	if v, ok := tx.get_cardinal(a.c, a.c.root, "_NET_CURRENT_DESKTOP"); ok { return int(v) + 1 }
	return 1
}
