module graphify

import os

struct WorkItem {
	path string
	rel  string
}

// build_graph_resilient builds a graph by parsing files in *worker processes*,
// so a file that makes V's parser panic is skipped and reported instead of
// aborting the whole run. Files are parsed in batches (fast); only when a batch
// worker crashes is the offending file isolated and the rest of the batch
// resumed. Returns the graph and the list of files that failed to parse.
pub fn build_graph_resilient(root string, worker_exe string) (Graph, []string) {
	abs_root := os.real_path(root)
	mut g := Graph{
		root: abs_root
	}
	mut failed := []string{}

	files := if os.is_dir(abs_root) {
		find_source_files(abs_root, ['v'])
	} else {
		[SourceFile{
			path: abs_root
			lang: 'v'
		}]
	}
	mut queue := []WorkItem{}
	for f in files {
		queue << WorkItem{
			path: f.path
			rel:  rel_path(abs_root, f.path)
		}
	}

	batch_size := 200
	listfile := os.join_path(os.temp_dir(), 'gf_list_${os.getpid()}.txt')
	outfile := os.join_path(os.temp_dir(), 'gf_out_${os.getpid()}.ndjson')

	for queue.len > 0 {
		n := if queue.len < batch_size { queue.len } else { batch_size }
		batch := queue#[..n].clone()
		mut lines := []string{}
		for w in batch {
			lines << '${w.path}\t${w.rel}'
		}
		os.write_file(listfile, lines.join('\n')) or {
			for w in batch {
				failed << w.rel
			}
			queue = queue#[n..].clone()
			continue
		}
		os.rm(outfile) or {}
		os.execute('"${worker_exe}" _parse-batch "${listfile}" "${outfile}"')

		// each completed file wrote one NDJSON line of its FileResult
		results := os.read_lines(outfile) or { []string{} }
		for line in results {
			if line.trim_space() == '' {
				continue
			}
			fr := decode_file_result(line)
			g.symbols << fr.symbols
			g.edges << fr.edges
		}
		completed := results.len
		if completed >= n {
			queue = queue#[n..].clone()
		} else {
			// the file at index `completed` crashed the worker — skip it and
			// resume with the rest of the batch followed by the remaining queue.
			failed << batch[completed].rel
			mut rest := []WorkItem{}
			for i := completed + 1; i < n; i++ {
				rest << batch[i]
			}
			rest << queue#[n..]
			queue = rest.clone()
		}
	}
	os.rm(listfile) or {}
	os.rm(outfile) or {}

	resolve_edges(mut g)
	return g, failed
}

// Options controls a graph build.
pub struct Options {
pub:
	root       string // directory (or single file) to analyze
	languages  []string = ['v'] // language ids to include; [] = all supported
	with_calls bool     = true  // record call edges between functions
}

// build_graph walks `opts.root`, parses every supported file with the right
// backend, and returns the assembled Graph.
pub fn build_graph(opts Options) Graph {
	root := os.real_path(opts.root)
	mut g := Graph{
		root: root
	}

	files := if os.is_dir(root) {
		find_source_files(root, opts.languages)
	} else {
		[
			SourceFile{
				path: root
				lang: lang_by_ext[os.file_ext(root)] or { '' }
			},
		]
	}

	for f in files {
		rel := rel_path(root, f.path)
		syms, edges := match f.lang {
			'v' { extract_v_file(f.path, rel) }
			else { extract_ts_file(f.path, rel, f.lang) }
		}

		g.symbols << syms
		if opts.with_calls {
			g.edges << edges
		} else {
			for e in edges {
				if e.kind != .calls {
					g.edges << e
				}
			}
		}
	}

	resolve_edges(mut g)
	return g
}

// resolve_edges turns raw callee names on `calls` edges into symbol ids when a
// matching symbol exists in the graph. Unresolved names are left as-is so the
// caller can still see external/unknown calls.
fn resolve_edges(mut g Graph) {
	mut by_name := map[string][]string{}
	for s in g.symbols {
		if s.kind == .function || s.kind == .method {
			by_name[s.name] << s.id
		}
	}
	mut resolved := []Edge{cap: g.edges.len}
	for e in g.edges {
		if e.kind == .calls {
			ids := by_name[e.to] or { []string{} }
			if ids.len == 1 {
				resolved << Edge{
					from: e.from
					to:   ids[0]
					kind: .calls
				}
				continue
			}
		}
		resolved << e
	}
	g.edges = resolved
}

fn rel_path(root string, path string) string {
	if path == root {
		// single-file run: use the bare file name as the header
		return os.base(path)
	}
	rel := if path.starts_with(root) { path[root.len..].trim_left('\\/') } else { path }
	// store with forward slashes so the graph resolves on any OS
	return rel.replace('\\', '/')
}
