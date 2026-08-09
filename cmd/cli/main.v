module main

import os
import graphify

const usage = 'graphify - build a queryable code graph to cut AI token usage

usage:
  graphify extract <path> [--out D]        build the graph (default ./graphify-out/)
  graphify overview                        compact summary: counts + most-connected symbols
  graphify query   <text> [opts]           traverse from matching symbols (token-bounded)
  graphify path    <A> <B>                 shortest path between two symbols
  graphify explain <symbol>                summarize a symbol and its relationships
  graphify body    <symbol>                print only that declaration body
  graphify skeleton <path>                 print a body-less skeleton of <path>
  graphify merge-graphs <a.json> <b.json> [more.json...] [--out F] [--labels a,b,...]
                                            combine graphs into one, namespaced by label
  graphify communities [--resolution N] [--restarts N]
                                            split the graph into subsystems (Leiden-style)
  graphify export <graphml|cypher|svg|html> [--out F]
                                            write the graph in that format

query options:
  --budget <n>   token budget for the result (default 2000)
  --dfs          walk depth-first instead of breadth-first

merge-graphs options:
  --out <file>     output path (default ./merged-graph.json)
  --labels <list>  comma-separated namespace label per input graph, in order;
                   defaults to each graph\'s own root directory name

communities options:
  --resolution <n>  > 1 favors more, smaller communities; < 1 favors fewer,
                     larger ones (default 1.0)
  --restarts <n>    randomized attempts, keeping the best result -- higher is
                     slower but more reliable (default 20)

export options:
  --out <file>  output path (default ./graph.<format>)

common options:
  --graph <file>   graph.json to read (default ./graphify-out/graph.json)
'

fn main() {
	args := os.args[1..]
	if args.len == 0 || args[0] in ['-h', '--help'] {
		println(usage)
		return
	}
	cmd := args[0]
	rest := args[1..]
	match cmd {
		'extract' {
			cmd_extract(rest)
		}
		'query' {
			cmd_query(rest)
		}
		'path' {
			cmd_path(rest)
		}
		'overview' {
			cmd_overview(rest)
		}
		'explain' {
			cmd_explain(rest)
		}
		'body' {
			cmd_body(rest)
		}
		'skeleton' {
			cmd_skeleton(rest)
		}
		'merge-graphs' {
			cmd_merge(rest)
		}
		'communities' {
			cmd_communities(rest)
		}
		'export' {
			cmd_export(rest)
		}
		'_parse-batch' {
			cmd_parse_batch(rest)
		}
		else {
			eprintln('unknown command: ' + cmd)
			fail(usage)
		}
	}
}

