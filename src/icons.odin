// Icons and thumbnails.
//
// File-type icons come from the XDG icon theme through milk's loader
// (package desktop, read-only): one loader per size, results copied into our
// own cache so nothing points into the loader's maps. When the theme has no
// icon for a kind, a Tabler glyph is drawn instead.
//
// Thumbnails (png/jpeg/bmp/... with core:image; svg with rsvg-convert; gif,
// webp, progressive jpeg... with ImageMagick when installed) are made by two
// worker threads so the UI never waits for a decoder. Results are cached as
// QOI files in ~/.cache/milk/spoil-thumbs/, keyed by path, size and mtime; a
// pipe wakes the event loop when one is ready.
package spoil

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/netpbm"
import "core:image/png"
import "core:image/qoi"
import _ "core:image/tga"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import config "milk:config"
import desktop "milk:desktop"
import tx "milk:tx"

GRID_ICON   :: 48 // theme icons in the grid
GRID_BOX    :: 64 // thumbnails in the grid fit this square
LIST_ICON   :: 22 // icons and thumbnails in the list
THUMB_MAX   :: 128 // stored thumbnail size (longer side)
THUMB_BYTES_MAX :: 80 * 1024 * 1024 // files larger than this get no thumbnail

Icon_Size :: enum { Grid, List }

@(private)
Theme_Icon :: struct {
	found: bool,
	img:   tx.Image,
}

Icon_Set :: struct {
	loaders:  [Icon_Size]desktop.Icon_Loader,
	ready:    [Icon_Size]bool,
	cache:    [Icon_Size]map[string]Theme_Icon,
	fallback: [Icon_Size]rawptr, // pixels of the loader's own fallback icon
}

Tools :: struct {
	rsvg:   bool,
	magick: string, // "magick" or "convert", "" when ImageMagick is missing
	gio:    bool,
	video:  string, // "ffmpegthumbnailer" or "ffmpeg" (video thumbnails), "" when missing
}

g_tools: Tools

detect_tools :: proc() {
	_, g_tools.rsvg = desktop.find_executable("rsvg-convert")
	if _, ok := desktop.find_executable("magick"); ok {
		g_tools.magick = "magick"
	} else if _, ok2 := desktop.find_executable("convert"); ok2 {
		g_tools.magick = "convert"
	}
	_, g_tools.gio = desktop.find_executable("gio")
	if _, ok := desktop.find_executable("ffmpegthumbnailer"); ok {
		g_tools.video = "ffmpegthumbnailer"
	} else if _, ok2 := desktop.find_executable("ffmpeg"); ok2 {
		g_tools.video = "ffmpeg"
	}
	if !g_tools.gio { log.warn("gio not found: moving to the trash is unavailable") }
}

// ---------------------------------------------------------------------------
// Theme icons
// ---------------------------------------------------------------------------
@(private)
icon_loader :: proc(a: ^App, size: Icon_Size) -> ^desktop.Icon_Loader {
	set := &a.icons
	if !set.ready[size] {
		tmp: config.Config
		if a.cfg != nil { tmp.linux.shortcuts.icon_theme = a.cfg.linux.shortcuts.icon_theme }
		tmp.linux.shortcuts.icon_size = size == .Grid ? GRID_ICON : LIST_ICON
		desktop.icons_init(&set.loaders[size], &tmp)
		set.cache[size] = make(map[string]Theme_Icon)
		probe := desktop.Shortcut{kind = .Application}
		if fb := desktop.icon_for(&set.loaders[size], &probe); fb != nil { set.fallback[size] = raw_data(fb.rgba) }
		set.ready[size] = true
	}
	return &set.loaders[size]
}

// A theme icon by name (copied out of the loader); ok = false when missing.
theme_icon :: proc(a: ^App, name: string, size: Icon_Size) -> (tx.Image, bool) {
	loader := icon_loader(a, size)
	cache := &a.icons.cache[size]
	if e, ok := cache[name]; ok { return e.img, e.found }
	sc := desktop.Shortcut{icon = name, kind = .Application}
	img := desktop.icon_for(loader, &sc)
	entry: Theme_Icon
	if img != nil && (name == "application-x-executable" || raw_data(img.rgba) != a.icons.fallback[size]) {
		entry.found = true
		entry.img = tx.image_make(img.w, img.h)
		copy(entry.img.rgba, img.rgba)
	}
	cache[strings.clone(name)] = entry
	return entry.img, entry.found
}

