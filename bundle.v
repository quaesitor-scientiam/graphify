module graphify

import os
import time
import x.json2

// default output directory, matching Python Graphify's `graphify-out/`.
pub const out_dir_name = 'graphify-out'

// Manifest is manifest.json's shape — enough to tell a clean graph from a
// degraded one without opening graph.json itself: which extractor binary
// produced it (matches the incremental cache's own binary-hash gate), which
// source commit it was extracted from (best-effort; '' outside a git repo or
// if git isn't available), and which files fell short of a fresh, successful
// parse this run. `pub` (struct and fields) so `load_manifest` can decode one
// from outside this module, e.g. `graphify diff`'s comparison of two runs.
pub struct Manifest {
pub:
	tool          string
	version       string
	root          string
	source_commit string
	binary_hash   string
	generated     string
	files         int
	symbols       int
	edges         int
	failed        []string
	stale         []string
	partial       []string
}

// load_manifest reads a manifest.json previously written by write_bundle.
pub fn load_manifest(path string) !Manifest {
	content := os.read_file(path)!
	return json2.decode[Manifest](content)!
}

// git_commit_of best-effort resolves `root`'s current commit hash, or ''
// when `root` isn't inside a git repository, git isn't on PATH, or the
// command otherwise fails — a missing commit is recorded as absent, never
// treated as an error that should stop an extract from publishing.
fn git_commit_of(root string) string {
	result := os.exec(['git', '-C', root, 'rev-parse', 'HEAD'])
	if result.exit_code != 0 {
		return ''
	}
	return result.output.trim_space()
}

// write_bundle writes the Graphify-style output bundle into `out_dir`:
//   graph.json        persistent, queryable graph
//   GRAPH_REPORT.md   plain-language summary + suggested queries
//   manifest.json     metadata + counts
pub fn write_bundle(g Graph, out_dir string, report ExtractReport) ! {
	os.mkdir_all(out_dir)!
	save_graph(g, os.join_path(out_dir, 'graph.json'))!
	os.write_file(os.join_path(out_dir, 'GRAPH_REPORT.md'), g.report())!
	os.write_file(os.join_path(out_dir, 'manifest.json'), g.manifest_json(report))!
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
	for e in g.edges {
		edge_kinds[edge_kind_str(e.kind)]++
	}
	calls_prov := count_provenance(idx, g.edges, .calls)
	refs_prov := count_provenance(idx, g.edges, .references)
	embeds_prov := count_provenance(idx, g.edges, .embeds)

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
	b << '## Edges by provenance'
	b << '`extracted` = unique name or (calls only) a parser-typed receiver; `inferred` = picked among several real candidates by locality/visibility; `built-in` = a primitive type such as `int`, which has no declaration to resolve to; `unresolved` = name stayed ambiguous or unknown.'
	b << '- calls: ${calls_prov.str()}'
	b << '- references: ${refs_prov.str()}'
	b << '- embeds: ${embeds_prov.str()}'
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
pub fn (g Graph) manifest_json(report ExtractReport) string {
	mut files := map[string]bool{}
	for s in g.symbols {
		files[s.file] = true
	}
	m := Manifest{
		tool:          'graphify'
		version:       '0.0.1'
		root:          g.root
		source_commit: git_commit_of(g.root)
		binary_hash:   report.binary_hash
		generated:     time.now().format_ss()
		files:         files.len
		symbols:       g.symbols.len
		edges:         g.edges.len
		failed:        report.failed
		stale:         report.stale
		partial:       report.partial
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

struct ProvCounts {
mut:
	extracted  int
	inferred   int
	builtin    int // a primitive type name, see builtin_type_names
	unresolved int
}

fn (c ProvCounts) str() string {
	builtin := if c.builtin > 0 { ', built-in ${c.builtin}' } else { '' }
	return 'extracted ${c.extracted}, inferred ${c.inferred}${builtin}, unresolved ${c.unresolved}'
}

// builtin_type_names are V's primitive types. Unlike `string`, `array` and
// `map`, which vlib/builtin declares as structs, they have no declaration,
// so a reference to one can never resolve; on the V compiler's own tree they
// were 35,072 of 36,625 unresolved references, hiding the ones worth a look.
const builtin_type_names = ['bool', 'i8', 'i16', 'int', 'i32', 'i64', 'u8', 'byte', 'u16', 'u32',
	'u64', 'usize', 'isize', 'f32', 'f64', 'rune', 'char', 'voidptr', 'byteptr', 'charptr',
	'void', 'any', 'none', 'nil', 'thread', 'chan', 'int_literal', 'float_literal']

// count_provenance buckets every edge of `kind` by how (and whether) its `to`
// was resolved. provenance only means something once `to` is a real symbol
// id — an edge resolve_edges never pinned down keeps the zero-value
// `extracted` it was never actually given, so resolution is checked first or
// an unresolved edge would read as unearned confidence.
fn count_provenance(idx Index, edges []Edge, kind EdgeKind) ProvCounts {
	mut c := ProvCounts{}
	for e in edges {
		if e.kind != kind {
			continue
		}
		if e.to !in idx.by_id {
			if e.kind != .calls && e.to in builtin_type_names {
				c.builtin++
			} else {
				c.unresolved++
			}
		} else if e.provenance == .inferred {
			c.inferred++
		} else {
			c.extracted++
		}
	}
	return c
}
