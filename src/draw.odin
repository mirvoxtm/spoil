// Drawing. Every frame is composed on a CPU canvas (a cached base with the
// backdrop, the path-bar strips and the content cards, their shadows and
// outlines), uploaded as the window background, and text is drawn on that
// pixmap with Xft afterwards, clipped per item. The look is the milk bar's:
// the bar's height, radius and colours, round hover pills, Tabler glyphs.
//
// Layout: the sidebar on the left; then one to four panes side by side, each
// with a tab strip, a path bar (a strip like milk's bar) and a card holding
// the file view and a status line.
package spoil

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

MARGIN      :: 10  // gaps between the window edge, the strips, the sidebar and the cards
SIDEBAR_W   :: 214 // including the margin on its left
SIDE_ROW_H  :: 34
TAB_H       :: 30
TAB_GAP     :: 6
STATUS_H    :: 32
LIST_ROW_H  :: 30
HEADER_H    :: 30
CELL_MIN_W  :: 112
EDGE_ZONE   :: 40  // tab drops this close to the outer pane edges make a new pane

Layout :: struct {
	pane:      tx.Rect, // the whole column
	tabs:      tx.Rect,
	toolbar:   tx.Rect,
	card:      tx.Rect,
	header:    tx.Rect, // list column titles (list mode)
	area:      tx.Rect, // the scrolled items
	status:    tx.Rect,
	mode:      View_Mode,
	cols:      int,
	cell_w:    i32,
	cell_h:    i32,
	row_h:     i32,
	content_h: i32,
	col_size:  i32, // list: right edge of the size column (area coordinates)
	col_date:  i32, // list: left edge of the date column
	col_path:  i32, // list of a search tab: left edge of the folder column (area.w = none)
}

// Pane columns: the width after the sidebar shared by weight.
pane_columns :: proc(a: ^App) -> (cols: [MAX_PANES]tx.Rect, n: int) {
	n = len(a.panes)
	x0 := i32(SIDEBAR_W)
	x1 := a.w - MARGIN
	if tw := term_width(a); tw > 0 { x1 -= tw + MARGIN } // the terminal column
	total := x1 - x0 - MARGIN * i32(n - 1)
	sum: f32 = 0
	for p in a.panes { sum += max(p.weight, 0.05) }
	x := x0
	for p, i in a.panes {
		w := i == n - 1 ? x1 - x : i32(f32(total) * max(p.weight, 0.05) / sum)
		cols[i] = {x, MARGIN, max(w, 1), a.h - 2 * MARGIN}
		x += w + MARGIN
	}
	return
}

sidebar_rect :: proc(a: ^App) -> tx.Rect {
	top := i32(MARGIN + TAB_H + TAB_GAP)
	return {MARGIN, top, SIDEBAR_W - MARGIN - 6, a.h - top - MARGIN}
}

pane_layout :: proc(a: ^App, pi: int) -> Layout {
	L: Layout
	cols, _ := pane_columns(a)
	col := cols[pi]
	t := pane_tab(a, pi)
	s := &a.style
	L.pane = col
	L.mode = t.mode
	L.tabs = {col.x, col.y, col.w, TAB_H}
	L.toolbar = {col.x, col.y + TAB_H + TAB_GAP, col.w, s.bar_h}
	top := L.toolbar.y + L.toolbar.h + MARGIN
	L.card = {col.x, top, col.w, a.h - top - MARGIN}
	L.status = {L.card.x, L.card.y + L.card.h - STATUS_H, L.card.w, STATUS_H}
	inner_top := L.card.y + 8
	if t.mode == .List {
		L.header = {L.card.x + 8, L.card.y + 6, L.card.w - 16, HEADER_H}
		inner_top = L.header.y + L.header.h + 2
	}
	L.area = {L.card.x + 8, inner_top, max(L.card.w - 16, 1), max(L.status.y - inner_top, 1)}
	n := len(t.view)
	if t.mode == .Grid {
		label_h := line_height(a.style.font_small)
		L.cols = max(1, int((L.area.w - 8) / CELL_MIN_W))
		L.cell_w = max((L.area.w - 8) / i32(L.cols), 1)
		L.cell_h = GRID_BOX + 12 + 2 * label_h + 12
		rows := (n + L.cols - 1) / L.cols
		L.content_h = i32(rows) * L.cell_h + 8
	} else {
		L.cols = 1
		L.row_h = LIST_ROW_H
		L.content_h = i32(n) * L.row_h + 8
		date_w := clamp(L.area.w / 5, 110, 140)
		size_w := clamp(L.area.w / 7, 70, 100)
		L.col_date = L.area.w - 12 - date_w
		L.col_size = L.col_date - 22
		if L.col_size - size_w < 160 {
			// Narrow pane: no date column.
			L.col_date = L.area.w
			L.col_size = L.area.w - 16
		}
		// Search results: Nome | Pasta | Tamanho | Modificado, when there is room.
		L.col_path = L.area.w
		if is_search(t) {
			name_x := i32(12 + LIST_ICON + 10)
			room := L.col_size - 96 - name_x
			if room >= 300 { L.col_path = name_x + room * 2 / 5 }
		}
	}
	return L
}

// Rectangle of view item `vi` in content coordinates (area-relative, scroll not applied).
item_rect :: proc(t: ^Tab, L: ^Layout, vi: int) -> tx.Rect {
	if L.mode == .Grid {
		row, col := vi / L.cols, vi % L.cols
		return {4 + i32(col) * L.cell_w, 4 + i32(row) * L.cell_h, L.cell_w, L.cell_h}
	}
	return {0, 4 + i32(vi) * L.row_h, L.area.w, L.row_h}
}

max_scroll :: proc(L: ^Layout) -> f32 {
	return f32(max(L.content_h - L.area.h, 0))
}

add_hit :: proc(a: ^App, r: tx.Rect, action: Action, pane: int = 0, arg: int = 0, clip := tx.Rect{}) {
	append(&a.hits, Hit{r = r, action = action, pane = pane, arg = arg, clip = clip})
}

hovered :: proc(a: ^App, action: Action, pane: int = 0, arg: int = 0) -> bool {
	return a.hover.action == action && a.hover.pane == pane && a.hover.arg == arg
}

hit_at :: proc(a: ^App, x, y: i32) -> Hit {
	#reverse for h in a.hits {
		if !tx.rect_contains(h.r, x, y) { continue }
		if h.clip.w > 0 && !tx.rect_contains(h.clip, x, y) { continue }
		return h
	}
	return {}
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------
@(private)
build_base :: proc(a: ^App) {
	th := &a.style.theme
	tx.canvas_destroy(&a.base)
	a.base = tx.canvas_make(a.w, a.h)
	a.base_dirty = false
	cv := &a.base
	tx.canvas_fill(cv, th.backdrop)
	rad := f32(a.style.radius)
	strength: f32 = th.dark ? 0.35 : 0.10
	for _, pi in a.panes {
		L := pane_layout(a, pi)
		for r in ([]tx.Rect{L.toolbar, L.card}) {
			radius := r == L.toolbar ? min(rad, f32(r.h) / 2) : rad
			soft_shadow(cv, r, radius, 10, strength, 2)
			fill_rounded(cv, r, radius, th.bg)
			stroke_rounded(cv, r, radius, 1, tx.color_with_alpha(th.muted, th.dark ? 45 : 60))
		}
		tx.canvas_fill_rect(cv, {L.status.x + 14, L.status.y, L.status.w - 28, 1}, mix(th.bg, th.muted, 0.22))
	}
}

