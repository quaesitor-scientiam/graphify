#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// graphify Claude Code hook, compiled to a native binary (see README /
// .claude/settings.json) rather than run via `v run` — a hook fires on
// every SessionStart and every Grep/Glob/Read, and `v run` recompiling
// from source each time costs seconds per call (measured), which a
// prebuilt binary avoids (measured ~35ms).
//
// Handles SessionStart (inject standing guidance) and PreToolUse on
// Read/Grep/Glob (steer Claude to the graph when it can answer). Reads the
// hook JSON from stdin, emits hookSpecificOutput.additionalContext. Always
// non-blocking (exits 0 either way).
//
// The PreToolUse reminder only fires when the operation targets V source
// the graph actually indexes: for Read it checks the file against the
// graph's node set, so it stays silent on markdown/JSON/other-language
// files AND on branch-only or newly added .v files the (master) graph
// does not yet cover.

import os
import json2
import graphify

const session_start_context = 'GRAPHIFY GRAPH AVAILABLE. Required workflow for tasks that involve navigating or understanding V code: (1) Start with overview or query_graph to orient — do NOT open files first. (2) Use get_node to inspect a symbol and its relationships with file:line. (3) Use get_body to read ONE declaration by name — do NOT read the whole file. (4) Only use Read/Grep/Bash for things the graph cannot answer (running tests, editing files, reading non-V source, or files not yet indexed). Every result includes file:line so you can always drill in precisely. EXCEPTION: for docs-only or file-creation tasks that do not require understanding V code, the graph is optional — a directory listing plus memory is a fine first move.'

const pretooluse_context = 'STOP: graphify graph available. Use query_graph/get_node/get_body instead of scanning files. get_body fetches one declaration by name; get_node shows all relationships with file:line. Only proceed with this file operation if the graph cannot answer the question.'

fn emit(event_name string, context string) string {
	mut inner := map[string]json2.Any{}
	inner['hookEventName'] = json2.Any(event_name)
	inner['additionalContext'] = json2.Any(context)
	mut outer := map[string]json2.Any{}
	outer['hookSpecificOutput'] = json2.Any(inner)
	return json2.encode(json2.Any(outer))
}

fn to_rel(p string, root string) string {
	if p == '' {
		return ''
	}
	a := p.replace('\\', '/')
	r := root.replace('\\', '/').trim_right('/')
	if r != '' && a.to_lower().starts_with(r.to_lower() + '/') {
		return a[r.len + 1..]
	}
	if a.starts_with('./') {
		return a[2..]
	}
	return a
}

// graph_file_set returns the lowercased set of repo-relative file paths
// that have nodes in the graph, cached in a sidecar next to graph.json and
// rebuilt only when graph.json changes.
fn graph_file_set(graph_path string) ?map[string]bool {
	cache_path := graph_path + '.files'
	graph_mtime := os.file_last_mod_unix(graph_path)
	fresh := os.exists(cache_path) && os.file_last_mod_unix(cache_path) >= graph_mtime

	mut set := map[string]bool{}
	if fresh {
		lines := os.read_lines(cache_path) or { return none }
		for line in lines {
			if line != '' {
				set[line] = true
			}
		}
		return set
	}

	g := graphify.load_graph(graph_path) or { return none }
	mut out_lines := []string{cap: g.symbols.len}
	for s in g.symbols {
		lower := s.file.to_lower()
		if lower !in set {
			set[lower] = true
			out_lines << lower
		}
	}
	os.write_file(cache_path, out_lines.join('\n')) or {}
	return set
}

fn main() {
	raw := os.get_raw_lines_joined()
	// json2.decode PANICS (not a catchable error, and V has no general
	// panic recovery) on some malformed input instead of returning a
	// decode error — confirmed empirically for whitespace-only input
	// ("\r\n") and for JSON truncated mid-object. A hook must never
	// crash, so the realistically reachable case (invoked with no
	// meaningful stdin at all, e.g. before Claude Code has written
	// anything) is checked before decode is ever called. Truncated/
	// otherwise-malformed-but-non-empty JSON is not guarded against:
	// Claude Code always writes one complete, already-serialized JSON
	// object, never a partial/streamed one, so that shape isn't a
	// realistic failure mode here the way empty stdin is.
	if raw.trim_space() == '' {
		println('{}')
		return
	}
	decoded := json2.decode[json2.Any](raw) or {
		println('{}')
		return
	}
	data := decoded.as_map()

	evt := (data['hook_event_name'] or { json2.Any('') }).str()
	env_proj := os.getenv('CLAUDE_PROJECT_DIR')
	proj := if env_proj != '' { env_proj } else { (data['cwd'] or { json2.Any('') }).str() }
	proj_base := os.base(proj.trim_right('/\\'))

	mut graph_path := ''
	candidate1 := os.join_path(proj, 'graphify-out', 'graph.json')
	if os.exists(candidate1) {
		graph_path = candidate1
	} else {
		store := os.getenv('GRAPHIFY_STORE')
		if store != '' {
			candidate2 := os.join_path(store, proj_base, 'graph.json')
			if os.exists(candidate2) {
				graph_path = candidate2
			}
		}
	}
	if graph_path == '' {
		println('{}')
		return
	}

	match evt {
		'SessionStart' {
			println(emit('SessionStart', session_start_context))
		}
		'PreToolUse' {
			ti_any := data['tool_input'] or { json2.Any(map[string]json2.Any{}) }
			ti := ti_any.as_map()
			mut relevant := false
			file_path_any := ti['file_path'] or { json2.Any('') }
			file_path := file_path_any.str()
			if file_path != '' {
				set := graph_file_set(graph_path) or { map[string]bool{} }
				if set.len > 0 {
					relevant = to_rel(file_path, proj).to_lower() in set
				} else {
					relevant = file_path.ends_with('.v')
				}
			} else {
				blob := '${(ti['path'] or { json2.Any('') }).str()} ${(ti['glob'] or {
					json2.Any('')
				}).str()} ${(ti['pattern'] or { json2.Any('') }).str()} ${(ti['type'] or {
					json2.Any('')
				}).str()}'
				type_str := (ti['type'] or { json2.Any('') }).str()
				relevant = type_str == 'v' || blob.contains('*.v') || blob.trim_space().ends_with('.v')
			}
			if relevant {
				println(emit('PreToolUse', pretooluse_context))
			} else {
				println('{}')
			}
		}
		else {
			println('{}')
		}
	}
}
