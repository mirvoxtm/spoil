// File system side of Spoil: well-known folders (XDG user dirs, trash, the
// milk runtime), directory listing with lstat/stat (broken links and
// unreadable entries are kept and flagged, never fatal), file kinds by
// extension, natural sorting, filtering and human-readable sizes and dates.
package spoil

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:unicode"
import "core:unicode/utf8"

File_Kind :: enum {
	Folder,
	Text,
	Image,
	Audio,
	Video,
	Archive,
	Pdf,
	Code,
	Document,
	Spreadsheet,
	Presentation,
	Executable,
	Generic,
	Broken, // a symlink whose target is missing
}

Entry :: struct {
	name:       string, // owned
	key:        string, // folded name for sorting and filtering (owned)
	size:       i64,
	mtime:      i64,    // unix seconds
	kind:       File_Kind,
	is_dir:     bool,   // a directory or a link to one
	is_link:    bool,
	unreadable: bool,   // no permission to read (or to enter, for folders)
	hidden:     bool,
	selected:   bool,
}

entry_destroy :: proc(e: ^Entry) {
	delete(e.name)
	delete(e.key)
	e^ = {}
}

entries_clear :: proc(list: ^[dynamic]Entry) {
	for &e in list { entry_destroy(&e) }
	clear(list)
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
join :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

home_dir :: proc() -> string {
	if v, found := os.lookup_env("HOME", context.temp_allocator); found && v != "" { return v }
	return "/"
}

config_home :: proc() -> string {
	if v, found := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator); found && v != "" { return v }
	return join({home_dir(), ".config"})
}

data_home :: proc() -> string {
	if v, found := os.lookup_env("XDG_DATA_HOME", context.temp_allocator); found && v != "" { return v }
	return join({home_dir(), ".local", "share"})
}

cache_home :: proc() -> string {
	if v, found := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator); found && v != "" { return v }
	return join({home_dir(), ".cache"})
}

// XDG_<KEY>_DIR from user-dirs.dirs ("" when it is not configured or is $HOME).
xdg_user_dir :: proc(key: string) -> string {
	data, err := os.read_entire_file(join({config_home(), "user-dirs.dirs"}), context.temp_allocator)
	if err != nil { return "" }
	wanted := fmt.tprintf("XDG_%s_DIR=", key)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, wanted) { continue }
		value := strings.trim(strings.trim_space(trimmed[len(wanted):]), "\"")
		value, _ = strings.replace_all(value, "$HOME", home_dir(), context.temp_allocator)
		if strings.has_prefix(value, "~/") { value = join({home_dir(), value[2:]}) }
		if value != "" && clean_path(value) != clean_path(home_dir()) { return value }
	}
	return ""
}

clean_path :: proc(p: string, allocator := context.temp_allocator) -> string {
	if p == "" { return strings.clone("/", allocator) }
	s, _ := filepath.clean(p, allocator)
	return s
}

// Absolute, clean version of a path typed or passed by the user ("~" expanded).
absolute_path :: proc(p: string, base: string, allocator := context.temp_allocator) -> string {
	s := strings.trim_space(p)
	if s == "~" { s = home_dir() }
	if strings.has_prefix(s, "~/") { s = join({home_dir(), s[2:]}) }
	if strings.has_prefix(s, "file://") { s = uri_decode(s[len("file://"):]) }
	if !strings.has_prefix(s, "/") { s = join({base, s}) }
	return clean_path(s, allocator)
}

// Percent-decoding for file:// URIs.
uri_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 { return s }
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	hex :: proc(ch: u8) -> (int, bool) {
		switch ch {
		case '0' ..= '9': return int(ch - '0'), true
		case 'a' ..= 'f': return int(ch - 'a') + 10, true
		case 'A' ..= 'F': return int(ch - 'A') + 10, true
		}
		return 0, false
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			h, ok1 := hex(s[i + 1])
			l, ok2 := hex(s[i + 2])
			if ok1 && ok2 {
				append(&out, u8(h * 16 + l))
				i += 2
				continue
			}
		}
		append(&out, s[i])
	}
	return string(out[:])
}

