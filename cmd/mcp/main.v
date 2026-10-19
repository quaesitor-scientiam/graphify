module main

// graphify MCP server — speaks JSON-RPC 2.0 over stdio (newline-delimited),
// the transport Claude Code uses for local MCP servers. It loads a persisted
// graph.json once and exposes graph traversal as tools, so the model queries
// the graph instead of re-reading source files.
//
//   v run cmd/mcp [graphify-out/graph.json] [source-dir] [--projects <dir>]
//
// Tools: query_graph, get_node, get_neighbors, shortest_path.
//
// With --projects, a directory of project graphs (`extract --store`), it serves the
// project whose root holds its working directory, layered on the graph it was given
// (the V tree's), so that a traversal from the project carries on into vlib
// (graphify.layer_graph, FUTURE_WORK.md §11); elsewhere it serves that graph alone.
//
// Started in a git worktree of a project, or of the V tree, it extracts the
// worktree's own graph in the background, with the graphify beside it, into a store
// of its own (graphify.worktree_store) seeded with the checkout's cache, and serves
// that graph in place of the checkout's once it is there; the checkout's until
// then. It extracts again when the worktree has changed since, so that the graph
// has the branch's edits (FUTURE_WORK.md §11).
//
// It reloads a graph when its graph.json changes on disk (an extract publishes
// it atomically), and a tool result starts with a note when the graph looks
// out of date (graphify.stale_note).
import os
import net.urllib
import time
import x.json2
import graphify

// Served is what the tools answer from: `g`, the graph served, and when it is a
// project layered on the base graph, the project's own graph, whose report the
// overview is.
struct Served {
	g       graphify.Graph
	project graphify.Graph
	layered bool
}

fn main() {
	mut positional := []string{}
	mut projects_dir := ''
	for i := 1; i < os.args.len; i++ {
		if os.args[i] == '--projects' && i + 1 < os.args.len {
			projects_dir = os.args[i + 1]
			i++
			continue
		}
		positional << os.args[i]
	}
	graph_path := if positional.len > 0 {
		positional[0]
	} else {
		os.join_path(graphify.out_dir_name, 'graph.json')
	}
	// optional 2nd arg / GRAPHIFY_SOURCE_DIR: override the extraction root so a
	// graph shared from another machine resolves get_body against local source.
	src_dir := if positional.len > 1 { positional[1] } else { os.getenv('GRAPHIFY_SOURCE_DIR') }
	// the project whose root holds the directory this server was started in
	base_root := if m := graphify.load_manifest(os.join_path(os.dir(graph_path), 'manifest.json')) {
		m.root
	} else {
		''
	}
	// the session's directory: where the server was started until the client says
	// otherwise (session_dir)
	mut here := os.getwd()
	mut project_path := graphify.project_for(projects_dir, here, base_root) or { '' }
	// a worktree's extract starts before the base graph is read, which takes longer
	// than a project's extract, so that the worktree's graph is the first one served
	mut wt := Worktree{}
	if src_dir == '' {
		wt = start_worktree(projects_dir, here, project_path, graph_path, base_root)
	}
	mut base := load(if wt.ready && wt.graph == graph_path { wt.path } else { graph_path },
		src_dir) or {
		eprintln('graphify-mcp: cannot load ${graph_path}: ${err}')
		exit(1)
	}
	if wt.poll() && wt.graph == graph_path {
		base = load(wt.path, '') or { base }
	}
	if wt.ready && wt.graph != graph_path {
		project_path = wt.path
	}
	mut served := serve(base, project_path)
	// the graph.json the base is read from: the worktree's, once it is there, for a
	// worktree of the V tree; mtime has one-second resolution, so the size is
	// compared as well
	mut base_path := if wt.ready && wt.graph == graph_path { wt.path } else { graph_path }
	mut stamp := file_stamp(base_path)
	mut project_stamp := if project_path != '' { file_stamp(project_path) } else { '' }
	// a shared graph was built by another machine's graphify: compare commits only
	cli := if src_dir != '' { '' } else { graphify.cli_beside() }
	mut note := notes(base_path, project_path, served, cli)
	mut note_at := time.now().unix()
	// whether the client said it has roots to answer roots_request with
	mut has_roots := false

	for {
		raw := os.get_raw_line()
		if raw.len == 0 {
			break // EOF
		}
		line := raw.trim_space()
		if line == '' {
			continue
		}
		// The client names the session's directory as its root: Claude Code starts a
		// server in the project's own checkout, not the worktree a session is in. The
		// server asks once the handshake is done, and again when the roots change.
		if line.contains('"initialize"') {
			has_roots = client_has_roots(line)
		}
		if has_roots && roots_asked(line) {
			println(roots_request)
			flush_stdout()
			continue
		}
		if dir := session_dir(line) {
			if os.real_path(dir) != os.real_path(here) {
				here = dir
				eprintln('graphify-mcp: the session is in ${here}')
				project_path = graphify.project_for(projects_dir, here, base_root) or { '' }
				wt = Worktree{}
				was_base := base_path
				base_path = graph_path
				if src_dir == '' {
					wt = start_worktree(projects_dir, here, project_path, graph_path,
						base_root)
					if wt.ready {
						if wt.graph == graph_path {
							base_path = wt.path
						} else {
							project_path = wt.path
						}
					}
				}
				// the next tool call reads what changed and serves it: the base only when
				// it is another graph.json
				if base_path != was_base {
					stamp = ''
				}
				project_stamp = ''
			}
			continue
		}
		if line.contains('"tools/call"') {
			if wt.root != '' {
				// the worktree's graph is there now: serve it in place of the checkout's
				if wt.poll() {
					// only the graph replaced is read again
					if wt.graph == graph_path {
						base_path = wt.path
						stamp = ''
					} else {
						project_path = wt.path
						project_stamp = ''
					}
				}
				wt.refresh()
			}
			// a re-extract replaced a graph.json: serve the new graph
			now_stamp := file_stamp(base_path)
			now_project := if project_path != '' { file_stamp(project_path) } else { '' }
			if now_stamp != stamp || now_project != project_stamp {
				if now_stamp != stamp {
					if fresh := load(base_path, if base_path == graph_path { src_dir } else { '' }) {
						base = fresh
					}
				}
				// the graph served before is let go first, so that the new one can take
				// its memory: a worktree's is served again after each change
				served = Served{}
				gc_collect()
				served = serve(base, project_path)
				stamp = now_stamp
				project_stamp = now_project
				note_at = 0
			}
			// the checkout moves on its own; look again at most once a minute
			if time.now().unix() - note_at >= 60 {
				note = notes(base_path, project_path, served, cli)
				note_at = time.now().unix()
			}
		}
		resp := handle(line, served, join_notes(wt.note(), note))
		if resp != '' {
			println(resp)
			flush_stdout()
		}
	}
}

