module main

// graphify MCP server — speaks MCP over stdio through V's mcp module, the
// transport Claude Code uses for local MCP servers. It loads a persisted
// graph.json once and exposes graph traversal as tools, so the model queries
// the graph instead of re-reading source files.
//
//   v run cmd/mcp [graphify-out/graph.json] [source-dir] [--projects <dir>]
//
// Tools: query_graph, get_node, get_neighbors, shortest_path, get_body, overview.
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
//
// Each session's server relays its tool calls to one daemon, which reads the base
// graph once for every session (daemon.v); without one it reads the graphs itself.
import os
import net.unix
import net.urllib
import time
import x.json2
import mcp
import graphify

// Served is what the tools answer from: `g`, the graph served, and when it is a
// project layered on the base graph, the project's own graph, whose report the
// overview is.
struct Served {
	g       graphify.Graph
	project graphify.Graph
	layered bool
}

// Config is how the server was started: the base graph, the store of project
// graphs, and the source directory that stands in for the base's root.
struct Config {
	graph_path   string
	projects_dir string
	src_dir      string
	base_root    string
	cli          string
}

// App is what the tools answer from for one session's directory, and where it
// comes from: the base graph read from `base_path`, the project's graph from
// `project_path`, and the worktree of the session's directory, `here`. Each tool
// call brings it up to date (refresh). Base graphs come from `bases`, which the
// daemon shares between the sessions it serves (daemon.v).
@[heap]
struct App {
	Config
mut:
	bases         &BaseCache = unsafe { nil }
	here          string
	project_path  string
	wt            Worktree
	base          graphify.Graph
	base_path     string
	served        Served
	stamp         string
	project_stamp string
	note          string
	note_at       i64
	used_at       i64
}

// BaseCache holds the base graphs read, each indexed once, by the graph.json it was
// read from: the V tree's, and a worktree's of it. A copy of a graph shares its
// index, so each session's App and each layered graph on it use the one index.
@[heap]
struct BaseCache {
mut:
	graphs map[string]CachedBase
}

struct CachedBase {
	g     graphify.Graph
	stamp string
}

// get is the graph at `path` (with its root replaced by `src_dir` when set),
// read again only when its graph.json has changed since.
fn (mut b BaseCache) get(path string, src_dir string) !graphify.Graph {
	key := '${path}\n${src_dir}'
	stamp := file_stamp(path)
	if c := b.graphs[key] {
		if c.stamp == stamp {
			return c.g
		}
		b.graphs.delete(key)
	}
	mut g := load(path, src_dir)!
	g.cache_index()
	b.graphs[key] = CachedBase{
		g:     g
		stamp: stamp
	}
	return g
}

// keep drops each graph no path in `used` names.
fn (mut b BaseCache) keep(used map[string]bool) {
	for key in b.graphs.keys() {
		if key.all_before('\n') !in used {
			b.graphs.delete(key)
		}
	}
}

