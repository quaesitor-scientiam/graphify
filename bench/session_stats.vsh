#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Shows graphify tool usage (main agent vs subagents) per Claude Code
// session, alongside Read/Grep/Glob/Bash call counts, for the last N days.
//
//   v run bench/session_stats.vsh
//   v run bench/session_stats.vsh -Days 30 -IncludeBench

import os
import time
import json2

fn flag_value(args []string, name string) string {
	for i, a in args {
		if a == name && i + 1 < args.len {
			return args[i + 1]
		}
	}
	return ''
}

fn flag_present(args []string, name string) bool {
	return name in args
}

// count_tool_uses tallies tool_use blocks by tool name across every
// assistant message in a session transcript (one JSON object per line).
fn count_tool_uses(path string) map[string]int {
	mut tbl := map[string]int{}
	lines := os.read_lines(path) or { return tbl }
	for line in lines {
		if line.trim_space() == '' {
			continue
		}
		decoded := json2.decode[json2.Any](line) or { continue }
		obj := decoded.as_map()
		if (obj['type'] or { continue }).str() != 'assistant' {
			continue
		}
		message := (obj['message'] or { continue }).as_map()
		content := (message['content'] or { continue }).as_array()
		for item in content {
			imap := item.as_map()
			if (imap['type'] or { continue }).str() != 'tool_use' {
				continue
			}
			name := (imap['name'] or { continue }).str()
			tbl[name] = tbl[name] + 1
		}
	}
	return tbl
}

fn sum_prefixed(tbl map[string]int, prefix string) int {
	mut total := 0
	for k, v in tbl {
		if k.starts_with(prefix) {
			total += v
		}
	}
	return total
}

fn merged(main map[string]int, subs map[string]int, key string) int {
	return (main[key] or { 0 }) + (subs[key] or { 0 })
}

fn pad_right(s string, width int) string {
	if s.len >= width {
		return s
	}
	return s + ' '.repeat(width - s.len)
}

fn pad_left(s string, width int) string {
	if s.len >= width {
		return s
	}
	return ' '.repeat(width - s.len) + s
}

fn dash_if_zero(n int) string {
	return if n > 0 { n.str() } else { '-' }
}

struct Row {
	date     string
	project  string
	g_main   int
	g_sub    int
	query    int
	node     int
	body     int
	overview int
	path     int
	read     int
	grep     int
	glob     int
	bash     int
}

fn main() {
	args := os.args#[1..]
	days_str := flag_value(args, '-Days')
	days := if days_str != '' { days_str.int() } else { 14 }
	include_bench := flag_present(args, '-IncludeBench')

	projects_dir := os.join_path(os.home_dir(), '.claude', 'projects')
	cutoff := time.now().unix() - i64(days) * 24 * 3600

	mut rows := []Row{}

	project_dirs := os.ls(projects_dir) or {
		eprintln('Could not list ${projects_dir}: ${err}')
		exit(1)
	}
	for pd in project_dirs {
		full_pd := os.join_path(projects_dir, pd)
		if !os.is_dir(full_pd) {
			continue
		}
		entries := os.ls(full_pd) or { continue }
		for entry in entries {
			if !entry.ends_with('.jsonl') {
				continue
			}
			full_path := os.join_path(full_pd, entry)
			if os.file_last_mod_unix(full_path) < cutoff {
				continue
			}
			if !include_bench && full_path.contains('graphify-bench') {
				continue
			}

			mut proj := pd.trim_string_left('S--').replace('-', '/')
			if proj.contains('/') {
				proj = proj.all_after_last('/')
			}
			if proj.len > 20 {
				proj = proj[..19] + '…'
			}
			date := time.unix(os.file_last_mod_unix(full_path)).local().custom_format('MM-DD HH:mm')

			main_tbl := count_tool_uses(full_path)
			mut sub_tbl := map[string]int{}
			session_base := entry#[..entry.len - '.jsonl'.len]
			subdir := os.join_path(full_pd, session_base, 'subagents')
			if os.is_dir(subdir) {
				sub_files := os.ls(subdir) or { []string{} }
				for sf in sub_files {
					if sf.ends_with('.jsonl') {
						sf_tbl := count_tool_uses(os.join_path(subdir, sf))
						for k, v in sf_tbl {
							sub_tbl[k] = sub_tbl[k] + v
						}
					}
				}
			}

			rows << Row{
				date:     date
				project:  proj
				g_main:   sum_prefixed(main_tbl, 'mcp__graphify__')
				g_sub:    sum_prefixed(sub_tbl, 'mcp__graphify__')
				query:    merged(main_tbl, sub_tbl, 'mcp__graphify__query_graph')
				node:     merged(main_tbl, sub_tbl, 'mcp__graphify__get_node')
				body:     merged(main_tbl, sub_tbl, 'mcp__graphify__get_body')
				overview: merged(main_tbl, sub_tbl, 'mcp__graphify__overview')
				path:     merged(main_tbl, sub_tbl, 'mcp__graphify__shortest_path')
				read:     merged(main_tbl, sub_tbl, 'Read')
				grep:     merged(main_tbl, sub_tbl, 'Grep')
				glob:     merged(main_tbl, sub_tbl, 'Glob')
				bash:     merged(main_tbl, sub_tbl, 'Bash') + merged(main_tbl, sub_tbl, 'PowerShell')
			}
		}
	}

	if rows.len == 0 {
		println('No sessions found in the last ${days} days.')
		return
	}
	rows.sort(a.date < b.date)

	hdr := '${pad_right('Date', 14)} ${pad_right('Project', 20)} ${pad_left('m/s', 8)} ${pad_left('query',
		6)} ${pad_left('node', 5)} ${pad_left('body', 5)} ${pad_left('overview', 9)} ${pad_left('path',
		5)} | ${pad_left('Read', 5)} ${pad_left('Grep', 5)} ${pad_left('Glob', 5)} ${pad_left('Bash', 5)}'
	println(hdr)
	println('  (graphify: m=main agent  s=subagents)')
	println('-'.repeat(hdr.len + 2))

	for r in rows {
		ms := if r.g_main + r.g_sub > 0 { '${r.g_main}/${r.g_sub}' } else { '-' }
		println('${pad_right(r.date, 14)} ${pad_right(r.project, 20)} ${pad_left(ms, 8)} ${pad_left(dash_if_zero(r.query),
			6)} ${pad_left(dash_if_zero(r.node), 5)} ${pad_left(dash_if_zero(r.body), 5)} ${pad_left(dash_if_zero(r.overview),
			9)} ${pad_left(dash_if_zero(r.path), 5)} | ${pad_left(r.read.str(), 5)} ${pad_left(r.grep.str(),
			5)} ${pad_left(r.glob.str(), 5)} ${pad_left(r.bash.str(), 5)}')
	}

	println('')
	println('graphify tools:')
	println('  query    search the graph by keyword, returns matching symbols + neighbors (use instead of grep)')
	println('  node     one symbol: signature, file:line, and all relationships (calls, callers, references)')
	println('  body     source of one declaration by name (use instead of reading the whole file)')
	println('  overview compact map of the codebase: counts + most-connected symbols')
	println('  path     shortest relationship chain between two symbols')
	println('')
	println('Bash column includes PowerShell calls. Bench sessions excluded (use -IncludeBench to add them).')
}
