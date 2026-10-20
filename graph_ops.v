module graphify

import os
import v.pref

// Index is a precomputed lookup over a Graph: symbols by id and name, plus an
// undirected adjacency of *internal* edges (edges whose target resolves to a
// known symbol). It powers query/path/explain without rescanning the slice.
//
// A layered graph's index (layer_graph) holds the project's symbols and edges only,
// and falls through to `under`, the base's, for the vlib declarations layered under
// the project: lookups go through symbol, has, named and neighbors_into, which see
// both, while the fields alone are the project's part. A whole-graph walk of the
// fields (communities, the emitters) sees that part only.
pub struct Index {
pub mut:
	by_id   map[string]Symbol
	by_name map[string][]string // short name -> distinct ids
	adj     map[string][]string // undirected neighbor ids
	edges   []Edge              // edges with `to` resolved to an id where possible
	// the library declarations the project reaches (Graph.library), and the edges
	// into them: they label edges in explain and answer get_body, but join no
	// traversal, ranking or name resolution, which stay the project's
	lib_by_id map[string]Symbol
	lib_edges []Edge
	// a layered graph's: the base's index, which its own falls through to; the
	// modules from VMODULES (Base.mods), in by_id but named apart, since a name's
	// ids list the project's, then vlib's, then theirs; the vlib side of the
	// adjacency of each declaration that a base edge links to one of by_id's, which
	// the base's adjacency can't give, since it doesn't say which way an edge goes;
	// and how many symbols are the base's, vlib's and the modules'
	under       &Index = unsafe { nil }
	mods        map[string]bool
	mod_by_name map[string][]string
	fix         map[string][]string
	base_count  int
	// what a graph layered on this one takes from it, worked out by the first
	// (layer_graph)
	layer &Layer = unsafe { nil }
	// the declarations each one calls, from the resolved `calls` edges: what call_path
	// follows, one way
	callees map[string][]string
}

// index builds the lookup structures for a graph, or returns the ones cache_index
// kept.
pub fn (g Graph) index() Index {
	if !isnil(g.index_cache) {
		return *g.index_cache
	}
	return g.build_index()
}

// cache_index builds the graph's index once and keeps it, so that each tool call on
// a graph served for many (the MCP server's) doesn't build it again: on the V tree
// that cost about 0.4 s a call. Only for a graph that isn't changed afterwards, since
// the kept index wouldn't follow a change.
pub fn (mut g Graph) cache_index() {
	// once: a copy of a graph shares the index it had when it was copied
	if !isnil(g.index_cache) {
		return
	}
	idx := g.build_index()
	g.index_cache = &Index{
		...idx
	}
}

fn (g Graph) build_index() Index {
	mut idx := Index{
		mods: g.base.mods
	}
	if !isnil(g.base.under) {
		idx.under = g.base.under.index_cache
	}
	for i, s in g.symbols {
		// Declarations that share an id are one logical declaration, such as a
		// function declared once per platform (`os.read_file` in os.c.v and
		// os_js.js.v, see disambiguate_ids); keep the one shown_before prefers,
		// which explain/get_body/query then show. by_name lists the id once, so
		// resolve doesn't take the copies for rival declarations.
		if s.id !in idx.by_id {
			idx.by_id[s.id] = s
			if !isnil(idx.under) && i >= g.base.own {
				idx.mod_by_name[s.name] << s.id
			} else {
				idx.by_name[s.name] << s.id
			}
		} else if shown_before(s, idx.by_id[s.id]) {
			idx.by_id[s.id] = s
		}
	}
	for s in g.library.symbols {
		if s.id !in idx.lib_by_id {
			idx.lib_by_id[s.id] = s
		}
	}
	for e in g.edges {
		if e.to in idx.lib_by_id && idx.has(e.from) {
			idx.lib_edges << e
			continue
		}
		if e.provenance == .undeclared {
			// no declaration to resolve to (see EdgeProvenance): a unique
			// name match would pin the call on an unrelated declaration, the
			// way a test's `conv` parameter matched `encoding.iconv.conv`. (A
			// call of a function-typed field is resolved to the field by
			// resolve_edges, so it isn't one of these.)
			continue
		}
		to_id := idx.resolve(e.to)
		if to_id == '' || !idx.has(e.from) {
			continue // skip edges to externals/unknowns
		}
		idx.edges << Edge{
			from:       e.from
			to:         to_id
			kind:       e.kind
			provenance: e.provenance
			lines:      e.lines
		}
		idx.adj[e.from] << to_id
		idx.adj[to_id] << e.from
		if e.kind == .calls {
			idx.callees[e.from] << to_id
		}
	}
	if !isnil(idx.under) {
		idx.fall_through()
	}
	return idx
}

// fall_through works out what a layered graph's index takes from the base's beyond
// a lookup: the base's edges into the project's library, the vlib side of the
// adjacency around a declaration of by_id's that a base edge links to (`fix`), and
// how many symbols the base has under the project.
fn (mut idx Index) fall_through() {
	mut touched := map[string]bool{}
	for e in idx.under.edges {
		if !idx.from_under(e.from) {
			continue
		}
		if e.to in idx.lib_by_id {
			idx.lib_edges << e
		} else if e.to in idx.by_id {
			touched[e.from] = true
			touched[e.to] = true
		}
	}
	if touched.len > 0 {
		for e in idx.under.edges {
			if (e.from in touched || e.to in touched) && idx.keeps(e) {
				if e.from in touched {
					idx.fix[e.from] << e.to
				}
				if e.to in touched {
					idx.fix[e.to] << e.from
				}
			}
		}
	}
	mut shadowed := 0
	for id, _ in idx.by_id {
		if id !in idx.mods && idx.under.layer_has(id) {
			shadowed++
		}
	}
	idx.base_count = idx.under.layer.ids.len - shadowed + idx.mods.len
}

// layer_has reports whether a graph layered on the one this indexes has `id`, but
// for the project shadowing it: whether a copy of it is declared in a layered_file.
fn (idx &Index) layer_has(id string) bool {
	return id in idx.layer.ids
}

// from_under reports whether `id` is one of the base's declarations a layered
// graph's index falls through to.
fn (idx &Index) from_under(id string) bool {
	return !isnil(idx.under) && id !in idx.by_id && idx.under.layer_has(id)
}

