#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Pulls the target repo, rebuilds graphify when it is out of date, and
// re-extracts when anything changed. Wired into a daily scheduler (Windows
// Task Scheduler / macOS launchd / Linux cron); can also be run by hand.
//
//   v run bin/update-vlang-graph.vsh                    # pull; extract if anything changed
//   v run bin/update-vlang-graph.vsh -NoPull            # skip the pull, always re-extract
//   v run bin/update-vlang-graph.vsh -Commit <sha>      # move up to that commit, not the newest
//   v run bin/update-vlang-graph.vsh -NoBuild           # never rebuild graphify
//
// The graph depends on graphify's own code and on the V parser it was compiled
// with (the vlib of the `v` on PATH), so a binary built before either changed
// extracts a different graph. The script records what each build saw in
// bin/.build-stamp and rebuilds bin/graphify (and graphify-mcp and
// graphify-hook, when present) whenever that no longer matches.
//
// -Commit makes two machines extract exactly the same source: it fast-forwards
// the repo to that commit and never moves it back or off its branch.

import os
import time
import crypto.sha256
import x.json2

struct Config {
	vlang_repo string
	store      string
}

struct Options {
mut:
	no_pull  bool
	no_build bool
	commit   string
}

const stamp_name = '.build-stamp'

fn log_line(log_path string, msg string) {
	line := '${time.now().format_ss()}  ${msg}'
	println(line)
	mut f := os.open_append(log_path) or { return }
	f.writeln(line) or {}
	f.close()
}

fn log_output(log_path string, out string) {
	for line in out.split_into_lines() {
		if line.trim_space() != '' {
			log_line(log_path, line)
		}
	}
}

fn fail(log_path string, msg string) {
	log_line(log_path, 'ERROR: ${msg}')
	log_line(log_path, '--- done ---')
	exit(1)
}

fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0
	for i < args.len {
		match args[i] {
			'-NoPull' {
				o.no_pull = true
			}
			'-NoBuild' {
				o.no_build = true
			}
			'-Commit' {
				if i + 1 >= args.len {
					return error('-Commit needs a commit')
				}
				o.commit = args[i + 1]
				i++
			}
			else {
				return error('unknown argument `${args[i]}`')
			}
		}
		i++
	}
	if o.no_pull && o.commit != '' {
		return error('-NoPull and -Commit contradict each other')
	}
	return o
}

fn git(repo string, args ...string) os.Result {
	mut cmd := ['git', '-C', repo]
	cmd << args
	return os.exec(cmd)
}

fn head_of(repo string) string {
	return git(repo, 'rev-parse', 'HEAD').output.trim_space()
}

// move_to_commit fast-forwards `repo` to `commit`, fetching first. It refuses
// to move back or sideways, which would need a reset or a detached HEAD.
fn move_to_commit(repo string, commit string) !string {
	fetch := git(repo, 'fetch')
	if fetch.exit_code != 0 {
		return error('git fetch failed: ${fetch.output.trim_space()}')
	}
	full := git(repo, 'rev-parse', '--verify', '${commit}^{commit}')
	if full.exit_code != 0 {
		return error('no commit `${commit}` in ${repo}, even after fetching')
	}
	target := full.output.trim_space()
	if head_of(repo) == target {
		return 'Already at ${target[..10]}.'
	}
	if git(repo, 'merge-base', '--is-ancestor', target, 'HEAD').exit_code == 0 {
		return error('${repo} is already past ${target[..10]}; not moving it back')
	}
	merge := git(repo, 'merge', '--ff-only', target)
	if merge.exit_code != 0 {
		return error('cannot fast-forward to ${target[..10]}: ${merge.output.trim_space()}')
	}
	return 'Fast-forwarded to ${target[..10]}.'
}

// find_v is the V compiler to build graphify with: the `v` on PATH, or else
// the one that compiled this script (launchd's PATH lacks /usr/local/bin).
fn find_v() string {
	return os.find_abs_path_of_executable('v') or { @VEXE }
}

// build_stamp names what a graphify build depends on: graphify's commit
// (plus its uncommitted changes), the V compiler's version, and the vlib it
// compiles against.
fn build_stamp(graphify_root string, v_exe string) !string {
	v_root := os.dir(os.real_path(v_exe))
	mut lines := []string{}
	lines << 'graphify ${head_of(graphify_root)}'
	diff := git(graphify_root, 'diff', 'HEAD', '--', '*.v', 'cmd', 'v.mod')
	if diff.output.trim_space() != '' {
		lines << 'graphify-diff ${sha256.hexhash(diff.output)}'
	}
	lines << 'v ${os.exec([v_exe, 'version']).output.trim_space()}'
	vlib := git(v_root, 'rev-parse', 'HEAD:vlib')
	if vlib.exit_code == 0 {
		lines << 'vlib ${vlib.output.trim_space()}'
	} else {
		// not a git checkout: the version line above is all there is
		lines << 'vlib ${v_root}'
	}
	return lines.join('\n')
}

