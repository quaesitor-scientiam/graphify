module graphify

import os

// Frontend-independent helpers shared by both extractors: the V 0.5.2 one in
// backend_v_notd_graphify_v3.v (the default build) and the V3 one in
// backend_v3_d_graphify_v3.v (`-d graphify_v3`).

// module_id builds a module id from `rel`, the graph-root-relative path of the
// file, instead of from V's `file.mod.name`. V qualifies that name by the
// file's path relative to the parent of the *process working directory*, so the
// same file yields a different name depending on where graphify was invoked
// from: `ci/common/runner.v` parses as `vlang.ci.common` from inside the vlang
// repo, `repo.vlang.ci.common` one level up, and a bare `common` from /tmp.
// That made every id -- and so every edge endpoint -- depend on the caller's
// cwd, which is why two machines extracting the same commit produced graphs
// that could not be compared. `rel` is derived from the extraction root, which
// is recorded in manifest.json, so it is stable across machines and callers.
//
// The directory is used as the whole identity, not just as a prefix on the
// declared name: V allows one module per directory, so the path already
// identifies it uniquely (`vlib/rand` and `vlib/crypto/rand` both declare
// `module rand` and stay distinct as `vlib.rand` / `vlib.crypto.rand`). The
// declared name deliberately does NOT contribute, because it cannot be read
// back reliably -- when V qualifies, it *replaces* the declared name with the
// path-derived one, so `examples/call_v_from_c/v_test_math.v` (which declares
// `module test_math`) reports `examples.call_v_from_c` from inside the repo and
// `test_math` from outside it. Only files with no directory of their own fall
// back to V's name, which is all there is to go on for a single-file run.
//
// Two modules in one directory -- a `_test.v` declaring `module main` beside an
// ordinary module -- therefore land on the same id here, which is precisely the
// build-unit collision disambiguate_ids already splits by file.
fn module_id(rel string, mod_name string) string {
	dir := os.dir(rel)
	if dir == '' || dir == '.' || dir == rel {
		// V's `module x` is a single identifier, so anything before the last
		// dot is qualification V added from the cwd, not part of the name.
		declared := mod_name.all_after_last('.')
		return if declared == '' { 'main' } else { declared }
	}
	return dir.replace('\\', '/').replace('/', '.')
}

// import_id is the id of the symbol for module `mod_id` importing `imported`.
// extract_from_ast builds import symbols with it and reparse_by_declaration
// matches their edges by it.
fn import_id(mod_id string, imported string) string {
	return '${mod_id}::import::${imported}'
}

// strip_generic_args drops the `[...]` argument list after a generic type's
// name, so `veb.Middleware[Context]` is read as `veb.Middleware` rather than
// leaving base_type_name nothing after the closing bracket. A `[` that
// follows an identifier opens generic arguments, except after `map`, whose
// brackets hold the key type; array brackets (`[]Foo`, `[4]Foo`) never follow
// an identifier and are kept.
fn strip_generic_args(name string) string {
	mut out := []u8{cap: name.len}
	mut depth := 0
	for i := 0; i < name.len; i++ {
		ch := name[i]
		if depth > 0 {
			if ch == `[` {
				depth++
			} else if ch == `]` {
				depth--
			}
			continue
		}
		if ch == `[` && out.len > 0 && (out.last().is_alnum() || out.last() == `_`)
			&& !out.bytestr().ends_with('map') {
			depth = 1
			continue
		}
		out << ch
	}
	return out.bytestr()
}

// is_generic_param reports whether a type name is a generic parameter such as
// `T`: V requires those to be exactly one capital letter, and they name no
// declaration, so a reference to one could never resolve.
fn is_generic_param(name string) bool {
	return name.len == 1 && name[0] >= `A` && name[0] <= `Z`
}

// doc_from collects the `//` block directly above `line` (1-based) from the
// source text. It stops at a blank line or anything that is not a comment, so a
// licence header, a section banner, or a note about the code *above* never gets
// attached to the declaration below it.
//
// Read from source rather than from the AST on purpose: in `.toplevel_comments`
// mode V surfaces only the *first* line of a contiguous block as a top-level
// node, which silently truncated every multi-line doc to one line. Reading the
// block directly is exact, and lets the parse stay in the cheaper
// `.skip_comments` mode.
fn doc_from(src []string, line int) string {
	mut out := []string{}
	mut i := line - 2 // 0-based index of the line above the declaration
	for i >= 0 && i < src.len {
		t := src[i].trim_space()
		if t.starts_with('@[') {
			i-- // attributes sit between the doc and the declaration
			continue
		}
		if !t.starts_with('//') {
			break
		}
		out.prepend(t.trim_string_left('//').trim_space())
		i--
	}
	return out.join('\n').trim_space()
}

// add_ref records a `references` edge to a type name, deduped per declaration.
fn add_ref(from string, typename string, file string, mut edges []Edge, mut seen map[string]bool) {
	if typename == '' || typename in seen || is_generic_param(typename) {
		return
	}
	seen[typename] = true
	edges << Edge{
		from: from
		to:   typename
		kind: .references
		file: file
	}
}
