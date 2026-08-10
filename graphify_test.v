module graphify

const sample = 'module demo

import os

pub struct User {
pub:
	name string
	age  int
}

pub const max_users = 100

pub fn (u User) greeting() string {
	return greet(u.name)
}

fn greet(name string) string {
	return "hi " + name
}

fn main() {
	println(greet("world"))
}
'

fn test_extracts_core_symbols() {
	syms, edges := extract_v_text(sample, 'demo.v')

	mut kinds := map[string]int{}
	for s in syms {
		kinds[s.kind.str()]++
	}

	assert kinds['module'] == 1
	assert kinds['import'] == 1
	assert kinds['struct'] == 1
	assert kinds['const'] == 1
	assert kinds['method'] == 1 // greeting
	assert kinds['fn'] == 2 // greet, main

	// the method signature is body-less and includes the receiver
	method := syms.filter(it.name == 'greeting')[0]
	assert method.signature.starts_with('pub fn (u User) greeting()')
	assert method.signature.ends_with('string')

	// a calls edge from main/greeting to greet should exist
	mut has_call := false
	for e in edges {
		if e.kind == .calls && e.to == 'greet' {
			has_call = true
		}
	}
	assert has_call
}

fn test_literal_receiver_types_the_call() {
	src := 'module demo

struct Foo {}

fn (f Foo) bar() {}

fn use() {
	Foo{}.bar()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	mut found := false
	for e in edges {
		if e.kind == .calls && e.to == 'bar' {
			found = true
			assert e.is_method
			assert e.recv_type == 'demo.Foo'
		}
	}
	assert found
}

fn test_cross_module_literal_receiver_types_by_its_own_module_not_the_callers() {
	// StructInit.typ_str always prefixes the *parsing* module rather than
	// whatever module was actually written (confirmed by direct probing of
	// v.parser, not assumed from its doc comment) -- so `other.Bar{}` inside
	// `demo` must still type as `other.Bar`, not `demo.Bar`.
	src := 'module demo

import other

fn use() {
	other.Bar{}.baz()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	mut found := false
	for e in edges {
		if e.kind == .calls && e.to == 'baz' {
			found = true
			assert e.is_method
			assert e.recv_type == 'other.Bar'
		}
	}
	assert found
}

fn recv_type_of(edges []Edge, to string) string {
	for e in edges {
		if e.kind == .calls && e.to == to {
			return e.recv_type
		}
	}
	return '<no such call edge>'
}

fn test_local_receiver_types_the_call() {
	src := 'module demo

struct Foo {}

fn (f Foo) bar() {}

fn use() {
	x := Foo{}
	x.bar()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	assert recv_type_of(edges, 'bar') == 'demo.Foo'
}

fn test_pointer_local_receiver_types_the_call() {
	src := 'module demo

struct Foo {}

fn (f &Foo) bar() {}

fn use() {
	x := &Foo{}
	x.bar()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	assert recv_type_of(edges, 'bar') == 'demo.Foo'
}

fn test_local_receiver_type_does_not_leak_out_of_its_block() {
	// `x` declared inside the if-branch is scoped to that branch. `bar` and
	// `baz` are distinct callee names on purpose: collect_calls records only
	// the first edge per name per function (a pre-existing dedup, unrelated
	// to scoping), so reusing one name for both calls would hide whichever
	// one lost the race rather than showing whether the type actually leaked.
	src := 'module demo

struct Foo {}

fn (f Foo) bar() {}

fn (f Foo) baz() {}

fn use(cond bool) {
	if cond {
		x := Foo{}
		x.bar()
	}
	x.baz()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	assert recv_type_of(edges, 'bar') == 'demo.Foo' // inside the if-branch
	assert recv_type_of(edges, 'baz') == '' // after the branch -- not the same `x`
}

fn test_local_with_uncertain_initializer_is_not_tracked() {
	// `compute()`'s return type is a checker fact, not a parser one -- the
	// exact case the README documents as genuinely requiring the checker.
	src := 'module demo

fn use() {
	x := compute()
	x.bar()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	assert recv_type_of(edges, 'bar') == ''
}

fn test_local_reassignment_does_not_clear_its_declared_type() {
	// V is statically typed: a `:=`-declared local's type cannot change for
	// the rest of its scope no matter what a later plain `=` looks like, so
	// track_assign deliberately ignores `=` rather than invalidating on it.
	src := 'module demo

struct Foo {}

fn (f Foo) bar() {}

fn use() {
	mut x := Foo{}
	x = Foo{}
	x.bar()
}
'
	_, edges := extract_v_text(src, 'demo.v')
	assert recv_type_of(edges, 'bar') == 'demo.Foo'
}

fn test_resolve_callee_provenance() {
	// a globally unique name leaves no real candidate to choose between --
	// extracted, not inferred, no matter how the rest of resolve_callee reads.
	mut unique_by_name := map[string][]CallCand{}
	unique_by_name['greet'] = [CallCand{ id: 'demo.greet', is_method: false, mod: 'demo', file: 'demo.v' }]
	e1 := Edge{
		from: 'demo.main'
		to:   'greet'
		kind: .calls
	}
	res1 := resolve_callee(e1, unique_by_name, map[string]DeclSite{}, map[string][]string{}) or {
		panic('expected greet to resolve')
	}
	assert res1.id == 'demo.greet'
	assert res1.inferred == false

	// a receiver whose type the parser wrote on the enclosing declaration is
	// syntactically certain, even with several same-named methods around --
	// also extracted.
	mut recv_by_name := map[string][]CallCand{}
	recv_by_name['foo'] = [
		CallCand{
			id:        'a.Foo.foo'
			is_method: true
			mod:       'a'
			file:      'a.v'
		},
		CallCand{
			id:        'b.Bar.foo'
			is_method: true
			mod:       'b'
			file:      'b.v'
		},
	]
	e2 := Edge{
		from:      'a.Foo.caller'
		to:        'foo'
		kind:      .calls
		is_method: true
		recv_type: 'a.Foo'
	}
	res2 := resolve_callee(e2, recv_by_name, map[string]DeclSite{}, map[string][]string{}) or {
		panic('expected the self-receiver shortcut to resolve foo')
	}
	assert res2.id == 'a.Foo.foo'
	assert res2.inferred == false

	// two real candidates with the same name, narrowed to one only via the
	// caller's own file -- a genuine heuristic pick, so inferred.
	mut file_by_name := map[string][]CallCand{}
	file_by_name['helper'] = [
		CallCand{
			id:        'x.helper'
			is_method: false
			mod:       'x'
			file:      'x.v'
		},
		CallCand{
			id:        'y.helper'
			is_method: false
			mod:       'y'
			file:      'y.v'
		},
	]
	mut site_of := map[string]DeclSite{}
	site_of['x.caller'] = DeclSite{
		mod:  'x'
		file: 'x.v'
	}
	e3 := Edge{
		from: 'x.caller'
		to:   'helper'
		kind: .calls
	}
	res3 := resolve_callee(e3, file_by_name, site_of, map[string][]string{}) or {
		panic('expected same-file narrowing to resolve helper')
	}
	assert res3.id == 'x.helper'
	assert res3.inferred == true
}

fn test_resolve_edges_sets_edge_provenance() {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'demo.greet'
			name:   'greet'
			kind:   .function
			parent: 'demo'
			file:   'demo.v'
		},
		Symbol{
			id:     'demo.main'
			name:   'main'
			kind:   .function
			parent: 'demo'
			file:   'demo.v'
		},
	]
	g.edges = [
		Edge{
			from: 'demo.main'
			to:   'greet'
			kind: .calls
		},
	]
	resolve_edges(mut g)
	assert g.edges.len == 1
	assert g.edges[0].to == 'demo.greet'
	assert g.edges[0].provenance == .extracted
}

fn test_resolve_type_ref_provenance() {
	// a globally unique type name: extracted, nothing to choose between.
	mut unique_by_name := map[string][]TypeCand{}
	unique_by_name['User'] = [TypeCand{ id: 'demo.User', mod: 'demo', file: 'demo.v' }]
	e1 := Edge{
		from: 'demo.greeting'
		to:   'User'
		kind: .references
	}
	res1 := resolve_type_ref(e1, unique_by_name, map[string]DeclSite{}, map[string][]string{}) or {
		panic('expected User to resolve')
	}
	assert res1.id == 'demo.User'
	assert res1.inferred == false

	// two structs sharing a name, narrowed to one only by the referencing
	// declaration's own file -- a genuine heuristic pick, so inferred.
	mut file_by_name := map[string][]TypeCand{}
	file_by_name['Config'] = [
		TypeCand{
			id:   'x.Config'
			mod:  'x'
			file: 'x.v'
		},
		TypeCand{
			id:   'y.Config'
			mod:  'y'
			file: 'y.v'
		},
	]
	mut site_of := map[string]DeclSite{}
	site_of['x.Loader'] = DeclSite{
		mod:  'x'
		file: 'x.v'
	}
	e2 := Edge{
		from: 'x.Loader'
		to:   'Config'
		kind: .embeds
	}
	res2 := resolve_type_ref(e2, file_by_name, site_of, map[string][]string{}) or {
		panic('expected same-file narrowing to resolve Config')
	}
	assert res2.id == 'x.Config'
	assert res2.inferred == true
}

fn test_resolve_edges_resolves_embeds() {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'demo.Base'
			name:   'Base'
			kind:   .struct_
			parent: 'demo'
			file:   'demo.v'
		},
		Symbol{
			id:     'demo.User'
			name:   'User'
			kind:   .struct_
			parent: 'demo'
			file:   'demo.v'
		},
	]
	g.edges = [
		Edge{
			from: 'demo.User'
			to:   'Base'
			kind: .embeds
		},
	]
	resolve_edges(mut g)
	assert g.edges.len == 1
	assert g.edges[0].to == 'demo.Base'
	assert g.edges[0].provenance == .extracted
}

fn test_merge_graphs_namespaces_ids() {
	mut a := Graph{
		root: 'S:/repo/svc-a'
	}
	a.symbols = [
		Symbol{
			id:     'demo.greet'
			name:   'greet'
			kind:   .function
			parent: 'demo'
			file:   'demo.v'
		},
	]
	mut b := Graph{
		root: 'S:/repo/svc-b'
	}
	b.symbols = [
		Symbol{
			id:     'demo.greet'
			name:   'greet'
			kind:   .function
			parent: 'demo'
			file:   'demo.v'
		},
	]
	merged := merge_graphs([a, b], [])
	assert merged.symbols.len == 2
	assert merged.symbols[0].id == 'svc-a::demo.greet'
	assert merged.symbols[1].id == 'svc-b::demo.greet'
	assert merged.symbols[0].parent == 'svc-a::demo'
	assert merged.symbols[1].parent == 'svc-b::demo'
}

fn test_merge_graphs_id_collision_stays_separate() {
	// `main` is the implicit module of every standalone V program, so two
	// unrelated projects each declaring `main.run` is the realistic case,
	// not a contrived one. Namespacing must keep them distinct rather than
	// one silently shadowing the other in the merged Index.
	mut a := Graph{
		root: 'S:/repo/tool-a'
	}
	a.symbols = [
		Symbol{
			id:   'main.run'
			name: 'run'
			kind: .function
			file: 'main.v'
		},
		Symbol{
			id:   'main.helper_a'
			name: 'helper_a'
			kind: .function
			file: 'main.v'
		},
	]
	a.edges = [
		Edge{
			from: 'main.helper_a'
			to:   'main.run'
			kind: .calls
		},
	]
	mut b := Graph{
		root: 'S:/repo/tool-b'
	}
	b.symbols = [
		Symbol{
			id:   'main.run'
			name: 'run'
			kind: .function
			file: 'main.v'
		},
		Symbol{
			id:   'main.helper_b'
			name: 'helper_b'
			kind: .function
			file: 'main.v'
		},
	]
	b.edges = [
		Edge{
			from: 'main.helper_b'
			to:   'main.run'
			kind: .calls
		},
	]
	merged := merge_graphs([a, b], [])
	idx := merged.index()
	assert idx.by_id.len == 4 // both `main.run`s (and their helpers) survive as distinct nodes
	assert 'tool-a::main.run' in idx.by_id
	assert 'tool-b::main.run' in idx.by_id
	// each project's own call edge must resolve to *its own* run, never the
	// other project's -- this is the actual failure mode a naive merge
	// (concatenate without namespacing) would produce.
	assert idx.adj['tool-a::main.helper_a'] == ['tool-a::main.run']
	assert idx.adj['tool-b::main.helper_b'] == ['tool-b::main.run']
}

fn test_merge_graphs_dedups_repeated_default_labels() {
	// two projects that both happen to be checked out under a directory
	// named `src` -- a very plausible collision for auto-derived labels.
	mut a := Graph{
		root: 'S:/repo/one/src'
	}
	mut b := Graph{
		root: 'S:/repo/two/src'
	}
	a.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function }]
	b.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function }]
	merged := merge_graphs([a, b], [])
	assert merged.symbols[0].id == 'src::x.f'
	assert merged.symbols[1].id == 'src-2::x.f'
}