// keeps reports whether a layered graph has the base's resolved edge `e`: one from a
// declaration under it to another, or to one of its own; one into the library is a
// lib_edges'.
fn (idx &Index) keeps(e Edge) bool {
	return idx.from_under(e.from) && e.to !in idx.lib_by_id
		&& (e.to in idx.by_id || idx.from_under(e.to))
}

// symbol is the declaration `id` names, the base's under a layered graph included.
pub fn (idx &Index) symbol(id string) ?Symbol {
	if s := idx.by_id[id] {
		return s
	}
	if !idx.from_under(id) {
		return none
	}
	if s := idx.under.layer.shown[id] {
		return s
	}
	return idx.under.by_id[id] or { none }
}

// has reports whether `id` names a declaration, the base's under a layered graph
// included.
pub fn (idx &Index) has(id string) bool {
	return id in idx.by_id || idx.from_under(id)
}

// is_base reports whether `id` is one of the declarations a layered graph has from
// under the project: the base's, or a module's from VMODULES.
pub fn (idx &Index) is_base(id string) bool {
	return id in idx.mods || idx.from_under(id)
}

// named lists the ids of the declarations named `name`: the project's, then those
// the base has under it, then the modules'.
pub fn (idx &Index) named(name string) []string {
	mut out := idx.by_name[name] or { []string{} }
	if isnil(idx.under) {
		return out
	}
	if late := idx.under.layer.named[name] {
		for id in late {
			if id !in idx.by_id {
				out << id
			}
		}
	} else {
		for id in idx.under.by_name[name] or { []string{} } {
			if idx.from_under(id) {
				out << id
			}
		}
	}
	out << idx.mod_by_name[name] or { []string{} }
	return out
}

// neighbors_into puts the ids linked to `id` into `out`, in place of what it held:
// the project's edges', then the base's under a layered graph. A walk reuses one
// `out` for every step.
pub fn (idx &Index) neighbors_into(id string, mut out []string) {
	out.clear()
	out << idx.adj[id] or { []string{} }
	if isnil(idx.under) {
		return
	}
	if fixed := idx.fix[id] {
		out << fixed
	} else if idx.from_under(id) {
		for nb in idx.under.adj[id] or { []string{} } {
			if idx.from_under(nb) {
				out << nb
			}
		}
	}
}

// callees_into puts the ids `id` calls into `out`, in place of what it held: the
// project's edges', then the base's from a declaration under a layered graph.
fn (idx &Index) callees_into(id string, mut out []string) {
	out.clear()
	out << idx.callees[id] or { []string{} }
	if idx.from_under(id) {
		for to in idx.under.callees[id] or { []string{} } {
			if idx.has(to) {
				out << to
			}
		}
	}
}

// neighbors lists the ids linked to `id` (neighbors_into).
pub fn (idx &Index) neighbors(id string) []string {
	mut out := []string{}
	idx.neighbors_into(id, mut out)
	return out
}

// edges_of lists the resolved edges from or to `id`, the base's under a layered
// graph included, and then the edges into the library.
fn (idx &Index) edges_of(id string) []Edge {
	mut out := []Edge{}
	for e in idx.edges {
		if e.from == id || e.to == id {
			out << e
		}
	}
	if !isnil(idx.under) && idx.has(id) {
		for e in idx.under.edges {
			if (e.from == id || e.to == id) && idx.keeps(e) {
				out << e
			}
		}
	}
	for e in idx.lib_edges {
		if e.from == id || e.to == id {
			out << e
		}
	}
	return out
}

// shown_before reports whether declaration `a`, met after `b` in g.symbols,
// should represent their shared id in its place: a file that isn't a test before
// one that is, so that a module, whose symbol each of its files declares, is shown
// from one of its own files and not `wayland_pipe_abi_test.c.v`; then a file for
// the C backend (plain `.v` or `.c.v`) before one for another backend, and the JS
// backend's `.js.v` last, since it is the copy furthest from what ordinary V code
// calls; then, between files of one backend, one this host compiles before one
// only another OS or architecture does (`os_nix.c.v` before `os_windows.c.v` on
// macOS), and an OS's own file before the `_default` one V falls back to without it.
// Between files of the same rank the later one wins, as it did before backends were
// ranked; g.symbols follows graph.json, which the same-graph CI job keeps identical
// across hosts.
fn shown_before(a Symbol, b Symbol) bool {
	a_test := is_test_file(a.file)
	if a_test != is_test_file(b.file) {
		return !a_test
	}
	a_backend, b_backend := backend_rank(a.file), backend_rank(b.file)
	if a_backend != b_backend {
		return a_backend < b_backend
	}
	return host_rank(a.file) <= host_rank(b.file)
}

// the OS and architecture graphify runs on, which a declaration shown is compiled for
const host_target = pref.host_target()

// host_rank orders a file by whether this host compiles it: one V compiles here,
// then a `_default` one, which V compiles only when the OS has no file of its own,
// then one for another OS or architecture (pref.file_has_incompatible_target_suffix).
fn host_rank(file string) int {
	name := os.file_name(file)
	if pref.file_has_incompatible_target_suffix(name, host_target) {
		return 2
	}
	if name.ends_with('_default.c.v') || name.ends_with('_default.v') {
		return 1
	}
	return 0
}

// is_test_file reports whether `file` is a test, which only `v test` compiles:
// `os_test.v`, or a platform's `wayland_test.c.v`.
fn is_test_file(file string) bool {
	return os.file_name(file).all_before('.').ends_with('_test')
}

// backend_rank orders a file by the backend its suffix compiles it for.
fn backend_rank(file string) int {
	if file.ends_with('.js.v') {
		return 2
	}
	if file.ends_with('.wasm.v') || file.ends_with('.native.v') {
		return 1
	}
	return 0
}

// resolve maps a raw edge target (an id or a bare name) to a symbol id, or ''
// when it can't be resolved to a single known symbol (e.g. an external call).
fn (idx Index) resolve(target string) string {
	if idx.has(target) {
		return target
	}
	// a layered graph's raw name is the project's, which by_name alone lists: its
	// edges were made among its own declarations, and the base's come resolved
	// (layer_graph)
	ids := idx.by_name[target] or { return '' }
	return if ids.len == 1 { ids[0] } else { '' }
}

