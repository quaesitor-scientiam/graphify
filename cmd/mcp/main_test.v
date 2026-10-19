module main

import os

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
