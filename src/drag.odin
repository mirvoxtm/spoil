// Pointer drags: files (between panes and onto folders, sidebar places, tabs
// and crumbs), rubber-band selection with auto-scroll, tabs (into another
// pane, or out to a new pane at the edges), pane dividers and scrollbars.
// Files dropped move on the same file system and copy across file systems;
// Ctrl forces a copy, Shift a move. The work runs as background jobs.
package spoil

import "core:strings"
import "core:sys/posix"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Drag_Kind :: enum { None, Press_Item, Press_Empty, Press_Tab, Files, Band, Tab, Divider, Scrollbar }
Drop_Kind :: enum { None, Folder, Pane, Place, Tab, Crumb, New_Pane }

Drop :: struct {
	kind: Drop_Kind,
	pane: int,
	arg:  int, // view index, place index, tab index, crumb index, or the side of a new pane (0 left, 1 right)
}

Drag :: struct {
	kind:         Drag_Kind,
	pane:         int,
	arg:          int,             // the pressed item (view index) or tab
	start:        [2]i32,
	defer_select: bool,            // pressed a selected item: select only it on release unless dragged
	paths:        [dynamic]string, // files being dragged (owned)
	src_dir:      string,          // owned
	ghost:        Entry,           // the pressed entry, for the drag image (name/key owned)
	ghost_ok:     bool,
	band_from:    [2]f32,          // content coordinates (area-relative, scroll included)
	band_to:      [2]f32,
	band_base:    [dynamic]bool,   // selection before a Ctrl+band, per entry
	ctrl, shift:  bool,
	drop:         Drop,
	widths:       [MAX_PANES]f32,  // divider drag: pane widths when it started
	grab:         i32,             // scrollbar drag: pointer offset inside the thumb
}

drag_reset :: proc(a: ^App) {
	d := &a.drag
	for p in d.paths { delete(p) }
	delete(d.paths)
	delete(d.src_dir)
	if d.ghost_ok { entry_destroy(&d.ghost) }
	delete(d.band_base)
	d^ = {}
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------
drag_press :: proc(a: ^App, kind: Drag_Kind, pi, arg: int, x, y: i32) {
	drag_reset(a)
	d := &a.drag
	d.kind = kind
	d.pane = pi
	d.arg = arg
	d.start = {x, y}
}

@(private)
begin_file_drag :: proc(a: ^App) {
	d := &a.drag
	if d.pane < 0 || d.pane >= len(a.panes) { return }
	t := pane_tab(a, d.pane)
	if d.arg < 0 || d.arg >= len(t.view) { return }
	pressed := &t.entries[t.view[d.arg]]
	if !pressed.selected { select_only(a, t, d.arg) }
	for p in selected_paths(t) { append(&d.paths, strings.clone(p)) }
	if len(d.paths) == 0 { return }
	d.src_dir = strings.clone(t.dir)
	d.ghost = pressed^
	d.ghost.name = strings.clone(pressed.name)
	d.ghost.key = strings.clone(pressed.key)
	d.ghost_ok = true
	d.kind = .Files
	d.defer_select = false
}

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------
drag_motion :: proc(a: ^App, x, y: i32, state: xlib.InputMask) {
	d := &a.drag
	d.ctrl = .ControlMask in state
	d.shift = .ShiftMask in state
	dist := abs(x - d.start.x) + abs(y - d.start.y)
	#partial switch d.kind {
	case .Press_Item:
		if dist > 6 { begin_file_drag(a) }
	case .Press_Empty:
		if dist > 4 { d.kind = .Band }
	case .Press_Tab:
		if dist > 10 && (len(a.panes) > 1 || len(a.panes[d.pane].tabs) > 1) { d.kind = .Tab }
	}
	#partial switch d.kind {
	case .Files:
		d.drop = file_drop_target(a, x, y)
		a.dirty = true
	case .Band:
		band_update(a)
	case .Tab:
		d.drop = tab_drop_target(a, x, y)
		a.dirty = true
	case .Divider:
		divider_update(a, x)
	case .Scrollbar:
		scrollbar_update(a, y)
	}
}

