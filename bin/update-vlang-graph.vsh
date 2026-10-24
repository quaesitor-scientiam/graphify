#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Pulls graphify and the target repo, rebuilds graphify when it is out of
// date, and re-extracts each graph that is out of date. Wired into a daily scheduler
// (Windows Task Scheduler / macOS launchd / Linux cron); can also be run by
// hand.
//
//   v run bin/update-vlang-graph.vsh                    # pull both; extract what is out of date
//   v run bin/update-vlang-graph.vsh -NoPull            # pull neither (after your own `v up`)
//   v run bin/update-vlang-graph.vsh -Force             # re-extract every graph, out of date or not
//   v run bin/update-vlang-graph.vsh -Commit <sha>      # move up to that commit, not the newest
//   v run bin/update-vlang-graph.vsh -NoBuild           # never rebuild graphify
//   v run bin/update-vlang-graph.vsh -PrintStamp        # print the build stamp and stop
//
// The graph depends on graphify's own code and on the V parser it was compiled
// with (the vlib of the `v` on PATH), so a binary built before either changed
// extracts a different graph. The script records what each build saw in
// bin/.build-stamp (graphify's commit and uncommitted changes, and the git
// tree of each vlib/v directory graphify compiles in, found with
// `v -print-v-files`) and rebuilds bin/graphify (and graphify-mcp and
// graphify-hook, when present) whenever that no longer matches. A change to
// the rest of vlib, such as os or strings, doesn't rebuild.
//
// -Commit makes two machines extract exactly the same source: it fast-forwards
// the repo to that commit and never moves it back or off its branch.
//
// A graph is out of date when it doesn't exist yet, or its manifest.json says it was
// extracted from another commit of its repo or by another graphify build than
// bin/graphify, or, for a project, read its vlib at another commit of the target
// repo, or a module under VMODULES at another commit of its clone (graph_out_of_date).
// Uncommitted edits aren't seen: -Force re-extracts every graph.
//
// The config's `projects` are extracted after the target repo, each into the store
// beside it, so the MCP server can layer each on it (`--projects`, FUTURE_WORK.md
// §11). A project is never pulled: it is someone's checkout.
//
// graphify's own checkout is fast-forwarded too, so a merged change reaches
// every machine on its next run; it is left alone when it has local changes
// or isn't on a branch, and a failed pull only logs a warning. A prebuilt
// bin/update-vlang-graph(.exe) beside it, which the Windows task runs, is
// rebuilt with the rest.
//
// One run goes at a time: a run holds a lock in the store (update.lock), and one
// that starts while it is held, such as the scheduled task while a run by hand is
// building, logs that and stops. A lock over an hour old was left by a run that
// died, and is taken over (acquire_lock).

import os
import time
import crypto.sha256
import x.json2

struct Config {
	vlang_repo string
	store      string
	projects   []string
}

// GraphManifest is the part of a graph's manifest.json that says whether it is out
// of date (graph_out_of_date).
struct GraphManifest {
	root          string
	source_commit string
	binary_hash   string
	library       []GraphLibrary
}

struct GraphLibrary {
	label   string
	root    string
	commit  string
	modules []GraphModule
}

struct GraphModule {
	name   string
	commit string
}

struct Options {
mut:
	no_pull     bool
	no_build    bool
	print_stamp bool
	force       bool
	commit      string
}

const stamp_name = '.build-stamp'

// the lock a run holds while it pulls, builds and extracts: a directory in the
// store, which only one process can create (acquire_lock)
const lock_name = 'update.lock'

// how old a lock is, in seconds, when it is taken for one left by a run that
// died; a whole run takes about 10 minutes
const lock_stale_after = i64(3600)

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
	// the lock is beside the log, in the store
	release_lock(os.join_path(os.dir(log_path), lock_name))
	exit(1)
}

