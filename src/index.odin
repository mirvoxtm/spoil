// The disk index behind "Buscar no disco", in the spirit of Everything by
// voidtools: every name on the local disks, kept compactly (one buffer of
// names, a parent index and a few flag bits per entry: 13 bytes plus the
// name) so that a query can scan all of them in a few milliseconds.
//
// A background thread walks every real mounted file system from / with
// getdents and d_type, so nothing is stat'ed while indexing. The mount table
// decides what is skipped: /proc, /sys, /dev and /run, and pseudo, network and
// FUSE file systems; btrfs subvolumes and other disks are followed, and real
// disks mounted under /run (/run/media/...) become roots of their own.
// Symlinked folders are not followed and unreadable folders are left out.
//
// Entries are stored folder by folder: the children of a folder are
// contiguous and sorted by name, and the folders come in path order, so the
// storage order is the order of the "Pasta" column; `by_name` is the name
// order. The index is saved to ~/.cache/milk/spoil-index.bin (a header and the
// raw arrays) and memory-mapped at the next start.
package spoil

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

INDEX_VERSION :: 1
INDEX_STALE   :: 10 * 60 // seconds: an older index is rescanned while a search tab is open
NO_PARENT     :: max(u32)
PATH_BUF      :: 8192    // paths are built backwards in buffers this large

Index_Flag :: enum u8 {
	Dir,    // a directory (a symlink to one is a Link, never followed)
	Fold,   // the name has capitals or non-ASCII letters: fold it before comparing
	Hidden, // the name or one of its folders starts with a dot
	Link,   // a symbolic link
}
Index_Flags :: bit_set[Index_Flag; u8]

Index :: struct {
	count:    int,
	dirs:     int,
	parent:   []u32,         // NO_PARENT for the roots ("/" and disks mounted under a skipped folder)
	name_off: []u32,         // count + 1 offsets: the name of i is names[name_off[i]:name_off[i + 1]]
	flags:    []Index_Flags,
	by_name:  []u32,         // entries in name order
	names:    []u8,
	scanned:  i64,           // unix time the walk started
	walk_ms:  f64,
	mapped:   []u8,          // the cache file, when the arrays point into it
}

@(private="file")
Index_Header :: struct #packed {
	magic:     [8]u8,
	version:   u32,
	order:     u32, // 0x01020304 in the writer's byte order
	count:     u64,
	names_len: u64,
	dirs:      u64,
	scanned:   i64,
	walk_ms:   f64,
	_:         [8]u8,
}
#assert(size_of(Index_Header) == 64)

@(private="file", rodata)
INDEX_MAGIC := [8]u8{'S', 'P', 'O', 'I', 'L', 'I', 'D', 'X'}

index_name :: #force_inline proc(ix: ^Index, i: u32) -> string {
	return string(ix.names[ix.name_off[i]:ix.name_off[i + 1]])
}

index_destroy :: proc(ix: ^Index) {
	if ix == nil { return }
	if ix.mapped != nil {
		posix.munmap(raw_data(ix.mapped), uint(len(ix.mapped)))
	} else {
		delete(ix.parent)
		delete(ix.name_off)
		delete(ix.flags)
		delete(ix.by_name)
		delete(ix.names)
	}
	free(ix)
}

// Full path of entry `i`, written backwards into the end of `buf`.
index_path :: proc(ix: ^Index, i: u32, buf: []u8) -> string {
	end := len(buf)
	pos := end
	j := i
	for {
		name := index_name(ix, j)
		up := ix.parent[j]
		if up == NO_PARENT {
			// "/" has an empty name; other roots carry their whole path.
			if name == "" {
				if pos == end && pos > 0 {
					pos -= 1
					buf[pos] = '/'
				}
			} else if pos >= len(name) {
				pos -= len(name)
				copy(buf[pos:], name)
			}
			break
		}
		if pos < len(name) + 1 { break }
		pos -= len(name)
		copy(buf[pos:], name)
		pos -= 1
		buf[pos] = '/'
		j = up
	}
	return string(buf[pos:end])
}