// file:// URI for a path (for text/uri-list).
file_uri :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		ch := path[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '/', '-', '_', '.', '~':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

parent_dir :: proc(p: string) -> string {
	if p == "/" { return "/" }
	return clean_path(filepath.dir(p))
}

base_name :: proc(p: string) -> string {
	if p == "/" { return "/" }
	return filepath.base(p)
}

is_directory :: proc(p: string) -> bool {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK { return false }
	return posix.S_ISDIR(st.st_mode)
}

// lstat-level existence (a broken link exists too).
path_exists :: proc(p: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK
}

mtime_of :: proc(p: string) -> (i64, bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(p, context.temp_allocator), &st) != .OK { return 0, false }
	return i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec), true
}

// A name in `dir` that does not exist yet: "name", "name (2)", "name (3)"...
// The extension of files is kept at the end ("foto (2).jpg").
unique_name :: proc(dir, name: string, is_dir: bool) -> string {
	if !path_exists(join({dir, name})) { return name }
	stem, ext := name, ""
	if !is_dir {
		dot := strings.last_index_byte(name, '.')
		if dot > 0 {
			stem, ext = name[:dot], name[dot:]
			// Keep double extensions of archives together (".tar.gz").
			if strings.has_suffix(stem, ".tar") { stem, ext = stem[:len(stem) - 4], name[len(stem) - 4:] }
		}
	}
	for n in 2 ..< 10000 {
		candidate := fmt.tprintf("%s (%d)%s", stem, n, ext)
		if !path_exists(join({dir, candidate})) { return candidate }
	}
	return fmt.tprintf("%s (%d)%s", stem, posix.getpid(), ext)
}

// ---------------------------------------------------------------------------
// Places (sidebar)
// ---------------------------------------------------------------------------
Place_Kind :: enum { Home, Desktop, Documents, Downloads, Pictures, Music, Videos, Trash, Common, Area, Wallpapers }

Place :: struct {
	kind:  Place_Kind,
	label: string, // temp allocator (rebuilt every frame)
	path:  string,
	milk:  bool,   // belongs to the "milk" group
	area:  int,
}

trash_files_dir :: proc() -> string { return join({data_home(), "Trash", "files"}) }

// milk's runtime folder: $MILK_RUNTIME, <Documents>/milk/runtime, or the
// legacy <Documents>/Temenos/runtime when only that one exists.
runtime_root :: proc() -> string {
	for name in ([]string{"MILK_RUNTIME", "TEMENOS_RUNTIME"}) {
		if v, found := os.lookup_env(name, context.temp_allocator); found && v != "" { return v }
	}
	docs := xdg_user_dir("DOCUMENTS")
	if docs == "" { docs = join({home_dir(), "Documents"}) }
	runtime := join({docs, "milk", "runtime"})
	legacy := join({docs, "Temenos", "runtime"})
	if !is_directory(runtime) && is_directory(legacy) { return legacy }
	return runtime
}

