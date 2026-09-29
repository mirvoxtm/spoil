// Archives: "Comprimir…" opens a small milk card (name field, format pills
// .zip / .tar.gz / .tar.zst / .7z) and runs bsdtar or 7z as a background job;
// "Extrair aqui" / "Extrair para pasta" unpack with bsdtar, 7z (or tar/unzip)
// without overwriting anything.
package spoil

import "core:fmt"
import "core:os"
import "core:strings"
import xlib "vendor:x11/xlib"
import desktop "milk:desktop"
import tx "milk:tx"

CARD_W :: 460
CARD_H :: 236

Archive_Format :: enum { Zip, Tar_Gz, Tar_Zst, Seven_Z }

@(rodata) FORMAT_EXT := [Archive_Format]string{.Zip = ".zip", .Tar_Gz = ".tar.gz", .Tar_Zst = ".tar.zst", .Seven_Z = ".7z"}

Archive_Tools :: struct {
	bsdtar:   bool,
	sevenzip: string, // "7z" / "7za", "" when missing
	zip:      bool,
	unzip:    bool,
	tar:      bool,
	zstd:     bool,
	unrar:    bool,
}

g_archive: Archive_Tools

detect_archive_tools :: proc() {
	_, g_archive.bsdtar = desktop.find_executable("bsdtar")
	if _, ok := desktop.find_executable("7z"); ok {
		g_archive.sevenzip = "7z"
	} else if _, ok2 := desktop.find_executable("7za"); ok2 {
		g_archive.sevenzip = "7za"
	}
	_, g_archive.zip = desktop.find_executable("zip")
	_, g_archive.unzip = desktop.find_executable("unzip")
	_, g_archive.tar = desktop.find_executable("tar")
	_, g_archive.zstd = desktop.find_executable("zstd")
	_, g_archive.unrar = desktop.find_executable("unrar")
}

format_available :: proc(f: Archive_Format) -> bool {
	switch f {
	case .Zip:     return g_archive.bsdtar || g_archive.zip
	case .Tar_Gz:  return g_archive.bsdtar || g_archive.tar
	case .Tar_Zst: return g_archive.bsdtar || (g_archive.tar && g_archive.zstd)
	case .Seven_Z: return g_archive.sevenzip != ""
	}
	return false
}

@(rodata) ARCHIVE_SUFFIXES := []string{".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.lz4",
                                       ".tgz", ".tbz", ".tbz2", ".txz", ".tzst", ".tar", ".zip", ".7z", ".rar", ".jar", ".cpio", ".iso"}

// The archive suffix of a name ("" when it is not an archive we can unpack).
archive_suffix :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	for s in ARCHIVE_SUFFIXES {
		if strings.has_suffix(lower, s) && len(lower) > len(s) { return s }
	}
	return ""
}

is_archive :: proc(path: string) -> bool {
	if is_directory(path) { return false }
	return archive_suffix(base_name(path)) != ""
}

// Unpack `archive` into `dir` (or a new folder named after it) as a job.
extract :: proc(a: ^App, archive, dir: string, into_folder: bool) {
	name := base_name(archive)
	suffix := archive_suffix(name)
	stem := name[:len(name) - len(suffix)]
	dest := dir
	select := ""
	if into_folder {
		folder := unique_name(dir, stem, true)
		dest = join({dir, folder})
		if err := make_dir(dest); err != "" {
			set_notice(a, fmt.tprintf(tr(a, "Não foi possível criar “%s”: %s", "Cannot create “%s”: %s"), folder, err), true)
			return
		}
		select = folder
	}
	argv := make([dynamic]string, context.temp_allocator)
	prefer_7z := suffix == ".7z" || suffix == ".rar"
	switch {
	case prefer_7z && g_archive.sevenzip != "":
		append(&argv, g_archive.sevenzip, "x", "-bd", "-y", "-aos", fmt.tprintf("-o%s", dest), "--", archive)
	case suffix == ".rar" && g_archive.unrar:
		append(&argv, "unrar", "x", "-o-", "-y", "--", archive, strings.concatenate({dest, "/"}, context.temp_allocator))
	case g_archive.bsdtar:
		append(&argv, "bsdtar", "-x", "-k", "-f", archive, "-C", dest)
	case g_archive.sevenzip != "":
		append(&argv, g_archive.sevenzip, "x", "-bd", "-y", "-aos", fmt.tprintf("-o%s", dest), "--", archive)
	case suffix == ".zip" && g_archive.unzip:
		append(&argv, "unzip", "-n", "-q", archive, "-d", dest)
	case g_archive.tar:
		append(&argv, "tar", "-x", "--skip-old-files", "-f", archive, "-C", dest)
	case:
		set_notice(a, tr(a, "Nenhum programa para extrair (instale bsdtar ou 7z)", "No program to extract with (install bsdtar or 7z)"), true)
		return
	}
	start_job(a, .Extract, argv[:], 1, dir, select)
}

