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
	// the build each declaration needs (Symbol.build), by id, and each call (Edge.build),
	// by `from` and `to` joined by \0, where some build doesn't have it: the conditions
	// call_paths keeps a route to. For an id that several files declare, the build of
	// any of them.
	builds      map[string]string
	call_builds map[string]string
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
		first := s.id !in idx.by_id
		if first {
			idx.by_id[s.id] = s
			if !isnil(idx.under) && i >= g.base.own {
				idx.mod_by_name[s.name] << s.id
			} else {
				idx.by_name[s.name] << s.id
			}
		} else if shown_before(s, idx.by_id[s.id]) {
			idx.by_id[s.id] = s
		}
		if first {
			if s.build != '' {
				idx.builds[s.id] = s.build
			}
		} else if b := idx.builds[s.id] {
			// a call reaches whichever copy a build compiles
			either := either_build(b, s.build)
			if either == '' {
				idx.builds.delete(s.id)
			} else {
				idx.builds[s.id] = either
			}
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
			build:      e.build
		}
		idx.adj[e.from] << to_id
		idx.adj[to_id] << e.from
		if e.kind == .calls {
			key := e.from + '\0' + to_id
			if b := idx.call_builds[key] {
				either := either_build(b, e.build)
				if either == '' {
					idx.call_builds.delete(key)
				} else {
					idx.call_builds[key] = either
				}
			} else if e.build != '' && to_id !in idx.callees[e.from] {
				// (an earlier edge to the same callee without one stands for every build)
				idx.call_builds[key] = e.build
			}
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

// decl_build is the build declaration `id` needs (Index.builds), the base's under a
// layered graph included: '' for every build.
fn (idx &Index) decl_build(id string) string {
	if id in idx.by_id {
		return idx.builds[id] or { '' }
	}
	if idx.from_under(id) {
		return idx.under.builds[id] or { '' }
	}
	return ''
}

// call_build is the build under which `from` calls `to` (Index.call_builds), the
// base's under a layered graph included: '' for every build.
fn (idx &Index) call_build(from string, to string) string {
	if from in idx.by_id {
		return idx.call_builds[from + '\0' + to] or { '' }
	}
	if idx.from_under(from) {
		return idx.under.call_builds[from + '\0' + to] or { '' }
	}
	return ''
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

// how many steps longer than the shortest a chain call_paths lists may be. The routes
// of a build the default one lacks are the long ones: of the 17 from `http.get` to
// `net.dial_tcp`, the 10 that need `use_openssl ?` are up to 9 longer than the
// shortest, and 3 was far enough for only 3 of them. It is cheap to look this far (about
// 3,000 of call_path_steps' 200,000 steps there), and call_path_steps and
// call_path_count_cap bound a search that isn't.
const call_path_slack = 10

// how many steps call_paths takes looking for chains before it stops with those it has
const call_path_steps = 200_000

// call_paths lists the chains of calls by which `a` reaches `b`, up to `max` of them,
// shortest first: each a different route, none through a declaration twice, none more
// than call_path_slack steps longer than the shortest, and none whose builds
// contradict each other (route_terms). `http.get` reaches `net.dial_tcp` through a
// pooled transport, a fresh connection or a proxy, and the shortest is the one taken
// least. Those the default build has (default_term) come first. [] when there is none,
// or `a` or `b` isn't found.
pub fn (g Graph) call_paths(a string, b string, max int) [][]string {
	return g.count_call_paths(a, b, max).paths
}

// how many routes count_call_paths counts before it stops counting
const call_path_count_cap = 1000

// CallRoutes is count_call_paths' answer: the first `max` routes, those the default
// build has first, how many there are in all and how many of them the default build
// has, and whether the count is all of them (false when it stopped at
// call_path_count_cap routes or call_path_steps steps).
pub struct CallRoutes {
pub:
	paths      [][]string
	total      int
	in_default int
	exact      bool = true
	// how many routes the default build hasn't, by the build each needs
	other_builds map[string]int
}

// count_call_paths is call_paths with how many routes there are in all, by the same
// rules: it goes on past `max`, counting.
pub fn (g Graph) count_call_paths(a string, b string, max int) CallRoutes {
	idx := g.index()
	start := g.resolve_one(a)
	goal := g.resolve_one(b)
	if start == '' || goal == '' || max <= 0 {
		return CallRoutes{}
	}
	if start == goal {
		return CallRoutes{
			paths:      [[start]]
			total:      1
			in_default: 1
		}
	}
	// what `a` reaches, and the calls among it, with the terms of each call's build
	// and its callee's
	mut callees := map[string][]string{}
	mut step_terms := map[string][]string{}
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
			terms := idx.step_terms(cur, to)
			if terms.len > 0 {
				step_terms[cur + '\0' + to] = terms
			}
			if to !in callees {
				callees[to] = []string{}
				queue << to
			}
		}
	}
	if goal !in callees {
		return CallRoutes{}
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
	shortest := to_goal[start] or { return CallRoutes{} }
	mut w := PathWalk{
		callees:    callees
		step_terms: step_terms
		to_goal:    to_goal
		goal:       goal
		max:        max
		cap:        call_path_count_cap
		steps:      call_path_steps
	}
	for length in shortest .. shortest + call_path_slack + 1 {
		w.on = {
			start: true
		}
		w.terms = map[string]int{}
		w.add_terms(build_terms(idx.decl_build(start)))
		w.walk([start], length)
		if w.total >= w.cap || w.steps <= 0 {
			break
		}
	}
	mut paths := w.found.clone()
	for p in w.found_other {
		if paths.len >= max {
			break
		}
		paths << p
	}
	return CallRoutes{
		paths:        paths
		total:        w.total
		in_default:   w.total_default
		other_builds: w.other_builds
		exact:        w.total < w.cap && w.steps > 0
	}
}

// PathWalk is call_paths' search for the chains of one length: the calls among what
// `a` reaches, the terms of each one's build (keyed `from`\0`to`), how far each is
// from the goal, the declarations on the chain so far and the terms of their builds,
// the first `max` chains found that the default build has and the first `max` it
// hasn't, and how many it has found in all and in the default build.
struct PathWalk {
	callees    map[string][]string
	step_terms map[string][]string
	to_goal    map[string]int
	goal       string
	max        int
	cap        int
mut:
	steps         int
	on            map[string]bool
	terms         map[string]int
	found         [][]string
	found_other   [][]string
	total         int
	total_default int
	other_builds  map[string]int
}

// walk extends `path` to every chain of `length` calls that ends at the goal and
// whose builds don't contradict each other.
fn (mut w PathWalk) walk(path []string, length int) {
	cur := path.last()
	if cur == w.goal {
		if path.len - 1 == length {
			w.total++
			if w.terms.keys().all(default_term(it)) {
				w.total_default++
				if w.found.len < w.max {
					w.found << path.clone()
				}
			} else {
				// sorted: routes that need the same builds meet them in another order
				mut need := w.terms.keys()
				need.sort()
				w.other_builds[terms_build(need)]++
				if w.found_other.len < w.max {
					w.found_other << path.clone()
				}
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
		terms := w.step_terms[cur + '\0' + to] or { []string{} }
		if w.contradicts(terms) {
			continue
		}
		w.on[to] = true
		w.add_terms(terms)
		mut longer := path.clone()
		longer << to
		w.walk(longer, length)
		w.on.delete(to)
		for t in terms {
			w.terms[t]--
			if w.terms[t] == 0 {
				w.terms.delete(t)
			}
		}
	}
}

// contradicts reports whether a route that takes a step with `terms`, the builds of
// its call and its callee, is in no build: some term has its opposite among them, or
// among the terms of the chain so far.
fn (w &PathWalk) contradicts(terms []string) bool {
	for t in terms {
		opposite := opposite_term(t)
		if opposite in terms || opposite in w.terms {
			return true
		}
	}
	return false
}

fn (mut w PathWalk) add_terms(terms []string) {
	for t in terms {
		w.terms[t]++
	}
}

// build_terms splits a build into the conditions joined by `&&` outside any brackets,
// each without brackets around the whole of it: `a ? && (b || c)` is `a ?` and
// `b || c`. `&&` binds tighter than `||`, so a build with an `||` outside its brackets
// is one term: `a ? && b ? || c ? && d ?` is not `a ?` and `b ? || c ?` and `d ?`.
fn build_terms(cond string) []string {
	if split_build(cond, `|`).len > 1 {
		return [cond.trim_space()]
	}
	return split_build(cond, `&`)
}

// split_build splits a build at each `&&` (`op` is `&`) or `||` (`|`) outside any
// brackets, into the conditions it joins, each without brackets around the whole of it.
fn split_build(cond string, op u8) []string {
	mut out := []string{}
	mut depth := 0
	mut from := 0
	for i := 0; i <= cond.len; i++ {
		if i < cond.len {
			match cond[i] {
				`(` {
					depth++
					continue
				}
				`)` {
					depth--
					continue
				}
				else {
					if cond[i] != op || depth != 0 || i + 1 >= cond.len || cond[i + 1] != op {
						continue
					}
				}
			}
		}
		t := unbracketed(cond[from..i].trim_space())
		if t != '' && t !in out {
			out << t
		}
		from = i + 2
		i++
	}
	return out
}

// unbracketed is `cond` without the brackets around the whole of it, if it has them.
fn unbracketed(cond string) string {
	mut c := cond
	for c.starts_with('(') && c.ends_with(')') {
		mut depth := 0
		for i := 0; i < c.len; i++ {
			if c[i] == `(` {
				depth++
			} else if c[i] == `)` {
				depth--
				if depth == 0 && i < c.len - 1 {
					return c
				}
			}
		}
		c = c[1..c.len - 1].trim_space()
	}
	return c
}

// opposite_term is the condition that holds just when the term `t` doesn't: `!x ?`
// for `x ?`, and `a || b` for `!(a || b)`. A route with both is in no build.
fn opposite_term(t string) string {
	if t.starts_with('!(') {
		inner := unbracketed(t[1..])
		if inner != t[1..] {
			return inner
		}
	}
	return unbracketed(negate_build(t))
}

// option_terms are the names a `$if` tests that only an option on the command line
// makes true: `-prod`, `-g` (`debug`), `v test`, `-profile`, `-autofree`, `-nofloat`,
// `-freestanding`, `-prealloc`, `-no-bounds-checking`, and the backends other than C's
// that V names there (`js` with its variants, and `native`). Others that are not
// listed, such as `wasm32`, are taken for the default build's.
const option_terms = ['prod', 'debug', 'test', 'profile', 'autofree', 'nofloat', 'freestanding',
	'prealloc', 'no_bounds_checking', 'js', 'js_node', 'js_browser', 'js_freestanding', 'native']

// default_term reports whether a build term can hold without an option on the command
// line: some alternative of it, joined by `||`, has only names that do. A `-d` flag
// (`x ?`) and an option_terms name don't; a term naming an OS, an architecture or a C
// compiler holds on a host's default build, and so does the opposite of any name.
fn default_term(t string) bool {
	for alt in split_build(t, `|`) {
		if split_build(alt, `&`).all(default_conjunct(it)) {
			return true
		}
	}
	return false
}

// default_conjunct is default_term for one name joined by `&&`, or a group of
// alternatives in brackets.
fn default_conjunct(c string) bool {
	if split_build(c, `|`).len > 1 {
		return default_term(c)
	}
	return !(c.ends_with(' ?') && !c.starts_with('!')) && c !in option_terms
}

// step_terms is the terms of the builds that a call from `from` to `to` and its
// callee need (build_terms).
fn (idx &Index) step_terms(from string, to string) []string {
	return build_terms(join_build(idx.call_build(from, to), idx.decl_build(to)))
}

// route_build is the build a chain of calls needs: the terms of its declarations' and
// its calls' builds, joined by `&&`; '' when every build has it.
fn (idx &Index) route_build(ids []string) string {
	mut terms := build_terms(idx.decl_build(ids[0]))
	for i in 1 .. ids.len {
		for t in idx.step_terms(ids[i - 1], ids[i]) {
			if t !in terms {
				terms << t
			}
		}
	}
	return terms_build(terms)
}

// terms_build joins build terms back into one build.
fn terms_build(terms []string) string {
	return terms.map(grouped_build(it)).join(' && ')
}

// render_call_path renders a call_path, one step a line, each call with the lines
// of its call sites in the caller's file and, for a call or callee only some builds
// have, their build; then the build the whole chain needs, if not every build:
//
//   get (vlib/net/http/http.v:70)
//     -> fetch (vlib/net/http/http.v:241), called at line 71
//     -> ssl_do (vlib/net/http/backend.c.v:9), called at line 400 [$if !windows]
//   needs $if !windows
pub fn (g Graph) render_call_path(ids []string) string {
	idx := g.index()
	// the lines of each step's call, in the file of the declaration it is made from
	mut call_lines := [][]int{len: ids.len}
	for i in 1 .. ids.len {
		for e in idx.edges_of(ids[i - 1]) {
			if e.kind == .calls && e.from == ids[i - 1] && e.to == ids[i] {
				call_lines[i] = merge_lines(call_lines[i], e.lines)
			}
		}
	}
	// the declarations of the route's ids, in one pass over the graph
	mut copies := map[string][]Symbol{}
	for id in ids {
		copies[id] = []Symbol{}
	}
	for s in g.all_symbols() {
		if s.id in copies {
			copies[s.id] << s
		}
	}
	mut out := []string{}
	for i, id in ids {
		// a declaration several build files declare is shown as the copy the next
		// call is made from, whose file those lines are in
		shown := if i + 1 < ids.len { g.copy_holding(copies[id], call_lines[i + 1]) } else { none }
		loc := if s := shown {
			'${s.name} (${s.loc()})'
		} else if s := idx.symbol(id) {
			'${s.name} (${s.loc()})'
		} else {
			id
		}
		if i == 0 {
			out << loc + build_mark(idx.decl_build(id))
			continue
		}
		lines := call_lines[i]
		mark := build_mark(terms_build(idx.step_terms(ids[i - 1], id)))
		out << '  -> ${loc}' + if lines.len > 0 { ', called${at_lines(lines)}' } else { '' } +
			mark
	}
	if ids.len > 1 {
		need := idx.route_build(ids)
		if need != '' {
			out << '  needs \$if ${need}'
		}
	}
	return out.join('\n')
}

// path_between answers "how does `a` reach `b`": the chains of calls from `a` to `b`
// (call_paths), up to max_call_paths, those the default build has first, then
// shortest first; else those from `b` to `a`, said so; else the shortest link through
// any relation (shortest_path), said so. '' when nothing links them.
pub fn (g Graph) path_between(a string, b string) string {
	return g.path_between_routes(a, b, max_call_paths)
}

// path_between_routes is path_between with up to `routes` chains listed instead of
// max_call_paths: at least 1 and at most max_listed_call_paths, whatever it is given.
pub fn (g Graph) path_between_routes(a string, b string, routes int) string {
	max := if routes < 1 {
		1
	} else if routes > max_listed_call_paths {
		max_listed_call_paths
	} else {
		routes
	}
	forward := g.count_call_paths(a, b, max)
	if forward.paths.len > 0 {
		return g.render_call_paths(forward)
	}
	back := g.count_call_paths(b, a, max)
	if back.paths.len > 0 {
		return "(`${a}` doesn't reach `${b}` by calls, but `${b}` reaches `${a}`:)\n" +
			g.render_call_paths(back)
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

// the most chains of calls path_between_routes will show
const max_listed_call_paths = 50

// render_call_paths renders chains of calls (render_call_path): one as it is, several
// numbered, after a line that says how many there are in all (at least that many
// when the count isn't exact), how many of them the default build has, when not all,
// and how many of them follow.
pub fn (g Graph) render_call_paths(r CallRoutes) string {
	paths := r.paths
	if paths.len == 1 && r.total == 1 {
		return g.render_call_path(paths[0])
	}
	first := g.index().symbol(paths[0][0]) or { Symbol{ name: paths[0][0] } }
	last := g.index().symbol(paths[0].last()) or { Symbol{ name: paths[0].last() } }
	all := if r.exact { '${r.total}' } else { 'at least ${r.total}' }
	defaults := if r.in_default < r.total { ' (${r.in_default} in the default build)' } else { '' }
	shown := if paths.len < r.total {
		if r.in_default < r.total {
			"; ${paths.len} of them, the default build's first"
		} else {
			'; the ${paths.len} shortest'
		}
	} else {
		''
	}
	mut out := ['${all} chains of calls from ${first.name} to ${last.name}${defaults}, at most ${call_path_slack} calls longer than the shortest${shown}:']
	for i, p in paths {
		out << ''
		out << '${i + 1}. ' + g.render_call_path(p)
	}
	// what the routes of other builds that don't follow need
	shown_other := if r.in_default < paths.len { paths.len - r.in_default } else { 0 }
	others := r.total - r.in_default
	if others > shown_other {
		mut needs := []string{}
		for need, n in r.other_builds {
			needs << '\$if ${need} (${n})'
		}
		out << ''
		out << '(${others - shown_other} more that only other builds have; the builds of all ${others} such: ${needs.join(', ')})'
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
	mut out := ['`${node}` names ${ids.len} declarations, the most called first; ${g.command('get_node')} one by its id, or as Type.method or file:line:']
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
	return build_mark(s.build)
}

// build_mark is ` [$if use_openssl ?]` for a build, and nothing for every build.
fn build_mark(build string) string {
	return if build == '' { '' } else { ' [\$if ${build}]' }
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
			d += '\n  | … (${dlines.len - shown.len} more lines — use ${g.command('get_body')} for the full source)'
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
	mut any_field := false
	for e in idx.edges_of(id) {
		if e.from == id {
			match e.kind {
				.calls {
					fmark := field_mark(idx, e.to)
					calls.add(label(idx, e.to) + fmark + prov_suffix(e.provenance), e.lines,
						e.build)
					any_inferred = any_inferred || e.provenance == .inferred
					any_field = any_field || fmark != ''
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
					called_by.add(label(idx, e.from) + prov_suffix(e.provenance), e.lines, e.build)
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
	if any_field {
		out << '  ^ [field] = a call through the fn that field holds, not a call of a method'
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
		out << '(use `${g.command('get_body')} ${s.name}` to read its source)'
	}
	return out.join('\n')
}

// CallList is a `calls` or `called by` list, each declaration once with the lines of
// its call sites (Edge.lines) and the builds that make them (Edge.build): two edges
// between the same declarations, which calls under different comptime conditions
// make, are one entry.
struct CallList {
mut:
	labels []string
	lines  map[string][]int
	builds map[string]string
}

fn (mut c CallList) add(label string, lines []int, build string) {
	if label !in c.lines {
		c.labels << label
		c.lines[label] = []int{}
		c.builds[label] = build
	} else {
		c.builds[label] = either_build(c.builds[label], build)
	}
	c.lines[label] = merge_lines(c.lines[label], lines)
}

// items renders each entry, `read_ptr (vlib/net/tcp.c.v:183) at lines 198, 224`: the
// lines are in the caller's file. A call only some builds make says which, as a `$if`
// would: `dial (vlib/net/openssl/ssl_connection.c.v:329) at line 39 [$if linux]`.
fn (c CallList) items() []string {
	return c.labels.map(it + at_lines(c.lines[it]) + if c.builds[it] == '' {
		''
	} else {
		' [\$if ${c.builds[it]}]'
	})
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

// field_mark marks a call of a field, ` [field]`: `s.on_running(mut s)` calls the fn
// the field holds, which reads as a method call when it isn't marked.
fn field_mark(idx Index, id string) string {
	s := idx.symbol(id) or { idx.lib_by_id[id] or { return '' } }
	return if s.kind == .field { ' [field]' } else { '' }
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

// copy_holding is the one of `copies`, the declarations several build files make
// under one id (`net.http.h2_dial_probe_vschannel` in
// vschannel_pooled_transport_windows.c.v and in a stub, backend_vschannel_d_cross.v),
// whose body holds all of `lines`, as read from its source: the copy a call at those
// lines is made from. none when there is one declaration, or no copy alone holds
// them; the index's copy then stands.
fn (g Graph) copy_holding(copies []Symbol, lines []int) ?Symbol {
	if lines.len == 0 || copies.len < 2 {
		return none
	}
	first, last := lines[0], lines.last()
	mut holding := []Symbol{}
	for c in copies {
		if c.line >= first {
			continue
		}
		path := g.source_path(c) or { continue }
		src := os.read_file(path) or { continue }
		text := src.replace('\r\n', '\n').split('\n')
		if last <= decl_end(text, c, g.symbols_of(c.file)) {
			holding << c
		}
	}
	return if holding.len == 1 { holding[0] } else { none }
}

// source_path is the path declaration `s` is read from.
fn (g Graph) source_path(s Symbol) ?string {
	// a layered module from VMODULES is read where the library was (layer_graph)
	if s.id in g.index().mods && s.file.starts_with(lib_vmodules_prefix) {
		return g.library.path_of(s.file)
	}
	return os.join_path(g.source_root(s), s.file)
}

// body_of is the source of the declaration `id`.
fn (g Graph) body_of(id string) string {
	idx := g.index()
	s := idx.symbol(id) or { return 'no symbol matches: ${id}' }
	path := g.source_path(s) or { return 'cannot read ${s.file}: no library root' }
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
