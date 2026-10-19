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
	uri := 'file://' + dir.replace(' ', '%20')
	answer := '{"result":{"roots":[{"uri":"${uri}"},{"uri":"file:///elsewhere"}]},"jsonrpc":"2.0","id":"graphify-roots"}'
	assert session_dir(answer) or { '' } == dir
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