render :: proc(a: ^App) {
	c := a.c
	a.dirty = false
	if a.win == 0 { return }
	started := tx.now()
	defer if dt := tx.now() - started; dt > 0.025 { log.debugf("Slow frame: %.1f ms", dt * 1000) }
	if a.base_dirty || a.base.w != a.w || a.base.h != a.h { build_base(a) }
	if a.frame.w != a.w || a.frame.h != a.h || len(a.frame.px) != len(a.base.px) {
		tx.canvas_destroy(&a.frame)
		a.frame = tx.canvas_make(a.w, a.h)
	}
	copy(a.frame.px, a.base.px)
	clear(&a.hits)
	a.texts = make([dynamic]Text_Item, context.temp_allocator)
	cv := &a.frame
	draw_sidebar(a, cv)
	for _, pi in a.panes {
		L := pane_layout(a, pi)
		add_hit(a, L.pane, .Pane, pi)
		draw_tabs(a, cv, pi, &L)
		draw_toolbar(a, cv, pi, &L)
		draw_content(a, cv, pi, &L)
		draw_status(a, cv, pi, &L)
	}
	draw_term_card(a, cv)
	draw_dividers(a, cv)
	draw_drag_overlay(a, cv)

	pm := tx.canvas_to_pixmap(c, a.frame)
	draw_texts(a, pm, a.texts[:])
	tx.set_background(c, a.win, pm)
	tx.pixmap_free(c, a.pixmap)
	a.pixmap = pm
	embeds_sync(a)
	tx.flush(c)

	// The layout may have moved under the pointer.
	h := hit_at(a, a.pointer.x, a.pointer.y)
	if a.drag.kind == .None && (h.action != a.hover.action || h.pane != a.hover.pane || h.arg != a.hover.arg) {
		a.hover = h
		a.dirty = true
	}
	update_cursor(a, h)
}

@(private)
update_cursor :: proc(a: ^App, h: Hit) {
	shape := 0
	#partial switch h.action {
	case .Search, .Path_Field, .Rename_Field: shape = 1
	case .Divider:                            shape = 3
	}
	if a.drag.kind == .Divider { shape = 3 }
	if shape == 0 && len(a.jobs) > 0 && a.drag.kind == .None { shape = 2 }
	if shape != a.cursor_shape {
		a.cursor_shape = shape
		xlib.DefineCursor(a.c.dpy, a.win, a.cursors[shape])
	}
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------
place_icon :: proc(k: Place_Kind) -> Ic {
	switch k {
	case .Home:       return .Home
	case .Desktop:    return .Desktop
	case .Documents:  return .File_Text
	case .Downloads:  return .Download
	case .Pictures:   return .Photo
	case .Music:      return .Music
	case .Videos:     return .Movie
	case .Trash:      return .Trash
	case .Common:     return .Folders
	case .Area:       return .Folder
	case .Wallpapers: return .Wallpaper
	}
	return .Folder
}

// A pill clipped to the rows of `clip` (sidebar rows scrolled past its edge).
@(private)
fill_rounded_clipped :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, color: tx.Color, clip: tx.Rect) {
	if r.y >= clip.y && r.y + r.h <= clip.y + clip.h {
		fill_rounded(cv, r, radius, color)
		return
	}
	sub := tx.canvas_make(r.w, r.h, context.temp_allocator)
	for yy in 0 ..< r.h {
		src_y := r.y + yy
		if src_y < 0 || src_y >= cv.h { continue }
		copy(sub.px[int(yy) * int(r.w):][:r.w], cv.px[int(src_y) * int(cv.w) + int(r.x):][:r.w])
	}
	fill_rounded(&sub, {0, 0, r.w, r.h}, radius, color)
	for yy in 0 ..< r.h {
		dst_y := r.y + yy
		if dst_y < clip.y || dst_y >= clip.y + clip.h { continue }
		copy(cv.px[int(dst_y) * int(cv.w) + int(r.x):][:r.w], sub.px[int(yy) * int(r.w):][:r.w])
	}
}

@(private)
draw_sidebar :: proc(a: ^App, cv: ^tx.Canvas) {
	th := &a.style.theme
	sb := sidebar_rect(a)
	// Brand, level with the tab strips.
	brand := tx.Rect{sb.x + 6, MARGIN, 28, TAB_H}
	tx.canvas_fill_circle(cv, f32(brand.x + 14), f32(brand.y + TAB_H / 2), 13, th.accent)
	glyph(a, a.style.icon_small, {brand.x, brand.y, 28, TAB_H}, .Milk, th.accent_fg)
	text_box(a, a.style.font, brand.x + 38, brand.y, TAB_H, "Spoil", th.fg)

	places := build_places(a)
	y := sb.y + 2 - a.side_scroll
	in_milk := false
	start := y
	cur := is_search(cur_tab(a)) ? "" : cur_tab(a).dir
	for p, i in places {
		if p.milk && !in_milk {
			in_milk = true
			y += 12
			hr := tx.Rect{sb.x + 14, y, sb.w - 28, 1}
			if hr.y >= sb.y && hr.y < sb.y + sb.h { tx.canvas_fill_rect(cv, hr, mix(th.backdrop, th.muted, 0.3)) }
			y += 10
			glyph(a, a.style.icon_small, {sb.x + 8, y, 24, 22}, .Milk, th.sub, sb)
			text_box(a, a.style.font_bold, sb.x + 38, y, 22, "milk", th.sub, sb)
			y += 26
		}
		r := tx.Rect{sb.x, y, sb.w, SIDE_ROW_H}
		sel := p.path == cur
		hot := hovered(a, .Place, 0, i)
		target := a.drag.drop.kind == .Place && a.drag.drop.arg == i
		if r.y + r.h > sb.y && r.y < sb.y + sb.h {
			fill := tx.Color{}
			if sel { fill = th.accent } else if hot || target { fill = mix(th.backdrop, th.hover, 0.85) }
			if fill.a > 0 { fill_rounded_clipped(cv, r, f32(r.h) / 2, fill, sb) }
			if target && r.y >= sb.y && r.y + r.h <= sb.y + sb.h { stroke_rounded(cv, r, f32(r.h) / 2, 2, th.accent) }
			fg := sel ? th.accent_fg : th.fg
			icon_color := sel ? th.accent_fg : th.sub
			glyph(a, a.style.icon_small, {r.x + 10, r.y, 22, r.h}, place_icon(p.kind), icon_color, sb)
			label := tx.text_ellipsize(a.c, a.style.font, p.label, r.w - 52)
			text_box(a, a.style.font, r.x + 40, r.y, r.h, label, fg, sb)
			add_hit(a, r, .Place, 0, i, sb)
		}
		y += SIDE_ROW_H + 2
	}
	a.side_max = max(0, (y - start) - sb.h + 4)
	if a.side_scroll > a.side_max { a.side_scroll = a.side_max }
}

