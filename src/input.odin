// Mouse and keyboard.
package spoil

import "core:fmt"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

KS_RETURN     :: 0xff0d
KS_KP_ENTER   :: 0xff8d
KS_ESCAPE     :: 0xff1b
KS_BACKSPACE  :: 0xff08
KS_TAB        :: 0xff09
KS_LEFT_TAB   :: 0xfe20
KS_DELETE     :: 0xffff
KS_KP_DELETE  :: 0xff9f
KS_HOME       :: 0xff50
KS_LEFT       :: 0xff51
KS_UP         :: 0xff52
KS_RIGHT      :: 0xff53
KS_DOWN       :: 0xff54
KS_PAGE_UP    :: 0xff55
KS_PAGE_DOWN  :: 0xff56
KS_END        :: 0xff57
KS_MENU       :: 0xff67
KS_F2         :: 0xffbf
KS_F3         :: 0xffc0
KS_F4         :: 0xffc1
KS_F5         :: 0xffc2
KS_F10        :: 0xffc7
KS_BACKSLASH  :: 0x5c
KS_XF86_BACK  :: 0x1008FF26
KS_XF86_FWD   :: 0x1008FF27

DOUBLE_CLICK_MS :: 400

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------
on_motion :: proc(a: ^App, x, y: i32, state: xlib.InputMask) {
	a.pointer = {x, y}
	if a.drag.kind != .None {
		drag_motion(a, x, y, state)
		return
	}
	h := hit_at(a, x, y)
	if h.action != a.hover.action || h.pane != a.hover.pane || h.arg != a.hover.arg {
		a.hover = h
		a.dirty = true
	}
}

