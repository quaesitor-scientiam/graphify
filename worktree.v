module graphify

import os
import crypto.sha256

// A git worktree of a project, or of the V tree, has the files of its own branch,
// but the graph of the project is of the project's checkout. The MCP server
// extracts the worktree's own graph, into a store of its own seeded with the
// checkout's cache, so that only the files the branch changed are parsed, and
// serves it in place of the checkout's (FUTURE_WORK.md §11).

// git_out is the trimmed output of git run in `dir`, '' when it fails.
fn git_out(dir string, args ...string) string {
	mut cmd := ['git', '-C', dir]
	cmd << args
	res := os.exec(cmd)
	return if res.exit_code == 0 { res.output.trim_space() } else { '' }
}

// git_common_dir is the real path of the repository `dir`'s checkout or worktree
// belongs to, which each worktree of it shares; '' outside a repository.
fn git_common_dir(dir string) string {
	d := git_out(dir, 'rev-parse', '--path-format=absolute', '--git-common-dir')
	return if d == '' { '' } else { os.real_path(d) }
}

// worktree_root is where the graph whose root is `root` would be rooted in the git
// worktree holding `dir`, when that is another worktree of root's repository than
// the one root is in: root's path in its checkout, under the worktree. None when
// `dir` is in root's own checkout, or in no worktree of its repository.
pub fn worktree_root(dir string, root string) ?string {
	if dir == '' || root == '' || !os.is_dir(dir) || !os.is_dir(root) {
		return none
	}
	top := git_out(dir, 'rev-parse', '--show-toplevel')
	root_top := git_out(root, 'rev-parse', '--show-toplevel')
	if top == '' || root_top == '' {
		return none
	}
	here := os.real_path(top)
	there := os.real_path(root_top)
	if here == there {
		return none
	}
	common := git_common_dir(dir)
	if common == '' || common != git_common_dir(root) {
		return none
	}
	real_root := os.real_path(root)
	sub := if real_root.len > there.len { real_root[there.len + 1..] } else { '' }
	return if sub == '' { here } else { os.join_path(here, sub) }
}

// worktree_stores is the directory the graphs of worktrees are extracted into, one
// store each (worktree_store): GRAPHIFY_WORKTREE_STORES, or one below the user's
// cache directory.
pub fn worktree_stores() string {
	dir := os.getenv('GRAPHIFY_WORKTREE_STORES')
	return if dir != '' { dir } else { os.join_path(os.cache_dir(), 'graphify', 'worktrees') }
}

// worktree_store is the directory under `stores` the graph of the worktree rooted
// at `worktree` is extracted into: its name, and a hash of its path, which tells
// apart two worktrees of one name.
pub fn worktree_store(stores string, worktree string) string {
	real := os.real_path(worktree)
	return os.join_path(stores, '${os.base(real)}-${sha256.hexhash(real)[..12]}')
}

// seed_worktree_store makes `store` and, when it has no extract cache yet, copies
// in the one beside `graph`, the graph of the checkout, so that an extract of the
// worktree parses only the files that differ from it.
pub fn seed_worktree_store(store string, graph string) ! {
	os.mkdir_all(store)!
	mine := os.join_path(store, cache_file_name)
	theirs := os.join_path(os.dir(graph), cache_file_name)
	if !os.exists(mine) && os.exists(theirs) {
		os.cp(theirs, mine)!
	}
}

// worktree_state tells when a worktree has changed: its commit, and the size and
// time of each V file git reports as changed, so that a file edited again since
// changes it as well.
pub fn worktree_state(worktree string) string {
	mut parts := [git_out(worktree, 'rev-parse', 'HEAD')]
	// a line's first column is a space for a file changed but not staged, so the
	// output is not trimmed
	status := os.exec(['git', '-C', worktree, 'status', '--porcelain', '-uall', '--', '*.v', '*.vsh']).output
	for line in status.split_into_lines() {
		if line.len < 4 {
			continue
		}
		path := os.join_path(worktree, line[3..].all_after(' -> '))
		parts << if os.is_file(path) {
			'${line}:${os.file_size(path)}:${os.file_last_mod_unix(path)}'
		} else {
			line
		}
	}
	return parts.join('\n')
}

// prune_worktree_stores removes each store under `stores` whose worktree is gone,
// as its manifest names it: a worktree is removed when its branch is done, and its
// store is a copy of a project's graph and cache.
pub fn prune_worktree_stores(stores string) {
	for name in os.ls(stores) or { return } {
		store := os.join_path(stores, name)
		m := load_manifest(os.join_path(store, 'manifest.json')) or { continue }
		if m.root != '' && !os.is_dir(m.root) {
			os.rmdir_all(store) or {}
		}
	}
}

// WorktreeGraph is the graph a worktree's is extracted in place of: `graph`, the
// graph.json of the checkout, and `root`, where its root is in the worktree.
pub struct WorktreeGraph {
pub:
	graph string
	root  string
}

// worktree_graph finds the graph whose repository has the worktree holding `dir`
// as another worktree: `project_graph`'s, the project graph project_for found for
// `dir`, when there is one; else the deepest of the project graphs in `projects_dir`
// whose root's place in the worktree holds `dir`; else `base_graph`'s, rooted at
// `base_root`. None when `dir` is in each one's own checkout, or in no worktree of
// theirs.
pub fn worktree_graph(projects_dir string, dir string, project_graph string, base_graph string, base_root string) ?WorktreeGraph {
	if dir == '' {
		return none
	}
	here := os.real_path(dir)
	if project_graph != '' {
		m := load_manifest(os.join_path(os.dir(project_graph), 'manifest.json')) or {
			return none
		}
		root := worktree_root(dir, m.root) or { return none }
		return WorktreeGraph{
			graph: project_graph
			root:  root
		}
	}
	mut best := WorktreeGraph{}
	if projects_dir != '' {
		for name in os.ls(projects_dir) or { []string{} } {
			graph := os.join_path(projects_dir, name, 'graph.json')
			m := load_manifest(os.join_path(projects_dir, name, 'manifest.json')) or { continue }
			if m.root == '' || !os.exists(graph) {
				continue
			}
			root := worktree_root(dir, m.root) or { continue }
			if path_holds(root, here) && root.len > best.root.len {
				best = WorktreeGraph{
					graph: graph
					root:  root
				}
			}
		}
	}
	if best.graph != '' {
		return best
	}
	root := worktree_root(dir, base_root) or { return none }
	if !path_holds(root, here) {
		return none
	}
	return WorktreeGraph{
		graph: base_graph
		root:  root
	}
}