// ---------------------------------------------------------------------------
// Tab strip
// ---------------------------------------------------------------------------
TAB_PILL_H :: 28

// Width of each tab in pane `pi` (all tabs share the strip).
tab_width :: proc(a: ^App, pi: int, L: ^Layout) -> i32 {
	n := i32(len(a.panes[pi].tabs))
	avail := L.tabs.w - 2 * TAB_PILL_H - 10 // the "+" and the magnifier
	return clamp(avail / max(n, 1) - 4, 56, 210)
}

@(private)
draw_tabs :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	p := a.panes[pi]
	strip := L.tabs
	active_pane := pi == a.active_pane
	add_hit(a, strip, .Tab_Strip, pi)
	w := tab_width(a, pi, L)
	y := strip.y + (strip.h - TAB_PILL_H) / 2
	x := strip.x
	for t, i in p.tabs {
		r := tx.Rect{x, y, w, TAB_PILL_H}
		if r.x + r.w > strip.x + strip.w - 2 * TAB_PILL_H - 8 { break }
		x += w + 4
		dragged := a.drag.kind == .Tab && a.drag.pane == pi && a.drag.arg == i
		is_active := i == p.active
		hot := hovered(a, .Tab, pi, i) || hovered(a, .Tab_Close, pi, i)
		target := a.drag.drop.kind == .Tab && a.drag.drop.pane == pi && a.drag.drop.arg == i
		fg := th.sub
		switch {
		case is_active && active_pane:
			fill_rounded(cv, r, f32(r.h) / 2, th.accent)
			fg = th.accent_fg
		case is_active:
			fill_rounded(cv, r, f32(r.h) / 2, th.bg)
			stroke_rounded(cv, r, f32(r.h) / 2, 1, tx.color_with_alpha(th.muted, 70))
			fg = th.fg
		case hot || target:
			fill_rounded(cv, r, f32(r.h) / 2, mix(th.backdrop, th.hover, 0.85))
			fg = th.fg
		}
		if target { stroke_rounded(cv, r, f32(r.h) / 2, 2, th.accent) }
		if dragged {
			stroke_rounded(cv, r, f32(r.h) / 2, 1.5, tx.color_with_alpha(th.accent, 160))
			fg = th.muted
		}
		glyph(a, a.style.icon_small, {r.x + 8, r.y, 20, r.h}, tab_icon(t), fg)
		show_close := hot || is_active
		label_right := r.x + r.w - (show_close ? 28 : 12)
		label := tx.text_ellipsize(a.c, a.style.font_small, tab_label(a, t), label_right - (r.x + 32))
		text_box(a, a.style.font_small, r.x + 32, r.y, r.h, label, fg, r)
		add_hit(a, r, .Tab, pi, i)
		if show_close {
			xr := tx.Rect{r.x + r.w - 25, r.y + 4, 20, 20}
			if hovered(a, .Tab_Close, pi, i) {
				fill_rounded(cv, xr, 10, is_active && active_pane ? mix(th.accent, th.accent_fg, 0.25) : th.pressed)
			}
			glyph(a, a.style.icon_small, xr, .X, fg)
			add_hit(a, xr, .Tab_Close, pi, i)
		}
	}
	plus := tx.Rect{x, y, TAB_PILL_H, TAB_PILL_H}
	if hovered(a, .Tab_New, pi) { fill_rounded(cv, plus, f32(plus.h) / 2, mix(th.backdrop, th.hover, 0.85)) }
	glyph(a, a.style.icon_small, plus, .Plus, th.sub)
	add_hit(a, plus, .Tab_New, pi)
	// Search the whole disk (Ctrl+Shift+F).
	find := tx.Rect{plus.x + TAB_PILL_H + 2, y, TAB_PILL_H, TAB_PILL_H}
	if hovered(a, .Search_Tab, pi) { fill_rounded(cv, find, f32(find.h) / 2, mix(th.backdrop, th.hover, 0.85)) }
	glyph(a, a.style.icon_small, find, .Search, th.sub)
	add_hit(a, find, .Search_Tab, pi)
}

// ---------------------------------------------------------------------------
// Path bar
// ---------------------------------------------------------------------------
@(private)
icon_button :: proc(a: ^App, cv: ^tx.Canvas, r: tx.Rect, ic: Ic, action: Action, pi: int, enabled: bool, active := false) {
	th := &a.style.theme
	hot := enabled && hovered(a, action, pi)
	if active {
		fill_rounded(cv, r, f32(r.h) / 2, hot ? mix(th.accent, th.bg, 0.15) : th.accent)
	} else if hot {
		fill_rounded(cv, r, f32(r.h) / 2, th.hover)
	}
	color := th.fg
	if !enabled { color = mix(th.muted, th.bg, 0.35) }
	if active { color = th.accent_fg }
	glyph(a, a.style.icon, r, ic, color)
	if enabled { add_hit(a, r, action, pi) }
}

Crumb :: struct {
	label: string,
	path:  string,
	icon:  Ic,
	w:     i32,
	more:  bool, // the "…" stand-in for hidden crumbs
}

@(private)
build_crumbs :: proc(a: ^App, dir: string) -> [dynamic]Crumb {
	crumbs := make([dynamic]Crumb, context.temp_allocator)
	home := clean_path(home_dir())
	rest: string
	if dir == home || strings.has_prefix(dir, strings.concatenate({home, "/"}, context.temp_allocator)) {
		append(&crumbs, Crumb{label = tr(a, "Início", "Home"), path = home, icon = .Home})
		rest = dir[len(home):]
	} else {
		append(&crumbs, Crumb{label = "", path = "/", icon = .Server})
		rest = dir
	}
	acc := crumbs[0].path
	for part in strings.split(rest, "/", context.temp_allocator) {
		if part == "" { continue }
		acc = join({acc, part})
		append(&crumbs, Crumb{label = part, path = acc})
	}
	return crumbs
}

@(private)
crumb_width :: proc(a: ^App, cr: ^Crumb) -> i32 {
	w: i32 = 24
	if cr.label != "" { w += tw(a, a.style.font, cr.label) }
	if cr.icon != .None { w += cr.label != "" ? 22 : 12 }
	return w
}

CRUMB_SEP :: i32(18)