on_button_press :: proc(a: ^App, ev: ^xlib.XButtonEvent) {
	x, y := ev.x, ev.y
	a.pointer = {x, y}
	button := i32(ev.button)
	ctrl := .ControlMask in ev.state
	shift := .ShiftMask in ev.state
	h := hit_at(a, x, y)
	pi := h.pane
	switch button {
	case 4, 5:
		dir: i32 = button == 4 ? -1 : 1
		if tx.rect_contains(sidebar_rect(a), x, y) {
			a.side_scroll = clamp(a.side_scroll + dir * 60, 0, a.side_max)
		} else if p := pane_at(a, x); p >= 0 {
			t := pane_tab(a, p)
			L := pane_layout(a, p)
			if y < L.tabs.y + L.tabs.h {
				cycle_tab_in(a, p, int(dir)) // the wheel over a tab strip switches tabs
			} else {
				step: f32 = t.mode == .Grid ? f32(L.cell_h) * 0.75 : f32(L.row_h) * 3
				t.scroll_to = clamp(t.scroll_to + f32(dir) * step, 0, max_scroll(&L))
			}
		}
		a.dirty = true
		return
	case 8, 9:
		if p := pane_at(a, x); p >= 0 {
			set_active_pane(a, p)
			if button == 8 { go_back(a, cur_tab(a)) } else { go_forward(a, cur_tab(a)) }
		}
		return
	case 2:
		middle_click(a, h)
		return
	case 3:
		if a.focus == .Rename && h.action != .Rename_Field { rename_finish(a) }
		#partial switch h.action {
		case .Item:
			set_active_pane(a, pi)
			t := cur_tab(a)
			if !t.entries[t.view[h.arg]].selected { select_only(a, t, h.arg) }
			t.cursor = h.arg
			menu_open(a, ev.x_root, ev.y_root, true)
		case .Empty:
			set_active_pane(a, pi)
			clear_selection(a, cur_tab(a))
			menu_open(a, ev.x_root, ev.y_root, false)
		case .Tab:
			set_active_tab(a, pi, h.arg)
			menu_open_tab(a, ev.x_root, ev.y_root, pi, h.arg)
		}
		return
	case 1:
	case:
		return
	}

	// Left button: any click inside a pane makes it the active one.
	if h.action != .Place && h.action != .Divider && h.action != .None { set_active_pane(a, pi) }
	t := cur_tab(a)
	// A click outside the field ends renaming / path editing / searching.
	if a.focus == .Rename && h.action != .Rename_Field { rename_finish(a) }
	if a.focus == .Path && h.action != .Path_Field { a.focus = .View; a.dirty = true }
	if a.focus == .Search && h.action != .Search && h.action != .Clear_Search { a.focus = .View; a.dirty = true }

	double := false
	if h.action == .Item {
		double = h.arg == a.last_item && pi == a.last_pane && ev.time - a.last_click < DOUBLE_CLICK_MS
		a.last_item, a.last_pane = h.arg, pi
		a.last_click = ev.time
	} else {
		a.last_item = -1
	}

	switch h.action {
	case .None, .Pane, .Tab_Strip, .Card_Field, .Card_Format, .Card_Cancel, .Card_Ok:
	case .Search_Tab:  search_open(a)
	case .Sort_Column: search_sort_by(a, t, Search_Sort(h.arg))
	case .Reindex:     search_reindex(a)
	case .Viewer_Prev:     viewer_step(a, pi, -1)
	case .Viewer_Next:     viewer_step(a, pi, 1)
	case .Viewer_Close:    viewer_close(a, pi)
	case .Viewer_External:
		if v := &a.panes[pi].viewer; v.path != "" {
			path := strings.clone(v.path, context.temp_allocator)
			viewer_close(a, pi)
			launch(a, {"xdg-open", path}, cur_tab(a).dir)
		}
	case .Term_Close:      embed_close(a, &a.term)
	case .Back:      go_back(a, t)
	case .Forward:   go_forward(a, t)
	case .Up:        go_up(a, t)
	case .Crumb:
		list := a.crumbs[pi]
		if h.arg >= 0 && h.arg < len(list) {
			target := strings.clone(list[h.arg], context.temp_allocator)
			child := ""
			if strings.has_prefix(t.dir, target) && t.dir != target {
				rest := strings.trim_left(t.dir[len(target):], "/")
				if i := strings.index_byte(rest, '/'); i >= 0 { child = rest[:i] } else { child = rest }
			}
			navigate(a, t, target, true, child)
		}
	case .Crumb_Bar:
		start_path_edit(a)
	case .Search:
		a.focus = .Search
		field_click(a, &t.search, x, a.style.font)
	case .Clear_Search:
		field_clear(&t.search)
		filter_changed(a, t)
		a.focus = .Search
	case .Path_Field:
		field_click(a, &cur_pane(a).path_field, x, a.style.font)
	case .Rename_Field:
		field_click(a, &a.rename, x, a.style.font_small)
	case .View_Grid: set_mode(a, t, .Grid)
	case .View_List: set_mode(a, t, .List)
	case .Hidden:    toggle_hidden(a, t)
	case .Place:     open_place(a, h.arg)
	case .Tab:
		set_active_tab(a, pi, h.arg)
		drag_press(a, .Press_Tab, pi, h.arg, x, y)
	case .Tab_Close:
		close_tab(a, pi, h.arg)
	case .Tab_New:
		new_tab(a, pi, pane_tab(a, pi).dir)
	case .Divider:
		drag_press(a, .Divider, 0, h.arg, x, y)
		divider_start(a, h.arg, x)
	case .Item:
		a.focus = .View
		e := &t.entries[t.view[h.arg]]
		defer_select := false
		switch {
		case double:
			select_only(a, t, h.arg)
			open_selection(a)
			return
		case ctrl:
			e.selected = !e.selected
			t.cursor, t.anchor = h.arg, h.arg
		case shift:
			if t.anchor < 0 { t.anchor = max(t.cursor, 0) }
			select_range(a, t, t.anchor, h.arg, false)
			t.cursor = h.arg
		case e.selected:
			// Keep a multi-selection for dragging; a plain click selects only this on release.
			defer_select = true
			t.cursor = h.arg
		case:
			select_only(a, t, h.arg)
		}
		drag_press(a, .Press_Item, pi, h.arg, x, y)
		a.drag.defer_select = defer_select
	case .Empty:
		a.focus = .View
		if !ctrl && !shift { clear_selection(a, t) }
		t.cursor = -1
		drag_press(a, .Press_Empty, pi, 0, x, y)
		band_start(a, pi, x, y, ctrl)
	case .Scrollbar:
		drag_press(a, .Scrollbar, pi, 0, x, y)
		scrollbar_start(a, pi, y)
	}
	a.dirty = true
}

on_button_release :: proc(a: ^App, ev: ^xlib.XButtonEvent) {
	if ev.button != .Button1 { return }
	a.pointer = {ev.x, ev.y}
	if a.drag.kind != .None {
		a.drag.ctrl = .ControlMask in ev.state
		a.drag.shift = .ShiftMask in ev.state
		drag_release(a)
	}
	on_motion(a, ev.x, ev.y, ev.state)
	a.dirty = true
}

