// "Definir como papel de parede da área N": the picture is copied into milk's
// runtime Wallpapers folder, milk.json gets workspaces."N".wallpaper (parsed,
// changed and written back pretty-printed with sorted keys, atomically, every
// other key kept), and the running milk is told to reload with SIGHUP.
package spoil

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

set_wallpaper :: proc(a: ^App, src: string, area: int) {
	if a.cfg_path == "" {
		set_notice(a, tr(a, "milk.json não encontrado", "milk.json not found"), true)
		return
	}
	root := runtime_root()
	folder := a.cfg != nil ? a.cfg.paths.wallpapers : "Wallpapers"
	dir := join({root, folder})
	if !is_directory(dir) {
		if err := os.make_directory_all(dir); err != nil && !is_directory(dir) {
			set_notice(a, fmt.tprintf(tr(a, "Não foi possível criar %s", "Cannot create %s"), dir), true)
			return
		}
	}
	name, ok := copy_into(src, dir)
	if !ok {
		set_notice(a, tr(a, "Não foi possível copiar a imagem para os papéis de parede do milk", "Cannot copy the picture into milk's wallpapers"), true)
		return
	}
	if msg := write_wallpaper(a, area, name); msg != "" {
		set_notice(a, msg, true)
		return
	}
	signalled := signal_milk(root)
	log.infof("Wallpaper of area %d: %s (milk %s)", area, name, signalled ? "reloaded" : "not running")
	set_notice(a, fmt.tprintf(tr(a, "Papel de parede da área %d definido", "Wallpaper of area %d set"), area))
}

// Copy `src` into `dir` unless it already lives there or an identical file
// does; returns the file name inside `dir`.
@(private)
copy_into :: proc(src, dir: string) -> (string, bool) {
	name := base_name(src)
	if parent_dir(src) == clean_path(dir) { return name, true }
	dst := join({dir, name})
	if path_exists(dst) {
		if same_content(src, dst) { return name, true }
		name = unique_name(dir, name, false)
		dst = join({dir, name})
	}
	tmp := fmt.tprintf("%s.spoil-%d.tmp", dst, posix.getpid())
	if err := os.copy_file(tmp, src); err != nil {
		log.warnf("Cannot copy %s: %v", src, err)
		os.remove(tmp)
		return "", false
	}
	if err := os.rename(tmp, dst); err != nil {
		os.remove(tmp)
		return "", false
	}
	return strings.clone(name, context.temp_allocator), true
}

@(private)
same_content :: proc(a, b: string) -> bool {
	da, ea := os.read_entire_file(a, context.temp_allocator)
	if ea != nil { return false }
	db, eb := os.read_entire_file(b, context.temp_allocator)
	if eb != nil { return false }
	return string(da) == string(db)
}

// Set workspaces."<area>".wallpaper in milk.json. Returns an error message ("" = done).
@(private)
write_wallpaper :: proc(a: ^App, area: int, name: string) -> string {
	path := a.cfg_path
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil { return fmt.tprintf(tr(a, "Não foi possível ler %s", "Cannot read %s"), path) }
	value, perr := json.parse(data, .JSON5, true, context.temp_allocator)
	root, is_obj := value.(json.Object)
	if perr != .None || !is_obj { return tr(a, "milk.json está inválido; nada foi alterado", "milk.json is invalid; nothing was changed") }
	workspaces, has_ws := root["workspaces"].(json.Object)
	key := fmt.tprintf("%d", area)
	ws, has_area := workspaces[key].(json.Object)
	if !has_ws || !has_area {
		return fmt.tprintf(tr(a, "A área %d não existe em milk.json", "Area %d is not defined in milk.json"), area)
	}
	ws["wallpaper"] = json.String(name)
	workspaces[key] = ws
	root["workspaces"] = workspaces
	out, merr := json.marshal(root, {spec = .JSON, pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil { return tr(a, "Não foi possível gerar o milk.json", "Cannot encode milk.json") }
	tmp := fmt.tprintf("%s.spoil.tmp", path)
	text := strings.concatenate({string(out), "\n"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, text); werr != nil {
		return fmt.tprintf(tr(a, "Não foi possível gravar %s", "Cannot write %s"), tmp)
	}
	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		return fmt.tprintf(tr(a, "Não foi possível substituir %s", "Cannot replace %s"), path)
	}
	return ""
}

// SIGHUP the milk instance of this runtime folder (pid file + /proc check).
signal_milk :: proc(root: string) -> bool {
	data, err := os.read_entire_file(join({root, "milk.pid"}), context.temp_allocator)
	if err != nil { return false }
	pid, ok := strconv.parse_int(strings.trim_space(string(data)), 10)
	if !ok || pid <= 0 { return false }
	cmdline, cerr := os.read_entire_file(fmt.tprintf("/proc/%d/cmdline", pid), context.temp_allocator)
	if cerr != nil || !strings.contains(string(cmdline), "milk") { return false }
	return posix.kill(posix.pid_t(pid), .SIGHUP) == .OK
}