// The crumbs that fit in `avail` pixels: the first one, a "…" pill standing
// for the hidden middle ones, and as many trailing crumbs as fit.
layout_crumbs :: proc(a: ^App, dir: string, avail: i32) -> [dynamic]Crumb {
	crumbs := build_crumbs(a, dir)
	total: i32 = 0
	for &cr in crumbs {
		cr.w = crumb_width(a, &cr)
		total += cr.w
	}
	total += CRUMB_SEP * i32(len(crumbs) - 1)
	if total <= avail || len(crumbs) <= 2 { return crumbs }
	more := Crumb{label = "…", more = true}
	more.w = crumb_width(a, &more)
	last := len(crumbs) - 1
	budget := avail - crumbs[0].w - more.w - 2 * CRUMB_SEP
	used := crumbs[last].w
	keep_from := last
	for k := last - 1; k >= 1; k -= 1 {
		if used + CRUMB_SEP + crumbs[k].w > budget { break }
		used += CRUMB_SEP + crumbs[k].w
		keep_from = k
	}
	if keep_from <= 1 { return crumbs }
	more.path = crumbs[keep_from - 1].path
	out := make([dynamic]Crumb, context.temp_allocator)
	append(&out, crumbs[0], more)
	append(&out, ..crumbs[keep_from:])
	return out
}

// The grid/list switch ending at `right`; returns its left edge.
@(private)
draw_view_switch :: proc(a: ^App, cv: ^tx.Canvas, pi: int, t: ^Tab, right, cy, ph: i32) -> i32 {
	th := &a.style.theme
	seg_w := ph + 6
	seg := tx.Rect{right - 2 * seg_w - 4, cy, 2 * seg_w + 4, ph}
	fill_rounded(cv, seg, f32(ph) / 2, th.field)
	for i in 0 ..< 2 {
		r := tx.Rect{seg.x + 2 + i32(i) * seg_w, cy + 2, seg_w, ph - 4}
		action := i == 0 ? Action.View_Grid : Action.View_List
		sel := (i == 0) == (t.mode == .Grid)
		if sel {
			fill_rounded(cv, r, f32(r.h) / 2, th.accent)
		} else if hovered(a, action, pi) {
			fill_rounded(cv, r, f32(r.h) / 2, th.hover)
		}
		glyph(a, a.style.icon_small, r, i == 0 ? .Grid : .List, sel ? th.accent_fg : th.fg)
		add_hit(a, r, action, pi)
	}
	return seg.x
}

// A search tab's bar: the query field (the whole width), Reindexar, the
// view switch and the hidden-files toggle.
@(private)
draw_search_toolbar :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	t := pane_tab(a, pi)
	p := a.panes[pi]
	tb := L.toolbar
	ph := a.style.pill_h
	cy := tb.y + (tb.h - ph) / 2
	pad := max(6, (tb.h - ph) / 2 + 2)
	x := tb.x + pad
	right := tb.x + tb.w - pad
	icon_button(a, cv, {right - ph, cy, ph, ph}, t.show_hidden ? .Eye : .Eye_Off, .Hidden, pi, true, t.show_hidden)
	right -= ph + 8
	if tb.w >= 470 { right = draw_view_switch(a, cv, pi, t, right, cy, ph) - 10 }
	indexing, _ := search_indexing(a)
	icon_button(a, cv, {right - ph, cy, ph, ph}, indexing ? .Hourglass : .Refresh, .Reindex, pi, !indexing)
	right -= ph + 8
	area := tx.Rect{x, cy, right - x, ph}
	if area.w < 60 { return }
	if a.focus == .Path && pi == a.active_pane {
		draw_field(a, cv, area, 0, 0, &p.path_field, "", true, .Folder_Open, .Path_Field, pi)
		return
	}
	info := search_index_info(a)
	placeholder := tr(a, "Buscar em todo o disco", "Search the whole disk")
	if info.ready {
		placeholder = fmt.tprintf(tr(a, "Buscar em todo o disco (%s itens)", "Search the whole disk (%s items)"), format_count(a, info.count))
	}
	draw_field(a, cv, area, 0, 0, &t.search, placeholder, a.focus == .Search && pi == a.active_pane, .Search, .Search, pi)
	if field_text(&t.search) != "" {
		xr := tx.Rect{area.x + area.w - ph + 2, cy + 2, ph - 4, ph - 4}
		if hovered(a, .Clear_Search, pi) { fill_rounded(cv, xr, f32(xr.h) / 2, th.hover) }
		glyph(a, a.style.icon_small, xr, .X, th.sub)
		add_hit(a, xr, .Clear_Search, pi)
	}
}

@(private)
draw_toolbar :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	t := pane_tab(a, pi)
	p := a.panes[pi]
	if is_search(t) {
		draw_search_toolbar(a, cv, pi, L)
		return
	}
	tb := L.toolbar
	ph := a.style.pill_h
	cy := tb.y + (tb.h - ph) / 2
	pad := max(6, (tb.h - ph) / 2 + 2)
	x := tb.x + pad
	icon_button(a, cv, {x, cy, ph, ph}, .Arrow_Left, .Back, pi, len(t.back_stack) > 0)
	x += ph + 2
	icon_button(a, cv, {x, cy, ph, ph}, .Arrow_Right, .Forward, pi, len(t.fwd_stack) > 0)
	x += ph + 2
	icon_button(a, cv, {x, cy, ph, ph}, .Arrow_Up, .Up, pi, t.dir != "/")
	x += ph + 12

	right := tb.x + tb.w - pad
	// Hidden files toggle.
	icon_button(a, cv, {right - ph, cy, ph, ph}, t.show_hidden ? .Eye : .Eye_Off, .Hidden, pi, true, t.show_hidden)
	right -= ph + 8
	// Narrow panes drop the view switch, then the search field (keys still work).
	show_seg := tb.w >= 470
	show_search := tb.w >= 330 || (a.focus == .Search && pi == a.active_pane)
	if show_seg { right = draw_view_switch(a, cv, pi, t, right, cy, ph) - 10 }
	if show_search {
		sw := clamp(tb.w / 4, 110, 250)
		sr := tx.Rect{right - sw, cy, sw, ph}
		focused := a.focus == .Search && pi == a.active_pane
		draw_field(a, cv, sr, 0, 0, &t.search, tr(a, "Filtrar esta pasta", "Filter this folder"), focused, .Search, .Search, pi)
		if field_text(&t.search) != "" {
			xr := tx.Rect{sr.x + sr.w - ph + 2, cy + 2, ph - 4, ph - 4}
			if hovered(a, .Clear_Search, pi) { fill_rounded(cv, xr, f32(xr.h) / 2, th.hover) }
			glyph(a, a.style.icon_small, xr, .X, th.sub)
			add_hit(a, xr, .Clear_Search, pi)
		}
		right = sr.x - 10
	}

	area := tx.Rect{x, cy, right - x, ph}
	if area.w < 30 { return }
	if a.focus == .Path && pi == a.active_pane {
		draw_field(a, cv, area, 0, 0, &p.path_field, "", true, .Folder_Open, .Path_Field, pi)
		return
	}
	add_hit(a, area, .Crumb_Bar, pi)
	crumbs := layout_crumbs(a, t.dir, area.w)
	list := &a.crumbs[pi]
	for s in list { delete(s) }
	clear(list)
	for cr in crumbs { append(list, strings.clone(cr.path)) }
	cx := area.x
	for &cr, i in crumbs {
		last := i == len(crumbs) - 1
		w := min(cr.w, area.x + area.w - cx)
		if w < 24 { break }
		r := tx.Rect{cx, cy, w, ph}
		hot := hovered(a, .Crumb, pi, i)
		if last {
			fill_rounded(cv, r, f32(ph) / 2, pi == a.active_pane ? th.accent : mix(th.accent, th.bg, 0.55))
		} else if hot {
			fill_rounded(cv, r, f32(ph) / 2, th.hover)
		}
		fg := last ? th.accent_fg : th.fg
		tx0 := r.x + 12
		if cr.icon != .None {
			glyph(a, a.style.icon_small, {tx0 - 2, r.y, 20, r.h}, cr.icon, fg)
			tx0 += cr.label != "" ? 22 : 16
		}
		if cr.label != "" {
			label := tx.text_ellipsize(a.c, a.style.font, cr.label, r.x + r.w - 12 - tx0)
			text_box(a, a.style.font, tx0, r.y, r.h, label, fg)
		}
		if !last { add_hit(a, r, .Crumb, pi, i) }
		cx += w
		if !last {
			glyph(a, a.style.icon_small, {cx, cy, CRUMB_SEP, ph}, .Chevron_Right, th.muted)
			cx += CRUMB_SEP
		}
	}
}