fn file_stamp(path string) string {
	return '${os.file_last_mod_unix(path)}:${os.file_size(path)}'
}

// load reads the graph, with its root replaced by `src_dir` when one is given.
fn load(graph_path string, src_dir string) !graphify.Graph {
	mut g := graphify.load_graph(graph_path)!
	if src_dir != '' {
		g.root = src_dir
	}
	eprintln('graphify-mcp: loaded ${g.symbols.len} symbols from ${graph_path}')
	return g
}

// serve is the graph to answer from: the project at `project_path` layered on
// `base`, or `base` alone when there is no project, or it can't be read.
fn serve(base graphify.Graph, project_path string) Served {
	// each tool call uses the graph's index: build it once, for the graph served
	if project_path == '' {
		mut alone := base
		alone.cache_index()
		return Served{
			g: alone
		}
	}
	project := load(project_path, '') or {
		eprintln('graphify-mcp: cannot load ${project_path}: ${err}; serving the base graph alone')
		mut alone := base
		alone.cache_index()
		return Served{
			g: alone
		}
	}
	mut g := graphify.layer_graph(project, base)
	g.cache_index()
	eprintln('graphify-mcp: layered ${project_path} on the base graph: ${g.base.ids.len} vlib symbols under it')
	return Served{
		g:       g
		project: project
		layered: true
	}
}

// notes is the stale note of each graph served, the project's and the base's, and
// whether the vlib layered under a project is the one it read (graphify.layer_note).
fn notes(graph_path string, project_path string, served Served, cli string) string {
	mut out := []string{}
	if served.layered {
		n := graphify.stale_note(project_path, served.project.root, cli)
		if n != '' {
			out << 'the project: ${n}'
		}
		l := graphify.layer_note(project_path, graph_path)
		if l != '' {
			out << l
		}
	}
	root := if served.layered { served.g.base.root } else { served.g.root }
	n := graphify.stale_note(graph_path, root, cli)
	if n != '' {
		out << if served.layered { 'the vlib under it: ${n}' } else { n }
	}
	return out.join(' ')
}