fn test_merge_graphs_explicit_labels_override_defaults() {
	mut a := Graph{
		root: 'S:/repo/one/src'
	}
	mut b := Graph{
		root: 'S:/repo/two/src'
	}
	a.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function }]
	b.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function }]
	merged := merge_graphs([a, b], ['alpha', 'beta'])
	assert merged.symbols[0].id == 'alpha::x.f'
	assert merged.symbols[1].id == 'beta::x.f'
}

// Zachary's Karate Club: the standard 34-node, 78-edge benchmark graph for
// community detection, with well-documented expected properties (used here,
// not a contrived toy) -- see https://en.wikipedia.org/wiki/Zachary%27s_karate_club.
const karate_edges = [
	[0, 1], [0, 2], [0, 3], [0, 4], [0, 5], [0, 6], [0, 7], [0, 8], [0, 10], [0, 11],
	[0, 12], [0, 13], [0, 17], [0, 19], [0, 21], [0, 31], [1, 2], [1, 3], [1, 7], [1, 13],
	[1, 17], [1, 19], [1, 21], [1, 30], [2, 3], [2, 7], [2, 8], [2, 9], [2, 13], [2, 27],
	[2, 28], [2, 32], [3, 7], [3, 12], [3, 13], [4, 6], [4, 10], [5, 6], [5, 10], [5, 16],
	[6, 16], [8, 30], [8, 32], [8, 33], [9, 33], [13, 33], [14, 32], [14, 33], [15, 32],
	[15, 33], [18, 32], [18, 33], [19, 33], [20, 32], [20, 33], [22, 32], [22, 33], [23, 25],
	[23, 27], [23, 29], [23, 32], [23, 33], [24, 25], [24, 27], [24, 31], [25, 31], [26, 29],
	[26, 33], [27, 33], [28, 31], [28, 33], [29, 32], [29, 33], [30, 32], [30, 33], [31, 32],
	[31, 33], [32, 33],
]

