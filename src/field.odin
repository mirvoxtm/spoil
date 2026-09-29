// One-line text fields (search, path, rename, new folder): UTF-8 buffer,
// caret and selection, and the milk look (a rounded pill with an accent
// outline when focused). Keys arrive already composed by the X input method
// (tx.input_lookup), so dead keys work: ´ + a = á.
package spoil

import "core:strings"
import "core:unicode/utf8"
import tx "milk:tx"

Field :: struct {
	buf:      [dynamic]u8,
	caret:    int, // byte offset
	anchor:   int, // selection anchor (== caret: no selection)
	scroll_x: i32,
	area_x:   i32, // where the text started at the last draw (window coordinates)
}

field_destroy :: proc(f: ^Field) {
	delete(f.buf)
	f^ = {}
}

field_text :: proc(f: ^Field) -> string { return string(f.buf[:]) }

field_set :: proc(f: ^Field, s: string) {
	clear(&f.buf)
	append(&f.buf, ..transmute([]u8)s)
	f.caret = len(f.buf)
	f.anchor = f.caret
	f.scroll_x = 0
}

field_clear :: proc(f: ^Field) { field_set(f, "") }

field_select :: proc(f: ^Field, from, to: int) {
	f.anchor = clamp(from, 0, len(f.buf))
	f.caret = clamp(to, 0, len(f.buf))
}

field_select_all :: proc(f: ^Field) { field_select(f, 0, len(f.buf)) }

field_has_selection :: proc(f: ^Field) -> bool { return f.anchor != f.caret }

field_selection :: proc(f: ^Field) -> (lo, hi: int) {
	return min(f.anchor, f.caret), max(f.anchor, f.caret)
}

@(private)
field_delete_selection :: proc(f: ^Field) -> bool {
	if !field_has_selection(f) { return false }
	lo, hi := field_selection(f)
	remove_range(&f.buf, lo, hi)
	f.caret, f.anchor = lo, lo
	return true
}

field_insert :: proc(f: ^Field, s: string) {
	field_delete_selection(f)
	inject_at(&f.buf, f.caret, ..transmute([]u8)s)
	f.caret += len(s)
	f.anchor = f.caret
}

@(private)
prev_boundary :: proc(f: ^Field, pos: int) -> int {
	p := pos - 1
	for p > 0 && (f.buf[p] & 0xC0) == 0x80 { p -= 1 }
	return max(p, 0)
}

@(private)
next_boundary :: proc(f: ^Field, pos: int) -> int {
	if pos >= len(f.buf) { return len(f.buf) }
	_, n := utf8.decode_rune(f.buf[pos:])
	return pos + max(n, 1)
}