// handle parses one JSON-RPC request and returns the response line, or '' for
// notifications (no id) and unparseable input.
fn handle(line string, served Served, note string) string {
	any := json2.decode[json2.Any](line) or { return rpc_error(json2.null, -32700, 'parse error') }
	req := any.as_map()
	method := req['method'] or { return '' }.str()
	has_id := 'id' in req
	id := req['id'] or { json2.null }

	// notifications carry no id and expect no response
	if !has_id {
		return ''
	}

	match method {
		'initialize' {
			return rpc_result(id, initialize_result())
		}
		'tools/list' {
			return rpc_result(id, jobj({
				'tools': jarr(tool_list())
			}))
		}
		'tools/call' {
			params := (req['params'] or { json2.null }).as_map()
			name := (params['name'] or { json2.null }).str()
			args := (params['arguments'] or { json2.null }).as_map()
			return rpc_result(id, call_tool(name, args, served, note))
		}
		'ping' {
			return rpc_result(id, jobj(map[string]json2.Any{}))
		}
		else {
			return rpc_error(id, -32601, 'method not found: ${method}')
		}
	}
}

// call_tool runs one tool; `note`, when set, says the graph may be stale and
// goes first in the result.
fn call_tool(name string, args map[string]json2.Any, served Served, note string) json2.Any {
	g := served.g
	mut str_args := map[string]string{}
	for k, v in args {
		if v is string {
			str_args[k] = v
		}
	}
	missing := graphify.missing_tool_arg(name, str_args)
	if missing != '' {
		return tool_result(missing, true)
	}
	text := match name {
		'query_graph' {
			budget := if 'budget' in args { (args['budget'] or { json2.null }).int() } else { 2000 }
			dfs := if 'dfs' in args { (args['dfs'] or { json2.null }).bool() } else { false }
			g.query((args['text'] or { json2.null }).str(), budget, dfs)
		}
		'get_node' {
			g.explain((args['node'] or { json2.null }).str())
		}
		'get_body' {
			g.get_body((args['node'] or { json2.null }).str())
		}
		'overview' {
			if served.layered {
				// the project's own report: vlib's counts and hubs would drown it
				'${served.project.report()}\n(layered on the vlib of ${g.base.root}: ${g.base.ids.len} more symbols, which the other tools reach)'
			} else {
				g.report()
			}
		}
		'get_neighbors' {
			names := g.neighbor_names((args['node'] or { json2.null }).str())
			if names.len == 0 {
				'(no neighbors / unknown node)'
			} else {
				names.join('\n')
			}
		}
		'shortest_path' {
			ids := g.shortest_path((args['a'] or { json2.null }).str(),
				(args['b'] or { json2.null }).str())
			if ids.len == 0 {
				'(no path)'
			} else {
				g.names(ids).join(' -> ')
			}
		}
		else {
			'unknown tool: ${name}'
		}
	}
	if note != '' {
		return tool_result('(note: ${note})\n\n${text}', false)
	}
	return tool_result(text, false)
}

// tool_result wraps `text` as an MCP tools/call result; `is_error` marks it as a
// tool error the client should surface rather than treat as an answer.
fn tool_result(text string, is_error bool) json2.Any {
	mut res := {
		'content': jarr([
			jobj({
				'type': jstr('text')
				'text': jstr(text)
			}),
		])
	}
	if is_error {
		res['isError'] = json2.Any(true)
	}
	return jobj(res)
}

// --- MCP metadata ---

fn initialize_result() json2.Any {
	return jobj({
		'protocolVersion': jstr('2024-11-05')
		'capabilities':    jobj({
			'tools': jobj(map[string]json2.Any{})
		})
		'serverInfo':      jobj({
			'name':    jstr('graphify')
			'version': jstr('0.0.1')
		})
	})
}

