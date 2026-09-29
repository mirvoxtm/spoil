// Drawing primitives on the CPU canvas (corner-only rounded fills, soft
// shadows, rounded images) and the text/glyph queue drawn with Xft once the
// canvas is a pixmap.
package spoil

import "core:math"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

foreign import xft_clip "system:Xft"
@(default_calling_convention="c")
foreign xft_clip {
	XftDrawSetClipRectangles :: proc(draw: ^tx.XftDraw, x, y: i32, rects: [^]xlib.XRectangle, n: i32) -> b32 ---
	XftDrawSetClip :: proc(draw: ^tx.XftDraw, region: rawptr) -> b32 ---
}

@(private)
blend :: #force_inline proc(dst: u32, src: u32, cov: f32) -> u32 {
	if cov >= 1 { return src }
	dr, dg, db := f32((dst >> 16) & 0xFF), f32((dst >> 8) & 0xFF), f32(dst & 0xFF)
	sr, sg, sb := f32((src >> 16) & 0xFF), f32((src >> 8) & 0xFF), f32(src & 0xFF)
	return u32(dr + (sr - dr) * cov) << 16 | u32(dg + (sg - dg) * cov) << 8 | u32(db + (sb - db) * cov)
}

@(private)
rounded_coverage :: #force_inline proc(px, py, w, h, rad: f32) -> f32 {
	cx := clamp(px, rad, w - rad)
	cy := clamp(py, rad, h - rad)
	dx := px - cx
	dy := py - cy
	if dx == 0 && dy == 0 { return 1 }
	return clamp(rad - math.sqrt(dx * dx + dy * dy) + 0.5, 0, 1)
}

// Rounded rectangle that only does coverage maths in the corners.
fill_rounded :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, c: tx.Color) {
	if r.w <= 0 || r.h <= 0 || c.a == 0 { return }
	rad := clamp(radius, 0, f32(min(r.w, r.h)) / 2)
	ir := i32(math.ceil(rad))
	src := u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
	alpha := f32(c.a) / 255
	x0, x1 := max(r.x, 0), min(r.x + r.w, cv.w)
	y0, y1 := max(r.y, 0), min(r.y + r.h, cv.h)
	fw, fh := f32(r.w), f32(r.h)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		ly := y - r.y
		corner_row := ly < ir || ly >= r.h - ir
		for x in x0 ..< x1 {
			lx := x - r.x
			cov := alpha
			if corner_row && (lx < ir || lx >= r.w - ir) {
				cov *= rounded_coverage(f32(lx) + 0.5, f32(ly) + 0.5, fw, fh, rad)
				if cov <= 0 { continue }
			}
			i := row + int(x)
			cv.px[i] = blend(cv.px[i], src, cov)
		}
	}
}

// A rounded outline `width` pixels wide.
stroke_rounded :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, width: f32, c: tx.Color) {
	tx.canvas_stroke_rounded_rect(cv, r, radius, width, c)
}

// Soft drop shadow around a rounded rectangle (drawn before it): darkness
// falls off quadratically over `spread` pixels; covered pixels are skipped.
soft_shadow :: proc(cv: ^tx.Canvas, r: tx.Rect, radius: f32, spread: i32, strength: f32, dy: i32) {
	sr := tx.Rect{r.x, r.y + dy, r.w, r.h}
	hw, hh := f32(sr.w) / 2, f32(sr.h) / 2
	cx, cy := f32(sr.x) + hw, f32(sr.y) + hh
	rad := clamp(radius, 0, min(hw, hh))
	ir := i32(math.ceil(radius))
	x0, x1 := max(sr.x - spread, 0), min(sr.x + sr.w + spread, cv.w)
	y0, y1 := max(sr.y - spread, 0), min(sr.y + sr.h + spread, cv.h)
	fs := f32(spread)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		in_rows := y >= r.y && y < r.y + r.h
		in_mid_rows := y >= r.y + ir && y < r.y + r.h - ir
		for x in x0 ..< x1 {
			if in_rows && x >= r.x + ir && x < r.x + r.w - ir { continue }
			if in_mid_rows && x >= r.x && x < r.x + r.w { continue }
			px := abs(f32(x) + 0.5 - cx) - (hw - rad)
			py := abs(f32(y) + 0.5 - cy) - (hh - rad)
			outside := math.sqrt(max(px, 0) * max(px, 0) + max(py, 0) * max(py, 0)) + min(max(px, py), 0) - rad
			if outside >= fs { continue }
			t: f32 = 1
			if outside > 0 { t = 1 - outside / fs }
			al := strength * t * t
			i := row + int(x)
			d := cv.px[i]
			k := 1 - al
			cv.px[i] = u32(f32((d >> 16) & 0xFF) * k) << 16 | u32(f32((d >> 8) & 0xFF) * k) << 8 | u32(f32(d & 0xFF) * k)
		}
	}
}

// An image with rounded corners (thumbnails); `opacity` scales it.
blit_rounded :: proc(dst: ^tx.Canvas, img: tx.Image, x, y: i32, radius: f32, opacity: f32 = 1) {
	rad := clamp(radius, 0, f32(min(img.w, img.h)) / 2)
	fw, fh := f32(img.w), f32(img.h)
	for iy in 0 ..< img.h {
		dy := y + iy
		if dy < 0 || dy >= dst.h { continue }
		for ix in 0 ..< img.w {
			dx := x + ix
			if dx < 0 || dx >= dst.w { continue }
			cov := rounded_coverage(f32(ix) + 0.5, f32(iy) + 0.5, fw, fh, rad)
			if cov <= 0 { continue }
			o := (int(iy) * int(img.w) + int(ix)) * 4
			src := u32(img.rgba[o]) << 16 | u32(img.rgba[o + 1]) << 8 | u32(img.rgba[o + 2])
			al := f32(img.rgba[o + 3]) / 255 * opacity
			i := int(dy) * int(dst.w) + int(dx)
			dst.px[i] = blend(dst.px[i], src, cov * al)
		}
	}
}