@(private)
is_word_byte :: proc(ch: u8) -> bool {
	return ch >= 0x80 || (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private)
word_left :: proc(f: ^Field, pos: int) -> int {
	p := pos
	for p > 0 && !is_word_byte(f.buf[p - 1]) { p = prev_boundary(f, p) }
	for p > 0 && is_word_byte(f.buf[p - 1]) { p = prev_boundary(f, p) }
	return p
}

@(private)
word_right :: proc(f: ^Field, pos: int) -> int {
	p := pos
	for p < len(f.buf) && !is_word_byte(f.buf[p]) { p = next_boundary(f, p) }
	for p < len(f.buf) && is_word_byte(f.buf[p]) { p = next_boundary(f, p) }
	return p
}

// Editing keys; returns true when the key was used. `text` is the composed
// input (already filtered to printable characters).
field_key :: proc(f: ^Field, ks: uint, text: string, ctrl, shift: bool) -> bool {
	move :: proc(f: ^Field, to: int, shift: bool) {
		f.caret = clamp(to, 0, len(f.buf))
		if !shift { f.anchor = f.caret }
	}
	switch ks {
	case KS_BACKSPACE:
		if field_delete_selection(f) { return true }
		if f.caret == 0 { return true }
		from := ctrl ? word_left(f, f.caret) : prev_boundary(f, f.caret)
		remove_range(&f.buf, from, f.caret)
		f.caret, f.anchor = from, from
		return true
	case KS_DELETE, KS_KP_DELETE:
		if field_delete_selection(f) { return true }
		if f.caret >= len(f.buf) { return true }
		to := ctrl ? word_right(f, f.caret) : next_boundary(f, f.caret)
		remove_range(&f.buf, f.caret, to)
		return true
	case KS_LEFT:
		if !shift && field_has_selection(f) {
			lo, _ := field_selection(f)
			move(f, lo, false)
		} else {
			move(f, ctrl ? word_left(f, f.caret) : prev_boundary(f, f.caret), shift)
		}
		return true
	case KS_RIGHT:
		if !shift && field_has_selection(f) {
			_, hi := field_selection(f)
			move(f, hi, false)
		} else {
			move(f, ctrl ? word_right(f, f.caret) : next_boundary(f, f.caret), shift)
		}
		return true
	case KS_HOME:
		move(f, 0, shift)
		return true
	case KS_END:
		move(f, len(f.buf), shift)
		return true
	}
	if ctrl {
		if ks == 'a' || ks == 'A' {
			field_select_all(f)
			return true
		}
		return false
	}
	if text != "" {
		field_insert(f, text)
		return true
	}
	return false
}

// Printable part of composed input (control characters dropped).
printable :: proc(s: string) -> string {
	if s == "" { return "" }
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		if r < 0x20 || r == 0x7F { continue }
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// Caret position for a click at window x (after the last draw).
field_click :: proc(a: ^App, f: ^Field, x: i32, font: ^tx.Font) {
	target := x - f.area_x + f.scroll_x
	best, best_d := 0, max(i32)
	pos := 0
	for {
		w := tx.text_width(a.c, font, string(f.buf[:pos]))
		d := abs(w - target)
		if d < best_d { best, best_d = pos, d }
		if pos >= len(f.buf) { break }
		pos = next_boundary(f, pos)
	}
	f.caret, f.anchor = best, best
}

// A field in `r` (canvas coordinates on `cv`; ox/oy turn them into window
// coordinates for text and hits). Placeholder shown when empty and unfocused.
draw_field :: proc(a: ^App, cv: ^tx.Canvas, r: tx.Rect, ox, oy: i32, f: ^Field, placeholder: string, focused: bool,
                   lead: Ic, action: Action, pane: int, clip := tx.Rect{}) {
	th := &a.style.theme
	font := action == .Rename_Field ? a.style.font_small : a.style.font
	hot := hovered(a, action, pane)
	fill := focused ? th.bg : (hot ? mix(th.field, th.hover, 0.6) : th.field)
	radius := f32(r.h) / 2
	if action == .Rename_Field { radius = 8 }
	fill_rounded(cv, r, radius, fill)
	if focused {
		stroke_rounded(cv, r, radius, 1.5, th.accent)
	} else {
		stroke_rounded(cv, r, radius, 1, th.outline)
	}
	x := r.x + (action == .Rename_Field ? 8 : 12)
	if lead != .None {
		glyph(a, a.style.icon_small, {ox + x - 2, oy + r.y, 20, r.h}, lead, focused ? th.accent : th.muted, clip)
		x += 24
	}
	right_pad: i32 = action == .Search ? r.h : 12
	if action == .Rename_Field { right_pad = 8 }
	avail := r.x + r.w - right_pad - x
	inner := tx.Rect{ox + x, oy + r.y, max(avail, 1), r.h}
	if clip.w > 0 {
		if ci, ok := tx.rect_intersect(inner, clip); ok { inner = ci } else { inner = {} }
	}
	value := field_text(f)
	if value == "" && !focused {
		text_box(a, font, ox + x, oy + r.y, r.h, tx.text_ellipsize(a.c, font, placeholder, avail), th.muted, inner)
		f.scroll_x = 0
	} else {
		caret_x := tx.text_width(a.c, font, value[:f.caret])
		// Keep the caret visible.
		if caret_x - f.scroll_x > avail - 2 { f.scroll_x = caret_x - avail + 2 }
		if caret_x - f.scroll_x < 0 { f.scroll_x = caret_x }
		total := tx.text_width(a.c, font, value)
		if total - f.scroll_x < avail - 2 { f.scroll_x = max(0, total - avail + 2) }
		if focused && field_has_selection(f) {
			lo, hi := field_selection(f)
			sx0 := x + tx.text_width(a.c, font, value[:lo]) - f.scroll_x
			sx1 := x + tx.text_width(a.c, font, value[:hi]) - f.scroll_x
			sx0 = max(sx0, x)
			sx1 = min(sx1, x + avail)
			if sx1 > sx0 {
				fill_rounded(cv, {sx0, r.y + (r.h - 20) / 2, sx1 - sx0, 20}, 4, mix(th.bg, th.accent, th.dark ? 0.45 : 0.3))
			}
		}
		text_box(a, font, ox + x - f.scroll_x, oy + r.y, r.h, value, th.fg, inner)
		if focused {
			cx := x + caret_x - f.scroll_x
			ch := min(r.h - 10, line_height(font) + 2)
			tx.canvas_fill_rect(cv, {cx, r.y + (r.h - ch) / 2, 2, ch}, th.accent)
		}
	}
	f.area_x = ox + x
	hit := tx.Rect{ox + r.x, oy + r.y, r.w, r.h}
	add_hit(a, hit, action, pane, 0, clip)
}