@(rodata) NAMES_FOLDER  := []string{"folder", "inode-directory"}
@(rodata) NAMES_TEXT    := []string{"text-x-generic"}
@(rodata) NAMES_IMAGE   := []string{"image-x-generic"}
@(rodata) NAMES_AUDIO   := []string{"audio-x-generic"}
@(rodata) NAMES_VIDEO   := []string{"video-x-generic"}
@(rodata) NAMES_ARCHIVE := []string{"package-x-generic", "application-x-archive"}
@(rodata) NAMES_PDF     := []string{"application-pdf", "x-office-document"}
@(rodata) NAMES_CODE    := []string{"text-x-script", "text-x-generic"}
@(rodata) NAMES_DOC     := []string{"x-office-document", "text-x-generic"}
@(rodata) NAMES_SHEET   := []string{"x-office-spreadsheet", "text-x-generic"}
@(rodata) NAMES_SLIDES  := []string{"x-office-presentation", "text-x-generic"}
@(rodata) NAMES_EXEC    := []string{"application-x-executable"}
@(rodata) NAMES_GENERIC := []string{"application-x-generic", "text-x-generic", "unknown"}
@(rodata) NAMES_BROKEN  := []string{"inode-symlink", "emblem-symlink", "application-x-generic"}

kind_icon_names :: proc(k: File_Kind) -> []string {
	switch k {
	case .Folder:       return NAMES_FOLDER
	case .Text:         return NAMES_TEXT
	case .Image:        return NAMES_IMAGE
	case .Audio:        return NAMES_AUDIO
	case .Video:        return NAMES_VIDEO
	case .Archive:      return NAMES_ARCHIVE
	case .Pdf:          return NAMES_PDF
	case .Code:         return NAMES_CODE
	case .Document:     return NAMES_DOC
	case .Spreadsheet:  return NAMES_SHEET
	case .Presentation: return NAMES_SLIDES
	case .Executable:   return NAMES_EXEC
	case .Generic:      return NAMES_GENERIC
	case .Broken:       return NAMES_BROKEN
	}
	return NAMES_GENERIC
}

kind_glyph :: proc(k: File_Kind) -> Ic {
	#partial switch k {
	case .Folder:           return .Folder
	case .Image:            return .Photo
	case .Audio:            return .Music
	case .Video:            return .Movie
	case .Text, .Code, .Pdf, .Document: return .File_Text
	case .Executable:       return .Apps
	case .Broken:           return .Link
	}
	return .File
}

// The theme icon of an entry (special folders get their places icon).
entry_icon :: proc(a: ^App, dir: string, e: ^Entry, size: Icon_Size) -> (tx.Image, bool) {
	if e.kind == .Folder {
		if special := special_folder_icon(join({dir, e.name})); special != "" {
			if img, ok := theme_icon(a, special, size); ok { return img, true }
		}
	}
	for name in kind_icon_names(e.kind) {
		if img, ok := theme_icon(a, name, size); ok { return img, true }
	}
	return {}, false
}

icons_reset :: proc(a: ^App) {
	set := &a.icons
	for size in Icon_Size {
		if !set.ready[size] { continue }
		desktop.icons_destroy(&set.loaders[size])
		for k, &v in set.cache[size] {
			delete(k)
			if v.found { tx.image_destroy(&v.img) }
		}
		delete(set.cache[size])
		set.ready[size] = false
		set.fallback[size] = nil
	}
}

// ---------------------------------------------------------------------------
// Thumbnails
// ---------------------------------------------------------------------------
Thumb_State :: enum { Pending, Ready, Failed }

Thumb :: struct {
	state: Thumb_State,
	grid:  tx.Image, // fits GRID_BOX
	list:  tx.Image, // fits LIST_ICON
}

@(private)
Thumb_Job :: struct {
	key:  string, // heap
	path: string, // heap
}

@(private)
Thumb_Done :: struct {
	key: string, // heap (the job's key, handed back)
	img: tx.Image,
	ok:  bool,
}

