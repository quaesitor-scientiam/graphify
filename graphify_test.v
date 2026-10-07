module graphify

import os
import x.json2

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

fn test_c_extern_decl_does_not_collide_with_same_name_v_wrapper() {
	// `fn C.foo()` is a body-less extern binding; `short_name` drops the
	// `C.`/`JS.` prefix (see fn_id's doc comment), so before this fix it and
	// a same-named real V wrapper IN THE SAME FILE got the identical id
	// `demo.get_string_array` -- a same-file collision a file-qualified
	// suffix can never separate. Matches the real shape found in
	// vlib/v/tests/c_function/pass_ref_test.c.v.
	src := 'module demo

fn C.get_string_array() &&char

pub fn get_string_array() &&char {
	return C.get_string_array()
}
'
	syms, _ := extract_v_text(src, 'demo.v')
	fns := syms.filter(it.kind == .function)
	assert fns.len == 1
	assert fns[0].id == 'demo.get_string_array'
	assert fns[0].name == 'get_string_array'
}

fn test_top_level_comptime_if_declarations_are_extracted() {
	// A file-scope `$if` parses to an ExprStmt wrapping a comptime IfExpr, so
	// the declarations inside it were never reached. The parser keeps only the
	// branch the host takes, so exactly one of each pair must appear --
	// whichever host runs this test. Matches the shape in vlib/os/os_darwin.c.v.
	src := 'module demo

$if windows {
	fn picked_a() {}
	struct PickedA {}
} $else {
	fn picked_b() {}
	struct PickedB {}
	$if windows {
		fn nested_a() {}
	} $else {
		fn nested_b() {}
	}
}

fn always() {}
'
	syms, _ := extract_v_text(src, 'demo.v')
	ids := syms.map(it.id)
	assert 'demo.always' in ids
	assert ('demo.picked_a' in ids) != ('demo.picked_b' in ids)
	assert ('demo.PickedA' in ids) != ('demo.PickedB' in ids)
	if 'demo.picked_b' in ids {
		assert ('demo.nested_a' in ids) != ('demo.nested_b' in ids)
	}
}

fn test_syntax_error_costs_only_its_own_declaration() {
	// V 0.5.2 rejects a loop variable shadowing a local and returns from the
	// middle of the `for` without closing its scope. Every later method whose
	// receiver has the same name then fails as a "redefinition of parameter"
	// and its body is read as garbage at file scope; functions with other
	// parameter names survive. Shape from vlib/v/types/
	// checker_ownership_d_ownership.v, which lost 320 of 501 functions to it.
	src := 'module demo

import os

struct Checker {}

fn (c Checker) shadows(m map[string]int) bool {
	name := os.args[0]
	for name, v in m {
		if v > 0 {
			return name.len > 0
		}
	}
	return false
}

@[inline]
fn (c Checker) after_one() int {
	return 1
}

fn plain() {}

struct After {
	x int
}

fn (c Checker) after_two(a After) int {
	return a.x
}

const quoted = \'
fn not_a_declaration() {}
\'
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error != ''
	by_id := maps_by_id(fr.symbols)
	for id in ['demo.Checker', 'demo.Checker.shadows', 'demo.Checker.after_one', 'demo.plain',
		'demo.After', 'demo.After.x', 'demo.Checker.after_two', 'demo.quoted'] {
		assert id in by_id, id
	}
	assert 'demo.not_a_declaration' !in by_id
	assert by_id['demo.Checker.after_one'].line == 18
	assert by_id['demo.After'].line == 24
	assert by_id['demo.Checker.after_two'].line == 28
	assert fr.symbols.filter(it.kind == .import_).len == 1
	assert fr.symbols.filter(it.kind == .mod_).len == 1
	assert fr.symbols.all(it.name != '')
}

fn test_reparse_keeps_header_when_an_attribute_precedes_module() {
	src := '@[has_globals]
module demo

struct Checker {}

fn (c Checker) first() {
	name := 1
	for name in [1] {
		_ = name
	}
}

fn (c Checker) second() {}

struct Third {}
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error != ''
	by_id := maps_by_id(fr.symbols)
	assert 'demo.Checker.second' in by_id
	assert 'demo.Third' in by_id
	assert by_id['demo.Checker.second'].line == 13
}

// assert_import_edges_match_symbols checks the invariant extract_from_ast
// establishes and every later step must keep: each import symbol has its
// `imports` edge from the module, and each `imports` edge has its import symbol.
fn assert_import_edges_match_symbols(fr FileResult) {
	for s in fr.symbols.filter(it.kind == .import_) {
		assert fr.edges.any(it.kind == .imports && it.from == s.parent && it.to == s.name), 'import symbol ${s.id} has no imports edge'
	}
	for e in fr.edges.filter(it.kind == .imports) {
		assert fr.symbols.any(it.kind == .import_ && it.parent == e.from && it.name == e.to), 'imports edge ${e.from} -> ${e.to} has no import symbol'
	}
}

fn import_edges_to(fr FileResult, mod string) int {
	return fr.edges.filter(it.kind == .imports && it.to == mod).len
}

fn test_reparse_keeps_the_imports_edge_of_an_implicit_import() {
	// The parser adds `builtin.closure` itself when it reaches a closure. Here
	// the closure sits in a declaration after the one with the syntax error, so
	// the per-declaration re-parse's header (module and imports) never sees it:
	// the whole-file parse alone supplies the symbol, and its edge must come
	// along with it.
	src := r'module demo

import os

fn broken(y []int) {
	x := [1, ...(y)]
	println(x)
}

fn later() {
	f := fn () {
		println(os.args)
	}
	f()
}

fn last() {}
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error != ''
	assert fr.symbols.any(it.kind == .import_ && it.name == 'builtin.closure')
	assert import_edges_to(fr, 'builtin.closure') == 1
	assert import_edges_to(fr, 'os') == 1 // an explicit import is not duplicated
	assert_import_edges_match_symbols(fr)
}

fn test_reparse_keeps_the_imports_edges_of_every_implicit_import() {
	// Same rule for imports other than the closure one: `spawn` makes the parser
	// import the threading modules, again from a later declaration.
	src := r'module demo

fn broken(y []int) {
	x := [1, ...(y)]
	println(x)
}

fn threaded() {
	t := spawn println(1)
	t.wait()
}

fn last() {}
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error != ''
	assert fr.symbols.filter(it.kind == .import_).len >= 1 // the fixture really triggers one
	assert_import_edges_match_symbols(fr)
}