// find returns the ids of the symbols `text` describes, best first: those that match
// every word of it, case-insensitively, in their name, signature, file or doc comment;
// when none matches them all, those that match the most. A word in a symbol's name
// counts more than one in its signature, and one there more than one in its file or
// doc, and a name the word is outright most; a tie goes to the project's over the
// base's under a layered graph, then to the shorter name. Words that say nothing about
// code (`the`, `how`, `does`) are left out, unless the text is nothing else. A test's
// declaration scores half. At most max_seeds ids.
pub fn (g Graph) find(text string) []string {
	terms := search_terms(text)
	if terms.len == 0 {
		return []
	}
	mut found := []Found{}
	mut seen := map[string]bool{}
	mut most := 1
	// next by hand: a `for in` walks a copy, whose from_base this one wouldn't say
	mut all := g.all_symbols()
	for {
		s := all.next() or { break }
		if s.id in seen || s.kind == .import_ {
			continue
		}
		name := s.name.to_lower()
		sig := s.signature.to_lower()
		mut matched := 0
		mut score := 0
		for t in terms {
			w := if name == t {
				8
			} else if name.contains(t) {
				4
			} else if sig.contains(t) {
				2
			} else if s.file.to_lower().contains(t) || s.doc.to_lower().contains(t) {
				1
			} else {
				0
			}
			if w > 0 {
				matched++
				score += w
			}
		}
		if matched < most {
			continue
		}
		if matched > most {
			// fewer words than this one are no match any more
			most = matched
			found = found.filter(it.matched >= most)
		}
		seen[s.id] = true
		found << Found{
			id:      s.id
			matched: matched
			// a test's declaration is seldom what a search is after
			score:   if is_test_file(s.file) { score / 2 } else { score }
			base:    all.from_base()
			name:    s.name.len
		}
	}
	found.sort_with_compare(fn (a &Found, b &Found) int {
		if a.score != b.score {
			return if a.score > b.score { -1 } else { 1 }
		}
		if a.base != b.base {
			return if a.base { 1 } else { -1 }
		}
		if a.name != b.name {
			return if a.name < b.name { -1 } else { 1 }
		}
		return 0
	})
	mut out := []string{}
	for f in found {
		if out.len == max_seeds {
			break
		}
		out << f.id
	}
	return out
}

// the most symbols a search seeds a query from: they come first in what it shows, and
// a budget rarely fits more
const max_seeds = 50

// Found is a symbol a search matches (find): how many of its words, how well, whether
// it is the base's, and its name's length.
struct Found {
	id      string
	matched int
	score   int
	base    bool
	name    int
}

// words a search leaves out: ones a question asks in, that name no code
const stop_words = ['a', 'an', 'and', 'are', 'at', 'by', 'code', 'does', 'for', 'from', 'how',
	'in', 'is', 'it', 'of', 'on', 'or', 'that', 'the', 'this', 'to', 'what', 'when', 'where', 'which',
	'who', 'why', 'with']

// search_terms are the lowercased words of a search, without its stop_words, unless
// those are all it has.
fn search_terms(text string) []string {
	words := text.to_lower().fields()
	mut terms := []string{}
	for w in words {
		if w !in stop_words && w !in terms {
			terms << w
		}
	}
	return if terms.len > 0 { terms } else { words }
}

// resolve_one returns the best id for a node reference: the first of
// resolve_all's, or '' when nothing matches.
pub fn (g Graph) resolve_one(query string) string {
	ids := g.resolve_all(query)
	return if ids.len > 0 { ids[0] } else { '' }
}

// resolve_all lists the declarations a node reference names, by the first rule that
// matches: an id; a `file:line` inside a declaration (the declaration starting
// nearest before it); a dotted tail of ids, `TcpConn.wait_for_read` or
// `unix.StreamListener.accept`, each declaration whose id ends with it; a name,
// each declaration of it; else the first declaration whose name contains it.
pub fn (g Graph) resolve_all(query string) []string {
	// An empty reference names nothing: without this guard '' is a substring of
	// every name and the fuzzy pass below would return an arbitrary symbol.
	q := query.trim_space()
	if q == '' {
		return []
	}
	idx := g.index()
	if idx.has(q) {
		return [q]
	}
	if id := g.at_location(q) {
		return [id]
	}
	if q.contains('.') && !q.ends_with('.') {
		mut tails := []string{}
		for id in idx.named(q.all_after_last('.')) {
			if id.ends_with('.' + q) {
				tails << id
			}
		}
		if tails.len > 0 {
			return tails
		}
	}
	named := idx.named(q)
	if named.len > 0 {
		return named
	}
	ql := q.to_lower()
	for s in g.all_symbols() {
		if s.name.to_lower().contains(ql) {
			return [s.id]
		}
	}
	return []
}

// at_location is the declaration a `file:line` reference is in: of those in a file
// whose path ends with `file`, the one that starts nearest before or at `line`;
// none when the reference is no `file:line`, or no declaration is there.
fn (g Graph) at_location(query string) ?string {
	file := query.all_before_last(':')
	n := query.all_after_last(':').int()
	if file == query || n <= 0 || !(file.ends_with('.v') || file.ends_with('.vsh')) {
		return none
	}
	mut best := Symbol{}
	for s in g.all_symbols() {
		if s.line > n || s.line <= best.line || s.kind in [SymbolKind.mod_, .import_] {
			continue
		}
		if s.file == file || s.file.ends_with('/' + file) {
			best = s
		}
	}
	return if best.id == '' { none } else { best.id }
}

// required_tool_args lists, per MCP tool, the arguments it cannot run without.
pub const required_tool_args = {
	'query_graph':   ['text']
	'get_node':      ['node']
	'get_body':      ['node']
	'get_neighbors': ['node']
	'shortest_path': ['a', 'b']
}

// missing_tool_arg returns an error message naming the first required argument
// of `tool` that is absent or blank in `args`, or '' when all are present.
// `args` holds only the arguments the caller actually sent as strings, so a
// JSON null or a non-string never reaches resolve_one as the text "null".
pub fn missing_tool_arg(tool string, args map[string]string) string {
	for name in required_tool_args[tool] or { []string{} } {
		if args[name] or { '' }.trim_space() == '' {
			return '${tool}: missing required argument `${name}`'
		}
	}
	return ''
}

