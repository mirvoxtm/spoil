// Tabs and panes. The window holds up to four panes side by side (tiling
// style, like milk's window manager); each pane has its own tab strip, path
// bar and file view, and each tab its own folder, history, selection,
// scroll, view mode, hidden-files switch and search. A search tab
// (search.odin) lists results from anywhere on the disk instead of a folder.
package spoil

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sys/posix"

MAX_PANES :: 4

Tab_Kind :: enum { Folder, Search }

Tab :: struct {
	kind:        Tab_Kind,
	id:          int,
	find:        Search_Tab, // search tabs: the query's state (the query is `search`)
	dir:         string, // owned
	dir_mtime:   i64,
	entries:     [dynamic]Entry, // sorted
	view:        [dynamic]int,   // indices into entries: filtered
	back_stack:  [dynamic]string,
	fwd_stack:   [dynamic]string,
	free_bytes:  i64,
	has_free:    bool,
	mode:        View_Mode,
	show_hidden: bool,
	cursor:      int, // view index with the keyboard focus (-1 = none)
	anchor:      int, // shift-selection anchor
	scroll:      f32,
	scroll_to:   f32,
	search:      Field,   // the folder filter; a search tab's query
}

Pane :: struct {
	tabs:       [dynamic]^Tab,
	active:     int,     // index into tabs
	weight:     f32,     // share of the width
	path_field: Field,
	viewer:     Embed,   // a picture/video shown inside the pane (embed.odin)
}

@(private="file")
g_tab_ids: int

tab_create :: proc(mode: View_Mode, show_hidden: bool) -> ^Tab {
	t := new(Tab)
	g_tab_ids += 1
	t.id = g_tab_ids
	t.cursor, t.anchor = -1, -1
	t.mode = mode
	t.show_hidden = show_hidden
	return t
}

tab_destroy :: proc(t: ^Tab) {
	entries_clear(&t.entries)
	delete(t.entries)
	delete(t.view)
	for s in t.back_stack { delete(s) }
	delete(t.back_stack)
	for s in t.fwd_stack { delete(s) }
	delete(t.fwd_stack)
	field_destroy(&t.search)
	delete(t.dir)
	free(t)
}

pane_create :: proc() -> ^Pane {
	p := new(Pane)
	p.weight = 1
	return p
}

pane_destroy :: proc(p: ^Pane) {
	for t in p.tabs { tab_destroy(t) }
	delete(p.tabs)
	field_destroy(&p.path_field)
	free(p)
}

cur_pane :: proc(a: ^App) -> ^Pane { return a.panes[a.active_pane] }

cur_tab :: proc(a: ^App) -> ^Tab {
	p := a.panes[a.active_pane]
	return p.tabs[p.active]
}

pane_tab :: proc(a: ^App, pi: int) -> ^Tab {
	p := a.panes[pi]
	return p.tabs[p.active]
}

is_search :: #force_inline proc(t: ^Tab) -> bool { return t.kind == .Search }

// The folder holding entry `e` (search results each have their own).
entry_dir :: proc(t: ^Tab, e: ^Entry) -> string { return e.dir != "" ? e.dir : t.dir }

entry_path :: proc(t: ^Tab, e: ^Entry) -> string { return join({entry_dir(t, e), e.name}) }

// The tab's title: its folder, or a search tab's query.
tab_label :: proc(a: ^App, t: ^Tab) -> string {
	if is_search(t) {
		q := strings.trim_space(field_text(&t.search))
		return q == "" ? tr(a, "Busca", "Search") : q
	}
	return dir_label(a, t.dir)
}

tab_icon :: proc(t: ^Tab) -> Ic {
	if is_search(t) { return .Search }
	return t.dir == clean_path(home_dir()) ? .Home : .Folder
}

// ---------------------------------------------------------------------------
// Tab and pane management
// ---------------------------------------------------------------------------

// Leave text editing before the active tab or pane changes.
end_editing :: proc(a: ^App) {
	if a.focus == .Rename { rename_finish(a) }
	a.focus = .View
	a.dirty = true
}

set_active_pane :: proc(a: ^App, pi: int) {
	if pi < 0 || pi >= len(a.panes) || pi == a.active_pane { return }
	end_editing(a)
	a.active_pane = pi
	tab_came_back(a, cur_tab(a))
	set_title(a)
	a.dirty = true
}

