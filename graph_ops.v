module graphify

import os

// Index is a precomputed lookup over a Graph: symbols by id and name, plus an
// undirected adjacency of *internal* edges (edges whose target resolves to a
// known symbol). It powers query/path/explain without rescanning the slice.
pub struct Index {
pub mut:
	by_id   map[string]Symbol
	by_name map[string][]string // short name -> ids
	adj     map[string][]string // undirected neighbor ids
	edges   []Edge              // edges with `to` resolved to an id where possible
}

// index builds the lookup structures for a graph.
pub fn (g Graph) index() Index {
	mut idx := Index{}
	for s in g.symbols {
		idx.by_id[s.id] = s
		idx.by_name[s.name] << s.id
	}
	for e in g.edges {
		to_id := idx.resolve(e.to)
		if to_id == '' || e.from !in idx.by_id {
			continue // skip edges to externals/unknowns
		}
		idx.edges << Edge{
			from: e.from
			to:   to_id
			kind: e.kind
		}
		idx.adj[e.from] << to_id
		idx.adj[to_id] << e.from
	}
	return idx
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
	for queue.len > 0 {
		id := if dfs {
			queue.pop()
		} else {
			first := queue.first()
			queue.delete(0)
			first
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
		line := s.render()
		t := line.len / 4
		if tokens + t > budget && lines.len > 0 {
			break
		}
		lines << line
		tokens += t
	}
	header := '// query: ${text}  (${lines.len} of ${order.len} reachable symbols, ~${tokens} tokens)'
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
	for queue.len > 0 {
		cur := queue.first()
		queue.delete(0)
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
	for e in idx.edges {
		if e.from == id {
			match e.kind {
				.calls { calls << label(idx, e.to) }
				.defines { defines << label(idx, e.to) }
				.references { references << label(idx, e.to) }
				.embeds { embeds << label(idx, e.to) }
				else {}
			}
		}
		if e.to == id {
			match e.kind {
				.calls { called_by << label(idx, e.from) }
				.defines { defined_in << label(idx, e.from) }
				.references { referenced_by << label(idx, e.from) }
				else {}
			}
		}
	}
	if defined_in.len > 0 {
		out << 'defined in    : ${uniq(defined_in).join(', ')}'
	}
	if defines.len > 0 {
		out << 'defines       : ${uniq(defines).join(', ')}'
	}
	if embeds.len > 0 {
		out << 'embeds        : ${uniq(embeds).join(', ')}'
	}
	if references.len > 0 {
		out << 'references    : ${uniq(references).join(', ')}'
	}
	if referenced_by.len > 0 {
		out << 'referenced by : ${uniq(referenced_by).join(', ')}'
	}
	if calls.len > 0 {
		out << 'calls         : ${uniq(calls).join(', ')}'
	}
	if called_by.len > 0 {
		out << 'called by     : ${uniq(called_by).join(', ')}'
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
				if e.kind == .calls && e.to == s.name && e.from in idx.by_id {
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

fn name_of(idx Index, id string) string {
	s := idx.by_id[id] or { return id }
	return s.name
}

// label renders `name (file:line)` for a related symbol, falling back to its raw id.
fn label(idx Index, id string) string {
	s := idx.by_id[id] or { return id }
	return '${s.name} (${s.loc()})'
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
	src := os.read_file(os.join_path(g.root, s.file)) or { return 'cannot read ${s.file}: ${err}' }
	lines := src.split('\n')
	start := if s.line > 0 { s.line - 1 } else { 0 }
	mut end := if s.end_line > s.line { s.end_line } else { 0 }
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
	if end > lines.len {
		end = lines.len
	}
	if start >= lines.len {
		return '(no source)'
	}
	return '// ${s.file}:${s.line}-${end}\n' + lines[start..end].join('\n')
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
