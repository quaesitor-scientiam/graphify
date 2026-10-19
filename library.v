module graphify

import os

// LibraryRoots are where the modules a project imports from outside its tree are
// read from, as V3 looks for them after the project: `vroot`, the V checkout whose
// vlib holds the standard library, then `vmodules`, where `v install` puts modules
// (~/.vmodules). An empty root is not looked in. See FUTURE_WORK.md §10.
pub struct LibraryRoots {
pub:
	vroot    string
	vmodules string
}

// the roots handed to the worker processes, which name an import of a vlib alias
// directory (`x.json2`) by the module it stands for (library_import)
const lib_env_vroot = 'GRAPHIFY_LIB_VROOT'
const lib_env_vmodules = 'GRAPHIFY_LIB_VMODULES'

// the rel prefixes a library file is extracted under: a vlib file's rel is its path
// from VROOT (`vlib/os/os.v`, so its ids are `vlib.os...`, as in the V tree's own
// graph), and a VMODULES file's is its path below VMODULES under `vmodules/`
// (`vmodules/vglyph/x.v`, ids `vmodules.vglyph...`)
const lib_vlib_prefix = 'vlib/'
const lib_vmodules_prefix = 'vmodules/'

// detect_library_roots finds the library roots of this machine: VROOT is the
// `VROOT` environment variable, or the directory of the `v` on PATH; VMODULES is the
// `VMODULES` variable, or ~/.vmodules. A root without what it should hold is left
// empty, and a `VROOT` set to '' turns the library off.
pub fn detect_library_roots() LibraryRoots {
	mut vroot := ''
	if 'VROOT' in os.environ() {
		vroot = os.getenv('VROOT')
	} else if v := os.find_abs_path_of_executable('v') {
		vroot = os.dir(os.real_path(v))
	}
	if vroot != '' && !os.is_dir(os.join_path(vroot, 'vlib', 'builtin')) {
		vroot = ''
	}
	if vroot == '' {
		return LibraryRoots{}
	}
	mut vmodules := os.getenv('VMODULES')
	if vmodules == '' {
		vmodules = os.join_path(os.home_dir(), '.vmodules')
	}
	return LibraryRoots{
		vroot:    os.real_path(vroot)
		vmodules: if os.is_dir(vmodules) { os.real_path(vmodules) } else { '' }
	}
}

pub fn (r LibraryRoots) enabled() bool {
	return r.vroot != ''
}

// export_env hands the roots to the worker processes this one starts.
fn (r LibraryRoots) export_env() {
	os.setenv(lib_env_vroot, r.vroot, true)
	os.setenv(lib_env_vmodules, r.vmodules, true)
}

// cache_tag is what a cache entry's extraction depends on besides the binary and
// the file: the roots an import is named against.
fn (r LibraryRoots) cache_tag() string {
	return if r.enabled() { 'lib:${r.vroot}:${r.vmodules}' } else { '' }
}

// library_import names an import the tree doesn't have the way V3 finds it next, in
// VROOT's vlib: an alias directory (`x.json2`) is the module it names (`json2`, for
// vlib/json2), and any other module keeps its name, which is its path below vlib or
// VMODULES. In a VMODULES file, `file_path`, a module of its own comes first, found
// beside its v.mod as V finds it: `import accessibility` in vglyph is
// `vglyph.accessibility`. Only a worker the library is handed to looks (export_env).
fn library_import(mod string, file_path string) string {
	vroot := os.getenv(lib_env_vroot)
	if vroot == '' {
		return mod
	}
	if own := vmodules_own_import(mod, file_path) {
		return own
	}
	vlib := vroot + '/vlib'
	if target := alias_dir_target(vlib + '/' + mod.replace('.', '/')) {
		full := vroot + '/' + target
		if full.starts_with(vlib + '/') {
			return full[vlib.len + 1..].replace('/', '.')
		}
	}
	return mod
}

// vmodules_own_import is the module `mod` names from the VMODULES file `file_path`
// when it is one of that module's own, beside the v.mod above the file, by its path
// below VMODULES; none for a file outside VMODULES or an import no v.mod holds.
fn vmodules_own_import(mod string, file_path string) ?string {
	vmods := os.getenv(lib_env_vmodules).replace('\\', '/')
	fp := file_path.replace('\\', '/')
	if vmods == '' || !fp.starts_with(vmods + '/') {
		return none
	}
	mut d := fp.all_before_last('/')
	for d.len > vmods.len {
		if os.exists(d + '/v.mod') {
			c := d + '/' + mod.replace('.', '/')
			if has_v_sources(c) {
				return c[vmods.len + 1..].replace('/', '.')
			}
			return none
		}
		d = d.all_before_last('/')
	}
	return none
}

// LibModule is a module directory the library is read from, with the rel its files
// are extracted under (`vlib/os`, `vmodules/vglyph`).
struct LibModule {
	dir     string
	rel_dir string
}

// module_of is the directory of the module an import names (`os`, `sokol.sapp`,
// `json2`, `vglyph`), in VROOT's vlib and then in VMODULES, as V3 looks.
fn (r LibraryRoots) module_of(imp string) ?LibModule {
	if imp == '' || imp.starts_with('.') {
		return none
	}
	path := imp.replace('.', '/')
	if r.vroot != '' {
		dir := os.join_path(r.vroot, 'vlib', path)
		if has_v_sources(dir) {
			return LibModule{
				dir:     dir
				rel_dir: lib_vlib_prefix + path
			}
		}
	}
	if r.vmodules != '' {
		dir := os.join_path(r.vmodules, path)
		if has_v_sources(dir) {
			return LibModule{
				dir:     dir
				rel_dir: lib_vmodules_prefix + path
			}
		}
	}
	return none
}

// files are a module's own source files: the `.v` files directly in its directory,
// in sorted order, without its tests. A subdirectory is another module.
fn (m LibModule) files() []string {
	mut names := os.ls(m.dir) or { return [] }
	names.sort()
	mut out := []string{}
	for n in names {
		if n.ends_with('.v') && !n.ends_with('_test.v') && !os.is_dir(os.join_path(m.dir, n)) {
			out << n
		}
	}
	return out
}

// path_of is the file on disk a library symbol's `file` names: `vlib/os/os.v` below
// VROOT, and `vmodules/vglyph/x.v` as `vglyph/x.v` below VMODULES.
fn (l Library) path_of(file string) ?string {
	if file.starts_with(lib_vlib_prefix) {
		root := l.roots['vlib'] or { return none }
		return os.join_path(root, file)
	}
	if file.starts_with(lib_vmodules_prefix) {
		root := l.roots['vmodules'] or { return none }
		return os.join_path(root, file[lib_vmodules_prefix.len..])
	}
	return none
}
