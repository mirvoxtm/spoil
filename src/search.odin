// "Buscar no disco": searching every file name on the disk as you type, in
// the spirit of Everything by voidtools, over the index of index.odin.
//
// A search tab (Ctrl+Shift+F, or the magnifier next to the tab strip) is a
// tab whose field holds the query and whose entries are the results, each
// with its own folder; the list view shows Nome, Pasta, Tamanho, Modificado
// and the usual file actions work on them.
//
// Query syntax: words separated by spaces must all match (AND); `a|b` is OR;
// `!word` excludes; `*` and `?` are wildcards that match the whole name;
// "quoted text" keeps its spaces; `ext:png;jpg` keeps those extensions,
// `file:` / `folder:` one kind, and `path:word` (or any word with a "/")
// matches the whole path instead of the name. Matching ignores case and
// accents ("musica" finds "Música").
//
// Queries run on a worker thread, which fans the scan out over a few threads
// and marks matches in a bitset; the listed results (at most SEARCH_CAP, in
// name order through the index's name permutation, or in folder order, which
// is the storage order) are then stat'ed in the background for their size and
// date. A newer query cancels the running one. A second thread keeps the index:
// it maps the saved one at start, walks the disk when there is none or when it
// is older than INDEX_STALE while a search tab is open, and on "Reindexar".
package spoil

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import tx "milk:tx"

SEARCH_CAP        :: 5000  // results listed (all matches are counted)
SEARCH_SORT_LIMIT :: 20000 // matches stat'ed to sort by size or date

Search_Sort :: enum { Name, Path, Size, Date }

// The state of a search tab (its query is the tab's `search` field).
Search_Tab :: struct {
	gen:      u64,  // the last query sent
	shown:    u64,  // the query whose results are listed
	total:    int,  // matches before the cap (hidden ones left out)
	hidden:   int,  // matches left out because they are hidden
	ms:       f64,
	sort:     Search_Sort,
	desc:     bool,
	busy:     bool, // the query or its stat pass is running
	no_index: bool, // the last query found no index yet
}

Stat_Info :: struct {
	size:       i64,
	mtime:      i64,
	kind:       File_Kind,
	is_dir:     bool,
	is_link:    bool,
	unreadable: bool,
	gone:       bool, // no longer exists (the index is older than the disk)
}

Index_Info :: struct {
	ready:   bool,
	count:   int,
	dirs:    int,
	scanned: i64,
	walk_ms: f64,
}

@(private="file")
Search_Request :: struct {
	tab:         int,
	gen:         u64,
	text:        string, // heap
	sort:        Search_Sort,
	desc:        bool,
	show_hidden: bool,
	preserve:    bool,
}

@(private="file")
Search_Item :: struct {
	name:   string, // heap
	dir:    string, // heap
	flags:  Index_Flags,
	st:     Stat_Info,
	has_st: bool,
}

@(private="file")
Msg_Kind :: enum { Results, Stats, Stats_Done, Index_Changed }

@(private="file")
Search_Msg :: struct {
	kind:     Msg_Kind,
	tab:      int,
	gen:      u64,
	items:    [dynamic]Search_Item, // Results (heap)
	stats:    [dynamic]Stat_Info,   // Stats (heap), for items start ..< start + len
	start:    int,
	total:    int,
	hidden:   int,
	ms:       f64,
	preserve: bool,
	no_index: bool,
}