fn karate_graph() Graph {
	mut g := Graph{}
	for i in 0 .. 34 {
		g.symbols << Symbol{
			id:   i.str()
			name: 'n${i}'
			kind: .function
		}
	}
	for pair in karate_edges {
		g.edges << Edge{
			from: pair[0].str()
			to:   pair[1].str()
			kind: .calls
		}
	}
	return g
}

fn test_communities_karate_club_finds_real_structure() {
	g := karate_graph()
	// this benchmark is small and adversarial enough to need more than the
	// production default's restarts for reliable quality -- see
	// default_leiden_restarts' doc comment.
	result := g.communities(resolution: 1.0, restarts: 30)

	// every node appears in exactly one community -- no loss, no duplication
	mut seen := map[string]int{}
	for c in result {
		for id in c.members {
			seen[id] = seen[id] + 1
		}
	}
	assert seen.len == 34
	for _, n in seen {
		assert n == 1
	}

	// meaningful structure, not degenerate: neither one giant blob nor 34
	// singletons. Louvain-style optimization on this graph is well
	// documented to land around 3-4 communities.
	assert result.len >= 2
	assert result.len <= 8

	// the two best-documented qualitative facts about this graph: nodes 0
	// (Mr. Hi) and 33 (John A) are the two rival factions' hub nodes and
	// end up in different communities under any real modularity
	// optimization -- if this assertion fails, the algorithm is not finding
	// real structure, whatever its other numbers say.
	mut comm_of := map[string]int{}
	for c in result {
		for id in c.members {
			comm_of[id] = c.id
		}
	}
	assert comm_of['0'] != comm_of['33']

	// modularity should be solidly above what a broken or near-random
	// partition produces on this graph. The literature's commonly-cited
	// ~0.42 for Louvain here is a best-of-many-restarts figure; empirically,
	// even leiden_restarts' 50 tries occasionally top out closer to 0.34 at
	// a wide, commonly-reached local optimum rather than escaping further
	// (see its doc comment) -- 0.30 is comfortably below every value
	// observed across dozens of runs during development, while a genuine
	// formula bug reliably produces something far lower (0.15-0.26 range,
	// also observed directly while this was being debugged).
	idx := g.index()
	w := build_wgraph(idx)
	q := modularity(w, comm_of, 1.0)
	assert q > 0.30
}

