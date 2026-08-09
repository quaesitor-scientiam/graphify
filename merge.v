module graphify

import os

// merge_graphs combines multiple previously-extracted graphs into one,
// namespacing every id with its source's label so that two unrelated
// projects sharing a common module name -- `main` above all, the implicit
// module of every standalone V program -- can never collide. Namespacing is
// unconditional (every graph, including the first) and uniform (symbols and
// edges alike), so the result never depends on merge order, and a still-
// unresolved edge's raw callee/type name simply stays unresolved rather
// than risking an accidental match against another graph's real id: a real
// id is always module-qualified (it contains a `.`), a namespaced-but-still-
// bare raw name never collides with one because `Index.resolve`'s by-name
// fallback matches a symbol's own short `name`, never a synthesized
// `label::` string.
//
// `labels[i]` names graphs[i]; a '' or missing entry falls back to that
// graph's own root directory name, deduplicated against every other label
// (explicit or defaulted) by appending -2, -3, ... on repeat.
//
// This does not deduplicate genuinely overlapping content -- the same file
// extracted into two of the input graphs simply appears twice, once under
// each label, rather than being merged into one node. Reconciling that is
// future scope, not silently guessed at here.
//
// get_body does not work correctly against the merged result: `s.file` is
// relative to each *original* root, but a merged graph has no single root to
// resolve it against. --source-dir picks one root for the whole graph, so it
// can only ever serve bodies for whichever single input that happens to be.
// Every other query (query/explain/path/shortest_path/overview) only reads
// already-captured signature/doc/relationship data, never the source tree,
// so they are unaffected.
pub fn merge_graphs(graphs []Graph, labels []string) Graph {
	resolved := dedup_labels(graphs, labels)
	mut out := Graph{
		root: resolved.join(' + ') // display only -- see get_body note above
	}
	for i, g in graphs {
		ns := resolved[i] + '::'
		for s in g.symbols {
			mut ns_s := s
			ns_s.id = ns + s.id
			if s.parent != '' {
				ns_s.parent = ns + s.parent
			}
			out.symbols << ns_s
		}
		for e in g.edges {
			out.edges << Edge{
				from:       ns + e.from
				to:         ns + e.to
				kind:       e.kind
				provenance: e.provenance
			}
		}
	}
	return out
}

// dedup_labels resolves each graph's namespace label: an explicit
// labels[i], or that graph's root basename, with -2/-3/... appended on any
// repeat (explicit or defaulted) so two labels are never equal.
fn dedup_labels(graphs []Graph, labels []string) []string {
	mut seen := map[string]int{}
	mut out := []string{cap: graphs.len}
	for i, g in graphs {
		mut base := if i < labels.len && labels[i] != '' { labels[i] } else { default_label(g) }
		if base == '' {
			base = 'graph'
		}
		n := seen[base]
		seen[base] = n + 1
		out << if n == 0 { base } else { '${base}-${n + 1}' }
	}
	return out
}

// default_label derives a namespace label from a graph's own root path, so
// an unlabeled merge is still readable (`myservice::main.run`) rather than
// an opaque index.
fn default_label(g Graph) string {
	if g.root == '' {
		return ''
	}
	return os.base(g.root.trim_right('\\/'))
}
