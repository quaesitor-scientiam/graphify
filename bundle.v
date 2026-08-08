module graphify

import os
import time
import x.json2

// default output directory, matching Python Graphify's `graphify-out/`.
pub const out_dir_name = 'graphify-out'

struct Manifest {
	tool      string
	version   string
	root      string
	generated string
	files     int
	symbols   int
	edges     int
}

// write_bundle writes the Graphify-style output bundle into `out_dir`:
//   graph.json        persistent, queryable graph
//   GRAPH_REPORT.md   plain-language summary + suggested queries
//   manifest.json     metadata + counts
pub fn write_bundle(g Graph, out_dir string) ! {
	os.mkdir_all(out_dir)!
	save_graph(g, os.join_path(out_dir, 'graph.json'))!
	os.write_file(os.join_path(out_dir, 'GRAPH_REPORT.md'), g.report())!
	os.write_file(os.join_path(out_dir, 'manifest.json'), g.manifest_json())!
}

// report renders GRAPH_REPORT.md: counts, the most-connected nodes, and a few
// suggested queries to get a reader started.
pub fn (g Graph) report() string {
	idx := g.index()

	mut files := map[string]bool{}
	mut sym_kinds := map[string]int{}
	for s in g.symbols {
		files[s.file] = true
		sym_kinds[s.kind.str()]++
	}
	mut edge_kinds := map[string]int{}
	mut calls_extracted := 0
	mut calls_inferred := 0
	mut calls_unresolved := 0
	for e in g.edges {
		edge_kinds[edge_kind_str(e.kind)]++
		if e.kind == .calls {
			// provenance only means something once `to` is a real symbol id —
			// an edge resolve_callee never pinned down keeps the zero-value
			// `extracted` it was never actually given, so check resolution
			// first or an unresolved call reads as unearned confidence.
			if e.to !in idx.by_id {
				calls_unresolved++
			} else if e.provenance == .inferred {
				calls_inferred++
			} else {
				calls_extracted++
			}
		}
	}

	mut b := []string{}
	b << '# Graph report'
	b << ''
	b << '- root: `${g.root}`'
	b << '- files: ${files.len}'
	b << '- symbols: ${g.symbols.len}'
	b << '- edges: ${g.edges.len}'
	b << ''
	b << '## Symbols by kind'
	for k, n in sym_kinds {
		b << '- ${k}: ${n}'
	}
	b << ''
	b << '## Edges by kind'
	for k, n in edge_kinds {
		b << '- ${k}: ${n}'
	}
	b << ''
	b << '## Call edges by provenance'
	b << '- extracted (unique name or a parser-typed receiver): ${calls_extracted}'
	b << '- inferred (picked among several real candidates by locality/visibility): ${calls_inferred}'
	b << '- unresolved (name stayed ambiguous or unknown): ${calls_unresolved}'
	b << ''
	b << '## Most connected symbols'
	for entry in top_by_degree(idx, 10) {
		s := idx.by_id[entry.id] or { continue }
		b << '- `${s.name}` (${entry.degree} links) — ${s.loc()}'
	}
	b << ''
	b << '## Suggested queries'
	for entry in top_by_degree(idx, 3) {
		s := idx.by_id[entry.id] or { continue }
		b << '- `graphify explain "${s.name}"`'
	}
	b << '- `graphify query "<topic>" --budget 2000`'
	b << ''
	return b.join('\n')
}

// manifest_json renders manifest.json.
pub fn (g Graph) manifest_json() string {
	mut files := map[string]bool{}
	for s in g.symbols {
		files[s.file] = true
	}
	m := Manifest{
		tool:      'graphify'
		version:   '0.0.1'
		root:      g.root
		generated: time.now().format_ss()
		files:     files.len
		symbols:   g.symbols.len
		edges:     g.edges.len
	}
	return json2.encode(m, prettify: true)
}

struct Degree {
	id     string
	degree int
}

fn top_by_degree(idx Index, n int) []Degree {
	mut ds := []Degree{}
	for id, neighbors in idx.adj {
		ds << Degree{
			id:     id
			degree: neighbors.len
		}
	}
	ds.sort(a.degree > b.degree)
	return if ds.len > n { ds[..n] } else { ds }
}

fn edge_kind_str(k EdgeKind) string {
	return match k {
		.defines { 'defines' }
		.calls { 'calls' }
		.imports { 'imports' }
		.implements { 'implements' }
		.embeds { 'embeds' }
		.references { 'references' }
	}
}