fn test_import_edges_match_import_symbols_when_a_file_parses_cleanly() {
	// The other side of the invariant, which never involved the re-parse: with no
	// syntax error the same shapes give the same one-to-one symbols and edges.
	src := r'module demo

import os

fn later() {
	f := fn () {
		println(os.args)
	}
	f()
}

fn threaded() {
	t := spawn println(1)
	t.wait()
}
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error == ''
	assert import_edges_to(fr, 'builtin.closure') == 1
	assert_import_edges_match_symbols(fr)
}

fn maps_by_id(syms []Symbol) map[string]Symbol {
	mut m := map[string]Symbol{}
	for s in syms {
		m[s.id] = s
	}
	return m
}

fn test_js_extern_decl_does_not_collide_with_same_name_v_wrapper() {
	// Same bug, JS backend -- matches
	// examples/wasm/change_color_by_id/change_color_by_id.wasm.v.
	src := 'module demo

fn JS.change_color(id string)

pub fn change_color(id string) {
	JS.change_color(id)
}
'
	syms, _ := extract_v_text(src, 'demo.v')
	fns := syms.filter(it.kind == .function)
	assert fns.len == 1
	assert fns[0].id == 'demo.change_color'
	assert fns[0].name == 'change_color'
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

fn test_disambiguate_ids_splits_main_module_collision() {
	// Two unrelated standalone programs, both `module main` (V's implicit
	// module for a program with no `module` declaration), each with their
	// own `fn main()` -- the single biggest real-world source of id
	// collision (see the README's Index.by_id note).
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'main.main'
			name:   'main'
			kind:   .function
			parent: 'main'
			file:   'a.v'
		},
		Symbol{
			id:     'main.main'
			name:   'main'
			kind:   .function
			parent: 'main'
			file:   'b.v'
		},
	]
	disambiguate_ids(mut g)
	assert g.symbols[0].id == 'main.main@a.v'
	assert g.symbols[1].id == 'main.main@b.v'
	assert g.symbols[0].id != g.symbols[1].id
	// each renamed declaration gets its own `defines` edge from the module
	assert g.edges.any(it.kind == .defines && it.from == 'main' && it.to == 'main.main@a.v')
	assert g.edges.any(it.kind == .defines && it.from == 'main' && it.to == 'main.main@b.v')
}

fn test_disambiguate_ids_leaves_platform_variant_untouched() {
	// One logical function declared once per platform -- e.g. `os.setenv` in
	// both environment.c.v and environment.js.v -- is NOT a collision: V
	// would reject a genuine redeclaration inside one ordinary module, so a
	// repeat here means the same id correctly addresses both declarations.
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'os.setenv'
			name:   'setenv'
			kind:   .function
			parent: 'os'
			file:   'environment.c.v'
		},
		Symbol{
			id:     'os.setenv'
			name:   'setenv'
			kind:   .function
			parent: 'os'
			file:   'environment.js.v'
		},
	]
	disambiguate_ids(mut g)
	assert g.symbols[0].id == 'os.setenv'
	assert g.symbols[1].id == 'os.setenv'
}

fn test_disambiguate_ids_splits_multi_test_file_collision() {
	// Not `main` this time -- an ordinary module, but the id repeats across
	// two distinct `_test.v` files, each of which V compiles as its own
	// executable, so they are separate build units too.
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'mymod.helper'
			name:   'helper'
			kind:   .function
			parent: 'mymod'
			file:   'a_test.v'
		},
		Symbol{
			id:     'mymod.helper'
			name:   'helper'
			kind:   .function
			parent: 'mymod'
			file:   'b_test.v'
		},
	]
	disambiguate_ids(mut g)
	assert g.symbols[0].id == 'mymod.helper@a_test.v'
	assert g.symbols[1].id == 'mymod.helper@b_test.v'
}

fn test_disambiguate_ids_cascades_to_struct_fields() {
	// Two colliding `main.Foo` structs, each with a field named `x` -- the
	// field's own id/parent embed the struct's id as a literal prefix, so
	// they must move in lockstep with the struct's rename even though a
	// field's own bare id is never itself checked for collision.
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'main.Foo'
			name:   'Foo'
			kind:   .struct_
			parent: 'main'
			file:   'a.v'
		},
		Symbol{
			id:     'main.Foo.x'
			name:   'x'
			kind:   .field
			parent: 'main.Foo'
			file:   'a.v'
		},
		Symbol{
			id:     'main.Foo'
			name:   'Foo'
			kind:   .struct_
			parent: 'main'
			file:   'b.v'
		},
		Symbol{
			id:     'main.Foo.x'
			name:   'x'
			kind:   .field
			parent: 'main.Foo'
			file:   'b.v'
		},
	]
	disambiguate_ids(mut g)
	assert g.symbols[0].id == 'main.Foo@a.v'
	assert g.symbols[1].id == 'main.Foo@a.v.x'
	assert g.symbols[1].parent == 'main.Foo@a.v'
	assert g.symbols[2].id == 'main.Foo@b.v'
	assert g.symbols[3].id == 'main.Foo@b.v.x'
	assert g.symbols[3].parent == 'main.Foo@b.v'
}

fn test_disambiguate_ids_renames_outgoing_calls_edges() {
	// Each colliding `main.main` calls a different helper -- Edge.file is
	// what lets disambiguate_ids tell the two calls edges apart even though
	// both originally share the exact same `from`.
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'main.main'
			name:   'main'
			kind:   .function
			parent: 'main'
			file:   'a.v'
		},
		Symbol{
			id:     'main.main'
			name:   'main'
			kind:   .function
			parent: 'main'
			file:   'b.v'
		},
	]
	g.edges = [
		Edge{
			from: 'main.main'
			to:   'helper_a'
			kind: .calls
			file: 'a.v'
		},
		Edge{
			from: 'main.main'
			to:   'helper_b'
			kind: .calls
			file: 'b.v'
		},
	]
	disambiguate_ids(mut g)
	call_a := g.edges.filter(it.kind == .calls && it.to == 'helper_a')
	call_b := g.edges.filter(it.kind == .calls && it.to == 'helper_b')
	assert call_a.len == 1
	assert call_a[0].from == 'main.main@a.v'
	assert call_b.len == 1
	assert call_b[0].from == 'main.main@b.v'
}