Thumbs :: struct {
	mutex:     sync.Mutex,
	sema:      sync.Sema,
	queue:     [dynamic]Thumb_Job,  // guarded by mutex; LIFO so visible items come first
	done:      [dynamic]Thumb_Done, // guarded by mutex
	quit:      bool,                // guarded by mutex
	workers:   [dynamic]^thread.Thread,
	cache_dir: string,
	items:     map[string]Thumb,    // main thread only
	wake_r:    posix.FD,
	wake_w:    posix.FD,
	pending:   int,                 // requested, not yet collected
}

THUMB_WORKERS :: 2

thumbs_init :: proc(a: ^App) {
	t := &a.thumbs
	t.items = make(map[string]Thumb)
	t.wake_r, t.wake_w = -1, -1
	fds: [2]posix.FD
	if posix.pipe(&fds) == .OK {
		t.wake_r, t.wake_w = fds[0], fds[1]
		for fd in fds {
			flags := posix.fcntl(fd, .GETFL)
			posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
			posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
		}
	}
	dir := join({cache_home(), "milk", "spoil-thumbs"})
	if err := os.make_directory_all(dir); err == nil || os.is_directory(dir) {
		t.cache_dir = strings.clone(dir, runtime.heap_allocator())
	}
	for _ in 0 ..< THUMB_WORKERS {
		th := thread.create(thumb_worker, .Low)
		if th == nil { continue }
		th.data = t
		thread.start(th)
		append(&t.workers, th)
	}
}

thumbs_destroy :: proc(a: ^App) {
	t := &a.thumbs
	sync.mutex_lock(&t.mutex)
	t.quit = true
	sync.mutex_unlock(&t.mutex)
	sync.sema_post(&t.sema, len(t.workers))
	for th in t.workers {
		thread.join(th)
		thread.destroy(th)
	}
	delete(t.workers)
	heap := runtime.heap_allocator()
	for job in t.queue { delete(job.key, heap); delete(job.path, heap) }
	delete(t.queue)
	for d in t.done {
		delete(d.key, heap)
		if d.ok { delete(d.img.rgba, heap) }
	}
	delete(t.done)
	for k, &v in t.items {
		delete(k)
		tx.image_destroy(&v.grid)
		tx.image_destroy(&v.list)
	}
	delete(t.items)
	delete(t.cache_dir, heap)
	if t.wake_r >= 0 { posix.close(t.wake_r) }
	if t.wake_w >= 0 { posix.close(t.wake_w) }
}

thumb_key :: proc(path: string, e: ^Entry) -> string {
	return fmt.tprintf("%s|%d|%d", path, e.mtime, e.size)
}

// The thumbnail of an image entry: requested on first use, drawn once ready.
entry_thumb :: proc(a: ^App, dir: string, e: ^Entry, size: Icon_Size) -> (tx.Image, bool) {
	if e.unreadable || e.size <= 0 { return {}, false }
	switch e.kind {
	case .Image:
		if e.size > THUMB_BYTES_MAX || !thumbnailable(e.name) { return {}, false }
	case .Video:
		if g_tools.video == "" { return {}, false } // a frame from the video (any size)
	case .Folder, .Text, .Audio, .Archive, .Pdf, .Code, .Document, .Spreadsheet, .Presentation, .Executable, .Generic, .Broken:
		return {}, false
	}
	if len(a.thumbs.workers) == 0 { return {}, false }
	path := join({dir, e.name})
	key := thumb_key(path, e)
	t := &a.thumbs
	if th, ok := t.items[key]; ok {
		if th.state != .Ready { return {}, false }
		return size == .Grid ? th.grid : th.list, true
	}
	heap := runtime.heap_allocator()
	t.items[strings.clone(key)] = Thumb{state = .Pending}
	job := Thumb_Job{key = strings.clone(key, heap), path = strings.clone(path, heap)}
	sync.mutex_lock(&t.mutex)
	append(&t.queue, job)
	sync.mutex_unlock(&t.mutex)
	sync.sema_post(&t.sema)
	t.pending += 1
	return {}, false
}

