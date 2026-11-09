module graphify

import os

// extractor_name is the CLI built with -prealloc that bin/update-vlang-graph.vsh
// builds beside the one built with the GC, `graphify-extract.exe` on Windows.
// extractor_pair_suffix names the file beside it that says which CLI it was built with:
// the hash of that CLI.
const extractor_name = $if windows { 'graphify-extract.exe' } $else { 'graphify-extract' }
const extractor_pair_suffix = '.cli-hash'

// no_extractor_env makes a CLI extract itself, for timing or comparing that build, or
// when the extractor can't run; the updater goes by it too. It says nothing about a
// graph already extracted: stale_note doesn't read it.
const no_extractor_env = 'GRAPHIFY_NO_EXTRACTOR'

// extractor_of is the binary that extracts for the CLI at `cli_exe`: the extractor
// beside it, when it was built with this very CLI, or the CLI itself. A CLI rebuilt by
// hand or restored from a backup is another build, so it goes on without the extractor.
// `extract` hands over to this binary (extract_handover), so each graph and cache of one
// build has the one hash.
pub fn extractor_of(cli_exe string) string {
	extractor := os.join_path(os.dir(cli_exe), extractor_name)
	paired := os.read_file(extractor + extractor_pair_suffix) or { return cli_exe }
	return if os.exists(extractor) && paired.trim_space() == file_hash(cli_exe) {
		extractor
	} else {
		cli_exe
	}
}

// extract_handover is the binary the `extract` of the CLI at `cli_exe` runs as: its
// extractor (extractor_of), unless no_extractor_env says to extract itself.
pub fn extract_handover(cli_exe string) string {
	return if os.getenv(no_extractor_env) != '' { cli_exe } else { extractor_of(cli_exe) }
}

// stale_note says why the graph at `graph_path` may no longer match what it
// describes, or '' when nothing suggests that. It reads the manifest.json
// written beside the graph and compares:
//
//   - the commit the graph was extracted from with the commit `root` (the
//     source checkout) is at now, and
//   - the commit each library root it read (VROOT, see Graph.library) was at
//     with the commit that root is at now, and each module under VMODULES it
//     kept was at with the commit that module's clone is at now, and
//   - the graphify build that extracted it with `cli_exe`, the graphify that
//     would extract it again, or the binary it would hand that to (extractor_of);
//     skipped when `cli_exe` is '', as for a graph shared from another machine, whose
//     build always differs. A copy of the CLI away from its extractor reports a graph
//     the extractor made, until the copy extracts it again.
//
// It costs one `git rev-parse` (two when the commits differ) and a hash of
// `cli_exe` and of its extractor. Uncommitted edits aren't reported: they are the normal state of
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
	// the library the project's calls resolve into: V updated, or a module reinstalled
	for l in m.library {
		for mod in l.modules {
			if mod.commit == '' {
				continue
			}
			dir := os.join_path(l.root, mod.name)
			head := git_commit_of(dir)
			if head != '' && head != mod.commit {
				notes << 'its module ${mod.name} was read from ${dir} at ${short_commit(mod.commit)}, which is at ${short_commit(head)} now'
			}
		}
		if l.commit == '' {
			continue
		}
		head := git_commit_of(l.root)
		if head != '' && head != l.commit {
			notes << 'its library (${l.label}) was read from ${l.root} at ${short_commit(l.commit)}, which is at ${short_commit(head)} now'
		}
	}
	if cli_exe != '' && m.binary_hash != '' && os.exists(cli_exe) {
		if m.binary_hash !in [file_hash(cli_exe), file_hash(extractor_of(cli_exe))] {
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

// cli_beside is the graphify CLI next to the executable `exe`, which extracts the
// graphs that executable reads, itself or through extractor_of.
pub fn cli_beside(exe string) string {
	name := $if windows { 'graphify.exe' } $else { 'graphify' }
	return os.join_path(os.dir(exe), name)
}