// What a file drag would drop onto at (x, y).
@(private)
file_drop_target :: proc(a: ^App, x, y: i32) -> Drop {
	d := &a.drag
	h := hit_at(a, x, y)
	#partial switch h.action {
	case .Item:
		t := pane_tab(a, h.pane)
		if h.arg < len(t.view) {
			e := &t.entries[t.view[h.arg]]
			path := join({t.dir, e.name})
			if e.is_dir && !e.unreadable && !is_dragged(a, path) { return {.Folder, h.pane, h.arg} }
		}
		if pane_tab(a, h.pane).dir != d.src_dir { return {.Pane, h.pane, 0} }
	case .Empty, .Pane, .Scrollbar, .Search, .Crumb_Bar, .Back, .Forward, .Up, .View_Grid, .View_List, .Hidden, .Path_Field:
		if pane_tab(a, h.pane).dir != d.src_dir { return {.Pane, h.pane, 0} }
	case .Place:
		places := build_places(a)
		if h.arg < len(places) && places[h.arg].path != d.src_dir && !is_dragged(a, places[h.arg].path) { return {.Place, 0, h.arg} }
	case .Tab, .Tab_Close:
		p := a.panes[h.pane]
		if h.arg < len(p.tabs) && p.tabs[h.arg].dir != d.src_dir { return {.Tab, h.pane, h.arg} }
	case .Crumb:
		list := a.crumbs[h.pane]
		if h.arg < len(list) && list[h.arg] != d.src_dir && !is_dragged(a, list[h.arg]) { return {.Crumb, h.pane, h.arg} }
	}
	return {}
}

@(private)
is_dragged :: proc(a: ^App, path: string) -> bool {
	for p in a.drag.paths {
		if p == path || strings.has_prefix(path, strings.concatenate({p, "/"}, context.temp_allocator)) { return true }
	}
	return false
}

// The folder the current file-drag target stands for ("" = none).
drop_dir :: proc(a: ^App) -> string {
	d := &a.drag
	switch d.drop.kind {
	case .None, .New_Pane:
		return ""
	case .Folder:
		if d.drop.pane >= len(a.panes) { return "" }
		t := pane_tab(a, d.drop.pane)
		if d.drop.arg >= len(t.view) { return "" }
		return join({t.dir, t.entries[t.view[d.drop.arg]].name})
	case .Pane:
		if d.drop.pane >= len(a.panes) { return "" }
		return pane_tab(a, d.drop.pane).dir
	case .Place:
		places := build_places(a)
		if d.drop.arg >= len(places) { return "" }
		return places[d.drop.arg].path
	case .Tab:
		if d.drop.pane >= len(a.panes) || d.drop.arg >= len(a.panes[d.drop.pane].tabs) { return "" }
		return a.panes[d.drop.pane].tabs[d.drop.arg].dir
	case .Crumb:
		if d.drop.pane >= len(a.panes) || d.drop.arg >= len(a.crumbs[d.drop.pane]) { return "" }
		return a.crumbs[d.drop.pane][d.drop.arg]
	}
	return ""
}

// Move or copy: Ctrl copies, Shift moves, otherwise move within a file
// system and copy across file systems.
drag_op :: proc(a: ^App) -> Job_Kind {
	d := &a.drag
	if d.ctrl { return .Copy }
	if d.shift { return .Move }
	dest := drop_dir(a)
	if dest == "" || len(d.paths) == 0 { return .Move }
	return same_fs(d.paths[0], dest) ? .Move : .Copy
}

same_fs :: proc(a, b: string) -> bool {
	sa, sb: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(a, context.temp_allocator), &sa) != .OK { return false }
	if posix.stat(strings.clone_to_cstring(b, context.temp_allocator), &sb) != .OK { return false }
	return sa.st_dev == sb.st_dev
}

// Where a dragged tab would go at (x, y).
@(private)
tab_drop_target :: proc(a: ^App, x, y: i32) -> Drop {
	d := &a.drag
	cols, n := pane_columns(a)
	src_alone := len(a.panes[d.pane].tabs) == 1
	if n < MAX_PANES {
		if x >= a.w - MARGIN - EDGE_ZONE && !(src_alone && d.pane == n - 1) { return {.New_Pane, 0, 1} }
		if x >= SIDEBAR_W && x < SIDEBAR_W + EDGE_ZONE && !(src_alone && d.pane == 0) { return {.New_Pane, 0, 0} }
	}
	for i in 0 ..< n {
		col := cols[i]
		if x < col.x - MARGIN / 2 || x >= col.x + col.w + MARGIN / 2 { continue }
		if i != d.pane { return {.Pane, i, 0} }
		// Same pane: reorder inside its strip.
		if y < col.y + TAB_H + 4 {
			L := pane_layout(a, i)
			w := tab_width(a, i, &L)
			idx := clamp(int((x - col.x + (w + 4) / 2) / (w + 4)), 0, len(a.panes[i].tabs))
			if idx != d.arg && idx != d.arg + 1 { return {.Tab, i, idx} }
		}
		return {}
	}
	return {}
}

