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
// get_body works against the merged result via `out.roots`: every symbol id
// carries its source's label chain as a `label::` prefix, and `roots` maps
// that exact chain back to the label's own original absolute root, so
// get_body can pick the right root per symbol instead of needing one root
// for the whole graph. If `g` (an input) is itself already a merge -- its
// own `roots` is non-empty -- its entries are re-prefixed with this merge's
// label rather than collapsed to `g.root` (which for an already-merged graph
// is only the cosmetic `" + "`-joined display string, not a real path), so
// nested merges resolve correctly too.
pub fn merge_graphs(graphs []Graph, labels []string) Graph {
	resolved := dedup_labels(graphs, labels)
	mut out := Graph{
		root:  resolved.join(' + ') // display only -- real roots live in `roots`
		roots: map[string]string{}
	}
	for i, g in graphs {
		ns := resolved[i] + '::'
		if g.roots.len > 0 {
			for inner_label, inner_root in g.roots {
				out.roots['${resolved[i]}::${inner_label}'] = inner_root
			}
		} else {
			out.roots[resolved[i]] = g.root
		}
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
