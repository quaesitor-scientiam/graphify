module main

import os
import time
import net.unix
import x.json2
import graphify

fn test_the_server_asks_for_roots_after_the_handshake_and_when_they_change() {
	assert roots_asked('{"jsonrpc":"2.0","method":"notifications/initialized"}')
	assert roots_asked('{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}')
	assert !roots_asked('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}')
	assert !roots_asked('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
	assert !roots_asked('not json, notifications/initialized')
}

fn test_only_a_client_that_has_roots_is_asked_for_them() {
	assert client_has_roots('{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true}}},"jsonrpc":"2.0","id":0}')
	assert !client_has_roots('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}')
	assert !client_has_roots('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query_graph","arguments":{"text":"initialize roots"}}}')
}

fn test_the_session_dir_is_the_first_root_the_client_answers_with() {
	dir := os.join_path(os.temp_dir(), 'graphify roots ${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// Claude Code's answer, for a session in a worktree; a space is percent-encoded
	answer := '{"result":{"roots":[{"uri":"${file_uri(dir)}"},{"uri":"file:///elsewhere"}]},"jsonrpc":"2.0","id":"graphify-roots"}'
	assert slashed(session_dir(answer) or { '' }) == slashed(dir)
	// an answer to another request, an empty one, and a root that is no directory
	assert session_dir(answer.replace('"graphify-roots"', '"other"')) == none
	assert session_dir('{"result":{"roots":[]},"jsonrpc":"2.0","id":"graphify-roots"}') == none
	assert session_dir('{"result":{"roots":[{"uri":"https://example.com/x"}]},"jsonrpc":"2.0","id":"graphify-roots"}') == none
	assert session_dir('{"result":{"roots":[{"uri":"file:///no/such/dir/here"}]},"jsonrpc":"2.0","id":"graphify-roots"}') == none
	// a request that only mentions the id is not the answer
	assert session_dir('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_graph","arguments":{"text":"graphify-roots"}}}') == none
}

fn test_a_windows_file_uri_has_no_slash_before_its_drive() {
	$if windows {
		assert dir_of_uri('file:///C:/Windows') or { '' } == 'C:/Windows'
	} $else {
		assert dir_of_uri('file:///tmp') or { '' } == '/tmp'
	}
}

fn test_a_client_has_roots_when_its_capabilities_say_so() {
	assert caps_have_roots('{"roots":{"listChanged":true}}')
	assert caps_have_roots('{"roots":{}}')
	assert !caps_have_roots('{"sampling":{}}')
	assert !caps_have_roots('')
}

// The tap passes the client's messages on, asks for the roots after the handshake,
// and keeps the answer from the mcp module.
fn test_the_stdin_tap_asks_for_roots_and_takes_the_answer() {
	dir := os.join_path(os.temp_dir(), 'graphify tap ${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	requests := os.join_path(dir, 'requests')
	defer {
		os.rmdir_all(dir) or {}
	}
	initialize := '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{}}}}\n'
	initialized := '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
	answer := '{"jsonrpc":"2.0","id":"graphify-roots","result":{"roots":[{"uri":"${file_uri(dir)}"}]}}\n'
	call := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"overview"}}'
	mut client := os.pipe() or { panic(err) }
	mut server := os.pipe() or { panic(err) }
	os.fd_write(client.write_fd, initialize + initialized + answer + call)
	os.fd_close(client.write_fd)
	mut out := os.create(requests) or { panic(err) }
	dirs := chan string{cap: 1}
	pass_stdin(client.read_fd, server.write_fd, out, dirs)
	out.close()
	os.fd_close(client.read_fd)
	// the call, with no newline, is passed on at the end of the input
	mut passed := ''
	for {
		s, n := os.fd_read(server.read_fd, 65536)
		if n <= 0 {
			break
		}
		passed += s
	}
	os.fd_close(server.read_fd)
	assert passed == initialize + initialized + call
	assert os.read_file(requests) or { '' } == roots_request + '\n'
	mut got := ''
	assert dirs.try_pop(mut got) == .success
	assert slashed(got) == slashed(dir)
}

fn test_a_client_without_roots_is_not_asked() {
	path := os.join_path(os.temp_dir(), 'graphify tap requests ${os.getpid()}')
	defer {
		os.rm(path) or {}
	}
	mut client := os.pipe() or { panic(err) }
	mut server := os.pipe() or { panic(err) }
	os.fd_write(client.write_fd, '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
	os.fd_close(client.write_fd)
	mut out := os.create(path) or { panic(err) }
	pass_stdin(client.read_fd, server.write_fd, out, chan string{cap: 1})
	out.close()
	os.fd_close(client.read_fd)
	os.fd_close(server.read_fd)
	assert os.read_file(path) or { 'x' } == ''
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