// ---------------------------------------------------------------------------
// Rubber band
// ---------------------------------------------------------------------------
band_start :: proc(a: ^App, pi: int, x, y: i32, ctrl: bool) {
	t := pane_tab(a, pi)
	L := pane_layout(a, pi)
	d := &a.drag
	d.band_from = {f32(x - L.area.x), f32(y - L.area.y) + t.scroll}
	d.band_to = d.band_from
	if ctrl {
		d.band_base = make([dynamic]bool, len(t.entries))
		for e, i in t.entries { d.band_base[i] = e.selected }
	}
}

band_rect :: proc(a: ^App, t: ^Tab) -> tx.Rect {
	d := &a.drag
	x0 := min(d.band_from.x, d.band_to.x)
	y0 := min(d.band_from.y, d.band_to.y)
	x1 := max(d.band_from.x, d.band_to.x)
	y1 := max(d.band_from.y, d.band_to.y)
	return {i32(x0), i32(y0), max(i32(x1 - x0), 1), max(i32(y1 - y0), 1)}
}

@(private)
band_update :: proc(a: ^App) {
	d := &a.drag
	if d.pane >= len(a.panes) { return }
	t := pane_tab(a, d.pane)
	L := pane_layout(a, d.pane)
	px := clamp(a.pointer.x, L.area.x, L.area.x + L.area.w - 1)
	py := clamp(a.pointer.y, L.area.y, L.area.y + L.area.h - 1)
	d.band_to = {f32(px - L.area.x), f32(py - L.area.y) + t.scroll_to}
	b := band_rect(a, t)
	for idx, vi in t.view {
		r := item_rect(t, &L, vi)
		// The visible part of an item (its highlight), not the whole cell.
		hit := L.mode == .Grid ? tx.Rect{r.x + 4, r.y + 2, r.w - 8, r.h - 4} : tx.Rect{r.x + 4, r.y + 1, min(r.w - 8, L.col_size), r.h - 2}
		_, touches := tx.rect_intersect(b, hit)
		base := idx < len(d.band_base) && d.band_base[idx]
		t.entries[idx].selected = base || touches
	}
	a.dirty = true
}

// The pointer near the top or bottom edge of the file view scrolls it.
drag_autoscrolling :: proc(a: ^App) -> bool {
	d := &a.drag
	if d.kind != .Band && d.kind != .Files { return false }
	pi := d.kind == .Band ? d.pane : pane_at(a, a.pointer.x)
	if pi < 0 || pi >= len(a.panes) { return false }
	L := pane_layout(a, pi)
	if d.kind == .Files && (a.pointer.x < L.area.x || a.pointer.x >= L.area.x + L.area.w) { return false }
	y := a.pointer.y
	return (y < L.area.y + 28 && y > L.area.y - 60) || (y > L.area.y + L.area.h - 28 && y < L.area.y + L.area.h + 60)
}

drag_tick :: proc(a: ^App, now: f64) {
	d := &a.drag
	if !drag_autoscrolling(a) { return }
	pi := d.kind == .Band ? d.pane : pane_at(a, a.pointer.x)
	t := pane_tab(a, pi)
	L := pane_layout(a, pi)
	y := a.pointer.y
	speed: f32 = 0
	if y < L.area.y + 28 {
		speed = -(f32(L.area.y + 28 - y) * 0.5 + 2)
	} else {
		speed = f32(y - (L.area.y + L.area.h - 28)) * 0.5 + 2
	}
	speed = clamp(speed, -40, 40)
	before := t.scroll_to
	t.scroll_to = clamp(t.scroll_to + speed, 0, max_scroll(&L))
	t.scroll = t.scroll_to
	if t.scroll_to != before {
		if d.kind == .Band { band_update(a) }
		a.dirty = true
	}
}

// The pane column under window x (-1 over the sidebar).
pane_at :: proc(a: ^App, x: i32) -> int {
	cols, n := pane_columns(a)
	for i in 0 ..< n {
		if x >= cols[i].x - MARGIN / 2 && x < cols[i].x + cols[i].w + MARGIN / 2 { return i }
	}
	return -1
}

// ---------------------------------------------------------------------------
// Dividers and scrollbars
// ---------------------------------------------------------------------------
divider_start :: proc(a: ^App, i: int, x: i32) {
	cols, n := pane_columns(a)
	d := &a.drag
	for k in 0 ..< n { d.widths[k] = f32(cols[k].w) }
	d.arg = i
}