fn test_communities_are_connected() {
	// Two disjoint triangles (0-1-2 and 3-4-5), joined only by a single
	// 2-6 edge -- weak enough that a real optimizer may or may not fold
	// node 6 into one side, but every returned community, whatever its
	// membership, must be internally connected by construction.
	mut g := Graph{}
	for i in 0 .. 7 {
		g.symbols << Symbol{
			id:   i.str()
			name: 'n${i}'
			kind: .function
		}
	}
	tri_edges := [[0, 1], [1, 2], [0, 2], [3, 4], [4, 5], [3, 5], [2, 6]]
	for pair in tri_edges {
		g.edges << Edge{
			from: pair[0].str()
			to:   pair[1].str()
			kind: .calls
		}
	}
	result := g.communities()
	idx := g.index()
	for c in result {
		mut in_group := map[string]bool{}
		for id in c.members {
			in_group[id] = true
		}
		mut visited := map[string]bool{}
		mut queue := [c.members[0]]
		visited[c.members[0]] = true
		for queue.len > 0 {
			node := queue.pop()
			for nb in idx.adj[node] or { []string{} } {
				if nb in in_group && !visited[nb] {
					visited[nb] = true
					queue << nb
				}
			}
		}
		assert visited.len == c.members.len // every member reached -- the community is one connected piece
	}
}

