module graphify

import os

// the directory of the V tree's files a project's graph is layered on: what a
// project calls (FUTURE_WORK.md §11)
const layer_dir = 'vlib/'

// layered_file reports whether a file of the V tree goes under a project: one in
// vlib, other than its tests, which no project calls.
fn layered_file(file string) bool {
	return file.starts_with(layer_dir) && !is_test_file(file) && !file.contains('/tests/')
		&& !file.contains('/slow_tests/') && !file.contains('/compiler_tests/')
		&& !file.contains('/testdata/')
}

// layer_graph is `project` with the vlib of `base`, the V tree's graph, under it, so
// that a traversal from the project carries on into vlib (FUTURE_WORK.md §11). The
// project's library ids are the V tree's own, so nothing is renamed. Under the
// project's symbols are each of base's declared in a vlib file (not a test) whose id
// the project doesn't have, and base's edges from those symbols, as base's own index
// resolved them. They aren't copied: the layered graph's index is over the project
// only and falls through to base's (Index.under), which base keeps for every graph
// layered on it, so a layer costs what the project does. The modules from VMODULES
// the project's graph keeps whole (keep_reached_library) join the project's symbols,
// after its own, so a traversal goes on into vglyph as into vlib. The library section
// keeps a vlib id base doesn't have. `base` must not be changed while the layered
// graph is used: the layer shares its symbols, edges and index.
pub fn layer_graph(project Graph, base Graph) Graph {
	// a copy of base's header, which shares base's arrays, maps and kept index
	mut under := &Graph{
		...base
	}
	under.cache_index()
	if isnil(under.index_cache.layer) {
		layer := under.layer()
		unsafe {
			under.index_cache.layer = &layer
		}
	}
	uidx := under.index_cache
	mut own := map[string]bool{}
	for s in project.symbols {
		own[s.id] = true
	}
	// a base id the layer has: one with a vlib copy, which the project doesn't shadow
	layered := fn [uidx, own] (id string) bool {
		return id !in own && uidx.layer_has(id)
	}
	mut out := Graph{
		root:        project.root
		roots:       project.roots.clone()
		symbols:     project.symbols.clone()
		file_hashes: project.file_hashes.clone()
	}
	out.library.roots = project.library.roots.clone()
	mut modules := map[string]bool{}
	for s in project.library.symbols {
		if s.id in own || layered(s.id) {
			continue
		}
		if s.file.starts_with(lib_vmodules_prefix) {
			out.symbols << s
			modules[s.id] = true
		} else {
			out.library.symbols << s
		}
	}
	mut lib_ids := map[string]bool{}
	for s in out.library.symbols {
		lib_ids[s.id] = true
	}
	// a module's edge that names no declaration is left out: the index would link a raw
	// name to the project's declaration of it, which the module can't call
	for e in project.edges {
		if e.from in modules && e.to !in own && !layered(e.to) && e.to !in modules
			&& e.to !in lib_ids {
			continue
		}
		out.edges << e
	}
	out.base = Base{
		root:  base.root
		under: under
		own:   project.symbols.len
		mods:  modules
	}
	return out
}

// Layer is what a graph layered on this one takes from it (layer_graph), worked out
// once for all of them where its index can't tell it at a glance. An id is layered
// when a copy of it is declared in a layered_file; the index shows each id from one
// copy, the one shown_before prefers among all of them, and lists a name's ids in
// the order their first copies come in.
pub struct Layer {
pub:
	// ids whose copy shown isn't in a layered_file, though another is: the one of
	// those shown_before prefers, which the layer shows
	shown map[string]Symbol
	// the names one of whose ids has its first copy outside the layered files: the
	// name's layered ids in the order of their first layered copies
	named map[string][]string
	// where in the graph's symbols each declared in a layered_file is
	at []int
	// the ids layered: one for each base graph, shared by all layered on it
	ids map[string]bool
}

