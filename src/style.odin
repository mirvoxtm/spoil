// Look: milk.json (found through $MILK_CONFIG or next to the milk clone) gives
// the colours, fonts, icon font, bar height/radius and UI language. The file
// is watched (mtime, about once a second) and Spoil restyles itself live, so
// theme changes made in milk's settings follow at once.
package spoil

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import config "milk:config"
import tx "milk:tx"

Theme :: struct {
	bg, fg, muted, accent, accent_fg, surface, warning: tx.Color,
	dark:     bool,
	backdrop: tx.Color, // window background around the cards
	field:    tx.Color, // text fields, segmented controls
	outline:  tx.Color,
	hover:    tx.Color, // hover pills
	pressed:  tx.Color,
	select:   tx.Color, // selected items (tonal accent)
	dim:      tx.Color, // greyed text (unreadable entries)
	sub:      tx.Color, // secondary text
}

// Tabler glyphs (the icon font of milk's bar).
Ic :: enum {
	None, Arrow_Left, Arrow_Right, Arrow_Up, Chevron_Right, Search, Grid, List, Eye, Eye_Off, Home, Folder,
	Folder_Open, Folder_Plus, File, Photo, Music, Movie, Download, Trash, Desktop, File_Text, Copy, Cut,
	Clipboard, Pencil, Terminal, External, X, Milk, Wallpaper, Link, Lock, Alert, Check, Apps, Clipboard_Copy,
	Server, Info, Refresh, Folders, Hourglass, Plus, Archive, Unarchive, Folder_Down, Columns, App_Window,
	Chevron_Down, Chevron_Up, Folder_Search,
}

@(rodata)
IC_CODES := [Ic]rune{
	.None = 0, .Arrow_Left = 0xEA19, .Arrow_Right = 0xEA1F, .Arrow_Up = 0xEA25, .Chevron_Right = 0xEA61,
	.Search = 0xEB1C, .Grid = 0xEDBA, .List = 0xEB6B, .Eye = 0xEA9A, .Eye_Off = 0xECF0, .Home = 0xEAC1,
	.Folder = 0xEAAD, .Folder_Open = 0xFAF7, .Folder_Plus = 0xEAAB, .File = 0xEAA4, .Photo = 0xEB0A,
	.Music = 0xEAFC, .Movie = 0xEAFA, .Download = 0xEA96, .Trash = 0xEB41, .Desktop = 0xEA89,
	.File_Text = 0xEAA2, .Copy = 0xEA7A, .Cut = 0xEA86, .Clipboard = 0xEA6F, .Pencil = 0xEB04,
	.Terminal = 0xEBEF, .External = 0xEA99, .X = 0xEB55, .Milk = 0xEF13, .Wallpaper = 0xEF56, .Link = 0xEADE,
	.Lock = 0xEAE2, .Alert = 0xEA06, .Check = 0xEA5E, .Apps = 0xEBB6, .Clipboard_Copy = 0xF299,
	.Server = 0xEB1F, .Info = 0xEAC5, .Refresh = 0xEB13, .Folders = 0xEAAE, .Hourglass = 0xEF93, .Plus = 0xEB0B,
	.Archive = 0xEA0B, .Unarchive = 0xF07A, .Folder_Down = 0xF912, .Columns = 0xEAD4, .App_Window = 0xEFE6,
	.Chevron_Down = 0xEA5F, .Chevron_Up = 0xEA62, .Folder_Search = 0xF918,
}

Style :: struct {
	theme:       Theme,
	font:        ^tx.Font, // body text: milk's bar font and size
	font_small:  ^tx.Font, // grid labels
	font_tiny:   ^tx.Font, // status line, column headers
	font_bold:   ^tx.Font, // group headers
	icon:        ^tx.Font, // Tabler at the bar's icon size (toolbar)
	icon_small:  ^tx.Font, // sidebar, menu, fields
	icon_big:    ^tx.Font, // empty states
	bar_h:       i32,
	icon_size:   i32,
	font_size:   i32,
	radius:      i32,      // card corners (the bar's radius)
	pill_h:      i32,      // hover pills (the bar's hover height)
	anim_scale:  f64,
}

tr :: proc(a: ^App, pt, en: string) -> string { return a.pt ? pt : en }

// milk.json: $MILK_CONFIG (set by milk), else ~/.config/milk/milk.json, else
// ../milk/milk.json next to Spoil's folder (where milk kept it before).
find_config :: proc() -> string {
	if v, found := os.lookup_env("MILK_CONFIG", context.temp_allocator); found && v != "" { return strings.clone(v) }
	config_home, has := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
	if !has || config_home == "" {
		home, _ := os.lookup_env("HOME", context.temp_allocator)
		config_home, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	if p, _ := filepath.join({config_home, "milk", "milk.json"}, context.temp_allocator); os.is_file(p) { return strings.clone(p) }
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		// bin/spoil → ../../milk/milk.json; a binary in spoil/ itself → ../milk/milk.json.
		for rel in ([]string{"../../milk/milk.json", "../milk/milk.json"}) {
			p, _ := filepath.join({dir, rel}, context.temp_allocator)
			p = clean_path(p)
			if os.is_file(p) { return strings.clone(p) }
		}
	}
	return ""
}

