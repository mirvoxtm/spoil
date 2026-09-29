// The CLIPBOARD selection. "Copiar caminho" puts text on it; copying files
// puts their paths there too (text, text/uri-list and GNOME's copied-files
// list, so other file managers can paste them). Spoil owns the selection and
// answers TARGETS / UTF8_STRING / STRING / TEXT requests itself. Pasting
// files inside Spoil uses the internal list, not the X selection.
package spoil

import "core:strings"
import xlib "vendor:x11/xlib"
import tx "milk:tx"

Clip :: struct {
	paths: [dynamic]string, // files copied or cut inside Spoil (owned)
	cut:   bool,
	text:  string,          // served as UTF8_STRING / STRING / TEXT (owned)
	uris:  string,          // text/uri-list, "" when only text is offered (owned)
	gnome: string,          // x-special/gnome-copied-files (owned)
	owner: bool,
}

clip_set_files :: proc(a: ^App, paths: []string, cut: bool) {
	clip_clear_files(a)
	for p in paths { append(&a.clip.paths, strings.clone(p)) }
	a.clip.cut = cut
	uris := make([dynamic]string, context.temp_allocator)
	for p in paths { append(&uris, file_uri(p)) }
	uri_list := strings.concatenate({strings.join(uris[:], "\r\n", context.temp_allocator), "\r\n"}, context.temp_allocator)
	gnome := strings.concatenate({cut ? "cut\n" : "copy\n", strings.join(uris[:], "\n", context.temp_allocator)}, context.temp_allocator)
	clip_own(a, strings.join(paths, "\n", context.temp_allocator), uri_list, gnome)
}

clip_clear_files :: proc(a: ^App) {
	for p in a.clip.paths { delete(p) }
	clear(&a.clip.paths)
	a.clip.cut = false
}

// Take the CLIPBOARD selection with this content.
clip_own :: proc(a: ^App, text, uris, gnome: string) {
	cl := &a.clip
	delete(cl.text)
	delete(cl.uris)
	delete(cl.gnome)
	cl.text = strings.clone(text)
	cl.uris = strings.clone(uris)
	cl.gnome = strings.clone(gnome)
	sel := tx.atom(a.c, "CLIPBOARD")
	xlib.SetSelectionOwner(a.c.dpy, sel, a.win, xlib.CurrentTime)
	cl.owner = xlib.GetSelectionOwner(a.c.dpy, sel) == a.win
	tx.flush(a.c)
}

clip_destroy :: proc(a: ^App) {
	clip_clear_files(a)
	delete(a.clip.paths)
	delete(a.clip.text)
	delete(a.clip.uris)
	delete(a.clip.gnome)
	a.clip = {}
}

clip_cleared :: proc(a: ^App, ev: ^xlib.XSelectionClearEvent) {
	if ev.selection == tx.atom(a.c, "CLIPBOARD") { a.clip.owner = false }
}

// Answer a SelectionRequest (another client pasting).
clip_request :: proc(a: ^App, req: ^xlib.XSelectionRequestEvent) {
	c := a.c
	cl := &a.clip
	reply: xlib.XEvent
	reply.xselection = xlib.XSelectionEvent{
		type = .SelectionNotify, requestor = req.requestor, selection = req.selection,
		target = req.target, property = 0, time = req.time,
	}
	prop := req.property
	if prop == 0 { prop = req.target } // obsolete clients
	if cl.owner && req.selection == tx.atom(c, "CLIPBOARD") {
		target := req.target
		utf8 := tx.atom(c, "UTF8_STRING")
		switch {
		case target == tx.atom(c, "TARGETS"):
			atoms := make([dynamic]xlib.Atom, context.temp_allocator)
			append(&atoms, tx.atom(c, "TARGETS"), utf8, tx.ATOM_STRING, tx.atom(c, "TEXT"),
			       tx.atom(c, "text/plain;charset=utf-8"), tx.atom(c, "text/plain"))
			if cl.uris != "" { append(&atoms, tx.atom(c, "text/uri-list"), tx.atom(c, "x-special/gnome-copied-files")) }
			xlib.ChangeProperty(c.dpy, req.requestor, prop, tx.ATOM_ATOM, 32, tx.PROP_MODE_REPLACE, raw_data(atoms), i32(len(atoms)))
			reply.xselection.property = prop
		case target == utf8 || target == tx.atom(c, "TEXT") || target == tx.atom(c, "text/plain;charset=utf-8"):
			xlib.ChangeProperty(c.dpy, req.requestor, prop, utf8, 8, tx.PROP_MODE_REPLACE, raw_data(cl.text), i32(len(cl.text)))
			reply.xselection.property = prop
		case target == tx.ATOM_STRING || target == tx.atom(c, "text/plain"):
			latin := to_latin1(cl.text)
			xlib.ChangeProperty(c.dpy, req.requestor, prop, tx.ATOM_STRING, 8, tx.PROP_MODE_REPLACE, raw_data(latin), i32(len(latin)))
			reply.xselection.property = prop
		case cl.uris != "" && target == tx.atom(c, "text/uri-list"):
			xlib.ChangeProperty(c.dpy, req.requestor, prop, target, 8, tx.PROP_MODE_REPLACE, raw_data(cl.uris), i32(len(cl.uris)))
			reply.xselection.property = prop
		case cl.uris != "" && target == tx.atom(c, "x-special/gnome-copied-files"):
			xlib.ChangeProperty(c.dpy, req.requestor, prop, target, 8, tx.PROP_MODE_REPLACE, raw_data(cl.gnome), i32(len(cl.gnome)))
			reply.xselection.property = prop
		}
	}
	xlib.SendEvent(c.dpy, req.requestor, false, {}, &reply)
	tx.flush(c)
}

// UTF-8 → ISO-8859-1 for STRING requests ('?' for what Latin-1 lacks).
@(private)
to_latin1 :: proc(s: string) -> []u8 {
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for r in s {
		append(&out, r < 256 ? u8(r) : '?')
	}
	return out[:]
}