// Collect finished thumbnails; true when something new can be drawn.
thumbs_collect :: proc(a: ^App) -> bool {
	t := &a.thumbs
	if t.wake_r >= 0 {
		buf: [64]u8
		for posix.read(t.wake_r, &buf[0], len(buf)) > 0 {}
	}
	sync.mutex_lock(&t.mutex)
	done := t.done
	t.done = {}
	sync.mutex_unlock(&t.mutex)
	if len(done) == 0 { return false }
	heap := runtime.heap_allocator()
	changed := false
	for d in done {
		t.pending = max(t.pending - 1, 0)
		if th, found := &t.items[d.key]; found {
			if d.ok {
				th.grid = fit_image(d.img, GRID_BOX)
				th.list = fit_image(d.img, LIST_ICON)
				th.state = .Ready
				changed = true
			} else {
				th.state = .Failed
			}
		}
		delete(d.key, heap)
		if d.ok { delete(d.img.rgba, heap) }
	}
	delete(done)
	return changed
}

// Folders changed: drop queued work (visible items ask again when drawn) and
// the thumbnails of folders no tab shows any more.
thumbs_forget :: proc(a: ^App) {
	t := &a.thumbs
	heap := runtime.heap_allocator()
	sync.mutex_lock(&t.mutex)
	jobs := t.queue
	t.queue = {}
	sync.mutex_unlock(&t.mutex)
	t.pending = max(t.pending - len(jobs), 0)
	for job in jobs {
		// Its entry would stay Pending forever: forget it so it is asked again.
		if key, _ := delete_key(&t.items, job.key); key != "" { delete(key) }
		delete(job.key, heap)
		delete(job.path, heap)
	}
	delete(jobs)
	prefixes := make([dynamic]string, context.temp_allocator)
	for p in a.panes {
		for tab in p.tabs {
			if tab.dir == "" { continue }
			append(&prefixes, tab.dir == "/" ? "/" : strings.concatenate({tab.dir, "/"}, context.temp_allocator))
		}
	}
	stale := make([dynamic]string, context.temp_allocator)
	outer: for k in t.items {
		for prefix in prefixes {
			if strings.has_prefix(k, prefix) && strings.index_byte(k[len(prefix):], '/') < 0 { continue outer }
		}
		append(&stale, k)
	}
	for k in stale {
		key, th := delete_key(&t.items, k)
		tx.image_destroy(&th.grid)
		tx.image_destroy(&th.list)
		delete(key)
	}
}

@(private)
thumb_worker :: proc(th: ^thread.Thread) {
	t := (^Thumbs)(th.data)
	context.allocator = runtime.heap_allocator()
	for {
		sync.sema_wait(&t.sema)
		sync.mutex_lock(&t.mutex)
		if t.quit {
			sync.mutex_unlock(&t.mutex)
			return
		}
		if len(t.queue) == 0 {
			sync.mutex_unlock(&t.mutex)
			continue
		}
		job := pop(&t.queue)
		sync.mutex_unlock(&t.mutex)

		img, ok := make_thumb(job.path, job.key, t.cache_dir)
		delete(job.path)
		sync.mutex_lock(&t.mutex)
		append(&t.done, Thumb_Done{key = job.key, img = img, ok = ok})
		sync.mutex_unlock(&t.mutex)
		if t.wake_w >= 0 {
			b := u8(1)
			posix.write(t.wake_w, &b, 1)
		}
	}
}

// One thumbnail (from the disk cache or decoded). Runs on a worker thread;
// the result is heap-allocated.
@(private)
make_thumb :: proc(path, key, cache_dir: string) -> (tx.Image, bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return {}, false }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	context.temp_allocator = scratch
	heap := runtime.heap_allocator()

	cache_file := ""
	if cache_dir != "" {
		cache_file = fmt.aprintf("%s/%016x.qoi", cache_dir, hash.fnv64a(transmute([]u8)key), allocator = scratch)
		if data, err := os.read_entire_file(cache_file, scratch); err == nil {
			img, lerr := qoi.load_from_bytes(data, {}, scratch)
			if lerr == nil && img != nil && img.channels == 4 && img.depth == 8 && img.width > 0 && img.height > 0 &&
			   img.width <= THUMB_MAX && img.height <= THUMB_MAX {
				out := tx.image_make(i32(img.width), i32(img.height), heap)
				copy(out.rgba, img.pixels.buf[:])
				return out, true
			}
		}
	}

	src: tx.Image
	ok: bool
	if is_video_path(path) {
		src, ok = video_frame(path, cache_dir, scratch)
	} else {
		src, ok = decode_image(path, scratch)
	}
	if !ok { return {}, false }
	w, h := fit_size(src.w, src.h, THUMB_MAX)
	out := box_resize(src, w, h, heap)

	if cache_file != "" {
		enc: image.Image
		enc.width, enc.height, enc.channels, enc.depth = int(w), int(h), 4, 8
		buf := make([dynamic]u8, len(out.rgba), scratch)
		copy(buf[:], out.rgba)
		enc.pixels = bytes.Buffer{buf = buf}
		tmp := fmt.aprintf("%s.%d.tmp", cache_file, posix.getpid(), allocator = scratch)
		if qoi.save_to_file(tmp, &enc, {}, scratch) == nil {
			if os.rename(tmp, cache_file) != nil { os.remove(tmp) }
		}
	}
	return out, true
}

