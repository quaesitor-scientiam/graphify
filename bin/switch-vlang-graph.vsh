#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Extracts (or reuses) a per-branch graph for the target repo and points
// ~/.claude.json's graphify MCP server at it.
//
//   v run bin/switch-vlang-graph.vsh [branch] [-Checkout] [-Force]

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
	mut branch := positional_branch(args)

	vlang := config.vlang_repo
	store := config.store
	exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
	graphify_exe := os.join_path(@VMODROOT, 'bin', exe_name)
	claude_json_path := os.join_path(os.home_dir(), '.claude.json')

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

	safe_branch := branch.replace('/', '-').replace('\\', '-')
	graph_dir := if branch in ['master', 'main'] {
		os.join_path(store, 'vlang')
	} else {
		os.join_path(store, 'vlang-${safe_branch}')
	}
	graph_file := os.join_path(graph_dir, 'graph.json')

	if force || !os.exists(graph_file) {
		println("Extracting graph for branch '${branch}' -> ${graph_dir} ...")
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