// Middle button: a folder opens in a new tab; a tab closes.
@(private)
middle_click :: proc(a: ^App, h: Hit) {
	#partial switch h.action {
	case .Item:
		t := pane_tab(a, h.pane)
		e := &t.entries[t.view[h.arg]]
		if e.is_dir {
			if new_tab(a, h.pane, entry_path(t, e), false) {
				set_notice(a, fmt.tprintf(tr(a, "“%s” aberta em uma nova aba", "“%s” opened in a new tab"), e.name))
			}
		}
	case .Tab:
		close_tab(a, h.pane, h.arg)
	case .Place:
		places := build_places(a)
		if h.arg < len(places) { new_tab(a, a.active_pane, places[h.arg].path) }
	case .Tab_Strip, .Tab_New:
		new_tab(a, h.pane, pane_tab(a, h.pane).dir)
	case .Search_Tab:
		set_active_pane(a, h.pane)
		search_open(a)
	}
}

cycle_tab_in :: proc(a: ^App, pi, dir: int) {
	p := a.panes[pi]
	n := len(p.tabs)
	if n <= 1 { return }
	set_active_tab(a, pi, (p.active + dir + n) % n)
}

open_place :: proc(a: ^App, index: int) {
	places := build_places(a)
	if index < 0 || index >= len(places) { return }
	navigate(a, cur_tab(a), places[index].path)
}

start_path_edit :: proc(a: ^App) {
	if a.focus == .Rename { rename_finish(a) }
	p := cur_pane(a)
	field_set(&p.path_field, cur_tab(a).dir)
	field_select_all(&p.path_field)
	a.focus = .Path
	a.dirty = true
}

