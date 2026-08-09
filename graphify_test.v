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
