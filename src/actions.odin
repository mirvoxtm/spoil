// What the user asks for: opening, renaming, new folders, the internal
// copy/cut/paste clipboard, the trash (gio trash), copying paths, a terminal
// here. File operations run as background jobs (cp, mv, gio, bsdtar, 7z)
// that never block the loop; their stderr explains failures.
package spoil

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import desktop "milk:desktop"

Job_Kind :: enum { Copy, Move, Trash, Compress, Extract }

Job :: struct {
	kind:   Job_Kind,
	p:      os.Process,
	count:  int,         // items handled by this process
	err_r:  posix.FD,    // its stderr (non-blocking), -1 when not captured
	err:    [dynamic]u8, // the first few hundred bytes of it
	select: string,      // select this name in the tab showing `dir` when done (owned)
	dir:    string,      // owned
}

run_command :: proc(a: ^App, cmd: Command, on_item: bool, area: int) {
	t := cur_tab(a)
	switch cmd {
	case .None:
	case .Open:       open_selection(a)
	case .Rename:     rename_start(a)
	case .Copy:       copy_selection(a, false)
	case .Cut:        copy_selection(a, true)
	case .Paste:      paste(a)
	case .Trash:      trash_selection(a)
	case .New_Folder: new_folder(a)
	case .Select_All: select_all(a, t)
	case .Hidden:     toggle_hidden(a, t)
	case .Compress:   card_open_compress(a)
	case .Extract_Here, .Extract_Folder:
		for path in selected_paths(t) {
			if is_archive(path) { extract(a, path, is_search(t) ? parent_dir(path) : t.dir, cmd == .Extract_Folder) }
		}
	case .New_Tab:
		dir := t.dir
		if on_item { if d, ok := single_selected_dir(t); ok { dir = d } }
		new_tab(a, a.active_pane, dir)
	case .New_Pane:
		dir := t.dir
		if on_item { if d, ok := single_selected_dir(t); ok { dir = d } }
		split_pane(a, a.active_pane, dir)
	case .Copy_Path:
		paths := on_item ? selected_paths(t) : []string{t.dir}
		if len(paths) == 0 { paths = []string{t.dir} }
		text := strings.join(paths, "\n", context.temp_allocator)
		clip_own(a, text, "", "")
		set_notice(a, len(paths) == 1 ? tr(a, "Caminho copiado", "Path copied") : fmt.tprintf(tr(a, "%d caminhos copiados", "%d paths copied"), len(paths)))
	case .Terminal:
		dir := t.dir
		if on_item { if d, ok := single_selected_dir(t); ok { dir = d } }
		open_terminal(a, dir)
	case .Wallpaper:
		sel := selected_entries(t)
		if len(sel) == 1 { set_wallpaper(a, entry_path(t, &t.entries[sel[0]]), area) }
	case .Close_Tab:
		close_tab(a, a.menu.tab_pane, a.menu.tab_index)
	case .Close_Other_Tabs:
		p := a.panes[a.menu.tab_pane]
		keep := p.tabs[a.menu.tab_index]
		for i := len(p.tabs) - 1; i >= 0; i -= 1 {
			if p.tabs[i] != keep { close_tab(a, a.menu.tab_pane, i) }
		}
	case .Tab_To_Pane:
		move_tab(a, a.menu.tab_pane, a.menu.tab_index, -1, -1, a.menu.tab_pane + 1)
	case .Open_Folder: search_reveal(a)
	case .Search:      search_open(a)
	case .Reindex:     search_reindex(a)
	}
	a.dirty = true
}