fn tool_list() []json2.Any {
	return [
		tool('query_graph',
			'Traverse the code graph from symbols matching a search text, breadth-first (or depth-first), returning a token-bounded body-less view with file:line locations. Use this instead of reading whole files.', schema({
			'text':   prop('string',
				'search text; seeds the traversal from matching symbol names/signatures')
			'budget': prop('integer', 'approximate token budget for the result (default 2000)')
			'dfs':    prop('boolean', 'walk depth-first instead of breadth-first (default false)')
		}, ['text'])),
		tool('get_node',
			'Summarize one symbol: signature, location, and its relationships (defines/defined-in, references/referenced-by, embeds, calls/called-by) — each with file:line.', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('get_body',
			'Return the source of ONE declaration by name, read by line range — fetch a single function/struct/const instead of reading the whole file.', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('overview',
			'A COMPACT summary: file/symbol/edge counts, symbols by kind, and the most-connected symbols with file:line. Small — orient with this, then query_graph/get_node to drill in. Not a full dump.', schema(map[string]json2.Any{},
			[]string{})),
		tool('get_neighbors',
			'List the names of all symbols directly linked to a symbol (calls, callers, defines, imports).', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('shortest_path', 'Find the shortest relationship path between two symbols.', schema({
			'a': prop('string', 'start symbol name or id')
			'b': prop('string', 'goal symbol name or id')
		}, ['a', 'b'])),
	]
}

// --- json2 builders ---

fn jstr(s string) json2.Any {
	return json2.Any(s)
}

fn jobj(m map[string]json2.Any) json2.Any {
	return json2.Any(m)
}

fn jarr(a []json2.Any) json2.Any {
	return json2.Any(a)
}

fn prop(typ string, desc string) json2.Any {
	return jobj({
		'type':        jstr(typ)
		'description': jstr(desc)
	})
}

fn schema(props map[string]json2.Any, required []string) json2.Any {
	mut req := []json2.Any{}
	for r in required {
		req << jstr(r)
	}
	return jobj({
		'type':       jstr('object')
		'properties': jobj(props)
		'required':   jarr(req)
	})
}

fn tool(name string, desc string, input_schema json2.Any) json2.Any {
	return jobj({
		'name':        jstr(name)
		'description': jstr(desc)
		'inputSchema': input_schema
	})
}

fn rpc_result(id json2.Any, result json2.Any) string {
	return jobj({
		'jsonrpc': jstr('2.0')
		'id':      id
		'result':  result
	}).json_str()
}

fn rpc_error(id json2.Any, code int, message string) string {
	return jobj({
		'jsonrpc': jstr('2.0')
		'id':      id
		'error':   jobj({
			'code':    json2.Any(code)
			'message': jstr(message)
		})
	}).json_str()
}

// Worktree is the git worktree this server was started in, when it is another
// worktree of a graph's repository: `graph`, the checkout's graph.json; `root`,
// the graph's root in the worktree; `path`, the graph.json its own graph is
// extracted to. An extract runs in the background, and `done` has its outcome.
struct Worktree {
	graph string
	root  string
	path  string
	cli   string
mut:
	ready    bool
	running  bool
	failed   string
	state    string
	state_at i64
	done     chan string
}

// start_worktree finds the worktree `dir`, the session's directory, is in (graphify.worktree_graph)
// and starts extracting its graph; a Worktree with no root when there is none, or
// no graphify beside this server to extract it with. A graph a server extracted for
// the worktree before is served from the start, while it is extracted again.
fn start_worktree(projects_dir string, dir string, project_path string, graph_path string, base_root string) Worktree {
	stores := graphify.worktree_stores()
	graphify.prune_worktree_stores(stores)
	found := graphify.worktree_graph(projects_dir, dir, project_path, graph_path, base_root) or {
		return Worktree{}
	}
	cli := graphify.cli_beside()
	if !os.exists(cli) {
		eprintln('graphify-mcp: ${found.root} is a worktree, but there is no ${cli} to extract it with')
		return Worktree{}
	}
	store := graphify.worktree_store(stores, found.root)
	graphify.seed_worktree_store(store, found.graph) or {
		eprintln('graphify-mcp: cannot make ${store}: ${err}')
		return Worktree{}
	}
	path := os.join_path(store, 'graph.json')
	mut wt := Worktree{
		graph: found.graph
		root:  found.root
		path:  path
		cli:   cli
		done:  chan string{cap: 1}
	}
	if m := graphify.load_manifest(os.join_path(store, 'manifest.json')) {
		wt.ready = os.exists(path) && os.real_path(m.root) == os.real_path(found.root)
	}
	wt.extract()
	return wt
}

// extract starts extracting the worktree's graph in the background, after taking
// the worktree's state, so that a change made while it runs is extracted after it.
fn (mut wt Worktree) extract() {
	wt.state = graphify.worktree_state(wt.root)
	wt.state_at = time.now().unix()
	wt.running = true
	eprintln('graphify-mcp: extracting the worktree ${wt.root}')
	spawn extract_worktree(wt.cli, wt.root, os.dir(wt.path), wt.done)
}

// extract_worktree runs `graphify extract` on the worktree into `store`, and sends
// '' when it published the graph, or what went wrong.
fn extract_worktree(cli string, root string, store string, done chan string) {
	res := os.exec([cli, 'extract', root, '--out', store])
	done <- if res.exit_code == 0 {
		''
	} else {
		lines := res.output.trim_space().split_into_lines()
		if lines.len > 0 { lines.last() } else { 'exit code ${res.exit_code}' }
	}
}

// poll takes the outcome of the extract running, when it is done, and reports
// whether the worktree's graph has just come: the first that is there, to be served
// in place of the checkout's. A graph published again is reloaded as any is.
fn (mut wt Worktree) poll() bool {
	if !wt.running {
		return false
	}
	mut msg := ''
	if wt.done.try_pop(mut msg) != .success {
		return false
	}
	wt.running = false
	wt.failed = msg
	if msg != '' {
		eprintln('graphify-mcp: cannot extract the worktree ${wt.root}: ${msg}')
		return false
	}
	eprintln('graphify-mcp: extracted the worktree ${wt.root}')
	came := !wt.ready
	wt.ready = true
	return came
}

// refresh extracts the worktree again when it has changed since the last extract
// started, looking at most every two seconds; never while one runs.
fn (mut wt Worktree) refresh() {
	if wt.running || time.now().unix() - wt.state_at < 2 {
		return
	}
	wt.state_at = time.now().unix()
	if graphify.worktree_state(wt.root) != wt.state {
		wt.extract()
	}
}

// note says what the graph served is to the worktree: the checkout's, until the
// worktree's own is there; the worktree's from before a change, while it is
// extracted again; '' once it is up to date.
fn (wt Worktree) note() string {
	if wt.root == '' {
		return ''
	}
	checkout := os.dir(wt.graph)
	if !wt.ready {
		if wt.failed != '' {
			return 'the graph of this worktree, ${wt.root}, could not be extracted (${wt.failed}), so this is the graph of the checkout in ${checkout}, not of this branch'
		}
		return 'the graph of this worktree, ${wt.root}, is being extracted; until it is there, this is the graph of the checkout in ${checkout}, not of this branch'
	}
	if wt.running {
		return 'the worktree has changed since its graph was extracted; it is being extracted again'
	}
	if wt.failed != '' {
		return 'the worktree has changed, but its graph could not be extracted again (${wt.failed})'
	}
	return ''
}

// join_notes joins the notes that are set.
fn join_notes(a string, b string) string {
	return if a == '' {
		b
	} else if b == '' {
		a
	} else {
		'${a} ${b}'
	}
}

// roots_request asks the client for its roots, the directories it works in.
const roots_request = '{"jsonrpc":"2.0","id":"graphify-roots","method":"roots/list"}'

// client_has_roots reports whether `line` is the client's `initialize` request and
// says the client can list its roots.
fn client_has_roots(line string) bool {
	any := json2.decode[json2.Any](line) or { return false }
	msg := any.as_map()
	if (msg['method'] or { return false }).str() != 'initialize' {
		return false
	}
	params := (msg['params'] or { return false }).as_map()
	caps := (params['capabilities'] or { return false }).as_map()
	return 'roots' in caps
}

// roots_asked reports whether `line` is a notification after which the server asks
// for the client's roots: the end of the handshake, or the roots changing.
fn roots_asked(line string) bool {
	if !line.contains('notifications/') {
		return false
	}
	any := json2.decode[json2.Any](line) or { return false }
	method := (any.as_map()['method'] or { return false }).str()
	return method in ['notifications/initialized', 'notifications/roots/list_changed']
}

// session_dir is the directory of the first root in `line` when it is the client's
// answer to roots_request; none for any other line, or a root that isn't a local
// directory.
fn session_dir(line string) ?string {
	if !line.contains('"graphify-roots"') {
		return none
	}
	any := json2.decode[json2.Any](line) or { return none }
	msg := any.as_map()
	if (msg['id'] or { return none }).str() != 'graphify-roots' {
		return none
	}
	result := (msg['result'] or { return none }).as_map()
	roots := (result['roots'] or { return none }).as_array()
	if roots.len == 0 {
		return none
	}
	uri := (roots[0].as_map()['uri'] or { return none }).str()
	return dir_of_uri(uri)
}

// dir_of_uri is the local directory a `file://` URI names, percent-decoded, with
// the slash before a Windows drive left out; none when it names no directory.
fn dir_of_uri(uri string) ?string {
	if !uri.starts_with('file://') {
		return none
	}
	mut path := urllib.path_unescape(uri['file://'.len..]) or { return none }
	if path.len > 2 && path[0] == `/` && path[2] == `:` {
		path = path[1..]
	}
	return if os.is_dir(path) { path } else { none }
}