set_active_tab :: proc(a: ^App, pi, ti: int) {
	if pi < 0 || pi >= len(a.panes) { return }
	p := a.panes[pi]
	if ti < 0 || ti >= len(p.tabs) { return }
	if pi != a.active_pane || ti != p.active { end_editing(a) }
	a.active_pane = pi
	p.active = ti
	tab_came_back(a, p.tabs[ti])
	set_title(a)
	a.dirty = true
}

// A tab shown again: pick up changes made while it was hidden.
tab_came_back :: proc(a: ^App, t: ^Tab) {
	if is_search(t) {
		// Results whose sizes were left unknown (another search ran meanwhile).
		if !t.find.busy {
			for e in t.entries {
				if e.pending {
					search_refresh(a, t)
					break
				}
			}
		}
		return
	}
	if mt, ok := mtime_of(t.dir); !ok || mt != t.dir_mtime { refresh(a, t) }
}

// A new tab showing `dir` after the current tab of pane `pi`.
new_tab :: proc(a: ^App, pi: int, dir: string, activate := true) -> bool {
	p := a.panes[pi]
	from := p.tabs[p.active]
	t := tab_create(from.mode, from.show_hidden)
	if !navigate(a, t, dir, false) {
		tab_destroy(t)
		return false
	}
	inject_at(&p.tabs, p.active + 1, t)
	if activate {
		set_active_tab(a, pi, p.active + 1)
	}
	a.dirty = true
	return true
}

close_tab :: proc(a: ^App, pi, ti: int) {
	if pi < 0 || pi >= len(a.panes) { return }
	p := a.panes[pi]
	if ti < 0 || ti >= len(p.tabs) { return }
	if pi == a.active_pane && ti == p.active { end_editing(a) }
	if len(p.tabs) == 1 {
		if len(a.panes) == 1 {
			a.running = false // the last tab of the last pane: close the window
			return
		}
		close_pane(a, pi)
		return
	}
	tab_destroy(p.tabs[ti])
	ordered_remove(&p.tabs, ti)
	if p.active > ti || p.active >= len(p.tabs) { p.active = max(p.active - 1, 0) }
	tab_came_back(a, p.tabs[p.active])
	thumbs_forget(a)
	set_title(a)
	a.dirty = true
}

close_pane :: proc(a: ^App, pi: int) {
	if len(a.panes) <= 1 || pi < 0 || pi >= len(a.panes) { return }
	if pi == a.active_pane { end_editing(a) }
	pane_destroy(a.panes[pi])
	ordered_remove(&a.panes, pi)
	if a.active_pane > pi || a.active_pane >= len(a.panes) { a.active_pane = max(a.active_pane - 1, 0) }
	thumbs_forget(a)
	set_title(a)
	a.base_dirty = true
	a.dirty = true
}

// Split: a new pane next to pane `pi` (to its right, or at `index`) showing `dir`.
split_pane :: proc(a: ^App, pi: int, dir: string, index := -1) -> bool {
	if len(a.panes) >= MAX_PANES {
		set_notice(a, fmt.tprintf(tr(a, "No máximo %d painéis", "At most %d panes"), MAX_PANES), true)
		return false
	}
	from := pane_tab(a, pi)
	t := tab_create(from.mode, from.show_hidden)
	if !navigate(a, t, dir, false) {
		tab_destroy(t)
		return false
	}
	np := pane_create()
	append(&np.tabs, t)
	at := index < 0 ? pi + 1 : clamp(index, 0, len(a.panes))
	inject_at(&a.panes, at, np)
	for p in a.panes { p.weight = 1 } // equal shares, like milk's tiling
	end_editing(a)
	a.active_pane = at
	set_title(a)
	a.base_dirty = true
	a.dirty = true
	return true
}

cycle_tab :: proc(a: ^App, dir: int) {
	p := cur_pane(a)
	n := len(p.tabs)
	if n <= 1 { return }
	set_active_tab(a, a.active_pane, (p.active + dir + n) % n)
}