// The same path folded (lower case, no accents) for matching.
index_path_folded :: proc(ix: ^Index, i: u32, buf: []u8) -> string {
	end := len(buf)
	pos := end
	j := i
	tmp: [1024]u8
	for {
		name := index_name(ix, j)
		if .Fold in ix.flags[j] { name = fold_to(tmp[:], name) }
		up := ix.parent[j]
		if up == NO_PARENT {
			if name == "" {
				if pos == end && pos > 0 {
					pos -= 1
					buf[pos] = '/'
				}
			} else if pos >= len(name) {
				pos -= len(name)
				copy(buf[pos:], name)
			}
			break
		}
		if pos < len(name) + 1 { break }
		pos -= len(name)
		copy(buf[pos:], name)
		pos -= 1
		buf[pos] = '/'
		j = up
	}
	return string(buf[pos:end])
}

// ---------------------------------------------------------------------------
// Folding (the same as sort_key, without allocating)
// ---------------------------------------------------------------------------

// Does `name` change when folded (capitals, accents, any non-ASCII byte)?
needs_fold :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 0x80 || (c >= 'A' && c <= 'Z') { return true }
	}
	return false
}

// Fold `s` into `dst` (truncated when it does not fit).
fold_to :: proc(dst: []u8, s: string) -> string {
	n := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c < 0x80 {
			if n >= len(dst) { break }
			dst[n] = c >= 'A' && c <= 'Z' ? c + 32 : c
			n += 1
			i += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(s[i:])
		i += size
		b, w := utf8.encode_rune(fold_rune(r))
		if n + w > len(dst) { break }
		copy(dst[n:], b[:w])
		n += w
	}
	return string(dst[:n])
}

// ---------------------------------------------------------------------------
// Mount table
// ---------------------------------------------------------------------------
@(rodata)
SKIP_FS := []string{
	"proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "ramfs", "cgroup", "cgroup2", "securityfs", "debugfs",
	"tracefs", "bpf", "pstore", "efivarfs", "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs",
	"binfmt_misc", "rpc_pipefs", "nsfs", "overlay", "squashfs", "selinuxfs", "nfsd", "devfs", "fuse",
	"nfs", "nfs4", "cifs", "smb3", "smbfs", "ncpfs", "9p", "afs", "ceph", "glusterfs", "davfs", "sshfs",
}

@(rodata)
SKIP_PATHS := []string{"/proc", "/sys", "/dev", "/run"}

// Octal escapes of /proc/self/mounts ("\040" is a space).
@(private="file")
unescape_mount :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 3 < len(s) {
			v := 0
			ok := true
			for k in 1 ..= 3 {
				if s[i + k] < '0' || s[i + k] > '7' { ok = false; break }
				v = v * 8 + int(s[i + k] - '0')
			}
			if ok {
				append(&out, u8(v))
				i += 3
				continue
			}
		}
		append(&out, s[i])
	}
	return string(out[:])
}

@(private="file")
skipped_fs :: proc(fstype: string) -> bool {
	if fstype == "fuseblk" { return false } // ntfs-3g and other disks through FUSE
	if strings.has_prefix(fstype, "fuse.") { return true }
	for s in SKIP_FS { if s == fstype { return true } }
	return false
}

@(private="file")
under :: proc(path, dir: string) -> bool {
	if dir == "/" { return true }
	return path == dir || (strings.has_prefix(path, dir) && len(path) > len(dir) && path[len(dir)] == '/')
}

