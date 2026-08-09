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