// Move tab `ti` of pane `from` into pane `to` (at `index`, -1 = the end), or
// into a new pane at `new_pane_index` when `to` < 0.
move_tab :: proc(a: ^App, from, ti, to: int, index := -1, new_pane_index := -1) {
	if from < 0 || from >= len(a.panes) { return }
	src := a.panes[from]
	if ti < 0 || ti >= len(src.tabs) { return }
	end_editing(a)
	t := src.tabs[ti]
	if to < 0 {
		// A new pane of its own.
		if len(a.panes) >= MAX_PANES {
			set_notice(a, fmt.tprintf(tr(a, "No máximo %d painéis", "At most %d panes"), MAX_PANES), true)
			return
		}
		if len(src.tabs) == 1 { return } // it already is a pane of its own
		ordered_remove(&src.tabs, ti)
		if src.active >= len(src.tabs) || src.active > ti { src.active = max(src.active - 1, 0) }
		np := pane_create()
		append(&np.tabs, t)
		at := clamp(new_pane_index, 0, len(a.panes))
		inject_at(&a.panes, at, np)
		for p in a.panes { p.weight = 1 }
		a.active_pane = at
	} else {
		if to >= len(a.panes) { return }
		dst := a.panes[to]
		if dst == src {
			// Reorder inside the strip.
			ordered_remove(&src.tabs, ti)
			at := index < 0 ? len(src.tabs) : clamp(index > ti ? index - 1 : index, 0, len(src.tabs))
			inject_at(&src.tabs, at, t)
			src.active = at
			a.active_pane = from
		} else {
			ordered_remove(&src.tabs, ti)
			if src.active >= len(src.tabs) || src.active > ti { src.active = max(src.active - 1, 0) }
			at := index < 0 ? len(dst.tabs) : clamp(index, 0, len(dst.tabs))
			inject_at(&dst.tabs, at, t)
			dst.active = at
			target := dst
			if len(src.tabs) == 0 {
				pane_destroy(src)
				ordered_remove(&a.panes, from)
				for p in a.panes { p.weight = 1 }
			}
			for p, i in a.panes { if p == target { a.active_pane = i } }
		}
	}
	set_title(a)
	a.base_dirty = true
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------
errno_text :: proc(a: ^App, err: posix.Errno) -> string {
	#partial switch err {
	case .EACCES, .EPERM: return tr(a, "sem permissão", "permission denied")
	case .ENOENT:         return tr(a, "a pasta não existe", "no such folder")
	case .ENOTDIR:        return tr(a, "não é uma pasta", "not a folder")
	}
	return fmt.tprintf("%v", err)
}

// Open folder `path` in tab `t`. On failure (permissions, missing) the tab
// stays where it was and a notice explains why. `select_name` is selected.
// A search tab becomes a folder tab.
navigate :: proc(a: ^App, t: ^Tab, path: string, push := true, select_name := "") -> bool {
	base := t.dir != "" ? t.dir : home_dir()
	target := absolute_path(path, base)
	list := make([dynamic]Entry)
	if err := list_directory(target, &list); err != .NONE {
		entries_clear(&list)
		delete(list)
		set_notice(a, fmt.tprintf(tr(a, "Não foi possível abrir “%s”: %s", "Cannot open “%s”: %s"), base_name(target), errno_text(a, err)), true)
		return false
	}
	slice.sort_by(list[:], entry_less)
	if t == cur_tab_or_nil(a) && a.focus == .Rename { rename_finish(a) }
	if push && t.dir != "" && t.dir != target && !is_search(t) {
		append(&t.back_stack, strings.clone(t.dir))
		for s in t.fwd_stack { delete(s) }
		clear(&t.fwd_stack)
	}
	entries_clear(&t.entries)
	delete(t.entries)
	t.entries = list
	t.kind = .Folder
	t.find = {}
	delete(t.dir)
	t.dir = strings.clone(target)
	t.dir_mtime, _ = mtime_of(target)
	field_clear(&t.search)
	if t == cur_tab_or_nil(a) && a.focus != .View { a.focus = .View }
	t.cursor, t.anchor = -1, -1
	rebuild_view(a, t)
	t.scroll, t.scroll_to = 0, 0
	if select_name != "" { select_by_name(a, t, select_name) }
	update_free(t)
	if len(a.panes) > 0 { thumbs_forget(a) }
	if a.win != 0 { set_title(a) }
	a.dirty = true
	log.debugf("Opened %s (%d entries)", t.dir, len(t.entries))
	return true
}

// The active tab, or nil while the first pane is being set up.
cur_tab_or_nil :: proc(a: ^App) -> ^Tab {
	if len(a.panes) == 0 || a.active_pane >= len(a.panes) { return nil }
	p := a.panes[a.active_pane]
	if len(p.tabs) == 0 { return nil }
	return p.tabs[p.active]
}