// The folders the walk starts from ("/" and real disks mounted inside a
// skipped folder, or the folders in $SPOIL_INDEX_ROOTS, separated by ":")
// and the folders it must not enter (temp allocator).
index_plan :: proc() -> (roots: []string, skip: map[string]bool) {
	skip = make(map[string]bool, 64, context.temp_allocator)
	for s in SKIP_PATHS { skip[s] = true }
	real := make([dynamic]string, context.temp_allocator)
	data, err := os.read_entire_file("/proc/self/mounts", context.temp_allocator)
	if err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) < 3 { continue }
			mnt := unescape_mount(fields[1])
			if skipped_fs(fields[2]) {
				if mnt != "/" { skip[mnt] = true }
			} else {
				append(&real, mnt)
			}
		}
	}
	list := make([dynamic]string, context.temp_allocator)
	if v, found := os.lookup_env("SPOIL_INDEX_ROOTS", context.temp_allocator); found && strings.trim_space(v) != "" {
		for r in strings.split(v, ":", context.temp_allocator) {
			if r != "" && is_directory(r) { append(&list, clean_path(r)) }
		}
		if len(list) > 0 { return list[:], skip }
	}
	append(&list, "/")
	// Longest first would nest; shortest first lets a disk's own sub-mounts ride along.
	slice.sort_by(real[:], proc(a, b: string) -> bool { return len(a) < len(b) })
	outer: for m in real {
		if m == "/" || m in skip { continue }
		inside_skip := false
		for s in SKIP_PATHS { if under(m, s) { inside_skip = true } }
		for s in skip { if under(m, s) { inside_skip = true } }
		if !inside_skip { continue } // reached by the walk from "/"
		for r in list[1:] { if under(m, r) { continue outer } }
		append(&list, m)
	}
	return list[:], skip
}

// ---------------------------------------------------------------------------
// Walking
// ---------------------------------------------------------------------------
@(private="file")
Dent :: struct {
	name:  u32, // offset of the name in the walker's sbuf
	key:   u32, // offset of the folded name (fbuf when .Fold, else sbuf)
	nlen:  u16,
	klen:  u16,
	flags: Index_Flags,
}

@(private="file")
Walker :: struct {
	parent:   [dynamic]u32,
	name_off: [dynamic]u32,
	flags:    [dynamic]Index_Flags,
	names:    [dynamic]u8,
	dirs:     int,
	path:     [dynamic]u8,
	dents:    []u8,
	batch:    [dynamic]Dent, // one folder's entries, before sorting
	sbuf:     [dynamic]u8,
	fbuf:     [dynamic]u8,
	skip:     map[string]bool,
	progress: ^int,
	quit:     ^bool,
}

@(private="file", thread_local)
g_walker: ^Walker

@(private="file")
dent_key :: #force_inline proc(w: ^Walker, d: Dent) -> string {
	buf := .Fold in d.flags ? w.fbuf[:] : w.sbuf[:]
	return string(buf[d.key:][:d.klen])
}

@(private="file")
dent_less :: proc(a, b: Dent) -> bool {
	w := g_walker
	ka, kb := dent_key(w, a), dent_key(w, b)
	if ka != kb { return natural_less(ka, kb) }
	return string(w.sbuf[a.name:][:a.nlen]) < string(w.sbuf[b.name:][:b.nlen])
}