@(private)
make_dir :: proc(path: string) -> string {
	if err := os.make_directory(path); err != nil { return os.error_string(err) }
	return ""
}

// Create `names` (in `dir`) into archive `target` (a name in `dir`) as a job.
compress :: proc(a: ^App, dir: string, names: []string, target: string, format: Archive_Format) -> bool {
	argv := make([dynamic]string, context.temp_allocator)
	switch format {
	case .Seven_Z:
		append(&argv, g_archive.sevenzip, "a", "-bd", "-y", "--", target)
		append(&argv, ..names)
	case .Zip, .Tar_Gz, .Tar_Zst:
		if g_archive.bsdtar {
			append(&argv, "bsdtar", "-a", "-c", "-f", target, "--")
		} else if format == .Zip {
			append(&argv, "zip", "-r", "-q", "-y", target, "--")
		} else if format == .Tar_Gz {
			append(&argv, "tar", "-c", "-z", "-f", target, "--")
		} else {
			append(&argv, "tar", "--zstd", "-c", "-f", target, "--")
		}
		append(&argv, ..names)
	}
	return start_job(a, .Compress, argv[:], len(names), dir, target)
}

// ---------------------------------------------------------------------------
// The "Comprimir…" card
// ---------------------------------------------------------------------------
Card :: struct {
	win:      xlib.Window,
	pixmap:   xlib.Pixmap,
	open:     bool,
	rect:     tx.Rect, // screen coordinates
	input:    tx.Input,
	name:     Field,
	format:   Archive_Format,
	names:    [dynamic]string, // items to compress (owned)
	dir:      string,          // owned
	hits:     [dynamic]Hit,    // card coordinates
	hover:    Hit,
	grab_ptr: bool,
	grab_kb:  bool,
	shaped:   bool,
}

card_open_compress :: proc(a: ^App) {
	t := cur_tab(a)
	sel := selected_entries(t)
	if len(sel) == 0 { return }
	card_close(a)
	cd := &a.card
	for idx in sel { append(&cd.names, strings.clone(t.entries[idx].name)) }
	cd.dir = strings.clone(t.dir)
	// Default name: the item (without its extension) or the folder.
	default_name := dir_label(a, t.dir)
	if len(sel) == 1 {
		e := &t.entries[sel[0]]
		default_name = e.name
		if !e.is_dir {
			if suffix := archive_suffix(e.name); suffix != "" {
				default_name = e.name[:len(e.name) - len(suffix)]
			} else if dot := strings.last_index_byte(e.name, '.'); dot > 0 {
				default_name = e.name[:dot]
			}
		}
	}
	if t.dir == "/" && len(sel) > 1 { default_name = tr(a, "Arquivos", "Archive") }
	field_set(&cd.name, default_name)
	field_select_all(&cd.name)
	if !format_available(cd.format) {
		for f in Archive_Format { if format_available(f) { cd.format = f; break } }
	}

	// Centred on the active pane's card.
	L := pane_layout(a, a.active_pane)
	ox, oy := window_origin(a)
	cd.rect = {ox + L.card.x + (L.card.w - CARD_W) / 2, oy + L.card.y + max((L.card.h - CARD_H) / 3, 10), CARD_W, CARD_H}
	c := a.c
	if cd.win == 0 {
		cd.win = tx.create_overlay(c, cd.rect, {.ButtonPress, .ButtonRelease, .PointerMotion, .LeaveWindow, .KeyPress, .FocusChange},
		                           "_NET_WM_WINDOW_TYPE_DIALOG", "Spoil")
		hint := xlib.XClassHint{res_name = "spoil", res_class = "Spoil"}
		xlib.SetClassHint(c.dpy, cd.win, &hint)
		cd.input = tx.input_open(c, cd.win)
	} else {
		tx.move_resize(c, cd.win, cd.rect)
	}
	if !cd.shaped {
		tx.shape_rounded(c, cd.win, CARD_W, CARD_H, 18)
		cd.shaped = true
	}
	cd.open = true
	card_draw(a)
	tx.map_window(c, cd.win)
	tx.raise_window(c, cd.win)
	ps := xlib.GrabPointer(c.dpy, cd.win, false, {.ButtonPress, .ButtonRelease, .PointerMotion},
	                       .GrabModeAsync, .GrabModeAsync, 0, 0, xlib.CurrentTime)
	ks := xlib.GrabKeyboard(c.dpy, cd.win, false, .GrabModeAsync, .GrabModeAsync, xlib.CurrentTime)
	cd.grab_ptr, cd.grab_kb = ps == 0, ks == 0
	tx.input_focus(&a.input, false)
	tx.input_focus(&cd.input, true)
	tx.flush(c)
}