// build_one builds one binary next to its final name and then swaps it in,
// so a running copy (the MCP server, on Windows) never blocks the build.
fn build_one(log_path string, v_exe string, out string, args []string) ! {
	tmp := out + '.new' + $if windows { '.exe' } $else { '' }
	mut cmd := [v_exe, '-prod', '-o', tmp]
	cmd << args
	res := os.exec(cmd)
	if res.exit_code != 0 {
		log_output(log_path, res.output)
		os.rm(tmp) or {}
		return error('building ${os.file_name(out)} failed')
	}
	if os.exists(out) {
		// Windows lets a running program be renamed but not deleted, so a
		// copy set aside by an earlier build may still be in use: take a name
		// that is free, and clear away every copy no longer running
		remove_old_copies(out)
		mut old := out + '.old'
		if os.exists(old) {
			old = '${out}.old-${time.now().unix_milli()}'
		}
		os.rename(out, old) or {
			os.rm(tmp) or {}
			return error('cannot replace ${out}: ${err}')
		}
		os.rm(old) or {}
	}
	os.rename(tmp, out)!
}

// remove_old_copies deletes the copies of `out` that earlier builds set
// aside, `<out>.old` and `<out>.old-<time>`; one still running stays.
fn remove_old_copies(out string) {
	bin_dir := os.dir(out)
	prefix := os.file_name(out) + '.old'
	for name in os.ls(bin_dir) or { return } {
		if name == prefix || name.starts_with(prefix + '-') {
			os.rm(os.join_path(bin_dir, name)) or {}
		}
	}
}

// rebuild_if_stale rebuilds graphify's binaries when bin/.build-stamp no
// longer matches, and reports whether it did.
fn rebuild_if_stale(log_path string, root string, exe string) !bool {
	v_exe := find_v()
	stamp := build_stamp(root, v_exe)!
	stamp_path := os.join_path(root, 'bin', stamp_name)
	old := os.read_file(stamp_path) or { '' }
	if old == stamp && os.exists(exe) {
		return false
	}
	log_line(log_path, 'graphify is out of date; rebuilding...')
	os.chdir(root)!
	ext := $if windows { '.exe' } $else { '' }
	// the CLI is what extracts; without it there is nothing to run
	build_one(log_path, v_exe, exe, ['cmd/cli'])!
	// the others only serve the graph: a failure is logged, the extract goes
	// ahead, and the stamp stays old so the next run tries them again
	mut all_built := true
	mcp := os.join_path(root, 'bin', 'graphify-mcp' + ext)
	if os.exists(mcp) {
		build_one(log_path, v_exe, mcp, ['cmd/mcp']) or {
			log_line(log_path, 'WARNING: ${err}')
			all_built = false
		}
	}
	hook := os.join_path(root, 'bin', 'graphify-hook' + ext)
	if os.exists(hook) {
		build_one(log_path, v_exe, hook, ['build', 'cmd/hooks/graphify_hook.vsh']) or {
			log_line(log_path, 'WARNING: ${err}')
			all_built = false
		}
	}
	if all_built {
		os.write_file(stamp_path, stamp)!
		log_line(log_path, 'rebuilt graphify')
	} else {
		log_line(log_path, 'rebuilt graphify, except as warned; the next run tries again')
	}
	return true
}

fn main() {
	root := @VMODROOT
	config_path := os.join_path(root, 'graphify.config.json')
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
	opts := parse_args(os.args[1..]) or {
		eprintln('${err}')
		exit(1)
	}

	vlang := config.vlang_repo
	store := config.store
	exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
	graphify_exe := os.join_path(root, 'bin', exe_name)
	log_path := os.join_path(store, 'update.log')

	log_line(log_path, '--- vlang graph update start ---')

	// pull first: the pull can bring V parser changes the rebuild must see
	mut changed := opts.no_pull
	if opts.commit != '' {
		log_line(log_path, 'moving to ${opts.commit}...')
		before := head_of(vlang)
		msg := move_to_commit(vlang, opts.commit) or {
			fail(log_path, err.msg())
			return
		}
		log_line(log_path, msg)
		changed = changed || head_of(vlang) != before
	} else if !opts.no_pull {
		log_line(log_path, 'git pull...')
		before := head_of(vlang)
		pull := git(vlang, 'pull', '--ff-only', '--quiet')
		if pull.exit_code != 0 {
			log_output(log_path, pull.output)
			fail(log_path, 'git pull failed')
		}
		after := head_of(vlang)
		if after == before {
			log_line(log_path, 'Already up to date.')
		} else {
			n := git(vlang, 'rev-list', '--count', '${before}..${after}').output.trim_space()
			log_line(log_path, 'Updated ${before#[..10]} -> ${after#[..10]} (${n} commits).')
		}
		changed = changed || after != before
	}

	if !opts.no_build {
		rebuilt := rebuild_if_stale(log_path, root, graphify_exe) or {
			fail(log_path, err.msg())
			return
		}
		changed = changed || rebuilt
	}

	if !changed {
		log_line(log_path, 'Nothing changed. Skipping extract.')
		log_line(log_path, '--- done ---')
		exit(0)
	}

	log_line(log_path, 'extracting graph...')
	start := time.now()
	result := os.exec([graphify_exe, 'extract', vlang, '--store', store])
	log_output(log_path, result.output)
	if result.exit_code != 0 {
		fail(log_path, 'extract failed')
	}
	elapsed_s := int(time.now().unix() - start.unix())
	log_line(log_path, 'done in ${elapsed_s}s')
	log_line(log_path, '--- done ---')
}