fn main() {
	mut positional := []string{}
	mut projects_dir := ''
	mut daemon := false
	for i := 1; i < os.args.len; i++ {
		if os.args[i] == '--projects' && i + 1 < os.args.len {
			projects_dir = os.args[i + 1]
			i++
			continue
		}
		if os.args[i] == '--daemon' {
			daemon = true
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
	cfg := Config{
		graph_path:   graph_path
		projects_dir: projects_dir
		src_dir:      src_dir
		base_root:    if m := graphify.load_manifest(os.join_path(os.dir(graph_path),
			'manifest.json'))
		{
			m.root
		} else {
			''
		}
		// a shared graph was built by another machine's graphify: compare commits only
		cli:          if src_dir != '' { '' } else { graphify.cli_beside() }
	}
	if daemon {
		run_daemon(cfg)
		return
	}
	// the session's directory: where the server was started until the client says
	// otherwise (session_dir)
	mut sess := &Session{
		cfg:  cfg
		here: os.getwd()
	}
	// one daemon answers for every session (daemon.v); without one, this server
	// reads the graphs itself
	if daemon_enabled() {
		sess.remote = connect_daemon(cfg)
	}
	if isnil(sess.remote) {
		sess.app = new_app(cfg, sess.here, &BaseCache{}) or {
			eprintln('graphify-mcp: ${err}')
			exit(1)
		}
	}

	mut server := mcp.new_server(name: 'graphify', version: '0.0.1')
	for t in tool_list() {
		name := t.name
		server.add_tool(t, fn [mut sess, name] (ctx mcp.Context, arguments string) !mcp.ToolResult {
			return sess.call(ctx, name, arguments)
		}) or { panic(err) }
	}
	// reading the graph leaves as much garbage again: let it go before the first
	// tool call adds its own, which would grow the heap past it
	gc_collect()
	tap_stdin(sess.dirs) or { eprintln("graphify-mcp: cannot watch for the client's roots: ${err}") }
	server.serve_stdio() or {
		eprintln('graphify-mcp: ${err}')
		exit(1)
	}
}

// new_app reads what the tools answer from for the session's directory `dir`.
fn new_app(cfg Config, dir string, bases &BaseCache) !&App {
	mut project_path := graphify.project_for(cfg.projects_dir, dir, cfg.base_root) or { '' }
	// a worktree's extract starts before the base graph is read, which takes longer
	// than a project's extract, so that the worktree's graph is the first one served
	mut wt := Worktree{}
	if cfg.src_dir == '' {
		wt = start_worktree(cfg.projects_dir, dir, project_path, cfg.graph_path, cfg.base_root)
	}
	mut b := unsafe { bases }
	mut base_path := if wt.ready && wt.graph == cfg.graph_path { wt.path } else { cfg.graph_path }
	mut base := b.get(base_path, if base_path == cfg.graph_path { cfg.src_dir } else { '' }) or {
		return error('cannot load ${base_path}: ${err}')
	}
	if wt.poll() && wt.graph == cfg.graph_path {
		if g := b.get(wt.path, '') {
			base = g
			base_path = wt.path
		}
	}
	if wt.ready && wt.graph != cfg.graph_path {
		project_path = wt.path
	}
	// mtime has one-second resolution, so the size is compared as well
	served := serve(base, project_path)
	return &App{
		Config:        cfg
		bases:         bases
		here:          dir
		project_path:  project_path
		wt:            wt
		base:          base
		base_path:     base_path
		served:        served
		stamp:         file_stamp(base_path)
		project_stamp: if project_path != '' { file_stamp(project_path) } else { '' }
		note:          notes(base_path, project_path, served, cfg.cli)
		note_at:       time.now().unix()
		used_at:       time.now().unix()
	}
}

// Session is one client's: the session's directory, from the client's roots, and
// either the daemon that answers for it (`remote`) or the App this server answers
// from itself.
@[heap]
struct Session {
	cfg Config
mut:
	here   string
	remote &unix.StreamConn = unsafe { nil }
	// what the daemon sent after the last answer it read
	pending []u8
	app     &App = unsafe { nil }
	// the session's directory, from the client's roots (tap_stdin): the latest only
	dirs chan string = chan string{cap: 1}
	// whether a 2026-07-28 client was asked for its roots, which it is once
	roots_asked bool
}

// call runs the tool `name` for the session's directory.
fn (mut s Session) call(ctx mcp.Context, name string, arguments string) !mcp.ToolResult {
	// A 2026-07-28 client has no session to be asked for its roots in: the first
	// tool call asks, and the client calls again with them (MRTR).
	if res := ctx.take_roots_result('roots') {
		if res.roots.len > 0 {
			if dir := dir_of_uri(res.roots[0].uri) {
				s.move_to(dir)
			}
		}
	} else if ctx.protocol_version == mcp.protocol_version_2026_07_28 && !s.roots_asked
		&& caps_have_roots(ctx.client_capabilities) {
		s.roots_asked = true
		return ctx.require_roots('roots')
	}
	mut dir := ''
	if s.dirs.try_pop(mut dir) == .success {
		s.move_to(dir)
	}
	text, is_error := s.answer(name, arguments)
	return mcp.ToolResult{
		content:  '[${mcp.text_content(text)}]'
		is_error: is_error
	}
}

// move_to takes `dir` for the session's directory.
fn (mut s Session) move_to(dir string) {
	s.here = dir
	if !isnil(s.app) {
		s.app.move_to(dir)
	}
}

// answer is the daemon's answer, or this server's own when there is no daemon to
// ask: one that went away is started again once, and then this server reads the
// graphs itself.
fn (mut s Session) answer(name string, arguments string) (string, bool) {
	if !isnil(s.remote) {
		if text, is_error := s.ask(name, arguments) {
			return text, is_error
		}
		s.remote = connect_daemon(s.cfg)
		if !isnil(s.remote) {
			if text, is_error := s.ask(name, arguments) {
				return text, is_error
			}
		}
		eprintln('graphify-mcp: no daemon to answer; reading the graphs here')
		s.remote = unsafe { nil }
	}
	if isnil(s.app) {
		s.app = new_app(s.cfg, s.here, &BaseCache{}) or {
			return 'graphify-mcp: ${err}', true
		}
	}
	return s.app.answer(name, arguments)
}

// answer brings the App up to date and runs the tool `name` on it.
fn (mut app App) answer(name string, arguments string) (string, bool) {
	app.used_at = time.now().unix()
	app.refresh()
	args := (json2.decode[json2.Any](arguments) or { json2.null }).as_map()
	return call_tool(name, args, app.served, join_notes(app.wt.note(), app.note))
}

// move_to picks the project and the worktree again for `dir`, the session's
// directory; the next refresh reads what changed and serves it.
fn (mut app App) move_to(dir string) {
	if os.real_path(dir) == os.real_path(app.here) {
		return
	}
	app.here = dir
	eprintln('graphify-mcp: the session is in ${dir}')
	app.project_path = graphify.project_for(app.projects_dir, dir, app.base_root) or { '' }
	app.wt = Worktree{}
	was_base := app.base_path
	app.base_path = app.graph_path
	if app.src_dir == '' {
		app.wt = start_worktree(app.projects_dir, dir, app.project_path, app.graph_path,
			app.base_root)
		if app.wt.ready {
			if app.wt.graph == app.graph_path {
				app.base_path = app.wt.path
			} else {
				app.project_path = app.wt.path
			}
		}
	}
	// the base only when it is another graph.json
	if app.base_path != was_base {
		app.stamp = ''
	}
	app.project_stamp = ''
}

// refresh serves the worktree's graph once it is there, and a graph.json a
// re-extract replaced, and looks again whether the graph is out of date.
fn (mut app App) refresh() {
	if app.wt.root != '' {
		// the worktree's graph is there now: serve it in place of the checkout's
		if app.wt.poll() {
			// only the graph replaced is read again
			if app.wt.graph == app.graph_path {
				app.base_path = app.wt.path
				app.stamp = ''
			} else {
				app.project_path = app.wt.path
				app.project_stamp = ''
			}
		}
		app.wt.refresh()
	}
	// a re-extract replaced a graph.json: serve the new graph
	now_stamp := file_stamp(app.base_path)
	now_project := if app.project_path != '' { file_stamp(app.project_path) } else { '' }
	if now_stamp != app.stamp || now_project != app.project_stamp {
		if now_stamp != app.stamp {
			if fresh := app.bases.get(app.base_path, if app.base_path == app.graph_path {
				app.src_dir
			} else {
				''
			})
			{
				app.base = fresh
			}
		}
		// the graph served before is let go first, so that the new one can take
		// its memory: a worktree's is served again after each change
		app.served = Served{}
		gc_collect()
		app.served = serve(app.base, app.project_path)
		app.stamp = now_stamp
		app.project_stamp = now_project
		app.note_at = 0
	}
	// the checkout moves on its own; look again at most once a minute
	if time.now().unix() - app.note_at >= 60 {
		app.note = notes(app.base_path, app.project_path, app.served, app.cli)
		app.note_at = time.now().unix()
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
	eprintln('graphify-mcp: layered ${project_path} on the base graph: ${g.index().base_count} vlib symbols under it')
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

// call_tool runs one tool and returns its text, and whether it is a tool error the
// client should surface rather than treat as an answer; `note`, when set, says the
// graph may be stale and goes first in the result.
fn call_tool(name string, args map[string]json2.Any, served Served, note string) (string, bool) {
	g := served.g
	mut str_args := map[string]string{}
	for k, v in args {
		if v is string {
			str_args[k] = v
		}
	}
	missing := graphify.missing_tool_arg(name, str_args)
	if missing != '' {
		return missing, true
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
				'${served.project.report()}\n(layered on the vlib of ${g.base.root}: ${g.index().base_count} more symbols, which the other tools reach)'
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
			path := g.path_between((args['a'] or { json2.null }).str(), (args['b'] or {
				json2.null
			}).str())
			if path == '' {
				'(no path)'
			} else {
				path
			}
		}
		else {
			'unknown tool: ${name}'
		}
	}
	if note != '' {
		return '(note: ${note})\n\n${text}', false
	}
	return text, false
}

// --- MCP metadata ---

fn tool_list() []mcp.Tool {
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
		tool('shortest_path', 'How a reaches b: the shortest chain of calls from a to b, each call with its line (or from b to a, when only that way has one); with no chain of calls, the shortest link through any relation.', schema({
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

fn tool(name string, desc string, input_schema json2.Any) mcp.Tool {
	return mcp.Tool{
		name:         name
		description:  desc
		input_schema: input_schema.json_str()
	}
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

// tap_stdin puts itself between the client and the mcp module's stdio loop, which
// reads fd 0: the client's messages go on to it through a pipe, and the tap asks the
// client for its roots after the handshake and when they change, and sends the
// session's directory it reads from the answer on `dirs`. The module can't do this
// itself over stdio: a notification reaches no handler, and the roots/list
// `Server.list_roots` sends is written only after the next message the client sends
// is answered, and waits for an answer that the loop running a handler can't read.
fn tap_stdin(dirs chan string) ! {
	client := os.fd_dup(0)
	if client < 0 {
		return error('cannot duplicate stdin')
	}
	mut p := os.pipe()!
	if os.fd_dup2(p.read_fd, 0) < 0 {
		p.close()
		return error('cannot replace stdin')
	}
	os.fd_close(p.read_fd)
	spawn pass_stdin(client, p.write_fd, os.stdout(), dirs)
}

// pass_stdin passes the lines read from `from` on to `to`, all but the client's
// answer to roots_request, and closes `to` at the end of the input; it writes
// roots_request to `out`, stdout.
fn pass_stdin(from int, to int, out os.File, dirs chan string) {
	mut requests := out
	mut has_roots := false
	mut pending := ''
	for {
		chunk, n := os.fd_read(from, 65536)
		if n <= 0 {
			break
		}
		pending += chunk
		for {
			i := pending.index_u8(`\n`)
			if i < 0 {
				break
			}
			line := pending[..i + 1]
			pending = pending[i + 1..]
			if line.contains('"initialize"') {
				has_roots = client_has_roots(line)
			}
			if dir := session_dir(line) {
				// only the latest is wanted: the tool call takes it from here
				mut old := ''
				dirs.try_pop(mut old)
				dirs.try_push(dir)
				continue
			}
			os.fd_write(to, line)
			if has_roots && roots_asked(line) {
				// a whole line in one write: the mcp module writes to stdout as well
				requests.write_string(roots_request + '\n') or {}
				requests.flush()
			}
		}
	}
	os.fd_write(to, pending)
	os.fd_close(to)
}

// roots_request asks the client for its roots, the directories it works in.
const roots_request = '{"jsonrpc":"2.0","id":"graphify-roots","method":"roots/list"}'

// caps_have_roots reports whether the client's capabilities, a JSON object, say it
// can list its roots.
fn caps_have_roots(caps string) bool {
	any := json2.decode[json2.Any](caps) or { return false }
	return 'roots' in any.as_map()
}

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