// ---------------------------------------------------------------------------
// File view
// ---------------------------------------------------------------------------
@(private)
draw_content :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	t := pane_tab(a, pi)
	area := L.area
	if a.panes[pi].viewer.kind == .Viewer {
		draw_viewer_header(a, cv, pi, L) // the file itself is drawn by mpv in its window
		return
	}
	if t.mode == .List { draw_list_header(a, cv, pi, L) }
	drop_here := a.drag.drop.kind == .Pane && a.drag.drop.pane == pi
	if drop_here { stroke_rounded(cv, L.card, f32(a.style.radius), 2, th.accent) }
	if len(t.view) == 0 {
		draw_empty_state(a, cv, t, L)
		add_hit(a, area, .Empty, pi)
		return
	}
	// Items are drawn on a canvas the size of the area (clipping for free),
	// then copied into the frame.
	sub := tx.canvas_make(area.w, area.h, context.temp_allocator)
	tx.canvas_fill(&sub, th.bg)
	add_hit(a, area, .Empty, pi)
	a.sub_origin = {area.x, area.y}
	a.sub_clip = area
	scroll := i32(math.round(t.scroll))
	if t.mode == .Grid {
		first_row := max(0, int((scroll - 4) / L.cell_h))
		last_row := int((scroll + area.h) / L.cell_h) + 1
		for row in first_row ..= last_row {
			for col in 0 ..< L.cols {
				vi := row * L.cols + col
				if vi >= len(t.view) { break }
				r := item_rect(t, L, vi)
				r.y -= scroll
				draw_grid_item(a, &sub, pi, t, L, vi, r)
			}
		}
	} else {
		first := max(0, int((scroll - 4) / L.row_h))
		last := min(len(t.view) - 1, int((scroll + area.h) / L.row_h) + 1)
		for vi in first ..= last {
			r := item_rect(t, L, vi)
			r.y -= scroll
			draw_list_item(a, &sub, pi, t, L, vi, r)
		}
	}
	if a.drag.kind == .Band && a.drag.pane == pi {
		b := band_rect(a, t)
		b.y -= scroll
		fill_rounded(&sub, b, 3, tx.color_with_alpha(th.accent, 40))
		stroke_rounded(&sub, b, 3, 1, tx.color_with_alpha(th.accent, 200))
	}
	draw_scrollbar(a, &sub, pi, t, L)
	blit_canvas(cv, &sub, area.x, area.y)
}

@(private)
draw_empty_state :: proc(a: ^App, cv: ^tx.Canvas, t: ^Tab, L: ^Layout) {
	th := &a.style.theme
	area := L.area
	ic := Ic.Folder_Open
	title := tr(a, "Pasta vazia", "Empty folder")
	sub := ""
	if is_search(t) {
		ic, title, sub = search_empty_state(a, t)
	} else if filter := field_text(&t.search); filter != "" {
		ic = .Search
		title = tr(a, "Nada encontrado", "Nothing found")
		sub = fmt.tprintf(tr(a, "Nenhum item corresponde a “%s”.", "No item matches “%s”."), filter)
	} else if hc := hidden_count(t); hc > 0 && !t.show_hidden {
		sub = fmt.tprintf(tr(a, "%d itens ocultos (Ctrl+H para mostrar)", "%d hidden items (Ctrl+H to show)"), hc)
	}
	cy := area.y + area.h / 2 - 50
	circle := tx.Rect{area.x + area.w / 2 - 40, cy - 40, 80, 80}
	fill_rounded(cv, circle, 40, th.field)
	glyph(a, a.style.icon_big, circle, ic, th.muted)
	text_centered(a, a.style.font, {area.x, cy + 52, area.w, 24}, tx.text_ellipsize(a.c, a.style.font, title, area.w - 20), th.fg, area)
	if sub != "" {
		text_centered(a, a.style.font_tiny, {area.x, cy + 78, area.w, 20},
		              tx.text_ellipsize(a.c, a.style.font_tiny, sub, area.w - 40), th.sub, area)
	}
}

@(private)
draw_list_header :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	hr := L.header
	f := a.style.font_tiny
	name_x := hr.x + 12 + LIST_ICON + 10
	if t := pane_tab(a, pi); is_search(t) {
		draw_search_header(a, cv, pi, t, L)
	} else {
		text_box(a, f, name_x, hr.y, hr.h, tr(a, "Nome", "Name"), th.sub, hr)
		size_label := tr(a, "Tamanho", "Size")
		text_box(a, f, L.area.x + L.col_size - tw(a, f, size_label), hr.y, hr.h, size_label, th.sub, hr)
		if L.col_date < L.area.w {
			text_box(a, f, L.area.x + L.col_date, hr.y, hr.h, tr(a, "Modificado", "Modified"), th.sub, hr)
		}
	}
	tx.canvas_fill_rect(cv, {hr.x + 8, hr.y + hr.h, hr.w - 16, 1}, mix(th.bg, th.muted, 0.18))
}