go_up :: proc(a: ^App, t: ^Tab) {
	if t.dir == "/" || is_search(t) { return }
	child := base_name(t.dir)
	navigate(a, t, parent_dir(t.dir), true, child)
}

go_back :: proc(a: ^App, t: ^Tab) {
	if len(t.back_stack) == 0 { return }
	target := pop(&t.back_stack)
	defer delete(target)
	from := strings.clone(t.dir, context.temp_allocator)
	child := ""
	if parent_dir(from) == target { child = base_name(from) }
	if navigate(a, t, target, false, child) {
		append(&t.fwd_stack, strings.clone(from))
	}
}

go_forward :: proc(a: ^App, t: ^Tab) {
	if len(t.fwd_stack) == 0 { return }
	target := pop(&t.fwd_stack)
	defer delete(target)
	from := strings.clone(t.dir, context.temp_allocator)
	if navigate(a, t, target, false) {
		append(&t.back_stack, strings.clone(from))
	}
}

// Re-read the folder, keeping the selection, the cursor and the scroll.
refresh :: proc(a: ^App, t: ^Tab) {
	if is_search(t) {
		search_refresh(a, t)
		return
	}
	selected := make(map[string]bool, context.temp_allocator)
	for e in t.entries { if e.selected { selected[strings.clone(e.name, context.temp_allocator)] = true } }
	cursor_name := ""
	if t.cursor >= 0 && t.cursor < len(t.view) { cursor_name = strings.clone(t.entries[t.view[t.cursor]].name, context.temp_allocator) }
	list := make([dynamic]Entry)
	if err := list_directory(t.dir, &list); err != .NONE {
		entries_clear(&list)
		delete(list)
		// The folder went away: fall back to the closest existing parent.
		p := parent_dir(t.dir)
		for p != "/" && !is_directory(p) { p = parent_dir(p) }
		navigate(a, t, p, false)
		return
	}
	slice.sort_by(list[:], entry_less)
	for &e in list { if e.name in selected { e.selected = true } }
	entries_clear(&t.entries)
	delete(t.entries)
	t.entries = list
	t.dir_mtime, _ = mtime_of(t.dir)
	t.cursor = -1
	rebuild_view(a, t)
	if cursor_name != "" {
		for idx, vi in t.view {
			if t.entries[idx].name == cursor_name { t.cursor = vi; break }
		}
	}
	if t.anchor >= len(t.view) { t.anchor = t.cursor }
	update_free(t)
	a.dirty = true
}

// Refresh every visible tab (after a job changed files).
refresh_visible :: proc(a: ^App) {
	for p in a.panes { refresh(a, p.tabs[p.active]) }
}

// Poll the visible folders' mtimes (entries added, removed or renamed).
check_directories :: proc(a: ^App) {
	for p in a.panes {
		t := p.tabs[p.active]
		if t.dir == "" || is_search(t) { continue }
		mt, ok := mtime_of(t.dir)
		if !ok || mt != t.dir_mtime { refresh(a, t) }
	}
}

update_free :: proc(t: ^Tab) {
	t.free_bytes, t.has_free = free_space(t.dir)
}

// The filtered, visible entries (entries are kept sorted). Search results
// are filtered by the search itself; only those gone from the disk drop out.
rebuild_view :: proc(a: ^App, t: ^Tab) {
	cursor_entry := -1
	if t.cursor >= 0 && t.cursor < len(t.view) { cursor_entry = t.view[t.cursor] }
	clear(&t.view)
	needle := is_search(t) ? "" : sort_key(strings.trim_space(field_text(&t.search)), context.temp_allocator)
	for &e, i in t.entries {
		visible := is_search(t) ? !e.gone : (t.show_hidden || !e.hidden) && matches_filter(e.key, needle)
		if !visible {
			e.selected = false
			continue
		}
		append(&t.view, i)
	}
	t.cursor = -1
	if cursor_entry >= 0 {
		for idx, vi in t.view { if idx == cursor_entry { t.cursor = vi; break } }
	}
	if t.anchor >= len(t.view) { t.anchor = -1 }
	clamp_scroll(a, t)
	a.dirty = true
}

hidden_count :: proc(t: ^Tab) -> int {
	if is_search(t) { return t.find.hidden }
	n := 0
	for e in t.entries { if e.hidden { n += 1 } }
	return n
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------
selected_entries :: proc(t: ^Tab) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for idx in t.view { if t.entries[idx].selected { append(&out, idx) } }
	return out[:]
}

