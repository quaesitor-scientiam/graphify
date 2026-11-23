module main

import os
import sync
import time
import net.unix
import x.json2
import graphify

fn test_a_windows_file_uri_has_no_slash_before_its_drive() {
	$if windows {
		assert dir_of_uri('file:///C:/Windows') or { '' } == 'C:/Windows'
	} $else {
		assert dir_of_uri('file:///tmp') or { '' } == '/tmp'
	}
}

fn test_the_session_dir_is_the_directory_a_root_names() {
	dir := os.join_path(os.temp_dir(), 'graphify roots ${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// as Claude Code sends it, for a session in a worktree: a space percent-encoded
	assert slashed(dir_of_uri(file_uri(dir)) or { '' }) == slashed(dir)
	// a root that is no local directory
	assert dir_of_uri('https://example.com/x') == none
	assert dir_of_uri('file:///no/such/dir/here') == none
}

fn test_a_client_has_roots_when_its_capabilities_say_so() {
	assert caps_have_roots('{"roots":{"listChanged":true}}')
	assert caps_have_roots('{"roots":{}}')
	assert !caps_have_roots('{"sampling":{}}')
	assert !caps_have_roots('')
}

// file_uri is the `file://` URI of the directory `dir`, as a client sends it: with
// forward slashes, a slash before a Windows drive, and a space percent-encoded.
fn file_uri(dir string) string {
	path := dir.replace('\\', '/').replace(' ', '%20')
	return if path.starts_with('/') { 'file://${path}' } else { 'file:///${path}' }
}

// slashed is `path` with forward slashes, which dir_of_uri gives on Windows.
fn slashed(path string) string {
	return path.replace('\\', '/')
}

fn test_a_daemon_socket_too_long_for_a_unix_socket_goes_under_tmp() {
	old := os.getenv('GRAPHIFY_DAEMON_DIR')
	defer {
		os.setenv('GRAPHIFY_DAEMON_DIR', old, true)
	}
	os.setenv('GRAPHIFY_DAEMON_DIR', '/tmp/short', true)
	assert daemon_dir() == '/tmp/short'
	os.setenv('GRAPHIFY_DAEMON_DIR', '/tmp/' + 'x'.repeat(90), true)
	// Windows has no /tmp: its temporary directory
	short := if os.user_os() == 'windows' {
		os.join_path(os.temp_dir(), 'graphify')
	} else {
		os.join_path('/tmp', 'graphify-${os.getuid()}')
	}
	assert daemon_dir() == short
}

fn test_a_daemon_running_from_a_copy_answers_for_the_binary_it_was_copied_from() {
	old := os.getenv('GRAPHIFY_MCP_EXE')
	defer {
		os.setenv('GRAPHIFY_MCP_EXE', old, true)
	}
	os.setenv('GRAPHIFY_MCP_EXE', '', true)
	assert server_exe() == os.executable()
	a := Config{
		graph_path: '/g/vlang/graph.json'
	}
	here := daemon_name(a)
	// a copy, named after what it was copied from, is named as the server that copied it
	os.setenv('GRAPHIFY_MCP_EXE', os.executable(), true)
	assert server_exe() == os.executable()
	assert daemon_name(a) == here
}

fn test_the_daemon_is_named_after_what_it_serves() {
	a := Config{
		graph_path: '/g/vlang/graph.json'
	}
	b := Config{
		graph_path:   '/g/vlang/graph.json'
		projects_dir: '/g'
	}
	assert daemon_name(a) == daemon_name(a)
	assert daemon_name(a) != daemon_name(b)
	assert daemon_name(a).starts_with('mcp-') && daemon_name(a).len == 20
}

// a directory of daemon files for the tests below, with a path short enough for a Unix
// socket's: under /tmp, since the temporary directory on macOS is too long for one
fn daemon_files_dir(label string) string {
	root := if os.user_os() == 'windows' { os.temp_dir() } else { '/tmp' }
	dir := os.join_path(root, 'gfd${label}${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

// touch writes `name` in `dir`, last written `age` seconds ago.
fn touch(dir string, name string, age i64) {
	path := os.join_path(dir, name)
	os.write_file(path, 'x') or { panic(err) }
	then := time.now().unix() - age
	os.utime(path, then, then) or { panic(err) }
}

fn files_in(dir string) []string {
	mut names := os.ls(dir) or { panic(err) }
	names.sort()
	return names
}

// A daemon that exits on its own removes its socket and nothing else: its log, and on
// Windows the copy of the binary it ran from, stay behind. The next daemon to start
// clears them away.
fn test_a_daemon_that_has_exited_leaves_no_log_or_copy_behind() {
	dir := daemon_files_dir('gone')
	defer {
		os.rmdir_all(dir) or {}
	}
	// named as a real one is, in lower-case hex digits
	touch(dir, 'mcp-931cec369e831a42.log', 3600)
	touch(dir, 'mcp-931cec369e831a42.exe', 3600)
	touch(dir, 'mcp-0a1b2c3d4e5f6789.log', 3600)
	touch(dir, 'mcp-0a1b2c3d4e5f6789.exe', 3600)
	remove_dead_daemons(dir, 'mcp-2222222222222222')
	assert files_in(dir) == []
}

// ...but not those of a daemon that is only starting: it has made its log, and has not
// yet listened.
fn test_a_daemon_that_is_still_starting_keeps_its_log_and_copy() {
	dir := daemon_files_dir('new')
	defer {
		os.rmdir_all(dir) or {}
	}
	touch(dir, 'mcp-1111111111111111.log', 0)
	touch(dir, 'mcp-1111111111111111.exe', 3600)
	// a copy made for a daemon not yet started has no log at all, however old its file
	touch(dir, 'mcp-3333333333333333.exe', 3600)
	remove_dead_daemons(dir, 'mcp-2222222222222222')
	assert files_in(dir) == ['mcp-1111111111111111.exe', 'mcp-1111111111111111.log',
		'mcp-3333333333333333.exe']
}

// GRAPHIFY_DAEMON_DIR can be a directory that other things write to: what the sweep
// removes has the exact name of a daemon's file (`mcp-` and 16 hex digits, then `.sock`,
// `.log` or `.exe`), and no other file is its business.
fn test_files_that_are_no_daemons_are_left_alone() {
	dir := daemon_files_dir('else')
	defer {
		os.rmdir_all(dir) or {}
	}
	touch(dir, 'mcp-server.log', 3600)
	touch(dir, 'mcp-server.exe', 3600)
	touch(dir, 'mcp-11111111111111111.log', 3600)
	touch(dir, 'mcp-111111111111111.log', 3600)
	touch(dir, 'mcp-ABCDEFABCDEFABCD.log', 3600)
	touch(dir, 'mcp-4444444444444444.bak', 3600)
	touch(dir, 'mcp-4444444444444444', 3600)
	before := files_in(dir)
	remove_dead_daemons(dir, 'mcp-2222222222222222')
	assert files_in(dir) == before
}

// A killed daemon leaves its socket, which nothing listens at: that one goes with its
// log and copy, however recently it was written.
fn test_a_killed_daemons_socket_log_and_copy_are_removed() {
	dir := daemon_files_dir('dead')
	defer {
		os.rmdir_all(dir) or {}
	}
	touch(dir, 'mcp-1111111111111111.sock', 0)
	touch(dir, 'mcp-1111111111111111.log', 0)
	touch(dir, 'mcp-1111111111111111.exe', 0)
	remove_dead_daemons(dir, 'mcp-2222222222222222')
	assert files_in(dir) == []
}

fn test_a_running_daemon_and_the_one_clearing_up_are_left_alone() {
	dir := daemon_files_dir('live')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut listener := unix.listen_stream(os.join_path(dir, 'mcp-1111111111111111.sock')) or {
		panic(err)
	}
	defer {
		listener.close() or {}
	}
	touch(dir, 'mcp-1111111111111111.log', 3600)
	touch(dir, 'mcp-1111111111111111.exe', 3600)
	// the daemon doing the clearing has its log and copy, and no socket until it listens
	touch(dir, 'mcp-2222222222222222.log', 3600)
	touch(dir, 'mcp-2222222222222222.exe', 3600)
	// and a file that is no daemon's
	touch(dir, 'notes.log', 3600)
	remove_dead_daemons(dir, 'mcp-2222222222222222')
	assert files_in(dir) == ['mcp-1111111111111111.exe', 'mcp-1111111111111111.log',
		'mcp-1111111111111111.sock', 'mcp-2222222222222222.exe', 'mcp-2222222222222222.log', 'notes.log']
}

// check_daemon is a daemon that has just been used, as run_daemon makes one, with the
// idle time GRAPHIFY_DAEMON_IDLE names left alone for the length of the test.
fn check_daemon(used_ago i64) &Daemon {
	return &Daemon{
		cfg:     Config{
			graph_path: os.join_path(os.temp_dir(), 'graphify no such graph.json')
		}
		used_at: time.now().unix() - used_ago
	}
}

// A daemon that has gone down on its own since the running one started would otherwise
// leave its log and copy until the next daemon starts, a rebuild away: the running one
// clears them away when it looks whether it is done, at least once a minute.
fn test_a_running_daemon_clears_away_one_that_exits_while_it_runs() {
	dir := daemon_files_dir('run')
	defer {
		os.rmdir_all(dir) or {}
	}
	old := os.getenv('GRAPHIFY_DAEMON_IDLE')
	defer {
		os.setenv('GRAPHIFY_DAEMON_IDLE', old, true)
	}
	os.setenv('GRAPHIFY_DAEMON_IDLE', '900', true)
	exe := os.executable()
	mut d := check_daemon(0)
	touch(dir, 'mcp-1111111111111111.log', 3600)
	touch(dir, 'mcp-1111111111111111.exe', 3600)
	// its own files, which a running daemon has all of
	touch(dir, 'mcp-2222222222222222.log', 3600)
	touch(dir, 'mcp-2222222222222222.exe', 3600)
	assert !d.check(dir, 'mcp-2222222222222222', exe, file_stamp(exe))
	assert files_in(dir) == ['mcp-2222222222222222.exe', 'mcp-2222222222222222.log']
}

// ...and reports whether it is done all the same, which is what ends its loop.
fn test_a_daemon_that_has_been_idle_is_done_when_it_checks() {
	dir := daemon_files_dir('idle')
	defer {
		os.rmdir_all(dir) or {}
	}
	old := os.getenv('GRAPHIFY_DAEMON_IDLE')
	defer {
		os.setenv('GRAPHIFY_DAEMON_IDLE', old, true)
	}
	os.setenv('GRAPHIFY_DAEMON_IDLE', '900', true)
	exe := os.executable()
	mut d := check_daemon(901)
	assert d.check(dir, 'mcp-2222222222222222', exe, file_stamp(exe))
	// the binary rebuilt since it started, with no server connected, ends it as well
	mut fresh := check_daemon(0)
	assert fresh.check(dir, 'mcp-2222222222222222', exe, 'a stamp the binary no longer has')
}

// A server that connects to a daemon counts as a session to it: the connection lasts
// for as long as the daemon takes to see it closed, and restarts its time to idle.
// Looking at the other daemons' sockets once a minute would hold each of two daemons up
// for ever, so a running daemon leaves the daemons that have a socket alone.
fn test_a_running_daemon_does_not_connect_to_the_daemons_that_listen() {
	dir := daemon_files_dir('probe')
	defer {
		os.rmdir_all(dir) or {}
	}
	old := os.getenv('GRAPHIFY_DAEMON_IDLE')
	defer {
		os.setenv('GRAPHIFY_DAEMON_IDLE', old, true)
	}
	os.setenv('GRAPHIFY_DAEMON_IDLE', '900', true)
	mut listener := unix.listen_stream(os.join_path(dir, 'mcp-1111111111111111.sock')) or {
		panic(err)
	}
	defer {
		listener.close() or {}
	}
	touch(dir, 'mcp-1111111111111111.log', 3600)
	exe := os.executable()
	mut d := check_daemon(0)
	assert !d.check(dir, 'mcp-2222222222222222', exe, file_stamp(exe))
	// a connection would be waiting to be accepted
	listener.set_accept_timeout(time.millisecond * 300)
	mut seen := true
	listener.wait_for_accept() or { seen = false }
	assert !seen
	assert files_in(dir) == ['mcp-1111111111111111.log', 'mcp-1111111111111111.sock']
}

// The daemon answers the sessions of two directories from one base graph, read once.
fn test_the_daemon_shares_one_base_graph_between_sessions() {
	dir := os.join_path(os.temp_dir(), 'graphify daemon ${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'src')
	os.mkdir_all(os.join_path(src, 'lib')) or { panic(err) }
	os.write_file(os.join_path(src, 'lib', 'lib.v'), 'module lib\n\npub fn shared_helper() int {\n\treturn 1\n}\n') or {
		panic(err)
	}
	out := os.join_path(dir, 'out')
	g := graphify.build_graph(graphify.Options{ root: src })
	graphify.write_bundle(g, out, graphify.ExtractReport{}) or { panic(err) }
	one := os.join_path(dir, 'one')
	two := os.join_path(dir, 'two')
	os.mkdir_all(one) or { panic(err) }
	os.mkdir_all(two) or { panic(err) }
	mut d := &Daemon{
		cfg: Config{
			graph_path: os.join_path(out, 'graph.json')
		}
	}
	for session in [one, two] {
		request := json2.encode({
			'dir':       json2.Any(session)
			'name':      json2.Any('get_node')
			'arguments': json2.Any('{"node":"shared_helper"}')
		})
		text, is_error := d.answer(request)
		assert !is_error
		assert text.contains('fn shared_helper  (lib/lib.v:3)'), text
	}
	assert d.apps.len == 2
	assert d.bases.graphs.len == 1
	// a request it can't read is an error, not a crash
	_, bad := d.answer('not json')
	assert bad
}

// shortest_path lists 5 chains of calls, or the `routes` it is given, up to 50.
fn test_shortest_path_lists_as_many_routes_as_it_is_asked_for() {
	dir := os.join_path(os.temp_dir(), 'graphify routes ${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'src')
	os.mkdir_all(src) or { panic(err) }
	mut code := 'module m\n\npub fn goal() {}\n\npub fn start() {\n'
	for i in 0 .. 7 {
		code += '\tvia_${i}()\n'
	}
	code += '}\n'
	for i in 0 .. 7 {
		code += '\nfn via_${i}() {\n\tgoal()\n}\n'
	}
	os.write_file(os.join_path(src, 'm.v'), code) or { panic(err) }
	g := graphify.build_graph(graphify.Options{ root: src })
	served := Served{
		g:       g
		project: g
	}
	mut args := {
		'a': json2.Any('start')
		'b': json2.Any('goal')
	}
	text, is_error := tool_text('shortest_path', args, served)
	assert !is_error
	assert text.contains('5. start') && !text.contains('6. start'), text
	args['routes'] = json2.Any(7)
	all, _ := tool_text('shortest_path', args, served)
	assert all.contains('7. start') && !all.contains('the 5 shortest'), all
	args['routes'] = json2.Any(0)
	one, _ := tool_text('shortest_path', args, served)
	assert one.contains('the 1 shortest') && !one.contains('2. start'), one
}

fn test_notes_are_joined_as_sentences() {
	// a worktree's note has no full stop, and ran on into the stale note after it
	assert join_notes('it is being extracted again', 'the project: out of date.') == 'it is being extracted again. The project: out of date.'
	assert join_notes('', 'out of date.') == 'out of date.'
	assert sentences(['a', '', 'b.']) == 'a. B.'
}

fn test_a_lookup_that_finds_nothing_is_told_from_an_answer() {
	assert missed('get_node', 'no symbol matches: f')
	assert missed('get_body', 'no symbol matches: f')
	assert missed('query_graph', 'no symbols match: f')
	assert missed('get_neighbors', no_neighbors)
	assert missed('shortest_path', no_path)
	assert !missed('get_node', 'fn f  (a.v:3)')
	assert !missed('overview', 'no symbol matches: f')
}

fn test_a_lookup_waits_for_the_extract_running_and_leaves_its_outcome() {
	mut app := &App{
		wt: Worktree{
			done: chan string{cap: 1}
		}
	}
	app.wt.running = true
	assert !app.wait_extract(50 * time.millisecond)
	app.wt.done <- ''
	assert app.wait_extract(50 * time.millisecond)
	// poll still takes it, so that refresh serves the graph it published
	assert app.wt.poll() && !app.wt.running
	// one taken by another call while this one waited is done as well
	app.wt.running = false
	assert app.wait_extract(50 * time.millisecond)
}

fn test_a_lookup_waiting_for_the_extract_lets_the_daemon_answer_other_sessions() {
	mut mu := sync.new_mutex()
	mut app := &App{
		wt:   Worktree{
			done: chan string{cap: 1}
		}
		held: mu
	}
	app.wt.running = true
	// another session's tool call, which takes the daemon's lock and ends the extract
	mu.lock()
	other := spawn fn [mut mu, app] () {
		mu.lock()
		app.wt.done <- ''
		mu.unlock()
	}()
	started := time.now()
	assert app.wait_extract(5 * time.second)
	assert time.since(started) < 2 * time.second
	mu.unlock()
	other.wait()
}

fn test_a_lookup_waits_for_the_extract_when_the_graph_served_is_from_before_an_update() {
	dir := os.join_path(os.temp_dir(), 'graphify stale worktree ${os.getpid()}')
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'src')
	os.mkdir_all(os.join_path(src, 'lib')) or { panic(err) }
	lib := os.join_path(src, 'lib', 'lib.v')
	os.write_file(lib, 'module lib\n\npub fn helper() int {\n\treturn 1\n}\n') or { panic(err) }
	// the worktree's graph as an earlier graphify left it
	store := os.join_path(dir, 'store')
	graphify.write_bundle(graphify.build_graph(graphify.Options{ root: src }), store, graphify.ExtractReport{}) or {
		panic(err)
	}
	path := os.join_path(store, 'graph.json')
	mut app := new_app(Config{ graph_path: path }, dir, &BaseCache{}) or { panic(err) }
	app.wt = Worktree{
		graph:    path
		root:     src
		path:     path
		ready:    true
		running:  true
		stale:    true
		done:     chan string{cap: 1}
	}
	// the extract publishes the worktree's graph as it is now, with helper moved down
	os.write_file(lib, 'module lib\n\nfn first() {}\n\npub fn helper() int {\n\treturn 1\n}\n') or {
		panic(err)
	}
	// and took the worktree's state as it started, as Worktree.extract does, so that
	// refresh, which looks again after it (always, with state_at long ago), finds
	// nothing changed: with no state, a run slower than two seconds extracted again
	app.wt.state = graphify.worktree_state(src)
	app.wt.state_at = 0
	done := app.wt.done
	extract := spawn fn [src, store, done] () {
		time.sleep(200 * time.millisecond)
		graphify.write_bundle(graphify.build_graph(graphify.Options{ root: src }), store,
			graphify.ExtractReport{}) or { panic(err) }
		done <- ''
	}()
	text, is_error := app.answer('get_node', '{"node":"helper"}')
	extract.wait()
	assert !is_error
	// found in the old graph too, but answered from the new one
	assert text.contains('fn helper  (lib/lib.v:5)'), text
	assert !text.contains('extracted again'), text
	assert !app.wt.stale && !app.wt.running
}

fn test_a_graph_from_before_an_update_is_waited_for_once() {
	mut app := &App{
		wt: Worktree{
			running: true
			stale:   true
			done:    chan string{cap: 1}
		}
	}
	// the extract does not end in time: answered from the graph there is, and the
	// next lookups do not wait again
	app.wait_stale(50 * time.millisecond)
	assert !app.wt.stale && app.wt.running
	started := time.now()
	app.wait_stale(5 * time.second)
	assert time.since(started) < time.second
}

// folder_fixture is a directory with a project `main` in git, with the graph of it in
// `out`, and a worktree of it, `wt`, whose `helper` is another: `from_main` and
// `from_wt` tell which of the two a body came from. `git` has a command run.
struct FolderFixture {
	dir  string
	main string
	wt   string
	cfg  Config
}

fn fixture_git(dir string, args ...string) {
	mut cmd := ['git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c',
		'commit.gpgsign=false', '-c', 'core.autocrlf=false']
	cmd << args
	res := os.exec(cmd)
	assert res.exit_code == 0, res.output
}

fn folder_fixture(label string) FolderFixture {
	dir := os.join_path(os.real_path(os.temp_dir()), 'gf folder ${label} ${os.getpid()}')
	os.rmdir_all(dir) or {}
	main_dir := os.join_path(dir, 'main')
	os.mkdir_all(os.join_path(main_dir, 'lib')) or { panic(err) }
	lib := os.join_path('lib', 'lib.v')
	os.write_file(os.join_path(main_dir, lib), 'module lib\n\npub fn helper() string {\n\treturn "from_main"\n}\n') or {
		panic(err)
	}
	fixture_git(main_dir, 'init', '-q')
	fixture_git(main_dir, 'add', '.')
	fixture_git(main_dir, 'commit', '-q', '-m', 'one')
	out := os.join_path(dir, 'out')
	graphify.write_bundle(graphify.build_graph(graphify.Options{ root: main_dir }), out,
		graphify.ExtractReport{}) or { panic(err) }
	wt := os.join_path(main_dir, '.claude', 'wt')
	fixture_git(main_dir, 'worktree', 'add', '-q', '-b', 'b', wt)
	os.write_file(os.join_path(wt, lib), 'module lib\n\npub fn helper() string {\n\treturn "from_wt"\n}\n') or {
		panic(err)
	}
	return FolderFixture{
		dir:  dir
		main: main_dir
		wt:   wt
		cfg:  Config{
			graph_path: os.join_path(out, 'graph.json')
			base_root:  main_dir
		}
	}
}

fn body_args(folder string) string {
	return json2.encode({
		'node':   json2.Any('helper')
		'folder': json2.Any(folder)
	})
}

// with_cli builds the graphify CLI once, for the servers of these tests to extract
// with, has them keep the worktrees' stores in `stores`, and runs `f`.
fn with_cli(cli_dir string, stores string, f fn ()) {
	old_exe := os.getenv('GRAPHIFY_MCP_EXE')
	old_stores := os.getenv('GRAPHIFY_WORKTREE_STORES')
	defer {
		os.setenv('GRAPHIFY_MCP_EXE', old_exe, true)
		os.setenv('GRAPHIFY_WORKTREE_STORES', old_stores, true)
	}
	os.setenv('GRAPHIFY_MCP_EXE', os.join_path(cli_dir, 'graphify-mcp'), true)
	os.setenv('GRAPHIFY_WORKTREE_STORES', stores, true)
	f()
}

fn build_cli() string {
	dir := os.join_path(os.temp_dir(), 'gf folder cli ${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	exe := graphify.cli_beside(os.join_path(dir, 'graphify-mcp'))
	if !os.exists(exe) {
		res := os.exec([@VEXE, '-o', exe, os.join_path(@DIR, '..', 'cli')])
		assert res.exit_code == 0, res.output
	}
	return dir
}

fn testsuite_end() {
	os.rmdir_all(os.join_path(os.temp_dir(), 'gf folder cli ${os.getpid()}')) or {}
}

fn test_a_folder_is_one_full_local_path() {
	mut all_bad := ['', ' ', 'lib', '..\\lib', 'C:lib', 'C:', '\\lib', '\\\\server\\share', '\\\\?\\C:\\lib',
		'1:\\lib', 'ab\\lib', '\\\\.\\C:\\lib', '\\\\?\\UNC\\server\\share', '\\\\?\\Volume{b75e}\\x', 'NUL']
	// each form of Microsoft's "File path formats" but the drive and root one
	if os.user_os() == 'windows' {
		all_bad << ['/lib', '//server/share', '//?/C:/lib', '/\\server\\share']
	}
	for bad in all_bad {
		folder_of(body_args(bad)) or {
			assert err.msg().contains('folder'), err.msg()
			continue
		}
		assert false, 'accepted `${bad}`'
	}
	good := if os.user_os() == 'windows' { ['C:\\lib', 'c:/lib'] } else { ['/lib'] }
	for g in good {
		assert folder_of(body_args(g)) or { panic(err) } == g
	}
	// without one, and with one that is no string
	assert folder_of('{"node":"x"}') or { panic(err) } == ''
	assert folder_of('{"folder":null}') or { panic(err) } == ''
	assert folder_of('') or { panic(err) } == ''
	mut said := ''
	folder_of('{"folder":7}') or { said = err.msg() }
	assert said.contains('not a string'), said
}

fn test_a_folder_is_covered_by_the_root_of_the_graph_that_holds_it() {
	fx := folder_fixture('cover')
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	assert covered_root(fx.cfg, fx.main) or { panic(err) } == fx.main
	assert covered_root(fx.cfg, os.join_path(fx.main, 'lib')) or { panic(err) } == fx.main
	// a worktree, and a folder in it, are one
	assert covered_root(fx.cfg, fx.wt) or { panic(err) } == fx.wt
	assert covered_root(fx.cfg, os.join_path(fx.wt, 'lib')) or { panic(err) } == fx.wt
	$if windows {
		assert covered_root(fx.cfg, fx.wt.to_upper().replace('\\', '/') + '/') or { panic(err) } == fx.wt
	}
	// a project of the store, deeper than the base, and its worktree
	projects := os.join_path(fx.dir, 'projects')
	graphify.write_bundle(graphify.build_graph(graphify.Options{
		root: os.join_path(fx.main, 'lib')
	}), os.join_path(projects, 'lib'), graphify.ExtractReport{}) or { panic(err) }
	stored := Config{
		...fx.cfg
		projects_dir: projects
	}
	assert covered_root(stored, os.join_path(fx.main, 'lib')) or { panic(err) } == os.join_path(fx.main,
		'lib')
	assert covered_root(stored, os.join_path(fx.wt, 'lib')) or { panic(err) } == os.join_path(fx.wt,
		'lib')
	assert covered_root(stored, fx.wt) or { panic(err) } == fx.wt
	// refused: in none, not there, a file, a repository of its own in the checkout,
	// a worktree git can't tell of, and any of a shared graph's server
	other := os.join_path(fx.dir, 'other')
	nested := os.join_path(fx.main, 'nested')
	broken := os.join_path(fx.main, 'broken')
	os.mkdir_all(other) or { panic(err) }
	os.mkdir_all(os.join_path(nested, 'sub')) or { panic(err) }
	os.mkdir_all(broken) or { panic(err) }
	fixture_git(nested, 'init', '-q')
	os.write_file(os.join_path(broken, '.git'), 'gitdir: /no/such/dir\n') or { panic(err) }
	for bad in [other, os.join_path(fx.dir, 'gone'), os.join_path(fx.main, 'lib', 'lib.v'), nested,
		os.join_path(nested, 'sub'), broken] {
		covered_root(fx.cfg, bad) or {
			// it says which roots there are
			assert err.msg().contains(fx.main), err.msg()
			continue
		}
		assert false, 'covered ${bad}'
	}
	// a folder git lists no more, as one left when its worktree was removed, is the
	// checkout's, and the answer says so
	left := os.join_path(fx.main, '.claude', 'left')
	os.mkdir_all(left) or { panic(err) }
	assert covered_root(fx.cfg, left) or { panic(err) } == fx.main
	// a project whose graph is not there is not one of the roots
	os.mkdir_all(os.join_path(projects, 'empty')) or { panic(err) }
	manifest := os.read_file(os.join_path(projects, 'lib', 'manifest.json')) or { panic(err) }
	os.write_file(os.join_path(projects, 'empty', 'manifest.json'), manifest) or { panic(err) }
	os.rm(os.join_path(projects, 'lib', 'graph.json')) or { panic(err) }
	assert roots_text(stored).ends_with(': ${fx.main}'), roots_text(stored)
	// each root once, whatever the order they are listed in, and none that is empty
	for name, root in {
		'a':     '/root/a'
		'b':     '/root/b'
		'c':     '/root/c'
		'again': fx.main
		'none':  ''
	} {
		os.mkdir_all(os.join_path(projects, name)) or { panic(err) }
		os.write_file(os.join_path(projects, name, 'manifest.json'), '{"root":"${root.replace('\\',
			'\\\\')}"}') or { panic(err) }
		os.write_file(os.join_path(projects, name, 'graph.json'), '{}') or { panic(err) }
	}
	mut listed := roots_text(stored).all_after('worktrees: ').split(', ')
	listed.sort()
	mut all_roots := ['/root/a', '/root/b', '/root/c', fx.main]
	all_roots.sort()
	assert listed == all_roots
	mut based := roots_text(Config{ projects_dir: projects }).all_after('worktrees: ').split(', ')
	based.sort()
	assert based == all_roots
	// a server whose graph says no root covers nothing
	if _ := covered_root(Config{ graph_path: fx.cfg.graph_path }, other) {
		assert false, 'covered with no root'
	}
	if _ := covered_root(Config{ ...fx.cfg, src_dir: fx.main }, fx.main) {
		assert false, 'covered by a shared graph'
	}
}

fn test_a_call_that_names_a_worktree_is_answered_from_it() {
	fx := folder_fixture('named')
	cli := build_cli()
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	with_cli(cli, os.join_path(fx.dir, 'stores'), fn [fx] () {
		mut d := &Daemon{
			cfg: fx.cfg
		}
		// the first call waits for the extract, and is never the checkout's
		text, is_error := d.call(fx.main, 'get_body', body_args(fx.wt))
		assert !is_error, text
		assert text.contains('from_wt') && !text.contains('from_main'), text
		assert text.starts_with('(folder: this is the graph of ${fx.wt})'), text
		// a folder in it is the same App, so one extract at a time writes its store
		in_it, bad := d.call(fx.main, 'get_body', body_args(os.join_path(fx.wt, 'lib')))
		assert !bad && in_it.contains('from_wt'), in_it
		assert d.apps.len == 1
		// the session's own folder is as it was
		own, _ := d.call(fx.main, 'get_body', '{"node":"helper"}')
		assert own.contains('from_main') && !own.contains('(folder:'), own
		named, _ := d.call(fx.wt, 'get_body', body_args(fx.main))
		assert named.contains('from_main') && named.contains('(folder: this is the graph of ${fx.main})'), named
		assert d.apps.len == 2
		// an edit is waited for as the first graph is
		os.write_file(os.join_path(fx.wt, 'lib', 'lib.v'), 'module lib\n\npub fn helper() string {\n\treturn "edited_wt"\n}\n') or {
			panic(err)
		}
		time.sleep(2100 * time.millisecond)
		edited, _ := d.call(fx.main, 'get_body', body_args(fx.wt))
		assert edited.contains('edited_wt') && !edited.contains('extracted again'), edited
		// a bad folder is an error of the call, and makes no App
		_, refused := d.call(fx.main, 'get_body', body_args(fx.dir))
		assert refused && d.apps.len == 2
		// each lets the others go on while it waits, and one in use is kept, with its base
		d.drop_idle()
		assert d.apps.len == 2
		for _, app in d.apps {
			assert voidptr(app.held) == voidptr(d.mu)
			assert '${app.base_path}\n' in d.bases.graphs
		}
		// and each is dropped once idle
		for _, mut app in d.apps {
			app.used_at = 0
		}
		d.drop_idle()
		assert d.apps.len == 0
	})
}

fn test_a_server_without_a_daemon_answers_for_a_folder() {
	fx := folder_fixture('alone')
	cli := build_cli()
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	with_cli(cli, os.join_path(fx.dir, 'stores'), fn [fx] () {
		mut s := &Session{
			cfg:  fx.cfg
			here: fx.main
		}
		text, is_error := s.answer('get_body', body_args(fx.wt))
		assert !is_error && text.contains('from_wt'), text
		own, _ := s.answer('get_body', '{"node":"helper"}')
		assert own.contains('from_main') && !own.contains('(folder:'), own
		assert s.here == fx.main && s.folders.apps.len == 1
		kept := voidptr(s.folders)
		s.answer('get_body', body_args(fx.wt))
		assert voidptr(s.folders) == kept
		// one left idle goes when the next is named
		for _, mut app in s.folders.apps {
			app.used_at = 0
		}
		main_text, _ := s.answer('get_body', body_args(fx.main))
		assert main_text.contains('from_main'), main_text
		assert s.folders.apps.keys() == [fx.main]
	})
}

fn test_a_named_worktree_without_its_own_graph_is_an_error() {
	fx := folder_fixture('nocli')
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	// no graphify to extract it with
	with_cli(os.join_path(fx.dir, 'no cli here'), os.join_path(fx.dir, 'stores'), fn [fx] () {
		mut d := &Daemon{
			cfg: fx.cfg
		}
		text, is_error := d.call(fx.main, 'get_body', body_args(fx.wt))
		assert is_error && !text.contains('from_main'), text
		assert text.contains(fx.wt), text
	})
	// an extract that failed, one that is not done, and one that could not be done again
	for ready in [false, true] {
		mut app := new_app(fx.cfg, fx.main, &BaseCache{}) or { panic(err) }
		app.wt = Worktree{
			root:     fx.main
			state:    graphify.worktree_state(fx.main)
			state_at: time.now().unix()
			ready:    ready
			failed:   'it broke'
		}
		text, is_error := app.answer_for(fx.main, 100 * time.millisecond, 'get_body', body_args(fx.main))
		assert is_error && text.contains('it broke'), text
		app.wt.failed = ''
		app.wt.running = true
		app.wt.done = chan string{cap: 1}
		slow, not_ready := app.answer_for(fx.main, 100 * time.millisecond, 'get_body', body_args(fx.main))
		assert not_ready && slow.contains('call again'), slow
	}
}

fn test_a_change_made_while_a_named_worktree_is_extracted_is_waited_for() {
	fx := folder_fixture('during')
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	mut app := new_app(fx.cfg, fx.main, &BaseCache{}) or { panic(err) }
	// an extract that is done, of the worktree before its last change; the cli it
	// would extract again with is not there, so that extract fails
	app.wt = Worktree{
		graph:    fx.cfg.graph_path
		root:     fx.main
		path:     fx.cfg.graph_path
		cli:      os.join_path(fx.dir, 'no cli')
		ready:    true
		running:  true
		state:    'before the change'
		done:     chan string{cap: 1}
	}
	app.wt.done <- ''
	text, is_error := app.answer_for(fx.main, 0, 'get_body', body_args(fx.main))
	assert is_error && !text.contains('from_main'), text
}

fn test_a_named_folder_has_the_notes_and_errors_of_its_graph() {
	fx := folder_fixture('notes')
	defer {
		os.rmdir_all(fx.dir) or {}
	}
	mut app := new_app(fx.cfg, fx.main, &BaseCache{}) or { panic(err) }
	app.note = 'the note'
	app.used_at = 0
	text, is_error := app.answer_for(fx.main, 0, 'get_body', body_args(fx.main))
	assert app.used_at > 0
	assert !is_error && text.contains('(folder: ') && text.contains('(note: the note)'), text
	assert text.contains('from_main'), text
	// an error of the tool is its own, with no header
	missing, bad := app.answer_for(fx.main, 0, 'get_body', '{}')
	assert bad && !missing.contains('(folder:'), missing
	// and a session in the folder has the App of one that names it
	mut d := &Daemon{
		cfg: fx.cfg
	}
	d.call(fx.main, 'get_body', '{"node":"helper"}')
	d.call('', 'get_body', body_args(os.join_path(fx.main, 'lib')))
	assert d.apps.len == 1
}

fn test_every_tool_takes_a_folder_and_requires_none() {
	for t in tool_list() {
		s := (json2.decode[json2.Any](t.input_schema) or { panic(err) }).as_map()
		props := (s['properties'] or { panic(t.name) }).as_map()
		assert 'folder' in props, t.name
		required := (s['required'] or { panic(t.name) }).as_array().map(it.str())
		assert 'folder' !in required, t.name
		if t.name == 'shortest_path' {
			assert required == ['a', 'b']
		}
	}
}