// A search tab's column titles: a click sorts by the column (again: the
// other way round); the sorted one carries an arrow.
@(private)
draw_search_header :: proc(a: ^App, cv: ^tx.Canvas, pi: int, t: ^Tab, L: ^Layout) {
	th := &a.style.theme
	hr := L.header
	f := a.style.font_tiny
	ax := L.area.x
	Column :: struct {
		sort:   Search_Sort,
		label:  string,
		x0, x1: i32, // the clickable span
		text_x: i32, // left edge of the title (right edge for right-aligned ones)
		right:  bool,
	}
	cols := make([dynamic]Column, context.temp_allocator)
	name_end := L.col_path < L.area.w ? L.col_path - 8 : L.col_size - 96
	append(&cols, Column{.Name, tr(a, "Nome", "Name"), ax + 4, ax + name_end, ax + 12 + LIST_ICON + 10, false})
	if L.col_path < L.area.w {
		append(&cols, Column{.Path, tr(a, "Pasta", "Folder"), ax + L.col_path - 8, ax + L.col_size - 96, ax + L.col_path, false})
	}
	append(&cols, Column{.Size, tr(a, "Tamanho", "Size"), ax + L.col_size - 92, ax + L.col_size + 8, ax + L.col_size, true})
	if L.col_date < L.area.w {
		append(&cols, Column{.Date, tr(a, "Modificado", "Modified"), ax + L.col_date - 8, hr.x + hr.w - 4, ax + L.col_date, false})
	}
	arrow := t.find.desc ? Ic.Chevron_Down : Ic.Chevron_Up
	for c in cols {
		r := tx.Rect{c.x0, hr.y + 3, max(c.x1 - c.x0, 1), hr.h - 6}
		active := t.find.sort == c.sort
		if hovered(a, .Sort_Column, pi, int(c.sort)) { fill_rounded(cv, r, f32(r.h) / 2, th.hover) }
		color := active ? th.fg : th.sub
		lw := tw(a, f, c.label)
		lx := c.right ? c.text_x - lw : c.text_x
		text_box(a, f, lx, hr.y, hr.h, c.label, color, hr)
		if active {
			ax0 := c.right ? lx - 18 : lx + lw + 2
			glyph(a, a.style.icon_small, {ax0, hr.y, 16, hr.h}, arrow, th.accent, hr)
		}
		add_hit(a, r, .Sort_Column, pi, int(c.sort))
	}
}

// Item highlight: selection (tonal accent), hover (surface), keyboard cursor
// (outline), drop target (accent ring).
@(private)
item_highlight :: proc(a: ^App, cv: ^tx.Canvas, r: tx.Rect, radius: f32, pi: int, t: ^Tab, vi: int, e: ^Entry) {
	th := &a.style.theme
	hot := hovered(a, .Item, pi, vi) && a.drag.kind == .None
	target := a.drag.drop.kind == .Folder && a.drag.drop.pane == pi && a.drag.drop.arg == vi
	if e.selected {
		fill_rounded(cv, r, radius, hot ? mix(th.select, th.accent, 0.08) : th.select)
		stroke_rounded(cv, r, radius, 1, tx.color_with_alpha(th.accent, th.dark ? 110 : 90))
	} else if hot || target {
		fill_rounded(cv, r, radius, target ? mix(th.bg, th.accent, 0.18) : th.hover)
	}
	if target { stroke_rounded(cv, r, radius, 2, th.accent) }
	if vi == t.cursor && a.has_focus && a.focus == .View && pi == a.active_pane && !e.selected && !target {
		stroke_rounded(cv, r, radius, 1.5, tx.color_with_alpha(th.accent, 140))
	}
}

// Split a name into at most two centred lines (the second ellipsised).
@(private)
wrap_two :: proc(a: ^App, f: ^tx.Font, s: string, max_w: i32) -> (l1, l2: string) {
	if tw(a, f, s) <= max_w { return s, "" }
	// Longest prefix (in runes) that fits, found by bisection.
	offsets := make([dynamic]int, context.temp_allocator)
	for _, i in s { append(&offsets, i) }
	append(&offsets, len(s))
	lo, hi := 1, len(offsets) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if tw(a, f, s[:offsets[mid]]) <= max_w { lo = mid } else { hi = mid - 1 }
	}
	cut := offsets[lo]
	// Prefer breaking after a space, dash, underscore or dot in the second half.
	best := -1
	for k := lo; k > lo / 2 && k > 0; k -= 1 {
		ch := s[offsets[k] - 1]
		if ch == ' ' || ch == '-' || ch == '_' || ch == '.' {
			best = offsets[k]
			break
		}
	}
	if best > 0 { cut = best }
	l1 = strings.trim_right_space(s[:cut])
	rest := strings.trim_left_space(s[cut:])
	l2 = tx.text_ellipsize(a.c, f, rest, max_w)
	return
}

@(private)
opaque_corners :: proc(img: tx.Image) -> bool {
	if img.w < 2 || img.h < 2 || len(img.rgba) < int(img.w * img.h * 4) { return false }
	last_row := int(img.h - 1) * int(img.w)
	for p in ([4]int{0, int(img.w) - 1, last_row, last_row + int(img.w) - 1}) {
		if img.rgba[p * 4 + 3] < 250 { return false }
	}
	return true
}

// Glyphs inside the item canvas: boxes are canvas-local; the canvas origin
// (a.sub_origin) turns them into window coordinates for Xft.
@(private)
glyph_local :: proc(a: ^App, f: ^tx.Font, box: tx.Rect, ic: Ic, color: tx.Color) {
	o := a.sub_origin
	glyph(a, f, {box.x + o.x, box.y + o.y, box.w, box.h}, ic, color, a.sub_clip)
}

draw_entry_icon :: proc(a: ^App, cv: ^tx.Canvas, dir: string, e: ^Entry, box: tx.Rect, size: Icon_Size, local := true) {
	th := &a.style.theme
	folder := e.dir != "" ? e.dir : dir // search results carry their folder
	opacity: f32 = e.unreadable ? 0.45 : (e.hidden ? 0.7 : 1)
	if img, ok := entry_thumb(a, folder, e, size); ok {
		x := box.x + (box.w - img.w) / 2
		y := box.y + (box.h - img.h) / 2
		radius: f32 = size == .Grid ? 6 : 3
		blit_rounded(cv, img, x, y, radius, opacity)
		// Photos get a faint frame; pictures with transparency (icons, logos) do not.
		if opaque_corners(img) { stroke_rounded(cv, {x, y, img.w, img.h}, radius, 1, tx.color_with_alpha(th.fg, 28)) }
		return
	}
	if img, ok := entry_icon(a, folder, e, size); ok {
		tx.canvas_blit_image(cv, img, box.x + (box.w - img.w) / 2, box.y + (box.h - img.h) / 2, opacity)
		return
	}
	// No theme icon: a Tabler glyph.
	f := size == .Grid ? a.style.icon_big : a.style.icon_small
	color := e.kind == .Folder ? th.accent : th.sub
	if e.unreadable { color = th.dim }
	if local {
		glyph_local(a, f, box, kind_glyph(e.kind), color)
	} else {
		glyph(a, f, box, kind_glyph(e.kind), color)
	}
}