selected_paths :: proc(t: ^Tab) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for idx in selected_entries(t) { append(&out, entry_path(t, &t.entries[idx])) }
	return out[:]
}

selection_stats :: proc(t: ^Tab) -> (count: int, bytes: i64, files: int) {
	for idx in t.view {
		e := &t.entries[idx]
		if !e.selected { continue }
		count += 1
		if !e.is_dir && e.kind != .Broken {
			bytes += e.size
			files += 1
		}
	}
	return
}

clear_selection :: proc(a: ^App, t: ^Tab) {
	for &e in t.entries { e.selected = false }
	a.dirty = true
}

select_only :: proc(a: ^App, t: ^Tab, vi: int) {
	clear_selection(a, t)
	if vi >= 0 && vi < len(t.view) { t.entries[t.view[vi]].selected = true }
	t.cursor, t.anchor = vi, vi
}

select_range :: proc(a: ^App, t: ^Tab, from, to: int, additive: bool) {
	if !additive { clear_selection(a, t) }
	lo, hi := min(from, to), max(from, to)
	for vi in max(lo, 0) ..= min(hi, len(t.view) - 1) { t.entries[t.view[vi]].selected = true }
	a.dirty = true
}

select_all :: proc(a: ^App, t: ^Tab) {
	for idx in t.view { t.entries[idx].selected = true }
	a.dirty = true
}

select_by_name :: proc(a: ^App, t: ^Tab, name: string) {
	for idx, vi in t.view {
		if t.entries[idx].name == name {
			select_only(a, t, vi)
			reveal(a, t, vi)
			return
		}
	}
}

// The pane showing tab `t` (-1 when it is not visible).
pane_of :: proc(a: ^App, t: ^Tab) -> int {
	for p, i in a.panes { if p.tabs[p.active] == t { return i } }
	return -1
}

// Scroll so that view item `vi` is fully visible.
reveal :: proc(a: ^App, t: ^Tab, vi: int) {
	if vi < 0 || vi >= len(t.view) { return }
	pi := pane_of(a, t)
	if pi < 0 { return }
	L := pane_layout(a, pi)
	r := item_rect(t, &L, vi)
	top := f32(r.y - 4)
	bottom := f32(r.y + r.h + 4 - L.area.h)
	if t.scroll_to > top { t.scroll_to = top }
	if t.scroll_to < bottom { t.scroll_to = bottom }
	t.scroll_to = clamp(t.scroll_to, 0, max_scroll(&L))
	a.dirty = true
}

// Keyboard cursor movement (arrows, Home/End, Page keys).
move_cursor :: proc(a: ^App, t: ^Tab, to: int, shift: bool) {
	if len(t.view) == 0 { return }
	target := clamp(to, 0, len(t.view) - 1)
	if shift {
		if t.anchor < 0 { t.anchor = max(t.cursor, 0) }
		select_range(a, t, t.anchor, target, false)
		t.cursor = target
	} else {
		select_only(a, t, target)
	}
	reveal(a, t, target)
}

clamp_scroll :: proc(a: ^App, t: ^Tab) {
	pi := pane_of(a, t)
	if pi < 0 { return }
	L := pane_layout(a, pi)
	m := max_scroll(&L)
	t.scroll_to = clamp(t.scroll_to, 0, m)
	t.scroll = clamp(t.scroll, 0, m)
}

set_mode :: proc(a: ^App, t: ^Tab, m: View_Mode) {
	if t.mode == m { return }
	t.mode = m
	a.base_dirty = true
	clamp_scroll(a, t)
	if t.cursor >= 0 { reveal(a, t, t.cursor) }
	t.scroll = t.scroll_to
	a.dirty = true
}

toggle_hidden :: proc(a: ^App, t: ^Tab) {
	t.show_hidden = !t.show_hidden
	if is_search(t) { search_refresh(a, t) } else { rebuild_view(a, t) }
	set_notice(a, t.show_hidden ? tr(a, "Mostrando arquivos ocultos", "Showing hidden files") : tr(a, "Arquivos ocultos escondidos", "Hidden files hidden"))
}

// The filter (or a search tab's query) was edited.
filter_changed :: proc(a: ^App, t: ^Tab) {
	if is_search(t) { search_submit(a, t) } else { rebuild_view(a, t) }
	a.dirty = true
}