card_close :: proc(a: ^App) {
	cd := &a.card
	if cd.open {
		if cd.grab_ptr { xlib.UngrabPointer(a.c.dpy, xlib.CurrentTime) }
		if cd.grab_kb { xlib.UngrabKeyboard(a.c.dpy, xlib.CurrentTime) }
		cd.grab_ptr, cd.grab_kb = false, false
		tx.input_focus(&cd.input, false)
		if a.has_focus { tx.input_focus(&a.input, true) }
		if cd.win != 0 { tx.unmap_window(a.c, cd.win) }
		cd.open = false
		tx.flush(a.c)
		a.dirty = true
	}
	for n in cd.names { delete(n) }
	clear(&cd.names)
	delete(cd.dir)
	cd.dir = ""
}

card_destroy :: proc(a: ^App) {
	cd := &a.card
	tx.input_close(&cd.input)
	if cd.win != 0 { tx.destroy_window(a.c, cd.win) }
	tx.pixmap_free(a.c, cd.pixmap)
	field_destroy(&cd.name)
	delete(cd.names)
	delete(cd.hits)
	cd^ = {}
}

@(private)
card_confirm :: proc(a: ^App) {
	cd := &a.card
	stem := strings.trim_space(field_text(&cd.name))
	if stem == "" || strings.index_byte(stem, '/') >= 0 {
		set_notice(a, tr(a, "Escolha um nome sem “/”", "Pick a name without “/”"), true)
		return
	}
	if !format_available(cd.format) { return }
	target := unique_name(cd.dir, strings.concatenate({stem, FORMAT_EXT[cd.format]}, context.temp_allocator), false)
	dir := strings.clone(cd.dir, context.temp_allocator)
	names := make([]string, len(cd.names), context.temp_allocator)
	for n, i in cd.names { names[i] = strings.clone(n, context.temp_allocator) }
	card_close(a)
	compress(a, dir, names, target, cd.format)
}