fn test_communities_resolution_increases_community_count() {
	// a higher resolution should never produce *fewer* communities than a
	// lower one on the same graph -- that's the defining monotonic property
	// of resolution-limited modularity's penalty term.
	g := karate_graph()
	low := g.communities(resolution: 0.5)
	high := g.communities(resolution: 2.0)
	assert high.len >= low.len
}

// clique_of_cliques_graph builds n_cliques fully-connected cliques of
// clique_size each, bridged into one connected structure by a single sparse
// edge between consecutive cliques -- a graph.html drill-down candidate's
// shape: one big, internally lumpy community with real sub-structure a flat
// view never reveals.
fn clique_of_cliques_graph(n_cliques int, clique_size int) Graph {
	mut g := Graph{}
	mut id := 0
	mut clique_members := [][]string{}
	for c := 0; c < n_cliques; c++ {
		mut members := []string{}
		for i := 0; i < clique_size; i++ {
			sid := 'n${id}'
			g.symbols << Symbol{
				id:   sid
				name: sid
				kind: .function
			}
			members << sid
			id++
		}
		for i := 0; i < members.len; i++ {
			for j := i + 1; j < members.len; j++ {
				g.edges << Edge{
					from: members[i]
					to:   members[j]
					kind: .calls
				}
			}
		}
		clique_members << members
	}
	for c := 0; c < n_cliques - 1; c++ {
		g.edges << Edge{
			from: clique_members[c][0]
			to:   clique_members[c + 1][0]
			kind: .calls
		}
	}
	return g
}

fn test_communities_within_finds_sub_structure() {
	g := clique_of_cliques_graph(3, 10) // 3 well-separated 10-node cliques, bridged sparsely
	mut all_members := []string{}
	for s in g.symbols {
		all_members << s.id
	}
	result := g.communities_within(all_members, resolution: 1.0, restarts: 15)
	assert result.len >= 3 // finds (at least) the 3 real cliques, not one inseparable blob

	// partition safety: every input member appears in exactly one output
	// community -- same shape as test_communities_karate_club_finds_real_structure.
	mut seen := map[string]int{}
	for c in result {
		for id in c.members {
			seen[id] = seen[id] + 1
		}
	}
	assert seen.len == all_members.len
	for _, n in seen {
		assert n == 1
	}

	// the connectivity guarantee holds at scoped level too -- same walk as
	// test_communities_are_connected.
	idx := g.index()
	for c in result {
		mut in_group := map[string]bool{}
		for id in c.members {
			in_group[id] = true
		}
		mut visited := map[string]bool{}
		mut queue := [c.members[0]]
		visited[c.members[0]] = true
		for queue.len > 0 {
			node := queue.pop()
			for nb in idx.adj[node] or { []string{} } {
				if nb in in_group && !visited[nb] {
					visited[nb] = true
					queue << nb
				}
			}
		}
		assert visited.len == c.members.len
	}
}