// layer works out the Layer of a graph indexed with cache_index.
fn (g Graph) layer() Layer {
	idx := g.index_cache
	mut first_layered := map[string]bool{}
	mut seen := map[string]bool{}
	mut late := map[string]bool{}
	mut shown := map[string]Symbol{}
	mut at := []int{}
	for i, s in g.symbols {
		lay := layered_file(s.file)
		if s.id !in first_layered {
			first_layered[s.id] = lay
		}
		if !lay {
			continue
		}
		at << i
		if s.id !in seen {
			seen[s.id] = true
			if !first_layered[s.id] {
				late[s.name] = true
			}
		}
		if !layered_file(idx.by_id[s.id].file) {
			if cur := shown[s.id] {
				if shown_before(s, cur) {
					shown[s.id] = s
				}
			} else {
				shown[s.id] = s
			}
		}
	}
	mut named := map[string][]string{}
	if late.len > 0 {
		mut listed := map[string]bool{}
		for i in at {
			s := g.symbols[i]
			if s.name in late && s.id !in listed {
				listed[s.id] = true
				named[s.name] << s.id
			}
		}
	}
	return Layer{
		shown: shown
		named: named
		at:    at
		ids:   seen
	}
}

// project_for is the graph.json of the project graph in `projects_dir` whose root
// holds `dir`, the deepest such root, so that a worktree inside a project finds the
// project's graph; none when no root holds it, or only `base_root`'s does, whose
// graph is the base itself. Each graph is found by its manifest's root, in a
// directory of its own, as `extract --store` writes it.
pub fn project_for(projects_dir string, dir string, base_root string) ?string {
	if projects_dir == '' || dir == '' {
		return none
	}
	here := os.real_path(dir)
	base := if base_root == '' { '' } else { os.real_path(base_root) }
	mut best := ''
	mut best_root := ''
	for name in os.ls(projects_dir) or { return none } {
		graph := os.join_path(projects_dir, name, 'graph.json')
		m := load_manifest(os.join_path(projects_dir, name, 'manifest.json')) or { continue }
		if m.root == '' || !os.exists(graph) {
			continue
		}
		root := os.real_path(m.root)
		if root == base || !path_holds(root, here) {
			continue
		}
		if root.len > best_root.len {
			best = graph
			best_root = root
		}
	}
	return if best == '' { none } else { best }
}

// base_for is the graph.json in `projects_dir` of the V tree whose vlib the project
// graph at `project_graph` read, as its manifest names it, for the project to be
// layered on (layer_graph); none when the project read no vlib, or is that V tree's
// own graph, or no graph in `projects_dir` is rooted at it.
pub fn base_for(projects_dir string, project_graph string) ?string {
	pm := load_manifest(os.join_path(os.dir(project_graph), 'manifest.json')) or { return none }
	mut vlib := ''
	for l in pm.library {
		if l.label == 'vlib' && l.root != '' {
			vlib = os.real_path(l.root)
		}
	}
	if vlib == '' || (pm.root != '' && os.real_path(pm.root) == vlib) {
		return none
	}
	for name in os.ls(projects_dir) or { return none } {
		graph := os.join_path(projects_dir, name, 'graph.json')
		m := load_manifest(os.join_path(projects_dir, name, 'manifest.json')) or { continue }
		if m.root != '' && os.exists(graph) && os.real_path(m.root) == vlib {
			return graph
		}
	}
	return none
}

// path_holds reports whether `path` is `root` or a path inside it.
fn path_holds(root string, path string) bool {
	if path == root {
		return true
	}
	sep := os.path_separator
	prefix := if root.ends_with(sep) { root } else { root + sep }
	return path.starts_with(prefix)
}

// layer_note says when the project graph at `project_graph` read its vlib from
// another checkout, or at another commit, than the one the base graph at
// `base_graph` was extracted from, so that a layered vlib declaration's line or id
// may not be the one the project's edges meant; '' when they agree or a manifest
// doesn't say.
pub fn layer_note(project_graph string, base_graph string) string {
	pm := load_manifest(os.join_path(os.dir(project_graph), 'manifest.json')) or { return '' }
	bm := load_manifest(os.join_path(os.dir(base_graph), 'manifest.json')) or { return '' }
	for l in pm.library {
		if l.label != 'vlib' || l.root == '' || bm.root == '' {
			continue
		}
		if os.real_path(l.root) != os.real_path(bm.root) {
			return 'the project read vlib from ${l.root}, but the vlib layered under it is the graph of ${bm.root}, so a vlib declaration may differ from the one the project calls'
		}
		if l.commit != '' && bm.source_commit != '' && l.commit != bm.source_commit {
			return 'the project read vlib at ${short_commit(l.commit)}, but the vlib layered under it was extracted at ${short_commit(bm.source_commit)}, so a vlib declaration may differ from the one the project calls; re-extract the one that is behind'
		}
	}
	return ''
}