@(private)
single_selected_dir :: proc(t: ^Tab) -> (string, bool) {
	sel := selected_entries(t)
	if len(sel) == 1 && t.entries[sel[0]].is_dir { return entry_path(t, &t.entries[sel[0]]), true }
	return "", false
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------
open_selection :: proc(a: ^App) {
	t := cur_tab(a)
	sel := selected_entries(t)
	if len(sel) == 0 && t.cursor >= 0 && t.cursor < len(t.view) { sel = []int{t.view[t.cursor]} }
	if len(sel) == 0 { return }
	if len(sel) == 1 {
		e := &t.entries[sel[0]]
		if e.kind == .Broken {
			set_notice(a, fmt.tprintf(tr(a, "“%s” aponta para um item que não existe mais", "“%s” points to an item that no longer exists"), e.name), true)
			return
		}
		if e.is_dir {
			// Search results keep their tab: the folder opens in a new one.
			if is_search(t) { new_tab(a, a.active_pane, entry_path(t, e)) } else { navigate(a, t, entry_path(t, e)) }
			return
		}
	}
	// One picture, video or song: shown inside the pane when mpv is installed.
	if len(sel) == 1 {
		e := &t.entries[sel[0]]
		if viewable(e) && viewer_open(a, a.active_pane, entry_path(t, e)) { return }
	}
	opened := 0
	for idx in sel {
		e := &t.entries[idx]
		if e.is_dir || e.kind == .Broken { continue }
		if opened >= 12 { break } // a runaway multi-selection should not start 500 viewers
		if launch(a, {"xdg-open", entry_path(t, e)}, entry_dir(t, e)) { opened += 1 }
	}
}

// Start a program detached from Spoil (its own session); reaped in tick.
launch :: proc(a: ^App, argv: []string, workdir: string) -> bool {
	pid, ok := desktop.spawn_detached(argv, workdir)
	if !ok {
		set_notice(a, fmt.tprintf(tr(a, "Não foi possível executar %s", "Cannot run %s"), argv[0]), true)
		return false
	}
	append(&a.children, pid)
	return true
}

reap_children :: proc(a: ^App) {
	for i := len(a.children) - 1; i >= 0; i -= 1 {
		if posix.waitpid(a.children[i], nil, {.NOHANG}) != 0 { unordered_remove(&a.children, i) }
	}
}

// "Abrir terminal aqui": embedded on the right when the terminal is Alacritty,
// else in its own window.
open_terminal :: proc(a: ^App, dir: string) {
	if term_open(a, dir) { return }
	term := terminal_command(a)
	launch(a, {"sh", "-c", term}, dir)
}

// ---------------------------------------------------------------------------
// Rename and new folder
// ---------------------------------------------------------------------------
rename_start :: proc(a: ^App) {
	t := cur_tab(a)
	sel := selected_entries(t)
	idx := -1
	if len(sel) == 1 {
		idx = sel[0]
	} else if len(sel) == 0 && t.cursor >= 0 && t.cursor < len(t.view) {
		idx = t.view[t.cursor]
	}
	if idx < 0 { return }
	e := &t.entries[idx]
	delete(a.rename_name)
	a.rename_name = strings.clone(e.name)
	a.rename_index = idx
	field_set(&a.rename, e.name)
	// Select the name without its extension, like other file managers.
	stop := len(e.name)
	if !e.is_dir {
		dot := strings.last_index_byte(e.name, '.')
		if dot > 0 { stop = dot }
		if strings.has_suffix(strings.to_lower(e.name[:stop], context.temp_allocator), ".tar") { stop -= 4 }
	}
	field_select(&a.rename, 0, stop)
	a.focus = .Rename
	for vi in 0 ..< len(t.view) {
		if t.view[vi] == idx {
			select_only(a, t, vi)
			reveal(a, t, vi)
			break
		}
	}
	a.dirty = true
}

rename_cancel :: proc(a: ^App) {
	if a.focus != .Rename { return }
	a.focus = .View
	delete(a.rename_name)
	a.rename_name = ""
	a.dirty = true
}

// Apply the typed name. On a problem the field stays open with a notice
// (returns false); `rename_finish` gives up instead.
rename_commit :: proc(a: ^App) -> bool {
	if a.focus != .Rename { return true }
	t := cur_tab(a)
	old := a.rename_name
	name := strings.trim_space(field_text(&a.rename))
	if name == "" || name == old {
		rename_cancel(a)
		return true
	}
	if strings.index_byte(name, '/') >= 0 || name == "." || name == ".." {
		set_notice(a, tr(a, "O nome não pode conter “/”", "The name cannot contain “/”"), true)
		return false
	}
	dir := t.dir
	idx := a.rename_index
	if is_search(t) {
		if idx < 0 || idx >= len(t.entries) || t.entries[idx].name != old {
			rename_cancel(a)
			return true
		}
		dir = entry_dir(t, &t.entries[idx])
	}
	from := join({dir, old})
	to := join({dir, name})
	if path_exists(to) && strings.to_lower(name, context.temp_allocator) != strings.to_lower(old, context.temp_allocator) {
		set_notice(a, fmt.tprintf(tr(a, "Já existe um item chamado “%s”", "An item called “%s” already exists"), name), true)
		return false
	}
	if err := os.rename(from, to); err != nil {
		set_notice(a, fmt.tprintf(tr(a, "Não foi possível renomear: %s", "Cannot rename: %s"), os.error_string(err)), true)
		rename_cancel(a)
		return false
	}
	new_name := strings.clone(name, context.temp_allocator)
	rename_cancel(a)
	if is_search(t) {
		// The index does not know the new name yet: rename the result in place.
		e := &t.entries[idx]
		delete(e.name)
		e.name = strings.clone(new_name)
		if !e.is_dir { e.kind = kind_for_name(e.name, e.kind == .Executable) }
		a.dirty = true
		return true
	}
	refresh(a, t)
	select_by_name(a, t, new_name)
	return true
}

rename_finish :: proc(a: ^App) {
	if !rename_commit(a) { rename_cancel(a) }
}

new_folder :: proc(a: ^App) {
	if a.focus == .Rename { rename_finish(a) }
	t := cur_tab(a)
	if is_search(t) { return }
	name := unique_name(t.dir, tr(a, "Nova pasta", "New folder"), true)
	if err := os.make_directory(join({t.dir, name})); err != nil {
		set_notice(a, fmt.tprintf(tr(a, "Não foi possível criar a pasta: %s", "Cannot create the folder: %s"), os.error_string(err)), true)
		return
	}
	field_clear(&t.search)
	refresh(a, t)
	select_by_name(a, t, name)
	rename_start(a)
	field_select_all(&a.rename)
}

// ---------------------------------------------------------------------------
// Clipboard (files)
// ---------------------------------------------------------------------------
copy_selection :: proc(a: ^App, cut: bool) {
	paths := selected_paths(cur_tab(a))
	if len(paths) == 0 { return }
	clip_set_files(a, paths, cut)
	n := len(paths)
	switch {
	case cut && n == 1:  set_notice(a, tr(a, "1 item recortado", "1 item cut"))
	case cut:            set_notice(a, fmt.tprintf(tr(a, "%d itens recortados", "%d items cut"), n))
	case n == 1:         set_notice(a, tr(a, "1 item copiado", "1 item copied"))
	case:                set_notice(a, fmt.tprintf(tr(a, "%d itens copiados", "%d items copied"), n))
	}
}

paste :: proc(a: ^App) {
	if len(a.clip.paths) == 0 { return }
	if is_search(cur_tab(a)) {
		set_notice(a, tr(a, "Abra uma pasta para colar", "Open a folder to paste"), true)
		return
	}
	cut := a.clip.cut
	paths := make([]string, len(a.clip.paths), context.temp_allocator)
	for p, i in a.clip.paths { paths[i] = strings.clone(p, context.temp_allocator) }
	started := transfer(a, paths, cur_tab(a).dir, cut ? .Move : .Copy)
	if cut && started > 0 { clip_clear_files(a) } // the originals are gone once moved
}

trash_selection :: proc(a: ^App) {
	t := cur_tab(a)
	paths := selected_paths(t)
	if len(paths) == 0 { return }
	if !g_tools.gio {
		set_notice(a, tr(a, "“gio” não está instalado: não é possível usar a lixeira", "“gio” is not installed: the trash is unavailable"), true)
		return
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "gio", "trash", "--")
	append(&argv, ..paths)
	if start_job(a, .Trash, argv[:], len(paths)) { clear_selection(a, t) }
}

// ---------------------------------------------------------------------------
// Background jobs
// ---------------------------------------------------------------------------
start_job :: proc(a: ^App, kind: Job_Kind, argv: []string, count := 1, workdir := "", select := "") -> bool {
	dir := workdir != "" ? workdir : cur_tab(a).dir
	// stderr is kept (drained while the job runs) to explain failures.
	err_r, err_w, perr := os.pipe()
	p, err := os.process_start(os.Process_Desc{command = argv, working_dir = dir, stderr = perr == nil ? err_w : nil})
	if perr == nil { os.close(err_w) }
	if err != nil {
		if perr == nil { os.close(err_r) }
		set_notice(a, fmt.tprintf(tr(a, "Não foi possível executar %s: %s", "Cannot run %s: %s"), argv[0], os.error_string(err)), true)
		return false
	}
	job := Job{kind = kind, p = p, count = count, err_r = -1, select = strings.clone(select), dir = strings.clone(dir)}
	if perr == nil {
		// Keep only the descriptor: the os.File wrapper is not needed.
		job.err_r = posix.dup(posix.FD(os.fd(err_r)))
		os.close(err_r)
		if job.err_r >= 0 {
			flags := posix.fcntl(job.err_r, .GETFL)
			posix.fcntl(job.err_r, .SETFL, flags | posix.O_NONBLOCK)
			posix.fcntl(job.err_r, .SETFD, posix.FD_CLOEXEC)
		}
	}
	log.debugf("Job: %s", strings.join(argv, " ", context.temp_allocator))
	append(&a.jobs, job)
	a.dirty = true
	return true
}

@(private)
drain_job :: proc(j: ^Job) {
	if j.err_r < 0 { return }
	buf: [1024]u8
	for {
		n := posix.read(j.err_r, &buf[0], len(buf))
		if n <= 0 { break }
		room := 600 - len(j.err)
		if room > 0 { append(&j.err, ..buf[:min(int(n), room)]) }
	}
}

@(private)
job_close :: proc(j: ^Job) {
	if j.err_r >= 0 { posix.close(j.err_r) }
	j.err_r = -1
	delete(j.err)
	j.err = nil
	delete(j.select)
	delete(j.dir)
}

// The useful part of a tool's error ("gio: file:///x: Reason" → "Reason").
@(private)
job_reason :: proc(j: ^Job) -> string {
	text := strings.trim_space(string(j.err[:]))
	// The last meaningful line (7z prints its banner first).
	lines := strings.split_lines(text, context.temp_allocator)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		l := strings.trim_space(lines[i])
		if l != "" {
			text = l
			break
		}
	}
	if colon := strings.last_index(text, ": "); colon >= 0 && colon + 2 < len(text) { text = text[colon + 2:] }
	return strings.clone(strings.trim_space(text), context.temp_allocator)
}