fn test_communities_within_no_internal_edges_returns_empty() {
	// every "m" node only calls "outside", never each other -- scoped to
	// just the "m" set, build_wgraph_scoped finds no qualifying edge at
	// all, exercising its empty-result path rather than crashing.
	mut g := Graph{}
	for i in 0 .. 4 {
		g.symbols << Symbol{
			id:   'm${i}'
			name: 'm${i}'
			kind: .function
		}
	}
	g.symbols << Symbol{
		id:   'outside'
		name: 'outside'
		kind: .function
	}
	for i in 0 .. 4 {
		g.edges << Edge{
			from: 'm${i}'
			to:   'outside'
			kind: .calls
		}
	}
	result := g.communities_within(['m0', 'm1', 'm2', 'm3'], resolution: 1.0)
	assert result.len == 0
}

// ring_of_cliques_graph is the classic Fortunato-Barthelemy resolution-limit
// construction: n_cliques small cliques arranged in a ring, each linked to
// its two neighbors by one edge. A plain clique-of-cliques (few cliques,
// one clean bridge) always gets cleanly separated by communities() at the
// TOP level too -- confirmed directly, not assumed, after several other
// constructions kept failing this exact way -- so it can never survive as
// one large top-level community for compute_drill_views to even consider.
// A large enough ring is different: modularity optimization provably
// cannot resolve individual cliques past a certain ring size and merges
// neighbors together instead, reliably producing a genuinely large,
// still-internally-splittable top-level community the way a real, much
// bigger codebase's own communities can. Verified empirically (repeated
// runs) that 400 5-node cliques reliably produces multiple 30+-member
// merged communities.
fn ring_of_cliques_graph(n_cliques int, clique_size int) Graph {
	mut g := Graph{}
	mut cliques := [][]string{}
	mut id := 0
	for c := 0; c < n_cliques; c++ {
		mut members := []string{}
		for i := 0; i < clique_size; i++ {
			sid := 'n${id}'
			g.symbols << Symbol{
				id:   sid
				name: sid
				kind: .function
			}
			members << sid
			id++
		}
		for i := 0; i < members.len; i++ {
			for j := i + 1; j < members.len; j++ {
				g.edges << Edge{
					from: members[i]
					to:   members[j]
					kind: .calls
				}
			}
		}
		cliques << members
	}
	for c := 0; c < n_cliques; c++ {
		nxt := (c + 1) % n_cliques
		g.edges << Edge{
			from: cliques[c][0]
			to:   cliques[nxt][0]
			kind: .calls
		}
	}
	return g
}

fn test_emit_graph_html_drill_views_capped_marked_and_disclosed() {
	// One graph, computed once, checked for all of: some communities are
	// large enough to be marked drillable and some are not (the size gate
	// actually filters something, not everything); the number of emitted
	// drill-views never exceeds drill_max_candidates; and since this ring
	// produces well over drill_max_candidates qualifying communities, the
	// "N of M" truncation disclosure is present, not silent.
	g := ring_of_cliques_graph(400, 5)
	out := g.emit_graph_html()

	views := out.count('class="drill-view"')
	badges := out.count('class="drill-badge-legend"')
	legend_items := out.count('class="legend-item"')

	assert views > 0 // this ring reliably produces qualifying, splittable communities
	assert views <= drill_max_candidates // the cap is a hard ceiling, never exceeded
	// occasionally one of the top-drill_max_candidates-by-size communities
	// fails the "really has >=2 sub-communities" gate and gets skipped
	// without being backfilled -- allow a little slack rather than
	// asserting an exact count that isn't actually guaranteed by the code.
	assert views >= drill_max_candidates - 3
	assert views == badges // every drill-view has exactly one matching legend badge
	assert legend_items > badges // not every community qualified -- the size gate filtered some out
	assert out.contains('large communities include a detail view') // truncation disclosed, not silent
}