// query seeds from symbols matching `text`, walks outward over the graph
// (breadth-first, or depth-first when `dfs` is set), and returns the body-less
// view of every symbol reached until `budget` tokens (~chars/4) are spent.
pub fn (g Graph) query(text string, budget int, dfs bool) string {
	idx := g.index()
	seeds := g.find(text)
	if seeds.len == 0 {
		return 'no symbols match: ${text}'
	}

	mut visited := map[string]bool{}
	mut order := []string{}
	mut queue := []string{}
	for s in seeds {
		visited[s] = true
		queue << s
	}
	// `head` is a cursor into `queue`, never removed from -- BFS used to dequeue
	// via `queue.first()` + `queue.delete(0)`, which shifts every remaining
	// element down one slot on every single pop. That is only cheap for a
	// small reachable set; a seed sitting in a large, densely-connected
	// component (a real one: "asm" in a real compiler's own codebase reaches
	// 85%+ of a 116k-symbol graph, confirmed on the actual vlang corpus) turns
	// this into genuine O(n^2) work -- confirmed hanging for 8+ CPU-minutes
	// per query and leaking unkillable server processes, not just "slow".
	// DFS still legitimately shrinks `queue` via `.pop()` off the end, which
	// is already O(1); `head` simply stays put in that mode.
	//
	// The `order.len < budget` bound below is a second, independent fix, not
	// just a mitigation for the first: no `budget`-token render can ever need
	// more than `budget` lines (each renders to at least ~1 token in
	// practice), so this can never change what the render loop below would
	// have produced anyway for any query whose reachable set already fit --
	// it only stops walking a component far larger than any budget could use.
	mut head := 0
	mut nbs := []string{}
	for head < queue.len && order.len < budget {
		id := if dfs {
			queue.pop()
		} else {
			queue[head]
		}
		if !dfs {
			head++
		}
		order << id
		idx.neighbors_into(id, mut nbs)
		for nb in nbs {
			if nb !in visited {
				visited[nb] = true
				queue << nb
			}
		}
	}

	mut lines := []string{}
	mut tokens := 0
	for id in order {
		s := idx.symbol(id) or { continue }
		mut line := s.render()
		if s.doc != '' {
			// One line, not explain's full excerpt: query already returns many
			// symbols under a shared budget, so each one gets just enough doc to
			// tell a caller whether it's worth an `explain`/`get_body` follow-up.
			line += '\n  | ' + s.doc.split('\n')[0]
		}
		t := line.len / 4
		if tokens + t > budget && lines.len > 0 {
			break
		}
		lines << line
		tokens += t
	}
	header := '// query: ${text}  (${lines.len} of ${order.len} visited symbols, ~${tokens} tokens)'
	return header + '\n' + lines.join('\n')
}

// shortest_path finds the shortest undirected path between two node references
// and returns the chain of symbol ids ([] if unreachable / not found).
pub fn (g Graph) shortest_path(a string, b string) []string {
	idx := g.index()
	start := g.resolve_one(a)
	goal := g.resolve_one(b)
	if start == '' || goal == '' {
		return []
	}
	if start == goal {
		return [start]
	}
	mut prev := map[string]string{}
	mut visited := map[string]bool{}
	visited[start] = true
	mut queue := [start]
	// Index cursor, not `queue.first()` + `queue.delete(0)` -- see the
	// identical fix (and its rationale) in query() above. A goal that is
	// unreachable, or simply far away in a large component, hits the same
	// O(n^2) blowup this had.
	mut head := 0
	mut nbs := []string{}
	for head < queue.len {
		cur := queue[head]
		head++
		idx.neighbors_into(cur, mut nbs)
		for nb in nbs {
			if nb in visited {
				continue
			}
			visited[nb] = true
			prev[nb] = cur
			if nb == goal {
				return reconstruct(prev, start, goal)
			}
			queue << nb
		}
	}
	return []
}

// call_path finds the shortest chain of calls by which `a` reaches `b`, `a` first,
// as symbol ids ([] when `a` calls nothing that leads to `b`, or either isn't found).
// Unlike shortest_path it follows only `calls` edges, and only the way they go, so
// it doesn't link two functions through a type they both mention.
pub fn (g Graph) call_path(a string, b string) []string {
	paths := g.call_paths(a, b, 1)
	return if paths.len > 0 { paths[0] } else { []string{} }
}

// how many steps longer than the shortest a chain call_paths lists may be
const call_path_slack = 3

// how many steps call_paths takes looking for chains before it stops with those it has
const call_path_steps = 200_000

// call_paths lists the chains of calls by which `a` reaches `b`, up to `max` of them,
// shortest first: each a different route, none through a declaration twice, none more
// than call_path_slack steps longer than the shortest. `http.get` reaches `net.dial_tcp`
// through a pooled transport, a fresh connection or a proxy, and the shortest is the
// one taken least. [] when there is none, or `a` or `b` isn't found.
pub fn (g Graph) call_paths(a string, b string, max int) [][]string {
	paths, _, _ := g.count_call_paths(a, b, max)
	return paths
}

// how many routes count_call_paths counts before it stops counting
const call_path_count_cap = 1000

// count_call_paths is call_paths with how many routes there are in all, by the same
// rules: it goes on past `max`, counting, and says whether the count is all of them
// (false when it stopped at call_path_count_cap routes or call_path_steps steps).
pub fn (g Graph) count_call_paths(a string, b string, max int) ([][]string, int, bool) {
	idx := g.index()
	start := g.resolve_one(a)
	goal := g.resolve_one(b)
	if start == '' || goal == '' || max <= 0 {
		return [][]string{}, 0, true
	}
	if start == goal {
		return [[start]], 1, true
	}
	// what `a` reaches, and the calls among it
	mut callees := map[string][]string{}
	mut queue := [start]
	callees[start] = []string{}
	mut head := 0
	mut next := []string{}
	for head < queue.len {
		cur := queue[head]
		head++
		if cur == goal {
			continue
		}
		idx.callees_into(cur, mut next)
		callees[cur] = next.clone()
		for to in next {
			if to !in callees {
				callees[to] = []string{}
				queue << to
			}
		}
	}
	if goal !in callees {
		return [][]string{}, 0, true
	}
	// how many calls from each of those `b` is, back from `b`
	mut callers := map[string][]string{}
	for from, tos in callees {
		for to in tos {
			callers[to] << from
		}
	}
	mut to_goal := {
		goal: 0
	}
	queue = [goal]
	head = 0
	for head < queue.len {
		cur := queue[head]
		head++
		for from in callers[cur] or { []string{} } {
			if from !in to_goal {
				to_goal[from] = to_goal[cur] + 1
				queue << from
			}
		}
	}
	shortest := to_goal[start] or { return [][]string{}, 0, true }
	mut w := PathWalk{
		callees: callees
		to_goal: to_goal
		goal:    goal
		max:     max
		cap:     call_path_count_cap
		steps:   call_path_steps
	}
	for length in shortest .. shortest + call_path_slack + 1 {
		w.on = {
			start: true
		}
		w.walk([start], length)
		if w.total >= w.cap || w.steps <= 0 {
			break
		}
	}
	return w.found, w.total, w.total < w.cap && w.steps > 0
}