// The bar options in effect (milk.json, or milk's defaults without it).
bar_opts :: proc(a: ^App) -> config.Bar_Options {
	if a.cfg != nil { return a.cfg.bar }
	return config.default_bar()
}

terminal_command :: proc(a: ^App) -> string {
	if a.cfg != nil && strings.trim_space(a.cfg.wm.terminal) != "" { return a.cfg.wm.terminal }
	return config.default_wm().terminal
}

// (Re)load milk.json. On the first load a broken or missing file gives the
// defaults; later a broken file (being written, say) keeps the current look.
load_config :: proc(a: ^App, first: bool) -> bool {
	if a.cfg_path == "" {
		if first { log.info("milk.json not found; using milk's default look") }
		return first
	}
	mt, ok := config_stamp(a)
	a.cfg_mtime = mt
	if !ok {
		if first { log.warnf("Cannot read %s; using milk's default look", a.cfg_path) }
		return first
	}
	cfg, err := config.load(a.cfg_path)
	if err != "" {
		log.warnf("milk.json: %s", err)
		delete(err)
		return first
	}
	if a.cfg != nil { config.destroy(a.cfg) }
	a.cfg = cfg
	return true
}

opaque :: proc(c: tx.Color) -> tx.Color { return {c.r, c.g, c.b, 255} }
mix :: proc(a, b: tx.Color, t: f32) -> tx.Color { return opaque(tx.color_mix(a, b, t)) }

luminance :: proc(c: tx.Color) -> f32 {
	return (0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b)) / 255
}

make_theme :: proc(t: config.Bar_Theme) -> Theme {
	th: Theme
	th.bg = tx.color_from_hex(t.background, tx.rgb(0xF5, 0xEE, 0xE6))
	th.fg = tx.color_from_hex(t.foreground, tx.rgb(0x3C, 0x3A, 0x38))
	th.muted = tx.color_from_hex(t.muted, tx.rgb(0xA8, 0x9E, 0x94))
	th.accent = tx.color_from_hex(t.accent, tx.rgb(0x4A, 0x3F, 0x35))
	th.accent_fg = tx.color_from_hex(t.accent_foreground, tx.rgb(0xF5, 0xEE, 0xE6))
	th.surface = tx.color_from_hex(t.surface, tx.rgb(0xE9, 0xE0, 0xD6))
	th.warning = tx.color_from_hex(t.warning, tx.rgb(0xB5, 0x47, 0x3A))
	th.bg, th.fg, th.muted = opaque(th.bg), opaque(th.fg), opaque(th.muted)
	th.accent, th.accent_fg, th.surface, th.warning = opaque(th.accent), opaque(th.accent_fg), opaque(th.surface), opaque(th.warning)
	th.dark = luminance(th.bg) < 0.5
	black := tx.rgb(0, 0, 0)
	if th.dark {
		th.backdrop = mix(th.bg, black, 0.28)
		th.field = mix(th.bg, th.surface, 0.8)
		th.outline = mix(th.surface, th.muted, 0.3)
		th.hover = th.surface
		th.pressed = mix(th.surface, th.muted, 0.25)
		th.select = mix(th.bg, th.accent, 0.2)
	} else {
		th.backdrop = mix(mix(th.bg, th.surface, 0.8), th.muted, 0.1)
		th.field = mix(th.bg, th.surface, 0.7)
		th.outline = mix(th.surface, th.muted, 0.4)
		th.hover = th.surface
		th.pressed = mix(th.surface, th.muted, 0.3)
		th.select = mix(th.bg, th.accent, 0.14)
	}
	th.dim = mix(th.fg, th.bg, 0.55)
	th.sub = mix(th.fg, th.muted, 0.6)
	return th
}

