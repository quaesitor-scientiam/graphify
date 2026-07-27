module main

// Token A/B benchmark: does consulting the graph cost fewer tokens than reading
// source? Models two realistic task types on a real codebase and reports the
// ratios with explicit assumptions. Token count is estimated as chars/4 (a
// common rough proxy for code; stated as an estimate, not exact).
//
//   v run cmd/bench <path-to-codebase>
import os
import graphify

fn est(s string) int {
	return (s.len + 3) / 4
}

fn median(values []f64) f64 {
	if values.len == 0 {
		return 0
	}
	mut v := values.clone()
	v.sort()
	mid := v.len / 2
	return if v.len % 2 == 1 { v[mid] } else { (v[mid - 1] + v[mid]) / 2 }
}

fn main() {
	path := if os.args.len > 1 { os.args[1] } else { '.' }
	g := graphify.build_graph(graphify.Options{ root: path })
	root := os.real_path(path)

	// read each file's source once
	mut file_src := map[string]string{}
	mut files := []string{}
	for s in g.symbols {
		if s.file in file_src {
			continue
		}
		content := os.read_file(os.join_path(root, s.file)) or { continue }
		file_src[s.file] = content
		files << s.file
	}

	mut total_src := 0
	for f in files {
		total_src += est(file_src[f])
	}
	skeleton := est(g.emit_skeleton())

	// Task B: understand one symbol in context. File-mode reads the whole
	// containing file; graph-mode reads explain(symbol) + only that symbol's
	// body (approximated as the source between its start line and the next
	// symbol's start line in the same file).
	mut by_file := map[string][]graphify.Symbol{}
	for s in g.symbols {
		if s.kind == .mod_ || s.kind == .import_ {
			continue
		}
		by_file[s.file] << s
	}

	mut ratios := []f64{}
	mut sampled := 0
	for f, syms in by_file {
		lines := file_src[f] or { continue }.split('\n')
		mut ordered := syms.clone()
		ordered.sort(a.line < b.line)
		for i, s in ordered {
			start := if s.line > 0 { s.line - 1 } else { 0 }
			end := if i + 1 < ordered.len { ordered[i + 1].line - 1 } else { lines.len }
			if start >= lines.len || end <= start {
				continue
			}
			body := lines[start..end].join('\n')
			// per-symbol, per-task: each is one independent task, NOT summed
			// (summing would count a shared file once per symbol — misleading).
			file_mode := est(file_src[f]) // baseline: read the whole containing file
			graph_mode := est(g.explain(s.name)) + est(body) // explain + that body only
			if graph_mode > 0 {
				ratios << f64(file_mode) / f64(graph_mode)
			}
			sampled++
			if sampled >= 300 {
				break
			}
		}
		if sampled >= 300 {
			break
		}
	}
	mut mean := 0.0
	for r in ratios {
		mean += r
	}
	mean = if ratios.len > 0 { mean / ratios.len } else { 0 }

	println('=== graphify token A/B benchmark ===')
	println('corpus            : ${root}')
	println('files / symbols   : ${files.len} / ${g.symbols.len}')
	println('token estimate    : chars / 4')
	println('')
	println('-- Task A: map the whole codebase (full source vs skeleton) --')
	println('full source tokens: ${total_src}')
	println('skeleton tokens   : ${skeleton}')
	println('reduction         : ${ratio_str(total_src, skeleton)} (${pct(total_src, skeleton)}% fewer)')
	println('')
	println('-- Task B: understand ONE symbol, per independent task (n=${sampled}) --')
	println('  file-mode baseline = read the whole containing file')
	println("  graph-mode         = explain(symbol) + that symbol's body only")
	println('per-task reduction: median ${median(ratios):.2}x, mean ${mean:.2}x')
	println('')
	println('CAVEAT: Task B assumes the file-mode baseline reads the ENTIRE file to')
	println('understand one symbol. That inflates savings for large/symbol-dense')
	println('files (you would not re-read a 1600-line file per symbol). If Claude')
	println('instead does a targeted read after a grep, graph-mode saves mainly the')
	println('search, not the body. Treat Task A (read-everything-once vs skeleton-')
	println('once) as the credible, apples-to-apples number; Task B is an upper')
	println('bound for the "would have loaded the whole file" case.')
}

fn ratio_str(a int, b int) string {
	if b == 0 {
		return 'n/a'
	}
	return '${f64(a) / f64(b):.2}x'
}

fn pct(a int, b int) int {
	if a == 0 {
		return 0
	}
	return int(100.0 - 100.0 * f64(b) / f64(a))
}