// PathWalk is call_paths' search for the chains of one length: the calls among what
// `a` reaches, how far each is from the goal, the declarations on the chain so far,
// the first `max` chains found, and how many it has found in all.
struct PathWalk {
	callees map[string][]string
	to_goal map[string]int
	goal    string
	max     int
	cap     int
mut:
	steps int
	on    map[string]bool
	found [][]string
	total int
}

// walk extends `path` to every chain of `length` calls that ends at the goal.
fn (mut w PathWalk) walk(path []string, length int) {
	cur := path.last()
	if cur == w.goal {
		if path.len - 1 == length {
			w.total++
			if w.found.len < w.max {
				w.found << path.clone()
			}
		}
		return
	}
	for to in w.callees[cur] or { []string{} } {
		if w.total >= w.cap || w.steps <= 0 {
			return
		}
		w.steps--
		left := w.to_goal[to] or { continue }
		if to in w.on || path.len + left > length {
			continue
		}
		w.on[to] = true
		mut longer := path.clone()
		longer << to
		w.walk(longer, length)
		w.on.delete(to)
	}
}

// render_call_path renders a call_path, one step a line, each call with the lines
// of its call sites in the caller's file:
//
//   get (vlib/net/http/http.v:70)
//     -> fetch (vlib/net/http/http.v:241), called at line 71
pub fn (g Graph) render_call_path(ids []string) string {
	idx := g.index()
	mut out := []string{}
	for i, id in ids {
		loc := if s := idx.symbol(id) { '${s.name} (${s.loc()})' } else { id }
		if i == 0 {
			out << loc
			continue
		}
		mut lines := []int{}
		for e in idx.edges_of(ids[i - 1]) {
			if e.kind == .calls && e.from == ids[i - 1] && e.to == id {
				lines = merge_lines(lines, e.lines)
			}
		}
		out << '  -> ${loc}' + if lines.len > 0 { ', called${at_lines(lines)}' } else { '' }
	}
	return out.join('\n')
}

// path_between answers "how does `a` reach `b`": the chains of calls from `a` to `b`
// (call_paths), up to max_call_paths, shortest first; else those from `b` to `a`, said
// so; else the shortest link through any relation (shortest_path), said so. '' when
// nothing links them.
pub fn (g Graph) path_between(a string, b string) string {
	forward, total, exact := g.count_call_paths(a, b, max_call_paths)
	if forward.len > 0 {
		return g.render_call_paths(forward, total, exact)
	}
	back, back_total, back_exact := g.count_call_paths(b, a, max_call_paths)
	if back.len > 0 {
		return "(`${a}` doesn't reach `${b}` by calls, but `${b}` reaches `${a}`:)\n" +
			g.render_call_paths(back, back_total, back_exact)
	}
	any := g.shortest_path(a, b)
	if any.len > 0 {
		return '(no chain of calls links them either way; the shortest link through any relation, calls, types or modules, either way:)\n' +
			g.names(any).join(' -- ')
	}
	return ''
}

// the most chains of calls path_between shows
const max_call_paths = 5

// render_call_paths renders chains of calls (render_call_path): one as it is, several
// numbered, after a line that says how many there are in all (`total`, at least that
// many when not `exact`) and how many of them follow.
pub fn (g Graph) render_call_paths(paths [][]string, total int, exact bool) string {
	if paths.len == 1 && total == 1 {
		return g.render_call_path(paths[0])
	}
	first := g.index().symbol(paths[0][0]) or { Symbol{ name: paths[0][0] } }
	last := g.index().symbol(paths[0].last()) or { Symbol{ name: paths[0].last() } }
	all := if exact { '${total}' } else { 'at least ${total}' }
	shown := if paths.len < total { '; the ${paths.len} shortest' } else { '' }
	mut out := ['${all} chains of calls from ${first.name} to ${last.name}, at most ${call_path_slack} calls longer than the shortest${shown}:']
	for i, p in paths {
		out << ''
		out << '${i + 1}. ' + g.render_call_path(p)
	}
	return out.join('\n')
}

fn reconstruct(prev map[string]string, start string, goal string) []string {
	mut path := [goal]
	mut cur := goal
	for cur != start {
		cur = prev[cur] or { return [] }
		path.prepend(cur)
	}
	return path
}

// explain summarizes one node: its signature/location, what it defines or is
// defined by, and what it calls / is called by.
// A name with several declarations is each of them: up to max_shown in full, one
// after another, or more as a list to name one from.
pub fn (g Graph) explain(node string) string {
	idx := g.index()
	mut ids := g.resolve_all(node)
	if ids.len == 0 && node in idx.lib_by_id {
		// a library declaration, named by its id (`vlib.os.join_path`)
		ids = [node]
	}
	if ids.len == 0 {
		return 'no symbol matches: ${node}'
	}
	if ids.len == 1 {
		return g.explain_id(ids[0], true)
	}
	if ids.len > max_shown {
		return g.list_declarations(node, ids)
	}
	mut out := ['`${node}` names ${ids.len} declarations; each follows.']
	for id in ids {
		out << ''
		out << g.explain_id(id, false)
	}
	return out.join('\n')
}

// how many declarations of one name explain shows in full, and get_body reads
const max_shown = 8
const max_bodies = 4

// list_declarations lists the declarations `ids` that a name `node` has, with how
// many calls each has, for a name with more than max_shown of them.
fn (g Graph) list_declarations(node string, ids []string) string {
	idx := g.index()
	mut out := ['`${node}` names ${ids.len} declarations, the most called first; get_node one by its id, or as Type.method or file:line:']
	mut rows := []DeclRow{cap: ids.len}
	for id in ids {
		s := idx.symbol(id) or { continue }
		rows << DeclRow{
			s:       s
			callers: idx.edges_of(id).filter(it.kind == .calls && it.to == id).len
		}
	}
	rows.sort_with_compare(fn (a &DeclRow, b &DeclRow) int {
		return b.callers - a.callers
	})
	shown := if rows.len > 40 { rows[..40] } else { rows }
	for r in shown {
		mark := if idx.is_base(r.s.id) { ' [library]' } else { '' }
		out << '  ${r.s.kind.str()} ${r.s.id}  (${r.s.loc()})${mark}, ${r.callers} caller(s)'
	}
	if rows.len > shown.len {
		out << '  … (${rows.len - shown.len} more)'
	}
	return out.join('\n')
}