// Indeterminate progress: a bright arc turning over a faint ring.
spinner :: proc(cv: ^tx.Canvas, cx, cy, radius, thickness: f32, phase: f32, color, track: tx.Color) {
	x0 := max(i32(cx - radius - thickness), 0)
	x1 := min(i32(cx + radius + thickness) + 1, cv.w)
	y0 := max(i32(cy - radius - thickness), 0)
	y1 := min(i32(cy + radius + thickness) + 1, cv.h)
	start := phase * 2 * math.PI
	span: f32 = 1.9
	fg := u32(color.r) << 16 | u32(color.g) << 8 | u32(color.b)
	bg := u32(track.r) << 16 | u32(track.g) << 8 | u32(track.b)
	for y in y0 ..< y1 {
		row := int(y) * int(cv.w)
		for x in x0 ..< x1 {
			dx := f32(x) + 0.5 - cx
			dy := f32(y) + 0.5 - cy
			d := math.sqrt(dx * dx + dy * dy)
			cov := clamp(thickness / 2 - abs(d - radius) + 0.5, 0, 1)
			if cov <= 0 { continue }
			ang := math.atan2(dy, dx) - start
			for ang < 0 { ang += 2 * math.PI }
			for ang >= 2 * math.PI { ang -= 2 * math.PI }
			i := row + int(x)
			if ang < span {
				cv.px[i] = blend(cv.px[i], fg, cov)
			} else {
				cv.px[i] = blend(cv.px[i], bg, cov * f32(track.a) / 255)
			}
		}
	}
}

// Text with its baseline placed so capitals are vertically centred in [y, y+h).
text_box :: proc(a: ^App, f: ^tx.Font, x, y, h: i32, s: string, color: tx.Color, clip := tx.Rect{}) {
	if f == nil || s == "" { return }
	ext := tx.text_extents(a.c, f, "H")
	baseline := y + (h - i32(ext.height)) / 2 + i32(ext.y)
	append(&a.texts, Text_Item{font = f, x = x, baseline = baseline, s = s, color = color, clip = clip})
}

text_centered :: proc(a: ^App, f: ^tx.Font, r: tx.Rect, s: string, color: tx.Color, clip := tx.Rect{}) {
	if f == nil || s == "" { return }
	w := tx.text_width(a.c, f, s)
	text_box(a, f, r.x + (r.w - w) / 2, r.y, r.h, s, color, clip)
}

// A Tabler glyph centred on its ink in `box` (a text symbol without the font).
glyph :: proc(a: ^App, f: ^tx.Font, box: tx.Rect, ic: Ic, color: tx.Color, clip := tx.Rect{}) {
	if ic == .None { return }
	if f == nil {
		text_centered(a, a.style.font, box, ic_fallback(ic), color, clip)
		return
	}
	s := ic_string(ic)
	ext := tx.text_extents(a.c, f, s)
	x := box.x + (box.w - i32(ext.width)) / 2 + i32(ext.x)
	baseline := box.y + (box.h - i32(ext.height)) / 2 + i32(ext.y)
	append(&a.texts, Text_Item{font = f, x = x, baseline = baseline, s = s, color = color, clip = clip})
}

tw :: proc(a: ^App, f: ^tx.Font, s: string) -> i32 { return tx.text_width(a.c, f, s) }

line_height :: proc(f: ^tx.Font) -> i32 {
	if f == nil { return 16 }
	return f.ascent + f.descent + 1
}

// Queued text drawn onto a pixmap (clip rectangles per item).
draw_texts :: proc(a: ^App, pm: xlib.Pixmap, texts: []Text_Item) {
	ts := tx.text_surface_make(a.c, xlib.Drawable(pm))
	clipped := false
	for t in texts {
		if t.clip.w > 0 {
			rect := xlib.XRectangle{i16(t.clip.x), i16(t.clip.y), u16(max(t.clip.w, 0)), u16(max(t.clip.h, 0))}
			XftDrawSetClipRectangles(ts.draw, 0, 0, &rect, 1)
			clipped = true
		} else if clipped {
			XftDrawSetClip(ts.draw, nil)
			clipped = false
		}
		tx.draw_text(&ts, t.font, t.x, t.baseline, t.s, t.color)
	}
	tx.text_surface_destroy(&ts)
}

// Copy `src` into `dst` at (x, y), rows clipped to both canvases.
blit_canvas :: proc(dst: ^tx.Canvas, src: ^tx.Canvas, x, y: i32) {
	for sy in 0 ..< src.h {
		dy := y + sy
		if dy < 0 || dy >= dst.h { continue }
		x0 := max(x, 0)
		x1 := min(x + src.w, dst.w)
		if x1 <= x0 { continue }
		copy(dst.px[int(dy) * int(dst.w) + int(x0):][:x1 - x0], src.px[int(sy) * int(src.w) + int(x0 - x):][:x1 - x0])
	}
}