@(private)
divider_update :: proc(a: ^App, x: i32) {
	d := &a.drag
	i := d.arg
	if i < 0 || i + 1 >= len(a.panes) { return }
	pair := d.widths[i] + d.widths[i + 1]
	left := clamp(d.widths[i] + f32(x - d.start.x), 220, pair - 220)
	if pair < 440 { return }
	for p, k in a.panes { p.weight = d.widths[k] }
	a.panes[i].weight = left
	a.panes[i + 1].weight = pair - left
	for p in a.panes { clamp_scroll(a, p.tabs[p.active]) }
	a.base_dirty = true
	a.dirty = true
}

scrollbar_start :: proc(a: ^App, pi: int, y: i32) {
	t := pane_tab(a, pi)
	L := pane_layout(a, pi)
	_, thumb, ok := scrollbar_rect(t, &L)
	if !ok { return }
	local_y := y - L.area.y
	a.drag.grab = local_y >= thumb.y && local_y < thumb.y + thumb.h ? local_y - thumb.y : thumb.h / 2
	scrollbar_update(a, y)
}

@(private)
scrollbar_update :: proc(a: ^App, y: i32) {
	d := &a.drag
	if d.pane >= len(a.panes) { return }
	t := pane_tab(a, d.pane)
	L := pane_layout(a, d.pane)
	track, thumb, ok := scrollbar_rect(t, &L)
	if !ok { return }
	span := f32(track.h - thumb.h)
	pos := f32(y - L.area.y - track.y - d.grab)
	if span > 0 { t.scroll_to = clamp(pos / span, 0, 1) * max_scroll(&L) }
	t.scroll = t.scroll_to
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Release
// ---------------------------------------------------------------------------
drag_release :: proc(a: ^App) {
	d := &a.drag
	#partial switch d.kind {
	case .Press_Item:
		if d.defer_select && d.pane < len(a.panes) {
			t := pane_tab(a, d.pane)
			if d.arg < len(t.view) { select_only(a, t, d.arg) }
		}
	case .Files:
		dest := strings.clone(drop_dir(a), context.temp_allocator)
		if dest != "" {
			op := drag_op(a)
			paths := make([]string, len(d.paths), context.temp_allocator)
			for p, i in d.paths { paths[i] = strings.clone(p, context.temp_allocator) }
			transfer(a, paths, dest, op)
		}
	case .Tab:
		drop := d.drop
		#partial switch drop.kind {
		case .Pane:     move_tab(a, d.pane, d.arg, drop.pane)
		case .Tab:      move_tab(a, d.pane, d.arg, drop.pane, drop.arg)
		case .New_Pane: move_tab(a, d.pane, d.arg, -1, -1, drop.arg == 0 ? 0 : len(a.panes))
		}
	}
	drag_reset(a)
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

// Copy or move `paths` into folder `dest` as background jobs. Items whose
// name is free go in one cp/mv call; clashes get " (2)" and a call each.
transfer :: proc(a: ^App, paths: []string, dest: string, op: Job_Kind) -> int {
	move := op == .Move
	plain := make([dynamic]string, context.temp_allocator)
	started := 0
	skipped_self := false
	reserved := make(map[string]bool, context.temp_allocator)
	for src in paths {
		if !path_exists(src) { continue }
		if move && parent_dir(src) == dest { continue } // already there
		src_is_dir := is_directory(src)
		if src_is_dir && (dest == src || strings.has_prefix(dest, strings.concatenate({src, "/"}, context.temp_allocator))) {
			skipped_self = true
			continue
		}
		name := base_name(src)
		if !path_exists(join({dest, name})) && !reserved[name] {
			reserved[strings.clone(name, context.temp_allocator)] = true
			append(&plain, src)
			continue
		}
		unique := unique_name(dest, name, src_is_dir)
		for reserved[unique] { unique = unique_name(dest, strings.concatenate({unique, "~"}, context.temp_allocator), src_is_dir) }
		reserved[strings.clone(unique, context.temp_allocator)] = true
		target := join({dest, unique})
		argv := move ? []string{"mv", "-n", "--", src, target} : []string{"cp", "-r", "--", src, target}
		if start_job(a, op, argv) { started += 1 }
	}
	if len(plain) > 0 {
		argv := make([dynamic]string, context.temp_allocator)
		if move { append(&argv, "mv", "-n", "-t", dest, "--") } else { append(&argv, "cp", "-r", "-t", dest, "--") }
		append(&argv, ..plain[:])
		if start_job(a, op, argv[:], len(plain)) { started += len(plain) }
	}
	if skipped_self { set_notice(a, tr(a, "Uma pasta não pode ir para dentro dela mesma", "A folder cannot go inside itself"), true) }
	return started
}
