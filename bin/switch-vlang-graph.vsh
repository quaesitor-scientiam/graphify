#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Extracts (or reuses) a per-branch graph for the target repo and points
// ~/.claude.json's graphify MCP server at it.
//
//   v run bin/switch-vlang-graph.vsh [branch] [-Checkout] [-Force]
//   v run bin/switch-vlang-graph.vsh <worktree-path> [-Force]
//
// A positional arg that is an existing directory is treated as a WORKTREE
// PATH, not a branch name: its own checked-out branch is used to label the
// stored graph, and -Checkout is meaningless (a worktree is already on its
// own branch) and ignored if passed. This is the normal case for this
// project's own convention of one worktree per feature branch (never
// `git checkout <branch>` inside the shared main checkout) -- pass the
// worktree path directly, e.g.:
//   v run bin/switch-vlang-graph.vsh S:\repo\vlang-http3-server-handshake
//
// A plain branch name (no such directory exists) keeps the original
// behavior: operates on the single configured `vlang_repo` checkout,
// optionally `git checkout`-ing it first with -Checkout.
//
// Either way, a brand-new graph is NOT a full rescan: master's own
// `.gf_cache.ndjson` (content-hash-keyed, portable across directories) is
// copied in to prime the target's cache before extracting, so only files
// that actually differ from master's current tree get reparsed. Measured
// on a real branch whose only difference from master was one commit: full
// scan ~60-90s, primed-cache scan ~8s, same symbol/edge count for the
// unchanged files. Skip this priming (rare: you want a graph of some
// OTHER, unrelated base than current master) by deleting the target
// graph_dir's .gf_cache.ndjson before rerunning with -Force.

import os
import time
import json2

struct Config {
	vlang_repo string
	store      string
}

fn parse_flag(args []string, name string) bool {
	return name in args
}

fn positional_branch(args []string) string {
	for a in args {
		if !a.starts_with('-') {
			return a
		}
	}
	return ''
}

fn count_occurrences(haystack string, needle string) int {
	mut count := 0
	mut start := 0
	for {
		idx := haystack.index_after(needle, start) or { break }
		count++
		start = idx + needle.len
	}
	return count
}

// patch_mcp_args replaces the graphify mcpServers entry's current args[0]
// value with `graph_file`, touching nothing else in the file byte-for-byte.
//
// Locating the entry via a naive text search on `"graphify"` is NOT safe:
// this file's own "projects" section keys projects by absolute path, and
// this very repo's path contains "graphify" too, so a bare keyword search
// can anchor on the wrong occurrence and corrupt an unrelated entry (caught
// empirically while testing against a real ~/.claude.json — it silently
// patched the "context7" server's args instead). Decoding first to find the
// CURRENT args[0] value, then anchoring the text splice on that exact
// value (verified to occur exactly once) is what makes this safe — a full
// decode+re-encode round-trip was tried too, but x.json2's `Any` sum type
// decodes every bare number as f64, and re-encoding floats that started as
// clean integers (timestamps, token counts throughout this file) produced
// precision artifacts like `54.988092999999985` — silently wrong data in a
// file Claude Code itself relies on.
fn patch_mcp_args(content string, graph_file string) !string {
	decoded := json2.decode[json2.Any](content) or { return error('not valid JSON: ${err}') }
	root := decoded.as_map()
	mcp_servers := (root['mcpServers'] or {
		return error('no top-level "mcpServers" key found')
	}).as_map()
	graphify_entry := (mcp_servers['graphify'] or {
		return error('no "graphify" entry under mcpServers — register it first (see README\'s MCP setup section)')
	}).as_map()
	old_args := (graphify_entry['args'] or {
		return error('graphify mcpServers entry has no "args" field')
	}).as_array()
	if old_args.len == 0 {
		return error('graphify mcpServers entry has an empty "args" array — nothing to anchor the replacement on')
	}
	old_escaped := json2.Any(old_args[0].str()).json_str()

	occurrences := count_occurrences(content, old_escaped)
	if occurrences != 1 {
		return error('expected exactly 1 occurrence of the current args value ${old_escaped}, found ${occurrences} — refusing to guess which one to replace')
	}
	idx := content.index(old_escaped) or { return error('unreachable') }
	new_escaped := json2.Any(graph_file).json_str()
	return content[..idx] + new_escaped + content[idx + old_escaped.len..]
}

