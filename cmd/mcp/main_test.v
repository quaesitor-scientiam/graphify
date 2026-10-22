module main

import os
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

fn test_a_windows_argument_is_quoted_so_argv_reads_it_back() {
	assert win_quote('--daemon') == '--daemon'
	assert win_quote('C:\\graph data\\graph.json') == '"C:\\graph data\\graph.json"'
	assert win_quote('') == '""'
	// a quote, and the backslashes before it, are escaped
	assert win_quote('a"b') == '"a\\"b"'
	assert win_quote('a\\"b') == '"a\\\\\\"b"'
	// backslashes before the closing quote are doubled; others are as they are
	assert win_quote('C:\\a b\\') == '"C:\\a b\\\\"'
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
	text, is_error := call_tool('shortest_path', args, served, '')
	assert !is_error
	assert text.contains('5. start') && !text.contains('6. start'), text
	args['routes'] = json2.Any(7)
	all, _ := call_tool('shortest_path', args, served, '')
	assert all.contains('7. start') && !all.contains('the 5 shortest'), all
	args['routes'] = json2.Any(0)
	one, _ := call_tool('shortest_path', args, served, '')
	assert one.contains('the 1 shortest') && !one.contains('2. start'), one
}