// Read folder `idx` (its path is w.path), append its sorted children as one
// block, then walk its subfolders in order.
@(private="file")
walk_dir :: proc(w: ^Walker, idx: u32) {
	if sync.atomic_load(w.quit) { return }
	append(&w.path, 0)
	fd, err := linux.open(cstring(raw_data(w.path)), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	pop(&w.path)
	if err != .NONE { return } // unreadable: left out silently
	clear(&w.batch)
	clear(&w.sbuf)
	clear(&w.fbuf)
	hidden := .Hidden in w.flags[idx]
	for {
		n, derr := linux.getdents(fd, w.dents)
		if derr != .NONE || n <= 0 { break }
		off := 0
		for de in linux.dirent_iterate_buf(w.dents[:n], &off) {
			name := linux.dirent_name(de)
			if name == "." || name == ".." || name == "" || len(name) > 255 { continue }
			flags: Index_Flags
			kind := de.type
			if kind == .UNKNOWN {
				// Some file systems do not fill d_type: ask this one entry.
				st: linux.Stat
				if linux.fstatat(fd, cstring(raw_data(name)), &st, {.SYMLINK_NOFOLLOW}) == .NONE {
					if linux.S_ISDIR(st.mode) { kind = .DIR } else if linux.S_ISLNK(st.mode) { kind = .LNK }
				}
			}
			if kind == .DIR { flags += {.Dir} } else if kind == .LNK { flags += {.Link} }
			if hidden || name[0] == '.' { flags += {.Hidden} }
			d := Dent{name = u32(len(w.sbuf)), nlen = u16(len(name)), flags = flags}
			append(&w.sbuf, name)
			if needs_fold(name) {
				d.flags += {.Fold}
				d.key = u32(len(w.fbuf))
				tmp: [1024]u8
				append(&w.fbuf, fold_to(tmp[:], name))
				d.klen = u16(u32(len(w.fbuf)) - d.key)
			} else {
				d.key, d.klen = d.name, d.nlen
			}
			append(&w.batch, d)
		}
	}
	linux.close(fd)
	g_walker = w
	slice.sort_by(w.batch[:], dent_less)
	first := u32(len(w.parent))
	for d in w.batch {
		append(&w.parent, idx)
		append(&w.name_off, u32(len(w.names)))
		append(&w.names, string(w.sbuf[d.name:][:d.nlen]))
		append(&w.flags, d.flags)
		if .Dir in d.flags { w.dirs += 1 }
	}
	last := u32(len(w.parent))
	sync.atomic_store(w.progress, int(last))
	if len(w.names) > int(max(u32)) - 64 * 1024 { return } // the name offsets are 32-bit

	base := len(w.path)
	for i in first ..< last {
		if .Dir not_in w.flags[i] { continue }
		end := i + 1 < u32(len(w.name_off)) ? w.name_off[i + 1] : u32(len(w.names))
		name := string(w.names[w.name_off[i]:end])
		if base > 1 { append(&w.path, '/') }
		append(&w.path, name)
		// btrfs snapshots (snapper) would repeat the whole disk.
		if string(w.path[:]) not_in w.skip && name != ".snapshots" { walk_dir(w, i) }
		resize(&w.path, base)
	}
}

// Walk the disks into a new index; nil when `quit` interrupted it.
index_build :: proc(progress: ^int, quit: ^bool) -> ^Index {
	started := posix.time(nil)
	t0 := now_ms()
	roots, skip := index_plan()
	w: Walker
	w.skip = skip
	w.progress = progress
	w.quit = quit
	w.dents = make([]u8, 64 * 1024)
	defer {
		delete(w.dents)
		delete(w.path)
		delete(w.batch)
		delete(w.sbuf)
		delete(w.fbuf)
	}
	reserve(&w.parent, 1 << 20)
	reserve(&w.name_off, 1 << 20)
	reserve(&w.flags, 1 << 20)
	reserve(&w.names, 32 << 20)
	for root in roots {
		idx := u32(len(w.parent))
		append(&w.parent, NO_PARENT)
		append(&w.name_off, u32(len(w.names)))
		append(&w.names, root == "/" ? "" : root)
		append(&w.flags, Index_Flags{.Dir})
		w.dirs += 1
		clear(&w.path)
		append(&w.path, root)
		walk_dir(&w, idx)
	}
	append(&w.name_off, u32(len(w.names)))
	if sync.atomic_load(quit) {
		delete(w.parent)
		delete(w.name_off)
		delete(w.flags)
		delete(w.names)
		return nil
	}
	ix := new(Index)
	ix.count = len(w.parent)
	ix.dirs = w.dirs
	ix.parent = exact(w.parent)
	ix.name_off = exact(w.name_off)
	ix.flags = exact(w.flags)
	ix.names = exact(w.names)
	ix.scanned = i64(started)
	ix.by_name = name_order(ix)
	ix.walk_ms = now_ms() - t0
	return ix
}

// A dynamic array as an exact-size slice (the spare capacity released).
@(private="file")
exact :: proc(d: [dynamic]$T) -> []T {
	out := make([]T, len(d))
	copy(out, d[:])
	delete(d)
	return out
}

now_ms :: proc() -> f64 {
	return f64(time.tick_now()._nsec) / 1e6
}

// ---------------------------------------------------------------------------
// Name order
// ---------------------------------------------------------------------------
@(private="file", thread_local)
g_sort_ix: ^Index
@(private="file", thread_local)
g_fold_a: [1024]u8
@(private="file", thread_local)
g_fold_b: [1024]u8

@(private="file")
name_less :: proc(a, b: u32) -> bool {
	ix := g_sort_ix
	na, nb := index_name(ix, a), index_name(ix, b)
	ka := .Fold in ix.flags[a] ? fold_to(g_fold_a[:], na) : na
	kb := .Fold in ix.flags[b] ? fold_to(g_fold_b[:], nb) : nb
	if ka != kb { return natural_less(ka, kb) }
	if na != nb { return na < nb }
	return a < b // same name: path order
}

@(private="file")
Sort_Part :: struct {
	ix:   ^Index,
	part: []u32,
}

@(private="file")
sort_part :: proc(p: ^Sort_Part) {
	g_sort_ix = p.ix
	slice.sort_by(p.part, name_less)
}

// Every entry in name order: parts sorted on their own threads, then merged.
@(private="file")
name_order :: proc(ix: ^Index) -> []u32 {
	n := ix.count
	order := make([]u32, n)
	for &o, i in order { o = u32(i) }
	k := n < 200_000 ? 1 : clamp(os.get_processor_core_count(), 1, 8)
	parts := make([]Sort_Part, k)
	defer delete(parts)
	for i in 0 ..< k {
		parts[i] = {ix = ix, part = order[n * i / k:n * (i + 1) / k]}
	}
	fan_out(sort_part, parts)
	if k == 1 { return order }
	// Merge the sorted parts pairwise.
	g_sort_ix = ix
	src := order
	dst := make([]u32, n)
	runs := make([dynamic][2]int, context.temp_allocator)
	for i in 0 ..< k { append(&runs, [2]int{n * i / k, n * (i + 1) / k}) }
	for len(runs) > 1 {
		next := make([dynamic][2]int, context.temp_allocator)
		for r := 0; r < len(runs); r += 2 {
			if r + 1 >= len(runs) {
				copy(dst[runs[r][0]:runs[r][1]], src[runs[r][0]:runs[r][1]])
				append(&next, runs[r])
				continue
			}
			lo, mid, hi := runs[r][0], runs[r][1], runs[r + 1][1]
			i, j, o := lo, mid, lo
			for i < mid && j < hi {
				if name_less(src[j], src[i]) {
					dst[o] = src[j]
					j += 1
				} else {
					dst[o] = src[i]
					i += 1
				}
				o += 1
			}
			for i < mid { dst[o] = src[i]; i += 1; o += 1 }
			for j < hi { dst[o] = src[j]; j += 1; o += 1 }
			append(&next, [2]int{lo, hi})
		}
		runs = next
		src, dst = dst, src
	}
	delete(dst)
	return src
}

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

// fn on every item, each on a thread of its own (the first one here); runs
// inline when no thread can be made.
fan_out :: proc(fn: proc(^$T), items: []T) {
	threads := make([dynamic]^thread.Thread, 0, len(items), context.temp_allocator)
	for i in 1 ..< len(items) {
		th := thread.create_and_start_with_poly_data(&items[i], fn)
		if th == nil { fn(&items[i]) } else { append(&threads, th) }
	}
	if len(items) > 0 { fn(&items[0]) }
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
}

// ---------------------------------------------------------------------------
// Cache file
// ---------------------------------------------------------------------------
index_cache_path :: proc() -> string { return join({cache_home(), "milk", "spoil-index.bin"}) }

@(private="file")
align4 :: #force_inline proc(n: int) -> int { return (n + 3) &~ 3 }

// Byte offsets of the arrays in the file.
@(private="file")
file_layout :: proc(count, names_len: int) -> (parent, name_off, flags, by_name, names, total: int) {
	parent = size_of(Index_Header)
	name_off = parent + 4 * count
	flags = name_off + 4 * (count + 1)
	by_name = align4(flags + count)
	names = by_name + 4 * count
	total = names + names_len
	return
}

// Write the index atomically (a temporary file renamed over the old one).
index_save :: proc(ix: ^Index, path: string) -> bool {
	_ = os.make_directory_all(parent_dir(path))
	tmp := fmt.tprintf("%s.%d.tmp", path, posix.getpid())
	f, err := os.create(tmp)
	if err != nil { return false }
	h := Index_Header{magic = INDEX_MAGIC, version = INDEX_VERSION, order = 0x01020304, count = u64(ix.count),
	                  names_len = u64(len(ix.names)), dirs = u64(ix.dirs), scanned = ix.scanned, walk_ms = ix.walk_ms}
	_, _, flags_at, by_name_at, _, _ := file_layout(ix.count, len(ix.names))
	pad := [4]u8{}
	ok := true
	write :: proc(f: ^os.File, b: []u8, ok: ^bool) {
		if !ok^ { return }
		n, werr := os.write(f, b)
		if werr != nil || n != len(b) { ok^ = false }
	}
	write(f, ([^]u8)(&h)[:size_of(h)], &ok)
	write(f, slice.to_bytes(ix.parent), &ok)
	write(f, slice.to_bytes(ix.name_off), &ok)
	write(f, slice.to_bytes(ix.flags), &ok)
	write(f, pad[:by_name_at - (flags_at + ix.count)], &ok)
	write(f, slice.to_bytes(ix.by_name), &ok)
	write(f, ix.names, &ok)
	os.close(f)
	if !ok || os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// The scan time recorded in the cache file (0 = no usable file).
index_file_scanned :: proc(path: string) -> i64 {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {})
	if fd < 0 { return 0 }
	defer posix.close(fd)
	h: Index_Header
	if posix.read(fd, ([^]u8)(&h), size_of(h)) != size_of(h) { return 0 }
	if h.magic != INDEX_MAGIC || h.version != INDEX_VERSION || h.order != 0x01020304 { return 0 }
	return h.scanned
}

// Map the cache file (read-only, shared with the page cache); nil when it is
// missing or does not look right.
index_load :: proc(path: string) -> ^Index {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {})
	if fd < 0 { return nil }
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size < size_of(Index_Header) { return nil }
	size := int(st.st_size)
	p := posix.mmap(nil, uint(size), {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED { return nil }
	data := ([^]u8)(p)[:size]
	h := (^Index_Header)(p)^
	count := int(h.count)
	names_len := int(h.names_len)
	parent_at, name_off_at, flags_at, by_name_at, names_at, total := file_layout(count, names_len)
	if h.magic != INDEX_MAGIC || h.version != INDEX_VERSION || h.order != 0x01020304 || count <= 0 || total != size {
		posix.munmap(p, uint(size))
		return nil
	}
	ix := new(Index)
	ix.mapped = data
	ix.count = count
	ix.dirs = int(h.dirs)
	ix.scanned = h.scanned
	ix.walk_ms = h.walk_ms
	ix.parent = slice.reinterpret([]u32, data[parent_at:name_off_at])
	ix.name_off = slice.reinterpret([]u32, data[name_off_at:flags_at])
	ix.flags = slice.reinterpret([]Index_Flags, data[flags_at:flags_at + count])
	ix.by_name = slice.reinterpret([]u32, data[by_name_at:names_at])
	ix.names = data[names_at:total]
	if int(ix.name_off[count]) != names_len {
		index_destroy(ix)
		return nil
	}
	return ix
}