// prime_cache_from_master copies master's incremental cache into a fresh
// graph_dir before extraction, so the extractor treats any file whose
// content is unchanged from master's current tree as already-parsed
// instead of rescanning it. Best-effort: a missing master cache (e.g. this
// is the very first extract ever) just means the branch's own extract
// falls back to a full scan, same as before this existed.
fn prime_cache_from_master(store string, graph_dir string) {
	master_cache := os.join_path(store, 'vlang', '.gf_cache.ndjson')
	target_cache := os.join_path(graph_dir, '.gf_cache.ndjson')
	if !os.exists(master_cache) {
		return
	}
	os.mkdir_all(graph_dir) or { return }
	os.cp(master_cache, target_cache) or {
		eprintln('Could not prime cache from master (${err}) -- falling back to a full scan')
	}
}

fn main() {
	config_path := os.join_path(@VMODROOT, 'graphify.config.json')
	if !os.exists(config_path) {
		eprintln('Missing config: ${config_path}\nCopy graphify.config.json.example to graphify.config.json and edit it for your setup.')
		exit(1)
	}
	config_content := os.read_file(config_path) or {
		eprintln('Could not read config: ${err}')
		exit(1)
	}
	config := json2.decode[Config](config_content) or {
		eprintln('Could not parse config: ${err}')
		exit(1)
	}

	args := os.args#[1..]
	do_checkout := parse_flag(args, '-Checkout')
	force := parse_flag(args, '-Force')
	positional := positional_branch(args)

	store := config.store
	exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
	graphify_exe := os.join_path(@VMODROOT, 'bin', exe_name)
	claude_json_path := os.join_path(os.home_dir(), '.claude.json')

	// A positional arg that names an existing directory is a worktree path:
	// extract IT directly, never touch the shared main checkout, and label
	// the stored graph after whatever branch that worktree itself is on.
	is_worktree := positional != '' && os.is_dir(positional)

	mut vlang := config.vlang_repo
	mut branch := positional

	if is_worktree {
		vlang = positional
		detect := os.execute('git -C ${os.quoted_path(vlang)} branch --show-current')
		branch = detect.output.trim_space()
		if branch == '' {
			eprintln('Could not detect the branch checked out at ${vlang}')
			exit(1)
		}
		if do_checkout {
			eprintln('-Checkout is ignored for a worktree path -- it is already on its own branch.')
		}
	} else {
		if branch == '' {
			detect := os.execute('git -C ${os.quoted_path(vlang)} branch --show-current')
			branch = detect.output.trim_space()
			if branch == '' {
				eprintln('Could not detect current branch')
				exit(1)
			}
		}
		if do_checkout {
			println('git checkout ${branch}...')
			checkout := os.execute('git -C ${os.quoted_path(vlang)} checkout ${os.quoted_path(branch)}')
			println(checkout.output.trim_space())
		}
	}

	safe_branch := branch.replace('/', '-').replace('\\', '-')
	graph_dir := if branch in ['master', 'main'] {
		os.join_path(store, 'vlang')
	} else {
		os.join_path(store, 'vlang-${safe_branch}')
	}
	graph_file := os.join_path(graph_dir, 'graph.json')

	if force || !os.exists(graph_file) {
		if branch !in ['master', 'main'] {
			prime_cache_from_master(store, graph_dir)
		}
		println("Extracting graph for branch '${branch}' (${vlang}) -> ${graph_dir} ...")
		start := time.now()
		result := os.execute('${os.quoted_path(graphify_exe)} extract ${os.quoted_path(vlang)} --out ${os.quoted_path(graph_dir)}')
		println(result.output.trim_space())
		elapsed_s := int(time.now().unix() - start.unix())
		println('Done in ${elapsed_s}s')
	} else {
		println("Graph already exists for '${branch}' (use -Force to re-extract)")
	}

	if !os.exists(claude_json_path) {
		eprintln('No ~/.claude.json found at ${claude_json_path} — skipping MCP config update.')
		exit(0)
	}
	claude_content := os.read_file(claude_json_path) or {
		eprintln('Could not read ${claude_json_path}: ${err}')
		exit(1)
	}
	new_content := patch_mcp_args(claude_content, graph_file) or {
		eprintln('Could not update ${claude_json_path}: ${err}')
		exit(1)
	}
	// Belt-and-suspenders: confirm the spliced result still parses before
	// writing it over the user's real config.
	json2.decode[json2.Any](new_content) or {
		eprintln('Refusing to write ${claude_json_path}: patched content is not valid JSON (${err})')
		exit(1)
	}
	os.write_file(claude_json_path, new_content) or {
		eprintln('Could not write ${claude_json_path}: ${err}')
		exit(1)
	}
	println('MCP config updated -> ${graph_file}')
	println('')
	println("Restart Claude Code to load the '${branch}' graph.")
}