fn test_disambiguate_ids_then_resolve_edges_fixes_self_receiver_across_collision() {
	// End-to-end: two unrelated standalone programs each declare their own
	// `struct Foo` with a `bar` method that self-calls `baz` on the same
	// receiver -- the exact self-receiver shortcut in resolve_callee that
	// only works once the receiver type's id has been correctly
	// disambiguated (want_suffixed) rather than left pointing at a bare,
	// now-collided id that matches nothing.
	src := 'struct Foo {}

fn (f Foo) baz() {}

fn (f Foo) bar() {
	f.baz()
}
'
	syms_a, edges_a := extract_v_text(src, 'a.v')
	syms_b, edges_b := extract_v_text(src, 'b.v')
	mut g := Graph{}
	g.symbols << syms_a
	g.symbols << syms_b
	g.edges << edges_a
	g.edges << edges_b
	disambiguate_ids(mut g)
	resolve_edges(mut g)

	bar_a := g.symbols.filter(it.name == 'bar' && it.file == 'a.v')[0]
	bar_b := g.symbols.filter(it.name == 'bar' && it.file == 'b.v')[0]
	baz_a := g.symbols.filter(it.name == 'baz' && it.file == 'a.v')[0]
	baz_b := g.symbols.filter(it.name == 'baz' && it.file == 'b.v')[0]
	assert bar_a.id != bar_b.id // the collision was real -- ids came out distinct
	assert baz_a.id != baz_b.id

	call_from_a := g.edges.filter(it.kind == .calls && it.from == bar_a.id)
	call_from_b := g.edges.filter(it.kind == .calls && it.from == bar_b.id)
	assert call_from_a.len == 1
	assert call_from_a[0].to == baz_a.id // resolves to its OWN file's baz, not the other's
	assert call_from_a[0].provenance == .extracted // self-receiver -- no guessing needed
	assert call_from_b.len == 1
	assert call_from_b[0].to == baz_b.id
	assert call_from_b[0].provenance == .extracted
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

// merge_get_body_fixture writes two tiny on-disk source trees (distinct
// content, same relative filename, so a root mix-up would read the wrong
// one) and returns their Graphs, ready to merge. Callers must remove the
// returned roots when done.
fn merge_get_body_fixture() (Graph, Graph, string, string) {
	root_a := os.join_path(os.temp_dir(), 'graphify_test_merge_a_${os.getpid()}')
	root_b := os.join_path(os.temp_dir(), 'graphify_test_merge_b_${os.getpid()}')
	os.rmdir_all(root_a) or {}
	os.rmdir_all(root_b) or {}
	os.mkdir_all(root_a) or { panic(err) }
	os.mkdir_all(root_b) or { panic(err) }
	os.write_file(os.join_path(root_a, 'demo.v'), 'fn greet_a() string {\n\treturn "hello from a"\n}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root_b, 'demo.v'), 'fn greet_b() string {\n\treturn "hello from b"\n}\n') or {
		panic(err)
	}
	mut a := Graph{
		root: root_a
	}
	a.symbols = [
		Symbol{
			id:       'demo.greet_a'
			name:     'greet_a'
			kind:     .function
			file:     'demo.v'
			line:     1
			end_line: 3
		},
	]
	mut b := Graph{
		root: root_b
	}
	b.symbols = [
		Symbol{
			id:       'demo.greet_b'
			name:     'greet_b'
			kind:     .function
			file:     'demo.v'
			line:     1
			end_line: 3
		},
	]
	return a, b, root_a, root_b
}

fn test_get_body_merged_graph_reads_from_each_source_own_root() {
	a, b, root_a, root_b := merge_get_body_fixture()
	defer {
		os.rmdir_all(root_a) or {}
		os.rmdir_all(root_b) or {}
	}

	merged := merge_graphs([a, b], ['svc_a', 'svc_b'])
	body_a := merged.get_body('svc_a::demo.greet_a')
	body_b := merged.get_body('svc_b::demo.greet_b')
	assert body_a.contains('hello from a')
	assert !body_a.contains('hello from b') // proves it read root_a's demo.v, not root_b's
	assert body_b.contains('hello from b')
	assert !body_b.contains('hello from a')
}

fn test_get_body_unmerged_graph_still_uses_single_root() {
	// A plain, non-merged graph has an empty `roots` map -- get_body must
	// fall back to `g.root` exactly as it did before merged graphs existed.
	a, _, root_a, root_b := merge_get_body_fixture()
	defer {
		os.rmdir_all(root_a) or {}
		os.rmdir_all(root_b) or {}
	}
	assert a.roots.len == 0
	body := a.get_body('demo.greet_a')
	assert body.contains('hello from a')
}

// body_fixture extracts `src` with the real extractor and writes it as demo.v
// under a per-process temp root, so get_body reads real on-disk text at the
// real symbols' line numbers. Callers must remove the returned root.
fn body_fixture(src string) (Graph, string) {
	root := os.join_path(os.temp_dir(), 'graphify_test_body_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	os.write_file(os.join_path(root, 'demo.v'), src) or { panic(err) }
	syms, edges := extract_v_text(src, 'demo.v')
	mut g := Graph{
		root: root
	}
	g.symbols = syms
	g.edges = edges
	return g, root
}

// own_closer is the closing brace a declaration named `name` should end with:
// a `}` at the same indentation as its `fn` line in `src`.
fn own_closer(src string, name string) string {
	for line in src.split('\n') {
		t := line.trim_space()
		if t.starts_with('fn ${name}(') || t.starts_with('pub fn ${name}(') {
			return line[..line.len - line.trim_left(' \t').len] + '}'
		}
	}
	return ''
}

// assert_body_ends_at_own_brace checks every fn in `names` that the extractor
// kept: get_body must stop at that fn's own closing brace, never at an
// enclosing block's. Returns how many were checked.
fn assert_body_ends_at_own_brace(g Graph, src string, names []string) int {
	mut checked := 0
	for name in names {
		if !g.symbols.any(it.name == name) {
			continue
		}
		body := g.get_body(name)
		want := own_closer(src, name)
		assert want != ''
		assert body.split('\n').last() == want, 'get_body(${name}) ended at the wrong brace:\n${body}'
		checked++
	}
	return checked
}

fn test_get_body_of_a_fn_in_a_file_level_comptime_if_ends_at_its_own_brace() {
	// get_body has no reliable end line for fns, so it trims back from the next
	// declaration to a closing brace. A fn inside a file-scope `$if` is followed
	// by the `$if`'s own `}`, which must not be taken for the fn's.
	src := r'module demo

$if windows {
	fn win_last() {
		println(1)
	}
} $else {
	fn other_last() {
		println(1)
	}
}

fn after() {
	println(2)
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	// the parser keeps exactly the host's branch
	assert assert_body_ends_at_own_brace(g, src, ['win_last', 'other_last']) == 1
	body := g.get_body(if g.symbols.any(it.name == 'win_last') { 'win_last' } else { 'other_last' })
	assert body.contains('println(1)')
	assert !body.contains('after')
}

fn test_get_body_in_nested_and_sibling_comptime_ifs_ends_at_the_fns_own_brace() {
	// The general rule: whatever encloses a fn, get_body stops at the closing
	// brace at the fn's own indentation. Every host keeps exactly one of
	// deep_a..deep_d (two levels down) and one of mid_a/mid_b (one level down,
	// with the nested `$if` closing right above it).
	src := r'module demo

$if windows {
	$if amd64 {
		fn deep_a() {
			println(1)
		}
	} $else {
		fn deep_b() {
			println(1)
		}
	}
	fn mid_a() {
		println(2)
	}
} $else {
	$if amd64 {
		fn deep_c() {
			println(1)
		}
	} $else {
		fn deep_d() {
			println(1)
		}
	}
	fn mid_b() {
		println(2)
	}
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	assert assert_body_ends_at_own_brace(g, src, ['deep_a', 'deep_b', 'deep_c', 'deep_d']) == 1
	assert assert_body_ends_at_own_brace(g, src, ['mid_a', 'mid_b']) == 1
}

fn test_get_body_of_a_plain_fn_skips_the_next_declarations_doc_comment() {
	// Unchanged behavior the indentation-aware trim must keep: the gap before
	// the next declaration holds blank lines and its doc comment, none of which
	// belong to this fn's body.
	src := 'module demo

fn first() {
	println(1)
}

// second is documented.
fn second() {
	println(2)
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	assert assert_body_ends_at_own_brace(g, src, ['first', 'second']) == 2
	assert !g.get_body('first').contains('documented')
}

fn test_get_body_of_a_one_line_fn_in_a_comptime_if_is_just_that_line() {
	// An indented one-liner has no closing brace line of its own, so it must not
	// reach for the enclosing `$if`'s.
	src := r'module demo

$if windows {
	fn tiny_win() int { return 1 }
} $else {
	fn tiny_other() int { return 1 }
}

fn after() {
	println(2)
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	name := if g.symbols.any(it.name == 'tiny_win') { 'tiny_win' } else { 'tiny_other' }
	assert g.get_body(name).split('\n').len == 2, g.get_body(name) // header + the one line
	assert g.get_body(name).split('\n').last() == '\tfn ${name}() int { return 1 }'
}

fn test_get_body_for_a_line_past_the_end_of_a_shrunken_file_has_no_source() {
	// The graph can outlive an edit that shortened the file. An unknown end line
	// plus a start past EOF must report no source, not index out of range.
	src := 'module demo\n\nfn only() {\n\tprintln(1)\n}\n'
	mut g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	g.symbols = [
		Symbol{
			id:   'demo.gone'
			name: 'gone'
			kind: .function
			file: 'demo.v'
			line: 99
		},
	]
	assert g.get_body('gone') == '(no source)'
}

fn test_get_body_falls_back_to_any_closing_brace_when_none_matches_the_indent() {
	// Not vfmt'd: the fn starts at column 0 but its brace is indented. No brace
	// matches the declaration's indentation, so get_body must still end at the
	// nearest closing brace rather than reaching back to the header.
	src := 'module demo

fn odd() {
	println(1)
	}

fn next_one() {
	println(2)
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	body := g.get_body('odd')
	assert body.split('\n').last() == '\t}', body
	assert body.contains('println(1)')
}

fn test_merge_graphs_nested_merge_propagates_roots() {
	// Merging an already-merged graph must re-prefix its inner labels rather
	// than collapsing to its cosmetic `root` (a " + "-joined display string,
	// not a real path -- see merge_graphs' doc comment).
	mut a := Graph{
		root: 'S:/repo/svc-a'
	}
	a.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function, file: 'x.v' }]
	mut b := Graph{
		root: 'S:/repo/svc-b'
	}
	b.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function, file: 'x.v' }]
	inner := merge_graphs([a, b], ['svc_a', 'svc_b'])
	assert inner.roots == {
		'svc_a': 'S:/repo/svc-a'
		'svc_b': 'S:/repo/svc-b'
	}

	mut c := Graph{
		root: 'S:/repo/svc-c'
	}
	c.symbols = [Symbol{ id: 'x.f', name: 'f', kind: .function, file: 'x.v' }]
	outer := merge_graphs([inner, c], ['bundle', 'svc_c'])
	assert outer.roots == {
		'bundle::svc_a': 'S:/repo/svc-a'
		'bundle::svc_b': 'S:/repo/svc-b'
		'svc_c':         'S:/repo/svc-c'
	}
	// and a symbol that went through both merges resolves through the
	// composed two-level prefix, not just the outer one.
	assert outer.source_root(Symbol{ id: 'bundle::svc_a::x.f' }) == 'S:/repo/svc-a'
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

	// The "N of M" disclosure only appears when compute_drill_views actually
	// dropped a qualifying (>= drill_min_members) community -- to the
	// drill_max_candidates cap, or to the "not really splittable" gate --
	// never unconditionally. Louvain's shuffled visitation order (see
	// communities.v) means the number of >= drill_min_members communities
	// this ring produces varies run to run, so don't assume it's always
	// more than drill_max_candidates: recover the actual qualifying count
	// the same way compute_drill_views did, from the legend's own
	// per-community sizes (legend and drill views are built from the same
	// `comms` slice inside emit_graph_html, and layout_ring always keeps
	// at least one member per community, so every qualifying community is
	// guaranteed a legend entry to count here).
	mut qualifying := 0
	mut rest := out
	for {
		start := rest.index('<span class="count">(') or { break }
		tail := rest[start + '<span class="count">('.len..]
		end := tail.index(')') or { break }
		if tail[..end].int() >= drill_min_members {
			qualifying++
		}
		rest = tail[end..]
	}
	assert qualifying >= views // every rendered drill-view came from a qualifying community
	if qualifying > views {
		assert out.contains('large communities include a detail view')
	} else {
		assert !out.contains('large communities include a detail view')
	}
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

fn test_rel_path_is_case_insensitive() {
	// Windows/macOS resolve `root` and a walked `path` from the same
	// filesystem entry regardless of casing, so a mismatch never showed up
	// there — but on a case-sensitive filesystem a real casing difference
	// between how `root` and `path` were each constructed (e.g. a symlink,
	// or os.real_path normalizing differently) must still be recognized as
	// "path is under root", not silently fall through to the raw absolute
	// path.
	assert rel_path('/repo/Project', '/repo/project/vlib/os/os.v') == 'vlib/os/os.v'
	assert rel_path('/repo/project', '/repo/Project/vlib/os/os.v') == 'vlib/os/os.v'
	// exact-case match still works
	assert rel_path('/repo/project', '/repo/project/vlib/os/os.v') == 'vlib/os/os.v'
	// a genuinely unrelated path still falls through unchanged
	assert rel_path('/repo/project', '/other/place/os.v') == '/other/place/os.v'
}

// cache_test_dir returns a fresh scratch dir for one cache.v test, so
// separate tests never share (or race on) the same .gf_cache.ndjson.
fn cache_test_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'graphify_test_cache_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_cache_round_trips_when_binary_hash_matches() {
	dir := cache_test_dir('roundtrip')
	entries := [
		CacheEntry{
			rel:  'demo.v'
			hash: 'abc123'
			fr:   FileResult{
				symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
			}
		},
	]
	save_cache(dir, 'binhash1', entries)
	loaded := load_cache(dir, 'binhash1')
	assert loaded.len == 1
	assert loaded['demo.v'].hash == 'abc123'
	assert loaded['demo.v'].fr.symbols[0].id == 'demo.greet'
}

fn test_cache_rejected_when_binary_hash_differs() {
	// The actual bug this fix closes: a cache written by one graphify binary
	// must not be trusted by a DIFFERENT one, even though every per-file
	// content hash inside it would still match on disk -- the binary is what
	// decides what a file's content extracts to, not just the file itself.
	dir := cache_test_dir('binary_mismatch')
	entries := [
		CacheEntry{
			rel:  'demo.v'
			hash: 'abc123'
			fr:   FileResult{
				symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
			}
		},
	]
	save_cache(dir, 'binhash1', entries)
	loaded := load_cache(dir, 'binhash2')
	assert loaded.len == 0
}

fn test_cache_rejected_when_written_by_older_format_without_binary_line() {
	// Simulates a real pre-existing v4 cache file already on a user's disk
	// from before this fix (format marker + per-file lines directly, no
	// binary-hash line at all) -- upgrading graphify must not crash trying
	// to parse it, and must treat it as stale (full reparse) rather than
	// silently misinterpreting the first entry line as a binary-hash header.
	dir := cache_test_dir('old_format')
	old_style := 'graphify-cache-v4\ndemo.v\tabc123\t' + encode_file_result(FileResult{
		symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
	})
	os.write_file(os.join_path(dir, cache_file_name), old_style) or { panic(err) }
	loaded := load_cache(dir, 'binhash1')
	assert loaded.len == 0

	// Also cover a hypothetical current-format file that is merely truncated
	// (format line present, binary-hash line missing entirely) -- the same
	// lines.len < 2 guard must catch this shape too, not just a wrong marker.
	os.write_file(os.join_path(dir, cache_file_name), cache_format) or { panic(err) }
	assert load_cache(dir, 'binhash1').len == 0
}

fn test_cache_not_trusted_or_written_when_binary_hash_is_blank() {
	// A blank bin_hash means we couldn't even hash our own executable --
	// nothing should be trusted, and nothing should be written that a future
	// load could never validate anyway.
	dir := cache_test_dir('blank_hash')
	entries := [
		CacheEntry{
			rel:  'demo.v'
			hash: 'abc123'
			fr:   FileResult{
				symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
			}
		},
	]
	save_cache(dir, '', entries)
	assert !os.exists(os.join_path(dir, cache_file_name))
	assert load_cache(dir, '').len == 0
}

fn test_cache_round_trips_the_stale_flag() {
	dir := cache_test_dir('stale_roundtrip')
	entries := [
		CacheEntry{
			rel:   'fresh.v'
			hash:  'h1'
			stale: false
			fr:    FileResult{
				symbols: [Symbol{ id: 'demo.fresh', name: 'fresh', kind: .function }]
			}
		},
		CacheEntry{
			rel:   'flaky.v'
			hash:  'h2'
			stale: true
			fr:    FileResult{
				symbols: [Symbol{ id: 'demo.flaky', name: 'flaky', kind: .function }]
			}
		},
	]
	save_cache(dir, 'binhash1', entries)
	loaded := load_cache(dir, 'binhash1')
	assert loaded.len == 2
	assert loaded['fresh.v'].stale == false
	assert loaded['flaky.v'].stale == true
	// a pre-fix 3-field line (no stale column) under an otherwise-valid
	// header must not be silently misparsed as if its FileResult text were
	// the stale flag -- it should simply be skipped, exactly like any other
	// malformed line, rather than crashing or fabricating a bogus entry.
	three_field_line := 'legacy.v\th3\t' + encode_file_result(FileResult{
		symbols: [Symbol{ id: 'demo.legacy', name: 'legacy', kind: .function }]
	})
	os.write_file(os.join_path(dir, cache_file_name), [cache_format, 'binary:binhash1', three_field_line].join('\n')) or {
		panic(err)
	}
	assert load_cache(dir, 'binhash1').len == 0
}

fn test_stale_fallback_for_returns_the_prior_entry_marked_stale() {
	old_cache := {
		'demo.v': CacheEntry{
			rel:   'demo.v'
			hash:  'h1'
			stale: false
			fr:    FileResult{
				symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
			}
		}
	}
	fallback := stale_fallback_for(old_cache, 'demo.v') or { panic('expected a fallback') }
	assert fallback.hash == 'h1'
	assert fallback.fr.symbols[0].id == 'demo.greet'
	assert fallback.stale == true
}

fn test_stale_fallback_for_returns_none_when_file_was_never_previously_cached() {
	old_cache := map[string]CacheEntry{}
	fallback := stale_fallback_for(old_cache, 'never_seen.v')
	assert fallback == none
}

fn test_stale_fallback_for_marks_stale_even_when_the_prior_entry_already_was() {
	// a file that keeps crashing across multiple runs should keep serving
	// the SAME original known-good extraction, not lose it after one cycle.
	old_cache := {
		'demo.v': CacheEntry{
			rel:   'demo.v'
			hash:  'h1'
			stale: true
			fr:    FileResult{
				symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
			}
		}
	}
	fallback := stale_fallback_for(old_cache, 'demo.v') or { panic('expected a fallback') }
	assert fallback.stale == true
	assert fallback.fr.symbols[0].id == 'demo.greet'
}

fn test_fresh_reuse_of_clears_a_previously_stale_flag() {
	// a hash match against the file's current content is a direct
	// verification, so a prior stale flag must not survive it -- otherwise a
	// file that recovers (or simply reverts to known-good content) would be
	// stuck reporting itself stale forever.
	cached := CacheEntry{
		rel:   'demo.v'
		hash:  'h1'
		stale: true
		fr:    FileResult{
			symbols: [Symbol{ id: 'demo.greet', name: 'greet', kind: .function }]
		}
	}
	reused := fresh_reuse_of(cached)
	assert reused.stale == false
	assert reused.hash == 'h1'
	assert reused.fr.symbols[0].id == 'demo.greet'
}

// hub_spoke_graph builds one `hub_fn` symbol calling `n` `leaf_N` symbols --
// a single connected component reachable in one hop from the hub, used to
// exercise query()/shortest_path() traversal without needing a real corpus.
fn hub_spoke_graph(n int) Graph {
	mut g := Graph{}
	g.symbols << Symbol{
		id:        'demo.hub_fn'
		name:      'hub_fn'
		kind:      .function
		file:      'demo.v'
		signature: 'fn hub_fn()'
	}
	for i in 0 .. n {
		leaf_id := 'demo.leaf_${i}'
		leaf_name := 'leaf_${i}'
		g.symbols << Symbol{
			id:        leaf_id
			name:      leaf_name
			kind:      .function
			file:      'demo.v'
			signature: 'fn ${leaf_name}()'
		}
		g.edges << Edge{
			from: 'demo.hub_fn'
			to:   leaf_id
			kind: .calls
		}
	}
	return g
}

fn test_query_finds_seeds_and_walks_calls_edges() {
	// query()/shortest_path() had ZERO test coverage before this -- this is
	// the first basic correctness check, not just the regression test below.
	g := hub_spoke_graph(3)
	out := g.query('hub', 2000, false)
	assert out.contains('fn hub_fn()')
	assert out.contains('fn leaf_0()')
	assert out.contains('fn leaf_1()')
	assert out.contains('fn leaf_2()')
}

fn test_query_never_walks_past_budget_even_in_a_large_component() {
	// The actual bug: query() used to walk the ENTIRE reachable component
	// before ever consulting `budget` -- on a real corpus (vlang, "asm"
	// query) that reached 85% of a 116k-symbol graph, and combined with an
	// O(n) `queue.delete(0)` dequeue, hung for 8+ CPU-minutes per query.
	// Verified this test actually catches that: temporarily reverted just
	// the query() fix (kept queue.delete(0) and no budget check on the
	// traversal loop) and confirmed this assertion FAILS with visited=51
	// (hub + all 50 leaves) before restoring the fix, which brings it to 5.
	g := hub_spoke_graph(50) // hub + 50 leaves = 51 nodes, all one component
	out := g.query('hub', 5, false)
	// "// query: hub  (N of VISITED visited symbols, ~T tokens)"
	visited := out.all_before('\n').all_after('of ').all_before(' visited').int()
	assert visited > 0 // sanity: actually parsed a number, not a silent 0 from a broken extraction
	assert visited <= 5
}

fn test_query_dfs_mode_also_finds_seeds() {
	g := hub_spoke_graph(3)
	out := g.query('leaf_1', 2000, true)
	assert out.contains('fn leaf_1()')
}

fn test_shortest_path_finds_a_real_path() {
	g := hub_spoke_graph(3)
	path := g.shortest_path('demo.leaf_0', 'demo.leaf_1')
	assert path == ['demo.leaf_0', 'demo.hub_fn', 'demo.leaf_1']
}

fn test_shortest_path_returns_empty_for_unreachable_or_unknown_nodes() {
	g := hub_spoke_graph(3)
	mut g2 := Graph{}
	g2.symbols << Symbol{ id: 'other.thing', name: 'thing', kind: .function }
	// unknown node on one side
	assert g.shortest_path('demo.leaf_0', 'nonexistent') == []
	// known nodes, but no edge connects them at all (disjoint graphs, so no
	// path exists once merged into one lookup -- same shape as "unreachable")
	mut disjoint := Graph{}
	disjoint.symbols << g.symbols
	disjoint.symbols << g2.symbols
	disjoint.edges << g.edges
	assert disjoint.shortest_path('demo.leaf_0', 'other.thing') == []
}

// store_test_dir returns a fresh scratch dir for one store.v test.
fn store_test_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'graphify_test_store_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn test_atomic_replace_replaces_an_existing_destination_file() {
	// The actual regression this guards against: Windows' C runtime
	// rename() FAILS outright when the destination already exists (verified
	// directly against the real Windows API, not assumed from docs) -- a
	// naive `os.rename(src, dst)` on Windows would error here every time,
	// since `dst` already exists. This is the exact scenario save_graph
	// hits on every publish after the first one (graph.json already exists).
	dir := store_test_dir('atomic_replace_direct')
	src := os.join_path(dir, 'src.txt')
	dst := os.join_path(dir, 'dst.txt')
	os.write_file(src, 'NEW') or { panic(err) }
	os.write_file(dst, 'OLD') or { panic(err) } // destination already exists
	atomic_replace(src, dst) or { panic(err) }
	assert (os.read_file(dst) or { panic(err) }) == 'NEW'
	assert !os.exists(src)
}

fn test_save_graph_works_when_the_target_already_exists() {
	// Integration-level sanity check on top of the direct atomic_replace
	// test above: a second save_graph to the same path (an ordinary repeat
	// extract) succeeds and fully replaces the previous content, with no
	// leftover `.tmp.<pid>` file from either write.
	dir := store_test_dir('atomic_replace')
	path := os.join_path(dir, 'graph.json')

	mut first := Graph{ root: 'r1' }
	first.symbols << Symbol{ id: 'demo.a', name: 'a', kind: .function }
	save_graph(first, path) or { panic(err) }
	loaded1 := load_graph(path) or { panic(err) }
	assert loaded1.symbols.len == 1
	assert loaded1.symbols[0].id == 'demo.a'

	mut second := Graph{ root: 'r2' }
	second.symbols << Symbol{ id: 'demo.b', name: 'b', kind: .function }
	second.symbols << Symbol{ id: 'demo.c', name: 'c', kind: .function }
	save_graph(second, path) or { panic(err) }
	loaded2 := load_graph(path) or { panic(err) }
	assert loaded2.symbols.len == 2
	assert loaded2.symbols.map(it.id) == ['demo.b', 'demo.c']

	// no leftover `.tmp.<pid>` file from either write.
	leftover := os.ls(dir) or { panic(err) }.filter(it.contains('.tmp.'))
	assert leftover.len == 0
}

fn diff_symbol(id string, file string) Symbol {
	return Symbol{
		id:   id
		name: id
		kind: .function
		file: file
		line: 1
	}
}

fn test_diff_graphs_returns_empty_when_nothing_disappeared() {
	old := Graph{ symbols: [diff_symbol('demo.a', 'a.v')] }
	new := Graph{ symbols: [diff_symbol('demo.a', 'a.v')] }
	assert diff_graphs(old, new, '') == []
}

fn test_diff_graphs_reports_symbols_missing_from_new_grouped_by_file() {
	old := Graph{
		symbols: [
			diff_symbol('demo.a', 'a.v'),
			diff_symbol('demo.b', 'b.v'),
			diff_symbol('demo.c', 'b.v'),
		]
	}
	new := Graph{ symbols: [diff_symbol('demo.a', 'a.v')] }
	losses := diff_graphs(old, new, '')
	assert losses.len == 1
	assert losses[0].file == 'b.v'
	assert losses[0].symbols.map(it.id) == ['demo.b', 'demo.c']
}

fn test_diff_graphs_reports_unknown_status_without_a_manifest() {
	old := Graph{ symbols: [diff_symbol('demo.a', 'a.v')] }
	new := Graph{}
	losses := diff_graphs(old, new, '')
	assert losses[0].status == FileLossStatus.unknown
}

fn test_diff_graphs_marks_status_from_the_new_graphs_manifest() {
	dir := store_test_dir('diff_manifest')
	report := ExtractReport{
		binary_hash: 'bh1'
		failed:      ['failed.v']
		stale:       ['stale.v']
		partial:     ['partial.v']
	}
	// only manifest.json matters to diff_graphs, but write_bundle needs a
	// real graph to also succeed at writing graph.json/GRAPH_REPORT.md.
	write_bundle(Graph{ root: dir }, dir, report) or { panic(err) }

	old := Graph{
		symbols: [
			diff_symbol('demo.failed', 'failed.v'),
			diff_symbol('demo.stale', 'stale.v'),
			diff_symbol('demo.partial', 'partial.v'),
			diff_symbol('demo.removed', 'removed.v'),
			diff_symbol('demo.present_sibling', 'present.v'),
			diff_symbol('demo.vanished', 'present.v'),
		]
	}
	new := Graph{ symbols: [diff_symbol('demo.present_sibling', 'present.v')] }
	losses := diff_graphs(old, new, dir)

	mut status_by_file := map[string]FileLossStatus{}
	for loss in losses {
		status_by_file[loss.file] = loss.status
	}
	assert status_by_file['failed.v'] == FileLossStatus.parse_failed
	assert status_by_file['stale.v'] == FileLossStatus.stale
	assert status_by_file['partial.v'] == FileLossStatus.partially_parsed
	assert status_by_file['removed.v'] == FileLossStatus.file_removed
	assert status_by_file['present.v'] == FileLossStatus.symbol_missing
}

fn test_manifest_json_carries_the_extract_report() {
	g := Graph{ root: 'r' }
	report := ExtractReport{
		binary_hash: 'abc123'
		failed:      ['x.v']
		stale:       ['y.v']
		partial:     ['z.v']
	}
	decoded := json2.decode[Manifest](g.manifest_json(report)) or { panic(err) }
	assert decoded.binary_hash == 'abc123'
	assert decoded.failed == ['x.v']
	assert decoded.stale == ['y.v']
	assert decoded.partial == ['z.v']
}

fn test_git_commit_of_is_blank_outside_a_git_repository() {
	// A missing commit is recorded as absent, never an error that could stop
	// an extract from publishing.
	dir := store_test_dir('git_commit_none')
	inside := os.exec(['git', '-C', dir, 'rev-parse', '--is-inside-work-tree'])
	if inside.exit_code == 0 {
		return // the scratch dir happens to sit inside someone's work tree; nothing to assert
	}
	assert git_commit_of(dir) == ''
}

fn test_git_commit_of_matches_git_rev_parse_in_a_real_repository() {
	// This checkout, when the sources really are in a git work tree (skipped
	// for e.g. an exported tarball, where there is no commit to find).
	expected := os.exec(['git', '-C', @VMODROOT, 'rev-parse', 'HEAD'])
	if expected.exit_code != 0 {
		return
	}
	got := git_commit_of(@VMODROOT)
	assert got != ''
	assert got == expected.output.trim_space()
}

// The V 0.5.2 parser does not know the array-literal spread on line 8. With
// its default settings it would stop there and drop everything after it;
// extraction runs it in recovery mode instead (extract_prefs), so it reports
// the error and still reads the rest of the file.
const partial_parse_src = 'module demo

fn before() int {
	return 1
}

fn broken() []int {
	x := [1, ...(parts()), 4]
	return x
}

fn after() int {
	return 2
}
'

fn test_extract_reports_a_parse_error_and_recovers_past_it() {
	fr := extract_v_text_result(partial_parse_src, 'demo.v')
	assert fr.parse_error.starts_with('8:'), fr.parse_error
	names := fr.symbols.map(it.name)
	assert 'before' in names
	assert 'after' in names
}

// A script-style file (top-level statements, no `fn main`) with an anonymous
// fn inside a top-level call: recovering past the first "bad top level
// statement", the parser reaches that `fn` and records it as a top-level
// declaration with no name. Such a node is not a real declaration and must
// not become a symbol -- its id would just be `<module>.`.
fn test_extract_drops_nameless_fn_declarations_from_error_recovery() {
	src := 'import gg

gg.start(
	frame_fn: fn (ctx &gg.Context) {
		ctx.begin()
	}
)
'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error != ''
	for s in fr.symbols {
		assert s.name != '', 'nameless symbol: ${s.id}'
	}
}

fn test_extract_clean_file_has_no_parse_error() {
	fr := extract_v_text_result('module demo\n\nfn ok() int {\n\treturn 1\n}\n', 'demo.v')
	assert fr.parse_error == ''
	assert fr.symbols.map(it.name).contains('ok')
}

fn test_file_result_parse_error_round_trips_through_the_batch_protocol() {
	fr := extract_v_text_result(partial_parse_src, 'demo.v')
	back := decode_file_result(encode_file_result(fr))
	assert back.parse_error == fr.parse_error
	assert back.symbols.len == fr.symbols.len
	clean := decode_file_result(encode_file_result(FileResult{}))
	assert clean.parse_error == ''
}

fn test_edge_file_round_trips_through_the_batch_protocol() {
	// disambiguate_ids renames a calls edge's `from` to `${from}@${file}`. The
	// protocol used to drop Edge.file, so on the worker path that `graphify
	// extract` takes, every call from a renamed declaration (each standalone
	// program's `main`) came out from `main@`, an id that does not exist.
	// The typed local matters: track_assign rebuilt the call context after it
	// and dropped the file, so every later call in the body lost it too.
	fr := extract_v_text_result('module main

struct Foo {}

fn main() {
	f := Foo{}
	println(f)
}
', 'tools/a.v')
	back := decode_file_result(encode_file_result(fr))
	calls := back.edges.filter(it.kind == .calls)
	assert calls.len > 0
	assert calls.all(it.file == 'tools/a.v')
}

fn test_cache_round_trips_a_partial_results_parse_error() {
	// A file with syntax errors that does not change is reused from the cache
	// next run rather than reparsed, so the cache must keep its parse error.
	dir := cache_test_dir('partial_roundtrip')
	save_cache(dir, 'binhash1', [
		CacheEntry{
			rel:  'part.v'
			hash: 'h1'
			fr:   FileResult{
				symbols:     [Symbol{ id: 'demo.before', name: 'before', kind: .function }]
				parse_error: '8:11: invalid expression: unexpected token `...`'
			}
		},
		CacheEntry{
			rel:  'whole.v'
			hash: 'h2'
			fr:   FileResult{
				symbols: [Symbol{ id: 'demo.ok', name: 'ok', kind: .function }]
			}
		},
	])
	loaded := load_cache(dir, 'binhash1')
	assert loaded['part.v'].fr.parse_error == '8:11: invalid expression: unexpected token `...`'
	assert loaded['part.v'].fr.symbols.len == 1
	assert loaded['whole.v'].fr.parse_error == ''
}

// write_tree lays `files` (relative path -> source) out under a fresh temp dir
// and returns its root.
fn write_tree(name string, files map[string]string) string {
	root := os.join_path(os.temp_dir(), 'graphify_test_${name}_${os.getpid()}')
	os.rmdir_all(root) or {}
	for rel, src in files {
		path := os.join_path(root, rel)
		os.mkdir_all(os.dir(path)) or { panic(err) }
		os.write_file(path, src) or { panic(err) }
	}
	return root
}

fn test_programs_in_a_subdirectory_are_separate_build_units() {
	// Module ids come from the directory, so two programs in tools/ both have
	// the parent `tools`; only their `module main` says they are separate.
	// Before main_unit_files, their `main` and `helper` shared one id each and
	// a call from one program resolved into the other.
	prog := 'module main

fn helper() {}

fn main() {
	helper()
}
'
	root := write_tree('main_units', {
		'tools/a.v': prog
		'tools/b.v': prog
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	ids := g.symbols.map(it.id)
	assert 'tools.main@tools/a.v' in ids
	assert 'tools.main@tools/b.v' in ids
	assert 'tools.helper@tools/a.v' in ids
	assert g.edges.any(it.kind == .calls && it.from == 'tools.main@tools/a.v'
		&& it.to == 'tools.helper@tools/a.v')
	assert g.edges.any(it.kind == .calls && it.from == 'tools.main@tools/b.v'
		&& it.to == 'tools.helper@tools/b.v')
	assert g.symbols.filter(it.kind == .mod_).all(it.signature == 'module main')
}

fn test_imports_and_builtin_reach_directory_module_ids() {
	// `import util` names the module whose id is `lib.util`, and builtin is
	// visible everywhere; a same-named declaration elsewhere is not visible.
	// Before visible_from, both rules compared directory ids such as
	// `lib.util` with import paths such as `util` and never matched.
	root := write_tree('import_reach', {
		'lib/util/util.v':       'module util

pub struct Conf {}
'
		'lib/other/other.v':     'module other

pub struct Conf {}

pub fn everywhere() {}
'
		'lib/builtin/builtin.v': 'module builtin

pub fn everywhere() {}
'
		'app/app.v':             'module app

import util

fn run(c util.Conf) {
	everywhere()
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .references && it.from == 'app.run' && it.to == 'lib.util.Conf')
	assert g.edges.any(it.kind == .calls && it.from == 'app.run'
		&& it.to == 'lib.builtin.everywhere')
}

fn test_field_and_const_get_their_own_id_beside_a_same_named_method_or_fn() {
	src := 'module demo

const answer = 42

fn answer() int {
	return answer
}

struct Server {
	username string
}

fn (s Server) username() string {
	return s.username
}

fn use(s Server) string {
	_ = answer()
	return s.username()
}
'
	root := write_tree('member_ids', {
		'demo/demo.v': src
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	mut count := map[string]int{}
	for s in g.symbols {
		count[s.id]++
	}
	assert count.keys().all(count[it] == 1)
	by_id := maps_by_id(g.symbols)
	assert by_id['demo.Server.username'].kind == .method
	assert by_id['demo.Server::field::username'].kind == .field
	assert by_id['demo.answer'].kind == .function
	assert by_id['demo::const::answer'].kind == .constant
	assert g.edges.any(it.kind == .defines && it.from == 'demo.Server'
		&& it.to == 'demo.Server::field::username')
	assert g.edges.any(it.kind == .defines && it.from == 'demo' && it.to == 'demo::const::answer')
	assert g.edges.any(it.kind == .calls && it.from == 'demo.use' && it.to == 'demo.Server.username')
}