@(private)
card_draw :: proc(a: ^App) {
	cd := &a.card
	th := &a.style.theme
	c := a.c
	w, h := cd.rect.w, cd.rect.h
	cv := tx.canvas_make(w, h, context.temp_allocator)
	tx.canvas_fill(&cv, th.bg)
	stroke_rounded(&cv, {0, 0, w, h}, 18, 1, tx.color_with_alpha(th.muted, 90))
	saved_texts, saved_hits, saved_hover := a.texts, a.hits, a.hover
	a.texts = make([dynamic]Text_Item, context.temp_allocator)
	clear(&cd.hits)
	a.hits = cd.hits
	a.hover = cd.hover

	pad: i32 = 22
	// Title: an accent disc with the archive glyph, then the text.
	tx.canvas_fill_circle(&cv, f32(pad + 16), f32(pad + 16), 16, th.accent)
	glyph(a, a.style.icon_small, {pad, pad, 32, 32}, .Archive, th.accent_fg)
	title := len(cd.names) == 1 ? fmt.tprintf(tr(a, "Comprimir “%s”", "Compress “%s”"), cd.names[0]) : fmt.tprintf(tr(a, "Comprimir %d itens", "Compress %d items"), len(cd.names))
	text_box(a, a.style.font, pad + 44, pad - 2, 22, tx.text_ellipsize(c, a.style.font, title, w - pad * 2 - 44), th.fg)
	text_box(a, a.style.font_tiny, pad + 44, pad + 18, 18, tx.text_ellipsize(c, a.style.font_tiny, fmt.tprintf(tr(a, "Em %s", "In %s"), dir_label(a, cd.dir)), w - pad * 2 - 44), th.sub)

	// Name field and the extension.
	y: i32 = pad + 52
	text_box(a, a.style.font_tiny, pad + 4, y, 18, tr(a, "Nome do arquivo", "Archive name"), th.sub)
	y += 22
	ext := FORMAT_EXT[cd.format]
	ext_w := tw(a, a.style.font, ext)
	fr := tx.Rect{pad, y, w - 2 * pad - ext_w - 12, 36}
	draw_field(a, &cv, fr, 0, 0, &cd.name, "", true, .None, .Card_Field, 0)
	text_box(a, a.style.font, fr.x + fr.w + 10, y, 36, ext, th.sub)
	y += 36 + 14

	// Format pills.
	x := pad
	for f in Archive_Format {
		label := FORMAT_EXT[f]
		pw := tw(a, a.style.font_small, label) + 26
		r := tx.Rect{x, y, pw, 30}
		enabled := format_available(f)
		sel := f == cd.format
		if sel {
			fill_rounded(&cv, r, 15, th.accent)
		} else if enabled && hovered(a, .Card_Format, 0, int(f)) {
			fill_rounded(&cv, r, 15, th.hover)
		} else {
			fill_rounded(&cv, r, 15, th.field)
		}
		fg := sel ? th.accent_fg : (enabled ? th.fg : mix(th.fg, th.bg, 0.6))
		text_centered(a, a.style.font_small, r, label, fg)
		if enabled { add_hit(a, r, .Card_Format, 0, int(f)) }
		x += pw + 8
	}

	// Buttons.
	by := h - pad - 34
	ok_label := tr(a, "Comprimir", "Compress")
	cancel_label := tr(a, "Cancelar", "Cancel")
	ok_w := tw(a, a.style.font, ok_label) + 40
	cancel_w := tw(a, a.style.font, cancel_label) + 36
	ok := tx.Rect{w - pad - ok_w, by, ok_w, 34}
	cancel := tx.Rect{ok.x - 10 - cancel_w, by, cancel_w, 34}
	fill_rounded(&cv, cancel, 17, hovered(a, .Card_Cancel) ? th.pressed : th.surface)
	text_centered(a, a.style.font, cancel, cancel_label, th.fg)
	add_hit(a, cancel, .Card_Cancel)
	fill_rounded(&cv, ok, 17, hovered(a, .Card_Ok) ? mix(th.accent, th.accent_fg, 0.14) : th.accent)
	text_centered(a, a.style.font, ok, ok_label, th.accent_fg)
	add_hit(a, ok, .Card_Ok)

	cd.hits = a.hits
	pm := tx.canvas_to_pixmap(c, cv)
	draw_texts(a, pm, a.texts[:])
	a.texts, a.hits, a.hover = saved_texts, saved_hits, saved_hover
	tx.set_background(c, cd.win, pm)
	tx.pixmap_free(c, cd.pixmap)
	cd.pixmap = pm
	tx.flush(c)
}

@(private)
card_hit :: proc(a: ^App, x, y: i32) -> Hit {
	#reverse for h in a.card.hits {
		if tx.rect_contains(h.r, x, y) { return h }
	}
	return {}
}

card_event :: proc(a: ^App, ev: ^xlib.XEvent) {
	cd := &a.card
	if !cd.open { return }
	#partial switch ev.type {
	case .MotionNotify:
		h := card_hit(a, ev.xmotion.x, ev.xmotion.y)
		if h.action != cd.hover.action || h.arg != cd.hover.arg {
			cd.hover = h
			card_draw(a)
		}
	case .ButtonPress:
		x, y := ev.xbutton.x, ev.xbutton.y
		if x < 0 || y < 0 || x >= cd.rect.w || y >= cd.rect.h {
			card_close(a) // a click outside cancels, like the menu
			return
		}
		if ev.xbutton.button != .Button1 { return }
		h := card_hit(a, x, y)
		#partial switch h.action {
		case .Card_Format:
			cd.format = Archive_Format(h.arg)
			card_draw(a)
		case .Card_Cancel:
			card_close(a)
		case .Card_Ok:
			card_confirm(a)
		case .Card_Field:
			field_click(a, &cd.name, x, a.style.font)
			card_draw(a)
		}
	case .KeyPress:
		raw, keysym := tx.input_lookup(&cd.input, &ev.xkey)
		ks := uint(keysym)
		text := printable(raw)
		if ks == 0 && len(text) == 1 { ks = uint(text[0]) }
		ctrl := .ControlMask in ev.xkey.state
		shift := .ShiftMask in ev.xkey.state
		switch ks {
		case KS_ESCAPE:
			card_close(a)
			return
		case KS_RETURN, KS_KP_ENTER:
			card_confirm(a)
			return
		case KS_TAB:
			cd.format = Archive_Format((int(cd.format) + 1) % len(Archive_Format))
			for !format_available(cd.format) { cd.format = Archive_Format((int(cd.format) + 1) % len(Archive_Format)) }
			card_draw(a)
			return
		}
		if field_key(&cd.name, ks, ctrl ? "" : text, ctrl, shift) { card_draw(a) }
	}
}