// The sidebar entries that exist on disk, in display order.
build_places :: proc(a: ^App) -> []Place {
	out := make([dynamic]Place, context.temp_allocator)
	add :: proc(out: ^[dynamic]Place, kind: Place_Kind, label, path: string, milk := false, area := 0) {
		if path == "" || !is_directory(path) { return }
		append(out, Place{kind = kind, label = label, path = clean_path(path), milk = milk, area = area})
	}
	add(&out, .Home, tr(a, "Início", "Home"), home_dir())
	add(&out, .Desktop, tr(a, "Área de trabalho", "Desktop"), xdg_user_dir("DESKTOP"))
	add(&out, .Documents, tr(a, "Documentos", "Documents"), xdg_user_dir("DOCUMENTS"))
	add(&out, .Downloads, tr(a, "Downloads", "Downloads"), xdg_user_dir("DOWNLOAD"))
	add(&out, .Pictures, tr(a, "Imagens", "Pictures"), xdg_user_dir("PICTURES"))
	add(&out, .Music, tr(a, "Música", "Music"), xdg_user_dir("MUSIC"))
	add(&out, .Videos, tr(a, "Vídeos", "Videos"), xdg_user_dir("VIDEOS"))
	trash := trash_files_dir()
	if is_directory(trash) {
		append(&out, Place{kind = .Trash, label = tr(a, "Lixeira", "Trash"), path = clean_path(trash)})
	}

	root := runtime_root()
	common, wallpapers := "Common", "Wallpapers"
	if a.cfg != nil {
		common, wallpapers = a.cfg.paths.common, a.cfg.paths.wallpapers
	}
	add(&out, .Common, tr(a, "Comum", "Common"), join({root, common}), true)
	if a.cfg != nil {
		keys := make([dynamic]int, context.temp_allocator)
		for k in a.cfg.workspaces { append(&keys, k) }
		slice.sort(keys[:])
		for k in keys {
			ws := a.cfg.workspaces[k]
			label := strings.trim_space(ws.name)
			if label == "" { label = fmt.tprintf(tr(a, "Área %d", "Area %d"), k) }
			add(&out, .Area, label, join({root, ws.folder}), true, k)
		}
	} else {
		for k in 1 ..= 9 {
			add(&out, .Area, fmt.tprintf(tr(a, "Área %d", "Area %d"), k), join({root, fmt.tprintf("Area%d", k)}), true, k)
		}
	}
	add(&out, .Wallpapers, tr(a, "Papéis de parede", "Wallpapers"), join({root, wallpapers}), true)
	return out[:]
}

// Theme icon name for a well-known folder (Adwaita's places icons).
special_folder_icon :: proc(path: string) -> string {
	if path == clean_path(home_dir()) { return "user-home" }
	pairs := [?][2]string{
		{"DESKTOP", "user-desktop"}, {"DOCUMENTS", "folder-documents"}, {"DOWNLOAD", "folder-download"},
		{"PICTURES", "folder-pictures"}, {"MUSIC", "folder-music"}, {"VIDEOS", "folder-videos"},
		{"TEMPLATES", "folder-templates"}, {"PUBLICSHARE", "folder-publicshare"},
	}
	for p in pairs {
		dir := xdg_user_dir(p[0])
		if dir != "" && clean_path(dir) == path { return p[1] }
	}
	return ""
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

// Read `dir` into `out` (cleared first). Errors: the errno of opendir.
list_directory :: proc(dir: string, out: ^[dynamic]Entry) -> posix.Errno {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	d := posix.opendir(cdir)
	if d == nil { return posix.errno() }
	defer posix.closedir(d)
	entries_clear(out)
	fd := posix.dirfd(d)
	for {
		de := posix.readdir(d)
		if de == nil { break }
		cname := cstring(&de.d_name[0])
		name := string(cname)
		if name == "." || name == ".." || name == "" { continue }
		e: Entry
		e.name = strings.clone(name)
		e.hidden = name[0] == '.' || strings.has_suffix(name, "~")
		st: posix.stat_t
		if posix.fstatat(fd, cname, &st, {.SYMLINK_NOFOLLOW}) != .OK {
			e.unreadable = true
			e.kind = .Generic
		} else {
			if posix.S_ISLNK(st.st_mode) {
				e.is_link = true
				target: posix.stat_t
				if posix.fstatat(fd, cname, &target, {}) == .OK {
					st = target
				} else {
					e.kind = .Broken
					e.unreadable = true
				}
			}
			e.size = i64(st.st_size)
			e.mtime = i64(st.st_mtim.tv_sec)
			if e.kind != .Broken {
				e.is_dir = posix.S_ISDIR(st.st_mode)
				want: posix.Mode_Flags = e.is_dir ? {.R_OK, .X_OK} : {.R_OK}
				if posix.faccessat(fd, cname, want, {}) != .OK { e.unreadable = true }
				exec := posix.S_ISREG(st.st_mode) && (st.st_mode & {.IXUSR, .IXGRP, .IXOTH}) != {}
				e.kind = e.is_dir ? .Folder : kind_for_name(name, exec)
			}
		}
		e.key = sort_key(name)
		append(out, e)
	}
	return .NONE
}

// Lower-cased name without accents: "Música" sorts and matches like "musica".
sort_key :: proc(name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(name), allocator)
	for r in name {
		strings.write_rune(&b, fold_rune(r))
	}
	return strings.to_string(b)
}