struct DeclRow {
	s       Symbol
	callers int
}

// build_mark is ` [$if use_openssl ?]` for a declaration only some builds have
// (Symbol.build), and nothing for one every build has.
fn (s Symbol) build_mark() string {
	return if s.build == '' { '' } else { ' [\$if ${s.build}]' }
}

// other_builds lists the declarations of `s`'s id in other files that another
// build compiles in its place: `ssl.SSLConn` is `mbedtls.SSLConn` in
// ssl_notd_use_openssl.v and `openssl.SSLConn` in ssl_d_use_openssl.v, one id that
// the index shows from one file.
fn (g Graph) other_builds(s Symbol) []string {
	mut out := []string{}
	for o in g.all_symbols() {
		if o.id == s.id && o.file != s.file && (o.build != '' || s.build != '') {
			out << '${o.signature} (${o.loc()})${o.build_mark()}'
		}
	}
	for o in g.library.symbols {
		if o.id == s.id && o.file != s.file && (o.build != '' || s.build != '') {
			out << '${o.signature} (${o.loc()})${o.build_mark()}'
		}
	}
	return out
}

// explain_id summarizes the declaration `id`; with `uncertain`, the call sites of its
// name that couldn't be put on one of its declarations as well, which a list of all
// of them leaves out.
fn (g Graph) explain_id(id string, uncertain bool) string {
	idx := g.index()
	node := id
	s := idx.symbol(id) or { idx.lib_by_id[id] or { return 'no symbol matches: ${node}' } }

	mark := if idx.is_base(id) || id in idx.lib_by_id { ' [library]' } else { '' }
	mut out := ['${s.kind.str()} ${s.name}  (${s.loc()})${mark}${s.build_mark()}', s.render()]
	others := g.other_builds(s)
	if others.len > 0 {
		out << 'other builds  : ' + others.join(', ')
	}
	// The doc comment is often the whole answer to "what does this do", which
	// otherwise costs a file read. Capped so one rambling comment cannot blow
	// the budget this tool exists to protect.
	if s.doc != '' {
		dlines := s.doc.split('\n')
		shown := if dlines.len > 8 { dlines[..8] } else { dlines }
		mut d := shown.map('  | ' + it).join('\n')
		if dlines.len > shown.len {
			d += '\n  | … (${dlines.len - shown.len} more lines — use get_body for the full source)'
		}
		out << d
	}

	mut calls := CallList{}
	mut called_by := CallList{}
	mut defines := []string{}
	mut defined_in := []string{}
	mut references := []string{}
	mut referenced_by := []string{}
	mut embeds := []string{}
	mut any_inferred := false
	for e in idx.edges_of(id) {
		if e.from == id {
			match e.kind {
				.calls {
					calls.add(label(idx, e.to) + prov_suffix(e.provenance), e.lines)
					any_inferred = any_inferred || e.provenance == .inferred
				}
				.defines { defines << label(idx, e.to) }
				.references {
					references << label(idx, e.to) + prov_suffix(e.provenance)
					any_inferred = any_inferred || e.provenance == .inferred
				}
				.embeds {
					embeds << label(idx, e.to) + prov_suffix(e.provenance)
					any_inferred = any_inferred || e.provenance == .inferred
				}
				else {}
			}
		}
		if e.to == id {
			match e.kind {
				.calls {
					called_by.add(label(idx, e.from) + prov_suffix(e.provenance), e.lines)
					any_inferred = any_inferred || e.provenance == .inferred
				}
				.defines { defined_in << label(idx, e.from) }
				.references {
					referenced_by << label(idx, e.from) + prov_suffix(e.provenance)
					any_inferred = any_inferred || e.provenance == .inferred
				}
				else {}
			}
		}
	}
	if defined_in.len > 0 {
		out << 'defined in    : ${capped(defined_in)}'
	}
	if defines.len > 0 {
		out << 'defines       : ${capped(defines)}'
	}
	if embeds.len > 0 {
		out << 'embeds        : ${capped(embeds)}'
	}
	if references.len > 0 {
		out << 'references    : ${capped(references)}'
	}
	if referenced_by.len > 0 {
		out << 'referenced by : ${capped(referenced_by)}'
	}
	if calls.labels.len > 0 {
		out << 'calls         : ${capped(calls.items())}'
	}
	if called_by.labels.len > 0 {
		out << 'called by     : ${capped(called_by.items())}'
	}
	if any_inferred {
		out << '  ^ [inferred] = picked among several same-named candidates by the inferred receiver type or by locality/visibility, not a name that was unambiguous outright — see the edge provenance note in README'
	}
	// A call whose name matches several declarations cannot be attributed to
	// one of them, so index() drops it and the `called by` line above silently
	// looks complete when it is not. Surface those call sites separately and
	// say plainly why they are uncertain — a short hedged list beats claiming
	// a symbol has no callers when it has dozens.
	if uncertain && s.kind in [SymbolKind.function, .method] {
		same_name := idx.named(s.name)
		if same_name.len > 1 {
			mut maybe := []string{}
			for e in g.edges {
				if e.kind == .calls && e.to == s.name && idx.has(e.from)
					&& e.provenance != .undeclared {
					maybe << label(idx, e.from) + at_lines(e.lines)
				}
			}
			// and the base's, from the declarations under a layered graph
			if !isnil(idx.under) {
				for e in idx.under.edges {
					if e.kind == .calls && e.to == s.name && idx.from_under(e.from)
						&& e.provenance != .undeclared {
						maybe << label(idx, e.from) + at_lines(e.lines)
					}
				}
			}
			maybe = uniq(maybe)
			if maybe.len > 0 {
				shown := if maybe.len > 10 { maybe[..10] } else { maybe }
				more := if maybe.len > shown.len {
					' (+${maybe.len - shown.len} more)'
				} else {
					''
				}
				out << 'possibly called by: ${shown.join(', ')}${more}' +
					'\n  ^ `${s.name}` has ${same_name.len} declarations, so these call sites could not be attributed to one of them'
			}
		}
	}
	if s.kind in [SymbolKind.function, .method, .struct_] {
		out << '(use `get_body ${s.name}` to read its source)'
	}
	return out.join('\n')
}