// Fonts, icon fonts and metrics from the bar options.
apply_style :: proc(a: ^App) {
	release_style(a)
	delete(a.look)
	a.look = strings.clone(look_signature(a))
	b := bar_opts(a)
	s := &a.style
	s.theme = make_theme(b.theme)
	s.font_size = i32(clamp(b.font_size, 9, 28))
	s.icon_size = i32(clamp(b.icon_size, 12, 32))
	s.bar_h = i32(clamp(b.height, 32, 64))
	s.radius = i32(clamp(b.radius, 6, 22))
	s.pill_h = min(s.bar_h - 8, max(s.icon_size + 9, s.font_size + 14))
	s.anim_scale = a.cfg != nil ? clamp(a.cfg.appearance.animation_scale, 0, 3) : 0.7
	a.pt = b.language == .Portuguese // bar.locale, "auto" = the system language

	open :: proc(c: ^tx.Connection, family, style: string, px: i32) -> ^tx.Font {
		pattern := style == "" ? family : strings.concatenate({family, ":", style}, context.temp_allocator)
		if f, ok := tx.font_open(c, pattern, px); ok { return f }
		fallback := style == "" ? "sans" : strings.concatenate({"sans:", style}, context.temp_allocator)
		f, _ := tx.font_open(c, fallback, px)
		return f
	}
	s.font = open(a.c, b.font, "", s.font_size)
	s.font_small = open(a.c, b.font, "", s.font_size - 1)
	s.font_tiny = open(a.c, b.font, "", max(9, s.font_size - 2))
	s.font_bold = open(a.c, b.font, "bold", max(9, s.font_size - 3))
	if b.icon_font_file != "" && os.exists(b.icon_font_file) {
		s.icon, _ = tx.font_open_file(a.c, b.icon_font_file, s.icon_size)
		s.icon_small, _ = tx.font_open_file(a.c, b.icon_font_file, max(12, s.icon_size - 3))
		s.icon_big, _ = tx.font_open_file(a.c, b.icon_font_file, 46)
		if s.icon != nil && !tx.font_has_glyph(a.c, s.icon, IC_CODES[.Folder]) {
			log.warnf("%s has no Tabler glyphs; icons are drawn as text", b.icon_font_file)
			close_icon_fonts(a)
		}
	} else if b.icon_font_file != "" {
		log.warnf("Icon font %q not found; toolbar icons fall back to text", b.icon_font_file)
	}
	a.base_dirty = true
	a.dirty = true
}

@(private)
close_icon_fonts :: proc(a: ^App) {
	s := &a.style
	for f in ([]^tx.Font{s.icon, s.icon_small, s.icon_big}) { if f != nil { tx.font_close(a.c, f) } }
	s.icon, s.icon_small, s.icon_big = nil, nil, nil
}

release_style :: proc(a: ^App) {
	s := &a.style
	for f in ([]^tx.Font{s.font, s.font_small, s.font_tiny, s.font_bold}) { if f != nil { tx.font_close(a.c, f) } }
	s.font, s.font_small, s.font_tiny, s.font_bold = nil, nil, nil, nil
	close_icon_fonts(a)
}

ic_string :: proc(ic: Ic) -> string {
	if ic == .None { return "" }
	buf, n := utf8.encode_rune(IC_CODES[ic])
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Text fallbacks when the icon font is missing.
ic_fallback :: proc(ic: Ic) -> string {
	#partial switch ic {
	case .Arrow_Left:    return "←"
	case .Arrow_Right:   return "→"
	case .Arrow_Up:      return "↑"
	case .Chevron_Right: return "›"
	case .Chevron_Down:  return "▾"
	case .Chevron_Up:    return "▴"
	case .Search:        return "⌕"
	case .Grid:          return "▦"
	case .List:          return "☰"
	case .Eye:           return "◉"
	case .Eye_Off:       return "○"
	case .X:             return "×"
	case .Check:         return "✓"
	case .Plus:          return "+"
	}
	return "•"
}

// When milk.json or the wallpaper theme's colours (which config.load applies
// over it) last changed; false when milk.json cannot be read.
config_stamp :: proc(a: ^App) -> (i64, bool) {
	if _, ok := mtime_of(a.cfg_path); !ok { return 0, false }
	return config.theme_stamp(a.cfg_path), true
}

// Watch milk.json: returns true when the look changed.
check_config :: proc(a: ^App) -> bool {
	if a.cfg_path == "" { return false }
	mt, ok := config_stamp(a)
	if !ok || mt == a.cfg_mtime { return false }
	if !load_config(a, false) {
		a.cfg_mtime = mt // do not retry a broken file every second
		return false
	}
	sig := look_signature(a)
	if sig == a.look {
		// Only other settings changed (area names, terminal, wallpapers).
		a.dirty = true
		return true
	}
	log.info("milk.json changed; restyling")
	apply_style(a)
	icons_reset(a)
	return true
}

// Everything in milk.json that changes how Spoil looks, as one string (temp).
look_signature :: proc(a: ^App) -> string {
	b := bar_opts(a)
	t := b.theme
	icon_theme := a.cfg != nil ? a.cfg.linux.shortcuts.icon_theme : ""
	anim := a.cfg != nil ? a.cfg.appearance.animation_scale : 0.7
	return fmt.tprintf("%s|%s|%s|%s|%s|%s|%s|%s|%d|%s|%d|%d|%d|%s|%s|%v",
	                   t.background, t.foreground, t.muted, t.accent, t.accent_foreground, t.surface, t.warning,
	                   b.font, b.font_size, b.icon_font_file, b.icon_size, b.height, b.radius, b.locale, icon_theme, anim)
}