start_search :: proc(a: ^App) {
	if a.focus == .Rename { rename_finish(a) }
	a.focus = .Search
	field_select_all(&cur_tab(a).search)
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------
on_key :: proc(a: ^App, ev: ^xlib.XKeyEvent) {
	raw, keysym := tx.input_lookup(&a.input, ev)
	ks := uint(keysym)
	text := printable(raw)
	ctrl := .ControlMask in ev.state
	shift := .ShiftMask in ev.state
	alt := .Mod1Mask in ev.state
	if ks == 0 && len(text) == 1 { ks = uint(text[0]) }

	if a.drag.kind != .None {
		if ks == KS_ESCAPE { drag_reset(a) }
		return
	}
	// Window-wide shortcuts first (tabs and panes).
	if ctrl && key_global(a, ks, shift, alt) { return }
	if ks == KS_F3 {
		split_pane(a, a.active_pane, cur_tab(a).dir)
		return
	}
	if ks == KS_F4 {
		term_toggle(a)
		return
	}
	// The viewer of the active pane: Escape closes it, arrows browse the folder.
	if a.panes[a.active_pane].viewer.kind == .Viewer && a.focus == .View {
		switch ks {
		case KS_ESCAPE, KS_BACKSPACE: viewer_close(a, a.active_pane); return
		case KS_LEFT, KS_UP:          viewer_step(a, a.active_pane, -1); return
		case KS_RIGHT, KS_DOWN, ' ':  viewer_step(a, a.active_pane, 1); return
		}
	}

	switch a.focus {
	case .Search:
		if key_search(a, ks, text, ctrl, shift) { return }
	case .Path:
		if key_path(a, ks, text, ctrl, shift) { return }
	case .Rename:
		if key_rename(a, ks, text, ctrl, shift) { return }
	case .View:
	}
	key_view(a, ks, text, ctrl, shift, alt)
}

// Ctrl shortcuts that work whatever has the focus.
@(private)
key_global :: proc(a: ^App, ks: uint, shift, alt: bool) -> bool {
	if alt {
		switch ks {
		case KS_LEFT:  set_active_pane(a, a.active_pane - 1); return true
		case KS_RIGHT: set_active_pane(a, a.active_pane + 1); return true
		}
		return false
	}
	switch ks {
	case 't', 'T':
		new_tab(a, a.active_pane, cur_tab(a).dir)
		return true
	case 'f', 'F':
		// Ctrl+Shift+F: search the whole disk (starting from the folder filter).
		if !shift { return false }
		t := cur_tab(a)
		search_open(a, is_search(t) ? "" : strings.trim_space(field_text(&t.search)))
		return true
	case 'w', 'W':
		if shift {
			if len(a.panes) > 1 { close_pane(a, a.active_pane) } else { a.running = false }
		} else {
			close_tab(a, a.active_pane, cur_pane(a).active)
		}
		return true
	case KS_TAB:
		cycle_tab(a, 1)
		return true
	case KS_LEFT_TAB:
		cycle_tab(a, -1)
		return true
	case KS_BACKSLASH:
		split_pane(a, a.active_pane, cur_tab(a).dir)
		return true
	case 'q', 'Q':
		a.running = false
		return true
	case KS_PAGE_UP:
		cycle_tab(a, -1)
		return true
	case KS_PAGE_DOWN:
		cycle_tab(a, 1)
		return true
	}
	return false
}

@(private)
key_search :: proc(a: ^App, ks: uint, text: string, ctrl, shift: bool) -> bool {
	t := cur_tab(a)
	switch ks {
	case KS_ESCAPE:
		if field_text(&t.search) != "" {
			field_clear(&t.search)
			filter_changed(a, t)
		} else {
			a.focus = .View
		}
		a.dirty = true
		return true
	case KS_RETURN, KS_KP_ENTER, KS_DOWN, KS_TAB:
		a.focus = .View
		if len(t.view) > 0 && len(selected_entries(t)) == 0 { move_cursor(a, t, 0, false) }
		if (ks == KS_RETURN || ks == KS_KP_ENTER) && len(t.view) == 1 { open_selection(a) }
		a.dirty = true
		return true
	}
	if ctrl && (ks == 'f' || ks == 'F') {
		field_select_all(&t.search)
		a.dirty = true
		return true
	}
	if ctrl && (ks == 'l' || ks == 'L') {
		start_path_edit(a)
		return true
	}
	before := strings.clone(field_text(&t.search), context.temp_allocator)
	used := field_key(&t.search, ks, ctrl ? "" : text, ctrl, shift)
	if used {
		// Caret moves do not search again; edits do.
		if field_text(&t.search) != before || !is_search(t) { filter_changed(a, t) }
		a.dirty = true
	}
	return used || !ctrl // plain keys never reach the file view while typing
}

@(private)
key_path :: proc(a: ^App, ks: uint, text: string, ctrl, shift: bool) -> bool {
	p := cur_pane(a)
	t := cur_tab(a)
	switch ks {
	case KS_ESCAPE:
		a.focus = .View
		a.dirty = true
		return true
	case KS_RETURN, KS_KP_ENTER:
		typed := strings.clone(field_text(&p.path_field), context.temp_allocator)
		a.focus = .View
		if strings.has_prefix(typed, "?") {
			// "?words" in the location bar searches the whole disk.
			search_open(a, strings.trim_space(typed[1:]))
			return true
		}
		target := absolute_path(typed, t.dir)
		if is_directory(target) {
			navigate(a, t, target)
		} else if path_exists(target) {
			// A file: open its folder with it selected.
			navigate(a, t, parent_dir(target), true, base_name(target))
		} else {
			set_notice(a, fmt.tprintf(tr(a, "“%s” não existe", "“%s” does not exist"), typed), true)
		}
		a.dirty = true
		return true
	}
	used := field_key(&p.path_field, ks, ctrl ? "" : text, ctrl, shift)
	if used { a.dirty = true }
	return used || !ctrl
}

@(private)
key_rename :: proc(a: ^App, ks: uint, text: string, ctrl, shift: bool) -> bool {
	switch ks {
	case KS_ESCAPE:
		rename_cancel(a)
		return true
	case KS_RETURN, KS_KP_ENTER:
		rename_commit(a)
		return true
	case KS_TAB:
		return true
	}
	used := field_key(&a.rename, ks, ctrl ? "" : text, ctrl, shift)
	if used { a.dirty = true }
	return true // every key belongs to the rename field while it is open
}

@(private)
key_view :: proc(a: ^App, ks: uint, text: string, ctrl, shift, alt: bool) {
	t := cur_tab(a)
	L := pane_layout(a, a.active_pane)
	per_row := t.mode == .Grid ? L.cols : 1
	page := max(1, int(L.area.h / (t.mode == .Grid ? L.cell_h : L.row_h))) * per_row
	cur := t.cursor
	if ctrl {
		switch ks {
		case 'c', 'C': copy_selection(a, false); return
		case 'x', 'X': copy_selection(a, true); return
		case 'v', 'V': paste(a); return
		case 'a', 'A': select_all(a, t); return
		case 'h', 'H': toggle_hidden(a, t); return
		case 'l', 'L': start_path_edit(a); return
		case 'f', 'F': start_search(a); return
		case 'n', 'N':
			if shift { new_folder(a) }
			return
		case 'r', 'R': refresh(a, t); return
		case '1': set_mode(a, t, .Grid); return
		case '2': set_mode(a, t, .List); return
		case KS_RETURN, KS_KP_ENTER:
			if is_search(t) { search_reveal(a) } // Ctrl+Enter: the containing folder
			return
		}
	}
	if alt {
		switch ks {
		case KS_LEFT:  go_back(a, t); return
		case KS_RIGHT: go_forward(a, t); return
		case KS_UP:    go_up(a, t); return
		case KS_RETURN, KS_KP_ENTER: return
		}
	}
	switch ks {
	case KS_XF86_BACK: go_back(a, t); return
	case KS_XF86_FWD:  go_forward(a, t); return
	case KS_RETURN, KS_KP_ENTER:
		open_selection(a)
		return
	case KS_BACKSPACE:
		if is_search(t) {
			// Back to editing the query.
			a.focus = .Search
			field_key(&t.search, KS_BACKSPACE, "", false, false)
			filter_changed(a, t)
			return
		}
		go_up(a, t)
		return
	case KS_F2:
		rename_start(a)
		return
	case KS_F5:
		refresh(a, t)
		return
	case KS_DELETE, KS_KP_DELETE:
		trash_selection(a)
		return
	case KS_MENU:
		menu_for_keyboard(a)
		return
	case KS_F10:
		if shift { menu_for_keyboard(a) }
		return
	case KS_ESCAPE:
		if field_text(&t.search) != "" && !is_search(t) {
			field_clear(&t.search)
			rebuild_view(a, t)
		} else {
			clear_selection(a, t)
		}
		return
	case KS_TAB:
		start_search(a)
		return
	case KS_LEFT:
		if t.mode == .Grid { move_cursor(a, t, cur < 0 ? 0 : cur - 1, shift) } else { go_up(a, t) }
		return
	case KS_RIGHT:
		if t.mode == .Grid {
			move_cursor(a, t, cur < 0 ? 0 : cur + 1, shift)
		} else if cur >= 0 && t.entries[t.view[cur]].is_dir && !is_search(t) {
			open_selection(a)
		}
		return
	case KS_UP:
		move_cursor(a, t, cur < 0 ? 0 : cur - per_row, shift)
		return
	case KS_DOWN:
		move_cursor(a, t, cur < 0 ? 0 : cur + per_row, shift)
		return
	case KS_HOME:
		move_cursor(a, t, 0, shift)
		return
	case KS_END:
		move_cursor(a, t, len(t.view) - 1, shift)
		return
	case KS_PAGE_UP:
		move_cursor(a, t, cur - page, shift)
		return
	case KS_PAGE_DOWN:
		move_cursor(a, t, cur < 0 ? page : cur + page, shift)
		return
	}
	// Typing in the file view starts filtering (or goes on with the query).
	if !ctrl && !alt && text != "" && text != " " {
		a.focus = .Search
		if is_search(t) {
			t.search.caret, t.search.anchor = len(t.search.buf), len(t.search.buf)
		} else {
			field_clear(&t.search)
		}
		field_insert(&t.search, text)
		filter_changed(a, t)
	}
}

// Context menu from the keyboard, at the cursor item (or the pointer).
menu_for_keyboard :: proc(a: ^App) {
	root_x, root_y := window_origin(a)
	t := cur_tab(a)
	sel := selected_entries(t)
	if len(sel) > 0 && t.cursor >= 0 {
		L := pane_layout(a, a.active_pane)
		r := item_rect(t, &L, t.cursor)
		x := L.area.x + r.x + r.w / 2
		y := L.area.y + r.y - i32(math.round(t.scroll)) + r.h / 2
		menu_open(a, root_x + x, root_y + y, true)
	} else {
		menu_open(a, root_x + a.pointer.x, root_y + a.pointer.y, false)
	}
}

// The window's position on the root window.
window_origin :: proc(a: ^App) -> (x, y: i32) {
	child: xlib.Window
	xlib.TranslateCoordinates(a.c.dpy, a.win, a.c.root, 0, 0, &x, &y, &child)
	return
}