// CallList is a `calls` or `called by` list, each declaration once with the lines of
// its call sites (Edge.lines): two edges between the same declarations, which calls
// under different comptime conditions make, are one entry.
struct CallList {
mut:
	labels []string
	lines  map[string][]int
}

fn (mut c CallList) add(label string, lines []int) {
	if label !in c.lines {
		c.labels << label
		c.lines[label] = []int{}
	}
	c.lines[label] = merge_lines(c.lines[label], lines)
}

// items renders each entry, `read_ptr (vlib/net/tcp.c.v:183) at lines 198, 224`: the
// lines are in the caller's file.
fn (c CallList) items() []string {
	return c.labels.map(it + at_lines(c.lines[it]))
}

// at_lines renders call-site lines, ' at line 198' or ' at lines 198, 224'; '' for none.
fn at_lines(lines []int) string {
	return match lines.len {
		0 { '' }
		1 { ' at line ${lines[0]}' }
		else { ' at lines ${lines.map(it.str()).join(', ')}' }
	}
}

// explain_list_cap bounds each relation list explain prints. A widely used
// symbol has thousands of relations (`vlib.v.flat.NodeId` is referenced by over
// 4,000 declarations, 270,000 characters), more than an MCP client accepts in
// one result; the count of the rest says how widely it is used.
const explain_list_cap = 40

// capped renders a relation list, deduplicated, with at most explain_list_cap
// entries and a count of the rest.
fn capped(items []string) string {
	all := uniq(items)
	if all.len <= explain_list_cap {
		return all.join(', ')
	}
	return all[..explain_list_cap].join(', ') + ' … (+${all.len - explain_list_cap} more)'
}

fn name_of(idx Index, id string) string {
	s := idx.symbol(id) or { return id }
	return s.name
}

// label renders `name (file:line)` for a related symbol, falling back to its raw id.
// A library declaration is marked, `contains (vlib/builtin/string.v:1773) [library]`.
fn label(idx Index, id string) string {
	if s := idx.symbol(id) {
		mark := if idx.is_base(id) { ' [library]' } else { '' }
		return '${s.name} (${s.loc()})${mark}'
	}
	if s := idx.lib_by_id[id] {
		return '${s.name} (${s.loc()}) [library]'
	}
	return id
}

// prov_suffix marks a resolved `calls` edge that resolve_callee had to
// disambiguate among several real candidates, rather than one whose name was
// unambiguous outright (see EdgeProvenance).
fn prov_suffix(p EdgeProvenance) string {
	return if p == .inferred { ' [inferred]' } else { '' }
}

fn uniq(a []string) []string {
	mut seen := map[string]bool{}
	mut out := []string{}
	for x in a {
		if x !in seen {
			seen[x] = true
			out << x
		}
	}
	return out
}

// source_root picks the root a given symbol's `file` is relative to: its
// own source's root when `g.roots` is populated (a merged graph — see
// merge_graphs), or the graph's single root otherwise, unchanged from
// before merged graphs were supported.
fn (g Graph) source_root(s Symbol) string {
	if g.from_base(s.id) {
		return g.base.root
	}
	for label, root in g.roots {
		if s.id.starts_with(label + '::') {
			return root
		}
	}
	return g.root
}

// get_body returns the source of a single declaration (by name or id), read
// from disk by its captured line range — so a caller can fetch one function
// instead of reading a whole file.
//
// A name with several declarations is each of their bodies, up to max_bodies, or a
// list of them to name one from.
pub fn (g Graph) get_body(node string) string {
	idx := g.index()
	ids := g.resolve_all(node)
	if ids.len == 0 {
		if ls := idx.lib_by_id[node] {
			return g.library_body(ls)
		}
		return 'no symbol matches: ${node}'
	}
	if ids.len > max_bodies {
		return g.list_declarations(node, ids)
	}
	if ids.len > 1 {
		return ids.map(g.body_of(it)).join('\n\n')
	}
	return g.body_of(ids[0])
}

// body_of is the source of the declaration `id`.
fn (g Graph) body_of(id string) string {
	idx := g.index()
	s := idx.symbol(id) or { return 'no symbol matches: ${id}' }
	// a layered module from VMODULES is read where the library was (layer_graph)
	path := if s.id in idx.mods && s.file.starts_with(lib_vmodules_prefix) {
		g.library.path_of(s.file) or { return 'cannot read ${s.file}: no library root' }
	} else {
		os.join_path(g.source_root(s), s.file)
	}
	src := os.read_file(path) or { return 'cannot read ${s.file}: ${err}' }
	// a CRLF file (a Windows checkout with core.autocrlf) would otherwise
	// leave a `\r` on every line, and the closing-brace checks below would
	// never match
	lines := src.replace('\r\n', '\n').split('\n')
	// the file's text as the extract read it: a change since then means the
	// captured line range may no longer be this declaration's
	mut drift := ''
	recorded := if idx.from_under(s.id) {
		g.base.under.file_hashes[s.file] or { '' }
	} else if s.id in idx.mods {
		''
	} else {
		g.file_hashes[s.file] or { '' }
	}
	if recorded != '' {
		if recorded != text_hash(src) {
			drift = '// ${s.file} has changed since the graph was built, so this body may not match it\n'
		}
	}
	start := if s.line > 0 { s.line - 1 } else { 0 }
	end := decl_end(lines, s, g.symbols_of(s.file))
	if start >= lines.len {
		return '(no source)'
	}
	return drift + '// ${s.file}:${s.line}-${end}\n' + lines[start..end].join('\n')
}

// library_body is get_body for a library declaration, read from the library's root.
// Its end_line is the last line of its body, found at extraction from all the
// declarations of its file (with_body_ends), since the graph keeps only some.
fn (g Graph) library_body(s Symbol) string {
	path := g.library.path_of(s.file) or { return 'cannot read ${s.file}: no library root' }
	src := os.read_file(path) or { return 'cannot read ${s.file}: ${err}' }
	lines := src.replace('\r\n', '\n').split('\n')
	start := if s.line > 0 { s.line - 1 } else { 0 }
	mut end := if s.end_line >= s.line { s.end_line } else { decl_end(lines, s, []Symbol{}) }
	if end > lines.len {
		end = lines.len
	}
	if start >= lines.len || end <= start {
		return '(no source)'
	}
	return '// ${s.file}:${s.line}-${end} (library)\n' + lines[start..end].join('\n')
}