// acquire_lock takes the lock `lock_dir` for this run: true when it holds it, false
// when another run does, which it logs. Without it, the scheduled task that starts
// while a run by hand is building builds and extracts the same again. A lock older
// than lock_stale_after was left by a run that died, and is taken over. When no lock
// can be made at all, the run goes on without one.
fn acquire_lock(log_path string, lock_dir string) bool {
	if take_lock(lock_dir) {
		return true
	}
	if !os.is_dir(lock_dir) {
		log_line(log_path, 'WARNING: cannot create ${lock_dir}; running without a lock')
		return true
	}
	who := (os.read_file(os.join_path(lock_dir, 'owner')) or { 'an unknown run' }).trim_space()
	since := os.file_last_mod_unix(lock_dir)
	age := time.now().unix() - since
	if age < lock_stale_after {
		log_line(log_path, 'another update is running (${who}, since ${time.unix(since).local().format_ss()}); not starting a second one. If none is, delete ${lock_dir}.')
		return false
	}
	// move it aside, which only one run can do, and take its place
	aside := '${lock_dir}.stale-${time.now().unix_milli()}'
	os.rename(lock_dir, aside) or {
		log_line(log_path, 'another update took over a stale lock first; not starting a second one')
		return false
	}
	// another run may have taken it over between the look and the move, and what
	// moved is that run's new lock: put it back
	if os.file_last_mod_unix(aside) != since {
		os.rename(aside, lock_dir) or {}
		log_line(log_path, 'another update took over a stale lock first; not starting a second one')
		return false
	}
	os.rmdir_all(aside) or {}
	log_line(log_path, 'taking over a lock left ${age / 60} min ago (${who})')
	if !take_lock(lock_dir) {
		log_line(log_path, 'another update took the lock first; not starting a second one')
		return false
	}
	return true
}

// take_lock creates the lock `lock_dir`, noting this run in it (lock_owner): false
// when it can't, most often because another run holds it. A lock it can't note its
// owner in goes again, as release_lock couldn't tell it was this run's.
fn take_lock(lock_dir string) bool {
	os.mkdir(lock_dir) or { return false }
	os.write_file(os.join_path(lock_dir, 'owner'), lock_owner()) or {
		os.rmdir_all(lock_dir) or {}
		return false
	}
	return true
}

// release_lock removes the lock `lock_dir` if this run holds it: a run that went on
// past lock_stale_after may have lost it to another.
fn release_lock(lock_dir string) {
	if (os.read_file(os.join_path(lock_dir, 'owner')) or { '' }) == lock_owner() {
		os.rmdir_all(lock_dir) or {}
	}
}

