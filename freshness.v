module graphify

import os

// stale_note says why the graph at `graph_path` may no longer match what it
// describes, or '' when nothing suggests that. It reads the manifest.json
// written beside the graph and compares:
//
//   - the commit the graph was extracted from with the commit `root` (the
//     source checkout) is at now, and
//   - the graphify build that extracted it with `cli_exe`, the graphify that
//     would extract it again; skipped when `cli_exe` is '', as for a graph
//     shared from another machine, whose build always differs.
//
// It costs one `git rev-parse` (two when the commits differ) and one hash of
// `cli_exe`. Uncommitted edits aren't reported: they are the normal state of
// a checkout being worked on.
pub fn stale_note(graph_path string, root string, cli_exe string) string {
	m := load_manifest(os.join_path(os.dir(graph_path), 'manifest.json')) or { return '' }
	mut notes := []string{}
	if m.source_commit != '' && root != '' {
		head := git_commit_of(root)
		if head != '' && head != m.source_commit {
			notes << 'it was extracted from ${short_commit(m.source_commit)}, but ${root} is at ${short_commit(head)}${commits_between(root,
				m.source_commit, head)}'
		}
	}
	if cli_exe != '' && m.binary_hash != '' && os.exists(cli_exe) {
		if file_hash(cli_exe) != m.binary_hash {
			notes << 'it was extracted by a different graphify build than ${cli_exe}'
		}
	}
	if notes.len == 0 {
		return ''
	}
	return 'this graph may be out of date: ${notes.join('; ')}. Re-extract it (bin/update-vlang-graph.vsh, or `graphify extract`) to refresh.'
}

fn short_commit(c string) string {
	return if c.len > 10 { c[..10] } else { c }
}

// commits_between describes how far `head` is from `old`: ' (3 commits
// ahead)' when `old` is an ancestor, '' otherwise (a rebase, another branch,
// or a commit this clone doesn't have).
fn commits_between(root string, old string, head string) string {
	res := os.exec(['git', '-C', root, 'rev-list', '--count', '${old}..${head}'])
	if res.exit_code != 0 {
		return ''
	}
	n := res.output.trim_space().int()
	if n <= 0 || os.exec(['git', '-C', root, 'merge-base', '--is-ancestor', old, head]).exit_code != 0 {
		return ''
	}
	return if n == 1 { ' (1 commit ahead)' } else { ' (${n} commits ahead)' }
}

// cli_beside is the graphify CLI next to the running executable, which is
// what extracts the graphs that executable reads.
pub fn cli_beside() string {
	name := $if windows { 'graphify.exe' } $else { 'graphify' }
	return os.join_path(os.dir(os.executable()), name)
}