fold_rune :: proc(r: rune) -> rune {
	l := unicode.to_lower(r)
	switch l {
	case 'á', 'à', 'â', 'ã', 'ä', 'å': return 'a'
	case 'é', 'è', 'ê', 'ë':           return 'e'
	case 'í', 'ì', 'î', 'ï':           return 'i'
	case 'ó', 'ò', 'ô', 'õ', 'ö':      return 'o'
	case 'ú', 'ù', 'û', 'ü':           return 'u'
	case 'ç':                          return 'c'
	case 'ñ':                          return 'n'
	case 'ý', 'ÿ':                     return 'y'
	}
	return l
}

// Natural order on folded keys: "img2" < "img10".
natural_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		ca, cb := a[i], b[j]
		if is_digit(ca) && is_digit(cb) {
			si := i
			for i < len(a) && is_digit(a[i]) { i += 1 }
			sj := j
			for j < len(b) && is_digit(b[j]) { j += 1 }
			na := strings.trim_left(a[si:i], "0")
			nb := strings.trim_left(b[sj:j], "0")
			if len(na) != len(nb) { return len(na) < len(nb) }
			if na != nb { return na < nb }
			if (i - si) != (j - sj) { return (i - si) > (j - sj) } // "01" before "1"
			continue
		}
		if ca != cb { return ca < cb }
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j
}

@(private)
is_digit :: #force_inline proc(ch: u8) -> bool { return ch >= '0' && ch <= '9' }

// Folders first, then by name (natural, case- and accent-insensitive).
entry_less :: proc(a, b: Entry) -> bool {
	if a.is_dir != b.is_dir { return a.is_dir }
	if a.key != b.key { return natural_less(a.key, b.key) }
	return a.name < b.name
}

// Does the folded `key` contain the folded `needle`?
matches_filter :: proc(key, needle: string) -> bool {
	if needle == "" { return true }
	return strings.contains(key, needle)
}