// lock_owner names this run in the lock it holds.
fn lock_owner() string {
	return 'pid ${os.getpid()}'
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
			'-Force' {
				o.force = true
			}
			'-PrintStamp' {
				o.print_stamp = true
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

// pull_graphify fast-forwards graphify's own checkout. It doesn't touch one
// with uncommitted changes or a detached HEAD, which someone is working in,
// and a failure is a warning: the run goes on with the code it has.
fn pull_graphify(log_path string, root string) {
	if git(root, 'symbolic-ref', '-q', 'HEAD').exit_code != 0 {
		log_line(log_path, 'graphify: not on a branch; not pulling it')
		return
	}
	if git(root, 'status', '--porcelain', '--untracked-files=no').output.trim_space() != '' {
		log_line(log_path, 'graphify: local changes; not pulling it')
		return
	}
	before := head_of(root)
	pull := git(root, 'pull', '--ff-only', '--quiet')
	if pull.exit_code != 0 {
		log_line(log_path, 'WARNING: graphify pull failed: ${pull.output.trim_space()}')
		return
	}
	after := head_of(root)
	if after != before {
		log_line(log_path, 'graphify: updated ${before#[..10]} -> ${after#[..10]}.')
	}
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

// set_vroot gives the extracts the V tree to read vlib and VMODULES against, as
// VROOT. An extract otherwise looks for the `v` on PATH, which a scheduled run's
// PATH may lack (launchd's lacks /usr/local/bin) or may hold outside a V tree, and
// without one it extracts no library at all, saying nothing. A VROOT already set
// is kept; otherwise it is the tree of the `v` on PATH, else of the `v` that runs
// this script (VEXE, which `v run` sets), else of the one that compiled it. A tree
// in V's cache is passed over: a script V3 can't compile is compiled by its
// v1-fallback (~/.cache/v/v1-fallback/0.5.2), whose vlib is V 0.5.2's.
fn set_vroot(log_path string) {
	if os.getenv('VROOT') == '' {
		for v in [os.find_abs_path_of_executable('v') or { '' }, os.getenv('VEXE'), @VEXE] {
			if v == '' {
				continue
			}
			tree := os.dir(os.real_path(v))
			if tree.replace('\\', '/').contains('/v1-fallback/') {
				continue
			}
			if os.is_dir(os.join_path(tree, 'vlib', 'builtin')) {
				os.setenv('VROOT', tree, true)
				break
			}
		}
	}
	vroot := os.getenv('VROOT')
	if vroot == '' {
		log_line(log_path, 'no V tree found: extracting without vlib and VMODULES')
		return
	}
	mut vmodules := os.getenv('VMODULES')
	if vmodules == '' {
		vmodules = os.join_path(os.home_dir(), '.vmodules')
	}
	if !os.is_dir(vmodules) {
		vmodules = '(none)'
	}
	log_line(log_path, 'libraries: vlib from ${vroot}, VMODULES ${vmodules}')
}

// build_stamp names what a graphify build depends on: graphify's commit (plus its
// uncommitted changes), the compiler that builds it, `v version`, and the vlib and
// thirdparty (libgc) it compiles in, as their git trees (plus their uncommitted
// changes). A new compiler counts even when vlib/v's parser, all the graph is read
// through, is the same: vlang/v#30996 changed only the C backend, and graphify-mcp
// went on losing live strings to the GC until it was rebuilt. A rebuild after each
// `v up` is about 36 s on top of the re-extract the moved vlib asks for anyway.
fn build_stamp(graphify_root string, v_exe string) !string {
	v_root := os.dir(os.real_path(v_exe))
	mut lines := []string{}
	lines << 'graphify ${head_of(graphify_root)}'
	diff := git(graphify_root, 'diff', 'HEAD', '--', '*.v', 'cmd', 'v.mod')
	if diff.output.trim_space() != '' {
		lines << 'graphify-diff ${sha256.hexhash(diff.output)}'
	}
	lines << 'compiler ${os.exec([v_exe, 'version']).output.trim_space()}'
	for dir in ['vlib', 'thirdparty'] {
		tree := git(v_root, 'rev-parse', 'HEAD:${dir}')
		if tree.exit_code == 0 {
			lines << '${dir} ${tree.output.trim_space()}'
		} else {
			// `v` isn't a git checkout
			lines << '${dir} ${os.join_path(v_root, dir)}'
		}
	}
	v_diff := git(v_root, 'diff', 'HEAD', '--', 'vlib', 'thirdparty')
	if v_diff.exit_code == 0 && v_diff.output.trim_space() != '' {
		lines << 'v-diff ${sha256.hexhash(v_diff.output)}'
	}
	return lines.join('\n')
}

// build_one builds one binary next to its final name and then swaps it in,
// so a running copy (the MCP server, on Windows) never blocks the build.
// `prod` (-prod: optimised, link-time) is for the CLI only. It takes 2 min to build
// where a plain build takes 8 s, but the CLI is what extracts and answers queries:
// a plain CLI extracts vlang in about 80 s against 25-50 s, and answers 4x slower.
// The MCP server takes 3 min 14 s with -prod and 29 s without, and the hook 36 s and
// 6 s; each answers about as fast either way (a lookup 0.05 s against 0.02 s, a hook
// call 0.04 s against 0.03 s).
fn build_one(log_path string, v_exe string, out string, prod bool, args []string) ! {
	tmp := out + '.new' + $if windows { '.exe' } $else { '' }
	mut cmd := [v_exe, '-o', tmp]
	if prod {
		cmd.insert(1, '-prod')
	}
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

// remove_build_leftovers deletes the `.<name>.v3cc.*` directories that V's
// compiler leaves beside a binary it built (each holds a ~2 MB C file). Only
// ones older than an hour go, so a build still running keeps its own.
fn remove_build_leftovers(bin_dir string) {
	cutoff := time.now().unix() - 3600
	for name in os.ls(bin_dir) or { return } {
		path := os.join_path(bin_dir, name)
		if name.starts_with('.') && name.contains('.v3cc.') && os.is_dir(path)
			&& os.file_last_mod_unix(path) < cutoff {
			os.rmdir_all(path) or {}
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
	build_one(log_path, v_exe, exe, true, ['cmd/cli'])!
	// the others only serve the graph: a failure is logged, the extract goes
	// ahead, and the stamp stays old so the next run tries them again
	mut all_built := true
	mcp := os.join_path(root, 'bin', 'graphify-mcp' + ext)
	if os.exists(mcp) {
		build_one(log_path, v_exe, mcp, false, ['cmd/mcp']) or {
			log_line(log_path, 'WARNING: ${err}')
			all_built = false
		}
	}
	hook := os.join_path(root, 'bin', 'graphify-hook' + ext)
	if os.exists(hook) {
		build_one(log_path, v_exe, hook, false, ['build', 'cmd/hooks/graphify_hook.vsh']) or {
			log_line(log_path, 'WARNING: ${err}')
			all_built = false
		}
	}
	// this script, prebuilt for the Windows task; it is running, which the
	// swap in build_one allows
	updater := os.join_path(root, 'bin', 'update-vlang-graph' + ext)
	if os.exists(updater) {
		build_one(log_path, v_exe, updater, false, ['build', 'bin/update-vlang-graph.vsh']) or {
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
	if opts.print_stamp {
		println(build_stamp(root, find_v()) or {
			eprintln('${err}')
			exit(1)
		})
		return
	}

	vlang := config.vlang_repo
	store := config.store
	exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
	graphify_exe := os.join_path(root, 'bin', exe_name)
	log_path := os.join_path(store, 'update.log')

	// a first run has no store yet, for its log or its lock
	os.mkdir_all(store) or {}
	log_line(log_path, '--- vlang graph update start ---')
	lock_dir := os.join_path(store, lock_name)
	if !acquire_lock(log_path, lock_dir) {
		log_line(log_path, '--- done ---')
		return
	}
	remove_build_leftovers(os.join_path(root, 'bin'))

	// graphify first: a change to it must be built before it extracts
	if !opts.no_pull {
		pull_graphify(log_path, root)
	}

	// pull first: the pull can bring V parser changes the rebuild must see
	if opts.commit != '' {
		log_line(log_path, 'moving to ${opts.commit}...')
		before := head_of(vlang)
		msg := move_to_commit(vlang, opts.commit) or {
			fail(log_path, err.msg())
			return
		}
		log_line(log_path, msg)
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
	}

	if !opts.no_build {
		rebuild_if_stale(log_path, root, graphify_exe) or {
			fail(log_path, err.msg())
			return
		}
	}

	set_vroot(log_path)

	// a pull or a rebuild shows as a graph out of date
	exe_hash := sha256.hexhash(os.read_file(graphify_exe) or { '' })
	vlang_head := head_of(vlang)
	vlang_graph := store_project_dir(store, vlang)
	why := if opts.force { 'forced' } else { graph_out_of_date(vlang_graph, vlang_head, exe_hash, '') }
	if why == '' {
		log_line(log_path, 'The graph is up to date. Skipping extract.')
	} else {
		log_line(log_path, 'extracting graph (${why})...')
		start := time.now()
		result := os.exec([graphify_exe, 'extract', vlang, '--store', store])
		log_output(log_path, result.output)
		if result.exit_code != 0 {
			fail(log_path, 'extract failed')
		}
		elapsed_s := int(time.now().unix() - start.unix())
		log_line(log_path, 'done in ${elapsed_s}s')
	}
	mut failed := []string{}
	for project in config.projects {
		extract_project(log_path, graphify_exe, project, store, exe_hash, vlang_head, opts.force) or {
			log_line(log_path, 'ERROR: ${err}')
			failed << project
		}
	}
	if failed.len > 0 {
		fail(log_path, 'project extract failed: ${failed.join(', ')}')
	}
	log_line(log_path, '--- done ---')
	release_lock(lock_dir)
}

// extract_project extracts one project into the store, as `extract --store` names
// it, when its graph is out of date (graph_out_of_date) or `force` is set.
fn extract_project(log_path string, exe string, project string, store string, exe_hash string, vlang_head string, force bool) ! {
	if !os.is_dir(project) {
		return error('${project}: no such directory')
	}
	out := store_project_dir(store, project)
	why := if force {
		'forced'
	} else {
		graph_out_of_date(out, head_of(project), exe_hash, vlang_head)
	}
	if why == '' {
		log_line(log_path, '${project}: up to date')
		return
	}
	log_line(log_path, 'extracting ${project} (${why})...')
	result := os.exec([exe, 'extract', project, '--store', store])
	log_output(log_path, result.output)
	if result.exit_code != 0 {
		return error('${project}: extract failed')
	}
}

// store_project_dir is the directory `extract --store` writes the graph of the
// project at `root` to, as graphify.store_project_dir picks it: the one whose
// manifest names that root, else one named after it, with `-2` and so on after it
// when another project of that name has it.
fn store_project_dir(store string, root string) string {
	real := os.real_path(root)
	for name in os.ls(store) or { []string{} } {
		text := os.read_file(os.join_path(store, name, 'manifest.json')) or { continue }
		m := json2.decode[GraphManifest](text) or { continue }
		if m.root != '' && os.real_path(m.root) == real {
			return os.join_path(store, name)
		}
	}
	stem := os.base(real)
	mut out := os.join_path(store, stem)
	for n := 2; os.exists(os.join_path(out, 'manifest.json')); n++ {
		out = os.join_path(store, '${stem}-${n}')
	}
	return out
}

// graph_out_of_date says why the graph in `dir` is out of date, or '' when it isn't:
// it doesn't exist, or its manifest says it was extracted from another commit than
// `head`, by another graphify than the one hashing to `exe_hash`, or, given
// `vlib_head`, from a vlib at another commit than that, or from a module under
// VMODULES at another commit than its clone is at now. A commit that can't be told
// ('', not a git checkout) is not compared.
fn graph_out_of_date(dir string, head string, exe_hash string, vlib_head string) string {
	if !os.exists(os.join_path(dir, 'graph.json')) {
		return 'no graph yet'
	}
	m := json2.decode[GraphManifest](os.read_file(os.join_path(dir, 'manifest.json')) or {
		''
	}) or { return 'no manifest' }
	if head != '' && m.source_commit != head {
		return 'its commit moved'
	}
	if exe_hash != '' && m.binary_hash != exe_hash {
		return 'graphify was rebuilt'
	}
	// extracted when no V tree was found (set_vroot), and one is now
	if m.library.len == 0 && os.getenv('VROOT') != '' {
		return 'it was extracted without its libraries'
	}
	if vlib_head != '' {
		for l in m.library {
			if l.label == 'vlib' && l.commit != '' && l.commit != vlib_head {
				return 'vlib moved'
			}
		}
	}
	for l in m.library {
		for mod in l.modules {
			if mod.commit != '' && mod.commit != head_of(os.join_path(l.root, mod.name)) {
				return '${mod.name} moved'
			}
		}
	}
	return ''
}
