module graphify

import os

// Index is a precomputed lookup over a Graph: symbols by id and name, plus an
// undirected adjacency of *internal* edges (edges whose target resolves to a
// known symbol). It powers query/path/explain without rescanning the slice.
pub struct Index {
pub mut:
	by_id   map[string]Symbol
	by_name map[string][]string // short name -> distinct ids
	adj     map[string][]string // undirected neighbor ids
	edges   []Edge              // edges with `to` resolved to an id where possible
}

// index builds the lookup structures for a graph.
pub fn (g Graph) index() Index {
	mut idx := Index{}
	for s in g.symbols {
		// Declarations that share an id are one logical declaration, such as a
		// function declared once per platform (`os.read_file` in os.c.v and
		// os_js.js.v, see disambiguate_ids); keep the one shown_before prefers,
		// which explain/get_body/query then show. by_name lists the id once, so
		// resolve doesn't take the copies for rival declarations.
		if s.id !in idx.by_id {
			idx.by_id[s.id] = s
			idx.by_name[s.name] << s.id
		} else if shown_before(s, idx.by_id[s.id]) {
			idx.by_id[s.id] = s
		}
	}
	for e in g.edges {
		if e.provenance == .undeclared {
			// no declaration to resolve to (see EdgeProvenance): a unique
			// name match would pin the call on an unrelated declaration, the
			// way a test's `conv` parameter matched `encoding.iconv.conv`. (A
			// call of a function-typed field is resolved to the field by
			// resolve_edges, so it isn't one of these.)
			continue
		}
		to_id := idx.resolve(e.to)
		if to_id == '' || e.from !in idx.by_id {
			continue // skip edges to externals/unknowns
		}
		idx.edges << Edge{
			from:       e.from
			to:         to_id
			kind:       e.kind
			provenance: e.provenance
		}
		idx.adj[e.from] << to_id
		idx.adj[to_id] << e.from
	}
	return idx
}

// shown_before reports whether declaration `a`, met after `b` in g.symbols,
// should represent their shared id in its place: a file for the C backend
// (plain `.v` or `.c.v`) before one for another backend, and the JS backend's
// `.js.v` last, since it is the copy furthest from what ordinary V code calls.
// Between files of the same backend the later one wins, as it did before
// backends were ranked; g.symbols follows graph.json, which the same-graph CI
// job keeps identical across hosts.
fn shown_before(a Symbol, b Symbol) bool {
	return backend_rank(a.file) <= backend_rank(b.file)
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
	if target in idx.by_id {
		return target
	}
	ids := idx.by_name[target] or { return '' }
	return if ids.len == 1 { ids[0] } else { '' }
}

// find returns ids of symbols whose name or signature contains any whitespace
// token of `text` (case-insensitive). This is the deterministic stand-in for
// Graphify's NL query seeding.
pub fn (g Graph) find(text string) []string {
	terms := text.to_lower().fields()
	mut hits := []string{}
	mut seen := map[string]bool{}
	for s in g.symbols {
		hay := '${s.name} ${s.signature}'.to_lower()
		for t in terms {
			if hay.contains(t) && s.id !in seen {
				seen[s.id] = true
				hits << s.id
				break
			}
		}
	}
	return hits
}

// resolve_one returns the single best id for a node reference (exact id, exact
// name, or unique signature substring), or '' if none/ambiguous.
pub fn (g Graph) resolve_one(query string) string {
	// An empty reference names nothing: without this guard '' is a substring of
	// every name and the fuzzy pass below would return an arbitrary symbol.
	if query.trim_space() == '' {
		return ''
	}
	idx := g.index()
	if query in idx.by_id {
		return query
	}
	if ids := idx.by_name[query] {
		if ids.len >= 1 {
			return ids[0]
		}
	}
	mut matches := []string{}
	ql := query.to_lower()
	for s in g.symbols {
		if s.name.to_lower().contains(ql) {
			matches << s.id
		}
	}
	return if matches.len > 0 { matches[0] } else { '' }
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
		for nb in idx.adj[id] or { []string{} } {
			if nb !in visited {
				visited[nb] = true
				queue << nb
			}
		}
	}

	mut lines := []string{}
	mut tokens := 0
	for id in order {
		s := idx.by_id[id] or { continue }
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
	for head < queue.len {
		cur := queue[head]
		head++
		for nb in idx.adj[cur] or { []string{} } {
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
pub fn (g Graph) explain(node string) string {
	idx := g.index()
	id := g.resolve_one(node)
	if id == '' {
		return 'no symbol matches: ${node}'
	}
	s := idx.by_id[id] or { return 'no symbol matches: ${node}' }

	mut out := ['${s.kind.str()} ${s.name}  (${s.loc()})', s.render()]
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

	mut calls := []string{}
	mut called_by := []string{}
	mut defines := []string{}
	mut defined_in := []string{}
	mut references := []string{}
	mut referenced_by := []string{}
	mut embeds := []string{}
	mut any_inferred := false
	for e in idx.edges {
		if e.from == id {
			match e.kind {
				.calls {
					calls << label(idx, e.to) + prov_suffix(e.provenance)
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
					called_by << label(idx, e.from) + prov_suffix(e.provenance)
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
	if calls.len > 0 {
		out << 'calls         : ${capped(calls)}'
	}
	if called_by.len > 0 {
		out << 'called by     : ${capped(called_by)}'
	}
	if any_inferred {
		out << '  ^ [inferred] = picked among several same-named candidates by the inferred receiver type or by locality/visibility, not a name that was unambiguous outright — see the edge provenance note in README'
	}
	// A call whose name matches several declarations cannot be attributed to
	// one of them, so index() drops it and the `called by` line above silently
	// looks complete when it is not. Surface those call sites separately and
	// say plainly why they are uncertain — a short hedged list beats claiming
	// a symbol has no callers when it has dozens.
	if s.kind in [SymbolKind.function, .method] {
		same_name := idx.by_name[s.name] or { []string{} }
		if same_name.len > 1 {
			mut maybe := []string{}
			for e in g.edges {
				if e.kind == .calls && e.to == s.name && e.from in idx.by_id
					&& e.provenance != .undeclared {
					maybe << label(idx, e.from)
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
	s := idx.by_id[id] or { return id }
	return s.name
}

// label renders `name (file:line)` for a related symbol, falling back to its raw id.
fn label(idx Index, id string) string {
	s := idx.by_id[id] or { return id }
	return '${s.name} (${s.loc()})'
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
pub fn (g Graph) get_body(node string) string {
	idx := g.index()
	id := g.resolve_one(node)
	if id == '' {
		return 'no symbol matches: ${node}'
	}
	s := idx.by_id[id] or { return 'no symbol matches: ${node}' }
	src := os.read_file(os.join_path(g.source_root(s), s.file)) or {
		return 'cannot read ${s.file}: ${err}'
	}
	// a CRLF file (a Windows checkout with core.autocrlf) would otherwise
	// leave a `\r` on every line, and the closing-brace checks below would
	// never match
	lines := src.replace('\r\n', '\n').split('\n')
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
		for o in g.symbols {
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
		// built; the `(no source)` check below handles that.)
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
				if lines[e - 1].trim_space() == '}' {
					end = e
					break
				}
			}
		}
	}
	if end > lines.len {
		end = lines.len
	}
	if start >= lines.len {
		return '(no source)'
	}
	return '// ${s.file}:${s.line}-${end}\n' + lines[start..end].join('\n')
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
	for nb in idx.adj[id] or { []string{} } {
		name := name_of(idx, nb)
		if name !in seen {
			seen[name] = true
			out << name
		}
	}
	return out
}