fn export_test_graph() Graph {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:        'demo.greet'
			name:      'greet'
			kind:      .function
			file:      'demo.v'
			line:      5
			signature: 'fn greet(name string) []T<int> & "quoted" & back\\slash'
		},
		Symbol{
			id:   'demo.main'
			name: 'main'
			kind: .function
			file: 'demo.v'
			line: 1
		},
	]
	g.edges = [
		Edge{
			from:       'demo.main'
			to:         'demo.greet'
			kind:       .calls
			provenance: .inferred
		},
		Edge{
			from: 'demo.main'
			to:   'nonexistent_external_call'
			kind: .calls
		},
	]
	return g
}

fn test_emit_svg_structure() {
	g := export_test_graph()
	out := g.emit_svg()

	assert out.starts_with('<svg xmlns="http://www.w3.org/2000/svg"')
	assert out.contains('data-id="demo.greet"')
	assert out.contains('data-id="demo.main"')
	assert out.contains('data-from="demo.main" data-to="demo.greet"')
	// the unresolved edge has no node to draw a line to or from
	assert !out.contains('nonexistent_external_call')
}

fn test_emit_svg_caps_large_graphs() {
	// svg_max_nodes is 300; build well past it, all in one tightly-connected
	// clump so they land in one (or a couple) communities rather than
	// spreading thin enough to dodge the cap.
	n := svg_max_nodes + 50
	mut g := Graph{}
	for i in 0 .. n {
		g.symbols << Symbol{
			id:   'n${i}'
			name: 'n${i}'
			kind: .function
		}
	}
	for i in 0 .. n {
		g.edges << Edge{
			from: 'n${i}'
			to:   'n${(i + 1) % n}'
			kind: .calls
		}
	}
	out := g.emit_svg()
	assert out.contains('showing') && out.contains('of ${n} symbols')
	assert out.count('data-id=') <= 2 * svg_max_nodes // circle + text per node
}

fn test_emit_graph_html_structure() {
	g := export_test_graph()
	out := g.emit_graph_html()

	assert out.starts_with('<!doctype html>')
	assert out.contains('<svg xmlns="http://www.w3.org/2000/svg"')
	assert out.contains('id="legend"')
	assert out.contains('<script>')
	assert out.contains('data-id="demo.greet"')
	assert out.contains('h2 class="sr-only"') // screen-reader summary, per artifact accessibility convention
}

fn location_test_graph() Graph {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:   'a1'
			name: 'a1'
			kind: .function
			file: 'v/checker/checker.v'
		},
		Symbol{
			id:   'a2'
			name: 'a2'
			kind: .function
			file: 'v/checker/infix.v'
		},
		Symbol{
			id:   'a3'
			name: 'a3'
			kind: .function
			file: 'v/checker/infix.v'
		},
		Symbol{
			id:   'b1'
			name: 'b1'
			kind: .function
			file: 'v/parser/parser.v'
		},
	]
	// communities() only clusters nodes that have edges (build_wgraph draws
	// from idx.edges) -- a graph with symbols but no connectivity data
	// finds nothing to cluster, so this needs real edges, not just symbols.
	g.edges = [
		Edge{
			from: 'a1'
			to:   'a2'
			kind: .calls
		},
		Edge{
			from: 'a2'
			to:   'a3'
			kind: .calls
		},
		Edge{
			from: 'a1'
			to:   'a3'
			kind: .calls
		},
		Edge{
			from: 'a1'
			to:   'b1'
			kind: .calls
		},
	]
	return g
}

fn test_community_location_single_directory() {
	g := location_test_graph()
	idx := g.index()
	loc := community_location(idx, ['a1', 'a2', 'a3'])
	assert loc == 'v/checker'
}

fn test_community_location_majority_directory() {
	g := location_test_graph()
	idx := g.index()
	// 3 of 4 members in v/checker -- a clear (75%) majority
	loc := community_location(idx, ['a1', 'a2', 'a3', 'b1'])
	assert loc == 'v/checker +1 more dir'
}