jobs_tick :: proc(a: ^App) {
	if len(a.jobs) == 0 { return }
	finished := false
	failed: [Job_Kind]int
	reason: [Job_Kind]string
	selects := make([dynamic][2]string, context.temp_allocator)
	for i := len(a.jobs) - 1; i >= 0; i -= 1 {
		j := &a.jobs[i]
		drain_job(j)
		state, err := os.process_wait(j.p, 0)
		if err == os.General_Error.Timeout { continue }
		drain_job(j)
		if err != nil || !state.success {
			failed[j.kind] += j.count
			if r := job_reason(j); r != "" { reason[j.kind] = r }
			log.warnf("Job failed: %s", strings.trim_space(string(j.err[:])))
		} else if j.select != "" {
			append(&selects, [2]string{strings.clone(j.dir, context.temp_allocator), strings.clone(j.select, context.temp_allocator)})
		}
		job_close(j)
		ordered_remove(&a.jobs, i)
		finished = true
	}
	if !finished { return }
	refresh_visible(a)
	for s in selects {
		for p in a.panes {
			t := p.tabs[p.active]
			if t.dir == s[0] && !is_search(t) { select_by_name(a, t, s[1]) }
		}
	}
	explain :: proc(msg, why: string) -> string { return why == "" ? msg : fmt.tprintf("%s: %s", msg, why) }
	if failed[.Copy] > 0 { set_notice(a, explain(fmt.tprintf(tr(a, "Falha ao copiar %d item(ns)", "Could not copy %d item(s)"), failed[.Copy]), reason[.Copy]), true) }
	if failed[.Move] > 0 { set_notice(a, explain(fmt.tprintf(tr(a, "Falha ao mover %d item(ns)", "Could not move %d item(s)"), failed[.Move]), reason[.Move]), true) }
	if failed[.Trash] > 0 { set_notice(a, explain(tr(a, "Não foi possível mover para a lixeira", "Could not move to the trash"), reason[.Trash]), true) }
	if failed[.Compress] > 0 { set_notice(a, explain(tr(a, "Não foi possível comprimir", "Could not compress"), reason[.Compress]), true) }
	if failed[.Extract] > 0 { set_notice(a, explain(tr(a, "Não foi possível extrair", "Could not extract"), reason[.Extract]), true) }
	a.dirty = true
}

jobs_label :: proc(a: ^App) -> string {
	counts: [Job_Kind]int
	for j in a.jobs { counts[j.kind] += j.count }
	switch {
	case counts[.Copy] > 0:     return fmt.tprintf(tr(a, "Copiando %d…", "Copying %d…"), counts[.Copy])
	case counts[.Move] > 0:     return fmt.tprintf(tr(a, "Movendo %d…", "Moving %d…"), counts[.Move])
	case counts[.Trash] > 0:    return tr(a, "Movendo para a lixeira…", "Moving to the trash…")
	case counts[.Compress] > 0: return tr(a, "Comprimindo…", "Compressing…")
	case counts[.Extract] > 0:  return tr(a, "Extraindo…", "Extracting…")
	}
	return ""
}

jobs_destroy :: proc(a: ^App) {
	// Copies keep running after Spoil closes (they are plain cp/mv processes);
	// only our handles are released.
	for &j in a.jobs { job_close(&j) }
	delete(a.jobs)
}