Search_Service :: struct {
	mutex:       sync.Mutex,
	work:        sync.Sema,           // wakes the search worker
	poke:        sync.Sema,           // wakes the indexer
	quit:        bool,                // atomic
	requests:    [dynamic]Search_Request, // guarded by mutex (one per tab)
	running_tab: int,                 // guarded
	cancel:      bool,                // atomic: the running query was superseded
	queued:      int,                 // atomic: requests waiting
	next_index:  ^Index,              // guarded: handed from the indexer to the worker
	msgs:        [dynamic]Search_Msg, // guarded
	info:        Index_Info,          // guarded
	indexing:    bool,                // atomic
	progress:    int,                 // atomic: entries walked so far
	wanted:      bool,                // atomic: a search tab is open (keep the index fresh)
	force:       bool,                // atomic: "Reindexar"
	index:       ^Index,              // the worker's own
	threads:     int,
	worker:      ^thread.Thread,
	indexer:     ^thread.Thread,
	wake_r:      posix.FD,
	wake_w:      posix.FD,
	cache_path:  string,              // heap
	lock_path:   string,              // heap
	next_gen:    u64,                 // UI thread
	shown_progress: int,              // UI thread: the count drawn last
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------
search_init :: proc(a: ^App) {
	s := &a.search
	s.wake_r, s.wake_w = -1, -1
	s.running_tab = -1
	fds: [2]posix.FD
	if posix.pipe(&fds) == .OK {
		s.wake_r, s.wake_w = fds[0], fds[1]
		for fd in fds {
			flags := posix.fcntl(fd, .GETFL)
			posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
			posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
		}
	}
	heap := runtime.heap_allocator()
	s.cache_path = strings.clone(index_cache_path(), heap)
	s.lock_path = strings.clone(join({cache_home(), "milk", "spoil-index.lock"}), heap)
	s.threads = clamp(os.get_processor_core_count(), 1, 8)
	s.worker = thread.create_and_start_with_poly_data(s, search_worker)
	s.indexer = thread.create_and_start_with_poly_data(s, indexer_main, priority = .Low)
}

search_destroy :: proc(a: ^App) {
	s := &a.search
	sync.atomic_store(&s.quit, true)
	sync.atomic_store(&s.cancel, true)
	sync.sema_post(&s.work)
	sync.sema_post(&s.poke)
	for th in ([]^thread.Thread{s.worker, s.indexer}) {
		if th == nil { continue }
		thread.join(th)
		thread.destroy(th)
	}
	heap := runtime.heap_allocator()
	for r in s.requests { delete(r.text, heap) }
	delete(s.requests)
	for &m in s.msgs { msg_free(&m) }
	delete(s.msgs)
	index_destroy(s.index)
	index_destroy(s.next_index)
	delete(s.cache_path, heap)
	delete(s.lock_path, heap)
	if s.wake_r >= 0 { posix.close(s.wake_r) }
	if s.wake_w >= 0 { posix.close(s.wake_w) }
	s^ = {}
}

@(private="file")
msg_free :: proc(m: ^Search_Msg) {
	heap := runtime.heap_allocator()
	for it in m.items {
		delete(it.name, heap)
		delete(it.dir, heap)
	}
	delete(m.items)
	delete(m.stats)
	m.items, m.stats = nil, nil
}

@(private="file")
post :: proc(s: ^Search_Service, m: Search_Msg) {
	sync.mutex_lock(&s.mutex)
	append(&s.msgs, m)
	sync.mutex_unlock(&s.mutex)
	wake(s)
}

@(private="file")
wake :: proc(s: ^Search_Service) {
	if s.wake_w >= 0 {
		b := u8(1)
		posix.write(s.wake_w, &b, 1)
	}
}

// What the status line shows about the index.
search_index_info :: proc(a: ^App) -> Index_Info {
	s := &a.search
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return s.info
}

search_indexing :: proc(a: ^App) -> (bool, int) {
	return sync.atomic_load(&a.search.indexing), sync.atomic_load(&a.search.progress)
}

// "Reindexar": walk the disk again now.
search_reindex :: proc(a: ^App) {
	if busy, _ := search_indexing(a); busy { return }
	sync.atomic_store(&a.search.force, true)
	sync.sema_post(&a.search.poke)
	set_notice(a, tr(a, "Reindexando o disco…", "Reindexing the disk…"))
}

// ---------------------------------------------------------------------------
// Indexer thread
// ---------------------------------------------------------------------------
@(private="file")
indexer_main :: proc(s: ^Search_Service) {
	context.allocator = runtime.heap_allocator()
	// Walk the disk politely: a lower CPU and I/O priority for this thread.
	tid := i32(linux.gettid())
	linux.setpriority(.PROCESS, tid, 10)
	IOPRIO_CLASS_BE :: 2
	linux.syscall(linux.SYS_ioprio_set, 1, uintptr(tid), uintptr(IOPRIO_CLASS_BE << 13 | 7))

	if ix := index_load(s.cache_path); ix != nil {
		log.debugf("Index: %d entries from %s", ix.count, s.cache_path)
		hand_over(s, ix)
	}
	for !sync.atomic_load(&s.quit) {
		force := sync.atomic_exchange(&s.force, false)
		sync.mutex_lock(&s.mutex)
		info := s.info
		sync.mutex_unlock(&s.mutex)
		now := i64(posix.time(nil))
		// Another Spoil may have written a newer index meanwhile.
		if !force {
			if on_disk := index_file_scanned(s.cache_path); on_disk > info.scanned {
				if ix := index_load(s.cache_path); ix != nil {
					hand_over(s, ix)
					continue
				}
			}
		}
		stale := now - info.scanned > INDEX_STALE && sync.atomic_load(&s.wanted)
		if force || !info.ready || stale { rescan(s) }
		free_all(context.temp_allocator)
		sync.mutex_lock(&s.mutex)
		ready := s.info.ready
		sync.mutex_unlock(&s.mutex)
		sync.sema_wait_with_timeout(&s.poke, ready ? 60 * time.Second : 5 * time.Second)
	}
}

@(private="file")
hand_over :: proc(s: ^Search_Service, ix: ^Index) {
	sync.mutex_lock(&s.mutex)
	if s.next_index != nil { index_destroy(s.next_index) }
	s.next_index = ix
	s.info = {ready = true, count = ix.count, dirs = ix.dirs, scanned = ix.scanned, walk_ms = ix.walk_ms}
	sync.mutex_unlock(&s.mutex)
	sync.sema_post(&s.work)
	wake(s)
}

// Walk the disk into a new index, save it and hand it over. Another Spoil
// already walking (the lock is taken) is left alone: its file is picked up.
@(private="file")
rescan :: proc(s: ^Search_Service) {
	_ = os.make_directory_all(parent_dir(s.lock_path))
	lock := posix.open(strings.clone_to_cstring(s.lock_path, context.temp_allocator), {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if lock >= 0 && linux.flock(linux.Fd(lock), {.EX, .NB}) != .NONE {
		posix.close(lock)
		log.debug("Index: another Spoil is indexing")
		return
	}
	defer if lock >= 0 { posix.close(lock) }
	sync.atomic_store(&s.progress, 0)
	sync.atomic_store(&s.indexing, true)
	wake(s)
	defer {
		sync.atomic_store(&s.indexing, false)
		wake(s)
	}
	ix := index_build(&s.progress, &s.quit)
	if ix == nil { return }
	log.infof("Index: %d entries (%d folders) in %.1f s", ix.count, ix.dirs, ix.walk_ms / 1000)
	if index_save(ix, s.cache_path) {
		// The saved file, mapped, costs no private memory.
		if mapped := index_load(s.cache_path); mapped != nil {
			index_destroy(ix)
			ix = mapped
		}
	} else {
		log.warnf("Index: cannot write %s", s.cache_path)
	}
	hand_over(s, ix)
}

// ---------------------------------------------------------------------------
// Search worker
// ---------------------------------------------------------------------------
@(private="file")
search_worker :: proc(s: ^Search_Service) {
	context.allocator = runtime.heap_allocator()
	for {
		sync.sema_wait(&s.work)
		if sync.atomic_load(&s.quit) { break }
		sync.mutex_lock(&s.mutex)
		fresh := s.next_index
		s.next_index = nil
		req: Search_Request
		has := len(s.requests) > 0
		if has {
			req = pop_front(&s.requests)
			s.running_tab = req.tab
			sync.atomic_store(&s.cancel, false)
		}
		sync.atomic_store(&s.queued, len(s.requests))
		sync.mutex_unlock(&s.mutex)
		if fresh != nil {
			index_destroy(s.index)
			s.index = fresh
			post(s, {kind = .Index_Changed})
		}
		if has {
			run_query(s, &req)
			delete(req.text)
			sync.mutex_lock(&s.mutex)
			s.running_tab = -1
			sync.mutex_unlock(&s.mutex)
		}
		free_all(context.temp_allocator)
	}
}

@(private="file")
stale_work :: proc(s: ^Search_Service) -> bool {
	return sync.atomic_load(&s.cancel) || sync.atomic_load(&s.quit)
}

// Scan the whole index for `q`: matches marked in `bits` (count+63)/64 words.
search_scan :: proc(ix: ^Index, q: ^Query, bits: []u64, show_hidden: bool, cancel: ^bool, threads: int) -> (total, hidden: int, ok: bool) {
	k := ix.count < 100_000 ? 1 : max(threads, 1)
	jobs := make([]Scan_Job, k, context.temp_allocator)
	// Chunks of whole cache lines of the bitset (512 entries).
	per := ((ix.count + k - 1) / k + 511) &~ 511
	for i in 0 ..< k {
		lo := min(i * per, ix.count)
		hi := min(lo + per, ix.count)
		jobs[i] = {ix = ix, q = q, lo = lo, hi = hi, bits = bits, show_hidden = show_hidden, cancel = cancel}
	}
	fan_out(scan_range, jobs)
	if sync.atomic_load(cancel) { return 0, 0, false }
	for j in jobs {
		total += j.count
		hidden += j.hidden
	}
	return total, hidden, true
}

@(private="file")
bit_set_at :: #force_inline proc(bits: []u64, i: u32) -> bool {
	return bits[i >> 6] & (1 << (i & 63)) != 0
}

@(private="file")
run_query :: proc(s: ^Search_Service, req: ^Search_Request) {
	t0 := time.tick_now()
	heap := runtime.heap_allocator()
	q := parse_query(req.text)
	ix := s.index
	msg := Search_Msg{kind = .Results, tab = req.tab, gen = req.gen, preserve = req.preserve}
	if len(q.groups) == 0 || ix == nil {
		msg.no_index = ix == nil && len(q.groups) > 0
		post(s, msg)
		post(s, {kind = .Stats_Done, tab = req.tab, gen = req.gen})
		return
	}
	bits := make([]u64, (ix.count + 63) / 64, context.temp_allocator)
	total, hidden, ok := search_scan(ix, &q, bits, req.show_hidden, &s.cancel, s.threads)
	if !ok { return } // superseded: the newer query answers

	// The listed ones, in the requested order.
	by_stat := req.sort == .Size || req.sort == .Date
	limit := by_stat ? SEARCH_SORT_LIMIT : SEARCH_CAP
	picked := make([dynamic]u32, 0, min(limit, total), context.temp_allocator)
	if req.sort == .Path {
		for n in 0 ..< ix.count {
			i := req.desc ? u32(ix.count - 1 - n) : u32(n)
			if !bit_set_at(bits, i) { continue }
			append(&picked, i)
			if len(picked) >= limit { break }
		}
	} else {
		for n in 0 ..< ix.count {
			i := req.desc && req.sort == .Name ? ix.by_name[ix.count - 1 - n] : ix.by_name[n]
			if !bit_set_at(bits, i) { continue }
			append(&picked, i)
			if len(picked) >= limit { break }
		}
	}
	items := make([dynamic]Search_Item, 0, len(picked), heap)
	dirbuf: [PATH_BUF]u8
	last := NO_PARENT
	dir := ""
	for i in picked {
		if up := ix.parent[i]; up != last {
			last = up
			dir = index_path(ix, up, dirbuf[:])
		}
		append(&items, Search_Item{name = strings.clone(index_name(ix, i), heap), dir = strings.clone(dir, heap), flags = ix.flags[i]})
	}
	if by_stat {
		// Size and date need a stat of every candidate before sorting.
		kept := 0
		for &it, n in items {
			if n % 64 == 0 && stale_work(s) {
				// Superseded: free what is left (kept ones and the unvisited rest).
				for k in 0 ..< kept { delete(items[k].name, heap); delete(items[k].dir, heap) }
				for k in n ..< len(items) { delete(items[k].name, heap); delete(items[k].dir, heap) }
				delete(items)
				return
			}
			it.st = stat_item(it.dir, it.name)
			it.has_st = true
			if it.st.gone {
				delete(it.name, heap)
				delete(it.dir, heap)
				total -= 1
				continue
			}
			items[kept] = it
			kept += 1
		}
		resize(&items, kept)
		if req.sort == .Size {
			slice.stable_sort_by(items[:], proc(x, y: Search_Item) -> bool { return x.st.size < y.st.size })
		} else {
			slice.stable_sort_by(items[:], proc(x, y: Search_Item) -> bool { return x.st.mtime < y.st.mtime })
		}
		if req.desc { slice.reverse(items[:]) }
		for len(items) > SEARCH_CAP {
			it := pop(&items)
			delete(it.name, heap)
			delete(it.dir, heap)
		}
	}
	// The stat pass below needs the paths once the items are the UI's.
	paths := make([]string, by_stat ? 0 : len(items), context.temp_allocator)
	for &p, n in paths { p = join({items[n].dir, items[n].name}) }
	msg.items = items
	msg.total = total
	msg.hidden = hidden
	msg.ms = time.duration_milliseconds(time.tick_since(t0))
	post(s, msg)

	// Sizes and dates of the listed results, in batches.
	batch := Search_Msg{kind = .Stats, tab = req.tab, gen = req.gen}
	sent := time.tick_now()
	for p, n in paths {
		if stale_work(s) || sync.atomic_load(&s.queued) > 0 { break }
		if len(batch.stats) == 0 { batch.start = n }
		append(&batch.stats, stat_item(p, ""))
		if len(batch.stats) >= 512 || time.duration_milliseconds(time.tick_since(sent)) > 40 {
			post(s, batch)
			batch = {kind = .Stats, tab = req.tab, gen = req.gen}
			sent = time.tick_now()
		}
	}
	if len(batch.stats) > 0 { post(s, batch) } else { delete(batch.stats) }
	post(s, {kind = .Stats_Done, tab = req.tab, gen = req.gen})
}

// lstat (and stat through a link) of a result, like list_directory does.
stat_item :: proc(dir_or_path, name: string) -> Stat_Info {
	path := name == "" ? dir_or_path : join({dir_or_path, name})
	base := name == "" ? base_name(path) : name
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	info: Stat_Info
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		info.gone = posix.errno() == .ENOENT || posix.errno() == .ENOTDIR
		info.unreadable = true
		info.kind = kind_for_name(base, false)
		return info
	}
	if posix.S_ISLNK(st.st_mode) {
		info.is_link = true
		target: posix.stat_t
		if posix.stat(cpath, &target) != .OK {
			info.kind = .Broken
			info.unreadable = true
			return info
		}
		st = target
	}
	info.size = i64(st.st_size)
	info.mtime = i64(st.st_mtim.tv_sec)
	info.is_dir = posix.S_ISDIR(st.st_mode)
	exec := posix.S_ISREG(st.st_mode) && (st.st_mode & {.IXUSR, .IXGRP, .IXOTH}) != {}
	info.kind = info.is_dir ? .Folder : kind_for_name(base, exec)
	return info
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------
Term_Kind :: enum { Text, Glob, Ext, Is_File, Is_Dir }

Term :: struct {
	kind: Term_Kind,
	text: string,   // folded
	exts: []string, // folded, without the dot
	path: bool,     // match the whole path, not the name
}

Group :: struct {
	terms:  [dynamic]Term, // any of them (OR)
	negate: bool,
}

Query :: struct {
	groups: [dynamic]Group, // all of them (AND)
}

// Split on blanks; "quoted text" stays one token.
@(private="file")
tokenize :: proc(s: string) -> []string {
	out := make([dynamic]string)
	b := strings.builder_make()
	quoted := false
	for r in s {
		switch {
		case r == '"':
			quoted = !quoted
		case (r == ' ' || r == '\t') && !quoted:
			if strings.builder_len(b) > 0 {
				append(&out, strings.clone(strings.to_string(b)))
				strings.builder_reset(&b)
			}
		case:
			strings.write_rune(&b, r)
		}
	}
	if strings.builder_len(b) > 0 { append(&out, strings.clone(strings.to_string(b))) }
	return out[:]
}

@(private="file")
cut_prefix :: proc(s: ^string, prefixes: ..string) -> bool {
	for p in prefixes {
		if len(s^) >= len(p) && strings.equal_fold(s[:len(p)], p) {
			s^ = s[len(p):]
			return true
		}
	}
	return false
}

// Parse a query (context.allocator; the worker uses its temp allocator).
parse_query :: proc(text: string, allocator := context.temp_allocator) -> Query {
	context.allocator = allocator
	q: Query
	or_next := false
	for tok in tokenize(text) {
		if tok == "|" {
			or_next = true
			continue
		}
		s := tok
		negate := false
		for strings.has_prefix(s, "!") {
			negate = !negate
			s = s[1:]
		}
		path := false
		groups := make([dynamic]Group)
		modifiers: for s != "" {
			switch {
			case cut_prefix(&s, "path:"):
				path = true
			case cut_prefix(&s, "file:", "files:"):
				g: Group
				append(&g.terms, Term{kind = .Is_File})
				append(&groups, g)
			case cut_prefix(&s, "folder:", "folders:", "dir:"):
				g: Group
				append(&g.terms, Term{kind = .Is_Dir})
				append(&groups, g)
			case cut_prefix(&s, "ext:"):
				exts := make([dynamic]string)
				for part in strings.split_multi(s, {";", ",", "|"}) {
					e := strings.trim_left(strings.trim_space(part), ".")
					if e != "" { append(&exts, sort_key(e)) }
				}
				s = ""
				if len(exts) > 0 {
					g: Group
					append(&g.terms, Term{kind = .Ext, exts = exts[:]})
					append(&groups, g)
				}
			case:
				break modifiers
			}
		}
		if s != "" {
			g: Group
			for alt in strings.split(s, "|") {
				if alt == "" { continue }
				f := sort_key(alt)
				kind := strings.contains_any(f, "*?") ? Term_Kind.Glob : Term_Kind.Text
				append(&g.terms, Term{kind = kind, text = f, path = path || strings.index_byte(f, '/') >= 0})
			}
			if len(g.terms) > 0 { append(&groups, g) }
		}
		if len(groups) == 0 { continue }
		// "!" applies to the word, or to the filter when there is no word.
		if negate { groups[len(groups) - 1].negate = true }
		if or_next && len(q.groups) > 0 && len(groups) == 1 && !groups[0].negate && !q.groups[len(q.groups) - 1].negate {
			append(&q.groups[len(q.groups) - 1].terms, ..groups[0].terms[:])
		} else {
			append(&q.groups, ..groups[:])
		}
		or_next = false
	}
	// Cheap filters first, whole paths last.
	cost :: proc(g: Group) -> int {
		c := 0
		for t in g.terms {
			switch t.kind {
			case .Is_File, .Is_Dir: c = max(c, 0)
			case .Ext:              c = max(c, 1)
			case .Text, .Glob:      c = max(c, t.path ? 3 : 2)
			}
		}
		return c
	}
	slice.stable_sort_by(q.groups[:], proc(x, y: Group) -> bool { return cost(x) < cost(y) })
	return q
}

// Does `hay` contain `needle` (both folded)?
contains_fast :: proc(hay, needle: string) -> bool {
	n := len(needle)
	if n == 0 { return true }
	if n > len(hay) { return false }
	first := needle[0]
	last := len(hay) - n
	i := 0
	for i <= last {
		j := strings.index_byte(hay[i:last + 1], first)
		if j < 0 { return false }
		i += j
		if hay[i:i + n] == needle { return true }
		i += 1
	}
	return false
}

// `*` and `?` over the whole of `s` (both folded; `?` is one character).
glob_match :: proc(pat, s: string) -> bool {
	p, i := 0, 0
	star_p, star_i := -1, 0
	for i < len(s) {
		if p < len(pat) {
			switch pat[p] {
			case '*':
				star_p = p
				star_i = i
				p += 1
				continue
			case '?':
				_, w := utf8.decode_rune_in_string(s[i:])
				p += 1
				i += w
				continue
			case:
				if pat[p] == s[i] {
					p += 1
					i += 1
					continue
				}
			}
		}
		if star_p < 0 { return false }
		// Let the last star swallow one more character.
		p = star_p + 1
		star_i += 1
		for star_i < len(s) && s[star_i] & 0xC0 == 0x80 { star_i += 1 }
		i = star_i
	}
	for p < len(pat) && pat[p] == '*' { p += 1 }
	return p == len(pat)
}

@(private="file")
Scan_Job :: struct {
	ix:          ^Index,
	q:           ^Query,
	lo, hi:      int,
	bits:        []u64,
	show_hidden: bool,
	cancel:      ^bool,
	count:       int,
	hidden:      int,
}

// One entry being matched; the folded name and path are made on demand.
@(private="file")
Matcher :: struct {
	ix:       ^Index,
	i:        u32,
	flags:    Index_Flags,
	name:     string,
	folded:   string,
	has_fold: bool,
	path:     string,
	has_path: bool,
	parent:   u32, // the folder whose folded path is in pbuf
	plen:     int,
	fbuf:     [1024]u8,
	pbuf:     [PATH_BUF + 1100]u8,
	tmp:      [PATH_BUF]u8,
}

@(private="file")
folded_name :: #force_inline proc(m: ^Matcher) -> string {
	if !m.has_fold {
		m.folded = .Fold in m.flags ? fold_to(m.fbuf[:], m.name) : m.name
		m.has_fold = true
	}
	return m.folded
}

@(private="file")
folded_path :: proc(m: ^Matcher) -> string {
	if !m.has_path {
		up := m.ix.parent[m.i]
		if up != m.parent || m.plen < 0 {
			s := index_path_folded(m.ix, up, m.tmp[:])
			if s == "/" { s = "" }
			copy(m.pbuf[:], s)
			m.plen = len(s)
			m.parent = up
		}
		name := folded_name(m)
		m.pbuf[m.plen] = '/'
		n := copy(m.pbuf[m.plen + 1:], name)
		m.path = string(m.pbuf[:m.plen + 1 + n])
		m.has_path = true
	}
	return m.path
}

@(private="file")
term_match :: proc(m: ^Matcher, t: ^Term) -> bool {
	switch t.kind {
	case .Is_File:
		return .Dir not_in m.flags
	case .Is_Dir:
		return .Dir in m.flags
	case .Ext:
		if .Dir in m.flags { return false }
		dot := strings.last_index_byte(m.name, '.')
		if dot <= 0 || dot == len(m.name) - 1 { return false }
		ext := m.name[dot + 1:]
		buf: [64]u8
		if len(ext) > len(buf) { return false }
		if needs_fold(ext) { ext = fold_to(buf[:], ext) }
		for e in t.exts { if e == ext { return true } }
		return false
	case .Text:
		return contains_fast(t.path ? folded_path(m) : folded_name(m), t.text)
	case .Glob:
		return glob_match(t.text, t.path ? folded_path(m) : folded_name(m))
	}
	return false
}

@(private="file")
scan_range :: proc(job: ^Scan_Job) {
	ix := job.ix
	m: Matcher
	m.ix = ix
	m.parent = NO_PARENT
	m.plen = -1
	groups := job.q.groups[:]
	for i in job.lo ..< job.hi {
		if i & 0x3FFF == 0 && sync.atomic_load(job.cancel) { return }
		if ix.parent[i] == NO_PARENT { continue } // "/" and the other roots
		m.i = u32(i)
		m.flags = ix.flags[i]
		m.name = index_name(ix, u32(i))
		m.has_fold = false
		m.has_path = false
		ok := true
		for &g in groups {
			hit := false
			for &t in g.terms {
				if term_match(&m, &t) {
					hit = true
					break
				}
			}
			if hit == g.negate {
				ok = false
				break
			}
		}
		if !ok { continue }
		if .Hidden in m.flags && !job.show_hidden {
			job.hidden += 1
			continue
		}
		job.bits[i >> 6] |= 1 << uint(i & 63)
		job.count += 1
	}
}

// ---------------------------------------------------------------------------
// Search tabs (UI thread)
// ---------------------------------------------------------------------------

// Ctrl+Shift+F: the pane's search tab (made when there is none), with its
// field focused; `query` (the folder filter, say) is typed in.
search_open :: proc(a: ^App, query := "") {
	end_editing(a)
	p := cur_pane(a)
	t: ^Tab
	for tab, i in p.tabs {
		if is_search(tab) {
			set_active_tab(a, a.active_pane, i)
			t = tab
			break
		}
	}
	if t == nil {
		from := cur_tab(a)
		t = tab_create(.List, from.show_hidden)
		t.kind = .Search
		t.dir = strings.clone(clean_path(home_dir()))
		update_free(t)
		inject_at(&p.tabs, p.active + 1, t)
		set_active_tab(a, a.active_pane, p.active + 1)
	}
	if query != "" {
		field_set(&t.search, query)
		search_submit(a, t)
	}
	a.focus = .Search
	field_select_all(&t.search)
	sync.atomic_store(&a.search.wanted, true)
	sync.sema_post(&a.search.poke) // a stale index is refreshed now
	a.dirty = true
}

// Send the tab's query to the worker (replacing one still waiting).
search_submit :: proc(a: ^App, t: ^Tab, preserve := false) {
	s := &a.search
	s.next_gen += 1
	t.find.gen = s.next_gen
	t.find.busy = true
	heap := runtime.heap_allocator()
	req := Search_Request{tab = t.id, gen = t.find.gen, text = strings.clone(strings.trim_space(field_text(&t.search)), heap),
	                      sort = t.find.sort, desc = t.find.desc, show_hidden = t.show_hidden, preserve = preserve}
	sync.mutex_lock(&s.mutex)
	replaced := false
	for &r in s.requests {
		if r.tab == t.id {
			delete(r.text, heap)
			r = req
			replaced = true
			break
		}
	}
	if !replaced { append(&s.requests, req) }
	if s.running_tab == t.id { sync.atomic_store(&s.cancel, true) }
	sync.atomic_store(&s.queued, len(s.requests))
	sync.mutex_unlock(&s.mutex)
	sync.sema_post(&s.work)
	a.dirty = true
}

// Run the query again, keeping the selection and the scroll.
search_refresh :: proc(a: ^App, t: ^Tab) {
	search_submit(a, t, true)
}

// A click on a column title: sort by it (again: the other way round).
search_sort_by :: proc(a: ^App, t: ^Tab, sort: Search_Sort) {
	if t.find.sort == sort {
		t.find.desc = !t.find.desc
	} else {
		t.find.sort = sort
		t.find.desc = sort == .Size || sort == .Date // largest and newest first
	}
	t.scroll, t.scroll_to = 0, 0
	if field_text(&t.search) != "" { search_submit(a, t, true) }
	a.dirty = true
}

// "Abrir pasta que contém": the folder of the first selected result in a new
// tab, with the item selected.
search_reveal :: proc(a: ^App) {
	t := cur_tab(a)
	sel := selected_entries(t)
	idx := -1
	if len(sel) > 0 {
		idx = sel[0]
	} else if t.cursor >= 0 && t.cursor < len(t.view) {
		idx = t.view[t.cursor]
	}
	if idx < 0 { return }
	e := &t.entries[idx]
	dir := strings.clone(entry_dir(t, e), context.temp_allocator)
	name := strings.clone(e.name, context.temp_allocator)
	if new_tab(a, a.active_pane, dir) { select_by_name(a, cur_tab(a), name) }
}

// Keep the index fresh while a search tab is open (checked once a second).
search_keepalive :: proc(a: ^App) {
	open := false
	for p in a.panes {
		for t in p.tabs { if is_search(t) { open = true } }
	}
	sync.atomic_store(&a.search.wanted, open)
}

@(private="file")
search_tab_by_id :: proc(a: ^App, id: int) -> ^Tab {
	for p in a.panes {
		for t in p.tabs { if t.id == id && is_search(t) { return t } }
	}
	return nil
}

@(private="file")
apply_stat :: proc(e: ^Entry, st: Stat_Info) {
	e.pending = false
	if st.gone {
		e.gone = true
		return
	}
	e.size, e.mtime = st.size, st.mtime
	e.is_link = st.is_link
	e.unreadable = st.unreadable
	e.kind = st.kind
	if st.kind != .Broken { e.is_dir = st.is_dir }
}

// Collect what the worker finished; true when something changed on screen.
search_tick :: proc(a: ^App) -> bool {
	s := &a.search
	if s.wake_r >= 0 {
		buf: [64]u8
		for posix.read(s.wake_r, &buf[0], len(buf)) > 0 {}
	}
	changed := false
	if busy, n := search_indexing(a); busy && n != s.shown_progress {
		s.shown_progress = n
		changed = true
	}
	sync.mutex_lock(&s.mutex)
	msgs := s.msgs
	s.msgs = {}
	sync.mutex_unlock(&s.mutex)
	for &m in msgs {
		changed = true
		switch m.kind {
		case .Index_Changed:
			for p in a.panes {
				for t in p.tabs {
					if is_search(t) && (field_text(&t.search) != "" || t.find.no_index) { search_refresh(a, t) }
				}
			}
		case .Results:
			apply_results(a, &m)
		case .Stats:
			t := search_tab_by_id(a, m.tab)
			if t == nil || t.find.shown != m.gen { break }
			gone := false
			for st, k in m.stats {
				i := m.start + k
				if i >= len(t.entries) { break }
				apply_stat(&t.entries[i], st)
				if st.gone { gone = true }
			}
			if gone { rebuild_view(a, t) }
		case .Stats_Done:
			if t := search_tab_by_id(a, m.tab); t != nil && t.find.gen == m.gen { t.find.busy = false }
		}
		msg_free(&m)
	}
	delete(msgs)
	return changed
}

@(private="file")
apply_results :: proc(a: ^App, m: ^Search_Msg) {
	t := search_tab_by_id(a, m.tab)
	if t == nil || t.find.gen != m.gen { return } // an older query or a closed tab
	// A refresh keeps the selection and the cursor (by path).
	keep := make(map[string]bool, 16, context.temp_allocator)
	cursor_path := ""
	if m.preserve {
		for &e in t.entries { if e.selected { keep[entry_path(t, &e)] = true } }
		if t.cursor >= 0 && t.cursor < len(t.view) { cursor_path = entry_path(t, &t.entries[t.view[t.cursor]]) }
	} else {
		t.cursor, t.anchor = -1, -1
		t.scroll, t.scroll_to = 0, 0
	}
	if a.focus == .Rename && t == cur_tab(a) { rename_cancel(a) }
	entries_clear(&t.entries)
	reserve(&t.entries, len(m.items))
	for &it in m.items {
		e := Entry{name = it.name, dir = it.dir, pending = true}
		e.is_dir = .Dir in it.flags
		e.is_link = .Link in it.flags
		e.hidden = .Hidden in it.flags
		e.kind = e.is_dir ? .Folder : kind_for_name(e.name, false)
		if it.has_st { apply_stat(&e, it.st) }
		append(&t.entries, e)
		it.name, it.dir = "", "" // the entry owns them now
	}
	t.find.shown = m.gen
	t.find.total = m.total
	t.find.hidden = m.hidden
	t.find.ms = m.ms
	t.find.no_index = m.no_index
	if m.preserve && (len(keep) > 0 || cursor_path != "") {
		cursor_entry := -1
		for &e, i in t.entries {
			path := entry_path(t, &e)
			if path in keep { e.selected = true }
			if path == cursor_path { cursor_entry = i }
		}
		t.cursor = -1
		rebuild_view(a, t)
		if cursor_entry >= 0 {
			for idx, vi in t.view { if idx == cursor_entry { t.cursor = vi } }
		}
	} else {
		rebuild_view(a, t)
	}
	thumbs_forget(a)
	a.dirty = true
}

// ---------------------------------------------------------------------------
// Texts
// ---------------------------------------------------------------------------

// 1234567 → "1.234.567" (pt) / "1,234,567".
format_count :: proc(a: ^App, n: int) -> string {
	digits := fmt.tprintf("%d", abs(n))
	b := strings.builder_make(context.temp_allocator)
	if n < 0 { strings.write_byte(&b, '-') }
	sep := a.pt ? u8('.') : u8(',')
	for i in 0 ..< len(digits) {
		if i > 0 && (len(digits) - i) % 3 == 0 { strings.write_byte(&b, sep) }
		strings.write_byte(&b, digits[i])
	}
	return strings.to_string(b)
}

// "agora", "há 3 min", "há 2 h", "há 4 dias".
format_age :: proc(a: ^App, t: i64) -> string {
	d := i64(posix.time(nil)) - t
	switch {
	case d < 60:        return tr(a, "agora", "just now")
	case d < 3600:      return fmt.tprintf(tr(a, "há %d min", "%d min ago"), d / 60)
	case d < 2 * 86400: return fmt.tprintf(tr(a, "há %d h", "%d h ago"), d / 3600)
	}
	return fmt.tprintf(tr(a, "há %d dias", "%d days ago"), d / 86400)
}

// A folder for the Pasta column: $HOME as "~".
display_dir :: proc(dir: string) -> string {
	home := clean_path(home_dir())
	if dir == home { return "~" }
	if strings.has_prefix(dir, home) && len(dir) > len(home) && dir[len(home)] == '/' {
		return strings.concatenate({"~", dir[len(home):]}, context.temp_allocator)
	}
	return dir
}

// The end of `s` that fits in `max_w` pixels, after "…" (paths keep their tail).
ellipsize_left :: proc(a: ^App, f: ^tx.Font, s: string, max_w: i32) -> string {
	if max_w <= 0 { return "" }
	if tw(a, f, s) <= max_w { return s }
	starts := make([dynamic]int, context.temp_allocator)
	for _, i in s { append(&starts, i) }
	lo, hi := 0, len(starts) - 1 // the first start that fits
	for lo < hi {
		mid := (lo + hi) / 2
		if tw(a, f, strings.concatenate({"…", s[starts[mid]:]}, context.temp_allocator)) <= max_w { hi = mid } else { lo = mid + 1 }
	}
	return strings.concatenate({"…", s[starts[lo]:]}, context.temp_allocator)
}

// Status line of a search tab: the left text, the right text, and whether the
// indexer is running (a spinner next to the right text).
search_status :: proc(a: ^App, t: ^Tab) -> (left, right: string, spinning: bool) {
	info := search_index_info(a)
	indexing, progress := search_indexing(a)
	if indexing {
		right = fmt.tprintf(tr(a, "Indexando… %s", "Indexing… %s"), format_count(a, progress))
		spinning = true
	} else if info.ready {
		right = fmt.tprintf(tr(a, "Índice %s", "Index %s"), format_age(a, info.scanned))
	}
	query := strings.trim_space(field_text(&t.search))
	gone := 0
	for &e in t.entries { if e.gone { gone += 1 } }
	switch {
	case !info.ready:
		left = indexing ? tr(a, "Indexando o disco pela primeira vez…", "Indexing the disk for the first time…") : tr(a, "Sem índice", "No index")
	case query == "":
		left = fmt.tprintf(tr(a, "%s itens no índice", "%s items indexed"), format_count(a, info.count))
	case t.find.shown != t.find.gen:
		left = tr(a, "Buscando…", "Searching…")
	case:
		count, bytes, files := selection_stats(t)
		total := t.find.total - gone
		if count > 0 {
			left = fmt.tprintf(tr(a, "%d de %s selecionados", "%d of %s selected"), count, format_count(a, total))
			if files > 0 { left = fmt.tprintf("%s · %s", left, format_size(a, bytes)) }
		} else {
			ms := max(i64(t.find.ms + 0.5), 1)
			left = total == 1 ? fmt.tprintf(tr(a, "1 resultado em %d ms", "1 result in %d ms"), ms) : fmt.tprintf(tr(a, "%s resultados em %d ms", "%s results in %d ms"), format_count(a, total), ms)
			if len(t.view) < total { left = fmt.tprintf(tr(a, "%s · mostrando %s", "%s · showing %s"), left, format_count(a, len(t.view))) }
		}
		if t.find.hidden > 0 && !t.show_hidden {
			left = fmt.tprintf(tr(a, "%s · %s ocultos", "%s · %s hidden"), left, format_count(a, t.find.hidden))
		}
	}
	return
}

// The empty file view of a search tab.
search_empty_state :: proc(a: ^App, t: ^Tab) -> (ic: Ic, title, sub: string) {
	info := search_index_info(a)
	indexing, progress := search_indexing(a)
	query := strings.trim_space(field_text(&t.search))
	switch {
	case !info.ready && indexing:
		return .Hourglass, tr(a, "Indexando o disco…", "Indexing the disk…"),
		       fmt.tprintf(tr(a, "%s itens até agora", "%s items so far"), format_count(a, progress))
	case query == "":
		return .Search, tr(a, "Buscar em todo o disco", "Search the whole disk"),
		       tr(a, "Palavras com * e ?, ext:png;jpg, file:, folder:, path:, a|b (ou), !palavra (sem)",
		          "Words with * and ?, ext:png;jpg, file:, folder:, path:, a|b (or), !word (not)")
	case t.find.shown != t.find.gen:
		return .Hourglass, tr(a, "Buscando…", "Searching…"), ""
	}
	sub = fmt.tprintf(tr(a, "Nenhum item corresponde a “%s”.", "No item matches “%s”."), query)
	if t.find.hidden > 0 && !t.show_hidden {
		sub = fmt.tprintf(tr(a, "%d itens ocultos correspondem (Ctrl+H para mostrar)", "%d hidden items match (Ctrl+H to show)"), t.find.hidden)
	}
	return .Search, tr(a, "Nada encontrado", "Nothing found"), sub
}

// ---------------------------------------------------------------------------
// Command line: spoil --reindex / spoil --search QUERY
// ---------------------------------------------------------------------------
@(private="file")
rss_kb :: proc() -> (rss, peak: int) {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil { return }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 { continue }
		n := 0
		for c in fields[1] { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
		if fields[0] == "VmRSS:" { rss = n }
		if fields[0] == "VmHWM:" { peak = n }
	}
	return
}

@(private="file")
cli_index :: proc(force: bool) -> ^Index {
	path := index_cache_path()
	if !force {
		if ix := index_load(path); ix != nil { return ix }
	}
	progress := 0
	quit := false
	ix := index_build(&progress, &quit)
	if ix == nil { return nil }
	bytes := 13 * ix.count + 4 + len(ix.names)
	_, peak := rss_kb()
	fmt.eprintfln("spoil: indexed %d entries (%d folders) in %.2f s; index %.1f MB, peak RSS %.1f MB",
	              ix.count, ix.dirs, ix.walk_ms / 1000, f64(bytes) / 1e6, f64(peak) / 1024)
	if !index_save(ix, path) { fmt.eprintfln("spoil: cannot write %s", path) }
	return ix
}

// spoil --reindex: walk the disk and save the index.
cli_reindex :: proc() -> bool {
	ix := cli_index(true)
	defer index_destroy(ix)
	return ix != nil
}

// spoil --search QUERY: the matching paths in name order (hidden ones too).
cli_search :: proc(query: string) -> bool {
	ix := cli_index(false)
	if ix == nil { return false }
	defer index_destroy(ix)
	q := parse_query(query)
	if len(q.groups) == 0 { return true }
	bits := make([]u64, (ix.count + 63) / 64)
	defer delete(bits)
	cancel := false
	t0 := time.tick_now()
	total, _, _ := search_scan(ix, &q, bits, true, &cancel, clamp(os.get_processor_core_count(), 1, 8))
	scan_ms := time.duration_milliseconds(time.tick_since(t0))
	buf: [PATH_BUF]u8
	for i in ix.by_name {
		if bit_set_at(bits, i) { fmt.println(index_path(ix, i, buf[:])) }
	}
	fmt.eprintfln("spoil: %d results in %.2f ms (%d entries)", total, scan_ms, ix.count)
	return true
}
