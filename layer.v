module graphify

import os

// the directory of the V tree's files a project's graph is layered on: what a
// project calls (FUTURE_WORK.md §11)
const layer_dir = 'vlib/'

// layered_file reports whether a file of the V tree goes under a project: one in
// vlib, other than its tests, which no project calls.
fn layered_file(file string) bool {
	// `os_test.v`, and a platform's `wayland_test.c.v`
	is_test := os.file_name(file).all_before('.').ends_with('_test')
	return file.starts_with(layer_dir) && !is_test && !file.contains('/tests/') && !file.contains('/slow_tests/')
		&& !file.contains('/compiler_tests/') && !file.contains('/testdata/')
}

// layer_graph is `project` with the vlib of `base`, the V tree's graph, under it, so
// that a traversal from the project carries on into vlib (FUTURE_WORK.md §11). The
// project's library ids are the V tree's own, so nothing is renamed. Its symbols come
// first, then each of base's declared in a vlib file (not a test) whose id the project doesn't
// have; its edges, then base's from those symbols, as base's own index resolved
// them. The project's library section keeps what base doesn't stand in for: modules
// from VMODULES, and a vlib id base doesn't have.
pub fn layer_graph(project Graph, base Graph) Graph {
	mut own := map[string]bool{}
	for s in project.symbols {
		own[s.id] = true
	}
	mut out := Graph{
		root:        project.root
		roots:       project.roots.clone()
		symbols:     project.symbols.clone()
		edges:       project.edges.clone()
		file_hashes: project.file_hashes.clone()
	}
	mut ids := map[string]bool{}
	mut hashes := map[string]string{}
	for s in base.symbols {
		if layered_file(s.file) && s.id !in own {
			out.symbols << s
			ids[s.id] = true
			if h := base.file_hashes[s.file] {
				hashes[s.file] = h
			}
		}
	}
	// resolved by base's index: a raw name of base's is resolved among base's own
	// declarations, never the project's
	for e in base.index().edges {
		if e.from in ids {
			out.edges << e
		}
	}
	out.library.roots = project.library.roots.clone()
	for s in project.library.symbols {
		if s.id !in ids && s.id !in own {
			out.library.symbols << s
		}
	}
	out.base = Base{
		root:        base.root
		ids:         ids
		file_hashes: hashes
	}
	return out
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