@(private)
draw_grid_item :: proc(a: ^App, cv: ^tx.Canvas, pi: int, t: ^Tab, L: ^Layout, vi: int, r: tx.Rect) {
	th := &a.style.theme
	e := &t.entries[t.view[vi]]
	area := L.area
	hl := tx.Rect{r.x + 4, r.y + 2, r.w - 8, r.h - 4}
	item_highlight(a, cv, hl, 14, pi, t, vi, e)
	box := tx.Rect{r.x + (r.w - GRID_BOX) / 2, r.y + 10, GRID_BOX, GRID_BOX}
	draw_entry_icon(a, cv, t.dir, e, box, .Grid)
	if e.is_link && e.kind != .Broken {
		// A small arrow badge for links.
		bc := tx.Rect{box.x + box.w - 18, box.y + box.h - 18, 18, 18}
		fill_rounded(cv, bc, 9, th.bg)
		fill_rounded(cv, {bc.x + 2, bc.y + 2, 14, 14}, 7, th.field)
		glyph_local(a, a.style.icon_small, bc, .External, th.sub)
	}
	f := a.style.font_small
	lh := line_height(f)
	label_y := box.y + box.h + 8
	max_w := r.w - 16
	color := e.unreadable ? th.dim : th.fg
	ox, oy := area.x, area.y
	if renaming(a, pi, t, vi, e) {
		fr := tx.Rect{r.x + 6, label_y - 4, r.w - 12, lh + 8}
		draw_field(a, cv, fr, ox, oy, &a.rename, "", true, .None, .Rename_Field, pi, area)
	} else {
		l1, l2 := wrap_two(a, f, e.name, max_w)
		w1 := tw(a, f, l1)
		append(&a.texts, Text_Item{font = f, x = ox + r.x + (r.w - w1) / 2, baseline = oy + label_y + f.ascent, s = l1, color = color, clip = area})
		if l2 != "" {
			w2 := tw(a, f, l2)
			append(&a.texts, Text_Item{font = f, x = ox + r.x + (r.w - w2) / 2, baseline = oy + label_y + lh + f.ascent, s = l2, color = color, clip = area})
		}
	}
	add_hit(a, {ox + hl.x, oy + hl.y, hl.w, hl.h}, .Item, pi, vi, area)
}

@(private)
draw_list_item :: proc(a: ^App, cv: ^tx.Canvas, pi: int, t: ^Tab, L: ^Layout, vi: int, r: tx.Rect) {
	th := &a.style.theme
	e := &t.entries[t.view[vi]]
	area := L.area
	hl := tx.Rect{r.x + 4, r.y + 1, r.w - 8, r.h - 2}
	item_highlight(a, cv, hl, f32(hl.h) / 2, pi, t, vi, e)
	box := tx.Rect{r.x + 12, r.y + (r.h - LIST_ICON) / 2, LIST_ICON, LIST_ICON}
	draw_entry_icon(a, cv, t.dir, e, box, .List)
	ox, oy := area.x, area.y
	name_x := box.x + LIST_ICON + 10
	name_w := L.col_size - 100 - name_x
	if L.col_date >= L.area.w { name_w = L.col_size - 90 - name_x }
	with_path := is_search(t) && L.col_path < L.area.w
	if with_path { name_w = L.col_path - 16 - name_x }
	color := e.unreadable ? th.dim : th.fg
	if renaming(a, pi, t, vi, e) {
		fr := tx.Rect{name_x - 8, r.y + 2, max(name_w + 8, 120), r.h - 4}
		draw_field(a, cv, fr, ox, oy, &a.rename, "", true, .None, .Rename_Field, pi, area)
	} else {
		name := tx.text_ellipsize(a.c, a.style.font, e.name, name_w)
		text_box(a, a.style.font, ox + name_x, oy + r.y, r.h, name, color, area)
	}
	f := a.style.font_tiny
	if with_path {
		folder := ellipsize_left(a, f, display_dir(e.dir), L.col_size - 100 - L.col_path)
		text_box(a, f, ox + L.col_path, oy + r.y, r.h, folder, th.sub, area)
	}
	size := e.is_dir || e.kind == .Broken ? "—" : (e.pending ? "…" : format_size(a, e.size))
	text_box(a, f, ox + L.col_size - tw(a, f, size), oy + r.y, r.h, size, th.sub, area)
	if L.col_date < L.area.w && !e.pending {
		text_box(a, f, ox + L.col_date, oy + r.y, r.h, format_date(a, e.mtime), th.sub, area)
	}
	add_hit(a, {ox + hl.x, oy + hl.y, hl.w, hl.h}, .Item, pi, vi, area)
}

// Is view item `vi` the one being renamed? (Search results can share names.)
@(private)
renaming :: proc(a: ^App, pi: int, t: ^Tab, vi: int, e: ^Entry) -> bool {
	if a.focus != .Rename || pi != a.active_pane || a.rename_name != e.name { return false }
	return !is_search(t) || t.view[vi] == a.rename_index
}

// Thin rounded thumb along the right edge (area coordinates).
scrollbar_rect :: proc(t: ^Tab, L: ^Layout) -> (track, thumb: tx.Rect, ok: bool) {
	m := max_scroll(L)
	if m <= 0 { return }
	area := L.area
	track = {area.w - 12, 4, 12, area.h - 8}
	th_h := max(i32(28), i32(f32(track.h) * f32(area.h) / f32(L.content_h)))
	pos := i32(f32(track.h - th_h) * clamp(t.scroll / m, 0, 1))
	thumb = {track.x + 4, track.y + pos, 5, th_h}
	return track, thumb, true
}

@(private)
draw_scrollbar :: proc(a: ^App, cv: ^tx.Canvas, pi: int, t: ^Tab, L: ^Layout) {
	th := &a.style.theme
	track, thumb, ok := scrollbar_rect(t, L)
	if !ok { return }
	hot := (a.drag.kind == .Scrollbar && a.drag.pane == pi) || hovered(a, .Scrollbar, pi)
	if hot { thumb = {thumb.x - 1, thumb.y, thumb.w + 2, thumb.h} }
	fill_rounded(cv, thumb, f32(thumb.w) / 2, tx.color_with_alpha(th.muted, hot ? 220 : 120))
	add_hit(a, {L.area.x + track.x, L.area.y + track.y, track.w, track.h}, .Scrollbar, pi, 0, L.area)
}

