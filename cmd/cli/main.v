module main

import os
import graphify

const usage = 'graphify - build a queryable code graph to cut AI token usage

usage:
  graphify extract <path> [--out D]  build the graph (default ./graphify-out/)
  graphify overview                  compact summary: counts + most-connected symbols
  graphify query   <text> [opts]     traverse from matching symbols (token-bounded)
  graphify path    <A> <B>           shortest path between two symbols
  graphify explain <symbol>          summarize a symbol and its relationships
  graphify body    <symbol>          print only that declaration body
  graphify skeleton <path>           print a body-less skeleton of <path>

query options:
  --budget <n>   token budget for the result (default 2000)
  --dfs          walk depth-first instead of breadth-first

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
fn cmd_parse_batch(args []string) {
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

fn positional(args []string, n int) ?string {
	mut count := 0
	for i := 0; i < args.len; i++ {
		a := args[i]
		if a.starts_with('--') {
			if a in ['--budget', '--graph', '--source-dir', '--out', '--store'] {
				i++ // skip the flag's value
			}
			continue
		}
		if count == n {
			return a
		}
		count++
	}
	return none
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

@[noreturn]
fn fail(msg string) {
	eprintln(msg)
	exit(1)
}