fn test_community_location_no_majority() {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:   'x1'
			name: 'x1'
			kind: .function
			file: 'v/checker/checker.v'
		},
		Symbol{
			id:   'x2'
			name: 'x2'
			kind: .function
			file: 'v/parser/parser.v'
		},
	]
	idx := g.index()
	// no single directory reaches a majority -- report a count, don't guess
	loc := community_location(idx, ['x1', 'x2'])
	assert loc == '2 directories'
}

fn test_emit_svg_has_cluster_labels_with_location() {
	g := location_test_graph()
	out := g.emit_svg()
	assert out.contains('class="cluster-label"')
	assert out.contains('v/checker') // the community's location shows up on-canvas
}

fn test_emit_graph_html_legend_shows_location() {
	g := location_test_graph()
	out := g.emit_graph_html()
	assert out.contains('class="loc"')
	assert out.contains('v/checker')
	// semantic zoom: node labels start hidden, a zoom-triggered class reveals them
	assert out.contains('text.node-label { opacity: 0')
	assert out.contains('svg.zoomed-in text.node-label { opacity: 1')
}

fn test_export_emits_one_node_per_colliding_id() {
	// caught live: this project's own files all declare `module graphify`,
	// so a naive one-node-per-raw-symbol export produced several
	// `CREATE (:Symbol:Module {id: 'graphify', ...})` statements, and the
	// *second* one failed outright against the uniqueness constraint the
	// same export emits. Simulates that directly: two module symbols
	// sharing one id, as if from two different files.
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:   'graphify'
			name: 'graphify'
			kind: .mod_
			file: 'a.v'
		},
		Symbol{
			id:   'graphify'
			name: 'graphify'
			kind: .mod_
			file: 'b.v'
		},
	]
	graphml := g.emit_graphml()
	assert graphml.count('<node id="graphify">') == 1

	cypher := g.emit_cypher()
	assert cypher.count("CREATE (:Symbol:Module {id: 'graphify'") == 1
}

fn test_emit_graphml_structure_and_escaping() {
	g := export_test_graph()
	out := g.emit_graphml()

	assert out.starts_with('<?xml version="1.0" encoding="UTF-8"?>')
	assert out.contains('<graphml')
	assert out.contains('<node id="demo.greet">')
	assert out.contains('<node id="demo.main">')

	// dangerous characters in the signature must come out escaped, and the
	// raw unescaped forms must not survive into the data content
	assert out.contains('&lt;int&gt;')
	assert out.contains('&amp;')
	assert out.contains('&quot;quoted&quot;')
	assert !out.contains('[]T<int>') // raw, unescaped -- would be invalid XML

	// the resolved edge is present with its provenance...
	assert out.contains('<edge source="demo.main" target="demo.greet">')
	assert out.contains('<data key="e_prov">inferred</data>')
	// ...the edge to an unresolved external name is not: GraphML's
	// source/target must reference declared nodes, and idx.edges already
	// excludes anything that never resolved
	assert !out.contains('nonexistent_external_call')
}

fn test_emit_cypher_structure_and_escaping() {
	g := export_test_graph()
	out := g.emit_cypher()

	assert out.contains('CREATE CONSTRAINT graphify_id IF NOT EXISTS FOR (n:Symbol) REQUIRE n.id IS UNIQUE;')
	assert out.contains(":Function {id: 'demo.greet'")
	assert out.contains(":Function {id: 'demo.main'")

	// the literal backslash in the signature comes out doubled (escaped)...
	assert out.contains('back\\\\slash')
	// ...but <, >, &, " are Cypher-safe as-is inside a single-quoted string
	// and must survive unescaped -- XML's escaping rules don't apply here
	assert out.contains('[]T<int> & "quoted"')

	assert out.contains("MATCH (a:Symbol {id: 'demo.main'}), (b:Symbol {id: 'demo.greet'}) CREATE (a)-[:CALLS {provenance: 'inferred'}]->(b);")
	assert !out.contains('nonexistent_external_call')
}

fn test_skeleton_is_bodyless() {
	syms, _ := extract_v_text(sample, 'demo.v')
	mut g := Graph{}
	g.symbols = syms
	out := g.emit_skeleton()

	assert out.contains('module demo')
	assert out.contains('import os')
	assert out.contains('{ ... }') // fn bodies elided
	assert !out.contains('println') // no implementation leaked
}