// ---------------------------------------------------------------------------
// Kinds
// ---------------------------------------------------------------------------
@(rodata) EXT_IMAGE := []string{"png", "jpg", "jpeg", "jpe", "gif", "bmp", "webp", "svg", "svgz", "tif", "tiff", "ico", "heic", "heif", "avif", "xpm", "qoi", "tga", "ppm", "pgm", "pbm", "pnm", "jxl", "xcf", "psd", "kra"}
@(rodata) EXT_AUDIO := []string{"mp3", "flac", "ogg", "oga", "opus", "wav", "m4a", "aac", "wma", "aif", "aiff", "mid", "midi", "ape", "wv", "mka"}
@(rodata) EXT_VIDEO := []string{"mp4", "mkv", "webm", "avi", "mov", "wmv", "flv", "m4v", "mpg", "mpeg", "ogv", "3gp", "ts", "m2ts", "vob"}
@(rodata) EXT_ARCHIVE := []string{"zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "7z", "rar", "lz", "lz4", "lzma", "cab", "deb", "rpm", "jar", "apk", "iso", "img", "dmg", "cpio", "ar"}
@(rodata) EXT_CODE := []string{"c", "h", "cpp", "hpp", "cc", "cxx", "hh", "py", "js", "mjs", "cjs", "ts", "jsx", "tsx", "odin", "go", "rs", "java", "kt", "kts", "sh", "bash", "zsh", "fish", "rb", "php", "lua", "pl", "cs", "swift", "html", "htm", "css", "scss", "sass", "less", "json", "json5", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "sql", "vim", "mk", "cmake", "diff", "patch", "ps1", "bat", "cmd", "vbs", "zig", "nim", "hs", "ml", "ex", "exs", "erl", "clj", "scm", "el", "dart", "vue", "svelte", "glsl", "hlsl", "desktop", "service", "gradle", "nix", "r", "jl", "m", "mm", "asm", "s"}
@(rodata) EXT_TEXT := []string{"txt", "md", "markdown", "rst", "log", "csv", "tsv", "tex", "org", "nfo", "srt", "vtt", "ass", "sub", "adoc", "text", "readme", "me", "1", "man"}
@(rodata) EXT_DOC := []string{"doc", "docx", "odt", "rtf", "abw", "pages", "epub", "fodt"}
@(rodata) EXT_SHEET := []string{"xls", "xlsx", "ods", "numbers", "fods"}
@(rodata) EXT_SLIDES := []string{"ppt", "pptx", "odp", "key", "fodp"}
@(rodata) EXT_EXEC := []string{"appimage", "run", "bin", "exe", "msi", "flatpakref"}

lower_ext :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 { return "" }
	return strings.to_lower(name[dot + 1:], context.temp_allocator)
}

kind_for_name :: proc(name: string, executable: bool) -> File_Kind {
	ext := lower_ext(name)
	in_list :: proc(list: []string, ext: string) -> bool {
		for e in list { if e == ext { return true } }
		return false
	}
	switch {
	case ext == "":
		if executable { return .Executable }
		lower := strings.to_lower(name, context.temp_allocator)
		switch lower {
		case "makefile", "dockerfile", "pkgbuild", "cmakelists.txt", "justfile", "gemfile", "rakefile":
			return .Code
		case "readme", "license", "copying", "authors", "changelog", "todo", "news", "install":
			return .Text
		}
		return .Generic
	case ext == "pdf":                return .Pdf
	case in_list(EXT_IMAGE, ext):     return .Image
	case in_list(EXT_AUDIO, ext):     return .Audio
	case in_list(EXT_VIDEO, ext):     return .Video
	case in_list(EXT_ARCHIVE, ext):   return .Archive
	case in_list(EXT_DOC, ext):       return .Document
	case in_list(EXT_SHEET, ext):     return .Spreadsheet
	case in_list(EXT_SLIDES, ext):    return .Presentation
	case in_list(EXT_CODE, ext):      return .Code
	case in_list(EXT_TEXT, ext):      return .Text
	case in_list(EXT_EXEC, ext):      return .Executable
	}
	return executable ? .Executable : .Generic
}

// Can core:image (or a helper) make a thumbnail of this file?
thumbnailable :: proc(name: string) -> bool {
	switch lower_ext(name) {
	case "png", "jpg", "jpeg", "jpe", "bmp", "qoi", "tga", "ppm", "pgm", "pbm", "pnm":
		return true
	case "svg", "svgz":
		return g_tools.rsvg
	case "gif", "webp", "tif", "tiff", "avif", "heic", "heif", "jxl", "ico":
		return g_tools.magick != ""
	}
	return false
}