// ---------------------------------------------------------------------------
// Status line
// ---------------------------------------------------------------------------
@(private)
draw_status :: proc(a: ^App, cv: ^tx.Canvas, pi: int, L: ^Layout) {
	th := &a.style.theme
	t := pane_tab(a, pi)
	st := L.status
	f := a.style.font_tiny
	x := st.x + 18
	right := st.x + st.w - 18
	s_left, s_right: string
	s_indexing: bool
	if is_search(t) { s_left, s_right, s_indexing = search_status(a, t) }
	// Background jobs (copies, moves, archives): a turning arc and a label.
	if len(a.jobs) > 0 && pi == len(a.panes) - 1 {
		label := jobs_label(a)
		w := tw(a, f, label)
		text_box(a, f, right - w, st.y, st.h, label, th.fg, st)
		phase := f32(tx.now() * 1.2)
		spinner(cv, f32(right - w - 14), f32(st.y + st.h / 2), 6, 2.2, phase - f32(i64(phase)), th.accent, tx.color_with_alpha(th.muted, 60))
		right -= w + 30
	} else if is_search(t) {
		// The index: its age, or the walk going on.
		if s_right != "" && st.w > 320 {
			w := tw(a, f, s_right)
			text_box(a, f, right - w, st.y, st.h, s_right, s_indexing ? th.fg : th.sub, st)
			if s_indexing { glyph(a, a.style.icon_small, {right - w - 22, st.y, 18, st.h}, .Hourglass, th.accent, st) }
			right -= w + (s_indexing ? 38 : 16)
		}
	} else if t.has_free && st.w > 320 {
		free := fmt.tprintf(tr(a, "%s livres", "%s free"), format_size(a, t.free_bytes))
		w := tw(a, f, free)
		text_box(a, f, right - w, st.y, st.h, free, th.sub, st)
		right -= w + 16
	}
	avail := right - x
	if a.notice != "" && pi == a.active_pane {
		ic := a.notice_warn ? Ic.Alert : Ic.Check
		color := a.notice_warn ? th.warning : th.accent
		label := tx.text_ellipsize(a.c, f, a.notice, avail - 40)
		pill := tx.Rect{x - 8, st.y + 5, tw(a, f, label) + 40, st.h - 10}
		fill_rounded(cv, pill, f32(pill.h) / 2, mix(th.bg, color, th.dark ? 0.16 : 0.12))
		glyph(a, a.style.icon_small, {pill.x + 6, pill.y, 20, pill.h}, ic, color)
		text_box(a, f, pill.x + 30, pill.y, pill.h, label, th.fg)
		return
	}
	if is_search(t) {
		text_box(a, f, x, st.y, st.h, tx.text_ellipsize(a.c, f, s_left, avail), th.sub, st)
		return
	}
	count, bytes, files := selection_stats(t)
	text: string
	n := len(t.view)
	switch {
	case count > 0 && files > 0:
		text = fmt.tprintf(tr(a, "%d de %d selecionados · %s", "%d of %d selected · %s"), count, n, format_size(a, bytes))
	case count > 0:
		text = fmt.tprintf(tr(a, "%d de %d selecionados", "%d of %d selected"), count, n)
	case n == 1:
		text = tr(a, "1 item", "1 item")
	case:
		text = fmt.tprintf(tr(a, "%d itens", "%d items"), n)
	}
	if hc := hidden_count(t); hc > 0 && !t.show_hidden && count == 0 {
		text = fmt.tprintf(tr(a, "%s · %d ocultos", "%s · %d hidden"), text, hc)
	}
	text_box(a, f, x, st.y, st.h, tx.text_ellipsize(a.c, f, text, avail), th.sub, st)
}

// ---------------------------------------------------------------------------
// Dividers and drag feedback
// ---------------------------------------------------------------------------
@(private)
draw_dividers :: proc(a: ^App, cv: ^tx.Canvas) {
	th := &a.style.theme
	cols, n := pane_columns(a)
	for i in 0 ..< n - 1 {
		r := tx.Rect{cols[i].x + cols[i].w, cols[i].y + TAB_H + TAB_GAP, MARGIN, cols[i].h - TAB_H - TAB_GAP}
		hot := hovered(a, .Divider, i) || (a.drag.kind == .Divider && a.drag.arg == i)
		if hot {
			grip := tx.Rect{r.x + r.w / 2 - 2, r.y + r.h / 2 - 24, 4, 48}
			fill_rounded(cv, grip, 2, th.accent)
		}
		add_hit(a, r, .Divider, 0, i)
	}
}

@(private)
draw_drag_overlay :: proc(a: ^App, cv: ^tx.Canvas) {
	th := &a.style.theme
	d := &a.drag
	#partial switch d.kind {
	case .Tab:
		// Where the tab will land: another pane, or a new pane at an edge.
		cols, _ := pane_columns(a)
		#partial switch d.drop.kind {
		case .Pane:
			col := cols[d.drop.pane]
			fill_rounded(cv, col, f32(a.style.radius), tx.color_with_alpha(th.accent, 34))
			stroke_rounded(cv, col, f32(a.style.radius), 2, th.accent)
		case .New_Pane:
			col := d.drop.arg == 0 ? cols[0] : cols[len(a.panes) - 1]
			w := col.w / 3
			r := d.drop.arg == 0 ? tx.Rect{col.x, col.y, w, col.h} : tx.Rect{col.x + col.w - w, col.y, w, col.h}
			fill_rounded(cv, r, f32(a.style.radius), tx.color_with_alpha(th.accent, 48))
			stroke_rounded(cv, r, f32(a.style.radius), 2, th.accent)
		}
		// The tab itself under the pointer.
		if d.pane >= 0 && d.pane < len(a.panes) && d.arg >= 0 && d.arg < len(a.panes[d.pane].tabs) {
			t := a.panes[d.pane].tabs[d.arg]
			label := tx.text_ellipsize(a.c, a.style.font_small, tab_label(a, t), 150)
			w := tw(a, a.style.font_small, label) + 46
			r := tx.Rect{a.pointer.x - w / 2, a.pointer.y - TAB_PILL_H / 2, w, TAB_PILL_H}
			soft_shadow(cv, r, f32(r.h) / 2, 8, th.dark ? 0.4 : 0.14, 2)
			fill_rounded(cv, r, f32(r.h) / 2, th.accent)
			glyph(a, a.style.icon_small, {r.x + 8, r.y, 20, r.h}, tab_icon(t), th.accent_fg)
			text_box(a, a.style.font_small, r.x + 32, r.y, r.h, label, th.accent_fg)
		}
	case .Files:
		if len(d.paths) == 0 { return }
		// A ghost card: the first item's icon, a count badge, and the operation.
		card := tx.Rect{a.pointer.x + 12, a.pointer.y + 10, 64, 64}
		soft_shadow(cv, card, 14, 10, th.dark ? 0.45 : 0.16, 3)
		fill_rounded(cv, card, 14, th.bg)
		stroke_rounded(cv, card, 14, 1, tx.color_with_alpha(th.muted, 90))
		if d.ghost_ok {
			tmp := d.ghost
			draw_entry_icon(a, cv, d.src_dir, &tmp, {card.x + 8, card.y + 8, 48, 48}, .Grid, false)
		}
		if len(d.paths) > 1 {
			label := fmt.tprintf("%d", len(d.paths))
			bw := max(22, tw(a, a.style.font_tiny, label) + 12)
			badge := tx.Rect{card.x + card.w - bw + 6, card.y - 8, bw, 22}
			fill_rounded(cv, badge, 11, th.accent)
			text_centered(a, a.style.font_tiny, badge, label, th.accent_fg)
		}
		if d.drop.kind != .None {
			op := drag_op(a) == .Copy ? tr(a, "Copiar", "Copy") : tr(a, "Mover", "Move")
			ow := tw(a, a.style.font_tiny, op) + 20
			pill := tx.Rect{card.x + (card.w - ow) / 2, card.y + card.h + 6, ow, 22}
			fill_rounded(cv, pill, 11, th.accent)
			text_centered(a, a.style.font_tiny, pill, op, th.accent_fg)
		}
	}
}