@(private)
is_video_path :: proc(path: string) -> bool {
	ext := lower_ext(path)
	for v in EXT_VIDEO { if v == ext { return true } }
	return false
}

// A frame of a video (a tenth of the way in, skipping black intros), decoded
// from a temporary PNG written by ffmpegthumbnailer or ffmpeg. Runs on a
// thumbnail worker thread, so waiting for the tool is fine.
@(private)
video_frame :: proc(path, cache_dir: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	dir := cache_dir != "" ? cache_dir : "/tmp"
	tmp := fmt.aprintf("%s/.frame-%d-%016x.png", dir, posix.getpid(), hash.fnv64a(transmute([]u8)path), allocator = scratch)
	defer os.remove(tmp)
	argv: []string
	size := fmt.aprintf("%d", THUMB_MAX, allocator = scratch)
	switch g_tools.video {
	case "ffmpegthumbnailer":
		argv = {"ffmpegthumbnailer", "-i", path, "-o", tmp, "-s", size, "-q", "8", "-c", "png", "-t", "10%"}
	case "ffmpeg":
		argv = {"ffmpeg", "-v", "error", "-y", "-ss", "3", "-i", path, "-frames:v", "1",
		        "-vf", fmt.aprintf("scale=%s:-2", size, allocator = scratch), tmp}
	case:
		return {}, false
	}
	process, err := os.process_start({command = argv})
	if err != nil { return {}, false }
	state, werr := os.process_wait(process, 20 * time.Second)
	if werr != nil || !state.exited {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process, time.Second)
		return {}, false
	}
	if state.exit_code != 0 || !os.is_file(tmp) { return {}, false }
	return decode_image(tmp, scratch)
}

// Decode any supported picture into straight RGBA8 (scratch memory).
@(private)
decode_image :: proc(path: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	ext := lower_ext(path)
	data: []u8
	switch ext {
	case "svg", "svgz":
		if !g_tools.rsvg { return {}, false }
		n := fmt.tprintf("%d", THUMB_MAX)
		state, stdout, _, err := os.process_exec(os.Process_Desc{command = {"rsvg-convert", "-a", "-w", n, "-h", n, path}}, scratch)
		if err != nil || !state.success || len(stdout) == 0 { return {}, false }
		img, lerr := png.load_from_bytes(stdout, {.alpha_add_if_missing}, scratch)
		if lerr != nil || img == nil { return {}, false }
		return image_rgba(img, scratch)
	case "gif", "webp", "tif", "tiff", "avif", "heic", "heif", "jxl", "ico":
		return magick_decode(path, scratch)
	}
	bytes_, rerr := os.read_entire_file(path, scratch)
	if rerr != nil { return {}, false }
	data = bytes_
	img, lerr := image.load_from_bytes(data, {.alpha_add_if_missing}, scratch)
	if lerr == nil && img != nil {
		if out, ok := image_rgba(img, scratch); ok { return out, true }
	}
	// Progressive JPEG and friends: ImageMagick when available.
	return magick_decode(path, scratch)
}

@(private)
magick_decode :: proc(path: string, scratch: runtime.Allocator) -> (tx.Image, bool) {
	if g_tools.magick == "" { return {}, false }
	geometry := fmt.tprintf("%dx%d", THUMB_MAX, THUMB_MAX)
	hint := fmt.tprintf("jpeg:size=%dx%d", THUMB_MAX * 2, THUMB_MAX * 2)
	src := fmt.tprintf("%s[0]", path)
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = {g_tools.magick, "-define", hint, src, "-auto-orient", "-thumbnail", geometry, "png:-"}}, scratch)
	if err != nil || !state.success || len(stdout) == 0 { return {}, false }
	img, lerr := png.load_from_bytes(stdout, {.alpha_add_if_missing}, scratch)
	if lerr != nil || img == nil { return {}, false }
	return image_rgba(img, scratch)
}