// Images that can become a milk wallpaper (feh loads these).
wallpaper_capable :: proc(name: string) -> bool {
	switch lower_ext(name) {
	case "png", "jpg", "jpeg", "jpe", "bmp", "webp", "gif", "tif", "tiff":
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// "4,2 MB" (pt-BR) / "4.2 MB": SI units like most Linux file managers.
format_size :: proc(a: ^App, bytes: i64) -> string {
	if bytes < 1000 {
		return bytes == 1 ? tr(a, "1 byte", "1 byte") : fmt.tprintf("%d bytes", bytes)
	}
	units := [?]string{"kB", "MB", "GB", "TB", "PB"}
	v := f64(bytes) / 1000
	u := 0
	for v >= 1000 && u < len(units) - 1 {
		v /= 1000
		u += 1
	}
	s := v >= 100 ? fmt.tprintf("%.0f %s", v, units[u]) : fmt.tprintf("%.1f %s", v, units[u])
	if a.pt { s, _ = strings.replace_all(s, ".", ",", context.temp_allocator) }
	return s
}

@(rodata) MONTHS_PT := [12]string{"jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"}
@(rodata) MONTHS_EN := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

@(private)
local_tm :: proc(t: i64) -> posix.tm {
	tt := posix.time_t(t)
	out: posix.tm
	posix.localtime_r(&tt, &out)
	return out
}

// "Hoje 14:32", "Ontem 09:10", "12 set", "12 set 2024".
format_date :: proc(a: ^App, t: i64) -> string {
	if t <= 0 { return "—" }
	now := i64(posix.time(nil))
	tm := local_tm(t)
	today := local_tm(now)
	day_index :: proc(tm: posix.tm) -> int { return int(tm.tm_year) * 400 + int(tm.tm_yday) }
	diff := day_index(today) - day_index(tm)
	months := a.pt ? MONTHS_PT : MONTHS_EN
	mon := months[clamp(int(tm.tm_mon), 0, 11)]
	switch {
	case diff == 0:
		return fmt.tprintf("%s %02d:%02d", tr(a, "Hoje", "Today"), tm.tm_hour, tm.tm_min)
	case diff == 1:
		return fmt.tprintf("%s %02d:%02d", tr(a, "Ontem", "Yesterday"), tm.tm_hour, tm.tm_min)
	case tm.tm_year == today.tm_year:
		return a.pt ? fmt.tprintf("%d %s %02d:%02d", tm.tm_mday, mon, tm.tm_hour, tm.tm_min) : fmt.tprintf("%s %d %02d:%02d", mon, tm.tm_mday, tm.tm_hour, tm.tm_min)
	}
	return a.pt ? fmt.tprintf("%d %s %d", tm.tm_mday, mon, int(tm.tm_year) + 1900) : fmt.tprintf("%s %d %d", mon, tm.tm_mday, int(tm.tm_year) + 1900)
}

kind_label :: proc(a: ^App, k: File_Kind) -> string {
	switch k {
	case .Folder:       return tr(a, "Pasta", "Folder")
	case .Text:         return tr(a, "Texto", "Text")
	case .Image:        return tr(a, "Imagem", "Image")
	case .Audio:        return tr(a, "Áudio", "Audio")
	case .Video:        return tr(a, "Vídeo", "Video")
	case .Archive:      return tr(a, "Arquivo compactado", "Archive")
	case .Pdf:          return "PDF"
	case .Code:         return tr(a, "Código", "Code")
	case .Document:     return tr(a, "Documento", "Document")
	case .Spreadsheet:  return tr(a, "Planilha", "Spreadsheet")
	case .Presentation: return tr(a, "Apresentação", "Presentation")
	case .Executable:   return tr(a, "Programa", "Program")
	case .Generic:      return tr(a, "Arquivo", "File")
	case .Broken:       return tr(a, "Atalho quebrado", "Broken link")
	}
	return ""
}

// Free space on the file system holding `path` (bytes), via statvfs.
free_space :: proc(path: string) -> (i64, bool) {
	buf: posix.statvfs_t
	if posix.statvfs(strings.clone_to_cstring(path, context.temp_allocator), &buf) != .OK { return 0, false }
	return i64(buf.f_bavail) * i64(buf.f_frsize), true
}

// First rune and its byte length (0 for an empty string).
first_rune :: proc(s: string) -> (rune, int) {
	if len(s) == 0 { return 0, 0 }
	return utf8.decode_rune_in_string(s)
}