fn cmd_extract(args []string) {
	path := positional(args, 0) or { '.' }
	out := resolve_out(args, path)
	// parse each file in its own worker process, so one file that panics V's
	// parser is skipped (and reported) rather than aborting the whole extract.
	// Files unchanged since the last extract to `out` are reused from its
	// cache instead of being reparsed.
	g, failed := graphify.build_graph_resilient(path, os.executable(), out)
	graphify.write_bundle(g, out) or { fail('write failed: ${err}') }
	println('extracted ${g.symbols.len} symbols, ${g.edges.len} edges')
	if failed.len > 0 {
		shown := if failed.len > 8 { failed#[..8] } else { failed }
		mut msg := 'skipped ${failed.len} unparseable file(s): ' + shown.join(', ')
		if failed.len > 8 {
			msg += ' …'
		}
		println(msg)
	}
	println('wrote ${out}/graph.json, GRAPH_REPORT.md, manifest.json')
}

// cmd_parse_batch is the hidden worker: parse each `path<TAB>rel` line from
// <listfile>, writing one NDJSON FileResult per file to <outfile> and flushing
// after each. If V's parser panics mid-batch, this process dies but the lines
// already flushed survive, so the parent knows exactly which file crashed.
fn C.freopen(&char, &char, &C.FILE) &C.FILE

// silence_stderr points this process's stderr at the null device.
//
// Batch workers are spawned concurrently and inherit the parent's console, so
// V's parser complaining about a script-mode file — or panicking outright on
// one, which is expected and recovered from — floods the extract log with
// pages of noise on every run. The parent detects a crashed worker from how
// many lines reached <outfile>, never from stderr, so nothing is lost.
//
// Done here rather than by redirecting the child's pipes from the parent: with
// nr_cpus() workers running at once, unread pipes fill and the child blocks on
// write, which would hang the whole extract instead of merely being noisy.
fn silence_stderr() {
	unsafe {
		C.freopen(&char(os.path_devnull.str), c'w', C.stderr)
	}
}

fn cmd_parse_batch(args []string) {
	silence_stderr()
	if args.len < 2 {
		exit(1)
	}
	lines := os.read_lines(args[0]) or { exit(1) }
	mut f := os.create(args[1]) or { exit(1) }
	for line in lines {
		parts := line.split('\t')
		if parts.len < 2 {
			f.writeln('{}') or {} // keep index alignment for empty/odd lines
			f.flush()
			continue
		}
		syms, edges := graphify.extract_v_file(parts[0], parts[1])
		f.writeln(graphify.encode_file_result(graphify.FileResult{ symbols: syms, edges: edges })) or {}
		f.flush()
	}
	f.close()
}

fn cmd_query(args []string) {
	text := positional(args, 0) or { fail('query: needs a search text') }
	budget := int_flag(args, '--budget') or { 2000 }
	dfs := '--dfs' in args
	g := load(args)
	println(g.query(text, budget, dfs))
}

fn cmd_path(args []string) {
	a := positional(args, 0) or { fail('path: needs two symbols') }
	b := positional(args, 1) or { fail('path: needs two symbols') }
	g := load(args)
	ids := g.shortest_path(a, b)
	if ids.len == 0 {
		println('no path between "${a}" and "${b}"')
		return
	}
	println(g.names(ids).join(' -> '))
}

fn cmd_overview(args []string) {
	g := load(args)
	println(g.report())
}

fn cmd_explain(args []string) {
	node := positional(args, 0) or { fail('explain: needs a symbol') }
	g := load(args)
	println(g.explain(node))
}

fn cmd_body(args []string) {
	node := positional(args, 0) or { fail('body: needs a symbol') }
	g := load(args)
	println(g.get_body(node))
}

fn cmd_skeleton(args []string) {
	path := positional(args, 0) or { '.' }
	g := graphify.build_graph(graphify.Options{ root: path })
	println(g.emit_skeleton())
}

fn cmd_merge(args []string) {
	paths := positionals(args)
	if paths.len < 2 {
		fail('merge-graphs: needs at least two graph.json paths')
	}
	out := str_flag(args, '--out') or { 'merged-graph.json' }
	mut labels := []string{}
	if l := str_flag(args, '--labels') {
		labels = l.split(',')
	}
	mut graphs := []graphify.Graph{}
	for p in paths {
		graphs << graphify.load_graph(p) or { fail('cannot read ${p}: ${err}') }
	}
	merged := graphify.merge_graphs(graphs, labels)
	graphify.save_graph(merged, out) or { fail('write failed: ${err}') }
	println('merged ${graphs.len} graphs -> ${merged.symbols.len} symbols, ${merged.edges.len} edges')
	println('wrote ${out}')
}

fn cmd_communities(args []string) {
	resolution := f64_flag(args, '--resolution') or { 1.0 }
	restarts := int_flag(args, '--restarts') or { graphify.default_leiden_restarts }
	g := load(args)
	idx := g.index()
	result := g.communities(resolution: resolution, restarts: restarts)
	println('${result.len} communities (resolution ${resolution}, restarts ${restarts})')
	for c in result {
		shown := if c.members.len > 6 { c.members#[..6] } else { c.members }
		mut names := []string{cap: shown.len}
		for id in shown {
			s := idx.by_id[id] or { continue }
			names << s.name
		}
		more := if c.members.len > shown.len { ' (+${c.members.len - shown.len} more)' } else { '' }
		println('- ${c.label} (${c.members.len} members): ${names.join(', ')}${more}')
	}
}

fn cmd_export(args []string) {
	format := positional(args, 0) or { fail('export: needs a format (graphml, cypher, svg, html)') }
	g := load(args)
	mut content := ''
	mut default_out := ''
	match format {
		'graphml' {
			content = g.emit_graphml()
			default_out = 'graph.graphml'
		}
		'cypher' {
			content = g.emit_cypher()
			default_out = 'graph.cypher'
		}
		'svg' {
			content = g.emit_svg()
			default_out = 'graph.svg'
		}
		'html' {
			content = g.emit_graph_html()
			default_out = 'graph.html'
		}
		else {
			fail('export: unknown format "${format}" (want graphml, cypher, svg, or html)')
		}
	}
	out := str_flag(args, '--out') or { default_out }
	os.write_file(out, content) or { fail('write failed: ${err}') }
	println('wrote ${out}')
}

// store_dir returns the central graph store (--store flag or GRAPHIFY_STORE
// env), or '' if none is configured.
fn store_dir(args []string) string {
	return str_flag(args, '--store') or { os.getenv('GRAPHIFY_STORE') }
}

// resolve_out picks where `extract` writes: an explicit --out, else a
// per-project subdir under the central store (<store>/<project-name>/), else
// the default ./graphify-out/.
fn resolve_out(args []string, path string) string {
	if o := str_flag(args, '--out') {
		return o
	}
	store := store_dir(args)
	if store != '' {
		return os.join_path(store, os.base(os.real_path(path)))
	}
	return graphify.out_dir_name
}

// load reads the persisted graph (or rebuilds from cwd if it is missing).
// `--source-dir <dir>` overrides the root the graph was extracted from, so a
// graph shared from another machine/OS resolves `body` against a local checkout.
fn load(args []string) graphify.Graph {
	file := str_flag(args, '--graph') or {
		env := os.getenv('GRAPHIFY_GRAPH')
		store := store_dir(args)
		if env != '' {
			env
		} else if store != '' {
			// central store: <store>/<current-project>/graph.json
			os.join_path(store, os.base(os.getwd()), 'graph.json')
		} else {
			os.join_path(graphify.out_dir_name, 'graph.json')
		}
	}
	mut g := if os.exists(file) {
		graphify.load_graph(file) or { fail('cannot read ${file}: ${err}') }
	} else {
		eprintln('note: ${file} not found, building graph from "." (run `graphify extract` to persist)')
		graphify.build_graph(graphify.Options{ root: '.' })
	}
	if sd := str_flag(args, '--source-dir') {
		g.root = sd
	}
	return g
}

// --- tiny arg helpers ---

// positionals returns every arg that is not a recognized flag or that
// flag's value, in order.
fn positionals(args []string) []string {
	mut out := []string{}
	for i := 0; i < args.len; i++ {
		a := args[i]
		if a.starts_with('--') {
			if a in ['--budget', '--graph', '--source-dir', '--out', '--store', '--labels', '--resolution',
				'--restarts'] {
				i++ // skip the flag's value
			}
			continue
		}
		out << a
	}
	return out
}

fn positional(args []string, n int) ?string {
	all := positionals(args)
	return if n < all.len { all[n] } else { none }
}

fn str_flag(args []string, name string) ?string {
	for i, a in args {
		if a == name && i + 1 < args.len {
			return args[i + 1]
		}
	}
	return none
}

fn int_flag(args []string, name string) ?int {
	v := str_flag(args, name) or { return none }
	return v.int()
}

fn f64_flag(args []string, name string) ?f64 {
	v := str_flag(args, name) or { return none }
	return v.f64()
}

@[noreturn]
fn fail(msg string) {
	eprintln(msg)
	exit(1)
}