// core:image result (1-4 channels, 8 or 16 bits) → straight RGBA8.
@(private)
image_rgba :: proc(img: ^image.Image, allocator: runtime.Allocator) -> (tx.Image, bool) {
	if img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 { return {}, false }
	if img.depth != 8 && img.depth != 16 { return {}, false }
	px := img.pixels.buf[:]
	n := img.width * img.height
	if img.depth == 8 && img.channels == 4 && len(px) >= n * 4 {
		return tx.Image{w = i32(img.width), h = i32(img.height), rgba = px[:n * 4]}, true
	}
	bpc := img.depth / 8
	if len(px) < n * img.channels * bpc { return {}, false }
	out := tx.image_make(i32(img.width), i32(img.height), allocator)
	sample :: #force_inline proc(px: []u8, index, bpc: int) -> u8 {
		return px[index] if bpc == 1 else px[index * 2 + 1]
	}
	for i in 0 ..< n {
		base := i * img.channels
		r, g, b, al: u8
		switch img.channels {
		case 1: r = sample(px, base, bpc); g = r; b = r; al = 255
		case 2: r = sample(px, base, bpc); g = r; b = r; al = sample(px, base + 1, bpc)
		case 3: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); b = sample(px, base + 2, bpc); al = 255
		case 4: r = sample(px, base, bpc); g = sample(px, base + 1, bpc); b = sample(px, base + 2, bpc); al = sample(px, base + 3, bpc)
		}
		out.rgba[i * 4], out.rgba[i * 4 + 1], out.rgba[i * 4 + 2], out.rgba[i * 4 + 3] = r, g, b, al
	}
	return out, true
}

// Size of a w×h picture scaled so that its longer side is at most `box`.
fit_size :: proc(w, h, box: i32) -> (i32, i32) {
	if w <= box && h <= box { return max(w, 1), max(h, 1) }
	if w >= h { return box, max(1, i32(f32(box) * f32(h) / f32(w) + 0.5)) }
	return max(1, i32(f32(box) * f32(w) / f32(h) + 0.5)), box
}

// Downscale with an integer box filter (alpha-weighted colour).
box_resize :: proc(src: tx.Image, dw, dh: i32, allocator := context.allocator) -> tx.Image {
	dst := tx.image_make(dw, dh, allocator)
	if src.w <= 0 || src.h <= 0 { return dst }
	if src.w == dw && src.h == dh {
		copy(dst.rgba, src.rgba)
		return dst
	}
	stride := int(src.w)
	for y in 0 ..< int(dh) {
		sy0 := clamp(y * int(src.h) / int(dh), 0, int(src.h) - 1)
		sy1 := clamp((y + 1) * int(src.h) / int(dh), sy0 + 1, int(src.h))
		for x in 0 ..< int(dw) {
			sx0 := clamp(x * int(src.w) / int(dw), 0, int(src.w) - 1)
			sx1 := clamp((x + 1) * int(src.w) / int(dw), sx0 + 1, int(src.w))
			r, g, b, al, n: u64
			for sy in sy0 ..< sy1 {
				row := sy * stride
				for sx in sx0 ..< sx1 {
					i := (row + sx) * 4
					pa := u64(src.rgba[i + 3])
					r += u64(src.rgba[i]) * pa
					g += u64(src.rgba[i + 1]) * pa
					b += u64(src.rgba[i + 2]) * pa
					al += pa
					n += 1
				}
			}
			o := (y * int(dw) + x) * 4
			if al > 0 {
				dst.rgba[o] = u8(r / al)
				dst.rgba[o + 1] = u8(g / al)
				dst.rgba[o + 2] = u8(b / al)
				dst.rgba[o + 3] = u8(al / n)
			}
		}
	}
	return dst
}

// A copy scaled to fit a box×box square (never upscaled).
fit_image :: proc(src: tx.Image, box: i32, allocator := context.allocator) -> tx.Image {
	w, h := fit_size(src.w, src.h, box)
	return box_resize(src, w, h, allocator)
}