// decl_end is the last line, 1-based, of declaration `s` in its file's `lines`;
// `siblings` are the declarations extracted from that file, which bound it when its
// own end line can't be told (a function's end_line is the end of its header).
fn decl_end(lines []string, s Symbol, siblings []Symbol) int {
	start := if s.line > 0 { s.line - 1 } else { 0 }
	mut end := if s.end_line > s.line { s.end_line } else { 0 }
	if s.kind in [.function, .method] {
		// A function's end_line is the last line of its header. When no `{`
		// opens a body there, the declaration has none (`pub fn (a array)
		// contains(value voidptr) bool` in a .c.v file), and the header is all
		// of it; reading on to the next declaration would serve the blank lines
		// and doc comment in between.
		header_end := if s.end_line > s.line { s.end_line } else { s.line }
		if header_end >= 1 && header_end <= lines.len
			&& !lines[header_end - 1].all_before('//').contains('{') {
			end = header_end
		}
	}
	if end == 0 {
		// no reliable end line (e.g. fn bodies) — stop just before the next
		// same-level declaration in this file, or at EOF.
		mut next := lines.len + 1
		for o in siblings {
			if o.file == s.file && o.parent == s.parent && o.line > s.line && o.line < next {
				next = o.line
			}
		}
		end = next - 1
		// A declaration indented inside a block (a file-scope `$if`) is followed by
		// that block's closing brace and by the text of branches the parser did not
		// keep, so the last brace in the gap is not necessarily its own; only its
		// indentation tells them apart. A top-level declaration has nothing around
		// it, so it takes the trim below, which also survives a `}` at column 0
		// inside a multi-line string.
		// (start can lie past the end of a file that shrank since the graph was
		// built; the `(no source)` check in get_body handles that.)
		indent := if start < lines.len {
			lines[start][..lines[start].len - lines[start].trim_left(' \t').len]
		} else {
			''
		}
		own_end := if indent != '' { nested_decl_end(lines, start, end, indent) } else { 0 }
		if own_end > 0 {
			end = own_end
		} else {
			// The gap before the next *extracted* symbol can hold blank lines, doc
			// comments for the next declaration, and declarations graphify does not
			// model at all (a `__global`, say) — all of which would be served as if
			// they were part of this body. Trim back to this declaration's own
			// closing brace, which vfmt puts alone on its line.
			for e := end; e > start; e-- {
				if e - 1 < lines.len && lines[e - 1].trim_space() == '}' {
					end = e
					break
				}
			}
		}
	}
	if end > lines.len {
		end = lines.len
	}
	return end
}

// nested_decl_end finds where a declaration that is indented inside a block
// ends, as a 1-based line number, or 0 when it cannot tell. `start` is the
// 0-based index of its first line, `gap_end` the 1-based last line it may use
// (just before the next declaration), `indent` the whitespace its first line
// starts with. A one-line declaration closes on its own line; otherwise the
// first line after the header that is a lone `}` at exactly `indent` closes it,
// because everything inside the body is indented deeper and everything that
// follows it at the same depth is another declaration.
fn nested_decl_end(lines []string, start int, gap_end int, indent string) int {
	first := lines[start].trim_space()
	if first.ends_with('}') && first.contains('{') {
		return start + 1
	}
	for i in start + 1 .. gap_end {
		line := lines[i]
		if line.trim_space() == '}' && line[..line.len - line.trim_left(' \t').len] == indent {
			return i + 1
		}
	}
	return 0
}

// names maps a list of symbol ids to their display names (for path output).
pub fn (g Graph) names(ids []string) []string {
	idx := g.index()
	return ids.map(name_of(idx, it))
}

// neighbor_names returns the display names of every symbol directly linked to
// `node` (either direction), deduplicated. Empty if the node is unknown.
pub fn (g Graph) neighbor_names(node string) []string {
	idx := g.index()
	id := g.resolve_one(node)
	if id == '' {
		return []
	}
	mut seen := map[string]bool{}
	mut out := []string{}
	for nb in idx.neighbors(id) {
		name := name_of(idx, nb)
		if name !in seen {
			seen[name] = true
			out << name
		}
	}
	return out
}

// Symbols walks a graph's symbols, a layered graph's in the order they would have
// if it held the base's: the project's, then each of the base's under it, then the
// modules' from VMODULES.
pub struct Symbols {
	own   []Symbol
	under []Symbol
	at    []int // where under's layered symbols are (Layer.at)
	mods  []Symbol
	idx   Index
mut:
	part int
	i    int
}

// all_symbols walks the graph's symbols (Symbols).
pub fn (g Graph) all_symbols() Symbols {
	if isnil(g.base.under) {
		return Symbols{
			own: g.symbols
		}
	}
	idx := g.index()
	return Symbols{
		own:   g.symbols[..g.base.own]
		under: g.base.under.symbols
		at:    idx.under.layer.at
		mods:  g.symbols[g.base.own..]
		idx:   idx
	}
}

pub fn (mut it Symbols) next() ?Symbol {
	for it.part < 3 {
		if it.part == 0 && it.i < it.own.len {
			it.i++
			return it.own[it.i - 1]
		}
		if it.part == 1 {
			for it.i < it.at.len {
				s := it.under[it.at[it.i]]
				it.i++
				// as layer_graph's: in a vlib file, with an id the project doesn't have
				if s.id !in it.idx.by_id {
					return s
				}
			}
		}
		if it.part == 2 && it.i < it.mods.len {
			it.i++
			return it.mods[it.i - 1]
		}
		it.part++
		it.i = 0
	}
	return none
}

// from_base reports whether the symbol next returned last is one a layered graph
// has from under the project.
fn (it &Symbols) from_base() bool {
	return it.part > 0
}

// from_base reports whether `id` is one of the declarations a layered graph has
// from under the project (Index.is_base).
fn (g Graph) from_base(id string) bool {
	return !isnil(g.base.under) && g.index().is_base(id)
}

// symbols_of lists the declarations of `file`, or all of a graph not layered, whose
// own are all there is to look through.
fn (g Graph) symbols_of(file string) []Symbol {
	if isnil(g.base.under) {
		return g.symbols
	}
	mut out := []Symbol{}
	for s in g.all_symbols() {
		if s.file == file {
			out << s
		}
	}
	return out
}
