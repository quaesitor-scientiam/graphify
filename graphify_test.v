module graphify

import os
import time
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
	// the binding is a symbol of its own, under the C namespace, so the two ids differ
	mut ids := fns.map(it.id)
	ids.sort()
	assert ids == ['C.get_string_array', 'demo.get_string_array'], ids.str()
	assert fns.filter(it.id == 'demo.get_string_array')[0].name == 'get_string_array'
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
	// every branch is kept, whichever host extracts
	for id in ['demo.picked_a', 'demo.picked_b', 'demo.PickedA', 'demo.PickedB', 'demo.nested_a',
		'demo.nested_b'] {
		assert id in ids, id
	}
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

fn test_a_static_member_of_a_js_binding_is_a_call_into_the_host() {
	// `JS.Promise.race` and `JS.Array.prototype.constructor()` are calls into the JS host,
	// as `JS.parseInt` is, so the full path is the callee and not its last name
	root := write_tree('js_static_calls', {
		'demo.v': 'module demo\n\npub fn make() {\n\t_ = JS.Array.prototype.constructor()\n\t_ = JS.Promise.race(1)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.make').map(it.to)
	assert 'JS.Array.prototype.constructor' in targets, targets.str()
	assert 'JS.Promise.race' in targets, targets.str()
	assert 'constructor' !in targets && 'race' !in targets, targets.str()
}

fn test_a_method_of_a_js_binding_type_is_a_call_into_the_host() {
	// `promise` is a `JS.Promise`, a type of the binding, which the program declares no `then`
	// on. The `then` of `Other` is no method of it, though a call matched by name alone would
	// take it
	root := write_tree('js_method_calls', {
		'demo.v': 'module demo\n\npub struct Waiter {\npub mut:\n\tpromise JS.Promise\n}\n\npub fn (w Waiter) run() {\n\tw.promise.then(1, 2)\n}\n\npub struct Other {\n}\n\npub fn (o Other) then(a int, b int) {\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Waiter.run').map(it.to)
	assert 'JS.Promise.then' in targets, targets.str()
	assert 'demo.Other.then' !in targets, targets.str()
}

fn test_a_method_of_a_js_binding_type_that_a_v_wrapper_declares_links_to_the_wrapper() {
	// `g` is a `JS.WebGLRenderingContext`, and the program's own `WebGLRenderingContext`
	// declares clear(), a wrapper of the host's. The call links to that declaration, and is
	// not a call into the host
	root := write_tree('js_wrapped_method_calls', {
		'demo.v': 'module demo\n\npub struct WebGLRenderingContext {\n}\n\npub fn (g WebGLRenderingContext) clear() {\n}\n\npub fn run(g JS.WebGLRenderingContext) {\n\tg.clear()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.run').map(it.to)
	assert 'demo.WebGLRenderingContext.clear' in targets, targets.str()
	assert 'JS.WebGLRenderingContext.clear' !in targets, targets.str()
}

fn test_a_function_typed_parameter_takes_the_type_its_function_returns() {
	// `new_hmac[D]` calls its `h fn () D`, and the function it is passed returns a Digest, so D
	// is a Digest and the call reaches Digest.block_size(). Other has one too, which a call
	// matched by name alone could take
	root := write_tree('function_typed_parameter', {
		'demo.v': 'module demo\n\npub struct Digest {\n}\n\npub fn (d &Digest) block_size() int {\n\treturn 64\n}\n\npub struct Other {\n}\n\npub fn (o &Other) block_size() int {\n\treturn 1\n}\n\npub fn new_digest() &Digest {\n\treturn &Digest{}\n}\n\npub fn new_hmac[D](h fn () D) int {\n\tdigest := h()\n\treturn digest.block_size()\n}\n\npub fn run() int {\n\treturn new_hmac(new_digest)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.new_hmac').map(it.to)
	assert 'demo.Digest.block_size' in targets, targets.str()
	assert 'demo.Other.block_size' !in targets, targets.str()
}

fn test_a_function_named_through_an_import_takes_its_return_type() {
	// `sha1.new` is named through `import crypto.sha1`, and the module of a file under vlib is
	// `vlib.crypto.sha1`, so the function is found under that id. md5 has a block_size() too, which
	// a call matched by name alone could take
	root := write_tree('function_through_import', {
		'vlib/crypto/sha1/sha1.v': 'module sha1\n\npub struct Digest {\n}\n\npub fn (d &Digest) block_size() int {\n\treturn 64\n}\n\npub fn new() &Digest {\n\treturn &Digest{}\n}\n'
		'vlib/crypto/md5/md5.v':   'module md5\n\npub struct Digest {\n}\n\npub fn (d &Digest) block_size() int {\n\treturn 1\n}\n'
		'vlib/crypto/hmac/hmac.v': 'module hmac\n\npub fn new_hmac[D](h fn () D) int {\n\tdigest := h()\n\treturn digest.block_size()\n}\n'
		'demo/demo.v':             'module demo\n\nimport crypto.hmac\nimport crypto.sha1\n\npub fn run() int {\n\treturn hmac.new_hmac(sha1.new)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.crypto.hmac.new_hmac').map(it.to)
	assert 'vlib.crypto.sha1.Digest.block_size' in targets, targets.str()
	assert 'vlib.crypto.md5.Digest.block_size' !in targets, targets.str()
}

fn test_a_method_on_a_field_of_a_generic_struct_takes_the_instance_the_struct_has() {
	// `reset` calls block_size() on the field `work`, of type D. The `Hmac[D]` that new_hmac builds
	// is instantiated with the Digest its function returns, so reset() reaches Digest's method
	root := write_tree('generic_struct_field_owner', {
		'demo.v': 'module demo\n\npub struct Digest {\n}\n\npub fn (d &Digest) block_size() int {\n\treturn 64\n}\n\npub struct Other {\n}\n\npub fn (o &Other) block_size() int {\n\treturn 1\n}\n\npub fn new_digest() &Digest {\n\treturn &Digest{}\n}\n\npub struct Hmac[D] {\n\twork D\n}\n\npub fn (m &Hmac[D]) reset() int {\n\treturn m.work.block_size()\n}\n\npub fn new_hmac[D](h fn () D) int {\n\tm := &Hmac[D]{\n\t\twork: h()\n\t}\n\treturn m.work.block_size()\n}\n\npub fn run() int {\n\treturn new_hmac(new_digest)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Hmac[D].reset').map(it.to)
	assert 'demo.Digest.block_size' in targets, targets.str()
	assert 'demo.Other.block_size' !in targets, targets.str()
}

fn test_a_method_on_a_field_of_a_type_parameter_takes_the_field_of_each_instance() {
	// `handle` calls touch() on the `req` field of its `ctx T`, and T is the Context that run()
	// passes. Other has a touch() too, which a call matched by name alone could take
	root := write_tree('field_of_type_parameter', {
		'demo.v': 'module demo\n\npub struct Request {\npub mut:\n\tdata string\n}\n\npub fn (r Request) touch() int {\n\treturn 1\n}\n\npub struct Other {\n}\n\npub fn (o Other) touch() int {\n\treturn 2\n}\n\npub struct Context {\npub mut:\n\treq Request\n}\n\npub fn handle[T](ctx T) int {\n\treturn ctx.req.touch()\n}\n\npub fn run(c Context) int {\n\treturn handle(c)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.handle').map(it.to)
	assert 'demo.Request.touch' in targets, targets.str()
	assert 'demo.Other.touch' !in targets, targets.str()
}

fn test_a_method_on_a_field_of_a_type_parameter_takes_the_explicit_type_argument() {
	// `make[Context]()` names T, so the closure's ctx is a Context, and its req field's touch() is
	// Request's, not Other's
	root := write_tree('explicit_type_argument', {
		'demo.v': 'module demo\n\npub struct Request {\npub mut:\n\tdata string\n}\n\npub fn (r Request) touch() int {\n\treturn 1\n}\n\npub struct Other {\n}\n\npub fn (o Other) touch() int {\n\treturn 2\n}\n\npub struct Context {\npub mut:\n\treq Request\n}\n\npub fn make[T]() fn (T) int {\n\treturn fn [T](ctx T) int {\n\t\treturn ctx.req.touch()\n\t}\n}\n\npub fn run() int {\n\tf := make[Context]()\n\treturn f(Context{})\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.make').map(it.to)
	assert 'demo.Request.touch' in targets, targets.str()
	assert 'demo.Other.touch' !in targets, targets.str()
}

fn test_an_explicit_type_argument_of_a_module_struct_finds_the_fields_of_its_embedded_struct() {
	// `Context` in the tests module embeds veb2's Context, and decode[Context]() names it through
	// that module, so the instance's name is qualified there: its req field is found all the same
	root := write_tree('explicit_type_argument_embedded', {
		'vlib/veb2/veb2.v':        'module veb2\n\npub struct Request {\npub mut:\n\tdata string\n}\n\npub fn (r Request) touch() int {\n\treturn 1\n}\n\npub struct Other {\n}\n\npub fn (o Other) touch() int {\n\treturn 2\n}\n\npub struct Context {\npub mut:\n\treq Request\n}\n\npub fn decode[T]() fn (mut T) int {\n\treturn fn [T](mut ctx T) int {\n\t\treturn ctx.req.touch()\n\t}\n}\n'
		'vlib/veb2/tests/tests.v': 'module tests\n\nimport veb2\n\npub struct Context {\n\tveb2.Context\npub mut:\n\tcounter int\n}\n\npub fn run() int {\n\tf := veb2.decode[Context]()\n\tmut c := Context{}\n\treturn f(mut c)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb2.decode').map(it.to)
	assert 'vlib.veb2.Request.touch' in targets, targets.str()
	assert 'vlib.veb2.Other.touch' !in targets, targets.str()
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
	assert assert_body_ends_at_own_brace(g, src, ['win_last', 'other_last']) == 2
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
	assert assert_body_ends_at_own_brace(g, src, ['deep_a', 'deep_b', 'deep_c', 'deep_d']) == 4
	assert assert_body_ends_at_own_brace(g, src, ['mid_a', 'mid_b']) == 2
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

// drill_views_plausible is the relationship between the drill-views a run
// rendered and the communities that qualified for one (>= drill_min_members
// members) that must hold for ANY Louvain run. compute_drill_views looks at
// the largest drill_max_candidates qualifying communities, so those are the
// candidates: it can never render more views than candidates, and a candidate
// only goes without a view when it fails the "really has >= 2 sub-communities"
// gate and is skipped without being backfilled -- allow a little slack for
// that rather than assert a count the code does not guarantee. How many
// communities qualify is not fixed: Louvain's shuffled visitation order (see
// communities.v) makes it vary run to run (9 to 22 for the 400-clique ring
// below over 150 local runs, and a macOS CI run rendered only 6 views), so a
// bound written in terms of the cap alone fails on correct runs.
fn drill_views_plausible(views int, qualifying int) bool {
	candidates := if qualifying < drill_max_candidates { qualifying } else { drill_max_candidates }
	return views <= candidates && views >= candidates - 3
}

fn test_drill_view_count_is_bounded_by_the_candidates_not_by_the_cap() {
	assert drill_views_plausible(10, 14) // more qualified than the cap: all ten candidates drilled
	assert drill_views_plausible(10, 10)
	assert drill_views_plausible(9, 9) // fewer qualified than the cap: one view each
	assert drill_views_plausible(6, 6) // a run where only six communities reach 30 members
	assert drill_views_plausible(8, 10) // two candidates skipped as unsplittable: within slack
	assert drill_views_plausible(7, 14)
	assert !drill_views_plausible(5, 10) // half the candidates dropped is not slack
	assert !drill_views_plausible(11, 14) // the cap exceeded
	assert !drill_views_plausible(7, 6) // more views than candidates
}

fn test_emit_graph_html_drill_views_capped_marked_and_disclosed() {
	// One graph, computed once, checked for all of: some communities are
	// large enough to be marked drillable and some are not (the size gate
	// actually filters something, not everything); the number of emitted
	// drill-views never exceeds drill_max_candidates; and whenever more
	// communities qualify than get a view, the "N of M" truncation
	// disclosure is present, not silent.
	g := ring_of_cliques_graph(400, 5)
	out := g.emit_graph_html()

	views := out.count('class="drill-view"')
	badges := out.count('class="drill-badge-legend"')
	legend_items := out.count('class="legend-item"')

	// Recover the actual qualifying count the same way compute_drill_views
	// did, from the legend's own per-community sizes (legend and drill views
	// are built from the same `comms` slice inside emit_graph_html, and
	// layout_ring always keeps at least one member per community, so every
	// qualifying community is guaranteed a legend entry to count here).
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

	assert views > 0 // this ring reliably produces qualifying, splittable communities
	assert views <= drill_max_candidates // the cap is a hard ceiling, never exceeded
	assert drill_views_plausible(views, qualifying), 'views=${views} qualifying=${qualifying}'
	assert views == badges // every drill-view has exactly one matching legend badge
	assert legend_items > badges // not every community qualified -- the size gate filtered some out

	// The "N of M" disclosure only appears when compute_drill_views actually
	// dropped a qualifying (>= drill_min_members) community -- to the
	// drill_max_candidates cap, or to the "not really splittable" gate --
	// never unconditionally. So it is expected exactly when qualifying > views.
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

// A file with a syntax error in the middle: the unclosed array literal on
// line 8.
const partial_parse_src = 'module demo

fn before() int {
	return 1
}

fn broken() []int {
	x := [1, 2
	return x
}

fn after() int {
	return 2
}
'

fn test_a_file_of_only_comments_has_no_parse_error() {
	for src in ['', '\n', '/*\nmodule demo\n*/\n', '// note\n/* a /* nested */ one */\n'] {
		fr := extract_v_text_result(src, 'demo.v')
		assert fr.parse_error == '', src
		assert fr.symbols.len == 0
	}
	// an unclosed comment is no file V builds
	assert extract_v_text_result('/* open\nmodule demo\n', 'demo.v').parse_error != ''
}

fn test_extract_clean_file_has_no_parse_error() {
	fr := extract_v_text_result('module demo\n\nfn ok() int {\n\treturn 1\n}\n', 'demo.v')
	assert fr.parse_error == ''
	assert fr.symbols.map(it.name).contains('ok')
}

fn test_a_method_in_both_branches_of_a_top_level_comptime_if_is_no_parse_error() {
	src := 'module demo\n\nstruct B {}\n\n\$if darwin {\n\tfn (b B) ready() bool {\n\t\treturn true\n\t}\n} \$else \$if windows {\n\tfn (b B) ready() bool {\n\t\treturn true\n\t}\n} \$else {\n\tfn (b B) ready() bool {\n\t\treturn false\n\t}\n}\n'
	fr := extract_v_text_result(src, 'demo.v')
	assert fr.parse_error == ''
	assert fr.symbols.filter(it.name == 'ready').map(it.line) == [6, 10, 14]
	// two `$if`s on a condition and on its negation, as in vlib/x/multiwindow
	negated := 'module demo\n\nstruct B {}\n\n\$if gui ? {\n\t\$if d3d ? {\n\t\tfn (b B) env() int {\n\t\t\treturn 1\n\t\t}\n\t}\n\t\$if !d3d ? {\n\t\tfn (b B) env() int {\n\t\t\treturn 2\n\t\t}\n\t}\n}\n'
	assert extract_v_text_result(negated, 'demo.v').parse_error == ''
	// a method declared twice in one branch, or outside any, is still reported
	twice := 'module demo\n\nstruct B {}\n\n\$if darwin {\n\tfn (b B) ready() bool {\n\t\treturn true\n\t}\n\tfn (b B) ready() bool {\n\t\treturn true\n\t}\n} \$else {\n\tfn (b B) ready() bool {\n\t\treturn false\n\t}\n}\n'
	assert extract_v_text_result(twice, 'demo.v').parse_error.contains('duplicate method `ready`')
	same := 'module demo\n\nstruct B {}\n\n\$if d3d ? {\n\tfn (b B) env() int {\n\t\treturn 1\n\t}\n}\n\$if d3d ? {\n\tfn (b B) env() int {\n\t\treturn 2\n\t}\n}\n'
	assert extract_v_text_result(same, 'demo.v').parse_error.contains('duplicate method `env`')
	plain := 'module demo\n\nstruct B {}\n\nfn (b B) ready() bool {\n\treturn true\n}\n\$if darwin {\n\tfn (b B) ready() bool {\n\t\treturn false\n\t}\n}\n'
	assert extract_v_text_result(plain, 'demo.v').parse_error.contains('duplicate method `ready`')
}

fn test_file_result_parse_error_round_trips_through_the_batch_protocol() {
	fr := extract_v_text_result(partial_parse_src, 'demo.v')
	assert fr.parse_error != ''
	back := decode_file_result(encode_file_result(fr))
	assert back.parse_error == fr.parse_error
	assert back.symbols.len == fr.symbols.len
	clean := decode_file_result(encode_file_result(FileResult{}))
	assert clean.parse_error == ''
}

fn test_edge_round_trips_every_field_and_decodes_the_5_field_form() {
	fr := FileResult{
		edges: [
			Edge{
				from:      'demo.Foo.bar'
				to:        'baz'
				kind:      .calls
				is_method: true
				recv_type: 'demo.Foo'
				file:      'sub/demo.v'
			},
		]
	}
	back := decode_file_result(encode_file_result(fr))
	assert back.edges.len == 1
	assert back.edges[0].from == 'demo.Foo.bar'
	assert back.edges[0].to == 'baz'
	assert back.edges[0].kind == .calls
	assert back.edges[0].is_method
	assert back.edges[0].recv_type == 'demo.Foo'
	assert back.edges[0].file == 'sub/demo.v'
	// the older 5-field edge form still decodes, with no file
	legacy := decode_file_result('${bp_ss}demo.a${bp_fs}b${bp_fs}${int(EdgeKind.calls)}${bp_fs}1${bp_fs}demo.T${bp_ss}')
	assert legacy.edges.len == 1
	assert legacy.edges[0].recv_type == 'demo.T'
	assert legacy.edges[0].file == ''
}

fn test_disambiguated_caller_keeps_its_file_through_the_batch_protocol() {
	// build_graph_resilient only ever sees a worker's FileResult after an
	// encode/decode round trip (and a cached one after another) -- if
	// Edge.file were dropped there, disambiguate_ids would rename the caller
	// to `main.main@`, an id matching no symbol.
	src := 'module main\n\nfn helper() {}\n\nfn main() {\n\thelper()\n}\n'
	mut g := Graph{}
	for rel in ['a.v', 'b.v'] {
		fr := decode_file_result(encode_file_result(extract_v_text_result(src, rel)))
		g.symbols << fr.symbols
		g.edges << fr.edges
	}
	disambiguate_ids(mut g)
	for e in g.edges.filter(it.kind == .calls) {
		assert e.file != ''
		assert e.from.ends_with('@${e.file}'), e.from
	}
	resolve_edges(mut g)
	ids := g.symbols.map(it.id)
	calls := g.edges.filter(it.kind == .calls)
	assert calls.len == 2
	for e in calls {
		assert e.from in ids, e.from
	}
	assert calls.map(it.from).sorted() == ['main.main@a.v', 'main.main@b.v']
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

fn test_module_qualified_calls_resolve_through_the_import() {
	// The parser reports `os.join_path(...)` as the raw name `os.join_path`,
	// and an aliased `json.decode()` with the alias already expanded to the
	// import path (`x.json2.decode`). A same-named function in an unrelated
	// module keeps the bare name from being unique on its own.
	root := write_tree('qualified_calls', {
		'lib/os/os.v':       'module os

pub fn join_path() {}
'
		'lib/x/json2/j.v':   'module json2

pub fn decode() {}
'
		'lib/decoy/decoy.v': 'module decoy

pub fn join_path() {}

pub fn decode() {}
'
		'app/app.v':         'module app

import os
import x.json2 as json

fn run() {
	os.join_path()
	json.decode()
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .calls && it.from == 'app.run' && it.to == 'lib.os.join_path')
	assert g.edges.any(it.kind == .calls && it.from == 'app.run' && it.to == 'lib.x.json2.decode')
}

fn test_module_qualified_calls_trust_only_one_module() {
	// `import rand` reaches both `lib.rand` and `lib.crypto.rand`, so
	// `rand.int` is left alone. And the parser prefixes an unqualified call
	// with the *current* module's declared name, even `shared()` after
	// `import util { shared }`, which comes out as `app.shared`: that prefix
	// means module `cmd.app` itself, so a call to the keyword-named `@select`
	// (which the parser also prefixes, as with `net.select` in vlib) resolves there,
	// but `shared` -- declared in no module of that id -- must not be pinned
	// on another module that merely ends in `app`.
	root := write_tree('qualified_unsure', {
		'lib/rand/rand.v':         'module rand

pub fn int() {}
'
		'lib/crypto/rand/rand.v':  'module rand

pub fn int() {}
'
		'lib/util/util.v':         'module util

pub fn shared() {}

pub fn @select() {}
'
		'lib/elsewhere/app/app.v': 'module app

pub fn shared() {}
'
		'cmd/app/app.v':           'module app

import rand
import util { shared }

fn run() {
	rand.int()
	shared()
	select()
}

fn @select() {}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	calls := g.edges.filter(it.kind == .calls && it.from == 'cmd.app.run')
	assert calls.len == 3
	assert calls.any(it.to == 'rand.int')
	// a selectively imported function is named by its module
	assert calls.any(it.to == 'lib.util.shared')
	assert calls.any(it.to == 'cmd.app.select')
}

fn test_struct_and_interface_embeds_become_embeds_edges() {
	// An embedded struct or interface becomes an `embeds` edge. The decoy
	// `Base` in another module checks that each edge resolves to the
	// declaration in the embedding type's own module.
	root := write_tree('embeds', {
		'demo/demo.v':   'module demo

struct Base {
	id int
}

struct Derived {
	Base
	name string
}

interface Reader {
	read() int
}

interface ReadCloser {
	Reader
	close()
}
'
		'demo/gen.v':    'module demo

struct Middleware[T] {
	ctx T
}

struct App {
	Middleware[Base]
}
'
		'other/other.v': 'module other

pub struct Base {}

pub struct Middleware[T] {}

pub interface Reader {
	read() int
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .embeds && it.from == 'demo.Derived' && it.to == 'demo.Base')
	assert g.edges.any(it.kind == .embeds && it.from == 'demo.ReadCloser'
		&& it.to == 'demo.Reader')
	// a generic embed is named by its base type, not lost to the brackets
	assert g.edges.any(it.kind == .embeds && it.from == 'demo.App' && it.to == 'demo.Middleware')
	// the embedded type is not also a field symbol
	assert !g.symbols.any(it.kind == .field && it.parent == 'demo.Derived' && it.name == 'Base')
	assert g.symbols.any(it.kind == .field && it.id == 'demo.Derived.name')
}

fn test_strip_generic_args() {
	assert strip_generic_args('veb.Middleware[Context]') == 'veb.Middleware'
	assert strip_generic_args('[]Foo[T]') == '[]Foo'
	assert strip_generic_args('map[string]Foo[map[int]T]') == 'map[string]Foo'
	assert strip_generic_args('[4]int') == '[4]int'
	assert strip_generic_args('&Pair[K, V]') == '&Pair'
}

fn test_type_declarations_are_symbols_and_resolve_references() {
	// `type` declarations (alias, sum type, fn type) were never extracted, so
	// every reference to one, `NodeId` in vlib/v/flat above all, stayed
	// unresolved. A generic parameter such as `T` names no declaration and
	// is not emitted as a reference at all.
	src := 'module demo

pub type NodeId = i32

struct Leaf {}

struct Branch {}

type Tree = Branch | Leaf

type Visit = fn (id NodeId) bool

fn walk[T](t Tree, start NodeId, v Visit, extra T) {}
'
	root := write_tree('type_decls', {
		'demo/demo.v': src
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	by_id := maps_by_id(g.symbols)
	assert by_id['demo.NodeId'].kind == .type_alias
	assert by_id['demo.NodeId'].signature == 'pub type NodeId = i32'
	assert by_id['demo.Tree'].signature == 'type Tree = Branch | Leaf'
	assert by_id['demo.Visit'].kind == .type_alias
	assert g.edges.any(it.kind == .defines && it.from == 'demo' && it.to == 'demo.Tree')
	assert g.edges.any(it.kind == .references && it.from == 'demo.Tree' && it.to == 'demo.Leaf')
	assert g.edges.any(it.kind == .references && it.from == 'demo.Visit' && it.to == 'demo.NodeId')
	for want in ['demo.Tree', 'demo.NodeId', 'demo.Visit'] {
		assert g.edges.any(it.kind == .references && it.from == 'demo.walk' && it.to == want), want
	}
	assert !g.edges.any(it.kind == .references && it.to == 'T')
}

fn test_test_file_declarations_are_not_visible_to_other_files() {
	// vlib/builtin/map_test.v declares `enum Color`; treating it as part of
	// builtin made it visible everywhere and won `Color` over the real one.
	root := write_tree('test_private', {
		'lib/builtin/map_test.v': 'module builtin

enum Color {
	red
}

fn test_color() {
	_ = Color.red
}
'
		'lib/color/color.v':      'module color

pub type Color = int
'
		'app/app.v':              'module app

import color

fn paint(c color.Color) {}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .references && it.from == 'app.paint' && it.to == 'lib.color.Color')
}

fn test_explain_caps_each_relation_list() {
	// A symbol referenced by thousands of declarations used to produce one
	// unbounded line; an MCP client rejects a result that large.
	mut g := Graph{}
	g.symbols << Symbol{
		id:   'demo.Hub'
		name: 'Hub'
		kind: .struct_
		file: 'demo.v'
		line: 1
	}
	for i in 0 .. explain_list_cap + 25 {
		g.symbols << Symbol{
			id:   'demo.user${i}'
			name: 'user${i}'
			kind: .function
			file: 'demo.v'
			line: i + 2
		}
		g.edges << Edge{
			from: 'demo.user${i}'
			to:   'demo.Hub'
			kind: .references
		}
	}
	out := g.explain('demo.Hub')
	line := out.split('\n').filter(it.starts_with('referenced by'))[0]
	assert line.count('user') == explain_list_cap
	assert line.ends_with('… (+25 more)')
	assert capped(['a', 'b', 'a']) == 'a, b'
}

fn test_report_counts_builtin_type_references_apart_from_unresolved() {
	mut g := Graph{}
	g.symbols << Symbol{
		id:   'demo.f'
		name: 'f'
		kind: .function
		file: 'demo.v'
	}
	for to in ['int', 'bool', 'Mystery'] {
		g.edges << Edge{
			from: 'demo.f'
			to:   to
			kind: .references
		}
	}
	// a call to an unknown `int` is not a type reference
	for to in ['int', 'C.memcpy', 'JS.parseInt'] {
		g.edges << Edge{
			from: 'demo.f'
			to:   to
			kind: .calls
		}
	}
	r := g.report()
	assert r.contains('- references: extracted 0, inferred 0, built-in 2, unresolved 1')
	assert r.contains('- calls: extracted 0, inferred 0, external 2, unresolved 1')
}

fn test_report_counts_v3_primitives_and_undeclared_host_types_apart_from_unresolved() {
	// V3 has 128-bit integers, which no file declares, and a `C.` or `JS.` type
	// that nothing in the program declares (resolve_edges marks it undeclared) is
	// in a system header or the JS host
	mut g := Graph{}
	g.symbols << Symbol{
		id:   'demo.f'
		name: 'f'
		kind: .function
		file: 'demo.v'
	}
	for to in ['u128', 'i128', 'C.Cursor', 'JS.EveryFn', 'C.timespec', 'Mystery'] {
		g.edges << Edge{
			from:       'demo.f'
			to:         to
			kind:       .references
			provenance: if to in ['C.Cursor', 'JS.EveryFn'] { .undeclared } else { .extracted }
		}
	}
	// `C.timespec` stands for one declared several times that doesn't resolve
	r := g.report()
	assert r.contains('- references: extracted 0, inferred 0, built-in 2, external 2, unresolved 2'), r
}

fn test_a_c_or_js_type_reference_names_only_a_c_or_js_declaration() {
	// A reference keeps the `C.` or `JS.` it is written with, and names the nearest C
	// or JS declaration of that name. It was recorded without it, so `C.Cursor` went
	// to the one V struct named Cursor, `JS.Number` to the V struct Number in the
	// referencing module, and the bare `Window` was ambiguous with `C.Window`. A V
	// type of the same name is not the C or JS one, `EveryFn` for `JS.EveryFn` too:
	// with no such declaration, the reference keeps its name and is external.
	g := graph_of({
		'vlib/x11/x11.c.v':          'module x11

pub type C.XID = u64

pub type C.Window = C.XID

pub type Window = C.Window

pub struct C.XEvent {
	typ int
}

pub struct Display {
	win    C.Window
	root   Window
	ev     C.XEvent
	cursor C.Cursor
}
'
		'vlib/ui/ui.v':              'module ui

pub struct Cursor {
	x int
}
'
		'vlib/builtin/js/jsfns.js.v': 'module builtin

pub interface JS.Number {}
'
		'vlib/js/dom/number.v':      'module dom

pub struct Number {
	n int
}
'
		'vlib/js/dom/dom.js.v':      'module dom

type EveryFn = fn (JS.Number) bool

pub interface JS.Point {
	x JS.Number
	every(JS.EveryFn) bool
}
'
	})
	display := g.edges.filter(it.kind == .references && it.from == 'vlib.x11.Display').map(it.to)
	assert display == ['C.Window', 'vlib.x11.Window', 'vlib.x11.C.XEvent', 'C.Cursor'], display.str()
	window := g.edges.filter(it.kind == .references && it.from == 'vlib.x11.Window').map(it.to)
	assert window == ['C.Window'], window.str()
	point := g.edges.filter(it.kind == .references && it.from.starts_with('vlib.js.dom.Point')).map(it.to)
	assert 'vlib.builtin.js.Number' in point && 'JS.EveryFn' in point, point.str()
	assert !g.edges.any(it.kind == .references
		&& it.to in ['vlib.ui.Cursor', 'vlib.js.dom.Number', 'vlib.js.dom.EveryFn'])
	r := g.report()
	assert r.contains('- references: extracted '), r
	assert r.contains(', external 2, '), r
}

fn test_a_sum_type_references_the_struct_of_each_named_variant() {
	// V3 declares each variant of `type Expr = IntLit(int) | Void` as a hidden
	// struct, `Expr@variant@IntLit { payload int }` and `Expr@variant@Void {}`, and
	// the sum type holds those structs. Its reference kept only the variant's name,
	// `IntLit`, which nothing declares, or named another type: the alias `Void`
	// beside it, the `Nil` struct of another module, the `Count` an import selects.
	// A variant is written `Expr.Count`, never by its name alone, so no type of
	// that name is it; the variant's struct references its payload's type.
	g := graph_of({
		'lib/expr.v':    'module lib

import other { Count }

struct Point {
	x int
}

type Void = int

type Expr = IntLit(int) | Count(string) | Pt(Point) | Void | Nil

pub type Opt[T] = Some(T) | Nothing
'
		'other/other.v': 'module other

pub struct Count {}

pub struct Nil {}
'
	})
	syms := maps_by_id(g.symbols)
	assert syms['lib.Expr'].signature == 'type Expr = Expr@variant@IntLit | Expr@variant@Count | Expr@variant@Pt | Expr@variant@Void | Expr@variant@Nil'
	expr := g.edges.filter(it.kind == .references && it.from == 'lib.Expr').map(it.to)
	assert expr == ['lib.Expr@variant@IntLit', 'lib.Expr@variant@Count', 'lib.Expr@variant@Pt',
		'lib.Expr@variant@Void', 'lib.Expr@variant@Nil'], expr.str()
	opt := g.edges.filter(it.kind == .references && it.from == 'lib.Opt').map(it.to)
	assert opt == ['lib.Opt@variant@Some', 'lib.Opt@variant@Nothing'], opt.str()
	pt := g.edges.filter(it.kind == .references && it.from == 'lib.Expr@variant@Pt').map(it.to)
	assert pt == ['lib.Point'], pt.str()
	assert !g.edges.any(it.kind == .references && it.to in ['lib.Void', 'other.Count', 'other.Nil'])
}

// two_strings are builtin's `string` and the JS builtin's in vlib/builtin/js, as V's
// tree has them, so a bare `string` never resolves by its name alone
const two_strings = {
	'vlib/builtin/string.v':       'module builtin

pub struct string {
	len int
}
'
	'vlib/builtin/js/string.js.v': 'module builtin

pub struct string {
	str int
}
'
}

// built_graph_of is graph_of with the steps build_graph takes in between: ids
// declared more than once in a build unit are told apart before edges resolve
fn built_graph_of(files map[string]string) Graph {
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	resolve_edges(mut g)
	return g
}

fn refs_of(g Graph, from string) []string {
	return g.edges.filter(it.kind == .references && it.from == from).map(it.to)
}

fn test_a_variadic_c_or_js_type_keeps_its_qualifier() {
	// `...JS.Any` left its dots on the qualifier, so the reference was recorded as the
	// bare `Any` and matched V types of that name
	g := graph_of({
		'vlib/builtin/js/jsfns.js.v': 'module builtin

pub interface JS.Any {}
'
		'vlib/json2/types.v':         'module json2

pub type Any = int | string
'
		'vlib/js/dom/dom.js.v':       'module dom

pub interface JS.ChildNode {
	after(nodes ...JS.Any)
}
'
	})
	refs := refs_of(g, 'vlib.js.dom.ChildNode.after')
	assert refs == ['vlib.builtin.js.Any'], refs.str()
}

fn test_a_type_in_a_module_main_directory_with_no_main_is_seen_by_its_files() {
	// `v test` builds a `module main` directory with no `fn main` together, so the
	// `Country` in country.v is the one country_cases.v names, as for an alias
	// conversion. A test file's own types stay its own.
	g := graph_of({
		'vlib/v/tests/generic_calls/country.v':       'module main

pub enum Country {
	us
	fr
}
'
		'vlib/v/tests/generic_calls/country_cases.v': 'module main

pub fn Country.cases() []Country {
	return []Country{}
}
'
		'vlib/v/tests/structs/struct_test.v':         'module main

struct Country {
	name string
}

fn test_country() {}
'
	})
	refs := refs_of(g, 'vlib.v.tests.generic_calls.Country__static__cases')
	assert refs == ['vlib.v.tests.generic_calls.Country'], refs.str()
}

fn test_a_test_in_a_module_main_directory_with_no_main_calls_its_siblings() {
	// V builds a `module main` test with the `module main` files of its directory
	// (expand_single_test_file_inputs in V's driver), so `validate` in
	// vlib/wasm/tests/common.v is the one every test there calls. Another test's
	// function stays its own, and a program's file, which is no test, doesn't see a
	// sibling program's.
	g := graph_of({
		'vlib/wasm/tests/common.v':      'module main\n\nstruct Box {}\n\nfn (b Box) open() {}\n\nstruct Jar {}\n\nfn (j Jar) open() {}\n\nconst limit = Box{}\n\n__global hook fn ()\n\npub fn validate(code []u8) ! {}\n'
		'vlib/wasm/tests/arith_test.v':  'module main\n\nfn test_add() {\n\tvalidate([]u8{}) or {}\n\tlimit.open()\n\tonly_in_block()\n\thook()\n}\n'
		'vlib/wasm/tests/block_test.v':  'module main\n\nfn only_in_block() {}\n\nfn test_block() {\n\tvalidate([]u8{}) or {}\n}\n'
		'examples/tools/a.v':            'module main\n\nfn helper() {}\n'
		'examples/tools/b.v':            'module main\n\nfn other() {\n\thelper()\n}\n'
		// the same names elsewhere, so no call resolves by a unique name
		'vlib/x/x.v':                    'module x\n\npub struct Lid {}\n\npub fn (l Lid) open() {}\n\npub fn validate() {}\n\npub fn only_in_block() {}\n\npub fn helper() {}\n\npub fn size() int {\n\treturn 0\n}\n'
		// a test beside another module's files isn't built with them
		'vlib/crypto/md5/md5.v':         'module md5\n\npub fn size() int {\n\treturn 16\n}\n'
		'vlib/crypto/md5/md5_test.v':    'module main\n\nfn test_size() {\n\t_ := size()\n}\n'
	})
	calls := g.edges.filter(it.kind == .calls)
	add := calls.filter(it.from == 'vlib.wasm.tests.test_add').map(it.to)
	assert 'vlib.wasm.tests.validate' in add, add.str()
	// a const of the directory types its receiver too (find_const)
	assert 'vlib.wasm.tests.Box.open' in add, add.str()
	// and a global holding a function there (resolve_const_callee)
	assert 'vlib.wasm.tests.hook' in add, add.str()
	assert 'vlib.wasm.tests.only_in_block' !in add, add.str()
	block := calls.filter(it.from == 'vlib.wasm.tests.test_block').map(it.to)
	assert block == ['vlib.wasm.tests.validate'], block.str()
	other := calls.filter(it.from == 'examples.tools.other').map(it.to)
	assert other == ['helper'], other.str()
	md5 := calls.filter(it.from == 'vlib.crypto.md5.test_size').map(it.to)
	assert md5 == ['size'], md5.str()
}

fn test_a_module_main_test_sees_its_directorys_main_consts_by_their_own_file() {
	// A const's id is shared by every file of its directory that declares it, so
	// whether a test sees it is told by the const's own file: `limit` of vlib/q/a.v
	// (module q) and of vlib/q/helper.v (module main) are one id, and the test is
	// built with helper.v only, so `limit.check()` is Limit's. md5.v's const is of
	// another module, a sibling test's declarations are its own (`b_test.c.v` too),
	// and a program file, which is no test, sees no sibling program's const.
	g := graph_of({
		// helper.v comes first, so the shared ids' site_of entries are a.v's
		'vlib/q/helper.v':        'module main\n\nstruct Limit {}\n\nfn (l Limit) check() {}\n\nconst limit = Limit{}\n\nfn make_b() fn () {\n\treturn fn () {}\n}\n\nconst run = make_b()\n\n\$if windows {\n\tfn plat() {}\n} \$else {\n\tfn plat() {}\n}\n'
		'vlib/q/a.v':             'module q\n\npub struct LimitX {}\n\npub fn (l LimitX) check() {}\n\nfn new_limit() LimitX {\n\treturn LimitX{}\n}\n\nconst limit = new_limit()\n\nfn make_a() fn () {\n\treturn fn () {}\n}\n\nconst run = make_a()\n'
		'vlib/q/q_test.v':        'module main\n\nfn test_q() {\n\tlimit.check()\n\thelper2()\n\trun()\n\tplat()\n}\n'
		'vlib/q/b_test.c.v':      'module main\n\nfn helper2() {}\n\nfn test_b() {}\n'
		'vlib/crypto/md5/md5.v':  'module md5\n\npub struct Key {}\n\npub fn (k Key) check() {}\n\npub const key = Key{}\n'
		'vlib/crypto/md5/md5_test.v': 'module main\n\nfn test_key() {\n\tkey.check()\n}\n'
		'examples/tools/a.v':     'module main\n\nstruct Pot {}\n\nfn (p Pot) check() {}\n\nconst pot = Pot{}\n'
		'examples/tools/b.v':     'module main\n\nfn other() {\n\tpot.check()\n}\n'
		// a test in a directory of several programs is built with none of them
		'examples/multi/a.v':     'module main\n\nstruct Jug {}\n\nfn (j Jug) check() {}\n\nconst jug = Jug{}\n\nfn main() {}\n'
		'examples/multi/b.v':     'module main\n\nfn main() {}\n'
		'examples/multi/m_test.v': 'module main\n\nfn test_m() {\n\tjug.check()\n}\n'
		// a test's own declarations are its own to call, even when they leave a call
		// ambiguous: `x.spin()` on an untyped `x` is not common.v's one `run`
		'vlib/r/common.v':        'module main\n\nstruct Baz {}\n\nfn (b Baz) spin() {}\n'
		'vlib/r/r_test.v':        'module main\n\nstruct Foo {}\n\nstruct Bar {}\n\nfn (f Foo) spin() {}\n\nfn (b Bar) spin() {}\n\nfn test_r() {\n\tx := C.get_thing()\n\tx.spin()\n}\n'
		'vlib/y/y.v':             'module y\n\npub struct Decoy {}\n\npub fn (d Decoy) check() {}\n\npub fn helper2() {}\n\npub fn plat() {}\n'
	})
	calls := g.edges.filter(it.kind == .calls)
	q := calls.filter(it.from == 'vlib.q.test_q').map(it.to)
	assert 'vlib.q.Limit.check' in q, q.str()
	// a const holding a function, called, and a function declared once per build
	// branch, whose id site_of keeps only per file
	assert 'vlib.q.run' in q, q.str()
	assert q.any(it.starts_with('vlib.q.plat')), q.str()
	assert 'vlib.q.LimitX.check' !in q, q.str()
	assert 'helper2' in q, q.str()
	key := calls.filter(it.from == 'vlib.crypto.md5.test_key').map(it.to)
	assert 'vlib.crypto.md5.Key.check' !in key, key.str()
	pot := calls.filter(it.from == 'examples.tools.other').map(it.to)
	assert 'examples.tools.Pot.check' !in pot, pot.str()
	jug := calls.filter(it.from == 'examples.multi.test_m').map(it.to)
	assert 'examples.multi.Jug.check' !in jug, jug.str()
	r := calls.filter(it.from == 'vlib.r.test_r').map(it.to)
	assert 'vlib.r.Baz.spin' !in r, r.str()
}

fn test_a_type_declared_once_per_platform_resolves_its_field_types() {
	// An id declared in two files has no one site, and only a function or method got
	// one per file back, so `string` in a struct declared once per platform had no
	// locality to pick builtin's by (`gg.Config` in gg.c.v and gg.js.v).
	mut files := two_strings.clone()
	files['vlib/fasthttp/fasthttp_linux.v'] = 'module fasthttp

pub struct Server {
	host string
}
'
	files['vlib/fasthttp/fasthttp_windows.v'] = 'module fasthttp

pub struct Server {
	host string
}
'
	g := built_graph_of(files)
	refs := refs_of(g, 'vlib.fasthttp.Server')
	assert refs == ['vlib.builtin.string', 'vlib.builtin.string'], refs.str()
}

fn test_a_bare_type_name_is_the_builtins_when_an_import_ends_like_a_builtin_directory() {
	// `import wasm` reaches vlib/builtin/wasm by its last segment as well as vlib/wasm,
	// so builtin's `string` and the wasm builtin's both looked visible. A bare type
	// name is the caller's module's, or else builtin's, as V reads it.
	mut files := two_strings.clone()
	files['vlib/builtin/wasm/string.v'] = 'module builtin

pub struct string {
	str int
}
'
	files['vlib/wasm/module.v'] = 'module wasm

pub struct Module {}
'
	files['examples/wasm_codegen/main.v'] = 'import wasm

fn save(m wasm.Module, path string) {}

fn main() {}
'
	files['examples/wasm_codegen/add.v'] = 'import wasm

fn main() {}
'
	g := built_graph_of(files)
	refs := refs_of(g, 'examples.wasm_codegen.save')
	assert 'vlib.builtin.string' in refs, refs.str()
}

fn test_a_function_repeated_under_a_top_level_comptime_if_resolves_its_types() {
	// A function declared in each branch of a top-level `$if` repeats one id in one
	// `module main` test file. The repeat made the id unaddressable, which also kept
	// its site from coming back, though every copy is in that one file.
	mut files := two_strings.clone()
	files['vlib/v/tests/comptime/top_test.v'] = "module main

\$if new_1 ? {
	pub fn ret() string {
		return 'a'
	}
} \$else {
	pub fn ret() string {
		return 'b'
	}
}

fn test_main() {
	assert ret() == 'a'
}
"
	g := built_graph_of(files)
	refs := refs_of(g, 'vlib.v.tests.comptime.ret@vlib/v/tests/comptime/top_test.v')
	assert refs.len == 2 && refs.all(it == 'vlib.builtin.string'), refs.str()
}

fn test_a_c_struct_has_an_id_apart_from_a_v_type_of_its_name() {
	// `struct C.Counter` and the alias `type Counter = C.Counter` are two types, but
	// both had the id `vlib.bridge.Counter`, so the alias's reference to `C.Counter`
	// was a loop to itself, and a reference to either named both. The same held for
	// a V type in another file of the module (builtin's `interface IError` and
	// `struct C.IError`). A C struct's id is `<module>.C.<name>`, as the ids of its
	// methods already begin.
	g := graph_of({
		'vlib/bridge/bridge.c.v': 'module bridge

pub struct C.Counter {
	value int
	label Label
}

pub type Counter = C.Counter

pub struct Holder {
	value C.Counter
}

pub fn (c C.Counter) read() int {
	return c.value
}

pub fn (c Counter) read() int {
	return c.value + 100
}

pub fn render(c Counter) string {
	return c.label.show()
}
'
		'vlib/bridge/label.v':    'module bridge

pub struct Label {
	text string
}

pub fn (l Label) show() string {
	return l.text
}

pub struct Badge {}

pub fn (b Badge) show() string {
	return b.str()
}

pub interface Event {
	name() string
}

pub fn handle(e Event) {}
'
		'vlib/bridge/event.c.v':  'module bridge

pub struct C.Event {
	code int
}

fn C.poll_event(e &C.Event) int
'
	})
	c_struct := g.symbols.filter(it.kind == .struct_ && it.name == 'Counter')
	assert c_struct.map(it.id) == ['vlib.bridge.C.Counter'], c_struct.str()
	fields := g.symbols.filter(it.kind == .field && it.name == 'value' && it.file == 'vlib/bridge/bridge.c.v')
	assert fields.map(it.parent) == ['vlib.bridge.C.Counter', 'vlib.bridge.Holder'], fields.str()
	assert g.symbols.filter(it.id == 'vlib.bridge.Counter').map(it.kind) == [SymbolKind.type_alias]
	assert refs_of(g, 'vlib.bridge.Counter') == ['vlib.bridge.C.Counter']
	assert refs_of(g, 'vlib.bridge.Holder') == ['vlib.bridge.C.Counter']
	assert 'vlib.bridge.C.Counter' in refs_of(g, 'vlib.bridge.C.Counter.read')
	assert 'vlib.bridge.Counter' in refs_of(g, 'vlib.bridge.Counter.read')
	assert g.symbols.filter(it.id == 'vlib.bridge.Event').map(it.kind) == [SymbolKind.interface_]
	assert 'vlib.bridge.Event' in refs_of(g, 'vlib.bridge.handle')
	assert 'vlib.bridge.C.Event' in refs_of(g, 'C.poll_event')
	// a field reached through the alias still has the C struct's field type, which
	// picks Label's `show` from Badge's: a bare name is not the C struct beside it
	calls := g.edges.filter(it.kind == .calls && it.from == 'vlib.bridge.render').map(it.to)
	assert calls == ['vlib.bridge.Label.show'], calls.str()
}

fn test_a_c_struct_beside_its_alias_in_a_test_program_resolves_its_references() {
	// In a directory of `module main` tests, `struct C.Size` with `type Size = C.Size`
	// in one file, and `struct C.Foo` with `type Foo = C.Foo` where other tests declare
	// `struct C.Foo` and `struct Foo`, came out as one id, `id@file` for the second
	// pair, for both declarations. Two declarations of an id in a standalone program
	// make it unaddressable, so every reference to the C struct and to the alias was
	// refused.
	g := built_graph_of({
		'vlib/v/tests/c_structs/return_csize_test.v':     '#include "@VMODROOT/csize.h"

struct C.Size {
	width int
}

type Size = C.Size

fn get_size() C.Size {
	return C.Size{11}
}

fn get_csize() Size {
	return Size(C.Size{11})
}

fn test_return_csize() {}
'
		'vlib/v/tests/c_structs/arr_map_test.c.v':       'module main

struct C.Foo {
	a int
}

type Foo = C.Foo

struct GameObject {
	b []Foo
}

fn test_main() {}
'
		'vlib/v/tests/c_structs/sumtype_test.c.v':       'struct C.Foo {
	a int
}

fn test_cstruct() {}
'
		'vlib/v/tests/c_structs/default_value_test.c.v': 'struct Foo {
	a int
}

fn test_default() {}
'
	})
	cs := 'vlib.v.tests.c_structs'
	assert refs_of(g, '${cs}.get_size') == ['${cs}.C.Size']
	assert refs_of(g, '${cs}.Size') == ['${cs}.C.Size']
	assert refs_of(g, '${cs}.get_csize') == ['${cs}.Size']
	foo := '${cs}.Foo@vlib/v/tests/c_structs/arr_map_test.c.v'
	assert refs_of(g, foo) == ['${cs}.C.Foo@vlib/v/tests/c_structs/arr_map_test.c.v']
	assert refs_of(g, '${cs}.GameObject') == [foo]
}

fn test_a_c_struct_repeated_under_a_top_level_comptime_if_in_a_program_resolves() {
	// A C struct declared in each branch of a top-level `$if` repeats one id in one
	// `module main` test file, as a function does. Its copies in that one file are one
	// declaration, as copies in an ordinary module's files are, so a reference to it
	// and a call of the function resolve. Two kinds of declaration under one id are
	// two declarations, and a reference to that id still doesn't resolve.
	g := built_graph_of({
		'vlib/v/tests/fns/closure_test.c.v': "module main

\$if windows {
	struct C.ClosureMutex {
		lock voidptr
	}
	fn ret() int {
		return 1
	}
} \$else {
	struct C.ClosureMutex {
		mutex voidptr
	}
	fn ret() int {
		return 2
	}
}

struct C.Closure {
	mtx C.ClosureMutex
}

struct Twice {}

type Twice = int

fn take(t Twice) {}

fn test_closure() {
	assert ret() > 0
}
"
	})
	file := 'vlib/v/tests/fns/closure_test.c.v'
	assert refs_of(g, 'vlib.v.tests.fns.C.Closure') == ['vlib.v.tests.fns.C.ClosureMutex@${file}']
	calls := g.edges.filter(it.kind == .calls && it.from == 'vlib.v.tests.fns.test_closure').map(it.to)
	assert calls == ['vlib.v.tests.fns.ret@${file}'], calls.str()
	assert refs_of(g, 'vlib.v.tests.fns.take') == ['Twice']
}

fn test_a_c_struct_declared_in_modules_the_reference_cannot_tell_apart_stays_unresolved() {
	// `C.timespec` is declared by os and by time. From picoev, which imports neither in
	// the referencing file, nothing picks one: the reference stays unresolved, neither
	// linked to one of them nor called undeclared. A file that imports time names
	// time's.
	g := graph_of({
		'vlib/os/sleeping.c.v':           'module os

pub struct C.timespec {
	tv_sec i64
}
'
		'vlib/time/time_nix.c.v':         'module time

pub struct C.timespec {
	tv_sec i64
}
'
		'vlib/picoev/loop_macos.c.v':     'module picoev

fn C.kevent(kq i32, timeout &C.timespec) i32
'
		'vlib/fasthttp/fasthttp_bsd.c.v': 'module fasthttp

import time

fn wait(ts &C.timespec) {}
'
	})
	kevent := g.edges.filter(it.kind == .references && it.from == 'C.kevent' && it.to.contains('timespec'))
	assert kevent.len == 1 && kevent[0].to == 'C.timespec' && kevent[0].provenance != .undeclared, kevent.str()
	assert refs_of(g, 'vlib.fasthttp.wait') == ['vlib.time.C.timespec']
}

fn test_a_global_that_shares_a_colliding_id_keeps_its_references() {
	// The functions `value` of two test files collide, so their edges are renamed to
	// `id@file`. A global of that id is not one of the kinds renamed, and its edges
	// were renamed too, to an id that names no symbol.
	mut files := two_strings.clone()
	files['vlib/v/tests/a_test.v'] = 'module main

fn value(n int) int {
	return n
}

fn test_a() {}
'
	files['vlib/v/tests/b_test.v'] = 'module main

fn value(n int) int {
	return n
}

fn test_b() {}
'
	files['vlib/v/tests/c_test.v'] = '@[translated]
module main

__global (
	value string
)

fn test_c() {}
'
	g := built_graph_of(files)
	ids := g.symbols.map(it.id)
	assert g.symbols.any(it.id == 'vlib.v.tests.value' && it.kind == .global)
	orphans := g.edges.filter(it.kind == .references && it.from !in ids)
	assert orphans.len == 0, orphans.map('${it.from} -> ${it.to}').str()
	assert refs_of(g, 'vlib.v.tests.value') == ['vlib.builtin.string']
}

fn test_parameter_types_resolve_method_calls() {
	// `s.contains(x)` inside `fn f(s string)` needs no inference: the type is
	// written on the declaration. Each call has a same-named decoy method in
	// the caller's own module, which the old same-module step picked instead.
	root := write_tree('param_types', {
		'lib/builtin/string.v':  'module builtin

pub struct string {}

pub fn (s string) contains(x string) bool {
	return false
}
'
		'lib/strings/builder.v': 'module strings

pub struct Builder {}

pub fn (mut b Builder) write_string(s string) {}
'
		'app/app.v':             'module app

import strings

struct Scope {}

fn (s Scope) contains(x string) bool {
	return false
}

fn (s Scope) write_string(x string) {}

fn check(name string, mut sb strings.Builder) bool {
	sb.write_string(name)
	return name.contains(".")
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .calls && it.from == 'app.check'
		&& it.to == 'lib.builtin.string.contains')
	assert g.edges.any(it.kind == .calls && it.from == 'app.check'
		&& it.to == 'lib.strings.Builder.write_string')
	assert !g.edges.any(it.kind == .calls && it.from == 'app.check' && it.to.starts_with('app.Scope'))
}

fn test_script_file_parses_in_script_mode_without_a_parse_error() {
	// Top-level statements with no `fn main` are a V script. Parsed as an
	// ordinary file every statement is an error and the file was flagged as
	// partial; in script mode they form `main`, with their calls.
	src := 'import os

fn helper() int {
	return 1
}

println(os.args.len)
x := helper()
println(x)
'
	fr := extract_v_text_result(src, 'examples/script.v')
	assert fr.parse_error == ''
	ids := fr.symbols.map(it.id)
	assert 'examples.helper' in ids
	assert 'examples.main' in ids
	assert fr.edges.any(it.kind == .calls && it.from == 'examples.main' && it.to.ends_with('helper'))
	// a real syntax error in a main file is still reported
	bad := extract_v_text_result('fn main() {\n\tx := [1, 2\n}\n', 'examples/bad.v')
	assert bad.parse_error != ''
}

fn test_source_files_are_listed_in_sorted_order() {
	// os.ls returns the filesystem's order, which differs between APFS and
	// NTFS; when two files declare the same id the first one read wins, so an
	// unsorted walk gave Mac and Windows different graphs of the same tree.
	root := write_tree('sorted_walk', {
		'z.v':     'module main\n'
		'a.v':     'module main\n'
		'm/b.v':   'module m\n'
		'm/a.v':   'module m\n'
		'b/c/x.v': 'module c\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	files := find_source_files(root).map(it.all_after(os.real_path(root)).replace('\\', '/'))
	assert files == ['/a.v', '/b/c/x.v', '/m/a.v', '/m/b.v', '/z.v']
}

fn test_anonymous_struct_types_do_not_name_the_host_path() {
	// V3 names an anonymous struct after the file's absolute path, so the
	// field's signature and its reference edge differed between machines.
	src := 'module cli

pub struct Command {
pub mut:
	defaults struct {
	pub mut:
		help bool
	}
	opt ?struct {
		x int
	}
}
'
	fr := extract_v_text_result(src, 'vlib/cli/command.v')
	syms := maps_by_id(fr.symbols)
	for id in ['vlib.cli.Command.defaults', 'vlib.cli.Command.opt'] {
		sig := syms[id] or { panic('missing ${id}') }.signature
		assert sig.contains('_VAnonStruct'), sig
		assert !sig.contains('_x2f_') && !sig.contains('_x5c_'), sig
	}
	for e in fr.edges {
		assert !e.to.contains('_x2f_') && !e.to.contains('_x5c_'), e.to
	}
}

fn test_an_anonymous_struct_is_referenced_through_the_types_of_its_fields() {
	// V3 names an anonymous struct or union after its file and a counter that
	// starts again in each file, so `_VAnonStruct1` here and in vlib/other are
	// different structs, and no declaration has the name: a reference to it
	// never resolved. The declaration that writes `struct { ... }` references
	// the types of its fields instead, through nested ones too, as it
	// references `Item` for a field of type `[]Item`.
	g := graph_of({
		'vlib/cfg/cfg.v':     'module cfg

pub struct Item {
	n int
}

pub enum Tag {
	x
}

pub struct Holder {
	name string
	opts ?struct {
		item  Item
		inner struct {
			items []Item
			u     union {
				a f32
				b Tag
			}
		}
	}
}

pub fn run(params struct {
	tag Tag
}) ?struct {
	item Item
} {
	return none
}

pub type Config = struct {
	holder Holder
}

type Check = fn (struct {
	item Item
}) bool

pub interface Source {
	cfg struct {
		tag Tag
	}
	get(o struct {
		item Item
	}) ?struct {
		tag Tag
	}
}

__global last struct {
	holder Holder
}
'
		'vlib/other/other.v': 'module other

struct Box {
	val struct {
		v int
	}
}
'
	})
	refs := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .references && it.from == from).map(it.to)
	}
	assert refs('vlib.cfg.Holder') == ['string', 'vlib.cfg.Item', 'f32', 'vlib.cfg.Tag'], refs('vlib.cfg.Holder').str()
	assert refs('vlib.cfg.run') == ['vlib.cfg.Tag', 'vlib.cfg.Item'], refs('vlib.cfg.run').str()
	assert refs('vlib.cfg.Config') == ['vlib.cfg.Holder'], refs('vlib.cfg.Config').str()
	// a function type's parameters are read from its text, as type_text wrote it
	assert refs('vlib.cfg.Check') == ['vlib.cfg.Item', 'bool'], refs('vlib.cfg.Check').str()
	assert refs('vlib.cfg.Source') == ['vlib.cfg.Tag'], refs('vlib.cfg.Source').str()
	assert refs('vlib.cfg.Source.get') == ['vlib.cfg.Item', 'vlib.cfg.Tag'], refs('vlib.cfg.Source.get').str()
	assert refs('vlib.cfg.last') == ['vlib.cfg.Holder'], refs('vlib.cfg.last').str()
	assert refs('vlib.other.Box') == ['int'], refs('vlib.other.Box').str()
	assert !g.edges.any(it.to.contains('Anon')), g.edges.filter(it.to.contains('Anon')).str()
	// the field is still a symbol, with its type as V 0.5.2 named it
	opts := g.symbols.filter(it.id == 'vlib.cfg.Holder.opts')
	assert opts.len == 1 && opts[0].signature.starts_with('opts ?_VAnonStruct'), opts.str()
}

fn test_if_guarded_functions_keep_their_calls_on_every_host() {
	// V3's parser drops the body of an `@[if cond]` function when cond is
	// false on this host, so each machine lost the other's calls.
	src := 'module m

fn helper() {}

@[if windows]
fn on_windows() {
	helper()
}

@[if !windows]
fn elsewhere() {
	helper()
}

/// traced logs
@[if trace ?; inline]
fn traced() {
	helper()
}
'
	fr := extract_v_text_result(src, 'm/m.v')
	assert fr.parse_error == ''
	syms := maps_by_id(fr.symbols)
	for f in ['on_windows', 'elsewhere', 'traced'] {
		assert fr.edges.any(it.kind == .calls && it.from == 'm.${f}' && it.to.ends_with('helper')), f
	}
	assert syms['m.on_windows'].line == 6
	assert syms['m.traced'].line == 17
	assert without_if_attrs('@[if a ?; inline]\nfn f() {}\n') == '@[${' '.repeat(8)}inline]\nfn f() {}\n'
	assert without_if_attrs('\t@[if a]\nx').len == '\t@[if a]\nx'.len
}

fn test_comptime_match_on_the_os_keeps_every_branch() {
	// V3's parser kept only this host's branch of `$match @OS`, so the const
	// below was declared on a different line on Mac and Windows, and the
	// body's call to `on_windows` existed only on Windows.
	src := r"module m

$match @OS {
	'linux' {
		const os = 'linux'
	}
	'windows' {
		const os = 'windows'
	}
	$else {
		const os = 'other'
	}
}

fn on_windows() {}

fn elsewhere() {}

fn pick() {
	$match @OS {
		'windows' { on_windows() }
		$else { elsewhere() }
	}
}
"
	fr := extract_v_text_result(src, 'm/m.v')
	assert fr.parse_error == ''
	consts := fr.symbols.filter(it.id == 'm.os')
	assert consts.map(it.line) == [5, 8, 11]
	for f in ['on_windows', 'elsewhere'] {
		assert fr.edges.any(it.kind == .calls && it.from == 'm.pick' && it.to.ends_with(f)), f
	}
	assert with_every_match_branch(r'$match @OS {') == r'$match mut @OS {'
}

fn test_imports_resolve_to_the_module_they_mean_in_the_tree() {
	// V3's import node holds the path as written. resolve_import names the
	// module the way V 0.5.2 did, below `vlib`, but in V3's lookup order and
	// only inside the extracted tree: `rand` in vlib/crypto/x is vlib/rand,
	// though vlib/crypto/rand is nearer (V 0.5.2 said `crypto.rand`).
	root := write_tree('import_resolution', {
		'vlib/rand/rand.v':                   'module rand\n\npub fn intn(n int) int {\n\treturn n\n}\n'
		'vlib/crypto/rand/rand.v':            'module rand\n\npub fn read(n int) int {\n\treturn n\n}\n'
		'vlib/crypto/x/x.v':                  'module x\n\nimport rand\nimport geometry\nimport os\n\nfn f() int {\n\treturn rand.intn(geometry.area())\n}\n'
		'vlib/crypto/x/geometry/geometry.v':  'module geometry\n\npub fn area() int {\n\treturn 1\n}\n'
		'vlib/v/tests/deep/user/user_test.v': 'module main\n\nimport helper\n\nfn test_u() {\n\thelper.go()\n}\n'
		'vlib/v/tests/helper/helper.v':       'module helper\n\npub fn go() {}\n'
		'examples/app/main.v':                'module main\n\nimport widgets as w\nimport os\n\nfn main() {\n\tw.draw()\n}\n'
		'examples/app/widgets/widgets.v':     'module widgets\n\npub fn draw() {}\n'
		'examples/app/empty/readme.md':       'no sources\n'
		'cmd/mcp/main.v':                     'module main\n\nimport mcp\n\nfn main() {\n\tmcp.serve()\n}\n'
		'lib/shapes/shapes.v':                 'module shapes\n\npub fn square() int {\n\treturn 4\n}\n'
		'lib/shapes/shapes_test.v':            'module main\n\nimport shapes\n\nfn test_s() {\n\tshapes.square()\n}\n'
		'vlib/arrays/arrays.v':                'module arrays\n\npub fn flatten() int {\n\treturn 1\n}\n'
		'vlib/v/tests/arrays/nested_test.v':   'module main\n\nfn test_n() {}\n'
		'vlib/v/tests/flat_test.v':            'module main\n\nimport arrays\n\nfn test_f() {\n\tarrays.flatten()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	real := os.real_path(root)
	imports := fn [real] (rel string) map[string]string {
		fr := extract_v_file_result(os.join_path(real, rel), rel)
		mut m := map[string]string{}
		for s in fr.symbols {
			if s.kind == .import_ {
				m[s.signature] = s.name
			}
		}
		for e in fr.edges {
			if e.kind == .calls {
				m['call ${e.to}'] = e.from
			}
		}
		return m
	}
	x := imports('vlib/crypto/x/x.v')
	assert 'import rand' in x, x.str()
	assert 'import crypto.x.geometry as geometry' in x, x.str()
	assert 'import os' in x, x.str()
	assert 'call rand.intn' in x, x.str()
	assert 'call crypto.x.geometry.area' in x, x.str()
	u := imports('vlib/v/tests/deep/user/user_test.v')
	assert 'import v.tests.helper as helper' in u, u.str()
	assert 'call v.tests.helper.go' in u, u.str()
	app := imports('examples/app/main.v')
	assert 'import examples.app.widgets as w' in app, app.str()
	assert 'import os' in app, app.str()
	assert 'call examples.app.widgets.draw' in app, app.str()
	// a program in a directory named like a module it imports, which it doesn't
	// declare, doesn't import itself: cmd/mcp's `import mcp` is the library's (here,
	// as written)
	mcp := imports('cmd/mcp/main.v')
	assert 'import mcp' in mcp, mcp.str()
	assert 'call mcp.serve' in mcp, mcp.str()
	// an external test imports the module of its own directory
	ext := imports('lib/shapes/shapes_test.v')
	assert 'import lib.shapes as shapes' in ext, ext.str()
	assert 'call lib.shapes.square' in ext, ext.str()
	// a directory of tests alone is no module: `import arrays` beside
	// vlib/v/tests/arrays is vlib's arrays
	flat := imports('vlib/v/tests/flat_test.v')
	assert 'import arrays' in flat, flat.str()
	assert 'call arrays.flatten' in flat, flat.str()
	// text has no place in a tree, so its imports stay as written
	t := extract_v_text_result('module m\n\nimport geometry\n', 'vlib/crypto/x/m.v')
	assert t.symbols.any(it.kind == .import_ && it.name == 'geometry')
}

fn test_get_body_of_a_crlf_file_has_no_carriage_returns() {
	// A Windows checkout with core.autocrlf gives CRLF files. Split on `\n`
	// alone every line kept a `\r`, and the closing-brace checks never
	// matched (CI's Windows runner caught it).
	src := 'module demo\n\nfn first() {\n\tprintln(1)\n}\n\nfn second() {\n\tprintln(2)\n}\n'.replace('\n',
		'\r\n')
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	body := g.get_body('first')
	assert !body.contains('\r'), body
	assert body.split('\n').last() == '}', body
	assert !body.contains('println(2)'), body
}

fn test_signatures_qualify_types_with_the_module_path_and_space_fn_types() {
	// V 0.5.2 wrote a type's module as its full path wherever it appears, and
	// a function type as `fn (...)`; V3 keeps the type as written.
	src := 'module m

import v.flat
import gg.m4 as mat
import encoding.binary { Endian }

pub fn walk(ids []flat.NodeId, by map[string]flat.Node, cb fn(flat.NodeId) bool) ?flat.NodeId {
	return none
}

struct S {
	v   mat.Vec4
	e   Endian
	all [][]flat.Op
}

type Visit = fn(&flat.Node, voidptr)
'
	fr := extract_v_text_result(src, 'm/m.v')
	syms := maps_by_id(fr.symbols)
	assert syms['m.walk'].signature == 'pub fn walk(ids []v.flat.NodeId, by map[string]v.flat.Node, cb fn (v.flat.NodeId) bool) ?v.flat.NodeId'
	assert syms['m.S.v'].signature == 'v gg.m4.Vec4'
	assert syms['m.S.e'].signature == 'e encoding.binary.Endian'
	assert syms['m.S.all'].signature == 'all [][]v.flat.Op'
	assert syms['m.Visit'].signature == 'type Visit = fn (&v.flat.Node, voidptr)'
}

fn test_function_end_line_is_the_last_line_of_its_header() {
	// V 0.5.2 recorded a function's end_line as the line of the `{` that
	// opens its body, so a multi-line header is covered; V3's extractor gave
	// the start line. A generic header or a body-less declaration ends on its
	// own line, where V 0.5.2's ran on.
	src := 'module m

fn long_header(a int,
	b map[string]int) ?struct {
	x int
} {
	return none
}

fn grouped[T](x T) string {
	return ""
}

fn C.puts(&char) int

fn bodyless(x int) int

fn brace_below() int
{
	return 1
}
'
	fr := extract_v_text_result(src, 'm/m.c.v')
	syms := maps_by_id(fr.symbols)
	assert syms['m.long_header'].line == 3
	assert syms['m.long_header'].end_line == 6
	assert syms['m.grouped'].end_line == 10
	assert syms['m.bodyless'].end_line == 16
	assert syms['m.brace_below'].end_line == 19
	script := extract_v_text_result('import os\n\nprintln(os.args)\nx := 1\nprintln(x)\n',
		'examples/s.v')
	main := maps_by_id(script.symbols)['examples.main']
	assert main.line == 3
	assert main.end_line == 5
}

fn test_imports_the_parser_adds_by_itself_are_marked_implied() {
	// V's parser imports `builtin.closure` for a closure, `sync.threads` for
	// `spawn`, `sync` for channels and `math` for `**`, though the file
	// doesn't write them. They are dependencies, so they stay, marked.
	src := 'module m

import os

fn work() int {
	return 1
}

fn f(ch chan int) {
	g := fn () {}
	t := spawn work()
	y := 2 ** 3
	println(os.args)
}
'
	fr := extract_v_text_result(src, 'm/m.v')
	mut sigs := map[string]string{}
	for s in fr.symbols {
		if s.kind == .import_ {
			sigs[s.name] = s.signature
		}
	}
	assert sigs['os'] == 'import os'
	assert sigs['builtin.closure'] == 'import builtin.closure (implied)', sigs.str()
	assert sigs['sync.threads'] == 'import sync.threads (implied)', sigs.str()
	assert sigs['sync'] == 'import sync (implied)', sigs.str()
	assert sigs['math'] == 'import math (implied)', sigs.str()
	assert fr.edges.any(it.kind == .imports && it.from == 'm' && it.to == 'sync.threads')
	// one the file writes is not marked
	w := extract_v_text_result('module m\n\nimport sync\n\nfn f(ch chan int) {}\n', 'm/w.v')
	assert w.symbols.filter(it.kind == .import_).map(it.signature) == ['import sync']
}

fn test_an_implied_import_does_not_make_a_module_visible_to_calls() {
	// A channel implies `sync`, but the file can't name anything in it, so a
	// bare `helper()` must not resolve into sync's or another module's
	// `helper`: counting implied imports turned 160 resolved `ch.close()`-style
	// calls on vlang ambiguous.
	root := write_tree('implied_visibility', {
		'm/m.v':         'module m\n\nfn f(ch chan int) {\n\thelper()\n}\n'
		'sync/sync.v':   'module sync\n\npub fn helper() {}\n'
		'other/other.v': 'module other\n\npub fn helper() {}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.symbols.any(it.kind == .import_ && it.signature == 'import sync (implied)')
	call := g.edges.filter(it.kind == .calls && it.from == 'm.f')
	assert call.len == 1
	assert call[0].to == 'helper', call[0].to
}

fn test_resolve_one_matches_nothing_for_an_empty_reference() {
	mut g := Graph{}
	g.symbols = [
		Symbol{
			id:     'json2.null'
			name:   'null'
			kind:   .constant
			parent: 'json2'
			file:   'types.v'
		},
		Symbol{
			id:     'demo.greet'
			name:   'greet'
			kind:   .function
			parent: 'demo'
			file:   'demo.v'
		},
	]
	assert g.resolve_one('') == ''
	assert g.resolve_one('   ') == ''
	assert g.resolve_one('greet') == 'demo.greet'
	assert g.shortest_path('', 'greet').len == 0
	assert g.neighbor_names('').len == 0
}

fn test_missing_tool_arg_names_the_absent_or_blank_argument() {
	// The MCP layer passes only string-valued arguments, so a client sending
	// `{"name": "x"}` instead of `{"node": "x"}` arrives here without `node`.
	assert missing_tool_arg('get_node', {
		'name': 'vlib.os.join_path'
	}) == 'get_node: missing required argument `node`'
	assert missing_tool_arg('get_body', {
		'node': ''
	}) == 'get_body: missing required argument `node`'
	assert missing_tool_arg('get_neighbors', map[string]string{}) == 'get_neighbors: missing required argument `node`'
	assert missing_tool_arg('query_graph', {
		'text': '  '
	}) == 'query_graph: missing required argument `text`'
	assert missing_tool_arg('shortest_path', {
		'a': 'x'
	}) == 'shortest_path: missing required argument `b`'
	assert missing_tool_arg('get_node', {
		'node': 'greet'
	}) == ''
	assert missing_tool_arg('overview', map[string]string{}) == ''
}

fn test_get_body_of_a_bodyless_declaration_is_just_its_header() {
	// A function declared without a body ends on its header. get_body used to
	// read on to the next declaration and found no closing brace to trim back
	// to, so it served the blank line and the next declaration's doc comment.
	src := 'module demo

// contains reports whether a holds value.
pub fn contains(a []int, value int) bool

// index finds value.
pub fn index(a []int, value int) int

fn wrapped(a int,
	b int) int

fn real() int {
	return 1
}
'
	g, root := body_fixture(src)
	defer {
		os.rmdir_all(root) or {}
	}
	assert g.get_body('contains') == '// demo.v:4-4\npub fn contains(a []int, value int) bool'
	assert g.get_body('wrapped') == '// demo.v:9-10\nfn wrapped(a int,\n\tb int) int'
	assert g.get_body('real').ends_with('\treturn 1\n}')
}

fn test_receiver_types_are_inferred_through_the_graph() {
	// `contains`, `size` and `label` are each declared on two types, so the
	// name alone can't pick one; the receiver's type, followed through
	// return types, field types, elements, map values, a multi-value return,
	// an option and `it`, does
	files := {
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) contains(x string) bool {
	return true
}
'
		'text/text.v':           'module text

pub struct Doc {
pub:
	title string
	parts []Part
	index map[string]Part
}

pub struct Part {
pub:
	name string
}

pub fn load(path string) !Doc {
	return Doc{}
}

pub fn (d Doc) first() ?Part {
	return none
}

pub fn (p Part) size() int {
	return 0
}

pub fn (p Part) label() string {
	return p.name
}
'
		'other/other.v':         'module other

pub struct Part {}

pub fn (p Part) size() int {
	return 1
}

pub fn (p Part) label() string {
	return ""
}

pub fn (p Part) contains(x string) bool {
	return false
}
'
		'app/main.v':            'module main

import text
import other

fn pair() (int, string) {
	return 1, "a"
}

fn run() {
	d := text.load("x") or { return }
	d.title.contains("a")
	for p in d.parts {
		p.size()
	}
	first := d.first() or { return }
	first.label()
	_, s := pair()
	s.contains("b")
	d.index["k"].size()
	d.parts.filter(it.size() > 0)
	o := other.Part{}
	o.label()
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	resolve_edges(mut g)
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run').map(it.to)
	assert 'vlib.builtin.string.contains' in calls
	assert 'other.Part.contains' !in calls
	assert 'text.Part.size' in calls
	assert 'other.Part.size' !in calls
	// `first.label()` is text's, `o.label()` other's: one edge each
	assert 'text.Part.label' in calls
	assert 'other.Part.label' in calls
	mut seen := map[string]bool{}
	for c in calls {
		assert c !in seen
		seen[c] = true
	}
}

fn test_inferred_receiver_respects_shadowing() {
	// the inner `d` is a string, whatever the outer one was
	files := {
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) contains(x string) bool {
	return true
}
'
		'lib/lib.v':             'module lib

pub struct Box {}

pub fn (b Box) contains(x string) bool {
	return false
}

pub fn make() Box {
	return Box{}
}
'
		'app/main.v':            'module main

import lib

fn run() {
	d := lib.make()
	if true {
		d := "text"
		d.contains("a")
	}
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	resolve_edges(mut g)
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run').map(it.to)
	assert 'vlib.builtin.string.contains' in calls
	assert 'lib.Box.contains' !in calls
}

fn test_type_text_helpers() {
	assert return_type('pub fn (b &Builder) str() string', 'str') == 'string'
	assert return_type('fn read_file(path string) !string', 'read_file') == '!string'
	assert return_type('fn run()', 'run') == ''
	assert return_type('fn map_of[T](xs []T) map[string]T', 'map_of') == 'map[string]T'
	assert bare_type('?&mut Foo') == 'Foo'
	assert bare_type('...string') == '[]string'
	k, v := map_parts('map[string][]int') or { '', '' }
	assert k == 'string' && v == '[]int'
	assert elem_type('[4]u8') or { '' } == 'u8'
	assert elem_type('string') or { '' } == 'u8'
	assert tuple_part('(int, map[string]int)', 1) or { '' } == 'map[string]int'
}

fn graph_of(files map[string]string) Graph {
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	resolve_edges(mut g)
	return g
}

fn test_interface_members_are_symbols() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub interface Logger {
	Base
	level int
mut:
	log(msg string) !
	name() string
}

pub interface Base {
	id() int
}
'
	})
	log := g.symbols.filter(it.id == 'lib.Logger.log')
	assert log.len == 1
	assert log[0].kind == .method
	assert log[0].signature == 'fn (Logger) log(msg string) !'
	name := g.symbols.filter(it.id == 'lib.Logger.name')
	assert name.len == 1 && name[0].signature == 'fn (Logger) name() string'
	level := g.symbols.filter(it.id == 'lib.Logger.level')
	assert level.len == 1 && level[0].kind == .field && level[0].parent == 'lib.Logger'
	assert g.symbols.filter(it.id == 'lib.Logger.Base').len == 0 // an embed, not a member
	assert g.edges.any(it.kind == .embeds && it.from == 'lib.Logger' && it.to == 'lib.Base')
}

fn test_calls_through_interfaces_and_embeds_resolve() {
	g := graph_of({
		'vlib/builtin/err.v': 'module builtin

pub interface IError {
	msg() string
	code() int
}

pub fn (s string) contains(x string) bool {
	return true
}
'
		'lib/lib.v':          'module lib

pub struct Inner {}

pub fn (i Inner) msg() string {
	return ""
}

pub fn (i Inner) contains(x string) bool {
	return false
}

pub struct Outer {
	Inner
}

pub interface Source {
	read() string
}

pub struct Holder {
pub:
	src Source
}

pub struct File {}

pub fn (f File) read() string {
	return ""
}

pub fn fail() ! {
}
'
		'app/main.v':         'module main

import lib

fn run(o lib.Outer, h lib.Holder) {
	lib.fail() or { err.msg().contains("x") }
	o.msg()
	h.src.read()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run').map(it.to)
	assert 'vlib.builtin.IError.msg' in calls
	assert 'vlib.builtin.string.contains' in calls
	assert 'lib.Inner.contains' !in calls
	assert 'lib.Inner.msg' in calls // promoted from the embedded struct
	assert 'lib.Source.read' in calls
	assert 'lib.File.read' !in calls
}

fn test_calls_without_declarations_are_undeclared() {
	g := graph_of({
		'lib/lib.v':  'module lib

pub type Callback = fn (int) int

pub struct Box {
pub:
	cb   fn (int) string
	hook Callback
}

pub fn cb(x int) string {
	return ""
}

pub fn hook(x int) int {
	return x
}

pub fn work() {
}

pub fn apply(f fn (int) int) int {
	return f(1)
}
'
		'app/main.v': 'module main

import lib

fn run(b lib.Box) {
	b.cb(1)
	b.hook(2)
	t := spawn lib.work()
	t.wait()
	g := fn (x int) int {
		return x
	}
	g(3)
}
'
	})
	run := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	for name in ['wait', 'g'] {
		e := run.filter(it.to == name)
		assert e.len == 1, name
		assert e[0].provenance == .undeclared, name
	}
	// a function-typed field, written out or through a `type`, is the
	// declaration such a call has, never a function of the same name
	assert run.any(it.to == 'lib.Box.cb')
	assert run.any(it.to == 'lib.Box.hook')
	assert !run.any(it.to == 'lib.cb' || it.to == 'lib.hook')
	// `f(1)` calls the parameter, not some function named `f`
	apply := g.edges.filter(it.kind == .calls && it.from == 'lib.apply')
	assert apply.len == 1 && apply[0].to == 'f' && apply[0].provenance == .undeclared
	report := g.report()
	assert report.contains('undeclared 3')
	// and `explain` doesn't count them as possible callers of `lib.cb`
	assert !g.explain('lib.cb').contains('possibly called by')
}

fn test_free_on_a_type_with_no_free_method_is_the_builtin_free() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub struct Plain {
	a int
}

pub struct Owned {
	a int
}

pub fn (o Owned) free() {
}
'
		'app/main.v': 'module main

import lib

fn run(p lib.Plain, o lib.Owned) {
	p.free()
	o.free()
}
'
	})
	run := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	// `Plain` declares no free, so `p.free()` is the builtin one V provides for any value
	plain := run.filter(it.to == 'free')
	assert plain.len == 1 && plain[0].provenance == .undeclared
	// `Owned` declares its own, which the call resolves to
	assert run.any(it.to == 'lib.Owned.free')
}

fn test_a_call_on_any_field_in_a_field_loop_reaches_each_field_types_method() {
	g := graph_of({
		'lib/lib.v': 'module lib

struct Alpha {}

fn (a Alpha) show() string {
	return ""
}

struct Beta {}

fn (b Beta) show() string {
	return ""
}

struct Key {}

fn (k Key) show() string {
	return ""
}

struct Plain {}

struct Box {
	a Alpha
	b Beta
	p Plain
	n int
	m map[Key]Alpha
}

fn concrete(x Box) {
	\$for field in Box.fields {
		\$if field.is_struct {
			x.\$(field.name).show()
		}
	}
}

fn generic[T](x T) {
	\$for field in T.fields {
		\$if field.is_map {
		} \$else {
			x.\$(field.name).show()
		}
	}
}

fn maps(x Box) {
	\$for field in Box.fields {
		\$if field.typ is \$map {
			for k, v in x.\$(field.name) {
				k.show()
				v.show()
			}
		}
	}
}

fn run() {
	generic(Box{})
}
'
	})
	calls_of := fn [g] (from string) []Edge {
		return g.edges.filter(it.kind == .calls && it.from == from)
	}
	// each struct field's show, one comptime edge each; the map and int fields are no structs
	concrete := calls_of('lib.concrete')
	assert concrete.filter(it.provenance == .comptime).map(it.to).sorted() == ['lib.Alpha.show', 'lib.Beta.show'], concrete.str()
	// in a generic function, the fields of each instance, less the map the `\$if` leaves out
	generic := calls_of('lib.generic')
	assert generic.filter(it.provenance == .comptime).map(it.to).sorted() == ['lib.Alpha.show', 'lib.Beta.show'], generic.str()
	// a map field's keys and values, each typed apart
	maps := calls_of('lib.maps')
	key := maps.filter(it.to == 'lib.Key.show')
	value := maps.filter(it.to == 'lib.Alpha.show')
	assert key.len == 1 && key[0].provenance == .comptime, maps.str()
	assert value.len == 1 && value[0].provenance == .comptime, maps.str()
	assert key[0].lines != value[0].lines, maps.str()
	assert !maps.any(it.to == 'lib.Beta.show' || it.to == 'show'), maps.str()
	assert g.report().contains('comptime 6')
}

fn test_a_field_loops_kind_narrowings_choose_the_fields_a_call_reaches() {
	g := graph_of({
		'lib/lib.v': 'module lib

struct Alpha {}

fn (a Alpha) show() string {
	return ""
}

struct Beta {}

fn (b Beta) show() string {
	return ""
}

enum Color {
	red
}

fn (c Color) show() string {
	return ""
}

type Gamma = Beta

fn (n int) show() string {
	return ""
}

struct Epsilon {}

fn (e Epsilon) show() string {
	return ""
}

fn (xs []Alpha) show() string {
	return ""
}

struct Box {
	a Alpha
	b Beta
	c Color
	g Gamma
	n int
	r &Epsilon
	l []Alpha
}

struct Small {
	a Alpha
}

fn enums(x Box) {
	\$for field in Box.fields {
		\$if field.is_enum {
			x.\$(field.name).show()
		}
	}
}

fn not_structs(x Box) {
	\$for field in Box.fields {
		\$if field.is_struct {
		} \$else {
			x.\$(field.name).show()
		}
	}
}

fn negated(x Box) {
	\$for field in Box.fields {
		\$if !field.is_struct {
			x.\$(field.name).show()
		}
	}
}

fn not_alpha(x Box) {
	\$for field in Box.fields {
		\$if field.typ is Alpha {
		} \$else {
			x.\$(field.name).show()
		}
	}
}

fn not_named(x Box) {
	\$for field in Box.fields {
		\$if field.name == \'a\' {
		} \$else \$if field.is_enum {
		} \$else {
			x.\$(field.name).show()
		}
	}
}

fn other_loop(x Box) {
	\$for field in Small.fields {
		x.\$(field.name).show()
	}
}

fn guarded[T](x T) {
	\$if T.unaliased_typ is Small {
		\$for field in T.fields {
			x.\$(field.name).show()
		}
	}
}

fn not_epsilon(x Box) {
	\$for field in Box.fields {
		\$if field.typ is Epsilon {
		} \$else {
			x.\$(field.name).show()
		}
	}
}

fn unaliased_enum(x Box) {
	\$for field in Box.fields {
		\$if field.unaliased_typ is \$enum {
			x.\$(field.name).show()
		}
	}
}

fn elems(xs []Box) {
	for x in xs {
		\$for field in Box.fields {
			\$if field.is_enum {
				x.\$(field.name).show()
			}
		}
	}
}

fn gen_elems[T](xs []T) {
	for x in xs {
		\$for field in T.fields {
			\$if field.is_enum {
				x.\$(field.name).show()
			}
		}
	}
}

fn two[T, U](x T, y U) {
	\$for field in U.fields {
		x.\$(field.name).show()
	}
}

fn run() {
	guarded(Box{})
	guarded(Small{})
	gen_elems([Box{}])
	two(Box{}, Small{})
}
'
	})
	comptime_of := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.from == from && it.provenance == .comptime).map(it.to).sorted()
	}
	// V reads is_enum and is_struct off the unaliased type: Gamma, an alias of a struct, is
	// one, and so is the Epsilon r points to; an int or an array is neither, whatever
	// methods it has
	assert comptime_of('lib.enums') == ['lib.Color.show']
	assert comptime_of('lib.unaliased_enum') == ['lib.Color.show']
	assert comptime_of('lib.not_structs') == ['lib.Color.show', 'lib.[]Alpha.show', 'lib.int.show']
	assert comptime_of('lib.negated') == ['lib.Color.show', 'lib.[]Alpha.show', 'lib.int.show']
	// an `\$else` after `typ is Alpha` is every other field, the alias of Beta included
	assert comptime_of('lib.not_alpha') == ['lib.Beta.show', 'lib.Color.show', 'lib.Epsilon.show',
		'lib.[]Alpha.show', 'lib.int.show']
	// `typ is Epsilon` is the whole type: r, an `&Epsilon`, is in the `\$else`
	assert comptime_of('lib.not_epsilon') == ['lib.Alpha.show', 'lib.Beta.show', 'lib.Color.show',
		'lib.Epsilon.show', 'lib.[]Alpha.show', 'lib.int.show']
	// after the field `a` and the enum, b, g, n, r and l are left
	assert comptime_of('lib.not_named') == ['lib.Beta.show', 'lib.Epsilon.show', 'lib.[]Alpha.show',
		'lib.int.show']
	// x is not of the type the loop walks, so its fields are not the loop's, whether x is a
	// known type or another type parameter than the loop's
	assert comptime_of('lib.other_loop') == []
	assert comptime_of('lib.two') == []
	// the guard keeps the Small instance only, not Box
	assert comptime_of('lib.guarded') == ['lib.Alpha.show']
	// an element of an array of the loop's type is of that type, concrete or a type parameter
	assert comptime_of('lib.elems') == ['lib.Color.show']
	assert comptime_of('lib.gen_elems') == ['lib.Color.show']
}

fn test_a_field_loops_type_pin_compares_declarations_not_names() {
	g := graph_of({
		'a/a.v': 'module a

pub struct Foo {}

pub fn (f Foo) show() string {
	return ""
}

pub struct S {
pub:
	x Foo
}

pub struct S2 {
pub:
	y &Foo
}
'
		'b/b.v': 'module b

import a

struct Foo {}

fn show_all[T](s T) {
	\$for field in T.fields {
		\$if field.typ is Foo {
		} \$else {
			s.\$(field.name).show()
		}
	}
}

fn show_ref[T](s T) {
	\$for field in T.fields {
		\$if field.typ is &Foo {
		} \$else {
			s.\$(field.name).show()
		}
	}
}

fn run() {
	show_all(a.S{})
	show_ref(a.S2{})
}
'
		'c/c.v': 'module c

pub struct Foo {}
'
		'd/d.v': 'module d

import a
import c { Foo }

fn walk[T](v T) {
	\$for field in T.fields {
		\$if field.typ is Foo {
		} \$else {
			v.\$(field.name).show()
		}
	}
}

fn run() {
	walk(a.S{})
}
'
	})
	// b's Foo is not a's: the field x is in the `\$else`, so the call reaches a.Foo.show,
	// and so does y, an `&a.Foo`, in the `\$else` of `typ is &Foo`; d's Foo is c's
	for from in ['b.show_all', 'b.show_ref', 'd.walk'] {
		calls := g.edges.filter(it.kind == .calls && it.from == from)
		assert calls.len == 1 && calls[0].to == 'a.Foo.show', '${from}: ${calls}'
		assert calls[0].provenance == .comptime, '${from}: ${calls}'
	}
}

fn test_a_field_loops_call_reaches_every_platform_copy_of_the_method() {
	files := {
		'prog/main.v':      'module main

struct Doc {}

struct Holder {
	d Doc
}

fn main() {
	run(Holder{})
}

fn run(x Holder) {
	\$for field in Holder.fields {
		x.\$(field.name).close()
	}
}
'
		'prog/p_nix.c.v':     'module main

pub fn (d Doc) close() bool {
	return true
}
'
		'prog/p_windows.c.v': 'module main

pub fn (d Doc) close() bool {
	return true
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	calls := g.edges.filter(it.kind == .calls && it.from == 'prog.run')
	assert calls.map(it.to).sorted() == ['prog.Doc.close@prog/p_nix.c.v',
		'prog.Doc.close@prog/p_windows.c.v'], calls.str()
	assert calls.all(it.provenance == .comptime), calls.str()
}

fn test_a_call_on_any_field_is_linked_per_field_even_when_its_name_is_unique() {
	g := graph_of({
		'lib/lib.v': 'module lib

struct Delta {}

fn (d Delta) only_here() {
}

struct Holder {
	d Delta
	n int
}

fn concrete(x Holder) {
	\$for field in Holder.fields {
		x.\$(field.name).only_here()
	}
}

fn generic[T](x T) {
	\$for field in T.fields {
		x.\$(field.name).only_here()
	}
}

fn run() {
	generic(Holder{})
}
'
	})
	// a name match would give the same callee as extracted; the loop makes it comptime
	for from in ['lib.concrete', 'lib.generic'] {
		calls := g.edges.filter(it.kind == .calls && it.from == from)
		assert calls.len == 1 && calls[0].to == 'lib.Delta.only_here', '${from}: ${calls}'
		assert calls[0].provenance == .comptime, '${from}: ${calls}'
	}
}

fn test_a_call_in_a_field_loop_that_no_field_answers_resolves_as_before() {
	g := graph_of({
		'lib/lib.v': 'module lib

struct Widget {}

fn (w Widget) frob() {
}

struct Gadget {}

fn (g Gadget) show() string {
	return ""
}

struct Box {
	n int
	g Gadget
}

fn concrete(x Box) {
	\$for field in Box.fields {
		x.\$(field.name).frob()
	}
}

fn generic[T](x T) {
	\$for field in T.fields {
		x.\$(field.name).frob()
	}
}

fn both(x Box, g Gadget) {
	g.show()
	\$for field in Box.fields {
		x.\$(field.name).show()
	}
}

fn run() {
	generic(Box{})
}
'
	})
	calls_of := fn [g] (from string) []Edge {
		return g.edges.filter(it.kind == .calls && it.from == from)
	}
	// no field of Box has a frob, so the call is matched by its name, as before field loops
	// were followed, both on a known type and on a type parameter's instances
	for from in ['lib.concrete', 'lib.generic'] {
		calls := calls_of(from)
		assert calls.len == 1 && calls[0].to == 'lib.Widget.frob', '${from}: ${calls}'
		assert calls[0].provenance != .comptime, '${from}: ${calls}'
	}
	// a field loop's call that reaches a method the function already calls joins that edge
	both := calls_of('lib.both').filter(it.to == 'lib.Gadget.show')
	assert both.len == 1, both.str()
	assert both[0].provenance != .comptime && both[0].lines.len == 2, both.str()
}

fn test_index_leaves_undeclared_calls_unresolved() {
	// `conv` and `on_done` are each declared exactly once, so a bare-name
	// match would resolve the undeclared calls to them
	g := graph_of({
		'lib/lib.v':  'module lib

pub fn conv(x int) int {
	return x
}
'
		'app/main.v': 'module main

struct Job {
	on_done fn ()
}

fn run(j Job, conv fn (int) int) int {
	j.on_done()
	return conv(1)
}
'
	})
	raw := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	assert raw.len == 2
	// `conv(1)` calls the parameter: undeclared, and never linked by name
	conv := raw.filter(it.to == 'conv')
	assert conv.len == 1 && conv[0].provenance == .undeclared
	idx := g.index()
	assert !idx.edges.any(it.from == 'app.run' && it.to == 'lib.conv')
	assert !g.explain('lib.conv').contains('app.run')
	assert g.shortest_path('app.run', 'lib.conv').len == 0
	// still counted as undeclared, not unresolved
	assert g.report().contains('undeclared 1')
	// `j.on_done()` calls the function-typed field, which is its declaration
	assert raw.any(it.to == 'app.Job.on_done' && it.provenance == .inferred)
	assert g.explain('app.Job.on_done').contains('run')
}

fn test_calls_through_constants_holding_functions_resolve() {
	// a call of a constant that holds a function resolves to that constant, from its own
	// file or an imported module; a method call never does, even when a constant of that
	// name exists
	g := graph_of({
		'lib/lib.v':  'module lib

pub fn once(x int) int {
	return x
}

pub const f = once
pub const size = 16

pub struct Box {
pub:
	n int
}
'
		'app/main.v': 'module main

import lib

const tdivider = lib.once

fn run() int {
	return tdivider(1) + lib.f(2)
}

fn run_method(b lib.Box) int {
	return b.size()
}

const count = 3

fn run_count() int {
	return count(1)
}
'
	})
	run := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	assert run.any(it.to == 'app.tdivider'), run.str()
	assert run.any(it.to == 'lib.f'), run.str()
	assert !g.edges.any(it.from == 'app.run_method' && it.to == 'lib.size'), g.edges.str()
	// `count` holds an int, so `count(1)` is a call of some function, never of the constant
	assert !g.edges.any(it.from == 'app.run_count' && it.to == 'app.count'), g.edges.str()
}

fn test_constants_are_callees_only_where_visible_and_no_function_takes_the_name() {
	g := graph_of({
		'lib/lib.v':  'module lib

pub fn once(x int) int {
	return x
}

pub const helper = once
pub const abc = once
'
		'app/main.v': 'module main

fn abc() int {
	return 1
}

fn run_helper() int {
	return helper(2)
}

fn run_abc() int {
	return abc()
}
'
	})
	// app does not import lib, so lib's `helper` is not what `helper(2)` calls
	assert !g.edges.any(it.from == 'app.run_helper' && it.to == 'lib.helper'), g.edges.str()
	// app's own `abc` function takes the call, not the constant of that name in lib
	assert g.edges.any(it.from == 'app.run_abc' && it.to == 'app.abc'), g.edges.str()
	assert !g.edges.any(it.from == 'app.run_abc' && it.to == 'lib.abc'), g.edges.str()
}

fn test_a_field_promoted_through_an_embedded_pointer_with_a_default_is_typed() {
	// `Alias` embeds `AliasDataRef` with a default, `AliasDataRef = empty_alias_data`, so
	// `base_type` is promoted from `AliasData`; reading it through a narrowed variable
	// types the call on it
	g := graph_of({
		'types/type.v': 'module types

pub type Type = Alias | Struct

pub struct Struct {
pub:
	id u32
}

pub struct Alias {
	AliasDataRef = empty_alias_data
}

const empty_alias_data = &AliasData{}

pub type AliasDataRef = &AliasData

pub struct AliasData {
pub:
	base_type &Type
}

pub fn (t &Type) source_type_id() u32 {
	return 1
}

pub fn (value Struct) source_type_id() u32 {
	return 2
}
'
		'app/main.v': 'module main

import types

fn pick(actual &types.Type) u32 {
	if actual is types.Alias {
		c := actual.base_type
		return c.source_type_id()
	}
	return 0
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.pick')
	assert calls.any(it.to == 'types.Type.source_type_id'), calls.str()
}

fn test_an_embedded_default_keeps_the_calls_in_it() {
	// `BaseRef = make_base()` embeds `BaseRef`, and its default's call is still made from
	// the field, as it was before the embed was recorded
	g := graph_of({
		'app/app.v': 'module app

pub struct Base {
pub:
	id int
}

pub type BaseRef = &Base

pub fn make_base() &Base {
	return &Base{}
}

pub struct Holder {
	BaseRef = make_base()
	extra   int
}
'
	})
	assert g.edges.any(it.from == 'app.Holder' && it.kind == .embeds && it.to == 'app.BaseRef'), g.edges.str()
	assert g.edges.any(it.from == 'app.Holder.BaseRef' && it.kind == .calls && it.to == 'app.make_base'), g.edges.str()
}

fn test_stale_note() {
	dir := os.join_path(os.temp_dir(), 'graphify_stale_${os.getpid()}')
	os.rmdir_all(dir) or {}
	repo := os.join_path(dir, 'repo')
	out := os.join_path(dir, 'out')
	os.mkdir_all(repo) or { panic(err) }
	os.mkdir_all(out) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	git := fn [repo] (args ...string) string {
		mut cmd := ['git', '-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
			'commit.gpgsign=false']
		cmd << args
		return os.exec(cmd).output.trim_space()
	}
	git('init', '-q')
	os.write_file(os.join_path(repo, 'a.v'), 'module a\n') or { panic(err) }
	git('add', '.')
	git('commit', '-q', '-m', 'one')
	first := git('rev-parse', 'HEAD')
	exe := os.join_path(dir, 'graphify-exe')
	os.write_file(exe, 'build one') or { panic(err) }
	graph := os.join_path(out, 'graph.json')
	write := fn [out] (commit string, bin_hash string) {
		os.write_file(os.join_path(out, 'manifest.json'), '{"source_commit": "${commit}", "binary_hash": "${bin_hash}"}') or {
			panic(err)
		}
	}
	write(first, file_hash(exe))
	assert stale_note(graph, repo, exe) == ''

	// the checkout moves on: two commits ahead of the graph
	for msg in ['two', 'three'] {
		os.write_file(os.join_path(repo, '${msg}.v'), 'module a\n') or { panic(err) }
		git('add', '.')
		git('commit', '-q', '-m', msg)
	}
	note := stale_note(graph, repo, exe)
	assert note.contains('extracted from ${first[..10]}')
	assert note.contains('(2 commits ahead)')
	assert !note.contains('graphify build')

	// a rebuilt graphify extracts differently
	write(git('rev-parse', 'HEAD'), file_hash(exe))
	os.write_file(exe, 'build two') or { panic(err) }
	assert stale_note(graph, repo, exe).contains('different graphify build')
	// the extractor built with this CLI: a graph either of them made is current, and one
	// made by an extractor since rebuilt is not
	at := git('rev-parse', 'HEAD')
	os.unsetenv(no_extractor_env)
	extractor := os.join_path(os.dir(exe), extractor_name)
	pair := extractor + extractor_pair_suffix
	os.write_file(extractor, 'extractor one') or { panic(err) }
	// with nothing saying it is of this CLI, it isn't used
	assert extractor_of(exe) == exe
	os.write_file(pair, file_hash(exe)) or { panic(err) }
	assert extractor_of(exe) == extractor
	assert stale_note(graph, repo, exe).contains('different graphify build')
	write(at, file_hash(exe))
	assert stale_note(graph, repo, exe) == ''
	write(at, file_hash(extractor))
	assert stale_note(graph, repo, exe) == ''
	os.write_file(extractor, 'extractor two') or { panic(err) }
	assert stale_note(graph, repo, exe).contains('different graphify build')
	// a CLI that is another build, rebuilt by hand or restored, goes on without it, and
	// the extractor's graph is of other code
	write(at, file_hash(extractor))
	os.write_file(pair, 'the hash of another CLI') or { panic(err) }
	assert extractor_of(exe) == exe
	assert stale_note(graph, repo, exe).contains('different graphify build')
	write(at, file_hash(exe))
	assert stale_note(graph, repo, exe) == ''
	// asked not to, the CLI extracts, and that says nothing of a graph already extracted
	os.write_file(pair, file_hash(exe)) or { panic(err) }
	write(at, file_hash(extractor))
	assert extract_handover(exe) == extractor
	os.setenv(no_extractor_env, '1', true)
	assert extract_handover(exe) == exe
	assert extractor_of(exe) == extractor
	assert stale_note(graph, repo, exe) == ''
	os.unsetenv(no_extractor_env)
	write(at, file_hash(exe))
	// with the extractor gone, the CLI extracts
	os.rm(extractor) or { panic(err) }
	assert extractor_of(exe) == exe
	os.rm(pair) or { panic(err) }
	write(at, 'build one no longer exists')
	// unless the graph came from another machine, whose build always differs
	assert stale_note(graph, repo, '') == ''
	// the library it read has moved: the V checkout was updated since
	head := git('rev-parse', 'HEAD')
	json_repo := repo.replace('\\', '\\\\')
	os.write_file(os.join_path(out, 'manifest.json'), '{"source_commit": "${head}", "library": [{"label": "vlib", "root": "${json_repo}", "commit": "${first}"}]}') or {
		panic(err)
	}
	lib_note := stale_note(graph, repo, '')
	assert lib_note.contains('its library (vlib) was read from ${repo} at ${first[..10]}'), lib_note
	// no manifest, no opinion
	os.rm(os.join_path(out, 'manifest.json')) or {}
	assert stale_note(graph, repo, exe) == ''
}

fn test_platform_variants_show_the_native_declaration() {
	// One function declared per backend shares one id (disambiguate_ids leaves
	// it alone). The walk visits a.c.v before a.js.v, so an index that kept the
	// last declaration showed the JS backend's copy for a call from plain V.
	root := write_tree('platform_variants', {
		'm/a.c.v':  'module m

pub fn read_it() string {
	return "native"
}
'
		'm/a.js.v': 'module m

pub fn read_it() string {
	return "js"
}
'
		'm/use.v':  'module m

pub fn caller() string {
	return read_it()
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.symbols.filter(it.id == 'm.read_it').len == 2
	explained := g.explain('read_it')
	assert explained.starts_with('fn read_it  (m/a.c.v:3)'), explained
	// the JS backend's copy is the other build's
	assert explained.contains('other builds  : pub fn read_it() string (m/a.js.v:3) [\$if js]'), explained
	body := g.get_body('read_it')
	assert body.starts_with('// m/a.c.v:3-'), body
	assert body.contains('"native"'), body
	assert g.explain('caller').contains('calls         : read_it (m/a.c.v:3)')
	assert g.query('read_it', 2000, false).contains('// m/a.c.v:3')
}

fn test_a_call_through_a_fn_field_is_marked_as_one() {
	// `s.on_running(mut s)` calls the function a field holds, not a method; listed
	// among the calls unmarked, it reads as one.
	root := write_tree('fn_field_call', {
		'm/s.v': 'module m

pub struct Server {
pub mut:
	on_running fn (mut s Server) = unsafe { nil }
}

pub fn (mut s Server) close() {}

pub fn (mut s Server) run() {
	s.on_running(mut s)
	s.close()
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	run := g.explain('Server.run')
	assert run.contains('on_running (m/s.v:5) [field]'), run
	assert run.contains('close (m/s.v:8) at line 12'), run
	assert run.contains('^ [field] = '), run
	// a declaration that calls no field has no note
	assert !g.explain('Server.close').contains('^ [field]')
}

fn test_a_call_of_a_function_taken_from_an_array_or_map_is_linked_to_its_holder() {
	// `h.list[i](x)` calls a function an array field holds, and `fns['a']()` one a
	// global map holds: the field and the global are the declarations there are, as for
	// `s.on_running(x)`, not some `list` method or `fns` function of another module
	g := graph_of({
		'lib/m/m.v':         'module m\n\nstruct Handlers {\n\tlist  []fn (int)\n\tnamed map[string]fn (int)\n\tdeep  map[string][]fn (int)\n}\n\n__global fns map[string]fn () int\n\n__global count map[string]int\n\n__global made = make_fn()\n\n__global refs &[]fn ()\n\nconst handlers = []fn () int{}\n\nfn make_fn() fn () {\n\treturn fn () {}\n}\n\nfn (h Handlers) run(i int) {\n\th.list[i](1)\n\th.named[\'a\'](2)\n\th.deep[\'a\'][0](3)\n\t_ := fns[\'a\']()\n\tmade()\n\tcount()\n\trefs[0]()\n\t_ := handlers[0]()\n}\n'
		'lib/other/other.v': 'module other\n\npub struct S {}\n\npub fn (s S) list() {}\n\npub fn (s S) named() {}\n\npub fn (s S) deep() {}\n'
		'lib/other/two.v':   'module other\n\npub struct T {}\n\npub fn (t T) list() {}\n\npub fn (t T) named() {}\n'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.m.Handlers.run').map(it.to)
	assert 'lib.m.Handlers.list' in calls, calls.str()
	assert 'lib.m.Handlers.named' in calls, calls.str()
	// a deeper index names nothing, so the only `deep` method is never what it calls
	assert !calls.any(it.contains('deep')), calls.str()
	assert 'lib.m.fns' in calls, calls.str()
	// a global with no stated type is called as a const is; one whose stated type holds
	// no function is never what a call names
	assert 'lib.m.made' in calls, calls.str()
	assert 'lib.m.count' !in calls, calls.str()
	// a reference to functions, and a const typed as a container of them, are called too
	assert 'lib.m.refs' in calls, calls.str()
	assert 'lib.m.handlers' in calls, calls.str()
	// a global whose type only starts with the letters `fn` holds no function
	k := graph_of({
		'lib/k/k.v':        'module k\n\nimport fnv1a\n\n__global h fnv1a.Sum\n\nfn use() {\n\th()\n}\n'
		'lib/fnv1a/sum.v':  'module fnv1a\n\npub struct Sum {}\n'
	})
	assert !k.edges.any(it.kind == .calls && it.from == 'lib.k.use' && it.to == 'lib.k.h'), k.edges.str()
	// container_elem looks through every array, fixed array and map
	assert container_elem('map[string][]fn (int)') == 'fn (int)'
	assert container_elem('[3]map[int]string') == 'string'
	assert container_elem('int') == 'int'
}

fn test_index_representative_ranks_backends() {
	// Backend first (plain/.c.v, then .wasm.v/.native.v, then .js.v), in any
	// order; between files of one backend, the later one, as before.
	decl := fn (file string) Symbol {
		return Symbol{
			id:   'os.f'
			name: 'f'
			kind: .function
			file: file
		}
	}
	js, wasm, c, plain := decl('os/f.js.v'), decl('os/f.wasm.v'), decl('os/f.c.v'), decl('os/f_more.v')
	for syms in [[js, wasm, c], [c, wasm, js], [wasm, c, js], [js, c, wasm]] {
		assert Graph{
			symbols: syms
		}.index().by_id['os.f'].file == 'os/f.c.v'
	}
	assert Graph{
		symbols: [js, wasm]
	}.index().by_id['os.f'].file == 'os/f.wasm.v'
	assert Graph{
		symbols: [c, plain, js]
	}.index().by_id['os.f'].file == 'os/f_more.v'
}

fn test_index_representative_is_the_file_this_host_compiles() {
	// `os.ls` is declared in os_nix.c.v and os_windows.c.v, both for the C backend;
	// the one shown was the later in the graph, os_windows.c.v on macOS too
	decl := fn (file string) Symbol {
		return Symbol{
			id:   'os.ls'
			name: 'ls'
			kind: .function
			file: file
		}
	}
	// the host told at run time: a `$if` on a name the test also gives a variable
	// was not read as the OS
	host := os.user_os()
	nix, win := decl('os/os_nix.c.v'), decl('os/os_windows.c.v')
	own_os := if host == 'windows' { win } else { nix }
	for syms in [[nix, win], [win, nix]] {
		assert Graph{
			symbols: syms
		}.index().by_id['os.ls'].file == own_os.file
	}
	// an OS's own file before the `_default` one V compiles only without it
	default := decl('os/fd_default.c.v')
	own := decl(match host {
		'windows' { 'os/fd_windows.c.v' }
		'macos' { 'os/fd_macos.c.v' }
		else { 'os/fd_linux.c.v' }
	})
	for syms in [[default, own], [own, default]] {
		assert Graph{
			symbols: syms
		}.index().by_id['os.ls'].file == own.file
	}
	// another architecture's file is passed over as another OS's is
	mut here, mut other := decl('os/f_amd64.c.v'), decl('os/f_arm64.c.v')
	$if arm64 {
		here, other = other, here
	}
	for syms in [[here, other], [other, here]] {
		assert Graph{
			symbols: syms
		}.index().by_id['os.ls'].file == here.file
	}
	// the backend comes first: a C file for another OS before the JS backend's
	js := decl('os/os.js.v')
	assert Graph{
		symbols: [win, js]
	}.index().by_id['os.ls'].file == win.file
}

fn test_index_lists_a_shared_id_once_by_name() {
	// Two declarations of one id are not two candidates: a bare-name edge to
	// them resolves, and explain doesn't say the name has 2 declarations.
	g := Graph{
		symbols: [
			Symbol{
				id:   'os.setenv'
				name: 'setenv'
				kind: .function
				file: 'os/environment.c.v'
				line: 1
			},
			Symbol{
				id:   'os.setenv'
				name: 'setenv'
				kind: .function
				file: 'os/environment.js.v'
				line: 1
			},
			Symbol{
				id:   'os.caller'
				name: 'caller'
				kind: .function
				file: 'os/use.v'
				line: 1
			},
		]
		edges:   [Edge{
			from: 'os.caller'
			to:   'setenv'
			kind: .calls
		}]
	}
	idx := g.index()
	assert idx.by_name['setenv'] == ['os.setenv']
	assert idx.edges.any(it.from == 'os.caller' && it.to == 'os.setenv')
	explained := g.explain('setenv')
	assert explained.contains('called by     : caller (os/use.v:1)'), explained
	assert !explained.contains('possibly called by'), explained
}

fn test_receivers_named_by_consts_globals_and_function_fields() {
	g := graph_of({
		'vlib/builtin/str.v': 'module builtin

pub fn (s string) bytes() []u8 {
	return []
}

pub fn (a array) clone() array {
	return a
}
'
		'lib/lib.v':          'module lib

pub struct Response {}

pub fn (r Response) bytes() []u8 {
	return []
}

pub fn (r Response) clone() Response {
	return r
}

pub const args = ["a"]

pub struct Server {
pub:
	on_run fn () = unsafe { nil }
}

pub fn on_run() {
}

@[flag]
pub enum Flags {
	a
	b
}

pub struct Holder {
pub:
	flags Flags
}

pub fn (h Holder) set() {
}
'
		'app/main.v':         'module main

import lib

const preface = "PRI * HTTP/2.0"
const local_server = lib.Server{}

__global counter = lib.Response{}

fn run(h lib.Holder) {
	preface.bytes()
	lib.args.clone()
	counter.clone()
	local_server.on_run()
	h.flags.set(.a)
	h.flags.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	tos := calls.map(it.to)
	assert 'vlib.builtin.string.bytes' in tos // a const's value
	assert 'lib.Response.bytes' !in tos
	assert 'vlib.builtin.array.clone' in tos // another module's const
	assert 'lib.Response.clone' in tos // a global
	// a call through a function-typed field resolves to the field
	assert 'lib.Server.on_run' in tos
	assert 'lib.on_run' !in tos
	// methods V writes for a flag enum, and str(), have no declaration
	for name in ['set', 'str'] {
		e := calls.filter(it.to == name)
		assert e.len == 1 && e[0].provenance == .undeclared, name
	}
	assert 'lib.Holder.set' !in tos
	globals := g.symbols.filter(it.kind == .global)
	assert globals.len == 1 && globals[0].id == 'app.counter'
}

fn test_err_in_an_if_guard_else_is_the_error() {
	g := graph_of({
		'vlib/builtin/err.v': 'module builtin

pub interface IError {
	msg() string
}
'
		'lib/lib.v':          'module lib

pub struct Doc {
	msg string
}

pub fn (d Doc) msg() string {
	return d.msg
}

fn find(x int) !int {
	return x
}

fn run() {
	if n := find(1) {
		println(n)
	} else {
		println(err.msg())
	}
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run')
	assert calls.any(it.to == 'vlib.builtin.IError.msg')
	assert !calls.any(it.to == 'lib.Doc.msg')
}

fn test_a_plain_call_is_its_own_module_or_builtin() {
	// `error()` from a file that imports log is still builtin's: log's needs
	// its prefix
	files := {
		'vlib/builtin/b.v':   'module builtin

pub fn error(s string) int {
	return 0
}
'
		'vlib/builtin/js/b.v': 'module builtin

pub fn error(s string) int {
	return 1
}
'
		'vlib/log/log.v':      'module log

pub fn error(s string) {
}
'
		'lib/a_windows.c.v':   'module lib

import log

fn helper() {
	error("x")
	log.error("y")
}
'
		'lib/a_linux.c.v':     'module lib

fn helper() {
	error("x")
}
'
		'own/own.v':           'module own

fn error(s string) int {
	return 2
}

fn run() {
	error("z")
}
'
	}
	g := graph_of(files)
	// `lib.helper` has a variant per platform; each call's own file places it
	helper := g.edges.filter(it.kind == .calls && it.from == 'lib.helper')
	assert helper.any(it.to == 'vlib.builtin.error')
	assert helper.any(it.to == 'vlib.log.error')
	assert !helper.any(it.to == 'error')
	run := g.edges.filter(it.kind == .calls && it.from == 'own.run')
	assert run.len == 1 && run[0].to == 'own.error'
}

fn test_an_embed_through_a_module_is_that_modules_type() {
	g := graph_of({
		'vlib/veb/context.v':      'module veb

pub struct Response {}

pub fn (mut r Response) set_status(code int) {
}

pub struct Context {
pub mut:
	res Response
}
'
		'vlib/wasm/module.v':      'module wasm

pub struct Module {}

pub fn (mut m Module) new_function(name string) int {
	return 0
}
'
		'vlib/v/gen/wasm/enc.v':   'module wasm

pub struct Module {}

pub fn (mut m Module) new_function(name string) int {
	return 1
}
'
		'examples/veb/example.v':  'module main

pub struct Context {}

fn main() {}
'
		'examples/app/main.v':     'module main

import veb
import wasm

pub struct Context {
	veb.Context
}

struct Math {
	wasm.Module
}

fn (mut ctx Context) handle(mut m Math) {
	ctx.res.set_status(404)
	m.new_function("add")
}

fn main() {}
'
	})
	embeds := g.edges.filter(it.kind == .embeds && it.from == 'examples.app.Context')
	// not the struct itself, nor the standalone program in examples/veb
	assert embeds.len == 1 && embeds[0].to == 'vlib.veb.Context'
	// `import wasm` is vlib/wasm, not vlib/v/gen/wasm
	assert g.edges.any(it.kind == .embeds && it.from == 'examples.app.Math'
		&& it.to == 'vlib.wasm.Module')
	calls := g.edges.filter(it.kind == .calls && it.from == 'examples.app.Context.handle')
	assert calls.any(it.to == 'vlib.veb.Response.set_status')
	assert calls.any(it.to == 'vlib.wasm.Module.new_function')
}

fn test_array_fields_elements_and_generated_methods() {
	g := graph_of({
		'vlib/builtin/b.v': 'module builtin

@[flag]
pub enum ArrayFlags {
	noslices
	noshrink
}

pub struct array {
pub mut:
	flags ArrayFlags
}

pub fn (a array) last() voidptr {
	return unsafe { nil }
}

pub fn (s string) split(d string) []string {
	return []
}

pub fn (s string) trim(c string) string {
	return s
}
'
		'lib/lib.v':        'module lib

pub type Value = int | string

pub struct Buf {}

pub fn (b Buf) trim(c string) Buf {
	return b
}

fn run(xs []int, s string, v Value) {
	if xs.flags.has(.noslices) {
	}
	println(s.split(",").last().trim(" "))
	println(v.type_name())
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run')
	// `last()` is declared as returning voidptr, but is one element
	assert calls.any(it.to == 'vlib.builtin.string.trim')
	// methods V generates: a flag enum's on an array's field, and type_name()
	for name in ['has', 'type_name'] {
		e := calls.filter(it.to == name)
		assert e.len == 1, name
		assert e[0].provenance == .undeclared, name
	}
}

fn test_a_type_named_through_its_module_is_that_modules_type() {
	g := graph_of({
		'vlib/sokol/gfx/gfx.v': 'module gfx

pub struct Image {}

pub struct Pass {}
'
		'vlib/x/json2/any.v':   'module json2

pub struct Any {}
'
		'vlib/db/mysql/db.v':   'module mysql

pub struct DB {}

pub fn connect() DB {
	return DB{}
}
'
		'vlib/db/driver.v':     'module db

\$if mysql ? {
	import db.mysql
}

pub struct DB {}

struct MysqlDriver {
	conn mysql.DB
}

fn open() {
	mysql.connect()
}
'
		'vlib/gg/gg.v':         'module gg

import sokol.gfx
import sokol.gfx { Pass }
import x.json2 as json

pub struct Image {}

pub struct Any {}

pub struct Pass {}

pub struct Slot {
	img   gfx.Image
	imgs  []gfx.Image
	pass  Pass
	local Image
}

pub type Doc = []json.Any | int

fn load(a map[string]json.Any) gfx.Image {
	return gfx.Image{}
}
'
	})
	refs := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .references && it.from == from).map(it.to)
	}
	slot := refs('vlib.gg.Slot')
	// `gfx.Image` is sokol's, though gg declares an Image of its own, and
	// `Pass` comes from the selective import
	assert 'vlib.sokol.gfx.Image' in slot
	assert 'vlib.sokol.gfx.Pass' in slot
	assert 'vlib.gg.Image' in slot // the field written `Image`
	assert 'vlib.gg.Pass' !in slot
	// through an alias, written (`json.Any`) or rendered (`x.json2.Any`)
	assert refs('vlib.gg.load') == ['vlib.x.json2.Any', 'vlib.sokol.gfx.Image']
	assert 'vlib.x.json2.Any' in refs('vlib.gg.Doc')
	assert 'vlib.gg.Any' !in refs('vlib.gg.Doc')
	// an import inside a `$if` names its module as any other does
	assert refs('vlib.db.MysqlDriver') == ['vlib.db.mysql.DB']
	assert g.edges.any(it.kind == .calls && it.from == 'vlib.db.open'
		&& it.to == 'vlib.db.mysql.connect')
}

fn test_a_generic_call_returns_its_type_argument() {
	// every method name is declared twice, in two imported modules, so the
	// call's own file and module don't settle it: only the type does
	g := graph_of({
		'vlib/json/json.v':   'module json

pub struct Any {}

pub fn (a Any) as_map() map[string]Any {
	return {}
}

pub struct Other {}

pub fn (o Other) as_map() int {
	return 0
}

pub fn (o Other) load() {}

pub fn (o Other) describe() {}

pub fn decode[T](s string) !T {
	return T{}
}

pub fn element[T](xs []T) !T {
	return xs[0]
}

pub fn fold[T, R](xs []T, init R) R {
	return init
}
'
		'vlib/models/models.v': 'module models

pub struct Config {}

pub fn (c Config) load() {}

pub fn (c Config) describe() {}
'
		'app/main.v':         'module main

import json
import models

fn run(s string) {
	json.decode[models.Config](s)!.load()
	json.decode[json.Any](s)!.as_map()
	xs := [models.Config{}]
	json.element[models.Config](xs)!.describe()
}

fn run_fold(xs []models.Config) {
	json.fold[models.Config, json.Any](xs, json.Any{}).as_map()
}

fn run_fold_ptr(xs []&models.Config) {
	// the unnamed `&models.Config` leaves the position of `R` intact
	json.fold[&models.Config, json.Any](xs, json.Any{}).as_map()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	assert calls.any(it.to == 'vlib.models.Config.load')
	assert calls.any(it.to == 'vlib.json.Any.as_map')
	assert calls.any(it.to == 'vlib.models.Config.describe')
	// `R` is the second type argument, not the first
	fold := g.edges.filter(it.kind == .calls && it.from == 'app.run_fold')
	assert fold.any(it.to == 'vlib.json.Any.as_map')
	fold_ptr := g.edges.filter(it.kind == .calls && it.from == 'app.run_fold_ptr')
	assert fold_ptr.any(it.to == 'vlib.json.Any.as_map')
	// without type arguments the result is still `T`, so `as_map` (declared
	// twice, so no unique name) stays unresolved
	g2 := graph_of({
		'vlib/json/json.v': 'module json

pub struct Any {}

pub fn (a Any) as_map() map[string]Any {
	return {}
}

pub struct Other {}

pub fn (o Other) as_map() int {
	return 0
}

pub fn decode[T](s string) !T {
	return T{}
}
'
		'app/main.v': 'module main

import json

fn run(s string) {
	json.decode(s)!.as_map()
}
'
	})
	untyped := g2.edges.filter(it.kind == .calls && it.from == 'app.run' && it.to.ends_with('as_map'))
	assert untyped.len == 1
	// still the raw name: neither declaration is picked
	assert untyped[0].to == 'as_map'
}


fn test_a_generic_receiver_substitutes_its_type_arguments() {
	// `load`, `describe` and `as_map` are each declared on two types, so the
	// receiver's type alone settles which one a call means
	g := graph_of({
		'vlib/json/json.v':    'module json

pub struct Any {}

pub fn (a Any) as_map() map[string]Any {
	return {}
}

pub struct Other {}

pub fn (o Other) load() {}

pub fn (o Other) describe() {}

pub fn (o Other) as_map() int {
	return 0
}
'
		'vlib/models/models.v': 'module models

pub struct Config {}

pub fn (c Config) load() {}

pub fn (c Config) describe() {}

pub struct Queue[T] {
pub mut:
	items []T
}

pub fn (q &Queue[T]) pop() !T {
	return q.items[0]
}
'
		'app/main.v':          'module main

import json
import models

fn run() {
	q := models.Queue[models.Config]{}
	q.pop()!.load()
	q.items[0].describe()
	r := models.Queue[json.Any]{}
	r.pop()!.as_map()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run')
	assert calls.any(it.to == 'vlib.models.Config.load')
	assert calls.any(it.to == 'vlib.models.Config.describe')
	assert calls.any(it.to == 'vlib.json.Any.as_map')
	assert !calls.any(it.to == 'vlib.json.Other.as_map')
}

fn test_a_smartcast_or_match_branch_types_its_variable() {
	// `area` is declared on both variants, so only the narrowed type settles
	// a call on the sum type's value
	g := graph_of({
		'lib/shapes.v': 'module shapes

pub struct Circle {
	r int
}

pub fn (c Circle) area() int {
	return c.r
}

pub struct Square {
	s int
}

pub fn (s Square) area() int {
	return s.s
}

pub fn (s Square) name() string {
	return "square"
}

pub fn (sh Shape) name() string {
	return ""
}

pub type Shape = Circle | Square

pub fn total(sh Shape) int {
	mut n := 0
	match sh {
		Circle {
			n += sh.area()
		}
		Square {
			n += sh.area()
		}
		else {}
	}
	if sh is Circle && sh.area() > 0 {
		n += 1
	}
	// `name` is on the sum type, not on Circle: the declared type answers
	if sh is Circle && sh.name() == "" {
		n += 2
	}
	return n
}

pub fn (sh Shape) describe() int {
	match sh {
		Circle {
			return sh.area()
		}
		else {
			return 0
		}
	}
}
'
	})
	total := g.edges.filter(it.kind == .calls && it.from == 'lib.total')
	assert total.any(it.to == 'lib.Circle.area')
	assert total.any(it.to == 'lib.Square.area')
	assert !total.any(it.to == 'area')
	// the receiver `sh` is narrowed to a Circle, not the sum type
	assert total.any(it.to == 'lib.Shape.name')
	assert !total.any(it.to == 'lib.Square.name')
	describe := g.edges.filter(it.kind == .calls && it.from == 'lib.Shape.describe')
	assert describe.any(it.to == 'lib.Circle.area')
}

fn test_a_type_check_narrows_values_the_else_branch_and_what_follows() {
	// `label` and `wide` are each declared on two types, so only the type a
	// check narrows to settles a call
	g := graph_of({
		'lib/kinds.v': 'module lib

pub struct Alias {
	base Kind
}

pub struct Prim {
	bits int
}

pub type Kind = Alias | Prim

pub fn (k Kind) label() string {
	return ""
}

pub fn (p Prim) wide() bool {
	return p.bits > 32
}

pub struct Other {}

pub fn (o Other) label() string {
	return ""
}

pub fn (o Other) wide() bool {
	return false
}

pub fn if_value(k Kind) string {
	c := if k is Alias { k.base } else { k }
	return c.label()
}

pub fn match_value(k Kind) string {
	c := match k {
		Alias { k.base }
		else { k }
	}
	return c.label()
}

pub fn field_match(a Alias) string {
	b := match a.base {
		Alias { a.base.base }
		else { a.base }
	}
	return b.label()
}

pub fn field_if(a Alias) bool {
	if a.base is Prim {
		return a.base.wide()
	}
	return false
}

pub fn or_rhs(k Kind) bool {
	return k !is Prim || k.wide()
}

pub fn after_return(k Kind) bool {
	if k !is Prim {
		return false
	}
	return k.wide()
}

pub fn in_else(k Kind) bool {
	if k !is Prim {
		println("no")
	} else {
		return k.wide()
	}
	return false
}

pub fn not_after(k Kind) bool {
	if k !is Prim {
		println("no")
	}
	return k.wide()
}
'
	})
	calls := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.from == from).map(it.to)
	}
	for f in ['if_value', 'match_value', 'field_match'] {
		assert 'lib.Kind.label' in calls('lib.${f}'), f
	}
	for f in ['field_if', 'or_rhs', 'after_return', 'in_else'] {
		assert 'lib.Prim.wide' in calls('lib.${f}'), f
	}
	// a block that runs on narrows nothing after it
	assert 'lib.Prim.wide' !in calls('lib.not_after')
}

fn test_receivers_through_shared_fields_called_fields_slices_and_spreads() {
	// `show` is declared on two types, so only the receiver's type settles a call
	g := graph_of({
		'lib/lib.v':      'module lib

import lib2

pub struct Name {}

pub fn (n Name) show() string {
	return ""
}

pub struct Other {}

pub fn (o Other) show() string {
	return ""
}

pub fn (ns []Name) all_show() {}

pub fn (os []Other) all_show() {}

pub struct Bare {
	text Name
}

pub struct Quoted {
	text Name
	q    int
}

pub type Key = Bare | Quoted

pub fn shared_field(k Key) string {
	return k.text.show()
}

pub type Some = Bare | Holder

pub fn partial_field(s Some) string {
	return s.text.show()
}

pub struct Pool {
	factory fn () Name
}

pub fn called_field(p Pool) string {
	n := p.factory()
	return n.show()
}

pub fn fixed_slice(a [3]Name) {
	a[..].all_show()
}

pub struct Store {
mut:
	items []Name
}

pub fn locked(shared s Store) string {
	n := rlock s {
		s.items[0]
	}
	return n.show()
}

pub fn branch_local(ns []Name, ok bool) string {
	n := if ok {
		first := ns[0]
		first
	} else {
		panic("none")
	}
	return n.show()
}

pub struct Holder {
	name Name
}

pub fn spread(h Holder) string {
	c := Holder{
		...h
	}
	return c.name.show()
}

pub struct Buf {
	data &Name
}

pub fn pointer_index(b Buf) string {
	return unsafe { b.data[1].show() }
}

pub fn attrs[T]() {
	\$for a in T.attributes {
		a.arg.show()
	}
}

pub fn decoded() {
	for x in lib2.decode[[]Name]("") {
		x.show()
	}
}

@[flag]
pub enum Hints {
	a
	b
}

pub fn zero_flags() bool {
	mut h := Hints.zero()
	h.set(.a)
	return h.has(.b)
}
'
		'lib2/dec.v':     'module lib2

pub fn decode[T](s string) T {
	return T{}
}
'
		'builtin/meta.v': 'module builtin

pub struct Tag {}

pub fn (t Tag) show() string {
	return ""
}

pub struct VAttribute {
pub:
	arg Tag
}
'
		// a `main` module that is one program reads its consts from any of its files
		'app/consts.v':   'module main

const settings = make()

struct Conf {
	name Label
}

struct Label {}

fn (l Label) show() string {
	return ""
}

struct Spare {}

fn (s Spare) show() string {
	return ""
}

fn make() Conf {
	return Conf{}
}
'
		'app/main.v':     'module main

fn main() {
	settings.name.show()
}
'
	})
	calls := fn [g] (from string) []Edge {
		return g.edges.filter(it.kind == .calls && it.from == from)
	}
	for f in ['shared_field', 'called_field', 'locked', 'branch_local', 'spread', 'pointer_index',
		'decoded'] {
		assert calls('lib.${f}').any(it.to == 'lib.Name.show'), f
	}
	// a field only some variants have is not the sum type's
	assert !calls('lib.partial_field').any(it.to == 'lib.Name.show')
	assert calls('lib.fixed_slice').any(it.to == 'lib.[]Name.all_show')
	assert calls('lib.attrs').any(it.to == 'builtin.Tag.show')
	assert calls('app.main').any(it.to == 'app.Label.show')
	// a `@[flag]` enum's `zero()` is a value of it, whose `has` and `set` V provides
	for e in calls('lib.zero_flags').filter(it.to in ['has', 'set']) {
		assert e.provenance == .undeclared, e.to
	}
	assert calls('lib.zero_flags').filter(it.to in ['has', 'set']).len == 2
}

fn test_an_unsafe_block_and_an_untyped_map_literal_have_types() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub struct Thing {
	name string
}

pub fn (t Thing) describe() int {
	return 1
}

pub struct Other {}

pub fn (o Other) describe() int {
	return 2
}

fn run(xs []Thing) int {
	b := unsafe { xs[0] }
	m := {
		\'name\': \'Joe\'
	}
	s := m.str()
	return b.describe() + s.len
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run')
	// the block's value is the element, a Thing
	assert calls.any(it.to == 'lib.Thing.describe')
	assert !calls.any(it.to == 'lib.Other.describe')
	// a map's `str()` is one V writes, so no declaration to resolve to
	str := calls.filter(it.to == 'str')
	assert str.len == 1 && str[0].provenance == .undeclared
}

fn test_files_of_one_program_see_each_other_but_separate_programs_do_not() {
	g := graph_of({
		'prog/a.v':   'module main

fn main() {
	helper_one()
}
'
		'prog/b.v':   'module main

fn helper_one() {
}
'
		'two/a.v':    'module main

fn main() {
	helper_two()
}
'
		'other/c.v':  'module main

fn helper_two() {
}
'
		'two/b.v':    'module main

fn helper_two() {
}

fn main() {
}
'
	})
	// one `fn main` in `prog`: its other files are the same program
	assert g.edges.any(it.kind == .calls && it.from == 'prog.main' && it.to == 'prog.helper_one')
	// two mains in `two`: two programs, so `helper_two` (also declared in
	// `other`) is not visible from `a.v`
	assert !g.edges.any(it.kind == .calls && it.from == 'two.main' && it.to == 'two.helper_two')
}

fn test_a_call_to_a_per_platform_function_reaches_every_variant() {
	// `open_dir` is declared once per platform in the caller's program. The call
	// can't say which platform runs it, and the graph is the same on every one,
	// so it links to both variants. The renaming step is what makes them distinct.
	files := {
		'prog/main.v':          'module main

fn main() {
	open_dir()
}
'
		'prog/dir_nix.c.v':     'module main

fn open_dir() {
}
'
		'prog/dir_windows.c.v': 'module main

fn open_dir() {
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	resolve_edges(mut g)
	targets := g.edges.filter(it.kind == .calls && it.from == 'prog.main').map(it.to)
	assert targets.sorted() == ['prog.open_dir@prog/dir_nix.c.v', 'prog.open_dir@prog/dir_windows.c.v'], targets.str()
}

fn test_calls_in_constant_global_and_field_initializers_come_from_their_declaration() {
	g := graph_of({
		'app/app.v': 'module app

pub struct Holder {
pub:
	n int = make_n(3)
}

const answer = make_n(7)

__global counter = make_n(9)

fn make_n(x int) int {
	return x
}
'
	})
	// each initializer is a caller of `make_n`, as a function body is
	for from in ['app.Holder.n', 'app.answer', 'app.counter'] {
		assert g.edges.any(it.kind == .calls && it.from == from && it.to == 'app.make_n'), from
	}
}

fn test_a_constant_named_like_a_function_keeps_its_own_initializer_calls() {
	// `test_it` is a function in one file and a constant in another, so the
	// constant gets its own id, and its initializer's call is its own, not the
	// function's.
	files := {
		'lib/a.v': 'module lib

const test_it = make_n(4)
'
		'lib/b.v': 'module lib

pub fn test_it() int {
	return 1
}

fn make_n(x int) int {
	return x
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	assert g.edges.any(it.kind == .calls && it.from == 'lib::const::test_it' && it.to == 'lib.make_n'), g.edges.map(it.from).str()
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.test_it'), g.edges.map(it.from).str()
}

fn test_a_flag_enums_zero_is_undeclared() {
	g := graph_of({
		'lib/lib.v': 'module lib

@[flag]
pub enum Show {
	a
	b
}

pub fn default_show() Show {
	return Show.zero()
}
'
	})
	// V provides `zero()` on a flag enum, so the call is undeclared, not unresolved
	assert g.edges.any(it.kind == .calls && it.from == 'lib.default_show' && it.provenance == .undeclared), g.edges.map(it.from).str()
}

fn test_a_zero_on_an_enum_that_is_not_a_flag_enum_is_not_undeclared() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub enum Show {
	a
	b
}

pub fn default_show() Show {
	return Show.zero()
}
'
	})
	// V makes `zero()` only for a @[flag] enum, so on this one the call is not V's
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.default_show' && it.provenance == .undeclared), g.edges.map(it.from).str()
	assert g.edges.any(it.kind == .calls && it.from == 'lib.default_show' && it.to == 'Show__static__zero'), g.edges.map(it.from).str()
}

fn test_a_zero_takes_the_flag_of_the_enum_the_callers_file_declares() {
	g := graph_of({
		'lib/tests/flagged_test.v': 'module tests

@[flag]
enum Pick {
	a
	b
}

fn flagged_zero() Pick {
	return Pick.zero()
}
'
		'lib/tests/plain_test.v':   'module tests

enum Pick {
	x
	y
}

fn plain_zero() Pick {
	return Pick.zero()
}
'
	})
	// each _test.v file is its own program, so each caller sees the `Pick` its own file declares
	assert g.edges.any(it.kind == .calls && it.from == 'lib.tests.flagged_zero' && it.provenance == .undeclared), g.edges.map(it.from).str()
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.tests.plain_zero' && it.provenance == .undeclared), g.edges.map(it.from).str()
}

// `json.decode[AnyStruct[json.Any]](s)!.val.int()`: the type argument is a generic struct, so `val` is a `json.Any` and its `int()` is that type's. A second `int` method the file also imports keeps the name alone from deciding it.
fn test_a_generic_struct_as_a_type_argument_types_its_field() {
	g := graph_of({
		'lib/json2/json.v': 'module json2

pub struct Any {}

pub fn (f Any) int() int {
	return 0
}

pub fn decode[T](s string) !T {
	return T{}
}
'
		'lib/alt/alt.v': 'module alt

pub struct Bar {}

pub fn (b Bar) int() int {
	return 0
}
'
		'lib/tests/t_test.v': 'module tests

import lib.json2 as json
import lib.alt

struct AnyStruct[T] {
	val T
}

fn test_values() {
	json.decode[AnyStruct[json.Any]](\'\')!.val.int()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.test_values')
	assert calls.any(it.to == 'lib.json2.Any.int' && it.provenance == .inferred), g.edges.map(it.to).str()
	assert !calls.any(it.to == 'lib.alt.Bar.int' || it.to == 'int'), g.edges.map(it.to).str()
}

// a module declares `value` on `[]Any` and on `map[string]Any`, and a file that imports it
// reaches them as `[]toml.Any` and `map[string]toml.Any`: the method is found by the module its types come from
fn test_a_method_on_an_array_or_map_of_a_module_type_is_found_by_its_owner() {
	g := graph_of({
		'lib/toml/any.v': 'module toml

pub struct Any {}

pub fn (a []Any) value(key string) Any {
	return Any{}
}

pub fn (m map[string]Any) value(key string) Any {
	return Any{}
}
'
		'lib/tests/t_test.v': 'module tests

import lib.toml

fn test_values() {
	a := []toml.Any{}
	a.value(\'x\')
	m := map[string]toml.Any{}
	m.value(\'x\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.test_values')
	assert calls.any(it.to == 'lib.toml.[]Any.value' && it.provenance == .inferred), g.edges.map(it.to).str()
	assert calls.any(it.to == 'lib.toml.map[string]Any.value' && it.provenance == .inferred), g.edges.map(it.to).str()
}

// `items.map(it.name).join(',')`: the map states no result, so its elements are a type the graph doesn't know, and `join` is declared on `[]string` alone, so the call is that array's join
fn test_a_join_on_a_map_with_no_stated_result_is_the_array_join() {
	g := graph_of({
		'lib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (a array) map(callback fn (voidptr) voidptr) array {
	return array{}
}

pub fn (a []string) join(sep string) string {
	return \'\'
}
'
		'lib/other/other.v': 'module other

pub struct Builder {}

pub fn (b Builder) join(sep string) string {
	return \'\'
}
'
		'lib/tests/t_test.v': 'module tests

import lib.other

struct Item {
	name string
}

fn names(items []Item) string {
	return items.map(it.name).join(\',\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.names')
	assert calls.any(it.to == 'lib.builtin.[]string.join' && it.provenance == .inferred), g.edges.map(it.to).str()
}

// `bs.repeat(2).hex()`: builtin's `repeat` returns an untyped `array`, which hides the element type, but a repeat keeps its elements, so the result is a `[]u8` and `hex` is that type's. A second `hex` the file imports keeps the name alone from deciding it.
fn test_a_repeat_keeps_the_element_type_of_the_array_it_repeats() {
	g := graph_of({
		'lib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (a array) repeat(count int) array {
	return array{}
}

pub fn (b []u8) hex() string {
	return \'\'
}
'
		'lib/other/other.v': 'module other

pub struct Enc {}

pub fn (e Enc) hex() string {
	return \'\'
}
'
		'lib/tests/t_test.v': 'module tests

import lib.other

fn digits(bs []u8) string {
	return bs.repeat(2).hex()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.digits')
	assert calls.any(it.to == 'lib.builtin.[]u8.hex' && it.provenance == .inferred), g.edges.map(it.to).str()
}

// `semver.from(s)` inside `module semver` calls the module's own `from`, not a method on a global named `semver`, so the call and the `satisfies` on its result are the module's
fn test_a_call_through_the_files_own_module_name_is_a_module_call() {
	g := graph_of({
		'lib/semver/semver.v': 'module semver

pub struct Version {}

pub fn from(s string) !Version {
	return Version{}
}

pub fn (v Version) satisfies(r string) bool {
	return true
}
'
		'lib/other/other.v': 'module other

pub fn from(s string) string {
	return s
}

pub struct Other {}

pub fn (o Other) satisfies(r string) bool {
	return true
}

pub fn (o Other) from(s string) bool {
	return true
}
'
		'lib/semver/check_test.v': 'module semver

fn check() bool {
	v := semver.from(\'0.1.0\') or { return false }
	return v.satisfies(\'x\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.semver.check')
	assert calls.any(it.to == 'lib.semver.from'), g.edges.map(it.to).str()
	assert calls.any(it.to == 'lib.semver.Version.satisfies'), g.edges.map(it.to).str()
}

// `v.satisfies(...)` on the result of `semver.from(...)` inside `module semver` is `Version`'s method. The
// module has another `satisfies`, so the name alone can't pick one: the result's type has to come through
// the module's own name, which the recipe spells with the module id (`lib.semver.from`).
fn test_a_method_on_a_module_call_result_is_typed_through_the_module_name() {
	g := graph_of({
		'lib/semver/semver.v': 'module semver

pub struct Version {}

pub fn from(s string) !Version {
	return Version{}
}

pub fn (v Version) satisfies(r string) bool {
	return true
}

pub struct Range {}

pub fn (r Range) satisfies(v Version) bool {
	return true
}
'
		'lib/semver/check_test.v': 'module semver

fn check() bool {
	v := semver.from(\'0.1.0\') or { return false }
	return v.satisfies(\'x\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.semver.check')
	assert calls.any(it.to == 'lib.semver.Version.satisfies'), g.edges.map(it.to).str()
}

fn test_a_per_platform_call_returns_the_type_its_variants_share() {
	// `open_it` is declared once per platform in a standalone program, so its
	// variants are renamed apart. They return the same type, so the receiver is typed.
	files := {
		'prog/main.v': 'module main

pub struct Doc {
	s string
}

pub struct Other {}

pub fn (d Doc) contains(x string) bool {
	return d.s == x
}

pub fn (o Other) contains(x string) bool {
	return x == \'\'
}

fn main() {
	println(per_platform())
}

fn per_platform() bool {
	d := open_it() or { return false }
	return d.contains(\'a\')
}
'
		'prog/p_nix.c.v': 'module main

fn open_it() ?Doc {
	return Doc{}
}
'
		'prog/p_windows.c.v': 'module main

fn open_it() ?Doc {
	return Doc{}
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	assert g.edges.any(it.kind == .calls && it.from == 'prog.per_platform' && it.to == 'prog.Doc.contains'), g.edges.map(it.to).str()
}

fn test_a_method_with_a_copy_per_platform_reaches_every_copy() {
	files := {
		'prog/main.v': 'module main

pub struct Doc {
	s string
}

pub struct Other {}

pub fn (o Other) close() bool {
	return false
}

fn main() {
	println(run())
}

fn run() bool {
	d := Doc{}
	return d.close()
}
'
		'prog/p_nix.c.v': 'module main

pub fn (d Doc) close() bool {
	return true
}
'
		'prog/p_windows.c.v': 'module main

pub fn (d Doc) close() bool {
	return true
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	targets := g.edges.filter(it.kind == .calls && it.from == 'prog.run').map(it.to)
	assert targets.contains('prog.Doc.close@prog/p_nix.c.v') && targets.contains('prog.Doc.close@prog/p_windows.c.v'), targets.str()
}

fn test_a_fixed_size_array_literal_has_the_type_of_its_elements() {
	// `['a', 'b']!` is a fixed-size array, so its loop variable is a string
	g := graph_of({
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) to_lower() string {
	return s
}
'
		'vlib/builtin/rune.v': 'module builtin

pub fn (r rune) to_lower() rune {
	return r
}
'
		'vlib/net/n.v': 'module net

const names = [\'Jan\', \'Feb\']!

pub fn loop() string {
	mut out := \'\'
	for m in names {
		out = m.to_lower()
	}
	return out
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'vlib.net.loop' && it.to == 'vlib.builtin.string.to_lower'), g.edges.map(it.to).str()
}

fn test_a_call_of_a_function_parameter_has_its_return_type() {
	g := graph_of({
		'm/f.v': 'module m

pub struct Doc {
	s string
}

pub struct Other {}

pub fn (d Doc) contains(x string) bool {
	return d.s == x
}

pub fn (o Other) contains(x string) bool {
	return x == \'\'
}

pub fn via_param(h fn () Doc) bool {
	d := h()
	return d.contains(\'a\')
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'm.via_param' && it.to == 'm.Doc.contains'), g.edges.map(it.to).str()
}

fn test_a_generic_call_with_a_map_type_argument_types_its_elements() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub struct Any {}

pub fn (a Any) str() string {
	return \'\'
}

pub struct Other {}

pub fn (o Other) str() string {
	return \'\'
}

pub fn decode[T](s string) !T {
	return error(s)
}
'
		'app/app.v': 'module app

import lib

pub fn field(json_text string, key string) string {
	parsed := lib.decode[map[string]lib.Any](json_text) or { return \'\' }
	value := parsed[key] or { return \'\' }
	return value.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.field' && it.to == 'lib.Any.str'), g.edges.map(it.to).str()
}

fn test_a_comptime_field_loop_variable_is_a_field_data() {
	g := graph_of({
		'vlib/builtin/meta.v': 'module builtin

pub struct FieldData {
pub:
	name  string
	attrs []string
}
'
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) contains(x string) bool {
	return s == x
}
'
		'vlib/lib/lib.v': 'module lib

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return x == \'\'
}
'
		'app/app.v': 'module app

import vlib.lib

fn walk[T]() bool {
	mut ok := false
	$for field in T.fields {
		for attr in field.attrs {
			ok = attr.contains(\'a\')
		}
	}
	return ok
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.walk' && it.to == 'vlib.builtin.string.contains'), g.edges.map(it.to).str()
}

fn test_a_member_of_an_enum_is_a_value_of_the_enum_type() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub enum Colour {
	red
	green
}

pub fn (c Colour) str() string {
	return \'\'
}

pub enum Shade {
	dark
}

pub fn label() string {
	return Colour.green.str()
}

pub fn shade() string {
	return Shade.dark.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'lib.label' && it.to == 'lib.Colour.str'), g.edges.map(it.to).str()
	assert g.edges.any(it.kind == .calls && it.from == 'lib.shade' && it.to == 'str' && it.provenance == .undeclared), g.edges.map(it.to).str()
}

fn test_a_str_of_a_type_that_declares_none_is_a_string() {
	g := graph_of({
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) contains(x string) bool {
	return s == x
}
'
		'lib/lib.v': 'module lib

pub struct Node {
	id int
}

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return x == \'\'
}

pub fn has_id(n Node) bool {
	return n.str().contains(\'1\')
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'lib.has_id' && it.to == 'vlib.builtin.string.contains'), g.edges.map(it.to).str()
}

fn test_a_generic_type_argument_written_with_an_import_alias_is_named_in_full() {
	g := graph_of({
		'vlib/json2/decode.v': 'module json2

pub type Any = bool | int

pub fn decode[T](val string) !T {
	return error(val)
}
'
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
		'app/app.v': 'module app

import json2 as json

fn show(s string) string {
	blocks := json.decode[[]map[string]json.Any](s) or {
		return \'\'
	}
	for block in blocks {
		value := block[\'text\'] or {
			continue
		}
		return value.str()
	}
	return \'\'
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'str' && it.provenance == .undeclared), g.edges.map(it.to).str()
}

fn test_an_import_of_an_alias_directory_is_the_module_it_aliases() {
	// vlib/x/json2 holds only `@[alias]`, so `import x.json2` is vlib/json2
	root := write_tree('alias_dir', {
		'vlib/json2/types.v':  'module json2

pub type Any = bool | int

pub fn decode[T](val string) !T {
	return error(val)
}
'
		'vlib/x/json2/alias.v': "@[alias: '@VMODROOT/vlib/json2']
module json2
"
		'app/app.v':           'module app

import x.json2

fn show(s string) int {
	return json2.decode[int](s) or { 0 }
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'vlib.json2.decode'), g.edges.filter(it.from == 'app.show').map(it.to).str()
}

fn test_a_str_of_a_map_of_runes_is_undeclared_not_a_str_of_another_type() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub fn f() string {
	m := {
		\'a\': `a`
	}
	return m.str()
}
'
		'node/node.v': 'module node

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
	})
	// a map's str() is one V writes, so no declaration to resolve to; the rune
	// values give the map its type, and the name `str` must not match Node.str
	assert g.edges.any(it.kind == .calls && it.from == 'lib.f' && it.to == 'str' && it.provenance == .undeclared), g.edges.map(it.to).str()
}

fn test_comptime_is_narrows_a_type_parameter_receiver() {
	// `other.Node.str` is the competing str(): lib imports it too, so the
	// name fallback sees two reachable str() methods and settles nothing
	g := graph_of({
		'leaf/leaf.v':  'module leaf

pub struct Leaf {}

pub fn (l Leaf) str() string {
	return \'leaf\'
}
'
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return \'node\'
}
'
		'lib/lib.v':    'module lib

import leaf
import other

pub fn render[T](value T) string {
	_ = other.Node{}
	$if T is leaf.Leaf {
		return value.str()
	} $else {
		return \'\'
	}
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'lib.render' && it.to == 'leaf.Leaf.str'), g.edges.map(it.to).str()
}

fn test_comptime_is_narrows_a_variable_of_a_type_parameter() {
	g := graph_of({
		'leaf/leaf.v':  'module leaf

pub struct Leaf {}

pub fn (l Leaf) str() string {
	return \'leaf\'
}
'
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return \'node\'
}
'
		'lib/lib.v':    'module lib

import leaf
import other

pub fn describe[T](data T) string {
	_ = other.Node{}
	$if data is leaf.Leaf {
		return data.str()
	}
	return \'\'
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'lib.describe' && it.to == 'leaf.Leaf.str'), g.edges.map(it.to).str()
}

fn test_comptime_is_on_an_interface_names_no_type() {
	// V's `T is Shape` holds for every T implementing Shape, so the block's T is
	// not the interface: the call is not Shape.str, and lib imports Node's str()
	// too, so the name fallback cannot pick Shape's either
	g := graph_of({
		'shape/shape.v': 'module shape

pub interface Shape {
	str() string
}
'
		'other/node.v':  'module other

pub struct Node {}

pub fn (n Node) str() string {
	return \'node\'
}
'
		'lib/lib.v':     'module lib

import shape
import other

pub fn draw[T](value T) string {
	_ = other.Node{}
	$if T is shape.Shape {
		return value.str()
	}
	return \'\'
}
'
	})
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.draw' && it.to.contains('Shape')), g.edges.map(it.to).str()
}

fn test_a_const_whose_value_is_a_comptime_if_has_the_type_of_its_branches() {
	// vlib/builtin's max_int is `$if ... { int(...) } $else { int(...) }`: both
	// branches are an int, so the const is one, whichever branch V keeps
	g := graph_of({
		'vlib/builtin/int.v': 'module builtin

pub fn (i int) str() string {
	return \'\'
}
'
		'node/node.v': 'module node

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
		'lib/lib.v': 'module lib

import node

pub const limit = $if x64 { int(1) } $else { int(2) }

pub fn f() string {
	_ = node.Node{}
	return limit.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'lib.f' && it.to == 'vlib.builtin.int.str'), g.edges.map(it.to).str()
}

fn test_a_comptime_if_value_passes_over_a_branch_only_an_option_selects() {
	// max_int is now `$if cross ? { portable_max_int() } $else $if new_int ? && x64 {
	// int(max_i64) } $else { int(max_i32) }`: the branches' recipes differ, but the
	// first two need `-d`, so the default build's value is the last one's, an int. A
	// value whose branches differ in builds a host picks by itself stays untyped.
	g := graph_of({
		'vlib/builtin/int.v': 'module builtin

pub fn (i int) str() string {
	return \'\'
}
'
		'node/node.v': 'module node

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
		'lib/lib.v': 'module lib

import node

fn portable() node.Node {
	return node.Node{}
}

pub const limit = \$if cross ? {
	portable()
} \$else \$if new_int ? && x64 {
	int(2)
} \$else {
	int(3)
}

pub const host = \$if linux {
	node.Node{}
} \$else {
	int(3)
}

pub const fast = \$if prod {
	node.Node{}
} \$else {
	int(3)
}

pub const negated = \$if !cross ? {
	node.Node{}
} \$else {
	int(3)
}

pub fn f() string {
	return limit.str()
}

pub fn g() string {
	return host.str()
}

pub fn p() string {
	return fast.str()
}

pub fn q() string {
	return negated.str()
}
'
	})
	// `prod` needs `-prod`, as an option_terms name, so the default build's value is
	// the `\$else`'s; `!cross ?` holds by default, so its branches differ in a build
	// the host picks and the value stays untyped
	assert g.edges.any(it.kind == .calls && it.from == 'lib.p' && it.to == 'vlib.builtin.int.str'), g.edges.filter(it.from == 'lib.p').str()
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.q' && it.to in ['vlib.builtin.int.str', 'node.Node.str']), g.edges.filter(it.from == 'lib.q').str()
	assert g.edges.any(it.kind == .calls && it.from == 'lib.f' && it.to == 'vlib.builtin.int.str'), g.edges.map(it.to).str()
	// the option's branch is a Node, so taking it would give Node.str
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.f' && it.to == 'node.Node.str')
	assert !g.edges.any(it.kind == .calls && it.from == 'lib.g' && it.to in ['vlib.builtin.int.str', 'node.Node.str']), g.edges.filter(it.from == 'lib.g').str()
}

fn test_shared_declaration_names_its_local() {
	g := graph_of({
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return ""
}
'
		'app/app.v':    'module app

import other

pub struct Abc {
mut:
	x f64
}

pub fn show() string {
	shared s := Abc{
		x: 6.25
	}
	astr := rlock s {
		s.str()
	}
	return astr
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show').map(it.to).str()
}

fn test_qualified_enum_const_is_its_enum() {
	g := graph_of({
		'gg/text.v':    'module gg

pub enum HorizontalAlign {
	left
	right
}
'
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return ""
}
'
		'app/app.v':    'module app

import gg
import other

const left = gg.HorizontalAlign.left

pub fn show() string {
	align := left
	return align.str()
}

pub fn show_direct() string {
	return gg.HorizontalAlign.left.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show').map(it.to).str()
	assert g.edges.any(it.kind == .calls && it.from == 'app.show_direct' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show_direct').map(it.to).str()
}

fn test_orm_select_block_is_a_list_of_its_table() {
	g := graph_of({
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return ""
}
'
		'app/app.v':    'module app

import other

pub struct Address {
	id int
}

pub fn show(db DB) string {
	x1 := sql db {
		select from Address
	}!
	return x1.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show').map(it.to).str()
}

fn test_enum_member_keys_type_a_map_literal() {
	g := graph_of({
		'other/node.v': 'module other

pub struct Node {}

pub fn (n Node) str() string {
	return ""
}
'
		'app/app.v':    'module app

import other

pub enum Animal {
	cat
	dog
}

pub fn show() string {
	map_1 := {
		Animal.cat: "gato"
		.dog:       "perro"
	}
	return map_1.str()
}

pub fn show_values() string {
	map_2 := {
		"gato":  Animal.cat
		"perro": .dog
	}
	return map_2.str()
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.show' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show').map(it.to).str()
	assert g.edges.any(it.kind == .calls && it.from == 'app.show_values' && it.to == 'str' && it.provenance == .undeclared), g.edges.filter(it.from == 'app.show_values').map(it.to).str()
}

fn test_plain_local_method_stays_in_its_own_test_file() {
	// two `_test.v` files of one module, each with its own Alarms; V compiles each
	// as its own program, so one_test.v's add is not visible from two_test.v
	g := graph_of({
		'pkg/one_test.v': 'module pkg

pub struct Alarms {}

pub fn (a Alarms) add(x int) {}
'
		'pkg/two_test.v': 'module pkg

pub struct Alarms {}

pub fn (shared a Alarms) add(x int) {}

pub fn show() {
	a := Alarms{}
	a.add(1)
}
'
	})
	assert !g.edges.any(it.kind == .calls && it.from == 'pkg.show' && it.to == 'pkg.Alarms.add'), g.edges.filter(it.from == 'pkg.show').map(it.to).str()
}

fn test_e16_wait_of_a_spawned_call_is_the_callees_result() {
	g := graph_of({
		'other/other.v':         'module other

pub struct Box {}

pub fn (b Box) str() string {
	return \'\'
}
'
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) str() string {
	return s
}
'
		'lib/lib.v':             'module lib

import other

fn name() string {
	return \'x\'
}

pub fn run() string {
	res := (spawn name()).wait()
	return res.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run' && it.to.ends_with('str'))
	assert calls.len == 1 && calls[0].to == 'vlib.builtin.string.str', calls.map(it.to).str()
}

fn test_e16_str_of_a_thread_is_compiler_provided() {
	g := graph_of({
		'other/other.v': 'module other

pub struct Box {}

pub fn (b Box) str() string {
	return \'\'
}
'
		'lib/lib.v':     'module lib

import other

fn ret() int {
	return 1
}

pub fn run() string {
	th := spawn ret()
	return th.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run' && it.to.ends_with('str'))
	assert calls.len == 1 && calls[0].to == 'str' && calls[0].provenance == .undeclared, calls.map(it.to).str()
}

fn test_e16_str_of_a_field_of_a_c_struct_is_the_fields_type() {
	g := graph_of({
		'other/other.v':        'module other

pub struct Box {}

pub fn (b Box) str() string {
	return \'\'
}
'
		'vlib/builtin/i32.v': 'module builtin

pub fn (n i32) str() string {
	return \'\'
}
'
		'lib/lib.v':            'module lib

import other

pub struct C.addrinfo {
	ai_family i32
}

pub fn family(ai &C.addrinfo) string {
	return ai.ai_family.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.family' && it.to.ends_with('str'))
	assert calls.len == 1 && calls[0].to == 'vlib.builtin.i32.str', calls.map(it.to).str()
}

fn test_e16_a_logical_right_shift_has_the_unsigned_type_of_its_operand() {
	g := graph_of({
		'other/other.v':         'module other

pub struct Box {}

pub fn (b Box) str() string {
	return \'\'
}
'
		'vlib/builtin/u128.v': 'module builtin

pub fn (n u128) str() string {
	return \'\'
}
'
		'lib/lib.v':             'module lib

import other

pub fn show() string {
	y := i128(-1)
	return (y >>> 1).str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.show' && it.to.ends_with('str'))
	assert calls.len == 1 && calls[0].to == 'vlib.builtin.u128.str', calls.map(it.to).str()
}

// `i64 { val_val.str() }` in a match of a `RedisValue` sum type: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_a_match_arm_on_a_primitive_types_its_sum_type_variable() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/redis/redis.v': 'module redis

import other

pub struct RedisMap {
pub:
	pairs []RedisValue
}

pub type RedisValue = bool | i64 | []u8 | RedisMap

pub struct DB {
}

pub fn (mut db DB) cmd(cmd ...string) !RedisValue {
	return RedisValue(i64(1))
}

pub fn (mut db DB) hgetall(key string) !map[string]string {
	resp := db.cmd("HGETALL", key)!
	mut result := map[string]string{}
	match resp {
		[]RedisValue {
			for i in 0 .. resp.len / 2 {
				val_val := resp[2 * i + 1]
				v := match val_val {
					[]u8 { val_val.bytestr() }
					i64 { val_val.str() }
					else { "" }
				}
				result[key] = v
			}
		}
		else {}
	}
	return result
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.redis.DB.hgetall')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
}

// `toml.Doc { doa.ast.table.str() }` in a match on a sum type alias: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_a_match_arm_on_a_qualified_type_types_its_sum_type_parameter() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/to/to.v': 'module to

import toml

type DocOrAny = toml.Any | toml.Doc

pub fn json(doa DocOrAny) string {
	match doa {
		toml.Doc {
			return doa.ast.table.str()
		}
		toml.Any {
			return ""
		}
	}
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
		'lib/toml/toml.v': 'module toml

import other

pub struct Root {
pub mut:
	table Value
}

pub type Value = bool | string

pub struct Doc {
pub:
	ast &Root = unsafe { nil }
}

pub type Any = bool | string

pub struct Date {
}

pub fn (d Date) str() string {
	return ""
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.to.json')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert !calls.any(it.to == 'lib.toml.Date.str')
}

// `toml_doc.reflect[User]().birthday.str()`: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_an_explicit_type_argument_of_a_method_names_its_own_type_parameter() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/reflect_test.v': 'module tests

import toml

struct User {
	birthday toml.Date
}

fn test_reflect() {
	toml_doc := toml.parse_text("") or { panic(err) }
	mut user := toml_doc.reflect[User]()
	assert user.birthday.str() == ""
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
		'lib/toml/toml.v': 'module toml

import other

pub struct Doc {
}

pub fn parse_text(text string) !Doc {
	return Doc{}
}

pub fn (d Doc) reflect[T]() T {
	return T{}
}

pub struct Date {
}

pub fn (d Date) str() string {
	return ""
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.test_reflect')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.toml.Date.str')
}

// `source.map(it.value.str())` on `type Sources = [2]Source`: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_an_alias_of_a_fixed_array_has_its_element_type() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/mapped.v': 'module tests

import other

struct Source {
	value int
}

type Sources = [2]Source

fn mapped_sources(source Sources) [2]string {
	return source.map(it.value.str()).map("value:" + it)
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.mapped_sources')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
}

// `arr.map(fn (s int) string {...}).str()` in a match arm of `[]int`: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_a_match_arm_on_an_array_types_the_variable_and_map_returns_its_closure_type() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/arr.v': 'module tests

import other

type Arr = []int | []string

fn test_match_with_array_map_in_branches() string {
	arr := Arr([0, 1])
	ret := match arr {
		[]int {
			arr.map(fn (s int) string {
				return s.str()
			}).str()
		}
		else {
			""
		}
	}
	return ret
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.test_match_with_array_map_in_branches')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
}

// `back.into_object[Integer]()!.value.str()`: no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_an_explicit_type_argument_of_a_method_on_an_interface_names_its_own_type_parameter() {
	g := graph_of({
		'lib/asn1/element.v': 'module asn1

import other

pub struct Integer {
pub:
	value i64
}

pub struct Element {
}

pub fn decode(bytes []u8) !Element {
	return Element{}
}

pub fn (el Element) into_object[T]() !T {
	return T{}
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}
'
		'lib/asn1/integer_test.v': 'module asn1

fn test_negative_number() ! {
	back := decode([]u8{})!
	back_value := back.into_object[Integer]()!
	assert back_value.value.str() == ""
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.asn1.test_negative_number')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.asn1.Element.into_object')
}

// `toml_doc.reflect[User]().birthday.str()`, with each file's FileResult through the batch protocol the way a parallel worker's output is, before its symbols and edges join the graph
fn test_a_method_type_parameter_survives_the_batch_protocol() {
	files := {
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/reflect_test.v': 'module tests

import toml

struct User {
	birthday toml.Date
}

fn test_reflect() {
	toml_doc := toml.parse_text("") or { panic(err) }
	mut user := toml_doc.reflect[User]()
	assert user.birthday.str() == ""
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
		'lib/toml/toml.v': 'module toml

import other

pub struct Doc {
}

pub fn parse_text(text string) !Doc {
	return Doc{}
}

pub fn (d Doc) reflect[T]() T {
	return T{}
}

pub struct Date {
}

pub fn (d Date) str() string {
	return ""
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		fr := decode_file_result(encode_file_result(extract_v_text_result(src, rel)))
		g.symbols << fr.symbols
		g.edges << fr.edges
	}
	resolve_edges(mut g)
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.test_reflect')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.toml.Date.str')
}

// `ctx.read_buf[i].Event.KeyEvent.uChar.UnicodeChar.str()`, where the C structs `Event`, `KEY_EVENT_RECORD` and `uChar` are declared in the caller's module and again in two other modules, as the terminal UI's Windows files are: the C namespace is one for the program, so the declaration nearest the field's own file is the one, and `rune.str` is the `str` the chain reaches (the name fallback can't pass by accident, see the competing `str` methods).
fn test_a_c_struct_declared_in_several_modules_takes_the_nearest_declaration() {
	g := graph_of({
		'vlib/builtin/rune.v': 'module builtin

pub fn (c rune) str() string {
	return ""
}

'
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/ui/input.v': 'module ui

pub struct Context {
	ExtraContext
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
		'lib/ui/input_nix.c.v': 'module ui

struct ExtraContext {
mut:
	read_buf []u8
}

'
		'lib/ui/input_windows.c.v': 'module ui

import other

const buf_size = 4

struct ExtraContext {
mut:
	read_buf [buf_size]C.INPUT_RECORD
}

fn (mut ctx Context) parse_events() {
	for i in 0 .. 4 {
		match int(ctx.read_buf[i].EventType) {
			1 {
				e := unsafe { ctx.read_buf[i].Event.KeyEvent }
				s := unsafe { e.uChar.UnicodeChar.str() }
				_ = s
			}
			else {}
		}
	}
}

'
		'lib/ui/consoleapi_windows.c.v': 'module ui

pub union C.Event {
	KeyEvent C.KEY_EVENT_RECORD
}

pub struct C.INPUT_RECORD {
	EventType u16
	Event     C.Event
}

pub union C.uChar {
mut:
	UnicodeChar rune
	AsciiChar   u8
}

pub struct C.KEY_EVENT_RECORD {
	bKeyDown i32
	uChar    C.uChar
}

'
		'lib/term/term_windows.c.v': 'module term

pub union C.uChar {
mut:
	UnicodeChar rune
	AsciiChar   u8
}

'
		'lib/v/compiler_tests/posix_wait.v': 'module compiler_tests

pub union C.Event {
	KeyEvent C.KEY_EVENT_RECORD
}

pub struct C.KEY_EVENT_RECORD {
	bKeyDown i32
	uChar    C.uChar
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.ui.Context.parse_events')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'vlib.builtin.rune.str')
}

// `host.contains('x')` on `host`, an `if` whose first branch is itself an `if` that yields no type (a string literal names none), so the `if` takes its type from the branch that does, the `string` of `name`: no `contains` edge is left unresolved (the name fallback can't pass by accident, see the competing `contains` methods).
fn test_an_if_value_takes_the_type_of_the_branch_that_has_one() {
	g := graph_of({
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) contains(sub string) bool {
	return false
}

'
		'lib/tests/pick_test.v': 'module tests

pub struct ProbeA {
}

pub fn (p ProbeA) contains(sub string) bool {
	return false
}

pub struct ProbeB {
}

pub fn (p ProbeB) contains(sub string) bool {
	return false
}

fn pick(flag bool, n int, name string) bool {
	host := if flag {
		if n == 0 {
			"a"
		} else {
			"b"
		}
	} else {
		name
	}
	return host.contains("x")
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.pick')
	assert !calls.any(it.to == 'contains' && it.provenance != .undeclared)
	assert calls.any(it.to == 'vlib.builtin.string.contains')
}

// `value.str()` in `for _, value in entries`, where `entries := { 'a': n }` holds a variable `n` of `Item`: a map literal whose entries name no type takes the type of its key and of the first value that has one, so `Item.str` is the method called and no `str` edge is left unresolved (the name fallback can't pass by accident, see the competing `str` methods).
fn test_a_map_literal_with_a_variable_value_takes_the_values_type() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/map_literal_test.v': 'module tests

import other

pub struct Item {
}

pub fn (i Item) str() string {
	return ""
}

fn walk(n Item) []string {
	entries := { \'a\': n }
	mut out := []string{}
	for _, value in entries {
		out << value.str()
	}
	return out
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.walk')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.tests.Item.str')
}

// `value.str()` in `for _, value in entries`, where `entries := { 'a': [Item{}], 'b': [] }` has an empty array as its second value: the empty array names no type, so the map takes its type from the first value that has one, `[]Item`, and the loop's value is that array, whose elements are `Item`s (no `str` edge is left unresolved; see the competing `str` methods).
fn test_a_map_literal_with_an_untyped_empty_array_takes_the_type_of_the_others() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/empty_array_test.v': 'module tests

import other

pub struct Item {
}

pub fn (i Item) str() string {
	return ""
}

fn walk() []string {
	entries := { \'a\': [Item{}], \'b\': [] }
	mut out := []string{}
	for _, values in entries {
		for value in values {
			out << value.str()
		}
	}
	return out
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.walk')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.tests.Item.str')
}

// `value.str()` in `for _, value in m`, where `m := { -1: Item{} }` has a negative key: `-1` is an int, so the map is `map[int]Item` and the value is an `Item` (no `str` edge is left unresolved; see the competing `str` methods).
fn test_a_map_literal_with_a_negative_key_is_typed_by_its_number() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Note {
	text string
}

pub fn (n Note) str() string {
	return n.text
}

'
		'lib/tests/negative_key_test.v': 'module tests

import other

pub struct Item {
}

pub fn (i Item) str() string {
	return ""
}

fn walk() []string {
	m := { -1: Item{} }
	mut out := []string{}
	for _, value in m {
		out << value.str()
	}
	return out
}

fn competitor() string {
	n := other.Note{}
	return n.str()
}

pub struct ProbeA {
}

pub fn (p ProbeA) str() string {
	return ""
}

pub struct ProbeB {
}

pub fn (p ProbeB) str() string {
	return ""
}

'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.walk')
	assert !calls.any(it.to == 'str' && it.provenance != .undeclared)
	assert calls.any(it.to == 'lib.tests.Item.str')
}

// `Kind.from(1)` for an enum `Kind` in the caller's module that declares no `from`: V generates it for every enum, so the call is one V provides, marked undeclared rather than left unresolved.
fn test_a_generated_from_of_an_enum_in_the_callers_module_is_provided_by_v() {
	g := graph_of({
		'lib/tests/kind_test.v': 'module tests

pub enum Kind {
	a
	b
}

fn parse(n int) Kind {
	return Kind.from(n) or { Kind.a }
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.parse')
	assert calls.any(it.to == 'Kind__static__from' && it.provenance == .undeclared)
	assert !calls.any(it.to == 'Kind__static__from' && it.provenance != .undeclared)
}

// `Kind.from_string('a')`, the same as `from` for an enum with no `from_string` declared: V generates it for every enum.
fn test_a_generated_from_string_of_an_enum_in_the_callers_module_is_provided_by_v() {
	g := graph_of({
		'lib/tests/kind_test.v': 'module tests

pub enum Kind {
	a
	b
}

fn parse(s string) Kind {
	return Kind.from_string(s) or { Kind.a }
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.parse')
	assert calls.any(it.to == 'Kind__static__from_string' && it.provenance == .undeclared)
	assert !calls.any(it.to == 'Kind__static__from_string' && it.provenance != .undeclared)
}

fn test_a_generated_from_string_of_an_imported_enum_is_provided_by_v() {
	// the enum of `mod2.Kind.from_string(s)` is the one module its qualifier names: a
	// standalone program's enum (app/progs/mod2) is no module an import names, and of
	// `rand.Kind`, vlib/rand is named exactly where vlib/crypto/rand only ends like it.
	// `Shape` is no enum, and `lone.Kind` is in two modules named `lone`, so neither
	// call is one V provides. `mod2.Show.zero()` is V's for a flag enum, and
	// `mod2.Kind.zero()` is not, as Kind is no flag enum.
	g := graph_of({
		'app/v.mod':               ''
		'app/mod/mod.v':           'module mod\n\npub struct Shape {}\n'
		'app/mod2/mod2.v':         'module mod2\n\npub enum Kind {\n\ta\n}\n\n@[flag]\npub enum Show {\n\ta\n\tb\n}\n'
		'app/progs/mod2/main.v':   'module main\n\nenum Kind {\n\ta\n}\n\nfn main() {}\n'
		'app/a/lone/lone.v':       'module lone\n\npub enum Kind {\n\ta\n}\n'
		'app/b/lone/lone.v':       'module lone\n\npub enum Kind {\n\ta\n}\n'
		'vlib/rand/rand.v':        'module rand\n\npub enum Kind {\n\ta\n}\n'
		'vlib/crypto/rand/rand.v': 'module rand\n\npub enum Kind {\n\ta\n}\n'
		'app/main_test.v':         'module main\n\nimport mod { Shape }\nimport mod2\nimport lone\nimport rand\n\nfn test_m() {\n\t_ := mod2.Kind.from_string(\'a\') or { return }\n\t_ := lone.Kind.from_string(\'a\') or { return }\n\t_ := rand.Kind.from_string(\'a\') or { return }\n\t_ := Shape.from_string(\'a\') or { return }\n\t_ := mod2.Show.zero()\n\t_ := mod2.Kind.zero()\n}\n'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.test_m')
	und := calls.filter(it.provenance == .undeclared).map(it.to)
	assert und.len == 3, calls.str()
	assert 'mod2.Kind__static__from_string' in und, und.str()
	assert 'rand.Kind__static__from_string' in und, und.str()
	assert 'mod2.Show__static__zero' in und, und.str()
	assert !calls.any(it.to.contains('Shape__static__from_string') && it.provenance == .undeclared)
	assert !calls.any(it.to.contains('lone.Kind') && it.provenance == .undeclared)
	assert !calls.any(it.to == 'mod2.Kind__static__zero' && it.provenance == .undeclared)
	// an enum declared once per platform is one module's, not two
	p := graph_of({
		'app/v.mod':                  ''
		'app/plat/kind_linux.c.v':    'module plat\n\npub enum Kind {\n\ta\n}\n'
		'app/plat/kind_windows.c.v':  'module plat\n\npub enum Kind {\n\ta\n}\n'
		'app/main_test.v':            'module main\n\nimport plat\n\nfn test_p() {\n\t_ := plat.Kind.from_string(\'a\') or { return }\n}\n'
	})
	pc := p.edges.filter(it.kind == .calls && it.from == 'app.test_p')
	assert pc.any(it.to == 'plat.Kind__static__from_string' && it.provenance == .undeclared), pc.str()
	// an enum that declares its own from_string (here in a test the caller can't
	// reach) isn't V's; a test's enum is no module's an import names, so `solo.Kind`
	// is app/d/solo's alone
	d := graph_of({
		'app/v.mod':                ''
		'app/dec/dec.v':            'module dec\n\npub enum Kind {\n\ta\n}\n'
		'app/dec/extra_test.v':     'module dec\n\nfn Kind.from_string(s string) ?Kind {\n\treturn none\n}\n'
		'app/c/solo/solo_test.v':   'module solo\n\nenum Kind {\n\ta\n}\n'
		'app/d/solo/solo.v':        'module solo\n\npub enum Kind {\n\ta\n}\n'
		'app/main_test.v':          'module main\n\nimport dec\nimport solo\n\nfn test_d() {\n\t_ := dec.Kind.from_string(\'a\') or { return }\n\t_ := solo.Kind.from_string(\'a\') or { return }\n}\n'
	})
	dc := d.edges.filter(it.kind == .calls && it.from == 'app.test_d')
	assert !dc.any(it.to == 'dec.Kind__static__from_string' && it.provenance == .undeclared), dc.str()
	assert dc.any(it.to == 'solo.Kind__static__from_string' && it.provenance == .undeclared), dc.str()
	// a static call through a selective import is named bare, as written, so one of a
	// module whose directory has another name still resolves by its name
	h := graph_of({
		'proj/v.mod':       ''
		'proj/odd/foo.v':   'module zmod_foo\n\npub struct Foo {}\n\npub fn Foo.new() Foo {\n\treturn Foo{}\n}\n'
		'proj/odd/main.v':  'module main\n\nimport zmod_foo { Foo }\n\nfn main() {\n\t_ := Foo.new()\n}\n'
	})
	hc := h.edges.filter(it.kind == .calls && it.from == 'proj.odd.main').map(it.to)
	assert hc == ['proj.odd.Foo__static__new'], hc.str()
}

fn test_a_method_v_provides_on_an_array_of_functions_or_a_literal_is_undeclared() {
	// `[a, b]` holds functions, so it is an array, and `index`, `contains` and
	// `to_fixed_size` are methods V writes for it rather than any declared `index`
	g := graph_of({
		'lib/m/m.v':          'module m\n\nfn a() {}\n\nfn b() {}\n\nfn probe() {\n\tfa := [a, b]\n\t_ := fa.index(b)\n\tff := [a, b]!\n\t_ := ff.contains(a)\n\t_ := [1, 2].to_fixed_size()\n}\n\nfn probe2() {\n\tys := [nope_a, nope_b]\n\t_ := ys.index(1)\n}\n'
		'lib/other/other.v':  'module other\n\npub struct S {}\n\npub fn (s S) index(x int) int {\n\treturn x\n}\n\npub fn (s S) contains(x int) bool {\n\treturn true\n}\n\npub fn (s S) to_fixed_size() int {\n\treturn 0\n}\n'
		'lib/other/other2.v': 'module other\n\npub struct T {}\n\npub fn (t T) index(x int) int {\n\treturn x\n}\n\npub fn (t T) contains(x int) bool {\n\treturn true\n}\n\npub fn (t T) to_fixed_size() int {\n\treturn 0\n}\n'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.m.probe' && it.to in ['index', 'contains', 'to_fixed_size'])
	assert calls.len == 3, calls.str()
	assert calls.all(it.provenance == .undeclared), calls.str()
	// names that reach no function are no functions, so `ys` is untyped and its
	// `index` is left to name matching, which the two declared `index` methods leave
	// ambiguous
	p2 := g.edges.filter(it.kind == .calls && it.from == 'lib.m.probe2' && it.to == 'index')
	assert p2.len == 1 && p2[0].provenance != .undeclared, p2.str()
}

// `__addr(x)` and `__v3_isreftype(x)` are compiler forms that V lowers, so the calls keep no edge at all: they are not calls into the program.
fn test_a_compiler_intrinsic_call_keeps_no_edge() {
	g := graph_of({
		'lib/tests/intrinsic_test.v': 'module tests

fn probe(x int) {
	_ = __addr(x)
	_ = __v3_isreftype(x)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.probe')
	assert !calls.any(it.to == '__addr')
	assert !calls.any(it.to == '__v3_isreftype')
}

// `bare_print('x')` and `__malloc(8)`: V's runtime helpers, which its bare builtin declares in its own source and no program does. Nothing in the program declares them, so each call is into the runtime and is marked undeclared, not left unresolved.
fn test_a_runtime_helper_no_program_declares_is_undeclared() {
	g := graph_of({
		'lib/tests/runtime_test.v': 'module tests

fn emit() {
	bare_print(\'x\')
	_ = __malloc(8)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.emit')
	assert calls.any(it.to == 'bare_print' && it.provenance == .undeclared)
	assert calls.any(it.to == '__malloc' && it.provenance == .undeclared)
	assert !calls.any(it.provenance != .undeclared && it.to in ['bare_print', '__malloc'])
}

// `vlibc_read_file(path)` in os: a function only V's bare builtin directories declare
// (`module builtin` in vlib/builtin/<os>_bare, which the driver adds under -d vlibc or
// -freestanding), one copy per OS. The call can't say which OS it is built for, so it
// reaches every copy, as a call of a per-platform function does. A method of the name
// is no candidate for a plain call, and a method call of the name is not linked to the
// functions. A name another module declares a function of too, a caller inside a bare
// directory, a parameter of that name, and a runtime helper are left as they were.
fn test_a_call_only_bare_builtin_directories_declare_reaches_every_copy() {
	g := graph_of({
		'vlib/builtin/linux_bare/vlibc_d_vlibc.v':   'module builtin

pub fn vlibc_read_file(path string) []u8 {
	return []u8{}
}

pub fn shared_name() {}

pub fn __malloc(n int) voidptr {
	return unsafe { nil }
}

pub struct Rec {}

pub fn (r Rec) vlibc_stat() int {
	return 0
}
'
		'vlib/builtin/linux_bare/extra_d_vlibc.v':   'module builtin

pub fn not_mine() {}
'
		'vlib/builtin/macos_bare/vlibc_d_vlibc.v':   'module builtin

pub fn vlibc_read_file(path string) []u8 {
	return []u8{}
}

pub fn two_copies() {}

pub fn vlibc_stat() int {
	return 1
}

pub fn __malloc(n int) voidptr {
	return unsafe { nil }
}

pub fn bare_self() {
	not_mine()
}
'
		'vlib/builtin/freebsd_bare/vlibc_d_vlibc.v': 'module builtin

pub fn two_copies() {}

pub fn not_mine() {}

pub fn vlibc_stat() int {
	return 2
}
'
		'vlib/other/other.v':                        'module other

pub fn shared_name() {}
'
		'vlib/os/os.c.v':                            'module os

fn read_bytes(path string) {
	\$if vlibc ? {
		_ = vlibc_read_file(path)
	}
	two_copies()
	shared_name()
	_ = vlibc_stat()
	_ = __malloc(8)
}

fn run(vlibc_read_file fn (string) []u8) {
	_ = vlibc_read_file(\'x\')
}

fn via_value(x Unknown) {
	_ = x.vlibc_read_file(\'p\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'vlib.os.read_bytes')
	to := fn [calls] (name string) []Edge {
		return calls.filter(it.to.ends_with('.' + name) || it.to == name)
	}
	// each OS's copy, with the call's own build
	read := to('vlibc_read_file')
	assert read.map(it.to).sorted() == ['vlib.builtin.linux_bare.vlibc_read_file',
		'vlib.builtin.macos_bare.vlibc_read_file'], calls.str()
	assert read.all(it.provenance == .inferred && it.build == 'vlibc ?'), read.str()
	// copies none of which is linux_bare's are each OS's all the same
	assert to('two_copies').map(it.to).sorted() == ['vlib.builtin.freebsd_bare.two_copies',
		'vlib.builtin.macos_bare.two_copies'], calls.str()
	// a method of the name is no candidate for a plain call: the two functions, not Rec's
	assert to('vlibc_stat').map(it.to).sorted() == ['vlib.builtin.freebsd_bare.vlibc_stat',
		'vlib.builtin.macos_bare.vlibc_stat'], calls.str()
	// another module declares it too: not the bare builtin's
	assert to('shared_name').map(it.to) == ['shared_name'], calls.str()
	// a runtime helper stays one
	assert to('__malloc').len == 1 && to('__malloc')[0].to == '__malloc'
		&& to('__malloc')[0].provenance == .undeclared, calls.str()
	// a parameter of that name is a function value, not the bare builtin's
	run := g.edges.filter(it.kind == .calls && it.from == 'vlib.os.run')
	assert run.len == 1 && run[0].to == 'vlibc_read_file' && run[0].provenance == .undeclared, run.str()
	// a method call of the name, on a receiver of no known type, names no function of it
	value := g.edges.filter(it.kind == .calls && it.from == 'vlib.os.via_value')
	assert value.len == 1 && value[0].to == 'vlibc_read_file' && value[0].is_method, value.str()
	// a caller in a bare directory: its build compiles only that directory
	bare := g.edges.filter(it.kind == .calls && it.from == 'vlib.builtin.macos_bare.bare_self')
	assert bare.map(it.to) == ['not_mine'], bare.str()
	// a graph whose root is vlib names the directories without `vlib.`
	assert is_bare_builtin_mod('vlib.builtin.linux_bare') && is_bare_builtin_mod('builtin.macos_bare')
	assert !is_bare_builtin_mod('vlib.builtin') && !is_bare_builtin_mod('vlib.builtin.js')
	assert !is_bare_builtin_mod('vlib.builtin.linux_bare.sub') && !is_bare_builtin_mod('x.builtin.linux_bare')
	// each check on its own: not under builtin, and not directly in it
	assert !is_bare_builtin_mod('vlib.other.linux_bare') && !is_bare_builtin_mod('vlib.builtin.x.linux_bare')
}

// The copies of a bare builtin function stay alike: a caller declared once per platform
// calls it in each file, and every copy gets both call sites and their builds together; a
// function value of the same name in the caller is its own undeclared edge, whichever
// comes first. A nearer rule keeps what it answers: the receiver's own method, an alias
// conversion. A method of the name outside the bare directories, or a test helper of it,
// doesn't stop the call linking; a copy whose id names no one declaration, and one a test
// file in a bare directory declares, are left out.
fn test_a_call_into_the_bare_builtin_keeps_its_copies_alike_and_yields_to_nearer_rules() {
	bare := 'pub fn vlibc_x(p string) []u8 {\n\treturn []u8{}\n}\n\npub fn describe() {}\n\npub fn vlibc_alias(n int) int {\n\treturn n\n}\n'
	g := graph_of({
		'vlib/builtin/linux_bare/vlibc_d_vlibc.v': 'module builtin\n\n' + bare
		'vlib/builtin/macos_bare/vlibc_d_vlibc.v': 'module builtin\n\n' + bare + '\npub fn uniq_x() {}\n\npub fn lone_x() {}\n'
		'vlib/builtin/linux_bare/uniq_d_vlibc.v':  'module builtin\n\npub fn uniq_x() {}\n'
		'vlib/builtin/linux_bare/a_test.v':        'module builtin\n\nfn uniq_x() {}\n'
		'vlib/builtin/linux_bare/b_test.v':        'module builtin\n\nfn uniq_x() {}\n\nfn lone_x() {}\n'
		// a test helper of the name in os, which no file but its own sees
		'vlib/os/helper_test.v':                   'module os\n\nfn vlibc_x(p string) []u8 {\n\treturn []u8{}\n}\n'
		'vlib/other/other.v':                      'module other\n\npub struct Obj {}\n\npub fn (o Obj) vlibc_x() {}\n'
		// read2 in two platform files, the call on line 5 under `$if vlibc ?` and on line 4
		'vlib/os/rb_nix.c.v':                      'module os\n\nfn read2(p string) {\n\t\$if vlibc ? {\n\t\t_ = vlibc_x(p)\n\t}\n}\n'
		'vlib/os/rb_windows.c.v':                  'module os\n\nfn read2(p string) {\n\t_ = vlibc_x(p)\n}\n'
		// the real call on line 4 and the parameter's call on line 6, then the other way round
		'vlib/os/real_first.v':                    'module os\n\nfn real_first(p string) {\n\t_ = vlibc_x(p)\n\tf := fn (vlibc_x fn (string) []u8) {\n\t\t_ = vlibc_x(\'x\')\n\t}\n\t_ = f\n}\n'
		'vlib/os/value_first.v':                   'module os\n\nfn value_first(p string) {\n\tf := fn (vlibc_x fn (string) []u8) {\n\t\t_ = vlibc_x(\'x\')\n\t}\n\t_ = f\n\t_ = vlibc_x(p)\n}\n'
		'vlib/os/b.v':                             'module os\n\nstruct B {}\n\nfn (b B) describe() {}\n\nfn (b B) go() {\n\tdescribe()\n}\n\ntype vlibc_alias = int\n\nfn use_alias() {\n\t_ = vlibc_alias(1)\n}\n\nfn use_uniq() {\n\tuniq_x()\n}\n\nfn use_lone() {\n\tlone_x()\n}\n'
	})
	calls_of := fn [g] (from string) []Edge {
		return g.edges.filter(it.kind == .calls && it.from == from)
	}
	copies := ['vlib.builtin.linux_bare.vlibc_x', 'vlib.builtin.macos_bare.vlibc_x']
	// both files' calls on every copy, with the build either makes them in; a method of
	// the name in vlib/other doesn't stop it
	read2 := calls_of('vlib.os.read2')
	assert read2.map(it.to).sorted() == copies, read2.str()
	assert read2.all(it.lines == [4, 5] && it.build == ''), read2.str()
	// the parameter's call is its own, undeclared, in either order
	for row in [['vlib.os.real_first', '4', '6'], ['vlib.os.value_first', '8', '5']] {
		cs := calls_of(row[0])
		real, value := row[1].int(), row[2].int()
		linked := cs.filter(it.to in copies)
		assert linked.map(it.to).sorted() == copies, cs.str()
		assert linked.all(it.lines == [real]), cs.str()
		assert cs.any(it.to == 'vlibc_x' && it.provenance == .undeclared && it.lines == [value]), cs.str()
	}
	// the receiver's own method, not the bare builtin's
	assert calls_of('vlib.os.B.go').map(it.to) == ['vlib.os.B.describe'], calls_of('vlib.os.B.go').str()
	// a conversion to the module's alias, not a call of the bare builtin's function
	assert calls_of('vlib.os.use_alias').map(it.to) == ['vlib.os.vlibc_alias'], calls_of('vlib.os.use_alias').str()
	// linux_bare's uniq_x is declared by a file of it and by two tests, an id for no one
	// declaration
	assert calls_of('vlib.os.use_uniq').map(it.to) == ['vlib.builtin.macos_bare.uniq_x'], calls_of('vlib.os.use_uniq').str()
	// a test file in a bare directory is its own program, not one of builtin's copies
	assert calls_of('vlib.os.use_lone').map(it.to) == ['vlib.builtin.macos_bare.lone_x'], calls_of('vlib.os.use_lone').str()
}

// `mut data, e := vlibc_read_file(path)` in os.read_bytes: every bare builtin copy returns
// `([]u8, Errno)`, so `data` is a `[]u8` and `data.bytestr()` is that type's, though
// another `bytestr` is in reach. Copies that return different types give no type, and
// neither does a call the receiver's own method or an alias conversion answers, which
// resolve_edges doesn't link to the copies. `Errno`, which each directory declares for
// itself, names no one OS's copy.
fn test_a_call_into_the_bare_builtin_has_the_type_its_copies_return() {
	same := 'pub enum Errno {\n\tok\n}\n\npub fn (e Errno) code() int {\n\treturn 0\n}\n\npub fn read_all(p string) ([]u8, Errno) {\n\treturn []u8{}, .ok\n}\n\npub fn rd(p string) []u8 {\n\treturn []u8{}\n}\n\npub fn myb(p int) []u8 {\n\treturn []u8{}\n}\n'
	g := graph_of({
		'vlib/builtin/array.v':                    'module builtin\n\npub fn (b []u8) bytestr() string {\n\treturn \'\'\n}\n\npub fn (s string) bytestr() string {\n\treturn s\n}\n'
		'vlib/builtin/linux_bare/vlibc_d_vlibc.v': 'module builtin\n\n' + same + '\npub fn differ() []u8 {\n\treturn []u8{}\n}\n'
		'vlib/builtin/macos_bare/vlibc_d_vlibc.v': 'module builtin\n\n' + same + '\npub fn differ() string {\n\treturn \'\'\n}\n'
		'vlib/net/http/response.v':                'module http\n\npub struct Response {}\n\npub fn (r Response) bytestr() string {\n\treturn \'\'\n}\n'
		'vlib/os/os.c.v':                          'module os\n\nimport net.http\n\nfn read_bytes(p string) string {\n\t_ = http.Response{}\n\tmut data, e := read_all(p)\n\t_ = e\n\treturn data.bytestr()\n}\n\nfn read_differ() string {\n\t_ = http.Response{}\n\tx := differ()\n\treturn x.bytestr()\n}\n\nfn read_errno(p string) int {\n\tmut data, e := read_all(p)\n\t_ = data\n\treturn e.code()\n}\n\nstruct Reader {}\n\nfn (r Reader) rd(p string) string {\n\treturn p\n}\n\nfn (r Reader) go() string {\n\tdata := rd(\'x\')\n\treturn data.bytestr()\n}\n\ntype myb = string\n\nfn use_alias() string {\n\tx := myb(\'q\')\n\treturn x.bytestr()\n}\n'
	})
	bytestr := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.from == from && it.to.ends_with('bytestr')).map(it.to)
	}
	assert bytestr('vlib.os.read_bytes') == ['vlib.builtin.[]u8.bytestr'], bytestr('vlib.os.read_bytes').str()
	// a []u8 on one OS and a string on another: no one type, so the call stays unresolved
	assert bytestr('vlib.os.read_differ') == ['bytestr'], bytestr('vlib.os.read_differ').str()
	// `rd` is the receiver's method, a string, and `myb(...)` a conversion to the alias:
	// neither value has the copies' []u8
	assert !bytestr('vlib.os.Reader.go').contains('vlib.builtin.[]u8.bytestr'), bytestr('vlib.os.Reader.go').str()
	assert !bytestr('vlib.os.use_alias').contains('vlib.builtin.[]u8.bytestr'), bytestr('vlib.os.use_alias').str()
	// each OS's Errno is its own type: e.code() is not linked to one OS's copy alone
	codes := g.edges.filter(it.kind == .calls && it.from == 'vlib.os.read_errno' && it.to.ends_with('code'))
	assert codes.map(it.to) == ['code'], codes.str()
}

// `uintptr_t(41)`, a bare call of `type uintptr_t = usize` in the caller's own module, is a conversion to that alias, so the call resolves to it instead of staying unresolved
fn test_a_bare_call_of_a_type_alias_in_scope_is_a_conversion_to_it() {
	g := graph_of({
		'lib/tests/alias_types.v': 'module tests

type uintptr_t = usize
'
		'lib/tests/alias_use.v':   'module tests

fn cast_it() usize {
	return uintptr_t(41)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.cast_it')
	assert calls.any(it.to == 'lib.tests.uintptr_t' && it.provenance == .inferred)
	assert !calls.any(it.to == 'uintptr_t')
}

// an alias in a module the caller does not import is not in its scope, so it does not claim a bare call of the same name
fn test_a_type_alias_the_caller_cannot_see_does_not_claim_a_bare_call() {
	g := graph_of({
		'lib/far/types.v':       'module far

type uintptr_t = usize
'
		'lib/tests/alias_use.v': 'module tests

fn cast_it() usize {
	return uintptr_t(41)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.tests.cast_it')
	assert !calls.any(it.to == 'lib.far.uintptr_t')
	assert calls.any(it.to == 'uintptr_t')
}

// a directory with no `fn main` is built as one program (V test), so a main file in it sees the alias in a sibling file, `_test.v` callers included
fn test_a_type_alias_is_in_scope_for_a_main_file_in_a_directory_with_no_main() {
	g := graph_of({
		'lib/casts/types.v':     'module main

type uintptr_t = usize
'
		'lib/casts/cast_test.v': 'module main

fn cast_it() usize {
	return uintptr_t(41)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.casts.cast_it')
	assert calls.any(it.to == 'lib.casts.uintptr_t' && it.provenance == .inferred)
}

// a directory with several `fn main` is several programs, so an alias in one of them is not a conversion from another
fn test_a_type_alias_is_not_in_scope_across_programs_in_a_directory_with_several_mains() {
	g := graph_of({
		'lib/casts/types.v': 'module main

type uintptr_t = usize
'
		'lib/casts/a.v':     'module main

fn main() {
	cast_it()
}

fn cast_it() usize {
	return uintptr_t(41)
}
'
		'lib/casts/b.v':     'module main

fn main() {}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.casts.cast_it')
	assert !calls.any(it.to == 'lib.casts.uintptr_t')
}

fn test_a_primitive_without_a_str_is_undeclared_and_shifts_keep_its_type() {
	g := graph_of({
		'lib/lib.v': 'module lib

pub fn run() string {
	a := u128(0).str()
	b := (u128(1) << 64).str()
	return a + b
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.run')
	// V writes `str()` for a u128, which the builtin doesn't declare
	assert calls.len == 1 && calls[0].to == 'str'
	assert calls[0].provenance == .undeclared
}

fn test_a_str_on_a_comptime_field_is_that_fields_type_inside_a_type_check() {
	g := graph_of({
		'vlib/builtin/int.v': 'module builtin

pub fn (i int) str() string {
	return \'\'
}
'
		'lib/lib.v': 'module lib

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
		'app/app.v': 'module app

import lib

fn encode[T](val T) bool {
	mut ok := false
	$for field in T.fields {
		$if field.typ is int {
			ok = val.$(field.name).str() == \'\'
		}
	}
	return ok
}

fn encode_other_fields[T](val T) bool {
	mut ok := false
	$for field in T.fields {
		$if field.typ is int {
			ok = true
		} $else {
			ok = val.$(field.name).str() == \'\'
		}
	}
	return ok
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.encode' && it.to == 'vlib.builtin.int.str'), g.edges.filter(it.from == 'app.encode').map(it.to).str()
	// a field the type check doesn't name stays unknown
	assert !g.edges.any(it.kind == .calls && it.from == 'app.encode_other_fields' && it.to == 'vlib.builtin.int.str')
}

fn test_a_str_on_a_comptime_method_call_is_that_methods_return_type_inside_a_type_check() {
	g := graph_of({
		'vlib/builtin/int.v': 'module builtin

pub fn (i int) str() string {
	return \'\'
}
'
		'lib/lib.v': 'module lib

pub struct Node {}

pub fn (n Node) str() string {
	return \'\'
}
'
		'app/app.v': 'module app

import lib

struct Foo {}

fn (f Foo) number() int {
	return 1
}

fn run[T](val T) bool {
	mut ok := false
	$for method in T.methods {
		$if method.return_type is int {
			x := val.$method()
			ok = x.str() == \'\'
		}
	}
	return ok
}
'
	})
	assert g.edges.any(it.kind == .calls && it.from == 'app.run' && it.to == 'vlib.builtin.int.str'), g.edges.filter(it.from == 'app.run').map(it.to).str()
}

fn test_get_body_notes_a_file_that_changed_since_the_extract() {
	src := 'module demo\n\npub fn greet() string {\n\treturn "hi"\n}\n'
	root := write_tree('get_body_drift', {
		'a.v': src
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert !g.get_body('greet').contains('has changed'), g.get_body('greet')
	// a line added above moves the declaration, so the captured range is wrong
	os.write_file(os.join_path(root, 'a.v'), '// added\n${src}') or { panic(err) }
	assert g.get_body('greet').starts_with('// a.v has changed since the graph was built'), g.get_body('greet')
	// put back, the file is clean again
	os.write_file(os.join_path(root, 'a.v'), src) or { panic(err) }
	assert !g.get_body('greet').contains('has changed'), g.get_body('greet')
}

fn test_get_body_of_a_crlf_checkout_is_not_reported_as_changed() {
	// the same text with CRLF line ends (a Windows checkout) is the same file
	assert text_hash('module demo\r\nfn a() {}\r\n') == text_hash('module demo\nfn a() {}\n')
	lf := 'module demo\n\npub fn greet() string {\n\treturn "hi"\n}\n'
	root := write_tree('get_body_crlf_drift', {
		'a.v': lf.replace('\n', '\r\n')
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	// the same file checked out with LF endings
	os.write_file(os.join_path(root, 'a.v'), lf) or { panic(err) }
	assert !g.get_body('greet').contains('has changed'), g.get_body('greet')
}

fn test_a_loaded_graph_notes_a_file_changed_since_its_manifest_was_written() {
	src := 'module demo\n\npub fn greet() string {\n\treturn "hi"\n}\n'
	root := write_tree('get_body_loaded', {
		'a.v': src
	})
	out := root + '_out'
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(out) or {}
	}
	g := build_graph(Options{ root: root })
	write_bundle(g, out, ExtractReport{}) or { panic(err) }
	loaded := load_graph(os.join_path(out, 'graph.json')) or { panic(err) }
	assert !loaded.get_body('greet').contains('has changed'), loaded.get_body('greet')
	os.write_file(os.join_path(root, 'a.v'), '// added\n${src}') or { panic(err) }
	assert loaded.get_body('greet').starts_with('// a.v has changed since the graph was built'), loaded.get_body('greet')
}

fn test_a_for_loop_over_a_range_takes_the_type_of_its_typed_bound() {
	// `u8(0) .. 255` loops over u8, and `0 .. n` takes n's type, so both reach the
	// u8 method; a loop over `0 .. 10` is int, and reaches the int method
	root := write_tree('range_loop_types', {
		'demo.v': 'module demo\n\npub fn (b u8) twice() u8 {\n\treturn b * 2\n}\n\npub fn (i int) twice() int {\n\treturn i * 2\n}\n\npub fn sums() {\n\tfor c in u8(0) .. 255 {\n\t\t_ = c.twice()\n\t}\n\tn := u8(3)\n\tfor k in 0 .. n {\n\t\t_ = k.twice()\n\t}\n\tfor i in 0 .. 10 {\n\t\t_ = i.twice()\n\t}\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.sums').map(it.to)
	assert 'demo.u8.twice' in targets, targets.str()
	assert targets.filter(it == 'demo.int.twice').len == 1, targets.str()
}

// write_canned writes the line a worker prints for `rel` as the file is now, to
// `tpl_dir/<rel>.line`, for crash_worker to copy out.
fn write_canned(tpl_dir string, root string, rel string) {
	fr := extract_v_file_result(os.join_path(root, rel), rel)
	os.write_file(os.join_path(tpl_dir, '${rel}.line'), encode_file_result(fr) + '\n') or {
		panic(err)
	}
}

// compile_crash_worker compiles a stand-in for `graphify _parse-batch LIST OUT`
// into dir and returns its path. For each file in LIST it copies that file's
// canned line (from the directory named by GRAPHIFY_TEST_CANNED) to OUT, except
// that while `crash_now` exists there it panics on crash.v, as a parser that
// crashes would, so the extract sees a worker that dies partway through its batch;
// `crash_once` makes it panic on crash.v once, removing the file as it does.
fn compile_crash_worker(dir string) string {
	src := os.join_path(dir, 'fake_worker.vsh')
	os.write_file(src, "module main

import os

fn main() {
	tpl := os.getenv('GRAPHIFY_TEST_CANNED')
	lines := os.read_lines(os.args[2]) or { exit(1) }
	mut out := os.create(os.args[3]) or { exit(1) }
	for line in lines {
		rel := line.all_after(u8(9).ascii_str())
		if rel == 'crash.v' && os.exists(os.join_path(tpl, 'crash_now')) {
			panic('the parser crashed on crash.v')
		}
		if rel == 'crash.v' && os.exists(os.join_path(tpl, 'crash_once')) {
			os.rm(os.join_path(tpl, 'crash_once')) or {}
			panic('the parser crashed on crash.v, once')
		}
		canned := os.read_file(os.join_path(tpl, rel + '.line')) or { exit(1) }
		out.writeln(canned.trim_right('\\r\\n')) or { exit(1) }
		out.flush()
	}
	out.close()
}
") or { panic(err) }
	exe := os.join_path(dir, 'fake_worker') + $if windows { '.exe' } $else { '' }
	vexe := @VEXE
	res := os.exec([vexe, '-o', exe, 'build', src])
	assert res.exit_code == 0, res.output
	return exe
}

// check_carry_forward runs a crash on crash.v after an extract that succeeded:
// the crashed file keeps its last extract, and the file queued behind it is parsed.
fn check_carry_forward(worker string, dir string) {
	root := write_tree('worker_crash_carry', {
		'a.v':     'module demo\n\npub fn a_fn() int {\n\treturn 1\n}\n'
		'crash.v': 'module demo\n\npub fn crash_fn() int {\n\treturn 2\n}\n'
		'z.v':     'module demo\n\npub fn z_fn() int {\n\treturn 3\n}\n'
	})
	tpl := os.join_path(dir, 'carry')
	out := root + '_out'
	os.mkdir_all(tpl) or { panic(err) }
	os.setenv('GRAPHIFY_TEST_CANNED', tpl, true)
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(out) or {}
	}
	for rel in ['a.v', 'crash.v', 'z.v'] {
		write_canned(tpl, root, rel)
	}
	// the first extract has nothing to fall back on, and every file parses
	g1, r1 := build_graph_resilient(root, worker, out)
	assert r1.failed.len == 0, r1.failed.str()
	assert 'demo.crash_fn' in g1.symbols.map(it.id), g1.symbols.map(it.id).str()
	// the next run changes crash.v and z.v, and the worker dies on crash.v, first in
	// the batch, so z.v is queued behind it and parsed in the next wave
	os.write_file(os.join_path(root, 'crash.v'), 'module demo\n\npub fn crash_fn() int {\n\treturn 4\n}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(root, 'z.v'), 'module demo\n\npub fn z_fn_v2() int {\n\treturn 5\n}\n') or {
		panic(err)
	}
	write_canned(tpl, root, 'z.v')
	os.write_file(os.join_path(tpl, 'crash_now'), '') or { panic(err) }
	g2, r2 := build_graph_resilient(root, worker, out)
	assert 'crash.v' in r2.failed, r2.failed.str()
	assert 'crash.v' in r2.stale, r2.stale.str()
	ids := g2.symbols.map(it.id)
	assert 'demo.crash_fn' in ids, ids.str() // the last good extract, carried forward
	assert 'demo.z_fn_v2' in ids, ids.str() // queued behind the crash, then parsed
	assert 'demo.a_fn' in ids, ids.str() // unchanged, reused from the cache
}

// check_first_sighting runs a crash on a file with nothing cached: it is failed,
// has no symbols, and is not stale.
fn check_first_sighting(worker string, dir string) {
	// nothing cached yet, so the crash has no earlier extract to carry forward
	root := write_tree('worker_crash_first', {
		'crash.v': 'module demo\n\npub fn crash_fn() int {\n\treturn 2\n}\n'
	})
	tpl := os.join_path(dir, 'first')
	out := root + '_out'
	os.mkdir_all(tpl) or { panic(err) }
	os.setenv('GRAPHIFY_TEST_CANNED', tpl, true)
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(out) or {}
	}
	os.write_file(os.join_path(tpl, 'crash_now'), '') or { panic(err) }
	g, r := build_graph_resilient(root, worker, out)
	assert 'crash.v' in r.failed, r.failed.str()
	assert r.stale.len == 0, r.stale.str()
	assert !g.symbols.any(it.id == 'demo.crash_fn'), g.symbols.map(it.id).str()
}

// check_crash_once runs a crash on crash.v that does not happen again: the file is
// parsed again in a worker of its own, so it is neither failed nor stale, and the
// file queued behind it is parsed too.
fn check_crash_once(worker string, dir string) {
	root := write_tree('worker_crash_once', {
		'crash.v': 'module demo\n\npub fn crash_fn() int {\n\treturn 2\n}\n'
		'z.v':     'module demo\n\npub fn z_fn() int {\n\treturn 3\n}\n'
	})
	tpl := os.join_path(dir, 'once')
	out := root + '_out'
	os.mkdir_all(tpl) or { panic(err) }
	os.setenv('GRAPHIFY_TEST_CANNED', tpl, true)
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(out) or {}
	}
	for rel in ['crash.v', 'z.v'] {
		write_canned(tpl, root, rel)
	}
	os.write_file(os.join_path(tpl, 'crash_once'), '') or { panic(err) }
	g, r := build_graph_resilient(root, worker, out)
	assert !os.exists(os.join_path(tpl, 'crash_once')) // the worker did crash
	assert r.failed.len == 0, r.failed.str()
	assert r.stale.len == 0, r.stale.str()
	ids := g.symbols.map(it.id)
	assert 'demo.crash_fn' in ids, ids.str()
	assert 'demo.z_fn' in ids, ids.str()
}

fn test_a_worker_crash_is_recovered_from_on_both_paths() {
	// one compile of the stand-in serves both cases; the directory they share is
	// removed at the end
	dir := os.join_path(os.temp_dir(), 'graphify_crash_worker_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	worker := compile_crash_worker(dir)
	check_carry_forward(worker, dir)
	check_first_sighting(worker, dir)
	check_crash_once(worker, dir)
}

fn test_a_c_function_binding_is_a_symbol_and_types_the_call_that_uses_it() {
	// `fn C.name(...)` is a function of the C namespace: a symbol with id `C.name`,
	// and a call of it has the result type its declaration gives
	root := write_tree('c_extern_binding', {
		'demo.v': 'module demo\n\npub struct Thing {\n}\n\npub fn (t Thing) size() int {\n\treturn 1\n}\n\nfn C.make_thing() Thing\n\nfn C.puts(s &char) int\n\npub fn use_it() int {\n\treturn C.make_thing().size() + C.puts(unsafe { nil })\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.symbols.any(it.id == 'C.puts' && it.kind == .function), g.symbols.map(it.id).str()
	assert g.symbols.any(it.id == 'C.make_thing' && it.signature == 'fn C.make_thing() Thing'), g.symbols.map(it.id).str()
	assert g.edges.any(it.kind == .calls && it.from == 'demo.use_it' && it.to == 'C.puts'), g.edges.filter(it.from == 'demo.use_it').map(it.to).str()
	assert g.edges.any(it.kind == .calls && it.from == 'demo.use_it' && it.to == 'demo.Thing.size'), g.edges.filter(it.from == 'demo.use_it').map(it.to).str()
}

fn test_a_c_call_the_program_binds_nowhere_is_undeclared() {
	// `C.puts` is bound in the program, so its call resolves; `C.close` is declared
	// only by a system header, so its call is undeclared, as a runtime helper's is
	root := write_tree('c_call_undeclared', {
		'demo.v': 'module demo\n\nfn C.puts(s &char) int\n\npub fn say() int {\n\treturn C.puts(unsafe { nil }) + C.close(1)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	calls := g.edges.filter(it.kind == .calls && it.from == 'demo.say')
	assert calls.any(it.to == 'C.puts' && it.provenance != .undeclared), calls.map(it.to).str()
	assert calls.any(it.to == 'C.close' && it.provenance == .undeclared), calls.map(it.to).str()
}

fn test_the_value_of_a_generated_enum_from_is_the_enum() {
	// V generates `Colour.from(x)` for every enum, and it returns a Colour, so a method
	// on its value is the enum's method
	root := write_tree('enum_from_value', {
		'demo.v': 'module demo\n\npub enum Colour as u8 {\n\tred\n}\n\npub fn (c Colour) size() int {\n\treturn 1\n}\n\npub fn pick() int {\n\tc := Colour.from(u8(1)) or { Colour.red }\n\treturn c.size()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.pick').map(it.to)
	assert 'demo.Colour.size' in targets, targets.str()
}

fn test_a_membership_test_is_a_bool_for_the_method_on_it() {
	// `('a' in xs).describe()` is a method on a bool, the type of an `in` test
	root := write_tree('membership_bool', {
		'demo.v': 'module demo\n\nfn (b bool) describe() string {\n\treturn \'b\'\n}\n\npub fn check(xs []string) string {\n\treturn (\'a\' in xs).describe()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.check').map(it.to)
	assert 'demo.bool.describe' in targets, targets.str()
}

fn test_a_method_on_a_type_parameter_links_to_each_instantiations_method() {
	// `show[T]` calls describe() on a value of type T, and it is called with a Box and a
	// Pen, so the call reaches the describe() of each
	root := write_tree('generic_instantiation', {
		'demo.v': 'module demo\n\npub struct Box {\n}\n\npub fn (b Box) describe() string {\n\treturn \'box\'\n}\n\npub struct Pen {\n}\n\npub fn (p Pen) describe() string {\n\treturn \'pen\'\n}\n\npub fn show[T](v T) string {\n\treturn v.describe()\n}\n\npub fn run() string {\n\treturn show(Box{}) + show(Pen{})\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.show').map(it.to)
	assert 'demo.Box.describe' in targets, targets.str()
	assert 'demo.Pen.describe' in targets, targets.str()
}

fn test_a_slice_parameter_takes_the_element_type_of_its_argument() {
	// `push[T](mut q []T)` is called with a []Node, so the method call on an element
	// of type T reaches Node.weight
	root := write_tree('slice_param_instantiation', {
		'demo.v': 'module demo\n\npub struct Node {\n\tv int\n}\n\npub fn (n Node) weight() int {\n\treturn n.v\n}\n\nfn push[T](mut q []T, x int) {\n\tfor e in q {\n\t\t_ = e.weight()\n\t}\n\t_ = x\n}\n\npub fn run() {\n\tmut q := []Node{}\n\tpush(mut q, 1)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.push').map(it.to)
	assert 'demo.Node.weight' in targets, targets.str()
}

fn test_a_mut_parameter_takes_the_element_type_of_its_argument() {
	// `push[T](mut q []T)` is written `q &[]T` in the signature, so its type is read past
	// the `&`. `weight` is declared on two types, so only the instantiation can say
	// which one the call means
	root := write_tree('mut_slice_param_instantiation', {
		'demo.v': 'module demo\n\npub struct Node {\n\tv int\n}\n\npub fn (n Node) weight() int {\n\treturn n.v\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 2\n}\n\nfn push[T](mut q []T, x int) {\n\tfor e in q {\n\t\t_ = e.weight()\n\t}\n\t_ = x\n}\n\npub fn run() {\n\tmut q := []Node{}\n\tpush(mut q, 1)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.push').map(it.to)
	assert 'demo.Node.weight' in targets, targets.str()
	assert 'demo.Other.weight' !in targets, targets.str()
}

fn test_a_mut_scalar_parameter_takes_the_type_of_its_argument() {
	// `show[T](mut v T)` is written `v &T` in the signature, and `describe` is declared
	// on two types, so only the argument's type can pick Box.describe
	root := write_tree('mut_scalar_param_instantiation', {
		'demo.v': 'module demo\n\npub struct Box {\n}\n\npub fn (b Box) describe() int {\n\treturn 1\n}\n\npub struct Pen {\n}\n\npub fn (p Pen) describe() int {\n\treturn 2\n}\n\nfn show[T](mut v T) int {\n\treturn v.describe()\n}\n\npub fn run() int {\n\tmut b := Box{}\n\treturn show(mut b)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.show').map(it.to)
	assert 'demo.Box.describe' in targets, targets.str()
	assert 'demo.Pen.describe' !in targets, targets.str()
}

fn test_a_method_of_a_generic_struct_links_its_type_parameter_to_each_instantiation() {
	// `total` calls weight() on its item, of type T, and Box is instantiated with a Node
	// and a Pen, so the call reaches the weight() of each. weight() is declared on three
	// types, so only the instantiations can say which ones the call means
	root := write_tree('generic_struct_instantiation', {
		'demo.v': 'module demo\n\npub struct Node {\n\tv int\n}\n\npub fn (n Node) weight() int {\n\treturn n.v\n}\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Box[T] {\n\titem T\n}\n\npub fn (b Box[T]) total() int {\n\treturn b.item.weight()\n}\n\npub fn run() int {\n\ta := Box[Node]{item: Node{v: 1}}\n\tp := Box[Pen]{item: Pen{}}\n\treturn a.total() + p.total()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Box[T].total').map(it.to)
	assert 'demo.Node.weight' in targets, targets.str()
	assert 'demo.Pen.weight' in targets, targets.str()
	assert 'demo.Other.weight' !in targets, targets.str()
}

fn test_a_generic_struct_in_a_field_type_instantiates_its_type_parameter() {
	// Holder has a field of type Box[Pen], and no call on a Box receives a Pen, so the
	// field's type is the only instantiation of Box; weight() is declared on two types,
	// so only that instantiation can say which one the call means
	root := write_tree('generic_struct_field_instantiation', {
		'demo.v': 'module demo\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Box[T] {\n\titem T\n}\n\npub fn (b Box[T]) total() int {\n\treturn b.item.weight()\n}\n\npub struct Holder {\n\tbox Box[Pen]\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Box[T].total').map(it.to)
	assert 'demo.Pen.weight' in targets, targets.str()
	assert 'demo.Other.weight' !in targets, targets.str()
}

fn test_a_generic_struct_in_a_field_of_a_renamed_struct_instantiates_its_type_parameter() {
	// Holder is declared in two test programs, so its id is told apart by file,
	// `vlib.v.tests.Holder@vlib/v/tests/a_test.v`, and the module its field type is
	// written in was read off that id up to its last dot, which is in the file name
	root := write_tree('generic_struct_field_renamed_owner', {
		'vlib/v/tests/box.v':    'module main\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Box[T] {\n\titem T\n}\n\npub fn (b Box[T]) total() int {\n\treturn b.item.weight()\n}\n'
		'vlib/v/tests/a_test.v': 'module main\n\nstruct Holder {\n\tbox Box[Pen]\n}\n\nfn test_a() {}\n'
		'vlib/v/tests/b_test.v': 'module main\n\nstruct Holder {\n\tn int\n}\n\nfn test_b() {}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.symbols.any(it.id == 'vlib.v.tests.Holder@vlib/v/tests/a_test.v')
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.v.tests.Box[T].total').map(it.to)
	assert 'vlib.v.tests.Pen.weight' in targets, targets.str()
	assert 'vlib.v.tests.Other.weight' !in targets, targets.str()
}

fn test_a_static_generic_call_with_a_type_argument_types_its_result() {
	// `Box.new[Pen](...)` is a generic static method, and its result is Box[Pen], so
	// `item` is a Pen; weight() is declared on two types, so only that can say which
	root := write_tree('static_generic_call', {
		'demo.v': 'module demo\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Box[T] {\n\titem T\n}\n\npub fn Box.new[T](item T) Box[T] {\n\treturn Box[T]{\n\t\titem: item\n\t}\n}\n\npub fn run() int {\n\ty := Box.new[Pen](Pen{})\n\treturn y.item.weight()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.run').map(it.to)
	assert 'demo.Pen.weight' in targets, targets.str()
	assert 'demo.Other.weight' !in targets, targets.str()
}

fn test_a_bare_call_in_a_method_names_the_receivers_method() {
	// `describe(1)` in `implicit` names no function, so it is the receiver's describe(),
	// as V calls it; a free function of the same name would win, as the callee shows
	root := write_tree('implicit_receiver_call', {
		'demo.v': 'module demo\n\npub struct Box[T] {\n\titem T\n}\n\npub fn (b Box[T]) describe(v int) int {\n\treturn v\n}\n\npub fn (b Box[T]) implicit() int {\n\treturn describe(1)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Box[T].implicit').map(it.to)
	assert 'demo.Box[T].describe' in targets, targets.str()
}

fn test_a_generic_struct_built_by_a_generic_function_takes_its_types() {
	// `build[T]` makes a Ctx[T] whose items are T, and build() is called with a Pen, so
	// the Ctx's first() reaches Pen.weight(), not Other.weight()
	root := write_tree('nested_generic_instantiation', {
		'demo.v': 'module demo\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Ctx[T] {\n\titems []T\n}\n\npub fn (c Ctx[T]) first() int {\n\treturn c.items[0].weight()\n}\n\npub fn build[T](x T) int {\n\tc := &Ctx[T]{\n\t\titems: [x]\n\t}\n\treturn c.first()\n}\n\npub fn run() int {\n\treturn build(Pen{})\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Ctx[T].first').map(it.to)
	assert 'demo.Pen.weight' in targets, targets.str()
	assert 'demo.Other.weight' !in targets, targets.str()
}

fn test_a_call_of_a_function_field_of_a_generic_struct_is_a_value_call() {
	// `func T` holds a function once FnHolder is instantiated with a function type, so
	// `self.func(a)` calls that value and names no method
	root := write_tree('function_field_value_call', {
		'demo.v': 'module demo\n\nfn neg(a int) int {\n\treturn -a\n}\n\npub struct FnHolder[T] {\n\tfunc T\n}\n\npub fn (self FnHolder[T]) call(a int) int {\n\treturn self.func(a)\n}\n\npub fn run() int {\n\treturn FnHolder[fn (int) int]{\n\t\tfunc: neg\n\t}.call(4)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	calls := g.edges.filter(it.kind == .calls && it.from == 'demo.FnHolder[T].call' && it.to == 'func')
	assert calls.len == 1, g.edges.map(it.to).str()
	assert calls[0].provenance == .undeclared, calls[0].provenance.str()
}

fn test_a_call_on_the_result_of_a_type_parameter_call_takes_that_result_type() {
	// `el.tag().size()` where el is T: tag() returns Tag, so size() is Tag's, and not
	// Other's, which the same name also has
	root := write_tree('chained_type_param_call', {
		'demo.v': 'module demo\n\npub struct Tag {\n\tn int\n}\n\npub fn (t Tag) size() int {\n\treturn t.n\n}\n\npub struct Other {\n}\n\npub fn (o Other) size() int {\n\treturn 2\n}\n\npub struct Aa {\n\ta string\n}\n\npub fn (a Aa) tag() Tag {\n\treturn Tag{\n\t\tn: 1\n\t}\n}\n\npub struct Choi[T] {\n\tsrc []T\n}\n\npub fn (c Choi[T]) content() int {\n\tmut n := 0\n\tfor el in c.src {\n\t\tn += el.tag().size()\n\t}\n\treturn n\n}\n\npub struct Holder {\n\tc Choi[Aa]\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Choi[T].content').map(it.to)
	assert 'demo.Tag.size' in targets, targets.str()
	assert 'demo.Other.size' !in targets, targets.str()
}

fn test_a_type_passed_through_two_generic_functions_reaches_the_struct_it_builds() {
	// `outer[T]` passes its T to `inner[T]`, which builds a Ctx[T]: the Ctx's first() takes
	// the types of outer's calls, Pen from run() and Other from Box[Other].total()
	root := write_tree('two_deep_instantiation', {
		'demo.v': 'module demo\n\npub struct Pen {\n}\n\npub fn (p Pen) weight() int {\n\treturn 2\n}\n\npub struct Other {\n}\n\npub fn (o Other) weight() int {\n\treturn 3\n}\n\npub struct Ctx[T] {\n\titems []T\n}\n\npub fn (c Ctx[T]) first() int {\n\treturn c.items[0].weight()\n}\n\npub fn inner[T](x T) int {\n\tc := &Ctx[T]{\n\t\titems: [x]\n\t}\n\treturn c.first()\n}\n\npub fn outer[T](x T) int {\n\treturn inner(x)\n}\n\npub fn run() int {\n\treturn outer(Pen{})\n}\n\npub struct Box[T] {\n\titem T\n}\n\npub fn (b Box[T]) total() int {\n\treturn outer(b.item)\n}\n\npub fn run_box() int {\n\tb := Box[Other]{\n\t\titem: Other{}\n\t}\n\treturn b.total()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.Ctx[T].first').map(it.to)
	assert 'demo.Pen.weight' in targets, targets.str()
	assert 'demo.Other.weight' in targets, targets.str()
}

fn test_a_call_in_a_comptime_branch_on_a_type_parameter_links_only_the_instances_it_compiles_for() {
	// `v.area()` is compiled only for an interface instance, and `v.release()` only for
	// the others, so the struct Pen, which the interface branch never compiles for, does not
	// reach Pen.area()
	root := write_tree('comptime_branch_guard', {
		'demo.v': 'module demo\n\npub interface Shape {\n\tarea() int\n}\n\npub struct Pen {\n}\n\npub fn (p Pen) area() int {\n\treturn 1\n}\n\npub fn (p Pen) release() int {\n\treturn 3\n}\n\npub fn use_it[T](v T) int {\n\t$if T.unaliased_typ is $interface {\n\t\treturn v.area()\n\t} $else {\n\t\treturn v.release()\n\t}\n}\n\npub fn run() int {\n\treturn use_it(Pen{})\n}\n\npub fn run_shape(s Shape) int {\n\treturn use_it(s)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.use_it').map(it.to)
	assert 'demo.Pen.release' in targets, targets.str()
	assert 'demo.Pen.area' !in targets, targets.str()
	assert 'demo.Shape.area' in targets, targets.str()
}

fn test_a_c_binding_result_type_picks_the_method_among_same_named_ones() {
	// two types declare `size`, so only the result type of C.make_thing() can tell
	// which one the call means
	root := write_tree('c_binding_result_type', {
		'demo.v': 'module demo\n\npub struct Thing {\n}\n\npub fn (t Thing) size() int {\n\treturn 1\n}\n\npub struct Other {\n}\n\npub fn (o Other) size() int {\n\treturn 2\n}\n\nfn C.make_thing() Thing\n\npub fn use_it() int {\n\treturn C.make_thing().size()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.use_it').map(it.to)
	assert 'demo.Thing.size' in targets, targets.str()
	assert 'demo.Other.size' !in targets, targets.str()
}

fn test_a_c_binding_declared_in_several_test_files_is_one_function() {
	// each test file is its own build unit, so a V function of one name there is one
	// per file; a C binding is one function, so the call in use.v reaches `C.puts`
	root := write_tree('c_binding_copies', {
		'a_test.v': 'module demo\n\nfn C.puts(s &char) int\n\nfn test_a() {\n\t_ = C.puts(unsafe { nil })\n}\n'
		'b_test.v': 'module demo\n\nfn C.puts(s &char) int\n\nfn test_b() {\n\t_ = C.puts(unsafe { nil })\n}\n'
		'use.v':    'module demo\n\npub fn use_it() int {\n\treturn C.puts(unsafe { nil })\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.use_it').map(it.to)
	// the call reaches one copy of the binding, which may carry its file as a suffix
	assert targets.any(it.all_before('@') == 'C.puts'), targets.str()
}

fn test_a_c_type_conversion_is_a_call_of_the_c_type() {
	// `type C.DWORD = u32` is a C type, and `C.DWORD(x)` converts to it, so the call
	// reaches the type rather than staying unresolved
	root := write_tree('c_type_conversion', {
		'demo.c.v': 'module demo\n\ntype C.DWORD = u32\n\npub fn conv() u32 {\n\treturn C.DWORD(3)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	assert g.symbols.any(it.id == 'C.DWORD' && it.kind == .type_alias), g.symbols.map(it.id).str()
	targets := g.edges.filter(it.kind == .calls && it.from == 'demo.conv').map(it.to)
	assert 'C.DWORD' in targets, targets.str()
}

fn test_a_tuple_from_a_match_or_if_takes_each_element_type_from_its_branch() {
	// `compressed` is the first value of each branch's tuple, `c`, which the branch declares from
	// zstd.compress(), so bytestr() on it is the []u8 method. Http's Response has a bytestr() too,
	// so the call is only resolved by the type of `compressed`, not by the name alone
	root := write_tree('tuple_from_branch', {
		'vlib/builtin/int.v':        'module builtin\n\npub fn (b []u8) bytestr() string {\n\treturn ""\n}\n'
		'vlib/net/http/response.v':  'module http\n\npub struct Response {\n}\n\npub fn (r Response) bytestr() string {\n\treturn ""\n}\n'
		'vlib/compress/zstd/zstd.v': 'module zstd\n\npub struct CompressParams {\npub:\n\tlevel int\n}\n\npub fn compress(data []u8, params CompressParams) ![]u8 {\n\treturn data\n}\n'
		'vlib/veb/context.v':        'module veb\n\nimport compress.zstd\nimport net.http\n\npub enum ContentEncoding {\n\tgzip\n\tzstd\n}\n\npub fn pack(encoding ContentEncoding, data string) string {\n\tcompressed, ext, encoding_name := match encoding {\n\t\t.zstd {\n\t\t\tc := zstd.compress(data.bytes(), zstd.CompressParams{}) or { return "" }\n\t\t\tc, ".zst", "zstd"\n\t\t}\n\t\t.gzip {\n\t\t\tc := zstd.compress(data.bytes(), zstd.CompressParams{}) or { return "" }\n\t\t\tc, ".gz", "gzip"\n\t\t}\n\t}\n\treturn compressed.bytestr() + ext + encoding_name\n}\n\npub fn pack_if(encoding ContentEncoding, data string) string {\n\tcompressed, ext := if encoding == .zstd {\n\t\tc := zstd.compress(data.bytes(), zstd.CompressParams{}) or { return "" }\n\t\tc, ".zst"\n\t} else {\n\t\tc := zstd.compress(data.bytes(), zstd.CompressParams{}) or { return "" }\n\t\tc, ".gz"\n\t}\n\treturn compressed.bytestr() + ext\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.pack').map(it.to)
	assert 'vlib.builtin.[]u8.bytestr' in targets, targets.str()
	targets_if := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.pack_if').map(it.to)
	assert 'vlib.builtin.[]u8.bytestr' in targets_if, targets_if.str()
}

fn test_a_map_of_a_method_on_each_element_types_the_elements_by_that_method() {
	// `ct` is the strings that `split` gives, each `trim_left`ed, so `ct[0]` is a string and its
	// trim() and to_lower() are the string methods. An array's trim() would match by name alone
	root := write_tree('map_of_method', {
		'vlib/builtin/string.v': 'module builtin\n\npub fn (s string) split(delim string) []string {\n\treturn []string{}\n}\n\npub fn (s string) trim_left(cutset string) string {\n\treturn s\n}\n\npub fn (s string) trim(cutset string) string {\n\treturn s\n}\n\npub fn (s string) to_lower() string {\n\treturn s\n}\n'
		'vlib/builtin/array.v':  'module builtin\n\npub fn (a array) trim(x string) array {\n\treturn a\n}\n'
		'vlib/veb/parse.v':      "module veb\n\npub fn parse(header string) string {\n\tct := header.split(';').map(it.trim_left(' \\t'))\n\treturn ct[0].trim(' \\t').to_lower()\n}\n"
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.parse').map(it.to)
	assert 'vlib.builtin.string.trim' in targets, targets.str()
	assert 'vlib.builtin.string.to_lower' in targets, targets.str()
}

fn test_a_comptime_check_against_an_interface_keeps_the_instance_for_its_fields() {
	// `$if T is ControllerInterface` compiles the block for each instance that implements the
	// interface, and global_app is still that instance, so `controllers` is the Ctl's field, an
	// array. string has a clone() too, so only the field's type names the array's
	root := write_tree('comptime_interface', {
		'vlib/builtin/array.v':  'module builtin\n\npub fn (a array) clone() array {\n\treturn a\n}\n'
		'vlib/builtin/string.v': 'module builtin\n\npub fn (s string) clone() string {\n\treturn s\n}\n'
		'vlib/veb/controller.v': 'module veb\n\npub struct ControllerPath {\npub:\n\tpath string\n}\n\npub interface ControllerInterface {\n\tcontrollers []&ControllerPath\n}\n\nfn check_duplicate_routes[T](global_app &T) []&ControllerPath {\n\tmut controllers_sorted := []&ControllerPath{}\n\t$if T is ControllerInterface {\n\t\tcontrollers_sorted = global_app.controllers.clone()\n\t}\n\treturn controllers_sorted\n}\n\npub struct Ctl {\npub mut:\n\tcontrollers []&ControllerPath\n}\n\npub fn run_check(app &Ctl) []&ControllerPath {\n\treturn check_duplicate_routes[Ctl](app)\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.check_duplicate_routes').map(it.to)
	assert 'vlib.builtin.array.clone' in targets, targets.str()
}

fn test_a_method_on_a_field_of_a_closure_type_parameter_takes_the_field_of_the_receivers_instance() {
	// the closure's `ctx T` is the T of Throttle[T], so `ctx.res.header` is the Header of the Context
	// the throttle is made for. Other has a set() too, which the name alone would leave ambiguous
	root := write_tree('closure_type_parameter', {
		'vlib/veb/throttle.v': "module veb\n\npub struct Header {\n}\n\npub fn (h Header) set(key string, value string) {\n}\n\npub struct Response {\npub mut:\n\theader Header\n}\n\npub struct Base {\npub mut:\n\tres Response\n}\n\npub struct Context {\n\tBase\n}\n\npub struct Other {\n}\n\npub fn (o Other) set() {\n}\n\npub struct Throttle[T] {\npub:\n\twait int\n}\n\npub struct MiddlewareOptions[T] {\npub:\n\thandler fn (mut T) bool\n}\n\npub fn (t Throttle[T]) acquire() MiddlewareOptions[T] {\n\treturn MiddlewareOptions[T]{\n\t\thandler: fn [t] [T](mut ctx T) bool {\n\t\t\tctx.res.header.set('a', 'b')\n\t\t\treturn true\n\t\t}\n\t}\n}\n\npub fn throttle[T](wait int) Throttle[T] {\n\treturn Throttle[T]{\n\t\twait: wait\n\t}\n}\n\npub fn run() MiddlewareOptions[Context] {\n\tth := throttle[Context](1)\n\treturn th.acquire()\n}\n"
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.Throttle[T].acquire').map(it.to)
	assert 'vlib.veb.Header.set' in targets, targets.str()
	assert 'vlib.veb.Other.set' !in targets, targets.str()
}

fn test_a_call_with_an_argument_narrowed_to_an_interface_passes_the_instance_on() {
	// handle_route calls app_global_handlers(app) only in a `$if A is Handlers` block, so its app is
	// the interface, which the instance keeps. Other has the same method name, which the name alone
	// would leave ambiguous
	root := write_tree('narrowed_argument', {
		'vlib/veb/middleware.v': "module veb\n\npub struct Middleware[T] {\npub mut:\n\thandlers []voidptr\n}\n\npub fn (m &Middleware[T]) get_global_handlers() []voidptr {\n\treturn m.handlers\n}\n\npub interface Handlers {\n\tget_global_handlers() []voidptr\n}\n\npub struct Other {\n}\n\npub fn (o &Other) get_global_handlers() []voidptr {\n\treturn []voidptr{}\n}\n\npub struct Context {\n}\n\npub struct App {\n\tMiddleware[Context]\n}\n\nfn app_global_handlers[A](app &A) []voidptr {\n\t$if A is $struct {\n\t\t$for field in A.fields {\n\t\t\t$if field.is_embed {\n\t\t\t\t$if field.name == 'Middleware' {\n\t\t\t\t\treturn app.$(field.name).get_global_handlers()\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n\treturn []voidptr{}\n}\n\nfn handle_route[A](mut app A) []voidptr {\n\t$if A is Handlers {\n\t\treturn app_global_handlers(app)\n\t}\n\treturn []voidptr{}\n}\n\nfn run_new[A](mut app A) []voidptr {\n\treturn handle_route[A](mut app)\n}\n\npub fn run_at[A](mut app A) []voidptr {\n\treturn run_new[A](mut app)\n}\n\npub fn serve() []voidptr {\n\tmut app := App{}\n\treturn run_at[App](mut app)\n}\n"
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.app_global_handlers').map(it.to)
	assert 'vlib.veb.Middleware[T].get_global_handlers' in targets, targets.str()
	assert 'vlib.veb.Other.get_global_handlers' !in targets, targets.str()
}

fn test_an_embedded_type_is_the_one_its_file_sees_not_a_test_only_one_of_the_same_name() {
	// ThrottleContext, in a test file, embeds Context, and other_test.v has its own Context that no
	// file but other_test.v sees. So the embed is veb's Context and its res reaches the Header's set()
	root := write_tree('embedded_test_private', {
		'vlib/veb/context.v':       'module veb\n\npub struct Response {\npub mut:\n\theader Header\n}\n\npub struct Header {\n}\n\npub fn (h Header) set(key string, value string) {\n}\n\npub struct Context {\npub mut:\n\tres Response\n}\n'
		'vlib/veb/other_test.v':    'module veb\n\npub struct Context {\n}\n'
		'vlib/veb/other.v':         'module veb\n\npub struct Other {\n}\n\npub fn (o Other) set() {\n}\n'
		'vlib/veb/throttle.v':      "module veb\n\npub struct Throttle[T] {\npub:\n\twait int\n}\n\npub struct MiddlewareOptions[T] {\npub:\n\thandler fn (mut T) bool\n}\n\npub fn (t Throttle[T]) acquire() MiddlewareOptions[T] {\n\treturn MiddlewareOptions[T]{\n\t\thandler: fn [t] [T](mut ctx T) bool {\n\t\t\tctx.res.header.set('a', 'b')\n\t\t\treturn true\n\t\t}\n\t}\n}\n\npub fn throttle[T](wait int) Throttle[T] {\n\treturn Throttle[T]{\n\t\twait: wait\n\t}\n}\n"
		'vlib/veb/throttle_test.v': 'module veb\n\nstruct ThrottleContext {\n\tContext\n}\n\npub fn make() MiddlewareOptions[ThrottleContext] {\n\tth := throttle[ThrottleContext](1)\n\treturn th.acquire()\n}\n'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.Throttle[T].acquire').map(it.to)
	assert 'vlib.veb.Header.set' in targets, targets.str()
	assert 'vlib.veb.Other.set' !in targets, targets.str()
}

fn test_a_field_named_by_a_comptime_check_in_a_field_loop_is_the_field_the_call_is_on() {
	// `app.$(field.name)` is the embedded Middleware in the block of `$if field.name == 'Middleware'`,
	// so the call is Middleware's method. Other has a method of the same name that is not embedded,
	// which the name alone would leave ambiguous
	root := write_tree('field_name_pin', {
		'vlib/veb/middleware.v': "module veb\n\npub struct Middleware {\npub mut:\n\thandlers []voidptr\n}\n\npub fn (m &Middleware) get_global_handlers() []voidptr {\n\treturn m.handlers\n}\n\npub struct Other {\n}\n\npub fn (o &Other) get_global_handlers() []voidptr {\n\treturn []voidptr{}\n}\n\npub struct App {\n\tMiddleware\n}\n\nfn app_global_handlers[A](app &A) []voidptr {\n\t$if A is $struct {\n\t\t$for field in A.fields {\n\t\t\t$if field.is_embed {\n\t\t\t\t$if field.name == 'Middleware' {\n\t\t\t\t\treturn app.$(field.name).get_global_handlers()\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n\treturn []voidptr{}\n}\n\npub fn run(app &App) []voidptr {\n\treturn app_global_handlers[App](app)\n}\n"
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root })
	targets := g.edges.filter(it.kind == .calls && it.from == 'vlib.veb.app_global_handlers').map(it.to)
	assert 'vlib.veb.Middleware.get_global_handlers' in targets, targets.str()
	assert 'vlib.veb.Other.get_global_handlers' !in targets, targets.str()
}

// library_fixture writes a V checkout (vroot), a VMODULES directory and a project
// beside them, as the library layer reads them (FUTURE_WORK.md §10).
fn library_fixture(name string) (string, LibraryRoots) {
	base := write_tree(name, {
		'v/vlib/builtin/string.v':  'module builtin

pub struct string {
	len int
}

pub fn (s string) contains(sub string) bool {
	return true
}
'
		'v/vlib/os/os.v':           'module os

// join_path joins its parts.
pub fn join_path(base string, dirs ...string) string {
	return base
}

pub fn rm(path string) ! {
	return
}
'
		'v/vlib/json2/decode.v':    'module json2

pub fn decode[T](src string) !T {
	return T{}
}
'
		'v/vlib/x/json2/alias.v':   "@[alias: '@VMODROOT/vlib/json2']
module json2
"
		'vmodules/glyph/glyph.v':   'module glyph

pub struct Ctx {}

pub fn new() Ctx {
	return Ctx{}
}
'
		'proj/v.mod':               "Module {
	name: 'proj'
}
"
		'proj/main.v':              'module main

import os
import x.json2 as json
import glyph

struct Widget {}

fn (w Widget) contains(sub string) bool {
	return false
}

struct Conf {
	name string
}

fn run(s string) bool {
	p := os.join_path(s, "b")
	_ := glyph.new()
	c := json.decode[Conf](s) or { Conf{} }
	return s.contains(p + c.name)
}

fn main() {}
'
	})
	roots := LibraryRoots{
		vroot:    os.real_path(os.join_path(base, 'v'))
		vmodules: os.real_path(os.join_path(base, 'vmodules'))
	}
	return base, roots
}

fn test_a_library_directory_of_tests_alone_is_no_module() {
	// module_of looks in VROOT's vlib and then VMODULES; a vlib directory holding only
	// tests is no module, so `foo` is VMODULES' (has_v_sources). vmodules_own_import
	// likewise skips a tests-only directory beside the v.mod.
	base := write_tree('library_tests_only', {
		'v/vlib/foo/foo_test.v':         'module foo\n\nfn test_f() {}\n'
		'vmodules/foo/foo.v':            'module foo\n\npub fn f() {}\n'
		'vmodules/pkg/v.mod':            ''
		'vmodules/pkg/pkg.v':            'module pkg\n\nimport helpers\n'
		'vmodules/pkg/helpers/h_test.v': 'module helpers\n\nfn test_h() {}\n'
	})
	defer {
		os.rmdir_all(base) or {}
	}
	roots := LibraryRoots{
		vroot:    os.real_path(os.join_path(base, 'v'))
		vmodules: os.real_path(os.join_path(base, 'vmodules'))
	}
	m := roots.module_of('foo') or { panic('foo not found') }
	assert m.rel_dir.starts_with(lib_vmodules_prefix), m.str()
	old := os.getenv(lib_env_vmodules)
	os.setenv(lib_env_vmodules, roots.vmodules, true)
	defer {
		os.setenv(lib_env_vmodules, old, true)
	}
	if own := vmodules_own_import('helpers', os.join_path(roots.vmodules, 'pkg', 'pkg.v')) {
		assert false, 'a tests-only directory was taken as a module: ${own}'
	}
}

fn test_a_project_resolves_its_calls_into_the_library() {
	// A project's tree has no vlib, so `s.contains` linked by name to the project's
	// only `contains` (Widget's), and `os.join_path`, `json.decode` and `glyph.new`
	// had nothing to resolve to. With the library read, each goes to its declaration,
	// and only the declarations the project reaches are kept, apart from its own.
	base, roots := library_fixture('library_calls')
	defer {
		os.rmdir_all(base) or {}
		os.setenv('GRAPHIFY_LIB_VROOT', '', true)
		os.setenv('GRAPHIFY_LIB_VMODULES', '', true)
	}
	g, _ := build_graph_with_library(os.join_path(base, 'proj'), '', os.join_path(base,
		'out'), roots)
	calls := g.edges.filter(it.kind == .calls && it.from == 'main.run').map(it.to)
	assert 'vlib.builtin.string.contains' in calls, calls.str()
	assert 'main.Widget.contains' !in calls, calls.str()
	assert 'vlib.os.join_path' in calls, calls.str()
	assert 'vlib.json2.decode' in calls, calls.str()
	assert 'vmodules.glyph.new' in calls, calls.str()
	lib_ids := g.library.symbols.map(it.id)
	assert 'vlib.os.join_path' in lib_ids && 'vlib.builtin.string' in lib_ids, lib_ids.str()
	// nothing the project reaches, so not kept
	assert 'vlib.os.rm' !in lib_ids, lib_ids.str()
	assert !g.symbols.any(it.file.starts_with('vlib/') || it.file.starts_with('vmodules/'))
	assert g.library.roots['vlib'] == roots.vroot
	r := g.report()
	assert r.contains('- library: '), r
	assert r.contains('- calls: extracted') && r.contains(', library '), r
	// get_body of a library declaration ends with it, though the next one in its
	// file (`rm`) is not kept
	body := g.get_body('vlib.os.join_path')
	assert body.contains('pub fn join_path') && body.contains('return base') && !body.contains('fn rm'), body
	assert g.explain('main.run').contains('join_path (vlib/os/os.v:4) [library]'), g.explain('main.run')
}

fn test_a_module_linked_into_vmodules_from_the_project_is_the_projects_own() {
	// `import proj.web` in proj names its own `web` module, which V finds through
	// ~/.vmodules/proj, a link to the checkout. It was read again as a library, and
	// the project's calls went to that copy.
	base, roots := library_fixture('library_self_link')
	defer {
		os.rmdir_all(base) or {}
		os.setenv('GRAPHIFY_LIB_VROOT', '', true)
		os.setenv('GRAPHIFY_LIB_VMODULES', '', true)
	}
	proj := os.join_path(base, 'proj')
	os.mkdir_all(os.join_path(proj, 'web')) or { panic(err) }
	os.write_file(os.join_path(proj, 'web', 'web.v'), 'module web\n\npub fn get(url string) string {\n\treturn url\n}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(proj, 'example.v'), 'module main\n\nimport proj.web\n\nfn fetch() string {\n\treturn web.get("x")\n}\n') or {
		panic(err)
	}
	os.symlink(proj, os.join_path(roots.vmodules, 'proj')) or { return }
	g, _ := build_graph_with_library(proj, '', os.join_path(base, 'out'), roots)
	calls := g.edges.filter(it.kind == .calls && it.from == 'main.fetch').map(it.to)
	assert calls == ['web.get'], calls.str()
	assert !g.library.symbols.any(it.id.starts_with('vmodules.proj')), g.library.symbols.map(it.id).str()
}

fn test_a_call_in_a_field_default_resolves_by_its_module() {
	// A field's site took its struct as its module, so a call in the field's default
	// that two modules declare (`rgba` in gui and in gg) was not placed by module, as
	// the same call in a function of the module is.
	g := graph_of({
		'gui/color.v': 'module gui\n\npub struct Color {\n\tr u8\n}\n\npub fn rgba(r u8, g u8, b u8, a u8) Color {\n\treturn Color{r}\n}\n'
		'gui/view.v':  'module gui\n\npub struct Style {\n\tbg Color = rgba(0, 0, 0, 50)\n}\n'
		'gg/color.v':  'module gg\n\npub struct Color {\n\tr u8\n}\n\npub fn rgba(r u8, g u8, b u8, a u8) Color {\n\treturn Color{r}\n}\n'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'gui.Style.bg').map(it.to)
	assert calls == ['gui.rgba'], calls.str()
}

fn test_graph_json_has_a_library_section_only_when_it_reads_one() {
	// a graph without a library is written as before, and one with it keeps its
	// declarations apart from the project's when it is read back
	mut g := Graph{
		root: '/p'
	}
	g.symbols << Symbol{
		id:   'main.run'
		name: 'run'
		kind: .function
		file: 'main.v'
	}
	assert !graph_to_json(g).contains('"library"')
	g.library.roots['vlib'] = '/v'
	g.library.symbols << Symbol{
		id:   'vlib.os.join_path'
		name: 'join_path'
		kind: .function
		file: 'vlib/os/os.v'
		line: 4
	}
	dir := os.join_path(os.temp_dir(), 'graphify_test_library_json_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'graph.json')
	save_graph(g, path) or { panic(err) }
	back := load_graph(path) or { panic(err) }
	assert back.symbols.map(it.id) == ['main.run']
	assert back.library.symbols.map(it.id) == ['vlib.os.join_path']
	assert back.library.roots['vlib'] == '/v'
}

// layer_fixture is a V tree's graph with gg in vlib, a test of it and a tool in
// cmd, and a project calling gg.draw, with a library section of its own.
fn layer_fixture() (Graph, Graph) {
	base_root := write_tree('layer_base', {
		'vlib/gg/gg.v':        'module gg\n\npub fn draw() {\n\tflush()\n}\n\nfn flush() {}\n\nfn helper() {}\n'
		'vlib/gg/gg_test.v':   'module gg\n\nfn test_draw() {}\n'
		'vlib/gg/gg_test.c.v': 'module gg\n\nfn test_native() {}\n'
		'cmd/tool.v':          'module main\n\nfn main() {}\n'
		'vmodules/ext/ext.v':  'module ext\n\npub fn f() {\n\tgg.flush()\n}\n'
	})
	base := Graph{
		root:    base_root
		symbols: [
			Symbol{
				id:        'vlib.gg.draw'
				name:      'draw'
				kind:      .function
				signature: 'pub fn draw()'
				file:      'vlib/gg/gg.v'
				line:      3
				end_line:  3
			},
			Symbol{
				id:        'vlib.gg.flush'
				name:      'flush'
				kind:      .function
				signature: 'fn flush()'
				file:      'vlib/gg/gg.v'
				line:      7
				end_line:  7
			},
			Symbol{
				id:        'vlib.gg.helper'
				name:      'helper'
				kind:      .function
				signature: 'fn helper()'
				file:      'vlib/gg/gg.v'
				line:      9
				end_line:  9
			},
			Symbol{
				id:   'vlib.gg.test_draw'
				name: 'test_draw'
				kind: .function
				file: 'vlib/gg/gg_test.v'
				line: 3
			},
			Symbol{
				id:   'vlib.gg.test_native'
				name: 'test_native'
				kind: .function
				file: 'vlib/gg/gg_test.c.v'
				line: 3
			},
			Symbol{
				id:   'cmd.main'
				name: 'main'
				kind: .function
				file: 'cmd/tool.v'
				line: 3
			},
		]
		edges:   [
			Edge{
				from: 'vlib.gg.draw'
				to:   'vlib.gg.flush'
				kind: .calls
			},
			Edge{
				from: 'vlib.gg.test_draw'
				to:   'vlib.gg.draw'
				kind: .calls
			},
		]
	}
	project := Graph{
		root:    '/nowhere/proj'
		symbols: [
			Symbol{
				id:        'proj.redraw'
				name:      'redraw'
				kind:      .function
				signature: 'fn redraw()'
				file:      'proj.v'
				line:      3
			},
			Symbol{
				id:        'proj.helper'
				name:      'helper'
				kind:      .function
				signature: 'fn helper()'
				file:      'proj.v'
				line:      7
			},
		]
		edges:   [
			Edge{
				from: 'proj.redraw'
				to:   'vlib.gg.draw'
				kind: .calls
			},
			// a name the project's own declaration answers, which vlib has too
			Edge{
				from: 'proj.redraw'
				to:   'helper'
				kind: .calls
			},
			Edge{
				from: 'proj.helper'
				to:   'vmodules.ext.f'
				kind: .calls
			},
			// a module from VMODULES, kept whole, calls into vlib, and has a call its
			// extract left unresolved
			Edge{
				from: 'vmodules.ext.f'
				to:   'vlib.gg.flush'
				kind: .calls
			},
			Edge{
				from: 'vmodules.ext.f'
				to:   'helper'
				kind: .calls
			},
		]
		library: Library{
			roots:   {
				'vlib':     base_root
				'vmodules': os.join_path(base_root, 'vmodules')
			}
			symbols: [
				Symbol{
					id:   'vlib.gg.draw'
					name: 'draw'
					kind: .function
					file: 'vlib/gg/gg.v'
					line: 3
				},
				Symbol{
					id:        'vmodules.ext.f'
					name:      'f'
					kind:      .function
					signature: 'pub fn f()'
					file:      'vmodules/ext/ext.v'
					line:      3
					end_line:  5
				},
			]
		}
	}
	return project, base
}

fn test_a_project_layered_on_the_v_tree_carries_on_into_vlib() {
	project, base := layer_fixture()
	g := layer_graph(project, base)
	// one path from the project, through the vlib function it calls, to what that calls
	assert g.shortest_path('proj.redraw', 'vlib.gg.flush') == ['proj.redraw', 'vlib.gg.draw',
		'vlib.gg.flush']
	// and the chain of calls, which goes on through vlib's own
	assert g.call_path('proj.redraw', 'vlib.gg.flush') == ['proj.redraw', 'vlib.gg.draw',
		'vlib.gg.flush']
	// vlib's tests and the rest of the tree stay out
	for id in ['vlib.gg.test_draw', 'vlib.gg.test_native', 'cmd.main'] {
		assert !g.index().has(id), id
	}
	// a raw name of the project's is still its own declaration, though vlib has one too
	idx := g.index()
	assert idx.edges.any(it.from == 'proj.redraw' && it.to == 'proj.helper')
	// a search seeds from vlib's matches as from the project's, a name it is first
	assert g.find('draw') == ['vlib.gg.draw', 'proj.redraw']
	assert g.find('flush') == ['vlib.gg.flush']
	// a vlib body is read from the V tree, and explain marks vlib and shows the project's callers
	assert g.get_body('vlib.gg.flush').contains('fn flush() {}')
	ex := g.explain('vlib.gg.draw')
	assert ex.contains('[library]')
	assert ex.contains('redraw (proj.v:3)')
	// a module from VMODULES joins the traversal as vlib does, read from where it is
	// installed, and its unresolved call isn't linked to the project's `helper`
	assert g.shortest_path('proj.helper', 'vlib.gg.flush') == ['proj.helper', 'vmodules.ext.f',
		'vlib.gg.flush']
	assert g.call_path('proj.helper', 'vlib.gg.flush') == ['proj.helper', 'vmodules.ext.f',
		'vlib.gg.flush']
	assert g.get_body('vmodules.ext.f').contains('gg.flush()')
	assert !idx.edges.any(it.from == 'vmodules.ext.f' && it.to == 'proj.helper')
	assert g.explain('vmodules.ext.f').contains('[library]')
	assert g.library.symbols.len == 0
	// the project's graph itself is untouched
	assert isnil(project.base.under)
}

fn test_a_project_declaration_shadows_the_one_of_vlib_with_its_id() {
	mut project, mut base := layer_fixture()
	base.edges << Edge{
		from: 'vlib.gg.flush'
		to:   'vlib.gg.helper'
		kind: .calls
	}
	// the project declares vlib's `flush` itself, by its id
	project.symbols << Symbol{
		id:        'vlib.gg.flush'
		name:      'flush'
		kind:      .function
		signature: 'fn flush()'
		file:      'proj.v'
		line:      9
	}
	mut g := layer_graph(project, base)
	g.cache_index()
	// the project's is the one shown, and vlib's call into it reaches it
	ex := g.explain('vlib.gg.flush')
	assert ex.starts_with('fn flush  (proj.v:9)\n'), ex
	assert ex.contains('called by     : f (vmodules/ext/ext.v:3) [library], draw (vlib/gg/gg.v:3) [library]'), ex
	assert g.shortest_path('proj.redraw', 'vlib.gg.flush') == ['proj.redraw', 'vlib.gg.draw',
		'vlib.gg.flush']
	// and the chain of calls, which goes on through vlib's own
	assert g.call_path('proj.redraw', 'vlib.gg.flush') == ['proj.redraw', 'vlib.gg.draw',
		'vlib.gg.flush']
	// what vlib's own `flush` calls isn't the project's
	assert g.neighbor_names('vlib.gg.flush') == ['f', 'draw']
	assert g.neighbor_names('vlib.gg.helper') == []string{}
	assert g.shortest_path('vlib.gg.draw', 'vlib.gg.helper') == []
	// draw and helper from vlib, and the module from VMODULES
	assert g.index().base_count == 3
}

fn test_a_project_graph_is_found_by_the_root_that_holds_the_directory() {
	tree := write_tree('layer_dirs', {
		'gui/a.v':     ''
		'gui/sub/a.v': ''
		'gui2/a.v':    ''
		'vlang/a.v':   ''
		'other/a.v':   ''
	})
	mut files := map[string]string{}
	for name, root in {
		'gui':   'gui'
		'inner': 'gui/sub'
		'gui2':  'gui2'
		'vlang': 'vlang'
	} {
		files['${name}/graph.json'] = '{}'
		files['${name}/manifest.json'] = json_root(os.join_path(tree, root))
	}
	// a directory without a graph.json is passed over
	files['stray/manifest.json'] = json_root(os.join_path(tree, 'other'))
	store := write_tree('layer_store', files)
	graph := fn [store] (name string) string {
		return os.join_path(store, name, 'graph.json')
	}
	base := os.join_path(tree, 'vlang')
	assert project_for(store, os.join_path(tree, 'gui'), base) or { '' } == graph('gui')
	// the deepest root that holds it: a project inside another, or a worktree's own graph
	assert project_for(store, os.join_path(tree, 'gui', 'sub'), base) or { '' } == graph('inner')
	// `gui2` is not inside `gui`
	assert project_for(store, os.join_path(tree, 'gui2'), base) or { '' } == graph('gui2')
	// the base's own tree, and a directory no project holds, serve the base alone
	assert project_for(store, base, base) == none
	assert project_for(store, os.join_path(tree, 'other'), base) == none
	assert project_for('', os.join_path(tree, 'gui'), base) == none
}

fn json_root(root string) string {
	return '{"root": "${root.replace('\\', '\\\\')}"}'
}

fn test_the_layer_note_says_when_the_project_read_another_vlib() {
	vroot := write_tree('layer_vroot', {
		'vlib/a.v': ''
	})
	esc := vroot.replace('\\', '\\\\')
	note := fn [esc] (lib_root string, lib_commit string, base_commit string) string {
		store := write_tree('layer_note', {
			'proj/graph.json':     '{}'
			'proj/manifest.json':  '{"root": "/p", "library": [{"label": "vlib", "root": "${lib_root}", "commit": "${lib_commit}"}]}'
			'vlang/graph.json':    '{}'
			'vlang/manifest.json': '{"root": "${esc}", "source_commit": "${base_commit}"}'
		})
		return layer_note(os.join_path(store, 'proj', 'graph.json'), os.join_path(store,
			'vlang', 'graph.json'))
	}
	assert note(esc, 'aaaa', 'aaaa') == ''
	assert note(esc, 'aaaa', 'bbbb').contains('extracted at bbbb')
	assert note('/elsewhere', 'aaaa', 'aaaa').contains('read vlib from /elsewhere')
}

fn test_a_project_is_layered_on_the_graph_of_the_vlib_it_read() {
	vroot := write_tree('base_for_vroot', {
		'vlib/a.v': ''
	})
	esc := vroot.replace('\\', '\\\\')
	store := write_tree('base_for', {
		'proj/graph.json':      '{}'
		'proj/manifest.json':   '{"root": "/p", "library": [{"label": "vlib", "root": "${esc}"}]}'
		'vlang/graph.json':     '{}'
		'vlang/manifest.json':  '{"root": "${esc}", "library": [{"label": "vlib", "root": "${esc}"}]}'
		'alone/graph.json':     '{}'
		'alone/manifest.json':  '{"root": "/q"}'
		'astray/graph.json':    '{}'
		'astray/manifest.json': '{"root": "/r", "library": [{"label": "vlib", "root": "/elsewhere"}]}'
	})
	graph := fn [store] (name string) string {
		return os.join_path(store, name, 'graph.json')
	}
	assert base_for(store, graph('proj')) or { '' } == graph('vlang')
	// the V tree's own graph is the base, on nothing; a project that read no vlib, or
	// one the store has no graph of, is served alone
	assert base_for(store, graph('vlang')) == none
	assert base_for(store, graph('alone')) == none
	assert base_for(store, graph('astray')) == none
}

fn test_a_cached_index_answers_as_a_built_one() {
	project, base := layer_fixture()
	plain := layer_graph(project, base)
	mut cached := plain
	cached.cache_index()
	assert cached.explain('vlib.gg.draw') == plain.explain('vlib.gg.draw')
	assert cached.query('draw', 500, false) == plain.query('draw', 500, false)
	assert cached.shortest_path('proj.redraw', 'vlib.gg.flush') == plain.shortest_path('proj.redraw',
		'vlib.gg.flush')
	assert cached.get_body('vlib.gg.flush') == plain.get_body('vlib.gg.flush')
	assert cached.neighbor_names('vlib.gg.draw') == plain.neighbor_names('vlib.gg.draw')
	// the kept index is the one built, not one built again: it doesn't follow a change
	cached.symbols << Symbol{
		id:   'proj.later'
		name: 'later'
		kind: .function
		file: 'proj.v'
	}
	assert 'proj.later' !in cached.index().by_id
	assert plain.index_cache == unsafe { nil }
}

fn test_a_module_is_shown_from_its_own_file_not_a_test_of_it() {
	g := graph_of({
		'gg/gg.v':            'module gg\n\npub fn draw() {}\n'
		'gg/zz_test.c.v':     'module gg\n\nfn test_draw() {}\n'
		'gg/zz_other_test.v': 'module gg\n\nfn test_more() {}\n'
	})
	assert g.index().by_id['gg'].file == 'gg/gg.v'
	assert g.explain('gg').contains('(gg/gg.v:1)')
}

fn test_a_module_from_vmodules_is_kept_whole_with_its_calls() {
	// The project calls glyph.new only, but the module it builds against is kept whole,
	// with the calls it makes, into itself and into vlib, resolved as the project's are,
	// so the MCP server can layer it under the project (layer_graph).
	base, fixture_roots := library_fixture('library_whole_module')
	defer {
		os.rmdir_all(base) or {}
		os.setenv('GRAPHIFY_LIB_VROOT', '', true)
		os.setenv('GRAPHIFY_LIB_VMODULES', '', true)
	}
	// VMODULES as it is named on a machine, ~/.vmodules: its files' paths don't end in
	// their rels, `vmodules/glyph/glyph.v`
	os.mv(os.join_path(base, 'vmodules'), os.join_path(base, '.vmodules')) or { panic(err) }
	roots := LibraryRoots{
		vroot:    fixture_roots.vroot
		vmodules: os.real_path(os.join_path(base, '.vmodules'))
	}
	glyph := os.join_path(roots.vmodules, 'glyph')
	os.write_file(os.join_path(glyph, 'glyph.v'), 'module glyph

import os
import sub

pub struct Ctx {}

pub fn new() Ctx {
	setup()
	return Ctx{}
}

fn setup() {
	os.rm("x") or {}
	sub.helper()
}

pub fn unused() {}
') or {
		panic(err)
	}
	// a module of its own, which V finds beside the module's v.mod: `import sub`
	os.write_file(os.join_path(glyph, 'v.mod'), "Module {\n\tname: 'glyph'\n}\n") or { panic(err) }
	os.mkdir_all(os.join_path(glyph, 'sub')) or { panic(err) }
	os.write_file(os.join_path(glyph, 'sub', 'sub.v'), 'module sub\n\npub fn helper() {}\n') or {
		panic(err)
	}
	g, _ := build_graph_with_library(os.join_path(base, 'proj'), '', os.join_path(base,
		'out'), roots)
	lib_ids := g.library.symbols.map(it.id)
	for id in ['vmodules.glyph.new', 'vmodules.glyph.setup', 'vmodules.glyph.unused'] {
		assert id in lib_ids, id
	}
	// reached only from the module, and kept for it
	assert 'vlib.os.rm' in lib_ids, lib_ids.str()
	glyph_calls := g.edges.filter(it.kind == .calls && it.from.starts_with('vmodules.glyph.'))
	assert glyph_calls.any(it.from == 'vmodules.glyph.new' && it.to == 'vmodules.glyph.setup')
	assert glyph_calls.any(it.from == 'vmodules.glyph.setup' && it.to == 'vlib.os.rm')
	assert glyph_calls.any(it.from == 'vmodules.glyph.setup' && it.to == 'vmodules.glyph.sub.helper'), glyph_calls.str()
	// vlib keeps only what is reached, without its own edges
	assert !g.edges.any(it.from.starts_with('vlib.'))
	// the report counts the project's edges, not the module's
	project_calls := g.edges.filter(it.kind == .calls && !it.from.starts_with('vmodules.')).len
	assert g.report().contains('- calls: ${project_calls}\n'), g.report()
	// and the edges line says how many the library's declarations have that it leaves out
	project_edges := g.edges.filter(!it.from.starts_with('vmodules.')).len
	assert g.report().contains('- edges: ${project_edges} (${g.edges.len - project_edges} more from library declarations, not counted)\n'), g.report()
}

fn test_a_module_from_vmodules_updated_in_place_makes_the_graph_stale() {
	// VMODULES is no repository, but each module `v install` put there is a clone of its
	// own: the manifest records the commit of each the graph keeps, so that a module
	// pulled since says the graph is behind, as a moved vlib does
	base, roots := library_fixture('library_module_commit')
	defer {
		os.rmdir_all(base) or {}
	}
	glyph := os.join_path(roots.vmodules, 'glyph')
	git := fn [glyph] (args ...string) string {
		mut cmd := ['git', '-C', glyph, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
			'commit.gpgsign=false']
		cmd << args
		return os.exec(cmd).output.trim_space()
	}
	git('init', '-q')
	git('add', '.')
	git('commit', '-q', '-m', 'one')
	first := git('rev-parse', 'HEAD')
	out := os.join_path(base, 'out')
	g, report := build_graph_with_library(os.join_path(base, 'proj'), '', out, roots)
	write_bundle(g, out, report) or { panic(err) }
	m := load_manifest(os.join_path(out, 'manifest.json')) or { panic(err) }
	vmods := m.library.filter(it.label == 'vmodules')
	assert vmods.len == 1 && vmods[0].commit == ''
	assert vmods[0].modules.len == 1, vmods.str()
	assert vmods[0].modules[0].name == 'glyph' && vmods[0].modules[0].commit == first
	graph := os.join_path(out, 'graph.json')
	assert !stale_note(graph, '', '').contains('glyph')

	os.write_file(os.join_path(glyph, 'more.v'), 'module glyph\n') or { panic(err) }
	git('add', '.')
	git('commit', '-q', '-m', 'two')
	note := stale_note(graph, '', '')
	assert note.contains('its module glyph was read from ${glyph} at ${first[..10]}'), note
}

fn test_a_module_installed_under_its_owner_is_tracked_by_its_own_clone() {
	// `v install` puts a package registered with its owner's name in a directory of the
	// owner's, `quaesitor_scientiam/vebidor`, which is no clone itself: the clone the
	// module's commit is read from is the one below it
	base, roots := library_fixture('library_owner_module')
	defer {
		os.rmdir_all(base) or {}
	}
	pkg := os.join_path(roots.vmodules, 'owner', 'pkg')
	os.mkdir_all(pkg) or { panic(err) }
	os.write_file(os.join_path(pkg, 'pkg.v'), 'module pkg\n\npub fn run() {}\n') or { panic(err) }
	os.write_file(os.join_path(pkg, 'v.mod'), "Module {\n\tname: 'pkg'\n}\n") or { panic(err) }
	os.write_file(os.join_path(base, 'proj', 'use.v'), 'module main\n\nimport owner.pkg\n\nfn use() {\n\tpkg.run()\n}\n') or {
		panic(err)
	}
	git := fn [pkg] (args ...string) string {
		mut cmd := ['git', '-C', pkg, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
			'commit.gpgsign=false']
		cmd << args
		return os.exec(cmd).output.trim_space()
	}
	git('init', '-q')
	git('add', '.')
	git('commit', '-q', '-m', 'one')
	first := git('rev-parse', 'HEAD')
	out := os.join_path(base, 'out')
	g, report := build_graph_with_library(os.join_path(base, 'proj'), '', out, roots)
	assert g.library.symbols.any(it.file.starts_with('vmodules/owner/pkg/')), g.library.symbols.map(it.file).str()
	write_bundle(g, out, report) or { panic(err) }
	m := load_manifest(os.join_path(out, 'manifest.json')) or { panic(err) }
	mods := m.library.filter(it.label == 'vmodules')[0].modules
	owned := mods.filter(it.name == 'owner/pkg')
	assert owned.len == 1 && owned[0].commit == first, mods.str()
	// glyph, in no clone, by its own directory without a commit
	assert mods.any(it.name == 'glyph' && it.commit == ''), mods.str()

	os.write_file(os.join_path(pkg, 'more.v'), 'module pkg\n') or { panic(err) }
	git('add', '.')
	git('commit', '-q', '-m', 'two')
	note := stale_note(os.join_path(out, 'graph.json'), '', '')
	assert note.contains('its module owner/pkg was read from ${pkg} at ${first[..10]}'), note
}

fn test_a_worktree_of_a_project_or_of_the_v_tree_is_found_as_one() {
	tree := os.real_path(write_tree('worktrees', {
		'proj/a.v':       'module main\n'
		'mono/app/a.v':   'module main\n'
		'mono/other/b.v': 'module other\n'
		'vlang/v.v':      'module main\n'
	}))
	defer {
		os.rmdir_all(tree) or {}
	}
	git := fn (dir string, args ...string) string {
		mut cmd := ['git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
			'commit.gpgsign=false']
		cmd << args
		return os.exec(cmd).output.trim_space()
	}
	for repo in ['proj', 'mono', 'vlang'] {
		dir := os.join_path(tree, repo)
		git(dir, 'init', '-q')
		git(dir, 'add', '.')
		git(dir, 'commit', '-q', '-m', 'one')
	}
	proj := os.join_path(tree, 'proj')
	vlang := os.join_path(tree, 'vlang')
	// a worktree inside the project, as Claude Code makes one, and one beside it
	inside := os.join_path(proj, '.claude', 'worktrees', 'wt')
	git(proj, 'worktree', 'add', '-q', inside, '-b', 'wt')
	beside := os.join_path(tree, 'proj-wt')
	git(proj, 'worktree', 'add', '-q', beside, '-b', 'beside')
	mono_wt := os.join_path(tree, 'mono-wt')
	git(os.join_path(tree, 'mono'), 'worktree', 'add', '-q', mono_wt, '-b', 'wt')
	vlang_wt := os.join_path(tree, 'vlang-wt')
	git(vlang, 'worktree', 'add', '-q', vlang_wt, '-b', 'wt')

	assert worktree_root(proj, proj) == none
	assert worktree_root(inside, proj) or { '' } == inside
	assert worktree_root(os.join_path(beside), proj) or { '' } == beside
	// a project in a directory of its repository is there in the worktree too
	assert worktree_root(os.join_path(mono_wt, 'app'), os.join_path(tree, 'mono', 'app')) or {
		''
	} == os.join_path(mono_wt, 'app')
	// another repository's checkout is no worktree of it
	assert worktree_root(vlang, proj) == none
	assert worktree_root(os.join_path(tree, 'proj-wt-missing'), proj) == none

	store := os.join_path(tree, 'store')
	for name, root in {
		'proj': proj
		'app':  os.join_path(tree, 'mono', 'app')
	} {
		os.mkdir_all(os.join_path(store, name)) or { panic(err) }
		os.write_file(os.join_path(store, name, 'graph.json'), '{}') or { panic(err) }
		os.write_file(os.join_path(store, name, 'manifest.json'), json_root(root)) or {
			panic(err)
		}
	}
	graph := fn [store] (name string) string {
		return os.join_path(store, name, 'graph.json')
	}
	base := os.join_path(tree, 'vlang-graph', 'graph.json')
	found := fn [store, base, vlang] (dir string) WorktreeGraph {
		project := project_for(store, dir, vlang) or { '' }
		return worktree_graph(store, dir, project, base, vlang) or { WorktreeGraph{} }
	}
	// project_for finds the project's graph for the worktree inside it
	assert found(inside) == WorktreeGraph{graph('proj'), inside}
	// and none for the one beside it, found by its repository
	assert found(beside) == WorktreeGraph{graph('proj'), beside}
	assert found(os.join_path(mono_wt, 'app')) == WorktreeGraph{graph('app'), os.join_path(mono_wt,
		'app')}
	// a worktree of the V tree is the base's
	assert found(vlang_wt) == WorktreeGraph{base, vlang_wt}
	// the checkouts themselves, and a directory of the worktree outside the project
	assert found(proj) == WorktreeGraph{}
	assert found(vlang) == WorktreeGraph{}
	assert found(os.join_path(mono_wt, 'other')) == WorktreeGraph{}
}

fn test_a_worktree_store_is_seeded_refreshed_and_pruned() {
	tree := os.real_path(write_tree('worktree_store', {
		'proj/a.v':                    'module main\n'
		'checkout/graph.json':         '{}'
		'checkout/${cache_file_name}': 'cache'
	}))
	defer {
		os.rmdir_all(tree) or {}
	}
	proj := os.join_path(tree, 'proj')
	git := fn [proj] (args ...string) string {
		mut cmd := ['git', '-C', proj, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c',
			'commit.gpgsign=false']
		cmd << args
		return os.exec(cmd).output.trim_space()
	}
	git('init', '-q')
	git('add', '.')
	git('commit', '-q', '-m', 'one')
	stores := os.join_path(tree, 'stores')
	store := worktree_store(stores, proj)
	assert os.dir(store) == stores && os.base(store).starts_with('proj-')
	// two worktrees of one name have stores of their own
	assert worktree_store(stores, os.join_path(tree, 'other', 'proj')) != store
	seed_worktree_store(store, os.join_path(tree, 'checkout', 'graph.json')) or { panic(err) }
	assert os.read_file(os.join_path(store, cache_file_name)) or { '' } == 'cache'
	// the store's own cache is kept, once it has one
	os.write_file(os.join_path(store, cache_file_name), 'mine') or { panic(err) }
	seed_worktree_store(store, os.join_path(tree, 'checkout', 'graph.json')) or { panic(err) }
	assert os.read_file(os.join_path(store, cache_file_name)) or { '' } == 'mine'

	clean := worktree_state(proj)
	a := os.join_path(proj, 'a.v')
	os.write_file(a, 'module main\n\nfn f() {}\n') or { panic(err) }
	edited := worktree_state(proj)
	assert edited != clean
	// a file changed already, changed again: git reports it the same
	os.write_file(a, 'module main\n\nfn f() {}\n\nfn g() {}\n') or { panic(err) }
	assert worktree_state(proj) != edited
	os.write_file(os.join_path(proj, 'b.v'), 'module main\n') or { panic(err) }
	assert worktree_state(proj).contains('?? b.v')
	// a file that isn't V is no change to the graph
	before := worktree_state(proj)
	os.write_file(os.join_path(proj, 'notes.md'), 'x') or { panic(err) }
	assert worktree_state(proj) == before

	// a store whose worktree is gone is removed; one whose worktree is there, and
	// one without a manifest yet, are kept
	os.write_file(os.join_path(store, 'manifest.json'), json_root(proj)) or { panic(err) }
	gone := worktree_store(stores, os.join_path(tree, 'gone'))
	os.mkdir_all(gone) or { panic(err) }
	os.write_file(os.join_path(gone, 'manifest.json'), json_root(os.join_path(tree, 'gone'))) or {
		panic(err)
	}
	partial := os.join_path(stores, 'partial')
	os.mkdir_all(partial) or { panic(err) }
	prune_worktree_stores(stores)
	assert os.is_dir(store) && os.is_dir(partial) && !os.exists(gone)
}

fn test_a_worktree_store_is_current_until_its_worktree_changes() {
	tree := os.real_path(write_tree('worktree_current', {
		'proj/a.v': 'module main\n'
	}))
	defer {
		os.rmdir_all(tree) or {}
	}
	proj := os.join_path(tree, 'proj')
	os.exec(['git', '-C', proj, 'init', '-q'])
	store := worktree_store(os.join_path(tree, 'stores'), proj)
	found := WorktreeGraph{
		graph: os.join_path(tree, 'checkout', 'graph.json')
		root:  proj
	}
	// a failed extract saves no state, so the next command tries again
	mut failed := false
	extract_worktree_store(store, found, os.join_path(tree, 'no-graphify')) or { failed = true }
	assert failed && !os.exists(os.join_path(store, worktree_state_file))
	assert !worktree_store_current(store, proj)
	os.write_file(os.join_path(store, 'graph.json'), '{}') or { panic(err) }
	assert !worktree_store_current(store, proj)
	os.write_file(os.join_path(store, worktree_state_file), worktree_state(proj)) or { panic(err) }
	assert worktree_store_current(store, proj)
	os.write_file(os.join_path(proj, 'a.v'), 'module main\n\nfn f() {}\n') or { panic(err) }
	assert !worktree_store_current(store, proj)
	// the MCP server extracts into the same store: an extract drops the state saved
	// before it, which its graph may no longer be of
	os.write_file(os.join_path(store, worktree_state_file), worktree_state(proj)) or { panic(err) }
	failed = false
	extract_worktree_at(store, proj, os.join_path(tree, 'no-graphify'), worktree_state(proj)) or {
		failed = true
	}
	assert failed && !worktree_store_current(store, proj)
}

fn test_two_projects_of_one_name_have_a_store_directory_each() {
	// `extract --store` filed a project under its directory's name, so a second
	// project of that name took over the first's graph
	tree := os.real_path(write_tree('store_names', {
		'a/proj/m.v': 'module main\n'
		'b/proj/m.v': 'module main\n'
	}))
	defer {
		os.rmdir_all(tree) or {}
	}
	store := os.join_path(tree, 'store')
	a := os.join_path(tree, 'a', 'proj')
	b := os.join_path(tree, 'b', 'proj')
	assert store_project_dir(store, a) == os.join_path(store, 'proj')
	for root in [a, b] {
		dir := store_project_dir(store, root)
		os.mkdir_all(dir) or { panic(err) }
		os.write_file(os.join_path(dir, 'manifest.json'), json_root(root)) or { panic(err) }
	}
	assert store_project_dir(store, a) == os.join_path(store, 'proj')
	assert store_project_dir(store, b) == os.join_path(store, 'proj-2')
	assert store_project_dir(store, os.join_path(tree, 'c', 'proj')) == os.join_path(store, 'proj-3')
}

fn test_a_worktree_changes_with_a_file_git_quotes_the_name_of() {
	// git quotes a path with a space or a non-ASCII letter, and a second edit of it
	// went unseen
	tree := os.real_path(write_tree('worktree_quoted', {
		'proj/a.v': 'module main\n'
	}))
	defer {
		os.rmdir_all(tree) or {}
	}
	proj := os.join_path(tree, 'proj')
	os.exec(['git', '-C', proj, 'init', '-q'])
	for name in ['my file.v', 'é.v'] {
		path := os.join_path(proj, name)
		os.write_file(path, 'module main\n\nfn first() {}\n') or { panic(err) }
		before := worktree_state(proj)
		os.write_file(path, 'module main\n\nfn first() {}\n\nfn second() {}\n') or { panic(err) }
		assert worktree_state(proj) != before, name
	}
}

fn test_a_hint_names_the_command_of_the_front_end() {
	mut g := graph_of({
		'a.v': 'module main\n\nfn f() {}\n'
	})
	assert g.explain('f').contains('(use `get_body f` to read its source)')
	g.cli = true
	assert g.explain('f').contains('(use `graphify body f` to read its source)')
	assert g.command('get_node') == 'graphify explain'
}

fn test_a_name_with_several_declarations_is_each_of_them() {
	// get_node took the first declaration of a name and dropped the rest, callers and
	// all: `wait_for_read` showed net's free function and none of the methods
	files := {
		'net/conn.v':  'module net

pub struct TcpConn {}

pub fn wait_for_read(h int) {}

pub fn (c TcpConn) wait_for_read() {
	wait_for_read(1)
}

pub fn (c TcpConn) read_ptr() {
	c.wait_for_read()
}
'
		'unix/conn.v': 'module unix

pub struct StreamListener {}

pub fn (l StreamListener) wait_for_read() {}

pub fn (l StreamListener) accept() {
	l.wait_for_read()
}

fn serve() {
	l := StreamListener{}
	l.accept()
}
'
	}
	g := graph_of(files)
	all := g.explain('wait_for_read')
	assert all.starts_with('`wait_for_read` names 3 declarations'), all
	for loc in ['net/conn.v:5', 'net/conn.v:7', 'unix/conn.v:5'] {
		assert all.contains('(${loc})'), all
	}
	// each with its own callers
	assert all.contains('called by     : read_ptr (net/conn.v:11)'), all
	assert all.contains('called by     : accept (unix/conn.v:7)'), all
	// a method by its type, or a dotted tail of its id
	tcp := g.explain('TcpConn.wait_for_read')
	assert tcp.starts_with('method wait_for_read  (net/conn.v:7)'), tcp
	assert g.explain('unix.StreamListener.accept').contains('called by     : serve (unix/conn.v:11)')
	assert g.resolve_all('StreamListener.wait_for_read') == ['unix.StreamListener.wait_for_read']
	// a file:line inside a declaration is that declaration
	assert g.resolve_all('unix/conn.v:8') == ['unix.StreamListener.accept']
	assert g.resolve_all('conn.v:12') == ['net.TcpConn.read_ptr']
	assert g.resolve_all('unix/conn.v:999') == ['unix.serve']
	assert g.resolve_all('nowhere.v:3') == []
	// a body of each, named alike, read from the files
	root := write_tree('several_declarations', files)
	defer {
		os.rmdir_all(root) or {}
	}
	bodies := build_graph(Options{ root: root }).get_body('wait_for_read')
	for loc in ['// net/conn.v:5-', '// net/conn.v:7-', '// unix/conn.v:5-'] {
		assert bodies.contains(loc), bodies
	}
	// a name of one declaration is it, as before
	assert g.explain('serve').starts_with('fn serve  (unix/conn.v:11)')
}

fn test_a_name_with_many_declarations_is_a_list_to_pick_from() {
	mut files := map[string]string{}
	for i in 0 .. max_shown + 2 {
		files['m${i}/a.v'] = 'module m${i}\n\npub struct T${i} {}\n\npub fn (t T${i}) str() string {\n\treturn ""\n}\n'
	}
	files['use/u.v'] = 'module use\n\nimport m3\n\nfn show() string {\n\tt := m3.T3{}\n\treturn t.str()\n}\n'
	g := graph_of(files)
	list := g.explain('str')
	lines := list.split_into_lines()
	assert lines[0].starts_with('`str` names ${max_shown + 2} declarations, the most called first'), list
	// the one called first
	assert lines[1].contains('m3.T3.str') && lines[1].ends_with('1 caller(s)'), list
	assert g.get_body('str').starts_with('`str` names')
}

fn test_a_call_edge_has_the_line_of_each_call() {
	// get_node gave a caller's declaration line, not where it calls, so a reader
	// grepped for the call sites anyway
	g := graph_of({
		'net/conn.v': 'module net

pub struct TcpConn {}

pub fn (c TcpConn) wait_for_read() {}

pub fn (c TcpConn) read_ptr() {
	c.wait_for_read()
	if true {
		c.wait_for_read()
	}
}

fn helper() {}

pub fn dial() {
	helper()
	x := 1
	helper()
}
'
	})
	mut by := map[string][]int{}
	for e in g.edges {
		if e.kind == .calls {
			by['${e.from} ${e.to}'] = e.lines
		}
	}
	assert by['net.TcpConn.read_ptr net.TcpConn.wait_for_read'] == [8, 10], by.str()
	assert by['net.dial net.helper'] == [17, 19], by.str()
	callee := g.explain('TcpConn.wait_for_read')
	assert callee.contains('read_ptr (net/conn.v:7) at lines 8, 10'), callee
	caller := g.explain('dial')
	assert caller.contains('helper (net/conn.v:14) at lines 17, 19'), caller
}

fn test_call_lines_survive_graph_json_and_the_worker_protocol() {
	g := graph_of({
		'a/a.v': 'module a

fn f() {}

fn g() {
	f()
	f()
}
'
	})
	dir := os.join_path(os.temp_dir(), 'graphify_test_lines_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'graph.json')
	save_graph(g, path) or { panic(err) }
	back := load_graph(path) or { panic(err) }
	calls := back.edges.filter(it.kind == .calls)
	assert calls.len == 1 && calls[0].lines == [6, 7], calls.str()
	// a graph.json from before has no lines, and still loads
	old := os.read_file(path) or { panic(err) }.replace(',"lines":[6,7]', '')
	os.write_file(path, old) or { panic(err) }
	before := load_graph(path) or { panic(err) }
	assert before.edges.filter(it.kind == .calls)[0].lines == []
	syms, edges := extract_v_text(os.read_file(os.join_path(@VMODROOT, 'graph_ops.v')) or { panic(err) },
		'graph_ops.v')
	fr := decode_file_result(encode_file_result(FileResult{ symbols: syms, edges: edges }))
	assert fr.edges.map(it.lines) == edges.map(it.lines)
	assert edges.any(it.lines.len > 0)
}

fn test_a_path_between_two_functions_is_their_chain_of_calls() {
	// shortest_path linked http.get to net.dial_tcp through the `string` type both
	// mention, not through the calls that lead from one to the other
	g := graph_of({
		'net/tcp.v':   'module net

pub fn dial_tcp(addr string) int {
	return addr.len
}
'
		'http/http.v': 'module http

import net

pub fn get(url string) int {
	return fetch(url)
}

fn fetch(url string) int {
	return do(url)
}

fn do(url string) int {
	return net.dial_tcp(url)
}
'
	})
	ids := g.call_path('get', 'dial_tcp')
	assert ids == ['http.get', 'http.fetch', 'http.do', 'net.dial_tcp'], ids.str()
	text := g.path_between('get', 'dial_tcp')
	// one line a step; joined, since a checkout with CRLF line ends would put them in a
	// multi-line literal
	assert text == ['get (http/http.v:5)', '  -> fetch (http/http.v:9), called at line 6',
		'  -> do (http/http.v:13), called at line 10',
		'  -> dial_tcp (net/tcp.v:3), called at line 14'].join('\n'), text
	// the other way round it is still the same chain, said so
	assert g.call_path('dial_tcp', 'get') == []
	back := g.path_between('dial_tcp', 'get')
	assert back.starts_with("(`dial_tcp` doesn't reach `get` by calls, but `get` reaches `dial_tcp`:)"), back
	// two functions that only share a type have no chain of calls
	apart := g.path_between('dial_tcp', 'http')
	assert apart.starts_with('(no chain of calls links them'), apart
}

fn test_a_search_matches_every_word_of_it() {
	// query_graph matched any one word, so `accept connection unix socket` seeded from
	// every symbol with `connection` in it, and the one it was about came nowhere
	g := graph_of({
		'net/unix/stream.v':    'module unix

pub struct StreamConn {}

pub struct StreamListener {}

// accept waits for a connection on the socket
pub fn (l StreamListener) accept() StreamConn {
	return StreamConn{}
}

pub fn connection_count() int {
	return 0
}
'
		'net/unix/stream_test.v': 'module unix

fn test_accept() {}
'
		'net/tcp.v':            'module net

pub fn accept_tcp() {}
'
	})
	// every word: in the name, signature, file or doc comment
	assert g.find('accept connection unix socket') == ['net.unix.StreamListener.accept'], g.find('accept connection unix socket').str()
	// question words name no code
	assert g.find('how does the listener accept a connection') == ['net.unix.StreamListener.accept']
	// a name the word is outright first, then one with it in, the shorter first; a
	// test's declaration after code that matches as well
	assert g.find('accept') == ['net.unix.StreamListener.accept', 'net.accept_tcp', 'net.unix.test_accept'], g.find('accept').str()
	// when nothing has every word, those with the most
	assert g.find('accept zebra') == g.find('accept')
	assert g.find('zebra') == []
}

fn test_a_search_ties_go_to_the_project_over_vlib() {
	project, base := layer_fixture()
	g := layer_graph(project, base)
	// `helper` is the project's and vlib's both
	found := g.find('helper')
	assert found.len == 2 && found[0] == 'proj.helper', found.str()
}

fn test_a_path_lists_every_route_by_calls_shortest_first() {
	// shortest_path gave one chain, http.get's through a fresh connection, not the
	// pooled transport's it takes by default
	g := graph_of({
		'net/tcp.v':   'module net

pub fn dial_tcp() {}
'
		'http/http.v': 'module http

import net

pub fn get() {
	if true {
		fresh()
	} else {
		pooled()
	}
}

fn fresh() {
	net.dial_tcp()
}

fn pooled() {
	dial()
}

fn dial() {
	again()
	net.dial_tcp()
}

fn again() {
	get()
}
'
	})
	paths := g.call_paths('get', 'dial_tcp', 5)
	// the loop back through get is no route
	assert paths == [['http.get', 'http.fresh', 'net.dial_tcp'],
		['http.get', 'http.pooled', 'http.dial', 'net.dial_tcp']], paths.str()
	assert g.call_paths('get', 'dial_tcp', 1) == [paths[0]]
	assert g.call_path('get', 'dial_tcp') == paths[0]
	text := g.path_between('get', 'dial_tcp')
	assert text == ['2 chains of calls from get to dial_tcp, at most 10 calls longer than the shortest:',
		'',
		'1. get (http/http.v:5)', '  -> fresh (http/http.v:13), called at line 7',
		'  -> dial_tcp (net/tcp.v:3), called at line 14', '', '2. get (http/http.v:5)',
		'  -> pooled (http/http.v:17), called at line 9',
		'  -> dial (http/http.v:21), called at line 18',
		'  -> dial_tcp (net/tcp.v:3), called at line 23'].join('\n'), text
}

fn test_a_signature_writes_each_parameter_as_its_declaration_does() {
	// V3 gives a `mut` parameter its type with a `&`, so `(mut c TcpConn)` read as
	// `(c &TcpConn)`, and `mut buf []u8` as `buf &[]u8`
	g := graph_of({
		'm/m.v': 'module m

pub struct T {}

pub fn (mut c T) a(mut buf []u8, n int) {}

pub fn (c &T) b(mut x T) {}

pub fn (mut c &T) d(mut p &T, q &T) {}

pub fn (c T) e(shared s T) {}

pub fn f(mut m map[string]int) {}

pub interface I {
mut:
	g(mut b []u8) int
}
'
	})
	mut sig := map[string]string{}
	for s in g.symbols {
		sig[s.id] = s.signature
	}
	assert sig['m.T.a'] == 'pub fn (mut c T) a(mut buf []u8, n int)', sig.str()
	assert sig['m.T.b'] == 'pub fn (c &T) b(mut x T)'
	assert sig['m.T.d'] == 'pub fn (mut c &T) d(mut p &T, q &T)'
	assert sig['m.T.e'] == 'pub fn (c T) e(shared s T)'
	assert sig['m.f'] == 'pub fn f(mut m map[string]int)'
	assert sig['m.I.g'] == 'fn (I) g(mut b []u8) int'
	// what reads a function's parameter types back off its signature still gets them
	assert param_types(sig['m.f']) == ['map[string]int']
}

fn test_a_path_says_how_many_routes_there_are_past_those_it_shows() {
	// shortest_path showed 5 routes and said nothing of the other 2 that
	// http.get has to net.dial_tcp
	mut src := 'module m\n\npub fn goal() {}\n\npub fn start() {\n'
	for i in 0 .. 7 {
		src += '\tvia_${i}()\n'
	}
	src += '}\n'
	for i in 0 .. 7 {
		src += '\nfn via_${i}() {\n\tgoal()\n}\n'
	}
	g := graph_of({
		'm/m.v': src
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.paths.len == 5 && r.total == 7 && r.exact, r.str()
	text := g.path_between('start', 'goal')
	assert text.all_before('\n') == '7 chains of calls from start to goal, at most 10 calls longer than the shortest; the 5 shortest:', text
	assert text.contains('5. start') && !text.contains('6. start')
}

// The routes of a build the default one lacks are the long ones: `http.get` has 10 to
// `net.dial_tcp` that need `use_openssl ?`, and they run up to 9 calls longer than the
// shortest. A chain 10 longer is listed and counted, in its own build; one 11 longer is
// not.
fn test_a_route_ten_calls_longer_than_the_shortest_is_a_route_and_one_eleven_longer_is_not() {
	mut src := 'module m\n\npub fn goal() {}\n\npub fn start() {\n\tgoal()\n\t\$if use_openssl ? {\n\t\tslow_0()\n\t}\n\ttoo_slow_0()\n}\n'
	// start, 10 functions, goal: 11 calls
	for i in 0 .. 10 {
		next := if i == 9 { 'goal' } else { 'slow_${i + 1}' }
		src += '\nfn slow_${i}() {\n\t${next}()\n}\n'
	}
	// start, 11 functions, goal: 12 calls
	for i in 0 .. 11 {
		next := if i == 10 { 'goal' } else { 'too_slow_${i + 1}' }
		src += '\nfn too_slow_${i}() {\n\t${next}()\n}\n'
	}
	g := graph_of({
		'm/m.v': src
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.total == 2 && r.in_default == 1 && r.exact, r.str()
	assert r.other_builds == {
		'use_openssl ?': 1
	}, r.other_builds.str()
	assert r.paths.map(it.len) == [2, 12], r.paths.str()
	text := g.path_between('start', 'goal')
	assert text.all_before('\n') == '2 chains of calls from start to goal (1 in the default build), at most 10 calls longer than the shortest:', text
	assert text.contains('slow_9') && !text.contains('too_slow')
}

// `routes` is how many chains of calls are listed: all of them when there are no more
// than that, and never more than 50, nor fewer than 1.
fn test_a_path_to_a_name_of_several_declarations_is_to_the_one_calls_reach() {
	// path took the first declaration of a name, a field for `real_path`, and found no
	// chain of calls to os.real_path, which get_node listed among them
	g := graph_of({
		'a.v': 'module main

struct File {
	real_path string
}

fn real_path() {}

fn start() {
	real_path()
}
'
	})
	assert g.resolve_one('real_path') == 'main.File.real_path'
	out := g.path_between('start', 'real_path')
	assert out.starts_with('(`real_path` names 2 declarations; the chains below are of the ones that calls link:)'), out
	assert out.contains('-> real_path (a.v:7)'), out
	// one declaration each is as before, with no note
	assert !g.path_between('start', 'main.real_path').contains('names'), g.path_between('start', 'main.real_path')
}

fn test_a_path_lists_as_many_routes_as_asked_for_up_to_fifty() {
	mut src := 'module m\n\npub fn goal() {}\n\npub fn start() {\n'
	for i in 0 .. 60 {
		src += '\tvia_${i}()\n'
	}
	src += '}\n'
	for i in 0 .. 60 {
		src += '\nfn via_${i}() {\n\tgoal()\n}\n'
	}
	g := graph_of({
		'm/m.v': src
	})
	assert g.path_between('start', 'goal') == g.path_between_routes('start', 'goal', 5)
	seven := g.path_between_routes('start', 'goal', 7)
	assert seven.all_before('\n') == '60 chains of calls from start to goal, at most 10 calls longer than the shortest; the 7 shortest:', seven
	assert seven.contains('7. start') && !seven.contains('8. start')
	// more than there are, and than a path lists
	most := g.path_between_routes('start', 'goal', 1000)
	assert most.contains('50. start') && !most.contains('51. start')
	assert most.all_before('\n').ends_with('; the 50 shortest:'), most
	// fewer than 1 is 1
	assert g.path_between_routes('start', 'goal', 0) == g.path_between_routes('start', 'goal', 1)
	assert g.path_between_routes('start', 'goal', -3) == g.path_between_routes('start', 'goal', 1)
	// and when all of them fit, they are all there, with no count of the rest
	few := graph_of({
		'm/m.v': 'module m\n\npub fn goal() {}\n\npub fn start() {\n\tone()\n\ttwo()\n\tthree()\n}\n\nfn one() {\n\tgoal()\n}\n\nfn two() {\n\tgoal()\n}\n\nfn three() {\n\tgoal()\n}\n'
	})
	all := few.path_between_routes('start', 'goal', 3)
	assert all.all_before('\n') == '3 chains of calls from start to goal, at most 10 calls longer than the shortest:', all
	assert all.contains('3. start')
}

fn test_a_file_name_says_which_builds_compile_it() {
	assert file_build('vlib/net/ssl/ssl_d_use_openssl.v') == 'use_openssl ?'
	assert file_build('vlib/net/ssl/ssl_notd_use_openssl.v') == '!use_openssl ?'
	assert file_build('vlib/os/os_nix.c.v') == '!windows'
	assert file_build('vlib/os/os_darwin.c.v') == 'macos'
	assert file_build('vlib/os/os_android_outside_termux.c.v') == 'android && !termux'
	assert file_build('vlib/math/bits_arm64.v') == 'arm64'
	assert file_build('vlib/net/ssl/ssl_d_use_openssl_test.v') == 'use_openssl ?'
	assert file_build('vlib/gg/gg_linux_d_gg_multiwindow.c.v') == 'linux && gg_multiwindow ?'
	assert file_build('vlib/os/os.js.v') == 'js'
	assert file_build('vlib/os/os.c.v') == ''
	assert file_build('vlib/os/os_default.c.v') == ''
}

fn test_a_declaration_carries_the_build_its_file_and_its_dollar_if_say() {
	src := 'module net

\$if linux {
	pub fn on_linux() {}
} \$else \$if windows {
	pub fn on_windows() {}
} \$else {
	pub fn elsewhere() {}
}

\$if !no_y ? {
	pub struct Y {
		a int
	}
}

\$if a ? || b ? {
	fn ab() {}
} \$else {
	fn not_ab() {}
}

\$if @OS == "linux" {
	const os_name = 1
} \$else {
	const os_name = 2
}

pub fn everywhere() {}
'
	syms, _ := extract_v_text(src, 'net/top_d_fast.v')
	build := maps_by_id(syms)
	assert build['net.on_linux'].build == 'fast ? && linux'
	assert build['net.on_windows'].build == 'fast ? && !linux && windows'
	assert build['net.elsewhere'].build == 'fast ? && !linux && !windows'
	assert build['net.Y'].build == 'fast ? && !no_y ?'
	// a field is in its struct's branch
	assert build['net.Y.a'].build == 'fast ? && !no_y ?'
	assert build['net.ab'].build == 'fast ? && (a ? || b ?)'
	assert build['net.not_ab'].build == 'fast ? && !(a ? || b ?)'
	assert build['net.everywhere'].build == 'fast ?'
	// as the source writes it: the parser's text has the host's OS for `@OS`
	os_names := syms.filter(it.name == 'os_name').map(it.build)
	assert os_names == ['fast ? && @OS == "linux"', 'fast ? && !(@OS == "linux")'], os_names.str()
	// a `$match @OS` arm has no `$if` in the source, and the parser's text for it
	// has the host's OS
	arms, _ := extract_v_text('module net

\$match @OS {
	"linux" {
		const arm = 1
	}
	\$else {
		const arm = 2
	}
}
', 'net/arms.v')
	arm_builds := arms.filter(it.name == 'arm').map(it.build)
	assert arm_builds == ['@OS == "linux"', '!(@OS == "linux")'], arm_builds.str()
	// the build goes through a worker's batch and into graph.json
	fr := decode_file_result(encode_file_result(FileResult{ symbols: syms }))
	assert maps_by_id(fr.symbols)['net.on_windows'].build == 'fast ? && !linux && windows'
}

// An alias declared once per build, `ssl.SSLConn` as `mbedtls.SSLConn` or
// `openssl.SSLConn`, names both types: a call through it reaches each build's
// method, and a call on one of the types themselves only its own.
fn test_a_call_through_an_alias_each_build_declares_reaches_every_builds_method() {
	g := graph_of({
		'tls/ma/conn.v':             'module ma

pub struct Conn {}

pub fn (c &Conn) connect() {}

pub fn (c &Conn) self_check() {
	c.connect()
}
'
		'tls/mb/conn.v':             'module mb

pub struct Conn {}

pub fn (c &Conn) connect() {}

pub fn (c &Conn) only_b() {}
'
		'tls/pick/pick_d_use_b.v':    'module pick

import tls.mb

pub type Conn = mb.Conn
'
		'tls/pick/pick_notd_use_b.v': 'module pick

import tls.ma

pub type Conn = ma.Conn
'
		'app/app.v':                 'module app

import tls.pick

pub fn run(c &pick.Conn) {
	c.connect()
	c.only_b()
}
'
	})
	calls := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.from == from).map(it.to).sorted()
	}
	assert calls('app.run') == ['tls.ma.Conn.connect', 'tls.mb.Conn.connect', 'tls.mb.Conn.only_b']
	assert calls('tls.ma.Conn.self_check') == ['tls.ma.Conn.connect']
	// each call through the alias needs the build of the declaration that names its
	// callee's type; the call on one of the types itself needs none
	mut build_of := map[string]string{}
	for e in g.edges {
		if e.kind == .calls {
			build_of['${e.from} ${e.to}'] = e.build
		}
	}
	assert build_of['app.run tls.ma.Conn.connect'] == '!use_b ?', build_of.str()
	assert build_of['app.run tls.mb.Conn.connect'] == 'use_b ?'
	assert build_of['tls.ma.Conn.self_check tls.ma.Conn.connect'] == ''
	// so a route through one build's type says so
	route := g.path_between('run', 'tls.mb.Conn.connect')
	assert route.ends_with('  needs \$if use_b ?'), route
	// get_node shows the build of the copy it shows, and the other build's copy
	text := g.explain('tls.pick.Conn')
	assert text.contains('type Conn  (tls/pick/pick_notd_use_b.v:5) [\$if !use_b ?]'), text
	assert text.contains('other builds  : pub type Conn = tls.mb.Conn (tls/pick/pick_d_use_b.v:5) [\$if use_b ?]'), text
}

// A call inside a body's `$if` is made only by the builds that take its branch
// (Edge.build). One callee called under two branches is called by either build, and
// called outside any, by every build. A `$if` on a type or a member picks no build.
fn test_a_call_carries_the_build_of_the_dollar_if_branches_it_is_in() {
	g := graph_of({
		'm/m.v': 'module m

struct S {
	xs []int
}

fn a() {}

fn b() {}

fn c() {}

fn d() {}

fn e() {}

fn h() {}

fn k() {}

fn g() {}

fn t() {}

pub fn f() {
	\$if linux {
		a()
	} \$else {
		b()
	}
	\$if use_x ? {
		c()
	}
	c()
	\$if windows {
		\$if amd64 {
			d()
		}
		h()
	}
	\$if a ? || b ? {
		e()
	}
	\$if linux {
		h()
		\$if x ? || y ? {
			k()
		}
	}
	\$for field in S.fields {
		\$if field.is_array {
			g()
		}
	}
}

pub fn gen[T](x T) {
	\$if T is int {
		t()
	}
}
'
	})
	builds := fn [g] (to string) string {
		for e in g.edges {
			if e.kind == .calls && e.to == to {
				return e.build
			}
		}
		return 'no call'
	}
	assert builds('m.a') == 'linux'
	assert builds('m.b') == '!linux'
	// called outside the `$if` as well
	assert builds('m.c') == ''
	assert builds('m.d') == 'windows && amd64'
	assert builds('m.e') == 'a ? || b ?'
	assert builds('m.h') == 'windows || linux'
	assert builds('m.k') == 'linux && (x ? || y ?)'
	// a member of the `$for` variable, and a type parameter: every build
	assert builds('m.g') == ''
	assert builds('m.t') == ''
	// through a worker's batch
	syms, edges := extract_v_text('module m\n\nfn a() {}\n\nfn f() {\n\t\$if linux {\n\t\ta()\n\t}\n}\n',
		'm/m.v')
	fr := decode_file_result(encode_file_result(FileResult{ symbols: syms, edges: edges }))
	assert fr.edges.filter(it.kind == .calls && it.to == 'a').map(it.build) == ['linux']
	// get_node says which builds make a call, both ways
	text := g.explain('m.f')
	assert text.contains('a (m/m.v:7) at line 27 [\$if linux], b (m/m.v:9) at line 29 [\$if !linux], c (m/m.v:11) at lines 32, 34, d'), text
	assert text.contains('h (m/m.v:17) at lines 39, 45 [\$if windows || linux]'), text
	assert g.explain('m.k').contains('f (m/m.v:25) at line 47 [\$if linux && (x ? || y ?)]')
}

// A build and its opposite hold between them in every build, so two call sites or two
// copies of a declaration that have them are in every build, not in
// `windows || !windows`.
fn test_two_builds_that_are_opposites_make_every_build() {
	assert either_build('windows', '!windows') == ''
	assert either_build('!x ?', 'x ?') == ''
	assert either_build("@OS == 'linux'", "!(@OS == 'linux')") == ''
	// among more, from either side
	assert either_build('windows || linux', '!windows') == ''
	assert either_build('!darwin', 'linux || darwin') == ''
	assert either_build('a ? || !(b ? && c ?)', 'b ? && c ?') == ''
	// a group and the opposite of the whole of it
	assert either_build('windows || linux', '!(windows || linux)') == ''
	assert either_build('!(a ? || b ?)', 'a ? || b ?') == ''
	assert either_build('(js || windows)', '!(js || windows)') == ''
	// builds that aren't opposites are joined as before
	assert either_build('windows || linux', '!(windows || darwin)') == '(windows || linux) || !(windows || darwin)'
	// a shared term, with the opposite of one more: `(a && b) || (!a && b)` is `b`
	assert either_build('a ? && b ?', '!a ? && b ?') == 'b ?'
	assert either_build('!a ? && b ?', 'a ? && b ?') == 'b ?'
	assert either_build('windows && a ? && b ?', '!windows && a ? && b ?') == 'a ? && b ?'
	assert either_build('a ? && (b ? || c ?)', '!a ? && (b ? || c ?)') == '(b ? || c ?)'
	// the rest must match on both sides, or nothing is absorbed
	assert either_build('a ? && b ?', '!a ? && c ?') == 'a ? && b ? || !a ? && c ?'
	assert either_build('windows', 'linux') == 'windows || linux'
	assert either_build('windows', '!linux') == 'windows || !linux'
	assert either_build('windows || linux', '!darwin') == '(windows || linux) || !darwin'
	assert either_build('windows && x ?', '!windows') == 'windows && x ? || !windows'
	assert either_build('a ?', 'a ?') == 'a ?'
	assert either_build('', '!windows') == ''
	// two calls of one callee, in the two branches of one `$if`, are an edge in every
	// build; one in a branch alone is not
	g := graph_of({
		'm/m.v': 'module m\n\nfn f() {}\n\npub fn g() {\n\t\$if windows {\n\t\tf()\n\t} \$else {\n\t\tf()\n\t}\n}\n\npub fn h() {\n\t\$if windows {\n\t\tf()\n\t}\n}\n'
	})
	mut builds := map[string]string{}
	for e in g.edges {
		if e.kind == .calls {
			builds['${e.from} ${e.to}'] = e.build
		}
	}
	assert builds['m.g m.f'] == '', builds.str()
	assert builds['m.h m.f'] == 'windows', builds.str()
}

// A name that only a command-line option makes true (`-prod`, `-g`, `v test`,
// `-freestanding`, a backend other than C's) isn't the default build's, as a `-d` flag
// isn't; one that holds on a host's default build is.
fn test_a_name_only_an_option_makes_true_is_not_the_default_build() {
	for name in ['prod', 'debug', 'test', 'profile', 'autofree', 'nofloat', 'freestanding', 'prealloc',
		'no_bounds_checking', 'js', 'js_node', 'js_browser', 'js_freestanding', 'native'] {
		assert !default_term(name), name
		assert !default_term('(' + name + ')'), name
		assert !default_term('${name} || a ?'), name
		// without the option, or beside a name that holds by default
		assert default_term('!' + name), name
		assert default_term('${name} || linux'), name
	}
	for name in ['windows', 'linux', 'macos', 'tinyc', 'gcboehm', 'amd64', 'threads', 'no_backtrace',
		'glibc'] {
		assert default_term(name), name
	}
	// so a route that needs one is another build's, and the default build's come first
	g := graph_of({
		'm/a.v': 'module m\n\npub fn goal() {}\n\npub fn start() {\n\tdirect()\n\t\$if freestanding {\n\t\tbare()\n\t}\n}\n\nfn direct() {\n\tgoal()\n}\n\nfn bare() {\n\tgoal()\n}\n'
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.total == 2 && r.in_default == 1, r.str()
	assert r.other_builds == {
		'freestanding': 1
	}, r.other_builds.str()
	text := g.path_between('start', 'goal')
	assert text.all_before('\n') == '2 chains of calls from start to goal (1 in the default build), at most 10 calls longer than the shortest:', text
}

// The other names V sets only from the command line are not the default build's
// either: a target no host builds for unasked (`-arch wasm32`, `-os wasm32_wasi` or
// `wasm32_emscripten`), `-fast-math`, `v interpret`, the JavaScript backend's `es5`,
// `-apk`, and a C++ compiler (`cplusplus`). A file named for one,
// `_wasm32_emscripten.c.v`, is another build's.
fn test_a_name_only_a_target_or_option_makes_true_is_not_the_default_build() {
	for name in ['wasm32', 'wasm32_wasi', 'wasm32_emscripten', 'fast_math', 'es5', 'interpreter',
		'apk', 'cplusplus'] {
		assert !default_term(name), name
		assert default_term('!' + name), name
	}
	g := graph_of({
		'm/a.v':                     'module m\n\npub fn goal() {}\n\npub fn start() {\n\tdirect()\n\tbare()\n}\n\nfn direct() {\n\tgoal()\n}\n'
		'm/b_wasm32_emscripten.c.v': 'module m\n\nfn bare() {\n\tgoal()\n}\n'
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.total == 2 && r.in_default == 1, r.str()
	assert r.other_builds == {
		'wasm32_emscripten': 1
	}, r.other_builds.str()
}

// `&&` binds tighter than `||`: a build with an `||` outside any brackets is one term,
// `a ? && b ? || c ? && d ?`, not `a ?` and `b ? || c ?` and `d ?`, and it is the
// default build's when some alternative of it has only names that hold by default.
fn test_a_build_that_is_a_union_of_conjunctions_is_one_term() {
	assert build_terms('a ? && b ? || c ? && d ?') == ['a ? && b ? || c ? && d ?']
	assert build_terms('p ? && q ? || !p ? && q ?') == ['p ? && q ? || !p ? && q ?']
	assert build_terms('(a ? && b ? || c ?)') == ['a ? && b ? || c ?']
	assert build_terms('a ? && b ? || c ? && d ? && windows') == ['a ? && b ? || c ? && d ? && windows']
	// it is still split at an `&&` outside its brackets, and not at one inside
	assert build_terms('(a ? && b ? || c ?) && d ?') == ['a ? && b ? || c ?', 'd ?']
	assert build_terms('a ? && (b ? && c ? || d ?) && !windows') == ['a ?', 'b ? && c ? || d ?',
		'!windows']
	assert build_terms('a ? || b ?') == ['a ? || b ?']
	assert build_terms('a ? && b ? && a ?') == ['a ?', 'b ?']
	// default: every name of some alternative holds without an option
	assert !default_term('!p ? && q ?')
	assert !default_term('!p ? && q ? || !p ? && r ?')
	assert !default_term('windows && prod')
	assert !default_term('windows && x ?')
	assert default_term('windows && x ? || linux')
	assert default_term('windows && !prod || x ?')
	assert default_term('!x ? && !y ?')
	assert default_term('(x ? || windows) && !prod || y ?')
	// so a route is not dropped for terms its builds don't need: the first call is made
	// in `q ?` whether or not `p ?` holds, and the second where `p ?` doesn't
	g := graph_of({
		'm/a.v': 'module m\n\npub fn goal() {}\n\npub fn start() {\n\t\$if p ? && q ? {\n\t\tmid()\n\t}\n\t\$if !p ? && q ? {\n\t\tmid()\n\t}\n}\n\nfn mid() {\n\t\$if !p ? {\n\t\tgoal()\n\t}\n}\n'
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.total == 1 && r.in_default == 0, r.str()
	text := g.path_between('start', 'goal')
	assert text.contains('  needs \$if q ? && !p ?'), text
}

// A route of calls through declarations or calls of builds that contradict each
// other, `use_openssl ?` and `!use_openssl ?`, is in no build, and isn't one. The
// others say what they need, and those the default build has come first, even when
// longer.
fn test_a_route_of_calls_keeps_to_one_build_and_the_default_builds_come_first() {
	g := graph_of({
		'net/tcp.v':                    'module net

pub fn dial_tcp() {}

pub fn get() {
	direct()
	\$if use_openssl ? {
		ssl_dial()
	}
	plain_check()
}

fn direct() {
	via()
}

fn via() {
	dial_tcp()
}
'
		'net/ssl_d_use_openssl.v':      'module net

pub fn ssl_dial() {
	dial_tcp()
}
'
		'net/plain_notd_use_openssl.v': 'module net

fn plain_check() {
	ssl_dial()
}
'
	})
	r := g.count_call_paths('get', 'dial_tcp', 5)
	assert r.total == 2 && r.in_default == 1 && r.exact, r.str()
	assert r.paths == [['net.get', 'net.direct', 'net.via', 'net.dial_tcp'],
		['net.get', 'net.ssl_dial', 'net.dial_tcp']], r.paths.str()
	assert g.call_path('get', 'dial_tcp') == r.paths[0]
	text := g.path_between('get', 'dial_tcp')
	assert text.all_before('\n') == '2 chains of calls from get to dial_tcp (1 in the default build), at most 10 calls longer than the shortest:', text
	assert text.contains(['2. get (net/tcp.v:5)',
		'  -> ssl_dial (net/ssl_d_use_openssl.v:3), called at line 8 [\$if use_openssl ?]',
		'  -> dial_tcp (net/tcp.v:3), called at line 4', '  needs \$if use_openssl ?'].join('\n')), text
	assert !text.contains('plain_check')
	// one shown: the other build's route is said to be there, and what it needs
	one := g.render_call_paths(g.count_call_paths('get', 'dial_tcp', 1))
	assert one.ends_with('(1 more that only other builds have; the builds of all 1 such: \$if use_openssl ? (1))'), one
	// the terms of a build, and what contradicts each
	assert build_terms('a ? && (b || c) && !windows') == ['a ?', 'b || c', '!windows']
	assert opposite_term('a ?') == '!a ?'
	assert opposite_term('!(b || c)') == 'b || c'
	assert opposite_term('b || c') == '!(b || c)'
	assert default_term('!a ?') && default_term('windows') && default_term('a ? || linux')
	assert !default_term('a ?') && !default_term('a ? || b ?') && !default_term('js')
}

// A route that needs a build and its opposite is in no build, whichever declarations
// and calls the two come from: a call and its callee in the one step, the nested
// conditions of one call, or the first function and a later call. One that doesn't
// is a route.
fn test_a_route_is_in_no_build_when_any_two_of_its_terms_are_opposite() {
	// a call made under `use_openssl ?` to a function only `!use_openssl ?` has
	same_step := graph_of({
		'net/a.v':                      'module net

pub fn goal() {}

pub fn start() {
	\$if use_openssl ? {
		only_plain()
	}
}
'
		'net/plain_notd_use_openssl.v': 'module net

fn only_plain() {
	goal()
}
'
	})
	r := same_step.count_call_paths('start', 'goal', 5)
	assert r.total == 0 && r.paths.len == 0, r.str()
	// one call under `x ?` and, inside it, `!x ?`
	nested := graph_of({
		'm/a.v': 'module m

pub fn goal() {}

pub fn start() {
	\$if x ? {
		\$if !x ? {
			goal()
		}
	}
}
'
	})
	n := nested.count_call_paths('start', 'goal', 5)
	assert n.total == 0 && n.paths.len == 0, n.str()
	// a first function only `!use_openssl ?` has, and a later call under `use_openssl ?`
	first := graph_of({
		'net/a.v':                      'module net

pub fn goal() {}
'
		'net/plain_notd_use_openssl.v': 'module net

fn start() {
	\$if use_openssl ? {
		goal()
	}
}
'
	})
	f := first.count_call_paths('start', 'goal', 5)
	assert f.total == 0 && f.paths.len == 0, f.str()
	// the same call to a function only `use_openssl ?` has is a route, in that build
	agree := graph_of({
		'net/a.v':                 'module net

pub fn goal() {}

pub fn start() {
	\$if use_openssl ? {
		only_ssl()
	}
}
'
		'net/ssl_d_use_openssl.v': 'module net

fn only_ssl() {
	goal()
}
'
	})
	a := agree.count_call_paths('start', 'goal', 5)
	assert a.total == 1 && a.in_default == 0 && a.paths.len == 1, a.str()
	assert a.other_builds == {
		'use_openssl ?': 1
	}, a.other_builds.str()
}

// Routes that need the same builds count as one entry in the builds of the routes the
// default build hasn't, whichever order they meet the builds in.
fn test_routes_that_need_the_same_builds_are_counted_together() {
	g := graph_of({
		'm/a.v': 'module m

pub fn goal() {}

pub fn start() {
	\$if x ? {
		r1()
	}
	\$if y ? {
		r2()
	}
}

fn r1() {
	\$if y ? {
		goal()
	}
}

fn r2() {
	\$if x ? {
		goal()
	}
}
'
	})
	r := g.count_call_paths('start', 'goal', 5)
	assert r.total == 2 && r.in_default == 0, r.str()
	assert r.other_builds.len == 1 && r.other_builds['x ? && y ?'] == 2, r.other_builds.str()
	one := g.render_call_paths(g.count_call_paths('start', 'goal', 1))
	assert one.ends_with('(1 more that only other builds have; the builds of all 2 such: \$if x ? && y ? (2))'), one
}

// A declaration that several build files declare under one id is shown in a route as
// the copy its next call is made from: `vschannel_fresh_round_trip`'s calls are in
// vschannel_pooled_transport_windows.c.v, not in the `-d cross` stub of it, which
// the index happened to show, with call lines the stub doesn't have.
fn test_a_route_shows_the_copy_of_a_declaration_its_call_is_made_from() {
	root := write_tree('route_copy', {
		'http/http.v':            'module http

pub fn get() int {
	return probe()
}

fn helper() int {
	return 1
}
'
		'http/stub_d_cross.v':    'module http

fn probe() int {
	return 0
}
'
		'http/probe_windows.c.v': 'module http

fn other() int {
	return 2
}

fn probe() int {
	x := other()
	return helper() + x
}
'
	})
	defer {
		os.rmdir_all(root) or {}
	}
	g := build_graph(Options{ root: root, with_calls: true })
	probes := g.symbols.filter(it.name == 'probe')
	assert probes.len == 2 && probes[0].id == probes[1].id, probes.map(it.id).str()
	text := g.path_between('get', 'helper')
	assert text.contains('  -> probe (http/probe_windows.c.v:7), called at line 4'), text
	assert text.contains('  -> helper (http/http.v:7), called at line 9'), text
	// with no call after it, a copy is shown as the index has it
	assert g.copy_holding(probes, []int{}) == none
	assert g.copy_holding(probes, [9]) or { Symbol{} }.file == 'http/probe_windows.c.v'
	assert g.copy_holding(probes, [4]) or { Symbol{} }.file == 'http/stub_d_cross.v'
	assert g.copy_holding(probes, [20]) == none
	assert g.copy_holding(probes[..1], [4]) == none
}

// a method with type parameters of its own, `fn (e Encoder) encode[T](val T)`, is called on the
// types its call sites pass, as a generic function is: directly, through another generic method,
// and through a generic function. A method of a generic struct with its own `X` finds a field's
// method on each instance of X, and an instance of the struct's T is not one of X's
fn test_a_method_with_its_own_type_parameters_is_expanded_by_its_call_sites() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Paper {}

pub fn (p Paper) describe() string {
	return \'\'
}

pub struct Encoder {}

pub fn (e Encoder) encode[T](val T) string {
	return val.describe()
}

pub fn (e Encoder) wrap[T](val T) string {
	return e.encode(val)
}

pub fn encode_all[T](val T) string {
	e := Encoder{}
	return e.wrap(val)
}

pub struct Res {}

pub fn (r Res) add() {}

pub struct Junk {}

pub fn (j Junk) add() {}

pub struct Ctx {
pub:
	res Res
}

// an instance of X leaking into T would link Store[T].show to this
pub fn (c Ctx) describe() string {
	return \'\'
}

pub struct Store[T] {}

pub fn (s Store[T]) touch[X](ctx X) {
	ctx.res.add()
}

pub fn (s Store[T]) show(v T) string {
	return v.describe()
}

fn keep() {
	s := Store[Paper]{}
	s.touch(Ctx{})
}
'
		'lib/app/app.v':     'module app

import codec

fn run() {
	e := codec.Encoder{}
	e.encode(codec.Pen{})
	codec.encode_all(codec.Ink{})
}
'
	})
	targets := fn [g] (from string, name string) []string {
		mut out := g.edges.filter(it.kind == .calls && it.from == from && it.to.ends_with(name)).map(it.to)
		out.sort()
		return out
	}
	assert targets('lib.codec.Encoder.encode', 'describe') == ['lib.codec.Ink.describe',
		'lib.codec.Pen.describe'], targets('lib.codec.Encoder.encode', 'describe').str()
	assert targets('lib.codec.Store[T].touch', 'add') == ['lib.codec.Res.add'], targets('lib.codec.Store[T].touch',
		'add').str()
	// the struct's own T is still read from its instance, and X's instance is none of T's
	assert targets('lib.codec.Store[T].show', 'describe') == ['lib.codec.Paper.describe'], targets('lib.codec.Store[T].show',
		'describe').str()
}

// `T.name` on a type parameter is the type's name, a string, so a call on it is the string's
fn test_a_type_parameters_name_is_a_string() {
	g := graph_of({
		'vlib/builtin/string.v': 'module builtin

pub fn (s string) index(p string) ?int {
	return none
}

pub fn (s string) to_lower() string {
	return s
}

pub fn (r rune) to_lower() rune {
	return r
}

pub fn (r rune) index(p string) ?int {
	return none
}

pub fn (i int) str() string {
	return \'\'
}

pub fn (b u8) str() string {
	return \'\'
}
'
		'lib/orm/orm.v':         'module orm

fn table_from_struct[T]() string {
	mut table_name := T.name
	if pos := table_name.index(\'[\') {
		table_name = table_name[..pos]
	}
	println(T.typ.str())
	println(T.indirections.str())
	return table_name.to_lower()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.orm.table_from_struct').map(it.to)
	assert 'vlib.builtin.string.index' in calls, calls.str()
	assert 'vlib.builtin.string.to_lower' in calls, calls.str()
	// `T.typ` is an int and `T.indirections` a u8, as V's checker types them
	assert 'vlib.builtin.int.str' in calls, calls.str()
	assert 'vlib.builtin.u8.str' in calls, calls.str()
}

// a method declared on a C struct, `fn (mut p C.sg_pipeline) free()`, is a method of the alias
// that names the struct, `type Pipeline = C.sg_pipeline`, here on a fixed array's element
fn test_a_method_on_a_c_struct_is_found_through_its_alias() {
	g := graph_of({
		'vlib/builtin/array.v': 'module builtin

pub fn (a &array) free() {}

pub fn (s &string) free() {}
'
		'lib/gfx/structs.c.v':  'module gfx

@[typedef]
pub struct C.sg_pipeline {}

pub type Pipeline = C.sg_pipeline

pub fn (mut p C.sg_pipeline) free() {}
'
		'lib/render/render.v':  'module render

import gfx

pub struct Pipe {
	pips [3]gfx.Pipeline
}

fn destroy(p Pipe) {
	mut pip := p.pips[0]
	pip.free()
}
'
		'lib/app/app.v':        'module app

import gfx

fn make() {
	mut raw := C.sg_pipeline{}
	raw.free()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.render.destroy').map(it.to)
	assert calls == ['lib.gfx.C.sg_pipeline.free'], calls.str()
	// a C struct is one name for the whole program: written in another module, its method is
	// still the one module's that declares it
	raw := g.edges.filter(it.kind == .calls && it.from == 'lib.app.make').map(it.to)
	assert raw == ['lib.gfx.C.sg_pipeline.free'], raw.str()
}

// builtin's `clone()` on an alias of a map returns plain `map`, but the value is the alias's
// own map: an index into it, and a method of the element, are still typed
fn test_a_clone_of_a_map_alias_keeps_its_type() {
	g := graph_of({
		'vlib/builtin/map.v': 'module builtin

pub fn (m &map) clone() map {
	return *m
}

pub fn (a &array) clone() array {
	return *a
}
'
		'lib/json2/any.v':    'module json2

pub type Any = string | int | map[string]Any

pub fn (f Any) as_map() map[string]Any {
	return map[string]Any{}
}

pub struct Other {}

pub fn (o Other) as_map() map[string]Any {
	return map[string]Any{}
}
'
		'lib/veb/doc.v':      'module veb

import json2

pub type Schema = map[string]json2.Any

pub struct Doc {}

fn (d &Doc) resolve(s Schema) Schema {
	return s
}

fn (d &Doc) variant(base Schema) {
	mut choice := d.resolve(base).clone()
	props := (choice[\'p\'] or { json2.Any(0) }).as_map().clone()
	println(props)
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.veb.Doc.variant').map(it.to)
	assert 'lib.json2.Any.as_map' in calls, calls.str()
	assert !calls.contains('clone'), calls.str()
}

// `if x := opt { x } else { ... }` as a value has the type of what the option holds: the first
// branch sees `x`, declared by the guard
fn test_an_if_guard_value_has_the_options_type() {
	g := graph_of({
		'lib/drv/drv.v': 'module drv

pub struct Prepared {}

pub fn (mut p Prepared) release() {}

pub struct Other {}

pub fn (mut o Other) release() {}

fn get() ?&Prepared {
	return none
}

fn run() {
	w := get()
	mut prepared := if x := w {
		x
	} else {
		panic(\'none\')
	}
	prepared.release()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.drv.run').map(it.to)
	assert 'lib.drv.Prepared.release' in calls, calls.str()
}

// a call on each field of a method's own type parameter, `val.$(field.name).show()` in
// `fn (e Enc) encode[T](val T)`, waits for T's instances as a generic function's does: it
// reaches the show of the field the call site's struct has, as a field-loop edge, and is not
// taken by name first for the one `show` there is
fn test_a_field_loop_on_a_methods_own_type_parameter_reaches_each_field() {
	g := graph_of({
		'lib/enc/enc.v': 'module enc

struct Alpha {}

fn (a Alpha) show() {}

struct Box {
	a Alpha
	n int
}

struct Enc {}

fn (e Enc) encode[T](val T) {
	\$for field in T.fields {
		val.\$(field.name).show()
	}
}

fn run() {
	e := Enc{}
	e.encode(Box{})
}
'
	})
	shows := g.edges.filter(it.kind == .calls && it.from == 'lib.enc.Enc.encode')
	assert shows.map(it.to) == ['lib.enc.Alpha.show'], shows.str()
	assert shows.all(it.provenance == .comptime), shows.str()
}
// two calls of one generic method through different receivers in one function are two raw
// edges that resolve to the same method: both call sites' arguments are its instances
fn test_every_call_site_of_a_generic_method_gives_it_instances() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Encoder {}

pub fn (e Encoder) encode[T](val T) string {
	return val.describe()
}

fn first() Encoder {
	return Encoder{}
}

fn second() Encoder {
	return Encoder{}
}

fn run() {
	a := first()
	b := second()
	a.encode(Pen{})
	b.encode(Ink{})
}
'
	})
	mut d := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Encoder.encode').map(it.to)
	d.sort()
	assert d == ['lib.codec.Ink.describe', 'lib.codec.Pen.describe'], d.str()
}

// `$if T is Pen { val.describe() }` in a method with its own T is compiled only for Pen, as
// in a generic function: Ink, the other instance, is not linked from that block
fn test_a_comptime_check_on_a_methods_own_type_parameter_narrows_it() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Encoder {}

pub fn (e Encoder) encode[T](val T) string {
	\$if T is Pen {
		return val.describe()
	}
	return \'\'
}

fn run() {
	e := Encoder{}
	e.encode(Pen{})
	e.encode(Ink{})
}
'
	})
	d := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Encoder.encode').map(it.to)
	assert d == ['lib.codec.Pen.describe'], d.str()
}

// two modules that each declare a method on one C struct: the receiver's own module's is the
// one, found before the program-wide fallback, which two declarations leave undecided
fn test_a_c_struct_method_in_the_receivers_module_comes_first() {
	g := graph_of({
		'lib/gfx/structs.c.v':   'module gfx

@[typedef]
pub struct C.sg_pipeline {}

pub type Pipeline = C.sg_pipeline

pub fn (mut p C.sg_pipeline) free() {}
'
		'lib/other/structs.c.v': 'module other

pub fn (mut p C.sg_pipeline) free() {}
'
		'lib/render/render.v':   'module render

import gfx
import other

pub struct Pipe {
	pips [3]gfx.Pipeline
}

fn destroy(p Pipe) {
	mut pip := p.pips[0]
	pip.free()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.render.destroy').map(it.to)
	assert calls == ['lib.gfx.C.sg_pipeline.free'], calls.str()
}

// a call the expansion links, `t.put(Pen{})` on a `t T` that is an Enc, reaches a method
// with a type parameter of its own: its argument is that method's instance too, so a call
// on X in Enc.put reaches Pen's method
fn test_a_generic_method_reached_through_a_type_parameter_gets_its_arguments_as_instances() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Enc {}

pub fn (e Enc) put[X](x X) string {
	return x.describe()
}

pub struct Other {}

pub fn (o Other) put[X](x X) string {
	return \'\'
}

pub fn run[T](t T) string {
	return t.put(Pen{})
}

fn keep() {
	run(Enc{})
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Enc.put').map(it.to)
	assert calls == ['lib.codec.Pen.describe'], calls.str()
}

// the other branches of an if-guard value: an `else if` guard's own variable, and `err`, the
// error, in a plain `else`
fn test_the_else_branches_of_an_if_guard_value_are_typed() {
	g := graph_of({
		'vlib/builtin/error.v': 'module builtin

pub interface IError {
	msg() string
}
'
		'lib/drv/drv.v':        'module drv

pub struct Prepared {}

pub fn (mut p Prepared) release() {}

pub fn (p Prepared) msg() string {
	return \'\'
}

pub struct Other {}

pub fn (mut o Other) release() {}

pub fn (o Other) msg() string {
	return \'\'
}

fn get() ?&Prepared {
	return none
}

fn mystery() ?int {
	return none
}

fn chained() {
	mut p := if x := mystery() {
		none
	} else if y := get() {
		y
	} else {
		panic(\'none\')
	}
	p.release()
}

fn failed() {
	e := if x := mystery() {
		none
	} else {
		err
	}
	println(e.msg())
}
'
	})
	chained := g.edges.filter(it.kind == .calls && it.from == 'lib.drv.chained').map(it.to)
	assert 'lib.drv.Prepared.release' in chained, chained.str()
	failed := g.edges.filter(it.kind == .calls && it.from == 'lib.drv.failed').map(it.to)
	assert 'vlib.builtin.IError.msg' in failed, failed.str()
}

// a C struct method declared in two modules, neither the receiver's: the program-wide
// fallback takes only the one module that declares it, so the call stays unresolved
fn test_a_c_struct_method_two_other_modules_declare_stays_unresolved() {
	g := graph_of({
		'lib/gfx/structs.c.v':   'module gfx

@[typedef]
pub struct C.sg_pipeline {}

pub fn (mut p C.sg_pipeline) free() {}
'
		'lib/other/structs.c.v': 'module other

pub fn (mut p C.sg_pipeline) free() {}
'
		'lib/app/app.v':         'module app

import gfx
import other

fn make() {
	mut raw := C.sg_pipeline{}
	raw.free()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.make').map(it.to)
	assert calls == ['free'], calls.str()
}

// builtin's `clone()` on an alias of an array returns plain `array`: the value keeps the
// alias, so an element of it, and that element's method, are typed
fn test_a_clone_of_an_array_alias_keeps_its_type() {
	g := graph_of({
		'vlib/builtin/array.v': 'module builtin

pub fn (a &array) clone() array {
	return *a
}
'
		'lib/pens/pens.v':      'module pens

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub type Pens = []Pen

fn first(ps Pens) string {
	c := ps.clone()
	return c[0].describe()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.pens.first').map(it.to)
	assert 'lib.pens.Pen.describe' in calls, calls.str()
}

// a call on a field of a type parameter's instance, `ctx.enc.put(Pen{})` on a `ctx T`,
// that the expansion links to a method with a type parameter of its own gives it its argument
fn test_a_generic_method_reached_through_a_field_of_a_type_parameter_gets_its_arguments() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Enc {}

pub fn (e Enc) put[X](x X) string {
	return x.describe()
}

pub struct Other {}

pub fn (o Other) put[X](x X) string {
	return \'\'
}

pub struct Ctx {
pub:
	enc Enc
}

pub fn run[T](ctx T) string {
	return ctx.enc.put(Pen{})
}

fn keep() {
	run(Ctx{})
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Enc.put').map(it.to)
	assert calls == ['lib.codec.Pen.describe'], calls.str()
}

// a method with its own type parameter that a direct call already gives an instance, and
// the expansion reaches with another: its call on X is linked to both, not only the first
fn test_a_late_instance_joins_the_ones_a_generic_method_had() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Enc {}

pub fn (e Enc) put[X](x X) string {
	return x.describe()
}

pub struct Other {}

pub fn (o Other) put[X](x X) string {
	return \'\'
}

pub fn run[T](t T) string {
	return t.put(Pen{})
}

fn keep() {
	run(Enc{})
	e := Enc{}
	e.put(Ink{})
}
'
	})
	mut calls := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Enc.put').map(it.to)
	calls.sort()
	assert calls == ['lib.codec.Ink.describe', 'lib.codec.Pen.describe'], calls.str()
}

// a field loop on a method's own type parameter, in a method the expansion reaches: the call
// is linked to each field's method as a direct call would be, whether a plain call of the
// same name sits beside it or another module's method is the only one by that name nearby
fn test_a_field_loop_in_a_generic_method_the_expansion_reaches_is_linked() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Alpha {}

pub fn (a Alpha) show() {}
'
		'lib/codec/codec.v': 'module codec

import other

pub struct Local {}

pub fn (l Local) show() {}

pub struct Box {
	a other.Alpha
}

pub fn (b Box) show() {}

pub struct Enc {}

pub fn (e Enc) put[X](x X) {
	x.show()
	\$for field in X.fields {
		x.\$(field.name).show()
	}
}

pub struct Decoy {}

pub fn (d Decoy) put[X](x X) {}

pub fn run[T](t T) {
	t.put(Box{})
}

fn keep() {
	run(Enc{})
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Enc.put')
	assert calls.any(it.to == 'lib.codec.Box.show' && it.provenance == .inferred), calls.str()
	assert calls.any(it.to == 'lib.other.Alpha.show' && it.provenance == .comptime), calls.str()
	assert !calls.any(it.to == 'lib.codec.Local.show'), calls.str()
}

// a call the expansion links can pass the caller's own type parameter on, `t.put(v)` in
// `run[T, V]`: the method it reaches takes V's types, through the flow, in the next pass
fn test_a_generic_method_reached_through_a_type_parameter_takes_a_passed_on_type() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Pen {}

pub fn (p Pen) describe() string {
	return \'\'
}

pub struct Ink {}

pub fn (i Ink) describe() string {
	return \'\'
}

pub struct Enc {}

pub fn (e Enc) put[X](x X) string {
	return x.describe()
}

pub struct Other {}

pub fn (o Other) put[X](x X) string {
	return \'\'
}

pub fn run[T, V](t T, v V) string {
	return t.put(v)
}

fn keep() {
	run(Enc{}, Pen{})
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.codec.Enc.put').map(it.to)
	assert calls == ['lib.codec.Pen.describe'], calls.str()
}

// reuse_freed_arenas allocates over what a freed arena held, so that anything still
// pointing into one reads as other text. A small arena's memory outlives its free
// until it is reused, so without this a dangling string reads as it did.
fn reuse_freed_arenas() {
	$if prealloc {
		for _ in 0 .. 40 {
			scope := unsafe { prealloc_scope_begin() }
			mut junk := []string{}
			for i in 0 .. 20000 {
				junk << 'reused arena memory ${i}'
			}
			unsafe { prealloc_scope_end(scope) }
		}
	}
}

// extract_text is all the text of what an extract returned, a new copy of it.
fn extract_text(g Graph, r ExtractReport) string {
	mut b := []string{}
	b << 'root ${g.root} binary ${r.binary_hash}'
	b << 'failed ${r.failed} stale ${r.stale} partial ${r.partial}'
	mut files := g.file_hashes.keys()
	files.sort()
	for f in files {
		b << 'hash ${f} ${g.file_hashes[f]}'
	}
	for s in g.symbols {
		b << 'sym ${s.id}|${s.name}|${s.signature}|${s.file}|${s.line}|${s.parent}|${s.doc}|${s.build}|${s.recipe}|${s.tparams}'
	}
	for e in g.edges {
		b << 'edge ${e.from}|${e.to}|${e.kind}|${e.recv_type}|${e.recv_recipe}|${e.arg_sites}|${e.guards}|${e.lines}|${e.build}|${e.file}'
	}
	for s in g.library.symbols {
		b << 'lib ${s.id}|${s.name}|${s.signature}|${s.file}|${s.end_line}|${s.parent}|${s.doc}'
	}
	return b.join('\n')
}

fn test_what_an_extract_returns_outlives_the_arenas_it_ran_in() {
	dir := os.join_path(os.temp_dir(), 'graphify_arena_worker_${os.getpid()}')
	tpl := os.join_path(dir, 'canned')
	os.mkdir_all(tpl) or { panic(err) }
	worker := compile_crash_worker(dir)
	root := write_tree('arena_outlives', {
		'crash.v':   'module demo\n\npub fn crash_fn() int {\n\treturn 2\n}\n'
		'ok.v':      'module demo\n\n// ok_fn has a doc.\npub fn ok_fn() int {\n\treturn crash_fn()\n}\n'
		'partial.v': partial_parse_src
	})
	out := root + '_out'
	os.setenv('GRAPHIFY_TEST_CANNED', tpl, true)
	defer {
		os.rmdir_all(dir) or {}
		os.rmdir_all(root) or {}
		os.rmdir_all(out) or {}
	}
	for rel in ['crash.v', 'ok.v', 'partial.v'] {
		write_canned(tpl, root, rel)
	}
	build_graph_resilient(root, worker, out)
	// crash.v changes and its worker dies, so the report has something in all its lists
	os.write_file(os.join_path(root, 'crash.v'), 'module demo\n\npub fn crash_fn() int {\n\treturn 4\n}\n') or {
		panic(err)
	}
	os.write_file(os.join_path(tpl, 'crash_now'), '') or { panic(err) }
	g, r := build_graph_resilient(root, worker, out)
	assert r.failed == ['crash.v']
	assert r.stale == ['crash.v']
	assert r.partial == ['partial.v']
	assert g.file_hashes.len == 3
	assert g.symbols.any(it.id == 'demo.ok_fn' && it.doc != '')
	assert g.edges.any(it.from == 'demo.ok_fn' && it.to == 'demo.crash_fn' && it.lines.len == 1)
	before := extract_text(g, r)
	reuse_freed_arenas()
	assert extract_text(g, r) == before
}

fn test_the_arena_copies_share_no_string_with_what_they_copy() {
	e := Edge{
		from:        'from'
		to:          'to'
		kind:        .calls
		provenance:  .inferred
		is_method:   true
		recv_type:   'recv_type'
		recv_recipe: 'recv_recipe'
		arg_sites:   'arg_sites'
		guards:      'guards'
		lines:       [1, 2]
		build:       'build'
		file:        'file'
	}
	c := clone_edges([e])[0]
	// a string field added to Edge must be set above, which this fails on until it is,
	// and copied by clone_edges: the `...e` there would only share it
	$for f in Edge.fields {
		$if f.typ is string {
			assert e.$(f.name) != '', f.name
			assert c.$(f.name) == e.$(f.name), f.name
			assert voidptr(c.$(f.name).str) != voidptr(e.$(f.name).str), f.name
		}
	}
	assert c.kind == .calls && c.provenance == .inferred && c.is_method
	assert c.lines == [1, 2]
	assert voidptr(c.lines.data) != voidptr(e.lines.data)
	s := Symbol{
		id:        'id'
		name:      'name'
		kind:      .method
		signature: 'signature'
		file:      'file'
		line:      3
		end_line:  4
		is_pub:    true
		parent:    'parent'
		doc:       'doc'
		build:     'build'
		recipe:    'recipe'
		tparams:   'tparams'
	}
	g := compact_graph(Graph{
		symbols: [s]
		edges:   [e]
	})
	cs := g.symbols[0]
	$for f in Symbol.fields {
		$if f.typ is string {
			assert s.$(f.name) != '', f.name
			assert cs.$(f.name) == s.$(f.name), f.name
			assert voidptr(cs.$(f.name).str) != voidptr(s.$(f.name).str), f.name
		}
	}
	assert cs.kind == .method && cs.line == 3 && cs.end_line == 4 && cs.is_pub
	assert g.edges[0].to == 'to' && voidptr(g.edges[0].to.str) != voidptr(e.to.str)
}

fn test_arena_copies_share_a_repeated_field_only_with_the_same_text() {
	a := Edge{
		from: 'one'
		file: 'f.v'
	}
	b := Edge{
		from: 'one'.clone()
		file: 'g.v'
	}
	d := Edge{
		from: 'two'
		file: 'g.v'.clone()
	}
	out := clone_edges([a, b, d])
	assert out.map(it.from) == ['one', 'one', 'two']
	assert out.map(it.file) == ['f.v', 'g.v', 'g.v']
	assert voidptr(out[1].from.str) == voidptr(out[0].from.str)
	assert voidptr(out[1].from.str) != voidptr(b.from.str)
	assert voidptr(out[2].file.str) == voidptr(out[1].file.str)
	syms := clone_symbols([Symbol{ file: 'f.v', parent: 'p' }, Symbol{ file: 'g.v', parent: 'p'.clone() }])
	assert syms.map(it.file) == ['f.v', 'g.v']
	assert voidptr(syms[1].parent.str) == voidptr(syms[0].parent.str)
}

fn test_arena_copies_of_a_report_and_its_maps_are_deep() {
	strs := ['a.v']
	assert clone_strings(strs) == strs
	assert voidptr(clone_strings(strs)[0].str) != voidptr(strs[0].str)
	key := 'k.v'
	hashes := {
		key: 'hash'
	}
	copied := clone_string_map(hashes)
	assert copied == hashes
	assert voidptr(copied[key].str) != voidptr(hashes[key].str)
	for k, _ in copied {
		assert voidptr(k.str) != voidptr(key.str)
	}
	files := {
		key: true
	}
	flags := clone_bool_map(files)
	assert flags == files
	for k, _ in flags {
		assert voidptr(k.str) != voidptr(key.str)
	}
}

// bp_sym is a symbol's fields as the protocol writes them, `n` of them.
fn bp_sym(n int) string {
	return ['i', 'n', int(SymbolKind.method).str(), 's', 'f', '3', '9', '1', 'p', 'd', 'r', 't', 'b'][..n].join(bp_fs)
}

// bp_edge is an edge's fields as the protocol writes them, `n` of them.
fn bp_edge(n int) string {
	return ['a', 'b', int(EdgeKind.calls).str(), '1', 'T', 'f', 'q', int(EdgeProvenance.inferred).str(),
		's', 'g', '1,2', 'b'][..n].join(bp_fs)
}

fn test_decoding_a_line_keeps_a_record_only_with_its_required_fields() {
	assert decode_file_result(bp_sym(9)).symbols.len == 0
	short := decode_file_result(bp_sym(10)).symbols
	assert short.len == 1
	assert short[0].id == 'i' && short[0].kind == .method && short[0].line == 3
	assert short[0].end_line == 9 && short[0].is_pub && short[0].doc == 'd'
	assert short[0].recipe == '' && short[0].build == ''
	full := decode_file_result(bp_sym(13)).symbols[0]
	assert full.recipe == 'r' && full.tparams == 't' && full.build == 'b'
	// a bad record is skipped, not the ones around it
	mixed := decode_file_result(bp_sym(9) + bp_rs + bp_sym(10) + bp_rs).symbols
	assert mixed.len == 1
	assert decode_file_result('${bp_ss}${bp_edge(2)}').edges.len == 0
	three := decode_file_result('${bp_ss}${bp_edge(3)}').edges
	assert three.len == 1
	assert three[0].to == 'b' && !three[0].is_method && three[0].lines == []
	// the odd-line marker of a worker, and a line with no sections, hold nothing
	odd := decode_file_result('{}')
	assert odd.symbols.len == 0 && odd.edges.len == 0 && odd.parse_error == ''
	assert decode_file_result('').symbols.len == 0
}

fn test_decoding_reads_provenance_only_from_an_edge_that_has_it() {
	assert decode_file_result('${bp_ss}${bp_edge(7)}').edges[0].provenance == .extracted
	assert decode_file_result('${bp_ss}${bp_edge(8)}').edges[0].provenance == .inferred
}

fn test_decoding_reads_each_edge_field_from_its_own_place() {
	e := decode_file_result('${bp_ss}${bp_edge(12)}').edges[0]
	assert e.from == 'a' && e.to == 'b' && e.kind == .calls && e.is_method
	assert e.recv_type == 'T' && e.file == 'f' && e.recv_recipe == 'q'
	assert e.provenance == .inferred
	assert e.arg_sites == 's' && e.guards == 'g'
	assert e.lines == [1, 2] && e.build == 'b'
}

fn test_decoding_a_flag_field_takes_only_a_lone_one() {
	assert decode_file_result('${bp_ss}a${bp_fs}b${bp_fs}0${bp_fs}1').edges[0].is_method
	assert !decode_file_result('${bp_ss}a${bp_fs}b${bp_fs}0${bp_fs}11').edges[0].is_method
	assert !decode_file_result('${bp_ss}a${bp_fs}b${bp_fs}0${bp_fs}0').edges[0].is_method
}

fn test_decoding_restores_newlines_and_stops_at_the_sections_end() {
	fr := FileResult{
		symbols:     [Symbol{ id: 'i', signature: 'a\nb', doc: 'c\r\nd' }]
		parse_error: 'first\nsecond'
	}
	back := decode_file_result(encode_file_result(fr))
	assert back.symbols[0].signature == 'a\nb'
	assert back.symbols[0].doc == 'c\nd'
	assert back.parse_error == 'first\nsecond'
	assert decode_file_result('${bp_ss}${bp_ss}err${bp_ss}more').parse_error == 'err'
}

fn test_decoding_reads_the_ints_the_protocol_writes() {
	assert bp_int_at('-5', 0, 2) == -5
	assert bp_int_at('+5', 0, 2) == 5
	assert bp_int_at('12x', 0, 3) == 12
	assert bp_int_at('', 0, 0) == 0
	sym := decode_file_result(['i', 'n', '0', 's', 'f', '-5', '7', '0', 'p', 'd'].join(bp_fs)).symbols[0]
	assert sym.line == -5 && sym.end_line == 7
	assert decode_file_result('${bp_ss}${bp_edge(11)}').edges[0].lines == [1, 2]
	sites := ['a', 'b', '0', '0', '', '', '', '0', '', '', '1,,3,'].join(bp_fs)
	assert decode_file_result('${bp_ss}${sites}').edges[0].lines == [1, 0, 3, 0]
}

fn test_the_library_files_of_an_extract_outlive_the_arena_they_were_read_in() {
	// keep_reached_library drops the edges of the files `lib_files` names after
	// resolve_edges has allocated over the arena they were read in, which takes a
	// project large enough that it does
	base, roots := library_fixture('library_arena')
	defer {
		os.rmdir_all(base) or {}
		os.setenv('GRAPHIFY_LIB_VROOT', '', true)
		os.setenv('GRAPHIFY_LIB_VMODULES', '', true)
	}
	mut big := []string{}
	for i in 0 .. 4000 {
		big << 'fn generated_${i}() int {\n\treturn generated_${i + 1}()\n}\n'
	}
	big << 'fn generated_4000() int {\n\treturn 0\n}\n'
	os.write_file(os.join_path(base, 'proj', 'generated.v'), 'module main\n\n' + big.join('\n')) or {
		panic(err)
	}
	g, _ := build_graph_with_library(os.join_path(base, 'proj'), '', os.join_path(base,
		'out'), roots)
	assert g.library.symbols.any(it.id == 'vlib.os.join_path' && it.file != ''), g.library.symbols.map(it.id).str()
	assert g.edges.any(it.from == 'main.generated_0' && it.to == 'main.generated_1')
	before := extract_text(g, ExtractReport{})
	reuse_freed_arenas()
	assert extract_text(g, ExtractReport{}) == before
	// a module from VMODULES is kept whole, with its edges; vlib's are dropped
	vlib := g.edges.filter(it.file.starts_with(lib_vlib_prefix))
	assert vlib.len == 0, vlib.map(it.file).str()
}

// test_a_prealloc_extract_uses_nothing_it_has_freed runs the real command in the build
// that unmaps an arena's memory as it is freed, so that using any of it crashes or
// comes out wrong: what a worker's arena for each file and the bundle's arena hold,
// and a global of the runtime set up inside an arena, as V's table of closures is
// by the first closure. Reused memory hides all of these from the tests above, which
// run in one process that has set up such globals long before. Graphify's own source,
// with the vlib it imports, is a project large enough for the library's closures to
// run with arenas already freed; on Windows, freed memory does not fault.
fn test_a_prealloc_extract_uses_nothing_it_has_freed() {
	$if windows {
		return
	}
	dir := os.join_path(os.temp_dir(), 'graphify_prealloc_cli_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	vexe := @VEXE
	cli := os.join_path(@DIR, 'cmd', 'cli')
	gc := os.join_path(dir, 'gc_cli')
	unmapping := os.join_path(dir, 'unmapping_cli')
	built := os.exec([vexe, '-o', gc, cli])
	assert built.exit_code == 0, built.output
	built2 := os.exec([vexe, '-prealloc', '-d', 'prealloc_no_recycle', '-d', 'trace_prealloc', '-o',
		unmapping, cli])
	assert built2.exit_code == 0, built2.output
	old_vroot := os.getenv('VROOT')
	old_vmodules := os.getenv('VMODULES')
	os.unsetenv(no_extractor_env)
	os.setenv('VROOT', @VEXEROOT, true)
	os.setenv('VMODULES', os.join_path(dir, 'no_vmodules'), true)
	defer {
		os.setenv('VROOT', old_vroot, true)
		os.setenv('VMODULES', old_vmodules, true)
	}
	expected := os.exec([gc, 'extract', @DIR, '--out', os.join_path(dir, 'gc_out')])
	assert expected.exit_code == 0, expected.output
	got := os.exec([unmapping, 'extract', @DIR, '--out', os.join_path(dir, 'unmapping_out')])
	assert got.exit_code == 0, got.output
	assert !got.output.contains('unparseable'), got.output
	// the arenas are freed, which the rest of this test can't see: with nothing freed,
	// nothing can be used after it. trace_prealloc logs the parent's arenas; a worker
	// silences its stderr. Parsing's and resolve_edges' are freed after copying out of
	// them, and the cache's and the bundle's end with what they wrote.
	assert got.output.count('[trace_prealloc] scope free-after') == 2, got.output
	assert got.output.count('[trace_prealloc] scope end') == 2, got.output
	for name in ['graph.json', 'GRAPH_REPORT.md'] {
		want := os.read_file(os.join_path(dir, 'gc_out', name)) or { panic(err) }
		have := os.read_file(os.join_path(dir, 'unmapping_out', name)) or { panic(err) }
		assert want.len > 0
		assert have == want, name
	}
	// a CLI's `extract` hands over to the extractor built with it, so the manifest names
	// the binary that extracted, and not to one built with another CLI
	extractor := os.join_path(dir, extractor_name)
	pair := extractor + extractor_pair_suffix
	os.cp(unmapping, extractor) or { panic(err) }
	os.write_file(pair, file_hash(gc)) or { panic(err) }
	handed := os.join_path(dir, 'handed_out')
	over := os.exec([gc, 'extract', @DIR, '--out', handed])
	assert over.exit_code == 0, over.output
	assert over.output.contains('[trace_prealloc]'), over.output
	m := load_manifest(os.join_path(handed, 'manifest.json')) or { panic(err) }
	assert m.binary_hash == file_hash(extractor)
	gc_graph := os.read_file(os.join_path(dir, 'gc_out', 'graph.json')) or { panic(err) }
	assert os.read_file(os.join_path(handed, 'graph.json')) or { panic(err) } == gc_graph
	os.write_file(pair, 'the hash of another CLI') or { panic(err) }
	kept := os.join_path(dir, 'kept_out')
	own := os.exec([gc, 'extract', @DIR, '--out', kept])
	assert own.exit_code == 0, own.output
	assert !own.output.contains('[trace_prealloc]'), own.output
	// nor when asked not to
	os.write_file(pair, file_hash(gc)) or { panic(err) }
	os.setenv(no_extractor_env, '1', true)
	opted := os.exec([gc, 'extract', @DIR, '--out', os.join_path(dir, 'opted_out')])
	os.unsetenv(no_extractor_env)
	assert opted.exit_code == 0, opted.output
	assert !opted.output.contains('[trace_prealloc]'), opted.output
	km := load_manifest(os.join_path(kept, 'manifest.json')) or { panic(err) }
	assert km.binary_hash == file_hash(gc)
}

fn test_freeing_an_arena_hands_its_memory_back() {
	$if prealloc {
		$if !prealloc_no_recycle ? {
			$if !windows {
				// arenas held open empty the pool of blocks that earlier tests freed (it
				// has 256 slots), so the only block the next arena can start in is a
				// freed one, not a new one
				mut held := unsafe { [300]voidptr{} }
				for i in 0 .. held.len {
					held[i] = arena_begin()
				}
				a := arena_begin()
				a_lo, a_hi := unsafe { prealloc_scope_address_range(a) }
				arena_leave(a)
				arena_free(a)
				b := arena_begin()
				b_lo, b_hi := unsafe { prealloc_scope_address_range(b) }
				arena_leave(b)
				arena_free(b)
				for i := held.len - 1; i >= 0; i-- {
					arena_leave(held[i])
					arena_free(held[i])
				}
				assert b_lo < a_hi && a_lo < b_hi
			}
		}
	}
}

// a generic function called by another generic function, `up[T]` passing its `db` on to
// `ensure_journal[T]`: the instance is a type of a test file, which only that file sees, and
// the method on it is the one the call reaches, though `execute` names another method too
fn test_a_generic_call_reaches_a_method_of_a_test_only_instance_through_a_generic_caller() {
	g := graph_of({
		'lib/migration/migration.v':      'module migration

pub fn up[T](mut db T) ! {
	ensure_journal(mut db)!
}

fn ensure_journal[T](mut db T) ! {
	db.execute(\'CREATE\')!
}
'
		'lib/migration/migration_test.v': 'module migration

struct FakeDB {}

fn (mut db FakeDB) execute(query string) ! {
}

fn test_up() {
	mut db := FakeDB{}
	up(mut db) or {}
}
'
		'lib/other/other.v':              'module other

pub struct Store {}

pub fn (s Store) execute(query string) ! {
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.migration.ensure_journal').map(it.to)
	assert 'lib.migration.FakeDB.execute' in calls, calls.str()
	assert 'lib.other.Store.execute' !in calls, calls.str()
}

// `rand.element(app.commands)`: a generic function's result has the element type of the
// array its argument has, so the call on the result is the one on that element's type
fn test_a_generic_call_result_takes_the_element_type_of_its_argument() {
	g := graph_of({
		'lib/rand/rand.v':  'module rand

pub fn element[T](array []T) !T {
	return array[0]
}
'
		'lib/cli/cli.v':    'module cli

type FnCommandCallback = fn (cmd Command) !

pub struct Command {
pub:
	name     string
	commands []Command
	execute  FnCommandCallback = unsafe { nil }
}
'
		'lib/other/other.v': 'module other

pub struct Task {}

pub fn (t Task) execute(args []string) ! {
}
'
		'lib/app/app.v':    'module app

import rand
import cli

pub fn run() {
	mut app := cli.Command{
		commands: [cli.Command{
			name: \'solve\'
		}]
	}
	if rcmd := rand.element(app.commands) {
		rcmd.execute(rcmd) or {}
	}
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run').map(it.to)
	assert 'lib.cli.Command.execute' in calls, calls.str()
	assert 'lib.other.Task.execute' !in calls, calls.str()
}

// `$if T.unaliased_typ is string` and `$map` in vlib's drop_owned, which only the compiler
// instantiates, so the tree shows no instance: `owned.free()` under each is the free of the type
// the check names, string's and map's, though `Buf` in builtin declares `free` too. The last
// `$else` compiles for none of the types the checks name, so its `drop` is not OwnershipDrop's
fn test_drop_owned_calls_are_typed_by_the_comptime_checks_around_them() {
	g := graph_of({
		'lib/builtin/ownership_notd_ownership.v':  'module builtin

fn drop_owned_map_key[K](key K) {
	drop_owned(key)
}

@[manualfree]
pub fn drop_owned[T](value T) {
	mut owned := value
	$if T.unaliased_typ is $interface {
		drop_owned_interface(owned)
	} $else $if T is OwnershipDrop {
		owned.drop()
	} $else $if T.unaliased_typ is string {
		unsafe { owned.free() }
	} $else $if T.unaliased_typ is $map {
		for key, item in owned {
			drop_owned_map_key(key)
			drop_owned(item)
		}
		unsafe { owned.free() }
	} $else $if T.unaliased_typ is $struct {
		$for field in T.fields {
			drop_owned(owned.$(field.name))
		}
	} $else {
		owned.drop()
	}
}
'
		'lib/builtin/ownership_interface_notd_v3_backend.v': 'module builtin

interface OwnershipDrop {
mut:
	drop()
}
'
		'lib/builtin/string.v':                   'module builtin

pub fn (s string) free() {
}
'
		'lib/builtin/map.v':                      'module builtin

pub struct map {}

pub fn (m &map) free() {
}
'
		'lib/builtin/buf.v':                      'module builtin

pub struct Buf {}

pub fn (b Buf) free() {
}

pub fn (b Buf) drop() {
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.builtin.drop_owned')
	targets := calls.map(it.to)
	assert 'lib.builtin.string.free' in targets, targets.str()
	assert 'lib.builtin.map.free' in targets, targets.str()
	assert 'lib.builtin.Buf.free' !in targets, targets.str()
	assert 'lib.builtin.Buf.drop' !in targets, targets.str()
	last := calls.filter(27 in it.lines).map(it.to)
	assert last == ['drop'], last.str()
}

// a generic struct instantiated from another module, `codec.Store[codec.Paper]{}`: `first()` of
// its instance has the type argument, so the call on the result is `Paper`'s, not that of
// `Board`, which declares `describe` too
fn test_a_generic_struct_instantiated_from_another_module_types_its_method_result() {
	g := graph_of({
		'lib/codec/codec.v': 'module codec

pub struct Paper {}

pub fn (p Paper) describe() string {
	return \'\'
}

pub struct Board {}

pub fn (b Board) describe() string {
	return \'\'
}

pub struct Store[T] {
pub mut:
	items []T
}

pub fn (s &Store[T]) first() T {
	return s.items[0]
}
'
		'lib/other/other.v': 'module other

pub struct Shelf {}

pub fn (s Shelf) first() int {
	return 0
}
'
		'app/app.v':         'module app

import codec

pub fn run() string {
	s := codec.Store[codec.Paper]{}
	p := s.first()
	return p.describe()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.run').map(it.to)
	assert 'lib.codec.Paper.describe' in calls, calls.str()
	assert 'lib.codec.Board.describe' !in calls, calls.str()
}

// the implicit `ctx` of a veb route method: V gives a method that returns `veb.Result` a
// `mut ctx Context` parameter of its module's own `Context`, wherever the App's middleware and
// `veb.run` are written, so `ctx.json()` in routes.v reaches the json that Context embeds
fn test_a_veb_route_method_has_its_modules_context_as_its_implicit_ctx() {
	g := graph_of({
		'lib/veb/veb.v':     'module veb

pub struct Result {}

pub struct Context {
pub mut:
	ok bool
}

pub fn (mut ctx Context) json(s string) Result {
	return Result{}
}

pub struct Middleware[T] {
}

pub fn run[A, X](mut app A, port int) {
}
'
		'lib/other/other.v': 'module other

pub struct Form {}

pub fn (f Form) json(s string) {
}
'
		'app/main.v':        'module main

import veb

pub struct Context {
	veb.Context
}

pub struct App {
	veb.Middleware[Context]
}

fn main() {
	mut app := &App{}
	veb.run[App, Context](mut app, 8082)
}
'
		'app/routes.v':      'module main

import veb
import other

pub fn (app &App) index() veb.Result {
	return ctx.json(\'x\')
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'app.App.index').map(it.to)
	assert 'lib.veb.Context.json' in calls, calls.str()
	assert 'lib.other.Form.json' !in calls, calls.str()
}

// V declares the implicit `ctx` only in a veb route method, one that returns `veb.Result` on a
// receiver other than `Context` and has no `Context` parameter: there it shadows a module's
// `__global ctx`, and in any other method `ctx` is that global
fn test_only_a_veb_route_method_has_an_implicit_ctx() {
	g := graph_of({
		'lib/veb/veb.v':     'module veb

pub struct Result {}

pub struct Context {
pub mut:
	ok bool
}

pub fn (mut ctx Context) json(s string) Result {
	return Result{}
}

pub struct Middleware[T] {
}
'
		'lib/other/other.v': 'module other

pub struct Form {}

pub fn (f Form) json(s string) {
}
'
		'app/app.v':         'module main

import veb
import other

__global ctx other.Form

pub struct Context {
	veb.Context
}

pub struct App {
	veb.Middleware[Context]
}

pub fn (app &App) index() veb.Result {
	return ctx.json(\'x\')
}

pub fn (app &App) helper() {
	ctx.json(\'x\')
}

pub fn (mut c Context) page() veb.Result {
	ctx.json(\'x\')
	return veb.Result{}
}

pub fn (app &App) form(mut c Context) veb.Result {
	ctx.json(\'x\')
	return veb.Result{}
}
'
	})
	route := g.edges.filter(it.kind == .calls && it.from == 'app.App.index').map(it.to)
	assert 'lib.veb.Context.json' in route, route.str()
	assert 'lib.other.Form.json' !in route, route.str()
	for from in ['app.App.helper', 'app.Context.page', 'app.App.form'] {
		calls := g.edges.filter(it.kind == .calls && it.from == from).map(it.to)
		assert 'lib.other.Form.json' in calls, '${from}: ${calls}'
		assert 'lib.veb.Context.json' !in calls, '${from}: ${calls}'
	}
}

// `x, y := pick(names), pick(nums)` on one line: the two calls to `pick` merge into one call
// edge with two argument sites, and `y` must still take the element type of `nums`, not of
// `names`, so `y.show()` is Num's method
fn test_two_generic_calls_on_one_line_each_take_their_own_argument_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub fn pick[T](xs []T) T {
	return xs[0]
}

pub fn run(names []Command, nums []Num) {
	x, y := pick(names), pick(nums)
	x.show()
	y.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run').map(it.to)
	assert 'lib.app.Num.show' in calls, calls.str()
	assert 'lib.app.Command.show' in calls, calls.str()
}

// the same generic callee on two lines of one function: its two calls merge into one call edge
// spanning both lines, and each result must still take the element type of its own argument
fn test_one_generic_callee_on_two_lines_types_each_call_by_its_own_argument() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub fn pick[T](xs []T) T {
	return xs[0]
}

pub fn run(names []Command, nums []Num) {
	x := pick(names)
	x.show()
	y := pick(nums)
	y.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run').map(it.to)
	assert 'lib.app.Num.show' in calls, calls.str()
	assert 'lib.app.Command.show' in calls, calls.str()
}


// two test files of one directory, each its own program with its own `Calc[S]`, `TypeA` and
// `TypeB`, as vlib/v/tests/generics has: the generic method of one test file reaches the methods
// of the types that file declares, never those of the other test file, which it can't see
fn test_a_generic_method_in_a_test_file_reaches_only_its_own_files_types() {
	src := 'module main

struct Calc[S] {
mut:
	typ S
}

struct TypeA {}

struct TypeB {}

fn (mut c Calc[S]) next[T](input T) f64 {
	$if S is TypeA || S is TypeB {
		return c.typ.next(input)
	} $else {
		return 99.0
	}
}

fn (mut t TypeA) next[T](input T) f64 {
	return 10.0
}

fn (mut t TypeB) next[T](input T) f64 {
	return 11.0
}

fn test_calc() {
	mut a := Calc[TypeA]{
		typ: TypeA{}
	}
	assert a.next(100) == 10.0
	mut b := Calc[TypeB]{
		typ: TypeB{}
	}
	assert b.next(100) == 11.0
}
'
	root := write_tree('generic_method_per_test_file', {
		'gen/a_test.v': src
		'gen/b_test.v': src
	})
	g := build_graph(Options{ root: root })
	for own in ['gen/a_test.v', 'gen/b_test.v'] {
		calls := g.edges.filter(it.kind == .calls && it.from == 'gen.Calc[S].next@' + own).map(it.to)
		assert 'gen.TypeA.next@' + own in calls, '${own}: ${calls}'
		assert 'gen.TypeB.next@' + own in calls, '${own}: ${calls}'
		assert calls.all(!it.starts_with('gen.Type') || it.ends_with('@' + own)), '${own}: ${calls}'
	}
}

// `$if c { a } $else { b }` as a value, where `a` and `b` each hold the result of a call of one
// function: the two calls are different call sites, but the branches still have one type, so
// the value has it
fn test_a_comptime_if_value_of_two_results_of_one_function_has_their_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Doc {}

pub fn (d Doc) show() {}

pub struct Other {}

pub fn (o Other) show() {}

fn make() Doc {
	return Doc{}
}

pub fn run() {
	a := make()
	b := make()
	y := $if linux {
		a
	} $else {
		b
	}
	y.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run').map(it.to)
	assert 'lib.app.Doc.show' in calls, calls.str()
	assert 'lib.app.Other.show' !in calls, calls.str()
}

// `$if T.unaliased_typ is Shower` where the tree instantiates T with Doc, which implements the
// interface: the call is Doc's own method, and the interface the check names adds no target
fn test_a_comptime_interface_check_keeps_its_instances_methods() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Shower {
	show()
}

pub struct Doc {}

pub fn (d Doc) show() {}

pub fn present[T](x T) {
	$if T.unaliased_typ is Shower {
		x.show()
	}
}

pub fn run() {
	present(Doc{})
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.present').map(it.to)
	assert 'lib.app.Doc.show' in calls, calls.str()
	assert 'lib.app.Shower.show' !in calls, calls.str()
}

// the `$else` of `$if T is Pen` in a generic function nothing calls compiles for types other than
// Pen: its call stands for no instance the tree shows, and the type the check names is not one.
// `keep(1)` instantiates another function, so the tree has instances to expand calls with
fn test_the_else_branch_of_a_comptime_type_check_does_not_take_its_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Box {}

pub fn (b Box) ink() {}

pub struct Pen {}

pub fn (p Pen) ink() {}

fn keep[T](x T) {}

pub fn use() {
	keep(1)
}

pub fn other[T](x T) {
	mut owned := x
	$if T is Pen {
		owned.ink()
	} $else {
		owned.ink()
	}
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.other')
	targets := calls.map(it.to)
	assert 'lib.app.Box.ink' !in targets, targets.str()
	// the `$if T is Pen` branch's call is Pen's, as the walk retypes `owned` there; the `$else`
	// one, on line 22, is no method the tree shows
	last := calls.filter(22 in it.lines).map(it.to)
	assert last == ['ink'], last.str()
}

// a generic call's result bound through `or { ... }` or `!`, which V3 reads as an or-expression
// around the call: it still takes the element type of the call's own argument
fn test_a_generic_result_bound_through_or_or_bang_takes_its_arguments_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub fn pick_opt[T](xs []T) ?T {
	return xs[0]
}

pub fn pick_res[T](xs []T) !T {
	return xs[0]
}

pub fn run(names []Command, nums []Num) ! {
	a := pick_opt(names) or { return }
	a.show()
	b := pick_res(nums)!
	b.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run')
	at := fn [calls] (line int) []string {
		return calls.filter(line in it.lines).map(it.to)
	}
	assert at(21) == ['lib.app.Command.show'], at(21).str()
	assert at(23) == ['lib.app.Num.show'], at(23).str()
}

// a variadic generic, `pick_any[T](xs ...T) T`: its result has the type of the arguments its
// `...T` parameter takes
fn test_a_variadic_generic_result_takes_its_arguments_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub fn pick_any[T](xs ...T) T {
	return xs[0]
}

pub fn run(c Command, n Num) {
	d := pick_any(c, c)
	d.show()
	e := pick_any(n)
	e.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run')
	at := fn [calls] (line int) []string {
		return calls.filter(line in it.lines).map(it.to)
	}
	assert at(17) == ['lib.app.Command.show'], at(17).str()
	assert at(19) == ['lib.app.Num.show'], at(19).str()
}

// `$if T.unaliased_typ is json.Any` after `import x.json2 as json`, in a generic function the
// tree instantiates with nothing: the type the check names is json2's `Any`, read through the
// import alias as the walk reads `$if T is json.Any`, so the call is Any's method
fn test_a_comptime_check_names_a_type_through_an_import_alias() {
	g := graph_of({
		'lib/x/json2/json2.v': 'module json2

pub struct Any {}

pub fn (a Any) show() {}
'
		'lib/other/other.v':   'module other

pub struct Other {}

pub fn (o Other) show() {}
'
		'lib/app/app.v':       'module app

import x.json2 as json
import other

fn keep[T](x T) {}

pub fn use() {
	keep(1)
}

pub fn present[T](x T) {
	mut v := x
	$if T.unaliased_typ is json.Any {
		v.show()
	}
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.present').map(it.to)
	assert 'lib.x.json2.Any.show' in calls, calls.str()
	assert 'lib.other.Other.show' !in calls, calls.str()
}

// a generic call's result bound in parentheses, `(pick(xs))` or `(pick_opt(xs) or { ... })`: the
// value is still the call's, so it takes the element type of the call's own argument
fn test_a_generic_result_bound_in_parentheses_takes_its_arguments_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub fn pick[T](xs []T) T {
	return xs[0]
}

pub fn pick_opt[T](xs []T) ?T {
	return xs[0]
}

pub fn run(names []Command, nums []Num) {
	a := (pick(names))
	a.show()
	b := (pick_opt(nums) or { return })
	b.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run')
	at := fn [calls] (line int) []string {
		return calls.filter(line in it.lines).map(it.to)
	}
	assert at(21) == ['lib.app.Command.show'], at(21).str()
	assert at(23) == ['lib.app.Num.show'], at(23).str()
}

// `y := id(x).tag()` and `tg := el.tag()` bind a method's result, not the generic call's: a call
// on y is still a chain from the type parameter's instances (chained_call_ids), which reads the
// method as the recipe's last step
fn test_a_bound_method_result_on_a_generic_call_stays_a_chain() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Far {}

pub fn (f Far) bytes() {}
'
		'lib/app/app.v':     'module app

import other

pub struct Beta {}

pub fn (b Beta) bytes() {}

pub struct Alpha {}

pub fn (a Alpha) tag() Beta {
	return Beta{}
}

pub struct Beta2 {}

pub fn (b Beta2) bytes() {}

pub struct Alpha2 {}

pub fn (a Alpha2) tag() Beta2 {
	return Beta2{}
}

fn id[T](x T) T {
	return x
}

fn make[T]() T {
	return T{}
}

fn via_id[T](x T) {
	y := id(x).tag()
	y.bytes()
}

fn via_make[T](x T) {
	y := make[T]().tag()
	y.bytes()
}

fn split[T](x T) {
	el := id(x)
	tg := el.tag()
	tg.bytes()
}

pub fn start() {
	via_id(Alpha{})
	via_make(Alpha{})
	split(Alpha{})
}
'
	})
	for from in ['via_id', 'via_make', 'split'] {
		calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.' + from).map(it.to)
		assert 'lib.app.Beta.bytes' in calls, '${from}: ${calls}'
		assert 'lib.app.Beta2.bytes' !in calls, '${from}: ${calls}'
	}
}

// `id2(id(n))`: the inner call's result is its own T, which isn't the caller's T even by that name,
// so the outer result must not become the caller's instances
fn test_a_nested_generic_call_does_not_take_the_callers_type_parameter() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

fn id[T](x T) T {
	return x
}

fn id2[U](x U) U {
	return x
}

fn nested[T](v T, n Num) {
	d := id2(id(n))
	d.show()
}

pub struct Box {}

pub fn (b Box) own[T](v T, n Num) {
	d := id2(id(n))
	d.show()
}

pub struct Holder[T] {}

pub fn (h Holder[T]) held(v T, n Num) {
	d := id2(id(n))
	d.show()
}

pub fn start() {
	nested(Command{}, Num{})
	b := Box{}
	b.own(Command{}, Num{})
	h := Holder[Command]{}
	h.held(Command{}, Num{})
}
'
	})
	for from in ['lib.app.nested', 'lib.app.Box.own', 'lib.app.Holder[T].held'] {
		calls := g.edges.filter(it.kind == .calls && it.from == from).map(it.to)
		assert 'lib.app.Command.show' !in calls, '${from}: ${calls}'
	}
}

// an untyped number gives T only if nothing else does, and a float before an int: `mix(0, b)` with
// `b u8` is a u8, `mix(1, 2.5)` an f64, also when the argument is past the one `...T` parameter
fn test_a_number_literal_argument_gives_way_to_a_typed_argument() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub fn (b u8) nudge() {}

pub fn (i int) nudge() {}

pub fn (f f64) nudge() {}

fn mix[T](a T, b T) T {
	return a
}

fn many[T](xs ...T) T {
	return xs[0]
}

pub fn typed(b u8) {
	x := mix(0, b)
	x.nudge()
}

pub fn float() {
	x := mix(1, 2.5)
	x.nudge()
}

pub fn spread(f f64) {
	x := many(0, f)
	x.nudge()
}

pub fn ints() {
	x := mix(1, 2)
	x.nudge()
}
'
	})
	for from, want in {
		'typed':  'lib.app.u8.nudge'
		'float':  'lib.app.f64.nudge'
		'spread': 'lib.app.f64.nudge'
		'ints':   'lib.app.int.nudge'
	} {
		calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.' + from && it.to.ends_with('nudge')).map(it.to)
		assert calls == [want], '${from}: ${calls}'
	}
}

// an argument a comptime check narrows gives the generic call's result the narrowed type: the
// call_args read settled recipes, as every other reader of an edge's arg_sites does
fn test_a_generic_result_takes_the_comptime_narrowed_type_of_its_argument() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Foo {}

pub fn (f Foo) go_on() {}

pub struct Bar {}

pub fn (b Bar) go_on() {}

fn id[T](x T) T {
	return x
}

fn id2[U](x U) U {
	return x
}

fn same_name[T](x T) {
	$if T is Foo {
		y := id(x)
		y.go_on()
	}
}

fn other_name[T](x T) {
	$if T is Foo {
		y := id2(x)
		y.go_on()
	}
}

pub fn start() {
	same_name(Bar{})
	other_name(Bar{})
}
'
	})
	for from in ['same_name', 'other_name'] {
		calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.' + from).map(it.to)
		assert 'lib.app.Foo.go_on' in calls, '${from}: ${calls}'
		assert 'lib.app.Bar.go_on' !in calls, '${from}: ${calls}'
	}
}

// a chain of generic results is followed only so far: generated code with thousands of them must
// neither overflow the stack nor take time that doubles with each one, and a short chain is typed
fn test_a_long_chain_of_generic_results_is_bounded() {
	head := ['module app', 'pub struct Alpha {}', 'pub fn (a Alpha) mm() {}', 'pub struct Beta {}',
		'pub fn (b Beta) mm() {}', 'fn id[T](x T) T {', '\treturn x', '}',
		'fn skip[T](x int, y T) T {', '\treturn y', '}', 'fn both[T](x T, y T) T {', '\treturn y', '}']
	mut deep := head.clone()
	deep << ['pub fn short() {', '\ta0 := id(Alpha{})', '\ta1 := id(a0)', '\ta2 := id(a1)', '\ta2.mm()',
		'}', 'pub fn deep() {', '\ta0 := Alpha{}']
	for i in 1 .. 8000 {
		deep << '\ta${i} := id(a${i - 1})'
	}
	deep << ['\ta7999.mm()', '}', '']
	g := graph_of({
		'lib/app/app.v': deep.join('\n')
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.short').map(it.to)
	assert 'lib.app.Alpha.mm' in calls, calls.str()

	mut doubling := head.clone()
	doubling << ['pub fn skipped() {', '\ta0 := Alpha{}']
	for i in 1 .. 21 {
		doubling << '\ta${i} := skip(a${i - 1}, a${i - 1})'
	}
	doubling << ['\ta20.mm()', '}', 'pub fn untyped() {', '\ta0 := unknown()']
	for i in 1 .. 21 {
		doubling << '\ta${i} := both(a${i - 1}, a${i - 1})'
	}
	doubling << ['\ta20.mm()', '}', '']
	sw := time.new_stopwatch()
	graph_of({
		'lib/app/app.v': doubling.join('\n')
	})
	assert sw.elapsed().milliseconds() < 5000
}

// a comptime check's stand-in doesn't depend on whether something else in the tree happens to
// instantiate a generic function
fn test_a_comptime_check_stands_in_when_the_tree_has_no_instance_at_all() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Foo {}

pub fn (f Foo) yy() {}

pub struct Bar {}

pub fn (b Bar) yy() {}

pub fn dec[T](v T) {
	$if T.unaliased_typ is Foo {
		v.yy()
	}
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.dec').map(it.to)
	assert calls == ['lib.app.Foo.yy'], calls.str()
}

// the implicit ctx is the module's own Context, not veb's, and V reads the types of a route's
// result and parameters through an import alias
fn test_an_implicit_ctx_reads_its_module_and_import_aliases() {
	g := graph_of({
		'lib/veb/veb.v':       "module veb

pub struct Context {}

pub fn (c Context) json() {}

pub struct Result {}
"
		'lib/other/other.v':   "module other

pub struct Form {}

pub fn (f Form) json() {}
"
		'lib/own/own.v':       "module own

import veb

pub struct Context {
	veb.Context
}

pub fn (c Context) json() {}

pub struct App {}

pub fn (app &App) index() veb.Result {
	ctx.json()
	return veb.Result{}
}
"
		'lib/aliased/app.v':   "module aliased

import veb as w

pub struct Context {
	w.Context
}

pub struct Form {}

pub fn (f Form) json() {}

pub struct App {}

pub fn (app &App) index() w.Result {
	ctx.json()
	return w.Result{}
}
"
		'lib/param/app.v':     "module param

import veb
import other

__global ctx other.Form

pub struct Context {
	veb.Context
}

pub struct App {}

pub fn (app &App) index(mut c veb.Context) veb.Result {
	ctx.json()
	return veb.Result{}
}
"
		'lib/aliasparam/app.v': "module aliasparam

import veb as w
import other

__global ctx other.Form

pub struct Context {
	w.Context
}

pub struct App {}

pub fn (app &App) index(mut c w.Context) w.Result {
	ctx.json()
	return w.Result{}
}
"
	})
	calls := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.from == from && it.to.ends_with('json')).map(it.to)
	}
	assert calls('lib.own.App.index') == ['lib.own.Context.json'], calls('lib.own.App.index').str()
	assert calls('lib.aliased.App.index') == ['lib.veb.Context.json'], calls('lib.aliased.App.index').str()
	assert calls('lib.param.App.index') == ['lib.other.Form.json'], calls('lib.param.App.index').str()
	assert calls('lib.aliasparam.App.index') == ['lib.other.Form.json'], calls('lib.aliasparam.App.index').str()
}

// a later method's type argument (`x.conv[Bar]()`) says nothing about the generic call that made
// its receiver, which still takes its argument's type
fn test_a_later_methods_type_argument_leaves_a_generic_call_typed_by_its_argument() {
	g := graph_of({
		'lib/other/other.v': 'module other

pub struct Far {}

pub fn (f Far) ping() {}
'
		'lib/app/app.v':     'module app

import other

pub struct Bar {}

pub fn (b Bar) ping() {}

pub struct Decoy {}

pub fn (d Decoy) ping() {}

pub struct Foo {}

pub fn (f Foo) conv[U]() U {
	return U{}
}

fn first[E](xs []E) E {
	return xs[0]
}

pub fn gated(v []Foo) {
	x := first(v)
	y := x.conv[Bar]()
	y.ping()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.gated').map(it.to)
	assert 'lib.app.Bar.ping' in calls, calls.str()
	assert 'lib.app.Decoy.ping' !in calls, calls.str()
}

// the result takes its type from the argument at the parameter the return type names, not from
// the first argument, and written type arguments win over any argument
fn test_a_generic_result_reads_the_argument_of_its_own_parameter() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

pub interface Shower {
	show()
}

fn second[A, B](a A, b B) B {
	return b
}

fn from_list[A, B](a A, bs []B) B {
	return bs[0]
}

fn conv[T](x T) T {
	return x
}

pub fn run_second(c Command, n Num) {
	s := second(c, n)
	s.show()
}

pub fn run_list(c Command, ns []Num) {
	s := from_list(c, ns)
	s.show()
}

pub fn run_explicit(n Num) {
	s := conv[Shower](n)
	s.show()
}
'
	})
	for from in ['run_second', 'run_list'] {
		calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.' + from).map(it.to)
		assert 'lib.app.Num.show' in calls, '${from}: ${calls}'
		assert 'lib.app.Command.show' !in calls, '${from}: ${calls}'
	}
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run_explicit').map(it.to)
	assert 'lib.app.Num.show' !in calls, calls.str()
}

// the type a test file declares has the methods the test sees through a field too, and through a
// loop over the fields, as it does for a direct call on the instance
fn test_a_test_only_instance_reaches_methods_through_its_fields() {
	g := graph_of({
		'lib/m/m.v':      'module m

pub fn up[T](x T) {
	x.inner.show()
}

pub fn over[T](x T) {
	$for field in T.fields {
		x.$(field.name).show()
	}
}
'
		'lib/m/m_test.v': 'module m

struct Tag {}

fn (t Tag) show() {}

struct Fake {
	inner Tag
}

fn test_up() {
	up(Fake{})
	over(Fake{})
}
'
		'lib/other/other.v': 'module other

pub struct Dq {}

pub fn (d Dq) show() {}
'
	})
	for from in ['up', 'over'] {
		calls := g.edges.filter(it.kind == .calls && it.from == 'lib.m.' + from).map(it.to)
		assert 'lib.m.Tag.show' in calls, '${from}: ${calls}'
		assert 'lib.other.Dq.show' !in calls, '${from}: ${calls}'
	}
}

// branches holding results of one generic function with different arguments have no one type, so
// the `$if` value takes neither branch's
fn test_a_comptime_if_value_of_one_generic_function_with_different_arguments_has_no_type() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Command {}

pub fn (c Command) show() {}

pub struct Num {}

pub fn (n Num) show() {}

fn pick[T](xs []T) T {
	return xs[0]
}

pub fn run(names []Command, nums []Num) {
	a := pick(names)
	b := pick(nums)
	y := $if linux {
		a
	} $else {
		b
	}
	y.show()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.run').map(it.to)
	assert 'lib.app.Command.show' !in calls, calls.str()
}

// the builtin declarations the tests of what V provides on a receiver reach
const provided_builtin = 'module builtin

pub struct array {}

pub fn (a &array) clone() array {
	return a
}

pub fn (a &array) map(x voidptr) array {
	return a
}

pub struct map {}

pub fn (m &map) keys() array {
	return array{}
}

pub fn (m &map) clone() map {
	return m
}

pub fn (s string) contains(x string) bool {
	return true
}

pub fn (s string) trim_space() string {
	return s
}

pub struct FunctionData {
pub:
	name  string
	attrs []string
}

pub struct VariantData {
pub:
	typ int
}

pub struct EnumData {
pub:
	name string
}

pub struct FunctionParam {
pub:
	name string
}

pub struct VAttribute {
pub:
	name string
}

pub struct FieldData {
pub:
	name string
}
'

// provided_calls are the calls of `name` out of the function `from`, by what they reach: a
// bare name that stays unresolved, or a symbol's id
fn provided_calls(g Graph, from string, name string) []string {
	return g.edges.filter(it.kind == .calls && it.from == 'lib.app.' + from
		&& it.to.all_after_last('.') == name).map('${it.to}:${it.provenance}')
}

fn test_a_map_literal_without_stated_types_has_the_methods_of_a_map() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          "module app

// a decoy: a call that names no type must not reach it
pub struct Other {}

pub fn (o Other) keys() {}

pub fn (o Other) clone() {}

pub fn by_variable_key(k int) {
	m := {
		k: 1
	}
	m.keys()
	m.clone()
}

pub fn by_call_key() {
	m := {
		'a'.trim_space(): 1
	}
	m.keys()
}

pub fn spread(base map[string]int) {
	m := {
		...base
	}
	n := {
		...m
		'b': 2
	}
	n.keys()
}

pub struct Item {}

pub fn (i Item) ping() {}

pub fn (o Other) ping() {}

// a spread keeps the value type of the map it copies, which no bare map has
pub fn spread_value(base map[string]Item) {
	m := {
		...base
	}
	m['a'].ping()
}
"
	})
	assert provided_calls(g, 'spread_value', 'ping') == ['lib.app.Item.ping:inferred']
	for from, want in {
		'by_variable_key': ['vlib.builtin.map.keys:inferred']
		'by_call_key':     ['vlib.builtin.map.keys:inferred']
		'spread':          ['vlib.builtin.map.keys:inferred']
	} {
		assert provided_calls(g, from, 'keys') == want, from
	}
	assert provided_calls(g, 'by_variable_key', 'clone') == ['vlib.builtin.map.clone:inferred']
}

fn test_a_match_branch_on_a_map_type_has_the_methods_of_a_map() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Other {}

pub fn (o Other) keys() {}

pub type Table = int | map[string]int

pub type Value = int | map[string]Value

pub fn smartcast(t Table) {
	match t {
		map[string]int { t.keys() }
		else {}
	}
}

pub struct Variant {}

pub type Sum = Variant | int | map[string]Sum

pub fn (s Sum) str() string {
	return ""
}

pub fn (s Sum) only_sum() {}

pub fn (o Other) only_sum() {}

pub fn (o Other) str() string {
	return ""
}

pub fn variant_str(s Sum) {
	if s is Variant {
		s.str()
		s.only_sum()
	}
}

// on a sum type that declares str(), the map in a branch has the str() V writes for a map, and the
// `else` keeps the sum type (as the output of such a program shows)
pub fn sum_str(s Sum) {
	match s {
		map[string]Sum { s.str() }
		else {}
	}
}

pub fn sum_else(s Sum) {
	match s {
		map[string]Sum {}
		else { s.str() }
	}
}

// a value read out of the narrowed map has the map value type, a sum type, which has the
// type_name() V writes
pub fn elements(t Value) {
	match t {
		map[string]Value {
			for _, v in t {
				match v {
					int {}
					else { v.type_name() }
				}
			}
		}
		else {}
	}
}
'
	})
	assert provided_calls(g, 'smartcast', 'keys') == ['vlib.builtin.map.keys:inferred']
	assert provided_calls(g, 'elements', 'type_name') == ['type_name:undeclared']
	assert provided_calls(g, 'sum_str', 'str') == ['str:undeclared']
	assert provided_calls(g, 'variant_str', 'str') == ['str:undeclared']
	assert provided_calls(g, 'variant_str', 'only_sum') == ['lib.app.Sum.only_sum:inferred']
	assert provided_calls(g, 'sum_else', 'str') == ['lib.app.Sum.str:extracted']
}

fn test_a_select_receive_variable_has_the_type_of_the_channel_element() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Other {}

pub fn (o Other) clone() {}

pub fn (o Other) str() string {
	return ""
}

pub fn receive(ch chan []string) {
	select {
		value := <-ch {
			value.clone()
		}
	}
}

// the branch that sends has no such variable, and `value` after the select is the outer one
pub fn outer(ch chan []string, value Other) {
	select {
		got := <-ch {
			got.clone()
		}
	}
	value.clone()
}

pub fn select_is_a_bool(ch chan int) {
	ok := select {
		_ := <-ch {}
	}
	ok.str()
}

pub fn channel_str() {
	ch := chan int{cap: 1}
	ch.str()
}
'
	})
	assert provided_calls(g, 'receive', 'clone') == ['vlib.builtin.array.clone:inferred']
	assert provided_calls(g, 'outer', 'clone').sorted() == ['lib.app.Other.clone:extracted',
		'vlib.builtin.array.clone:inferred'].sorted()
	assert provided_calls(g, 'channel_str', 'str') == ['str:undeclared']
	assert provided_calls(g, 'select_is_a_bool', 'str') == ['str:undeclared']
}

fn test_a_comptime_loop_variable_has_the_builtin_type_of_what_it_walks() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          "module app

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return false
}

pub struct Routes {}

pub struct Custom {
pub:
	flag string
}

pub fn methods() {
	\$for method in Routes.methods {
		method.attrs.contains('x')
		method.attrs[0].contains('y')
		method.name.contains('z')
	}
}

pub enum Colour {
	red
}

pub fn values() {
	\$for v in Colour.values {
		v.name.contains('x')
	}
}

pub fn params() {
	\$for m in Routes.methods {
		\$for p in m.params {
			p.name.contains('x')
		}
	}
}

pub fn attributes() {
	\$for attr in Routes.attributes {
		\$if attr is Custom {
			attr.flag.contains('x')
		}
	}
}
"
	})
	calls := provided_calls(g, 'methods', 'contains')
	// method.attrs.contains is V's on an array, the two others string's
	assert calls.sorted() == ['contains:undeclared', 'vlib.builtin.string.contains:inferred'].sorted(), calls.str()
	assert provided_calls(g, 'attributes', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'values', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'params', 'contains') == ['vlib.builtin.string.contains:inferred']
}

fn test_a_map_of_a_field_is_an_array_of_the_field() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          "module app

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return false
}

pub struct Diag {
pub:
	message string
	inner   Other
}

pub fn diags() []Diag {
	return []
}

pub fn messages() {
	m := diags().map(it.message)
	m.any(it.contains('x'))
}

pub fn deep() {
	m := diags().map(it.inner)
	m[0].contains('x')
}

// a field of the element's field
pub struct Outer {
pub:
	diag Diag
}

pub fn path(xs []Outer) {
	m := xs.map(it.diag.inner)
	m[0].contains('x')
}

// the first field alone would be a Diag, which has one of its own
pub fn (d Diag) contains(x string) bool {
	return false
}

// a selector on anything but `it` says nothing of the elements: `h.message` is no field of a Diag
pub struct Holder {
pub:
	message Other
}

pub fn other_root(h Holder) {
	m := diags().map(h.message)
	m[0].contains('x')
}

// a method named map on a type of the program is no array's: its declared result stands
pub struct Stream {}

pub fn (s Stream) map(n string) Stream {
	return s
}

pub fn (s Stream) run() {}

pub fn (o Other) run() {}

pub fn user_map(s Stream, c Diag) {
	s.map(c.message).run()
}

pub fn user_map_it(s Stream, it Diag) {
	s.map(it.message).run()
}

// an element typed T has no field this can read: the result is still an array
pub fn of_param[T](xs []T) {
	xs.map(it.name).first()
}

// a selector with no recipe (a C name) leaves the result an array of an unknown element, on
// which V's own array methods are still known
pub fn host_value() {
	m := diags().map(C.FLAG)
	m.first()
}

pub fn (o Other) first() {}
"
	})
	assert provided_calls(g, 'path', 'contains') == ['lib.app.Other.contains:inferred']
	assert provided_calls(g, 'other_root', 'contains') == ['contains:extracted']
	assert provided_calls(g, 'user_map', 'run') == ['lib.app.Stream.run:inferred']
	assert provided_calls(g, 'user_map_it', 'run') == ['lib.app.Stream.run:inferred']
	assert provided_calls(g, 'of_param', 'first') == ['first:undeclared']
	assert provided_calls(g, 'host_value', 'first') == ['first:undeclared']
	assert provided_calls(g, 'messages', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'deep', 'contains') == ['lib.app.Other.contains:inferred']
}

fn test_a_call_of_a_function_literal_has_its_written_result() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          "module app

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return false
}

pub struct Inputs {
pub:
	unknown string
}

pub fn invoked() {
	x := fn () string {
		return ''
	}().trim_space()
	x.contains('y')
}

pub fn held() {
	make := fn () Inputs {
		return Inputs{}
	}
	got := make()
	got.unknown.contains('y')
}

// a literal with no result gives nothing to call a method on
pub fn no_result() {
	run := fn () {}
	run()
}
"
	})
	assert provided_calls(g, 'invoked', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'held', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'no_result', 'run') == ['run:undeclared']
}

fn test_a_kind_check_on_a_variable_gives_it_that_builtin_type() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Other {}

pub fn (o Other) clone() {}

pub fn merge[K, V](m map[K]V) {
	for _, v in m {
		\$if v is \$map {
			v.clone()
		} \$else \$if v is \$array {
			v.clone()
		}
	}
}

pub fn use_merge() {
	merge({
		"a": 1
	})
}

// a variable typed T keeps T, so an alias of a map has its own method
pub type Own = map[string]int

pub fn (o Own) tag() {}

pub fn (o Other) tag() {}

pub fn on_param[T](v T) {
	\$if v is \$map {
		v.tag()
	}
}

// a type the variable has is kept: an alias with its own method, and elements
pub fn (o Own) clone() Own {
	return o
}

pub fn on_param_clone[T](v T) {
	\$if v is \$map {
		v.clone()
	}
}

pub fn use_on_param_clone() {
	on_param_clone(Own({
		"a": 1
	}))
}

pub fn alias_param(v Own) {
	\$if v is \$map {
		v.clone()
	}
}

pub struct Foo {}

pub fn (f Foo) bar() {}

pub fn (o Other) bar() {}

pub fn elements_of_map(v map[string]Foo) {
	\$if v is \$map {
		v["a"].bar()
	}
}

pub fn elements_of_array(v []Foo) {
	\$if v is \$array {
		v[0].bar()
	}
}

// the kind holds in its own block only
pub fn in_else[K, V](m map[K]V) {
	for _, v in m {
		\$if v is \$map {
		} \$else {
			v.clone()
		}
	}
}

pub fn use_on_param() {
	on_param(Own({
		"a": 1
	}))
}
'
	})
	assert provided_calls(g, 'merge', 'clone').sorted() == ['vlib.builtin.array.clone:inferred',
		'vlib.builtin.map.clone:inferred'].sorted()
	assert provided_calls(g, 'on_param', 'tag') == ['lib.app.Own.tag:inferred']
	assert provided_calls(g, 'alias_param', 'clone')[0].starts_with('lib.app.Own.clone')
	assert provided_calls(g, 'on_param_clone', 'clone') == ['lib.app.Own.clone:inferred']
	assert provided_calls(g, 'elements_of_map', 'bar') == ['lib.app.Foo.bar:inferred']
	assert provided_calls(g, 'elements_of_array', 'bar') == ['lib.app.Foo.bar:inferred']
	assert !provided_calls(g, 'in_else', 'clone').any(it.starts_with('vlib.builtin.'))
}

// no generic call at all in the tree: nothing says V writes it
fn test_a_method_v_writes_on_a_type_parameter_with_no_instance_in_the_tree_stays_unresolved() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct A {}

pub fn (a A) str() string {
	return ""
}

pub struct B {}

pub fn (b B) str() string {
	return ""
}

pub fn alone[T](v T) {
	v.str()
}
'
	})
	assert provided_calls(g, 'alone', 'str') == ['str:extracted']
}

// a nested literal that states no types doesn't hide the type a later entry states, and a bare
// map's keys are an array of an element not known, not the voidptr builtin's first() declares
fn test_a_bare_map_gives_way_to_a_stated_type_and_has_no_element() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin + '
pub fn (a &array) first() voidptr {
	return unsafe { nil }
}

pub fn (v voidptr) str() string {
	return ""
}
'
		'lib/app/app.v':          "module app

pub struct Foo {}

pub fn (f Foo) ok() {}

pub struct Other {}

pub fn (o Other) ok() {}

pub fn (o Other) str() string {
	return ''
}

pub fn nested(k string) {
	m := {
		'a': {
			k: Foo{}
		}
		'b': {
			'x': Foo{}
		}
	}
	m['b']['x'].ok()
}

pub fn chained(k string) {
	x := {
		k: 1
	}
	ks := x.keys()
	ks.first().str()
}

pub fn (o Other) keys() {}

// only bare maps inside: the outer value is still a map
pub fn only_bare(k string) {
	m := {
		'a': {
			k: 1
		}
	}
	m['a'].keys()
}
"
	})
	assert provided_calls(g, 'only_bare', 'keys') == ['vlib.builtin.map.keys:inferred']
	assert provided_calls(g, 'nested', 'ok') == ['lib.app.Foo.ok:inferred']
	assert !provided_calls(g, 'chained', 'str').any(it.contains('voidptr'))
}

// the result of a function type is what follows its parameter list
fn test_a_function_literal_returning_a_function_or_several_values() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Foo {}

pub fn (f Foo) ok() {}

pub struct Other {}

pub fn (o Other) ok() {}

pub fn makes_a_function() {
	f := fn () fn () Foo {
		return fn () Foo {
			return Foo{}
		}
	}
	g := f()
	g.ok()
}

pub fn makes_two() {
	f := fn () (int, Foo) {
		return 1, Foo{}
	}
	_, b := f()
	b.ok()
}
'
	})
	assert !provided_calls(g, 'makes_a_function', 'ok').any(it.starts_with('lib.app.Foo'))
	assert provided_calls(g, 'makes_two', 'ok') == ['lib.app.Foo.ok:inferred']
	assert fn_return('fn () fn () Foo') or { '' } == 'fn () Foo'
	assert fn_return('fn (x fn () int) Foo') or { '' } == 'Foo'
	assert fn_return('fn () (int, Foo)') or { '' } == '(int, Foo)'
	assert (fn_return('fn (x int)') or { 'none' }) == 'none'
}

// a literal whose entries state no type has no key type either: `k` is not an int
fn test_a_map_literal_without_stated_types_gives_its_key_no_type() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin + '
pub fn (i int) str() string {
	return ""
}
'
		'lib/app/app.v':          'module app

pub struct Other {}

pub fn (o Other) str() string {
	return ""
}

pub fn keys_of(key Other) {
	m := {
		key: 1
	}
	for k, _ in m {
		k.str()
	}
}
'
	})
	// the only other `str` in sight is int's, which typing the key as an int would pick
	assert provided_calls(g, 'keys_of', 'str') == ['lib.app.Other.str:inferred']
}

// a variable that shares a name with the type a check names does not stop the narrowing: only a
// variants loop's does. `$if x is v` on one narrows nothing either
fn test_a_type_check_is_ignored_only_for_a_variants_loop_variable() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Foo {}

pub fn (f Foo) ping() {}

pub struct Other {}

pub fn (o Other) ping() {}

pub type Sum = Foo | int

pub fn same_name(x Sum, Foo int) {
	if x is Foo {
		x.ping()
	}
}

pub fn comptime_variant[T](val T) {
	\$for v in T.variants {
		\$if val is v {
			val.str()
		}
	}
}

pub struct NoStr {}

pub fn use_variant() {
	comptime_variant(NoStr{})
}

pub fn (o Other) str() string {
	return ""
}

pub fn (f Foo) str() string {
	return ""
}
'
	})
	assert provided_calls(g, 'same_name', 'ping') == ['lib.app.Foo.ping:inferred']
	assert provided_calls(g, 'comptime_variant', 'str') == ['str:undeclared']
}

// V writes str() for any type, and type_name() for a sum type, so one on a type parameter that
// no instance declares has no declaration; any other method stays unresolved, and an instance
// that declares it is linked
fn test_a_method_v_writes_on_a_type_parameter_is_undeclared() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Plain {}

pub struct Named {}

pub fn (n Named) str() string {
	return ""
}

pub fn (n Named) type_name() string {
	return ""
}

// decoys: with one method of a name a call would link to it by the name alone
pub struct Other {}

pub fn (o Other) str() string {
	return ""
}

pub fn (o Other) type_name() string {
	return ""
}

pub fn no_instance[T](v T) {
	v.str()
	v.type_name()
	v.type_idx()
	v.missing()
}

pub fn plain_instance[T](v T) {
	v.str()
	v.missing()
}

pub fn named_instance[T](v T) {
	v.str()
	v.type_name()
}

pub fn elements[T](vs []T) {
	_ := vs.map(it.str())
}

pub type Dyn = Plain | Named

pub fn dynamic[T](v T) {
	v.type_name()
	v.type_idx()
}

// one call site gives a type this can read and one gives none: the second may be a type that
// declares str(), so nothing can be said
pub fn id_of[T](x T) T {
	return x
}

pub fn partly_known[T](v T) {
	v.str()
}

// the same through a parameter passed on
pub fn outer[T](v T) {
	inner(v)
}

pub fn inner[T](v T) {
	v.str()
}

// a parameter no type is collected from: the tree does pass one, here a Named
pub fn by_map[K, V](m map[K]V) {
	for _, v in m {
		v.str()
	}
}

pub fn variant[T](val T) {
	\$for v in T.variants {
		if val is v {
			val.str()
		}
	}
}

pub fn use() {
	plain_instance(Plain{})
	named_instance(Named{})
	elements([Plain{}])
	variant(Plain{})
	dynamic(Dyn(Plain{}))
	partly_known(Plain{})
	partly_known(id_of(Named{}))
	outer(Plain{})
	outer(id_of(Named{}))
	by_map({
		"a": Named{}
	})
}
'
	})
	// no instance known: a type that declares it may still be given, by an argument this can't read
	assert provided_calls(g, 'no_instance', 'str') == ['str:extracted']
	assert provided_calls(g, 'no_instance', 'type_name') == ['type_name:extracted']
	// but no type here declares this one, so whichever instance compiles has it from V
	assert provided_calls(g, 'no_instance', 'type_idx') == ['type_idx:undeclared']
	assert provided_calls(g, 'dynamic', 'type_name') == ['type_name:undeclared']
	assert provided_calls(g, 'dynamic', 'type_idx') == ['type_idx:undeclared']
	assert provided_calls(g, 'partly_known', 'str') == ['str:extracted']
	assert provided_calls(g, 'inner', 'str') == ['str:extracted']
	assert provided_calls(g, 'by_map', 'str') == ['str:extracted']
	assert provided_calls(g, 'no_instance', 'missing') == ['missing:extracted']
	assert provided_calls(g, 'plain_instance', 'str') == ['str:undeclared']
	assert provided_calls(g, 'plain_instance', 'missing') == ['missing:extracted']
	assert provided_calls(g, 'named_instance', 'str') == ['lib.app.Named.str:inferred']
	assert provided_calls(g, 'named_instance', 'type_name') == ['lib.app.Named.type_name:inferred']
	assert provided_calls(g, 'elements', 'str') == ['str:undeclared']
	assert provided_calls(g, 'variant', 'str') == ['str:undeclared']
}

// the method of `$if T is Iface` is each instance's that answers it, read wherever the instance is
// declared; with no instance that answers, the interface's own, as on a value of that type
fn test_an_interface_check_on_a_type_parameter_is_its_instances_then_the_interface() {
	g := graph_of({
		'lib/app/app.v':     'module app

import lib.far
import lib.far as farr
import lib.far { Reaches }

pub interface Dropper {
mut:
	dropit()
}

pub struct Owner {}

pub fn (mut o Owner) dropit() {}

// a decoy: it has the name, and no call gives its type
pub struct Decoy {}

pub fn (mut d Decoy) dropit() {}

pub struct Silent {}

pub fn by_type_known[T](v T) {
	mut c := v
	\$if T is Dropper {
		c.dropit()
	}
}

pub fn by_type_unknown[T](v T) {
	mut c := v
	\$if T is Dropper {
		c.dropit()
	}
}

pub fn by_type_silent[T](v T) {
	mut c := v
	\$if T is Dropper {
		c.dropit()
	}
}

pub fn by_var_known[T](v T) {
	\$if v is Dropper {
		mut c := v
		c.dropit()
	}
}

pub fn by_var_unknown[T](v T) {
	\$if v is Dropper {
		mut c := v
		c.dropit()
	}
}

pub fn by_mut_known[T](mut v T) {
	\$if v is Dropper {
		v.dropit()
	}
}

pub fn by_mut_unknown[T](mut v T) {
	\$if v is Dropper {
		v.dropit()
	}
}

// the branch after the check is no longer held to the interface
pub fn in_else[T](mut v T) {
	\$if v is Dropper {
	} \$else {
		v.dropit()
	}
}

pub fn in_else_of_type[T](v T) {
	mut c := v
	\$if T is Dropper {
	} \$else {
		c.dropit()
	}
}

// the check holds T, and the call is on a value typed U
pub fn other_param[T, U](a T, b U) {
	mut c := b
	\$if T is Dropper {
		c.dropit()
	}
}

pub fn no_check[T](mut v T) {
	v.dropit()
}

pub interface Printable {
	str() string
}

pub fn (o Owner) str() string {
	return ""
}

pub fn (d Decoy) str() string {
	return ""
}

// V writes str() for a type that declares none, so the interface does not settle it
pub fn prints[T](v T) {
	\$if v is Printable {
		v.str()
	}
}

// the interface through an import: qualified, under an alias, or selected
pub fn qualified_none[T](v T) {
	mut c := v
	\$if T is far.Reaches {
		c.reach()
	}
}

pub fn aliased_none[T](v T) {
	mut c := v
	\$if T is farr.Reaches {
		c.reach()
	}
}

pub fn aliased_known[T](v T) {
	mut c := v
	\$if T is farr.Reaches {
		c.reach()
	}
}

pub fn selected_none[T](v T) {
	mut c := v
	\$if T is Reaches {
		c.reach()
	}
}

pub fn selected_known[T](v T) {
	mut c := v
	\$if T is Reaches {
		c.reach()
	}
}

pub fn selected_known_var[T](mut v T) {
	\$if v is Reaches {
		v.reach()
	}
}

pub fn use() {
	by_type_known(Owner{})
	by_type_silent(Silent{})
	by_var_known(Owner{})
	mut o := Owner{}
	by_mut_known(mut o)
	aliased_known(far.Reacher{})
	selected_known(far.Reacher{})
	mut r := far.Reacher{}
	selected_known_var(mut r)
}
'
		'lib/far/far.v':     'module far

pub interface Reaches {
mut:
	reach()
}

pub struct Reacher {}

pub fn (mut r Reacher) reach() {}

// a decoy
pub struct Other {}

pub fn (mut o Other) reach() {}
'
		'lib/other/other.v': 'module other

import lib.app

// declared where the name `Dropper` means nothing
pub struct Faraway {}

pub fn (mut f Faraway) dropit() {}

pub fn use() {
	app.by_type_known(Faraway{})
}
'
	})
	iface := ['lib.app.Dropper.dropit:inferred']
	owner := 'lib.app.Owner.dropit:inferred'
	mut known := provided_calls(g, 'by_type_known', 'dropit')
	known.sort()
	assert known == ['lib.app.Owner.dropit:inferred', 'lib.other.Faraway.dropit:inferred']
	assert provided_calls(g, 'by_type_unknown', 'dropit') == iface
	assert provided_calls(g, 'by_type_silent', 'dropit') == iface
	assert provided_calls(g, 'by_var_known', 'dropit') == [owner]
	assert provided_calls(g, 'by_var_unknown', 'dropit') == iface
	assert provided_calls(g, 'by_mut_known', 'dropit') == [owner]
	assert provided_calls(g, 'by_mut_unknown', 'dropit') == iface
	assert provided_calls(g, 'in_else', 'dropit') == ['dropit:extracted']
	assert provided_calls(g, 'in_else_of_type', 'dropit') == ['dropit:extracted']
	assert provided_calls(g, 'other_param', 'dropit') == ['dropit:extracted']
	assert provided_calls(g, 'no_check', 'dropit') == ['dropit:extracted']
	assert provided_calls(g, 'prints', 'str') == ['str:extracted']
	reach_iface := ['lib.far.Reaches.reach:inferred']
	reacher := ['lib.far.Reacher.reach:inferred']
	assert provided_calls(g, 'qualified_none', 'reach') == reach_iface
	assert provided_calls(g, 'aliased_none', 'reach') == reach_iface
	assert provided_calls(g, 'selected_none', 'reach') == reach_iface
	assert provided_calls(g, 'aliased_known', 'reach') == reacher
	assert provided_calls(g, 'selected_known', 'reach') == reacher
	assert provided_calls(g, 'selected_known_var', 'reach') == reacher
}

// a check for any of several kinds holds a type parameter to their builtin types, when no instance
// says otherwise; it reads only kinds of the one parameter
fn test_a_check_for_several_kinds_is_a_guard_on_a_type_parameter() {
	g := graph_of({
		'vlib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (mut a array) wipe() {}

pub fn (a &array) first() voidptr {
	return unsafe { nil }
}

pub fn (a &array) keep() voidptr {
	return unsafe { nil }
}

pub struct map {}

pub fn (mut m map) wipe() {}

pub fn (v voidptr) tell() {}
'
		'lib/app/app.v':          'module app

pub struct One {}

pub fn (o One) wipe() {}

pub struct Two {}

pub fn (o Two) wipe() {}

pub fn either_unknown[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
		mut t := unsafe { x }
		t.wipe()
	}
}

pub fn either_array[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
		mut t := unsafe { x }
		t.wipe()
	}
}

pub fn either_struct[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
		mut t := unsafe { x }
		t.wipe()
	}
}

pub fn only_array[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic {
		mut t := unsafe { x }
		t.wipe()
	}
}

pub fn in_else[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
	} \$else {
		mut t := unsafe { x }
		t.wipe()
	}
}

// decoys, so that no name is unique
pub fn (o Two) tell() {}

pub struct Three {}

pub fn (o Three) tell() {}

// an element of an array whose element isn t known is not the voidptr builtin declares
pub fn element_unknown[F](x F) {
	\$if F.unaliased_typ is \$array_dynamic {
		x.first().tell()
	}
}

pub fn element_union[F](x F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
		x.first().tell()
	}
}

// nor of an instance whose element has no such method
pub fn element_instance[F](x F) {
	x.first().tell()
}

// a method of builtin that does return a voidptr still does
pub fn not_an_element[F](x F) {
	\$if F.unaliased_typ is \$array_dynamic {
		x.keep().tell()
	}
}

// an instance of the kinds does not reach the branch after the check
pub fn else_of_array[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
	} \$else {
		mut t := unsafe { x }
		t.wipe()
	}
}

// the instance meets the second kind
pub fn either_map[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is \$map {
		mut t := unsafe { x }
		t.wipe()
	}
}

pub fn not_only_kinds[F](x &F) {
	\$if F.unaliased_typ is \$array_dynamic || F.unaliased_typ is One {
		mut t := unsafe { x }
		t.wipe()
	}
}

// the condition says nothing of G alone, though it ends with it
pub fn two_params[F, G](x &F, y &G) {
	\$if F.unaliased_typ is \$array_dynamic || G.unaliased_typ is \$map {
		mut t := unsafe { y }
		t.wipe()
	}
}

pub fn use() {
	a := []int{}
	either_array(&a)
	else_of_array(&a)
	b := One{}
	either_struct(&b)
	m := map[string]int{}
	either_map(&m)
	element_instance([]One{})
}
'
	})
	mut both := provided_calls(g, 'either_unknown', 'wipe')
	both.sort()
	assert both == ['vlib.builtin.array.wipe:inferred', 'vlib.builtin.map.wipe:inferred']
	assert provided_calls(g, 'either_array', 'wipe') == ['vlib.builtin.array.wipe:inferred']
	// an instance that isn't of those kinds doesn't compile the block
	mut none_met := provided_calls(g, 'either_struct', 'wipe')
	none_met.sort()
	assert none_met == ['vlib.builtin.array.wipe:inferred', 'vlib.builtin.map.wipe:inferred']
	assert provided_calls(g, 'only_array', 'wipe') == ['vlib.builtin.array.wipe:inferred']
	assert provided_calls(g, 'in_else', 'wipe') == ['wipe:extracted']
	assert provided_calls(g, 'else_of_array', 'wipe') == ['wipe:extracted']
	assert provided_calls(g, 'either_map', 'wipe') == ['vlib.builtin.map.wipe:inferred']
	assert provided_calls(g, 'not_only_kinds', 'wipe') == ['wipe:extracted']
	assert provided_calls(g, 'two_params', 'wipe') == ['wipe:extracted']
	assert provided_calls(g, 'element_unknown', 'tell') == ['tell:extracted']
	assert provided_calls(g, 'element_union', 'tell') == ['tell:extracted']
	assert provided_calls(g, 'element_instance', 'tell') == ['tell:extracted']
	assert provided_calls(g, 'not_an_element', 'tell') == ['vlib.builtin.voidptr.tell:inferred']
}

// type_idx needs no instance, and nothing else in the graph to bring the expansion on
fn test_type_idx_on_a_type_parameter_alone_in_a_graph_is_undeclared() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub fn alone[T](v T) {
	v.type_idx()
}
'
	})
	assert provided_calls(g, 'alone', 'type_idx') == ['type_idx:undeclared']
}

// `T.type_name()` is no method V writes: it names a static method only a type that declares one has
fn test_a_static_call_on_a_type_parameter_is_not_a_method_v_writes() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub fn named[T]() string {
	return T.type_name()
}
'
	})
	calls := g.edges.filter(it.kind == .calls && it.from == 'lib.app.named').map('${it.to}:${it.provenance}')
	assert calls == ['T__static__type_name:extracted']
}

// a field read off a variable matched by a branch of several types has a type only when they agree,
// and the variable is no such thing once narrowed or declared again
fn test_a_field_of_a_branch_of_several_types_has_the_type_they_agree_on() {
	g := graph_of({
		'lib/app/app.v':     'module app

import lib.other

pub struct Base {}

pub fn (b &Base) tid() int {
	return 1
}

pub struct Rival {}

pub fn (r Rival) tid() int {
	return 2
}

pub struct First {
pub:
	same   &Base  = unsafe { nil }
	differ &Base  = unsafe { nil }
	third  &Base  = unsafe { nil }
	lonely &Base  = unsafe { nil }
	across &Base  = unsafe { nil }
	title  string
}

pub struct Second {
pub:
	same   &Base  = unsafe { nil }
	differ &Rival = unsafe { nil }
	third  &Base  = unsafe { nil }
	across &Base  = unsafe { nil }
}

pub struct Third {
pub:
	same  &Base  = unsafe { nil }
	third &Rival = unsafe { nil }
}

pub fn (f First) run() {}

pub fn (s Second) run() {}

pub type Either = First | Second | Third | other.Remote

pub fn agrees(t Either) int {
	match t {
		First, Second { return t.same.tid() }
		else { return 0 }
	}
}

pub fn differs(t Either) int {
	match t {
		First, Second { return t.differ.tid() }
		else { return 0 }
	}
}

pub fn last_differs(t Either) int {
	match t {
		First, Second, Third { return t.third.tid() }
		else { return 0 }
	}
}

pub fn one_lacks(t Either) int {
	match t {
		First, Second { return t.lonely.tid() }
		else { return 0 }
	}
}

pub fn narrowed_again(t Either) int {
	match t {
		First, Second {
			if t is Second {
				return t.differ.tid()
			}
			return 0
		}
		else { return 0 }
	}
}

pub fn declared_again(t Either, r First) int {
	match t {
		First, Second {
			t := r
			return t.differ.tid()
		}
		else { return 0 }
	}
}

pub fn other_module(t Either) int {
	match t {
		First, other.Remote { return t.across.tid() }
		else { return 0 }
	}
}

pub fn a_method(t Either) {
	match t {
		First, Second { t.run() }
		else {}
	}
}

// a string is one type in every module
pub fn primitive_across(t Either) {
	match t {
		First, other.Remote { t.title.tell() }
		else {}
	}
}

// a branch of values narrows nothing
pub fn of_values(f First, a First, b First) int {
	match f {
		a, b { return f.same.tid() }
		else { return 0 }
	}
}

pub struct Holder {
pub:
	kind Key
}

// a field path is matched as a variable is
pub fn on_a_path(h Holder) int {
	match h.kind {
		First, Second { return h.kind.same.tid() }
		else { return 0 }
	}
}

pub struct OtherHolder {
pub:
	kind Lone
}

pub struct Lone {
pub:
	same &Rival = unsafe { nil }
}

// `h` declared again, its path is another variable`s
pub fn path_of_a_param_again(h Holder) int {
	match h.kind {
		First, Second {
			f := fn (h OtherHolder) int {
				return h.kind.same.tid()
			}
			return f(OtherHolder{})
		}
		else {
			return 0
		}
	}
}

pub fn path_of_a_local_again(h Holder) int {
	match h.kind {
		First, Second {
			f := fn () int {
				h := OtherHolder{}
				return h.kind.same.tid()
			}
			return f()
		}
		else {
			return 0
		}
	}
}

pub fn path_of_it_again(hs []Holder, others []OtherHolder) []int {
	return hs.map(match it.kind {
		First, Second { others.map(it.kind.same.tid()).len }
		else { 0 }
	})
}

pub struct Far {
pub:
	across &other.Base = unsafe { nil }
	names  []string
	counts map[string]int
	rivals map[string]Base
	loose  other.Base
}

// decoys: the name, and no type gives them
pub struct Bystander {}

pub fn (b Bystander) tell_all() {}

pub fn (b Bystander) tell_map() {}

// the same text in two modules names two types
pub fn map_of_two_types(x AcrossKey) {
	match x {
		other.Remote, Far {
			for _, v in x.rivals {
				v.tid()
			}
		}
		else {}
	}
}

// a call looks through `&`
pub fn a_pointer_and_a_value(x AcrossKey) {
	match x {
		other.Remote, Far { x.loose.tid() }
		else {}
	}
}

// `h` declared is not `holder`
pub fn a_name_that_starts_alike(holder Holder) int {
	match holder.kind {
		First, Second {
			h := 1
			return h + holder.kind.same.tid()
		}
		else {
			return 0
		}
	}
}

// one type named from two modules, and arrays and maps of builtin types, are one type
pub fn across_modules(x AcrossKey) bool {
	match x {
		other.Remote, Far {
			x.across.tid()
			x.names.tell_all()
			x.counts.tell_map()
		}
		else {}
	}
	return false
}

pub type AcrossKey = Far | Plain | other.Remote
'
		'lib/other/other.v': 'module other

pub struct Base {}

pub fn (b &Base) tid() int {
	return 3
}

pub struct Remote {
pub:
	across &Base = unsafe { nil }
	title  string
	names  []string
	counts map[string]int
	rivals map[string]Base
	loose  &Base = unsafe { nil }
}

pub struct Decoy {}

pub fn (d Decoy) tell() {}
'
		'vlib/builtin/builtin.v': 'module builtin

pub fn (s string) tell() {}

pub fn (a []string) tell_all() {}

pub fn (m map[string]int) tell_map() {}
'
	})
	base := ['lib.app.Base.tid:inferred']
	unresolved := ['tid:extracted']
	assert provided_calls(g, 'agrees', 'tid') == base
	assert provided_calls(g, 'differs', 'tid') == unresolved
	assert provided_calls(g, 'last_differs', 'tid') == unresolved
	assert provided_calls(g, 'one_lacks', 'tid') == unresolved
	assert provided_calls(g, 'narrowed_again', 'tid') == ['lib.app.Rival.tid:inferred']
	assert provided_calls(g, 'declared_again', 'tid') == ['lib.app.Base.tid:inferred']
	assert provided_calls(g, 'other_module', 'tid') == unresolved
	// V calls each type's, so no one of them is the callee
	assert provided_calls(g, 'a_method', 'run') == ['run:extracted']
	assert provided_calls(g, 'of_values', 'tid') == base
	assert provided_calls(g, 'primitive_across', 'tell') == ['vlib.builtin.string.tell:inferred']
	assert provided_calls(g, 'on_a_path', 'tid') == base
	rival := ['lib.app.Rival.tid:inferred']
	assert provided_calls(g, 'path_of_a_param_again', 'tid') == rival
	assert provided_calls(g, 'path_of_a_local_again', 'tid') == rival
	assert provided_calls(g, 'path_of_it_again', 'tid') == rival
	assert provided_calls(g, 'across_modules', 'tid') == ['lib.other.Base.tid:inferred']
	assert provided_calls(g, 'across_modules', 'tell_all').len == 1
	assert provided_calls(g, 'across_modules', 'tell_all')[0].starts_with('vlib.builtin.')
	assert provided_calls(g, 'across_modules', 'tell_map').len == 1
	assert provided_calls(g, 'across_modules', 'tell_map')[0].starts_with('vlib.builtin.')
	assert provided_calls(g, 'map_of_two_types', 'tid') == unresolved
	assert provided_calls(g, 'a_pointer_and_a_value', 'tid') == ['lib.other.Base.tid:inferred']
	assert provided_calls(g, 'a_name_that_starts_alike', 'tid') == base
}

// `$if T is Foo` is not read for a concrete type: V's `is` takes an alias of Foo, Foo may be another
// type parameter, and an array of an interface is a type, not the interface
fn test_a_check_for_a_concrete_type_keeps_the_instances() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Solid {}

pub fn (s Solid) tag() {}

pub type Renamed = Solid

pub fn (r Renamed) tag() {}

pub struct Decoy {}

pub fn (d Decoy) tag() {}

pub struct Rest {}

pub fn (r Rest) tag() {}

pub fn by_type[T]() {
	\$if T is Solid {
		v := T{}
		v.tag()
	}
}

pub fn by_var[T](x T) {
	\$if x is Solid {
		v := T{}
		v.tag()
	}
}

pub fn in_the_else[T](x T) {
	\$if T is Solid {
	} \$else {
		x.tag()
	}
}

pub fn other_param[T, U](x T, y U) {
	\$if T is U {
		v := T{}
		v.tag()
	}
}

pub interface Pinger {
	ping()
}

pub struct Echo {}

pub fn (e Echo) ping() {}

pub fn elements[T](x T) {
	\$if T is []Pinger {
		x.first().ping()
	}
}

pub fn run(r Renamed) {
	by_type[Renamed]()
	by_var(r)
	other_param(Rest{}, Rest{})
	in_the_else(Solid{})
	in_the_else(Rest{})
}
'
	})
	// the else of a type check leaves its type out
	assert provided_calls(g, 'in_the_else', 'tag') == ['lib.app.Rest.tag:inferred']
	assert provided_calls(g, 'by_type', 'tag') == ['lib.app.Renamed.tag:inferred']
	assert provided_calls(g, 'by_var', 'tag') == ['lib.app.Renamed.tag:inferred']
	assert provided_calls(g, 'other_param', 'tag') == ['lib.app.Rest.tag:inferred']
	assert provided_calls(g, 'elements', 'ping') == ['lib.app.Pinger.ping:inferred']
}

// an interface check holds a type parameter to the instances that can implement it, and it reads
// the same in each spelling
fn test_an_interface_check_leaves_out_an_instance_that_cannot_implement_it() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Named {
	name string
}

pub interface Pinger {
	Named
	ping(n int) string
	str() string
}

pub struct Good {
pub:
	name string
}

pub fn (g Good) ping(n int) string {
	return ""
}

// other parameters
pub struct Arity {
pub:
	name string
}

pub fn (a Arity) ping() string {
	return ""
}

// no field the embedded interface has
pub struct Nameless {}

pub fn (n Nameless) ping(k int) string {
	return ""
}

pub struct Decoy {
pub:
	name string
}

pub fn (d Decoy) ping(n int) string {
	return ""
}

pub fn by_var[T](x T) {
	\$if x is Pinger {
		x.ping(1)
	}
}

pub fn by_type[T](x T) {
	\$if T is Pinger {
		x.ping(1)
	}
}

pub fn by_unaliased[T](x T) {
	\$if T.unaliased_typ is Pinger {
		x.ping(1)
	}
}

pub fn no_instance[T](x T) {
	\$if T.unaliased_typ is Pinger {
		x.ping(1)
	}
}

pub fn none_can[T](x T) {
	\$if x is Pinger {
		x.ping(1)
	}
}

// the else of the check is what can`t implement it, and what is left of the rest isn`t read
pub fn in_the_else[T](x T) {
	\$if T is Pinger {
	} \$else {
		x.ping()
	}
}

pub fn passes_on[T](x T) {
	\$if x is Pinger {
		helper(x)
	}
}

pub fn helper[U](v U) {
	v.ping(1)
}

pub fn run() {
	for_each := Good{}
	by_var(for_each)
	by_var(Arity{})
	by_var(Nameless{})
	by_type(for_each)
	by_type(Arity{})
	by_unaliased(for_each)
	by_unaliased(Nameless{})
	none_can(Arity{})
	passes_on(for_each)
	passes_on(Arity{})
	in_the_else(Arity{})
}
'
	})
	assert provided_calls(g, 'in_the_else', 'ping') == ['lib.app.Arity.ping:inferred']
	good := ['lib.app.Good.ping:inferred']
	// a call of a generic function records no condition, so what it passes on isn't narrowed by one
	assert provided_calls(g, 'helper', 'ping') == ['lib.app.Good.ping:inferred',
		'lib.app.Arity.ping:inferred']
	assert provided_calls(g, 'by_var', 'ping') == good
	assert provided_calls(g, 'by_type', 'ping') == good
	assert provided_calls(g, 'by_unaliased', 'ping') == good
	assert provided_calls(g, 'no_instance', 'ping') == ['lib.app.Pinger.ping:inferred']
	assert provided_calls(g, 'none_can', 'ping') == ['lib.app.Pinger.ping:inferred']
}

// a check for several kinds: an alias meets a kind however it is written, a test that isn`t decided
// keeps the instance, a kind with no builtin type leaves the others no stand-in, and a condition
// that isn`t only kinds is no guard
fn test_a_check_for_several_kinds_reads_each_kind() {
	g := graph_of({
		'vlib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (a array) clear() {}

pub fn (a array) reverse() {}

pub struct map {
pub:
	key_bytes int
}

pub fn (m map) clear() {}

pub fn (m map) tag() {}

pub fn (i int) show() {}
'
		'lib/app/app.v':          'module app

pub type Table = map[string]int

pub fn (t Table) tag() {}

pub fn (t Table) reverse() {}

pub type Flag = bool

pub fn (f Flag) tag() {}

pub struct Plain {}

pub fn (p Plain) tag() {}

pub fn (p Plain) clear() {}

pub fn (p Plain) reverse() {}

pub fn (p Plain) show() {}

pub struct Decoy {}

pub fn (d Decoy) tag() {}

pub fn (d Decoy) clear() {}

pub fn (d Decoy) reverse() {}

pub fn (d Decoy) show() {}

pub fn alias_written_plain[T](x T) {
	\$if T is \$map || T is \$array_dynamic {
		x.tag()
	}
}

pub fn alias_unaliased[T](x T) {
	\$if T.unaliased_typ is \$array_dynamic || T.unaliased_typ is \$map {
		x.reverse()
	}
}

// V reads an alias of a bool as no \$bool
pub fn alias_of_bool[T](x T) {
	\$if T is \$bool {
		x.tag()
	}
}

// nor written with `unaliased_typ`
pub fn alias_of_bool_unaliased[T](x T) {
	\$if T.unaliased_typ is \$bool || T.unaliased_typ is \$map {
		x.tag()
	}
}

pub fn undecided_kind[T](x T) {
	\$if T.unaliased_typ is \$struct || T.unaliased_typ is \$map {
		x.tag()
	}
}

pub fn not_only_kinds[T](x T) {
	\$if T.unaliased_typ is \$map || windows {
		x.tag()
	}
}

pub fn a_kind_with_no_type[T](mut x T) {
	\$if T.unaliased_typ is \$array || T.unaliased_typ is \$map {
		x.clear()
	}
}

pub fn int_or_map[T](x T) {
	\$if T.unaliased_typ is \$int || T.unaliased_typ is \$map {
		x.show()
	}
}

pub fn a_loop_over_a_map[T](x T) {
	\$if T.unaliased_typ is \$array_dynamic || T.unaliased_typ is \$map {
		\$for f in T.fields {
			x.\$(f.name).show()
		}
	}
}

pub fn run(t Table, f Flag) {
	alias_written_plain[Table](t)
	alias_unaliased[Table](t)
	alias_of_bool[Flag](f)
	alias_of_bool_unaliased[Flag](f)
	undecided_kind(Plain{})
	not_only_kinds(Plain{})
}
'
	})
	assert provided_calls(g, 'alias_written_plain', 'tag') == ['lib.app.Table.tag:inferred']
	assert provided_calls(g, 'alias_unaliased', 'reverse') == ['lib.app.Table.reverse:inferred']
	assert provided_calls(g, 'alias_of_bool_unaliased', 'tag').all(!it.contains('Flag'))
	assert provided_calls(g, 'undecided_kind', 'tag') == ['lib.app.Plain.tag:inferred']
	assert provided_calls(g, 'not_only_kinds', 'tag') == ['lib.app.Plain.tag:inferred']
	assert provided_calls(g, 'a_kind_with_no_type', 'clear') == ['clear:extracted']
	assert provided_calls(g, 'int_or_map', 'show') == ['show:extracted']
	assert provided_calls(g, 'a_loop_over_a_map', 'show').all(!it.contains('int.show'))
	assert provided_calls(g, 'alias_of_bool', 'tag').all(!it.contains('Flag'))
}

// a function in a field of the name is no method V writes
fn test_a_function_field_named_as_a_method_v_writes_is_not_undeclared() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Holder {
pub:
	type_name fn () string = fn () string {
		return ""
	}
}

pub fn read[T](x T) string {
	return x.type_name()
}

pub type Reader = fn () int

// a named function type is one too, and a field of another type can`t be called
pub struct Named {
pub:
	type_idx Reader
}

pub fn idx[T](x T) int {
	return x.type_idx()
}

pub fn run() {
	read(Holder{})
}
'
	})
	assert !provided_calls(g, 'read', 'type_name').any(it.ends_with(':undeclared'))
	assert !provided_calls(g, 'idx', 'type_idx').any(it.ends_with(':undeclared'))
	data := graph_of({
		'lib/app/app.v': 'module app

pub struct Data {
pub:
	type_idx int
}

pub fn idx[T](x T) int {
	return x.type_idx()
}
'
	})
	assert provided_calls(data, 'idx', 'type_idx') == ['type_idx:undeclared']
}

// what an interface asks of an implementer is what its body declares: a method written with a body
// on the interface isn't, nor a static one, but one the body declares still is
fn test_a_method_with_a_body_on_an_interface_is_not_asked_of_an_implementer() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Spk {
	say() int
}

pub fn (s Spk) extra() {}

pub fn (mut s Spk) extra_mut() {}

pub fn Spk.make() {}

pub struct Plain {}

pub fn (p Plain) say() int {
	return 1
}

pub fn (p Plain) other() {}

// it doesn`t have what the body declares
pub struct Silent {}

pub fn (s Silent) other() {}

pub struct Decoy {}

pub fn (d Decoy) say() int {
	return 1
}

pub fn (d Decoy) other() {}

pub fn (d Decoy) bye() {}

pub fn (d Decoy) get() int {
	return 1
}

pub fn own[T](x T) {
	\$if T is Spk {
		x.other()
		x.say()
	}
}

pub interface Inner {
	hi() int
}

pub fn (i Inner) helper() {}

pub interface Outer {
	Inner
	bye()
}

pub struct Duo {}

pub fn (d Duo) hi() int {
	return 1
}

pub fn (d Duo) bye() {}

pub fn (d Duo) other() {}

pub fn embedded[T](x T) {
	\$if T.unaliased_typ is Outer {
		x.other()
	}
}

pub interface Gen[K] {
	get() int
}

pub fn (g Gen[K]) body() {}

pub struct Getter {}

pub fn (g Getter) get() int {
	return 1
}

pub fn (g Getter) other() {}

// a generic interface isn`t read, so its members can`t leave an instance out
pub fn generic_interface[T](x T) {
	\$if T is Gen[int] {
		x.other()
	}
}

pub fn run() {
	own(Plain{})
	own(Silent{})
	embedded(Duo{})
	generic_interface(Getter{})
}
'
	})
	assert provided_calls(g, 'own', 'other') == ['lib.app.Plain.other:inferred']
	assert provided_calls(g, 'own', 'say') == ['lib.app.Plain.say:inferred']
	assert provided_calls(g, 'embedded', 'other') == ['lib.app.Duo.other:inferred']
	assert provided_calls(g, 'generic_interface', 'other') == ['lib.app.Getter.other:inferred']
	assert is_interface_member('fn (Spk) say() int')
	assert is_interface_member('fn (Gen[K, V]) say()')
	assert !is_interface_member('fn (s Spk) extra()')
	assert !is_interface_member('fn (s Gen[K, V]) extra()')
	assert !is_interface_member('fn (mut s Spk) extra()')
	assert !is_interface_member('pub fn (s Spk) extra()')
}

// an instance is only left out of an interface check when the whole of it was read and the member
// isn`t there: a member the lookups can`t pick one of, or don`t reach, keeps it
fn test_a_member_the_lookup_cannot_decide_keeps_the_instance() {
	g := graph_of({
		'lib/app/app.v':         'module app

import os

pub interface HasM {
	mc() int
}

pub interface HasTag {
	tag int
}

pub interface HasClose {
	mut:
	close()
}

pub struct Lefty {
pub:
	tag int
}

pub fn (l Lefty) mc() int {
	return 1
}

pub struct Righty {
pub:
	tag int
}

pub fn (r Righty) mc() int {
	return 2
}

// the same member by two embeds
pub struct Both {
	Lefty
	Righty
}

pub fn (b Both) other() {}

// embeds, past what the lookups follow
pub struct Deep1 {
	Deep2
}

pub struct Deep2 {
	Deep3
}

pub struct Deep3 {
	Deep4
}

pub struct Deep4 {
	Deep5
}

pub struct Deep5 {
	Deep6
}

pub struct Deep6 {
pub:
	tag int
}

pub fn (d Deep6) mc() int {
	return 3
}

pub fn (d Deep1) other() {}

// a method on concrete instances of the type
pub struct Box[T] {}

pub fn (b Box[int]) mc() int {
	return 4
}

pub fn (b Box[string]) mc() int {
	return 5
}

pub fn (b Box[T]) other() {}

// one copy per platform
pub struct Doc {}

pub fn (d Doc) other() {}

// the method of a type outside the graph
pub struct Mine {
	os.File
}

pub fn (m Mine) other() {}

// through an alias, to one with the method by two embeds
pub type AlBoth = Both

pub fn (a AlBoth) other() {}

// embeds read in full, where nothing has the member
pub struct Bare {}

pub struct Wraps {
	Bare
}

pub fn (w Wraps) other() {}

pub struct Decoy {
pub:
	tag int
}

pub fn (d Decoy) mc() int {
	return 6
}

pub fn (d Decoy) close() {}

pub fn (d Decoy) other() {}

pub fn by_method[T](x T) {
	\$if T is HasM {
		x.other()
	}
}

pub fn by_field[T](x T) {
	\$if T is HasTag {
		x.other()
	}
}

pub fn by_outside[T](x T) {
	\$if T is HasClose {
		x.other()
	}
}

pub fn run() {
	by_method(Both{})
	by_method(Deep1{})
	by_method(Box[int]{})
	by_method(Doc{})
	by_method(AlBoth{})
	by_method(Wraps{})
	by_field(Both{})
	by_field(Deep1{})
	by_field(Wraps{})
	by_outside(Mine{})
	by_outside(Wraps{})
}
'
		'lib/far2/far2.v':         'module far2

// the type of the name that has the method is another module`s
pub struct Wraps {}

pub fn (w Wraps) mc() int {
	return 9
}
'
		'lib/app/doc_nix.c.v':     'module app

pub fn (d Doc) mc() int {
	return 7
}
'
		'lib/app/doc_windows.c.v': 'module app

pub fn (d Doc) mc() int {
	return 8
}
'
	})
	method := provided_calls(g, 'by_method', 'other')
	for kept in ['Both', 'Deep1', 'Box[T]', 'Doc', 'AlBoth'] {
		assert method.contains('lib.app.${kept}.other:inferred'), kept
	}
	assert !method.any(it.contains('Wraps')), method.str()
	field := provided_calls(g, 'by_field', 'other')
	for kept in ['Both', 'Deep1'] {
		assert field.contains('lib.app.${kept}.other:inferred'), kept
	}
	assert !field.any(it.contains('Wraps')), field.str()
	assert provided_calls(g, 'by_outside', 'other') == ['lib.app.Mine.other:inferred']
}

// a program's copies of a method per platform each have their own id, so no one of them can be picked:
// the type has it, an alias's own included, whatever the alias names
fn test_a_method_with_a_copy_per_platform_in_a_program_keeps_the_instance() {
	files := {
		'main.v':           'module main

interface HasM {
	mc() int
}

struct Doc {}

fn (d Doc) other() {}

struct Base {}

type AlOwn = Base

fn (a AlOwn) other() {}

// what the alias names has no such method, and nor does this
struct Lacking {}

fn (l Lacking) other() {}

type AlLacking = Base

fn (a AlLacking) other() {}

struct Dc {}

fn (d Dc) mc() int {
	return 0
}

fn (d Dc) other() {}

fn am[T](x T) {
	\$if T is HasM {
		x.other()
	}
}

fn main() {
	am(Doc{})
	am(AlOwn{})
	am(Lacking{})
	am(AlLacking{})
}
'
		'plat_nix.c.v':     'module main

fn (d Doc) mc() int {
	return 1
}

fn (a AlOwn) mc() int {
	return 1
}
'
		'plat_windows.c.v': 'module main

fn (d Doc) mc() int {
	return 2
}

fn (a AlOwn) mc() int {
	return 2
}
'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	resolve_edges(mut g)
	other := g.edges.filter(it.kind == .calls && it.from.all_before('@') == 'main.am'
		&& it.to.all_after_last('.') == 'other').map(it.to.all_before('@'))
	assert 'main.Doc.other' in other, other.str()
	assert 'main.AlOwn.other' in other, other.str()
	assert 'main.Lacking.other' !in other, other.str()
	assert 'main.AlLacking.other' !in other, other.str()
}

// the instance and the interface may each be generic, or of another module, and a type no
// declaration names isn`t read
fn test_an_interface_check_reads_each_way_of_naming_the_instance() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Local {
	ping(n int)
}

pub struct Good {}

pub fn (g Good) ping(n int) {}

pub struct Gen[T] {}

pub fn (g Gen[T]) ping() {}

pub struct Decoy {}

pub fn (d Decoy) ping(n int) {}

pub fn generic_inst[T](x T) {
	\$if x is Local {
		x.ping(1)
	}
}

pub interface Both {
	mut:
	clear()
	gone()
}

pub fn arr[T](mut x T) {
	\$if x is Both {
		x.clear()
	}
}

pub interface Top {
	Mid
	top()
}

pub interface Mid {
	Low
}

pub interface Low {
	low()
}

pub struct Whole {}

pub fn (w Whole) top() {}

pub fn (w Whole) low() {}

pub struct NoLow {}

pub fn (n NoLow) top() {}

pub fn (d Decoy) top() {}

pub fn (d Decoy) low() {}

pub fn (d Decoy) clear() {}

pub fn (d Decoy) gone() {}

pub fn two_levels[T](x T) {
	\$if x is Top {
		x.top()
	}
}

pub fn run() {
	generic_inst(Good{})
	generic_inst(Gen[int]{})
	mut a := []int{}
	arr(mut a)
	two_levels(Whole{})
	two_levels(NoLow{})
}
'
		'vlib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (a array) clear() {}
'
		'lib/app/app_test.v': 'module app

pub struct Tst {}

pub fn (t Tst) tping() {}

pub fn (t Tst) both() {}

// it has no `tping`, read from the test file that declares it
pub struct TstLack {}

pub fn (t TstLack) both() {}

fn test_tst() {
	in_test(Tst{})
	in_test(TstLack{})
}
'
		'lib/app/more.v': 'module app

pub interface Pinger {
	tping()
}

pub struct TDecoy {}

pub fn (t TDecoy) tping() {}

pub fn (t TDecoy) both() {}

pub struct TDecoy2 {}

pub fn (t TDecoy2) both() {}

pub fn in_test[T](x T) {
	\$if x is Pinger {
		x.tping()
		x.both()
	}
}
'
	})
	assert provided_calls(g, 'generic_inst', 'ping') == ['lib.app.Good.ping:inferred']
	// an array has `clear` and no `gone`: it can`t implement the interface
	assert provided_calls(g, 'arr', 'clear') == ['lib.app.Both.clear:inferred']
	assert provided_calls(g, 'two_levels', 'top') == ['lib.app.Whole.top:inferred']
	// an instance in a test file is read from there
	assert provided_calls(g, 'in_test', 'tping') == ['lib.app.Tst.tping:inferred']
	assert provided_calls(g, 'in_test', 'both') == ['lib.app.Tst.both:inferred']
}

// as a type of another module, called from a program
fn test_an_interface_check_reads_an_instance_and_an_interface_of_another_module() {
	g := graph_of({
		'far/far.v': 'module far

pub interface Reaches {
	reach(n int)
}

pub struct GoodReach {}

pub fn (g GoodReach) reach(n int) {}

pub struct WrongReach {}

pub fn (w WrongReach) reach() {}

pub struct Wrong {}

pub fn (w Wrong) ping() {}
'
		'main.v':    'module main

import far
import ext

interface Local {
	ping(n int)
}

struct Good {}

fn (g Good) ping(n int) {}

struct Decoy {}

fn (d Decoy) ping(n int) {}

fn (d Decoy) reach(n int) {}

struct Decoy2 {}

fn (d Decoy2) reach(n int) {}

fn qual_inst[T](x T) {
	\$if x is Local {
		x.ping(1)
	}
}

fn qual_iface[T](x T) {
	\$if x is far.Reaches {
		x.reach(1)
	}
}

interface Nm {
	nm() string
}

struct Dcl {}

fn (d Dcl) nm() string {
	return ""
}

// a type no declaration in the graph names isn`t read, and may declare the method
fn strs[T](x T) {
	\$if x is Nm {
		x.str()
	}
}

fn main() {
	qual_inst(Good{})
	qual_inst(far.Wrong{})
	qual_iface(far.GoodReach{})
	qual_iface(far.WrongReach{})
	strs(Dcl{})
	strs(ext.Thing{})
}
'
	})
	ping := g.edges.filter(it.kind == .calls && it.from.all_before('@') == 'main.qual_inst'
		&& it.to.all_after_last('.') == 'ping').map(it.to.all_before('@'))
	assert ping == ['main.Good.ping']
	reach := g.edges.filter(it.kind == .calls && it.from.all_before('@') == 'main.qual_iface'
		&& it.to.all_after_last('.') == 'reach').map(it.to.all_before('@'))
	assert reach == ['far.GoodReach.reach']
	assert !g.edges.any(it.kind == .calls && it.from.all_before('@') == 'main.strs'
		&& it.to == 'str' && it.provenance == .undeclared)
}

// the method of a check nested in another is on whichever of the two interfaces declares it
fn test_nested_interface_checks_find_the_method_on_either() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Aa1 {
	aa()
}

pub interface Bb1 {
	bb()
}

pub struct Decoy1 {}

pub fn (d Decoy1) bb() {}

pub struct Decoy2 {}

pub fn (d Decoy2) bb() {}

pub fn by_type[T](x T) {
	\$if T is Aa1 {
		\$if T is Bb1 {
			x.bb()
		}
	}
}

pub fn by_unaliased[T](x T) {
	\$if T.unaliased_typ is Aa1 {
		\$if T.unaliased_typ is Bb1 {
			x.bb()
		}
	}
}
'
	})
	assert provided_calls(g, 'by_type', 'bb') == ['lib.app.Bb1.bb:inferred']
	assert provided_calls(g, 'by_unaliased', 'bb') == ['lib.app.Bb1.bb:inferred']
}

// a pointer to an interface, like an array of one, is a concrete type, and V holds no implementer
// to it
fn test_a_check_for_a_pointer_to_an_interface_is_not_an_interface_check() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub interface Speaker {
	speak() int
}

pub struct Dog {}

pub fn (d Dog) speak() int {
	return 1
}

pub fn (d Dog) only() {}

pub struct Decoy {}

pub fn (d Decoy) speak() int {
	return 1
}

pub fn (d Decoy) only() {}

pub fn by_type[T](x T) {
	\$if T is &Speaker {
		x.only()
	}
}

pub fn run() {
	d := Dog{}
	by_type(d)
	by_type(&d)
}
'
	})
	assert !provided_calls(g, 'by_type', 'only').any(it.contains('Dog'))
}

// `T.unaliased_typ is X` names X as `T is X` does: through an import`s alias or its selected names
fn test_an_unaliased_check_reads_the_names_an_import_gives() {
	g := graph_of({
		'lib/sub/sub.v':     'module sub

pub interface Iface {
	m() int
}
'
		'lib/pick/pick.v':   'module pick

pub interface Picked {
	m() int
}
'
		'lib/app/app.v':     'module app

import lib.sub as z

pub struct Foo {}

pub fn (f Foo) m() int {
	return 1
}

pub struct Decoy {}

pub fn (d Decoy) m() int {
	return 2
}

pub fn plain[T](x T) {
	\$if T is z.Iface {
		x.m()
	}
}

pub fn unaliased[T](x T) {
	\$if T.unaliased_typ is z.Iface {
		x.m()
	}
}

pub fn run() {
	plain(Foo{})
	unaliased(Foo{})
}
'
		'lib/app/picked.v':  'module app

import lib.pick { Picked }

pub fn selected[T](x T) {
	\$if T.unaliased_typ is Picked {
		x.m()
	}
}

pub fn run2() {
	selected(Foo{})
}
'
	})
	foo := ['lib.app.Foo.m:inferred']
	assert provided_calls(g, 'plain', 'm') == foo
	assert provided_calls(g, 'unaliased', 'm') == foo
	assert provided_calls(g, 'selected', 'm') == foo
}

// the else of `$map` in a check for an array or a map is only ever the array
fn test_a_nested_kind_check_narrows_the_stand_ins() {
	g := graph_of({
		'vlib/builtin/builtin.v': 'module builtin

pub struct array {}

pub fn (a array) clear() {}

pub struct map {}

pub fn (m map) clear() {}

pub fn (m map) keys() {}
'
		'lib/app/app.v':          'module app

pub fn plain[T](mut x T) {
	\$if T is \$array_dynamic || T is \$map {
		\$if T is \$map {
			x.keys()
		} \$else {
			x.clear()
		}
	}
}

pub fn unaliased[T](mut x T) {
	\$if T.unaliased_typ is \$array_dynamic || T.unaliased_typ is \$map {
		\$if T.unaliased_typ is \$map {
			x.keys()
		} \$else {
			x.clear()
		}
	}
}
'
	})
	assert provided_calls(g, 'plain', 'clear') == ['vlib.builtin.array.clear:inferred']
	assert provided_calls(g, 'unaliased', 'clear') == ['vlib.builtin.array.clear:inferred']
	assert provided_calls(g, 'plain', 'keys') == ['vlib.builtin.map.keys:extracted']
}

// `$if x is Foo` holds on a variable typed by a type parameter, `mut` or not, but never on `x &T`,
// which reads the same to a recipe as `mut x T`
fn test_a_type_check_on_a_pointer_parameter_does_not_narrow_it() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Foo {}

pub fn (f Foo) m() {}

pub struct Bar {}

pub fn (b Bar) m() {}

pub fn pointer[T](x &T) {
	\$if x is Foo {
		x.m()
	} \$else {
		x.m()
	}
}

pub fn by_mut[T](mut x T) {
	\$if x is Foo {
		x.m()
	}
}

pub fn by_mut_pointer[T](mut x &T) {
	\$if x is Foo {
		x.m()
	}
}

pub fn run() {
	pointer(&Bar{})
	mut f := Foo{}
	by_mut(mut f)
}
'
	})
	assert provided_calls(g, 'pointer', 'm') == ['lib.app.Bar.m:inferred']
	assert provided_calls(g, 'by_mut', 'm') == ['lib.app.Foo.m:inferred']
	assert provided_calls(g, 'by_mut_pointer', 'm') == ['lib.app.Foo.m:inferred']
}

// a parameter written `&T`, `mut` or not, keeps builtin's fallback under `$if x is $map`: V calls
// builtin's `clone` on `mut x T` even for an alias that declares its own. A variable typed T has only
// its instances, and a method builtin doesn't have is the instance's on either
fn test_a_kind_check_on_a_pointer_parameter_keeps_its_fallback() {
	g := graph_of({
		'vlib/builtin/builtin.v': 'module builtin

pub struct map {}

pub fn (m map) clone() map {
	return m
}
'
		'lib/app/app.v':          'module app

pub struct Decoy1 {}

pub fn (d Decoy1) clone() int {
	return 1
}

pub fn (d Decoy1) tag() {}

pub struct Decoy2 {}

pub fn (d Decoy2) clone() int {
	return 2
}

pub fn (d Decoy2) tag() {}

pub type Own = map[string]int

pub fn (o Own) clone() Own {
	return o
}

pub fn (o Own) tag() {}

pub fn alias_mut[T](mut x T) {
	\$if x is \$map {
		x.clone()
	}
}

pub fn own_method_mut[T](mut x T) {
	\$if x is \$map {
		x.tag()
	}
}

pub fn run() {
	mut own := Own{}
	alias_mut(mut own)
	own_method_mut(mut own)
}

pub fn by_pointer[T](x &T) {
	\$if x is \$map {
		x.clone()
	}
}

pub fn by_value[T](x T) {
	\$if x is \$map {
		x.clone()
	}
}

pub fn by_mut[T](mut x T) {
	\$if x is \$map {
		x.clone()
	}
}

pub fn by_mut_pointer[T](mut x &T) {
	\$if x is \$map {
		x.clone()
	}
}
'
	})
	assert provided_calls(g, 'by_pointer', 'clone') == ['vlib.builtin.map.clone:inferred']
	assert provided_calls(g, 'by_value', 'clone') == ['clone:extracted']
	builtin := ['vlib.builtin.map.clone:inferred']
	assert provided_calls(g, 'by_mut', 'clone') == builtin
	assert provided_calls(g, 'by_mut_pointer', 'clone') == builtin
	assert provided_calls(g, 'alias_mut', 'clone') == builtin
	assert provided_calls(g, 'own_method_mut', 'tag') == ['lib.app.Own.tag:inferred']
}

// an alias of a pointer meets no test: V reads it as a pointer, written either way
fn test_an_alias_of_a_pointer_meets_no_check() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Foo {}

pub type Pint = &int

pub fn (a Pint) tag() {}

pub type Pstr = &string

pub fn (a Pstr) tag() {}

pub type Pfoo = &Foo

pub fn (a Pfoo) tag() {}

pub fn in_else[T](v T) {
	\$if T is \$int {
	} \$else {
		v.tag()
	}
}

pub fn in_block[T](v T) {
	\$if T is \$int {
		v.tag()
	}
}

pub fn unaliased[T](v T) {
	\$if T.unaliased_typ is \$string {
	} \$else {
		v.tag()
	}
}

pub fn named[T](v T) {
	\$if T.unaliased_typ is Foo {
	} \$else {
		v.tag()
	}
}

// V holds these for it, and doesn`t hold a struct
pub fn alias_kind[T](v T) {
	\$if T is \$alias {
		v.tag()
	}
}

pub fn pointer_kind[T](v T) {
	\$if T is \$pointer {
		v.tag()
	}
}

pub fn run(p Pint, s Pstr, f Pfoo) {
	alias_kind[Pint](p)
	pointer_kind[Pint](p)
	in_else[Pint](p)
	in_block[Pint](p)
	unaliased[Pstr](s)
	named[Pfoo](f)
}
'
	})
	assert provided_calls(g, 'alias_kind', 'tag') == ['lib.app.Pint.tag:inferred']
	assert provided_calls(g, 'pointer_kind', 'tag') == ['lib.app.Pint.tag:inferred']
	assert provided_calls(g, 'in_else', 'tag') == ['lib.app.Pint.tag:inferred']
	assert provided_calls(g, 'in_block', 'tag') == ['tag:extracted']
	assert provided_calls(g, 'unaliased', 'tag') == ['lib.app.Pstr.tag:inferred']
	assert provided_calls(g, 'named', 'tag') == ['lib.app.Pfoo.tag:inferred']
}

// a branch on a call has no variable: another call`s field is not of the branch
fn test_a_branch_of_several_types_on_a_call_narrows_nothing() {
	g := graph_of({
		'lib/app/app.v': 'module app

pub struct Base {}

pub fn (b Base) tid() {}

pub struct Rival {}

pub fn (r Rival) tid() {}

pub struct One {
pub:
	same &Base
}

pub struct Two {
pub:
	same &Base
}

pub struct Three {}

pub type Sum = One | Two | Three

pub struct Other {
pub:
	same &Rival
}

pub fn make() Sum {
	return Three{}
}

pub fn other() Other {
	return Other{}
}

pub fn no_path() {
	match make() {
		One, Two {
			other().same.tid()
		}
		else {}
	}
}
'
	})
	assert provided_calls(g, 'no_path', 'tid') == ['lib.app.Rival.tid:inferred']
}

// a field holds a function of a type named in another module too, and a field that only ends in the
// name is another field
fn test_a_function_field_is_read_by_its_whole_name_and_across_modules() {
	g := graph_of({
		'lib/far/far.v': 'module far

pub type Reader = fn () int
'
		'lib/app/app.v': 'module app

import lib.far

pub struct FnHolder {
pub:
	type_idx far.Reader
}

pub fn idx[T](x T) int {
	return x.type_idx()
}
'
	})
	assert !provided_calls(g, 'idx', 'type_idx').any(it.ends_with(':undeclared'))
	suffix := graph_of({
		'lib/app/app.v': 'module app

pub struct Data {
pub:
	my_type_idx fn () int
}

pub fn idx[T](x T) int {
	return x.type_idx()
}
'
	})
	assert provided_calls(suffix, 'idx', 'type_idx') == ['type_idx:undeclared']
}
// `JS.X.prototype.constructor()` builds a `JS.X`, whose methods are the binding's
fn test_a_js_constructor_call_has_the_type_it_builds() {
	g := graph_of({
		'lib/app/app.js.v': 'module app

pub interface JS.Array {
	push(JS.Any) JS.Any
}

pub fn JS.Array.prototype.constructor(...any) JS.Array

pub fn JS.Array.prototype.other() JS.Array

pub fn JS.Array.make() JS.Array

// decoys: a call that names no type could reach them by the name
pub struct One {}

pub fn (o One) push(x int) {}

pub struct Two {}

pub fn (o Two) push(x int) {}

pub fn built() {
	a := JS.Array.prototype.constructor()
	a.push(1)
}

pub fn no_constructor() {
	a := JS.Array.prototype.other()
	a.push(1)
}

pub fn no_prototype() {
	a := JS.Array.make()
	a.push(1)
}
'
	})
	assert provided_calls(g, 'built', 'push') == ['lib.app.Array.push:inferred']
	assert provided_calls(g, 'no_constructor', 'push') == ['push:extracted']
	assert provided_calls(g, 'no_prototype', 'push') == ['push:extracted']
}
// a field loop's str() on a field that declares none stays unresolved: a field's type may be one
// this can't read, and nothing says which
fn test_a_str_on_any_field_that_declares_none_stays_unresolved() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          'module app

pub struct Plain {}

// a decoy: the call on the field must not reach it by name
pub struct Other {}

pub fn (o Other) str() string {
	return ""
}

pub struct Data {
pub:
	p Plain
}

pub fn fields(d Data) {
	\$for field in Data.fields {
		d.\$(field.name).str()
	}
}

// the result of a call between them may declare str(), so it stays unresolved
pub fn through_a_call(d Data) {
	\$for field in Data.fields {
		d.\$(field.name).unknown().str()
	}
}

pub struct Decoy {}

pub fn (o Decoy) str() string {
	return ""
}

// and the same on a type parameter, which the expansion answers (field_any_fallback)
pub fn generic_fields[T](d T) {
	\$for field in T.fields {
		d.\$(field.name).str()
	}
}

pub fn use_generic_fields() {
	generic_fields(Data{})
}
'
	})
	assert provided_calls(g, 'generic_fields', 'str') == ['str:extracted']
	assert provided_calls(g, 'fields', 'str') == ['str:extracted']
	assert provided_calls(g, 'through_a_call', 'str') == ['str:extracted']
}

fn test_a_c_struct_and_a_js_type_read_their_declarations() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/structs.c.v':    'module app

pub struct C.Iter {
pub:
	isize int
	str   &char
}
'
		'lib/app/host.js.v':      'module app

pub struct JS.Failure {
pub:
	stack string
}
'
		'lib/app/app.v':          "module app

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return false
}

pub fn (o Other) str() string {
	return ''
}

pub fn c_struct() {
	iter := C.Iter{}
	iter.str().contains('x')
}

pub struct DataField {
pub:
	str string
}

pub fn data_field(d DataField) {
	d.str()
}

pub fn js_type() {
	e := JS.Failure{}
	e.stack.contains('x')
}
"
	})
	assert provided_calls(g, 'c_struct', 'str') == ['str:undeclared']
	assert provided_calls(g, 'c_struct', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'js_type', 'contains') == ['vlib.builtin.string.contains:inferred']
	assert provided_calls(g, 'data_field', 'str') == ['str:undeclared']
}

fn test_an_array_init_expression_has_its_implicit_index() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin + '
pub fn (i int) str() string {
	return ""
}
'
		'lib/app/app.v':          'module app

pub struct Other {}

pub fn (o Other) str() string {
	return ""
}

pub fn fill() []string {
	return []string{len: 3, init: index.str()}
}

// the implicit index is in `init` only: `len` reads the variable of that name
pub fn outer_index(index Other) {
	_ := []string{len: index.size()}
}

// and in `init` it is the index, whatever variable has the name
pub fn shadowed_index(index Other) {
	_ := []string{len: 1, init: index.str()}
}

pub fn (o Other) size() int {
	return 0
}

pub fn (i int) size() int {
	return 0
}
'
	})
	assert provided_calls(g, 'fill', 'str') == ['vlib.builtin.int.str:inferred']
	assert provided_calls(g, 'outer_index', 'size') == ['lib.app.Other.size:extracted']
	assert provided_calls(g, 'shadowed_index', 'str') == ['vlib.builtin.int.str:inferred']
}

fn test_a_lock_expression_gives_each_name_its_own_value() {
	g := graph_of({
		'vlib/builtin/builtin.v': provided_builtin
		'lib/app/app.v':          "module app

pub struct Other {}

pub fn (o Other) contains(x string) bool {
	return false
}

pub struct Shared {
pub mut:
	a string
	b Other
}

pub fn locked(shared s Shared) {
	x, y := rlock s {
		s.a, s.b
	}
	x.contains('p')
	y.contains('q')
}

pub fn (s Shared) pair() (Other, string) {
	return s.b, s.a
}

// a block ending in one call with several results
pub fn locked_call(shared s Shared) {
	x, y := rlock s {
		s.pair()
	}
	x.contains('p')
	y.contains('q')
}
"
	})
	assert provided_calls(g, 'locked', 'contains').sorted() == ['lib.app.Other.contains:inferred',
		'vlib.builtin.string.contains:inferred'].sorted()
	assert provided_calls(g, 'locked_call', 'contains').sorted() == ['lib.app.Other.contains:inferred',
		'vlib.builtin.string.contains:inferred'].sorted()
}

fn test_a_module_main_test_does_not_take_its_directorys_module_as_its_own() {
	// A test with no `module` line beside `module io` isn't in io, so a plain `copy()` is
	// builtin's, though io declares one: vlib/io/io_test.v. A test of `module io` is in it.
	g := built_graph_of({
		'vlib/builtin/array.v':  'module builtin\n\npub fn copy(mut dst []u8, src []u8) int {\n\treturn 0\n}\n'
		'vlib/io/copy.v':        'module io\n\npub fn copy(mut dst Writer, mut src Reader) !i64 {\n\treturn 0\n}\n'
		'vlib/io/main_test.v':   'import io\n\nfn test_main() {\n\tcopy(mut a, b)\n}\n'
		'vlib/io/inner_test.v':  'module io\n\nfn test_inner() {\n\tcopy(mut a, mut b)!\n}\n'
		'vlib/q/q.v':            'module q\n\npub fn copy() {}\n'
		'vlib/q/helper.v':       'module main\n\nfn copy() {}\n'
		'vlib/q/q_test.v':       'module main\n\nimport q\n\nfn test_helper() {\n\tcopy()\n}\n'
	})
	calls := fn [g] (from string) []string {
		return g.edges.filter(it.kind == .calls && it.to.all_before('@').all_after_last('.') == 'copy'
			&& it.from.all_after_last('.').all_before('@') == from).map(it.to)
	}
	assert calls('test_main') == ['vlib.builtin.copy']
	assert calls('test_inner') == ['vlib.io.copy']
	// helper.v is what a `module main` test of its directory is built with
	assert calls('test_helper') == ['vlib.q.copy@vlib/q/helper.v']
}

// plain_calls lists what the function `from` calls by the name `name`, as `to:provenance`.
fn plain_calls(g Graph, from string, name string) []string {
	return g.edges.filter(it.kind == .calls && it.from.all_before('@').all_after_last('.') == from
		&& it.to.all_before('@').all_after_last('.').all_after_last('::') == name).map('${it.to}:${it.provenance}')
}

fn test_an_alias_of_a_module_name_does_not_take_the_path_of_another_import() {
	// The parser names an aliased import by its path, so `jj.start()` is `benchmark.start`,
	// whichever order the imports come in: vlib/v/tests/import_order_{1,2}_test.v.
	benchmarks := {
		'vlib/benchmark/benchmark.v':   'module benchmark\n\npub fn start() int {\n\treturn 0\n}\n'
		'vlib/x/benchmark/benchmark.v': 'module benchmark\n\npub fn setup() int {\n\treturn 0\n}\n'
	}
	mut files := benchmarks.clone()
	files['vlib/v/tests/one_test.v'] = 'import x.benchmark\nimport benchmark as jj\n\nfn test_one() {\n\tjj.start()\n\tbenchmark.setup()\n}\n'
	files['vlib/v/tests/two_test.v'] = 'import benchmark as jj\nimport x.benchmark\n\nfn test_two() {\n\tjj.start()\n\tbenchmark.setup()\n}\n'
	g := graph_of(files)
	assert plain_calls(g, 'test_one', 'start') == ['vlib.benchmark.start:extracted']
	assert plain_calls(g, 'test_two', 'start') == ['vlib.benchmark.start:extracted']
	assert plain_calls(g, 'test_one', 'setup') == ['vlib.x.benchmark.setup:extracted']
	assert plain_calls(g, 'test_two', 'setup') == ['vlib.x.benchmark.setup:extracted']
}

fn test_an_import_of_a_module_declared_beside_the_file_is_that_module() {
	// vlib/v/tests/testdata/enum_in_builtin: main.v imports `c`, which c.v beside it
	// declares. Only when the import reaches no module of its own: a real `other` wins
	// over a file declaring `module other` beside the caller, as in a single-file build (a
	// directory build takes the file), and a call the module beside it doesn't declare stays
	// unresolved.
	g := graph_of({
		'app/run/main.v':  'module main\n\nimport c\nimport other\n\nfn main() {\n\tc.tst_enum()\n\tother.pick()\n\tc.absent()\n}\n'
		'app/run/c.v':     'module c\n\npub fn tst_enum() {}\n'
		'app/run/near.v':  'module other\n\npub fn pick() {}\n'
		'app/other/o.v':   'module other\n\npub fn pick() {}\n'
		'app/skip/main.v': 'module main\n\nimport missing\n\nfn start() {\n\tmissing.go_on()\n}\n'
		'app/skip/mod.v':  'module skip\n\npub fn go_on() {}\n'
	})
	assert plain_calls(g, 'main', 'tst_enum') == ['app.run.tst_enum:extracted']
	assert plain_calls(g, 'main', 'pick') == ['app.other.pick:extracted']
	assert plain_calls(g, 'main', 'absent') == ['c.absent:extracted']
	assert plain_calls(g, 'start', 'go_on') == ['missing.go_on:extracted']
}

fn test_a_global_function_in_the_callers_own_file_is_what_it_calls() {
	// vlib/v/tests/init_global_test.v: `func2(22)` calls the `__global` of its file,
	// where other files declare functions of that name, in the same directory too.
	files := {
		'vlib/v/tests/init_global_test.v': '__global (\n\tfunc2 = fn (n int) int {\n\t\treturn n\n\t}\n\tcount int\n)\n\nfn test_fn_type() {\n\tfunc2(22)\n}\n\nfn test_local() {\n\tfunc2 := fn (n int) int {\n\t\treturn n\n\t}\n\tfunc2(1)\n}\n\nfn own() {}\n\n__global (\n\town2 = fn () {}\n)\n\nfn test_own() {\n\town()\n\town2()\n}\n\nfn make_int() int {\n\treturn 1\n}\n\nconst valued = make_int()\n\nfn valued() {}\n\nfn test_valued() {\n\tvalued()\n}\n\nconst held = fn () {}\n\nfn held() {}\n\nfn test_held() {\n\theld()\n}\n'
		'vlib/v/tests/return_option_test.v': 'fn func2() ?(int, int) {\n\treturn 1, 2\n}\n\nfn test_other() {\n\tfunc2() or {}\n}\n'
		'lib/lone/lone.v': 'module lone\n\npub fn lone_fn() {}\n'
		'vlib/v/tests/lone_test.v': '__global (\n\tlone_fn = fn () {}\n)\n\nfn test_lone() {\n\tlone_fn()\n}\n'
	}
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	separate_member_ids(mut g)
	resolve_edges(mut g)
	assert plain_calls(g, 'test_fn_type', 'func2') == ['vlib.v.tests::global::func2:inferred']
	assert plain_calls(g, 'test_other', 'func2') == ['vlib.v.tests.func2:extracted']
	// a name unique among functions elsewhere doesn't take it either
	assert plain_calls(g, 'test_lone', 'lone_fn') == ['vlib.v.tests.lone_fn:inferred']
	// a local of the name shadows it, and is undeclared
	assert plain_calls(g, 'test_local', 'func2') == ['func2:undeclared']
	// a global of another name is no candidate for a function of the file
	assert plain_calls(g, 'test_own', 'own') == ['vlib.v.tests.own:extracted']
	assert plain_calls(g, 'test_own', 'own2') == ['vlib.v.tests.own2:inferred']
	// a function the caller sees keeps the call, the constant holding another value or a function
	assert plain_calls(g, 'test_valued', 'valued') == ['vlib.v.tests.valued:extracted']
	assert plain_calls(g, 'test_held', 'held') == ['vlib.v.tests.held:extracted']
	// a global with an id of its own, so no edge to the function reaches it
	assert g.symbols.filter(it.name == 'func2' && it.file.ends_with('init_global_test.v'))[0].id == 'vlib.v.tests::global::func2'
}

fn test_a_bare_call_of_a_struct_or_enum_of_the_module_is_a_conversion() {
	// `&debug_info(raw)` and `token(0)` in a `@[translated]` file are conversions, as
	// `uintptr_t(x)` of an alias is, not calls. vlib/v/tests/casts/translated_alias_casts.
	// A lowercase type of a module the file only imports is no conversion: V needs its
	// prefix. Nor does a type of another `main` program in the directory count.
	g := graph_of({
		'lib/gen/gen.v':     '@[translated]\nmodule gen\n\nstruct debug_info {\n\tvalue int\n}\n\nenum token {\n\tzero\n}\n\nfn conv(raw voidptr) {\n\t_ := &debug_info(raw)\n\t_ := token(0)\n\t_ := pub_type(0)\n\t_ := other_token(0)\n\t_ := own_type(0)\n}\n\nfn conv_c() {\n\tc_only(0)\n}\n\nstruct C.c_only {}\n'
		'lib/gen/more.v':    'module gen\n\nstruct pub_type {}\n\nstruct own_type {}\n'
		'lib/dep/dep.v':     '@[translated]\nmodule dep\n\npub enum other_token {\n\tzero\n}\n\npub enum dep_token {\n\tzero\n}\n'
		'lib/tok/tok.v':     'module tok\n\npub fn token() {}\n'
		'lib/use/use.v':     'module use\n\nimport dep\n\nfn dep_token() {}\n\nfn imported() {\n\tdep_token()\n}\n'
		'lib/mm/a.v':        'module main\n\nstruct mm_t {}\n\nfn main() {}\n'
		'lib/mm/b.v':        'module main\n\nfn main() {}\n\nfn other_main() {\n\tmm_t(0)\n}\n'
	})
	assert plain_calls(g, 'conv', 'debug_info') == ['lib.gen.debug_info:inferred']
	assert plain_calls(g, 'conv', 'token') == ['lib.gen.token:inferred']
	assert plain_calls(g, 'conv', 'pub_type') == ['lib.gen.pub_type:inferred']
	// a type of an imported module is not one, nor is a function hidden by it
	assert plain_calls(g, 'conv', 'other_token') == ['other_token:extracted']
	assert plain_calls(g, 'imported', 'dep_token') == ['lib.use.dep_token:extracted']
	assert plain_calls(g, 'other_main', 'mm_t') == ['mm_t:extracted']
	// a C struct is no conversion by its bare name
	assert plain_calls(g, 'conv_c', 'c_only') == ['c_only:extracted']
}

fn test_a_const_sharing_an_id_with_a_global_keeps_an_id_of_its_own() {
	// a global is still another kind of symbol to a const: each file is its own program
	mut g := Graph{}
	for rel, src in {
		'vlib/v/tests/a_test.v': '__global (\n\tshared_name = fn () {}\n)\n\nfn test_a() {\n\tshared_name()\n}\n'
		'vlib/v/tests/b_test.v': 'const shared_name = 3\n\nfn test_b() {}\n'
	} {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	separate_member_ids(mut g)
	assert g.symbols.filter(it.name == 'shared_name').map(it.id).sorted() == ['vlib.v.tests.shared_name',
		'vlib.v.tests::const::shared_name'].sorted()
}

fn test_the_value_of_a_conversion_or_a_held_function_call_has_its_type() {
	// `x := token(0)` is a token, whatever a `token` function elsewhere returns, and
	// `y := func3(1)` is what the global of the file holds returns
	g := graph_of({
		'vlib/builtin/string.v': 'module builtin\n\npub struct string {}\n\npub fn (s string) tell() {}\n'
		'lib/tok/tok.v':         'module tok\n\npub struct Decoy {}\n\npub fn (d Decoy) tell() {}\n\npub fn token() Decoy {\n\treturn Decoy{}\n}\n\npub fn func3() Decoy {\n\treturn Decoy{}\n}\n\npub fn uint_t() Decoy {\n\treturn Decoy{}\n}\n'
		'lib/gen/gen.v':         '@[translated]\nmodule gen\n\nenum token {\n\tzero\n}\n\nfn (t token) tell() {}\n\ntype uint_t = Mine\n\nstruct Mine {}\n\nfn (u uint_t) tell() {}\n\n__global (\n\tfunc3 = fn (n int) string {\n\t\treturn ""\n\t}\n)\n\nfn conv() {\n\tx := token(0)\n\tx.tell()\n}\n\nfn held() {\n\ty := func3(1)\n\ty.tell()\n}\n\nfn aliased() {\n\tz := uint_t(0)\n\tz.tell()\n\tuint_t(1)\n}\n'
	})
	assert plain_calls(g, 'conv', 'tell') == ['lib.gen.token.tell:inferred']
	assert plain_calls(g, 'held', 'tell') == ['vlib.builtin.string.tell:inferred']
	assert plain_calls(g, 'aliased', 'tell') == ['lib.gen.uint_t.tell:inferred']
	// the alias itself: a function of the name elsewhere is no call of it
	assert plain_calls(g, 'aliased', 'uint_t') == ['lib.gen.uint_t:inferred']
}

fn test_an_alias_of_builtin_is_tried_after_a_function_of_the_callers_own_module() {
	// not what V does: compiled with a @[translated] builtin file, it converts. No builtin file
	// declares a lowercase alias, and this is the order the disclosed limit describes
	g := graph_of({
		'vlib/builtin/alias.v': 'module builtin\n\npub type own_alias = int\n'
		'lib/app/app.v':        'module app\n\nfn own_alias(n int) int {\n\treturn n\n}\n\nfn run() {\n\town_alias(1)\n}\n'
	})
	assert plain_calls(g, 'run', 'own_alias') == ['lib.app.own_alias:extracted']
	// a struct of the module is the conversion, though only V's bare builtin declares a
	// function of the name, which a call otherwise reaches every copy of
	bare := graph_of({
		'vlib/builtin/linux_bare/f.v': 'module builtin\n\npub fn bare_t() {}\n'
		'vlib/builtin/macos_bare/f.v': 'module builtin\n\npub fn bare_t() {}\n'
		'lib/gen/gen.v':               '@[translated]\nmodule gen\n\nstruct bare_t {}\n\nfn conv() {\n\tbare_t(0)\n}\n'
	})
	assert plain_calls(bare, 'conv', 'bare_t') == ['lib.gen.bare_t:inferred']
}

fn test_a_type_private_to_a_test_or_of_a_host_is_no_conversion() {
	// another test's struct stays its own, and a JS type is reached as `JS.name`
	g := graph_of({
		'lib/gen/a_test.v': 'module gen\n\nstruct other_t {}\n\nfn test_a() {}\n'
		'lib/gen/b_test.v': 'module gen\n\nfn test_b() {\n\tother_t(0)\n\tjs_only(0)\n}\n\ninterface JS.js_only {}\n'
	})
	assert plain_calls(g, 'test_b', 'other_t') == ['other_t:extracted']
	assert plain_calls(g, 'test_b', 'js_only') == ['js_only:extracted']
}

fn test_a_global_of_the_module_takes_a_call_only_from_a_function_it_cant_see() {
	// a function of the module keeps the call, from a global in its file or another; one of another
	// module doesn't. A global of another module, or of a test, isn't in scope, and a program of a
	// directory with several sees only its own file.
	mut g := Graph{}
	for rel, src in {
		'lib/app/a.v':       'module app\n\nfn pick() {}\n\nfn run() {\n\tpick()\n}\n\nfn keep() {}\n\nfn call_keep() {\n\tkeep()\n}\n\nfn hidden() {}\n\nfn call_hidden() {\n\thidden()\n}\n'
		'lib/app/other.v':   'module app\n\n__global (\n\tpick = fn () {}\n\tfar = fn () {}\n)\n\nfn call_far() {\n\tfar()\n}\n'
		'lib/two/far.v':     'module two\n\npub fn far() {}\n'
		'lib/app/h_test.v':  'module app\n\n__global (\n\thidden = fn () {}\n)\n\nfn test_h() {}\n'
		'lib/two/f.v':       'module two\n\n__global (\n\tkeep = fn () {}\n)\n'
		'cmd/p/one.v':       'module main\n\nconst solo_f = fn () {}\n\nfn main() {}\n'
		'cmd/p/two.v':       'module main\n\nfn solo_f() {}\n\nfn main() {}\n\nfn call_solo() {\n\tsolo_f()\n}\n'
	} {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	assert plain_calls(g, 'run', 'pick') == ['lib.app.pick:extracted']
	assert plain_calls(g, 'call_far', 'far') == ['lib.app.far:inferred']
	assert plain_calls(g, 'call_keep', 'keep') == ['lib.app.keep:extracted']
	assert plain_calls(g, 'call_hidden', 'hidden') == ['lib.app.hidden:extracted']
	assert plain_calls(g, 'call_solo', 'solo_f') == ['cmd.p.solo_f:extracted']
}

fn test_a_module_beside_the_file_stays_out_when_it_is_a_test_or_a_method() {
	g := graph_of({
		'app/run/main.v':   'module main\n\nimport c\n\nfn main() {\n\tc.in_test()\n\tc.as_method()\n}\n'
		'app/run/c_test.v': 'module c\n\nfn in_test() {}\n'
		'app/run/c.v':      'module c\n\npub struct S {}\n\npub fn (s S) as_method() {}\n'
	})
	assert plain_calls(g, 'main', 'in_test') == ['c.in_test:extracted']
	assert plain_calls(g, 'main', 'as_method') == ['c.as_method:extracted']
}

// extract_graph_of builds as an extract does, with the id stages graph_of leaves out.
fn extract_graph_of(files map[string]string) Graph {
	mut g := Graph{}
	for rel, src in files {
		syms, edges := extract_v_text(src, rel)
		g.symbols << syms
		g.edges << edges
	}
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	return g
}

const builtin_fns = 'module builtin\n\npub fn copy(mut d []u8, s []u8) int {\n\treturn 0\n}\n\npub fn error(s string) IError {\n\treturn IError{}\n}\n\npub interface IError {\n\tmsg() string\n}\n'

fn test_a_type_v_does_not_read_bare_gives_way_to_builtins_function() {
	// each of these is builtin's function: an imported module's alias needs its prefix, a type of a
	// module beside a `module main` test or program is not its own, and a C type is named `C.x`.
	// So is one under the caller's own lowercase type, as on master, though compiled, V converts.
	g := extract_graph_of({
		'vlib/builtin/a.v':  builtin_fns
		'lib/m/m.v':         '@[translated]\nmodule m\n\npub type copy = int\n'
		'lib/use/use.v':     'module use\n\nimport m\n\nfn imported() {\n\tcopy(mut a, b)\n}\n'
		'pkg/lib.v':         '@[translated]\nmodule lib\n\npub type copy = int\n'
		'pkg/x_test.v':      'module main\n\nfn test_beside() {\n\tcopy(mut a, b)\n}\n'
		'solo/main.v':       'module main\n\nfn main() {\n\tcopy(mut a, b)\n}\n'
		'solo/lib.v':        '@[translated]\nmodule lib\n\npub struct copy {\n\ta int\n}\n'
		'own/own.v':         '@[translated]\nmodule own\n\npub struct error {\n\tx int\n}\n\nfn own_error() {\n\terror(0)\n}\n'
		'host/host.v':       'module host\n\ntype C.error = int\n\nfn host_error() {\n\terror(0)\n}\n'
	})
	for from in ['imported', 'test_beside', 'main'] {
		assert plain_calls(g, from, 'copy').all(it == 'vlib.builtin.copy:inferred'
			|| it == 'vlib.builtin.copy:extracted'), from
	}
	assert plain_calls(g, 'own_error', 'error').len == 1
	assert plain_calls(g, 'own_error', 'error')[0].starts_with('vlib.builtin.error:')
	assert plain_calls(g, 'host_error', 'error')[0].starts_with('vlib.builtin.error:')
}

fn test_a_held_function_of_the_module_beats_an_imported_alias() {
	// compiled: V calls the const, and an imported alias of the name has no say
	g := extract_graph_of({
		'tr/tr.v':     '@[translated]\nmodule tr\n\npub type pick = int\n'
		'lib/a/a.v':   'module a\n\nimport tr\n\nconst pick = fn () int {\n\treturn 42\n}\n\nfn run() int {\n\treturn pick()\n}\n'
	})
	assert plain_calls(g, 'run', 'pick') == ['lib.a.pick:inferred']
}

fn test_a_held_function_keeps_a_call_from_a_type_in_the_edge_and_the_value() {
	// as on master, though compiled, a @[translated] caller converts where any other calls the const:
	// what a declaration says can't tell them apart
	g := extract_graph_of({
		'lib/a/a.v': '@[translated]\nmodule a\n\nstruct Mine {}\n\nfn (m Mine) tell() {}\n\nstruct Other {}\n\nfn (o Other) tell() {}\n\ntype foo = Mine\n\nconst foo = fn (m Mine) Other {\n\treturn Other{}\n}\n\nfn run() {\n\tx := foo(Mine{})\n\tx.tell()\n}\n'
	})
	assert plain_calls(g, 'run', 'foo') == ['lib.a::const::foo:inferred']
	assert plain_calls(g, 'run', 'tell') == ['lib.a.Other.tell:inferred']
}

fn test_a_local_function_value_keeps_its_name_from_a_const_or_a_type() {
	// compiled: V calls the local each time, so `x` has what the local holds returns
	g := extract_graph_of({
		'lib/a/a.v': '@[translated]\nmodule a\n\nstruct Foo {}\n\nfn (f Foo) m() {}\n\nstruct Bar {}\n\nfn (b Bar) m() {}\n\nstruct token {}\n\nfn (t token) m() {}\n\nconst fa = fn (i int) Foo {\n\treturn Foo{}\n}\n\nfn mk(i int) Bar {\n\treturn Bar{}\n}\n\nfn by_local() {\n\tfa := mk\n\tx := fa(1)\n\tx.m()\n}\n\nfn by_conv() {\n\ttoken := mk\n\ty := token(1)\n\ty.m()\n}\n\nfn plain() {\n\tz := fa(1)\n\tz.m()\n}\n'
	})
	assert plain_calls(g, 'by_local', 'm') == ['lib.a.Bar.m:inferred']
	assert plain_calls(g, 'by_conv', 'm') == ['lib.a.Bar.m:inferred']
	assert plain_calls(g, 'plain', 'm') == ['lib.a.Foo.m:inferred']
}

fn test_a_held_function_in_one_platforms_file_leaves_the_others_function() {
	// compiled: V on Windows calls the const and on Linux the function, so the const can't
	// take the call from the file of neither
	g := extract_graph_of({
		'pkg/a_windows.c.v': 'module pkg\n\npub const plat_f = fn () string {\n\treturn ""\n}\n'
		'pkg/a_linux.c.v':   'module pkg\n\nfn plat_f() string {\n\treturn ""\n}\n'
		'pkg/use.v':         'module pkg\n\npub fn use_it() string {\n\treturn plat_f()\n}\n'
	})
	assert plain_calls(g, 'use_it', 'plat_f') == ['pkg.plat_f:extracted']
}

fn test_a_renamed_global_takes_its_type_reference_with_it() {
	// `fn work() int` never names OnlyGlobal: the global's edge isn't the function's
	g := extract_graph_of({
		'lib/a/a.v': 'module a\n\nstruct OnlyGlobal {}\n\n__global work fn () OnlyGlobal\n\nfn work() int {\n\treturn 2\n}\n'
	})
	refs := g.edges.filter(it.kind == .references && it.to == 'lib.a.OnlyGlobal').map(it.from)
	assert refs == ['lib.a::global::work']
}

fn test_a_function_the_caller_cannot_see_leaves_its_own_alias_the_conversion() {
	// compiled: a `module main` test's own alias, beside `module foo`'s function of the name
	g := extract_graph_of({
		'lib/foo.v':      'module foo\n\npub fn conv(i int) string {\n\treturn ""\n}\n'
		'lib/foo_test.v': '@[translated]\nmodule main\n\ntype conv = int\n\nfn test_it() {\n\tconv(1)\n}\n'
	})
	assert plain_calls(g, 'test_it', 'conv') == ['lib.conv@lib/foo_test.v:inferred']
}

fn test_a_method_call_is_no_held_function_or_conversion() {
	g := extract_graph_of({
		'lib/a/a.v': '@[translated]\nmodule a\n\nstruct S {}\n\npub fn (s S) token() {}\n\nstruct token {}\n\n__global (\n\tfunc2 = fn () {}\n)\n\nfn on_type(s S) {\n\ts.token()\n}\n\nfn on_unknown(x Unknown) {\n\tx.func2()\n}\n\nfn bare_conv() {\n\ttoken(0)\n}\n'
	})
	assert plain_calls(g, 'on_type', 'token') == ['lib.a.S.token:extracted']
	assert plain_calls(g, 'on_unknown', 'func2') == ['func2:extracted']
	assert plain_calls(g, 'bare_conv', 'token') == ['lib.a.token:inferred']
}

fn test_the_clauses_of_the_new_rules_each_decide_something() {
	g := extract_graph_of({
		// a module beside the file is in the caller's own directory, and a const reaches it too
		'app/run/main.v':     'module main\n\nimport c\n\nfn main() {\n\tc.tst()\n\tc.held()\n}\n'
		'app/run/c.v':        'module c\n\npub const held = fn () {}\n'
		'app/elsewhere/x.v':  'module c\n\npub fn tst() {}\n'
		// a global sharing its id with a type moves too
		'lib/ty/t.v':         '@[translated]\nmodule ty\n\nstruct gt {}\n\n__global (\n\tgt = fn () {}\n)\n'
		// a test sees a `module main` file of its directory, for a global and a type
		'lib/w/common.v':     '@[translated]\nmodule main\n\n__global (\n\thelp = fn () {}\n)\n\nstruct ty_w {}\n'
		'lib/w/t_test.v':     'module main\n\nfn test_w() {\n\thelp()\n\tty_w(0)\n}\n'
		'lib/z/z.v':          'module z\n\npub fn help() {}\n\npub fn ty_w() {}\n'
	})
	assert plain_calls(g, 'main', 'tst') == ['c.tst:extracted']
	assert plain_calls(g, 'main', 'held') == ['app.run.held:extracted']
	assert g.symbols.filter(it.name == 'gt').map(it.id).sorted() == ['lib.ty.gt', 'lib.ty::global::gt'].sorted()
	assert plain_calls(g, 'test_w', 'help') == ['lib.w.help:inferred']
	assert plain_calls(g, 'test_w', 'ty_w') == ['lib.w.ty_w:inferred']
}

fn test_a_conversion_of_the_module_takes_a_call_only_from_a_function_it_cant_see() {
	// a function of the module keeps `foo(1)` from its type, as on master, though compiled, V
	// converts; and an enum of the module wins over an imported alias of its name
	g := extract_graph_of({
		'lib/a/a.v':       '@[translated]\nmodule a\n\ntype foo = int\n\nfn foo(x int) string {\n\treturn ""\n}\n\nfn run() {\n\tfoo(1)\n}\n'
		'lib/m/m.v':       '@[translated]\nmodule m\n\npub type token = int\n'
		'lib/own/own.v':   '@[translated]\nmodule own\n\nimport m\n\nenum token {\n\tzero\n}\n\nfn conv() {\n\ttoken(1)\n}\n'
		// a test of builtin's own is no function of builtin: `tt` is still the conversion
		'vlib/builtin/p_test.v': 'module builtin\n\nfn tt() {}\n\nfn test_p() {}\n'
		'lib/tt/t.v':      '@[translated]\nmodule tt\n\nstruct tt {}\n\nfn conv_tt() {\n\ttt(0)\n}\n\nstruct meth_t {}\n\nfn conv_m() {\n\tmeth_t(0)\n}\n'
		// nor is a method of builtin's a function a bare call can reach
		'vlib/builtin/s.v': 'module builtin\n\npub struct Str {}\n\npub fn (s Str) meth_t() {}\n'
	})
	assert plain_calls(g, 'run', 'foo') == ['lib.a.foo:extracted']
	assert plain_calls(g, 'conv', 'token') == ['lib.own.token:inferred']
	assert plain_calls(g, 'conv_tt', 'tt') == ['lib.tt.tt:inferred']
	assert plain_calls(g, 'conv_m', 'meth_t') == ['lib.tt.meth_t:inferred']
}

const which_types = 'pub struct Rrr {}\n\npub fn (r Rrr) which() string {\n\treturn ""\n}\n\npub struct Sss {}\n\npub fn (r Sss) which() string {\n\treturn ""\n}\n'

// calls_from_file are the calls of `name` from the function `from` in `file`, a program's own
fn calls_from_file(g Graph, from string, file string, name string) []string {
	mut found := g.edges.filter(it.kind == .calls && it.from.all_before('@').all_after_last('.') == from
		&& it.file == file && it.to.all_before('@').all_after_last('.') == name).map(it.to)
	found.sort()
	return found
}

fn test_a_generic_function_of_the_module_is_the_call_not_a_conversion() {
	// compiled: `foo(1)` and `foo[int](1)` print `in generic` and the value is an Rrr, under an
	// alias, an enum or a struct of the name, though a plain function of the name loses to it
	g := extract_graph_of({
		'lib/m/a.v': '@[translated]\nmodule m\n\npub type foo = int\n'
		'lib/m/c.v': 'module m\n\n${which_types}\npub fn foo[T](x T) Rrr {\n\treturn Rrr{}\n}\n'
		'lib/m/b.v': '@[translated]\nmodule m\n\nfn run() {\n\tx := foo(1)\n\tx.which()\n}\n\nfn run_args() {\n\tx := foo[int](1)\n\tx.which()\n}\n'
	})
	for from in ['run', 'run_args'] {
		assert plain_calls(g, from, 'which') == ['lib.m.Rrr.which:inferred'], from
		// the function: the type's edge would be inferred
		assert plain_calls(g, from, 'foo') == ['lib.m.foo:extracted'], from
	}
}

fn test_a_method_of_the_receiver_is_the_call_not_a_conversion_or_a_held_function() {
	// compiled: each prints `in method`, the bare call in a method of Box[U] being its own
	typ := extract_graph_of({
		'lib/m/a.v': '@[translated]\nmodule m\n\npub struct describe {\n\ta int\n}\n\n${which_types}\npub struct Box[U] {\n\titem U\n}\n'
		'lib/m/b.v': 'module m\n\npub fn (b Box[U]) describe(v int) Rrr {\n\treturn Rrr{}\n}\n\npub fn (b Box[U]) imp() string {\n\tx := describe(1)\n\treturn x.which()\n}\n'
	})
	assert plain_calls(typ, 'imp', 'which') == ['lib.m.Rrr.which:inferred']
	assert plain_calls(typ, 'imp', 'describe').len == 1
	assert plain_calls(typ, 'imp', 'describe')[0].contains('Box')
	// another type's method of the name in the file leaves the call to the tier of the receiver's own
	ambiguous := extract_graph_of({
		'lib/a/a.v': '@[translated]\nmodule a\n\npub struct describe {\n\ta int\n}\n\npub struct Box[U] {\n\titem U\n}\n'
		'lib/a/b.v': 'module a\n\npub struct Other {}\n\npub fn (o Other) describe(v int) int {\n\treturn v\n}\n\npub fn (b Box[U]) describe(v int) int {\n\treturn v\n}\n\npub fn (b Box[U]) imp() {\n\tdescribe(1)\n}\n'
	})
	assert plain_calls(ambiguous, 'imp', 'describe').len == 1
	assert plain_calls(ambiguous, 'imp', 'describe')[0].contains('Box')
	held := extract_graph_of({
		'lib/k/a.v': 'module k\n\n${which_types}\npub struct Box[U] {\n\titem U\n}\n\nconst describe = fn (x int) Rrr {\n\treturn Rrr{}\n}\n'
		'lib/k/b.v': 'module k\n\npub fn (b Box[U]) describe(v int) Rrr {\n\treturn Rrr{}\n}\n\npub fn (b Box[U]) imp() string {\n\tx := describe(1)\n\treturn x.which()\n}\n'
	})
	assert plain_calls(held, 'imp', 'which') == ['lib.k.Rrr.which:inferred']
	assert plain_calls(held, 'imp', 'describe')[0].contains('Box')
	// the same in a method of a struct that isn't generic, as on master, though compiled, V converts:
	// a receiver's method of the name is a function the caller sees
	plain := extract_graph_of({
		'lib/p/p.v': '@[translated]\nmodule p\n\nstruct Box {}\n\ntype describe = int\n\nfn (b Box) describe(v int) string {\n\treturn ""\n}\n\nfn (b Box) imp() {\n\tdescribe(1)\n}\n'
	})
	assert plain_calls(plain, 'imp', 'describe').len == 1
	assert plain_calls(plain, 'imp', 'describe')[0].contains('Box')
}

fn test_a_type_of_one_platform_or_flag_takes_no_call_from_a_function() {
	// compiled without `-d custom`: `in fn`, and the value is an Rrr
	g := extract_graph_of({
		'lib/m/a_d_custom.v': '@[translated]\nmodule m\n\npub type foo = int\n'
		'lib/m/c.v':          'module m\n\n${which_types}\npub fn foo(x int) Rrr {\n\treturn Rrr{}\n}\n'
		'lib/m/b.v':          '@[translated]\nmodule m\n\nfn run() {\n\tx := foo(1)\n\tx.which()\n}\n'
	})
	assert plain_calls(g, 'run', 'which') == ['lib.m.Rrr.which:inferred']
	// nor one in the caller's own file: a function the caller sees keeps the call
	own := extract_graph_of({
		'lib/m/a_d_custom.v': '@[translated]\nmodule m\n\npub type foo = int\n\nfn run() {\n\tfoo(1)\n}\n'
		'lib/m/c.v':          'module m\n\npub fn foo(x int) int {\n\treturn x\n}\n'
	})
	assert plain_calls(own, 'run', 'foo') == ['lib.m.foo:extracted']
}

fn test_a_function_literal_sees_only_the_locals_it_captures() {
	// compiled: `f` in a literal that doesn't capture it is the module's function, so `Rrr`
	g := graph_of({
		'lib/m/a.v': 'module m\n\n${which_types}\nfn f(x int) Rrr {\n\treturn Rrr{}\n}\n\nfn mks(x int) Sss {\n\treturn Sss{}\n}\n\nfn none_captured() string {\n\tf := mks\n\t_ = f\n\tg := fn () string {\n\t\tx := f(1)\n\t\treturn x.which()\n\t}\n\treturn g()\n}\n\nfn other_captured() string {\n\tf := mks\n\ty := 1\n\t_ = f\n\tg := fn [y] () string {\n\t\t_ = y\n\t\tx := f(1)\n\t\treturn x.which()\n\t}\n\treturn g()\n}\n\nfn param_uncaptured(f fn (int) Sss) string {\n\t_ = f\n\tg := fn () string {\n\t\tx := f(1)\n\t\treturn x.which()\n\t}\n\treturn g()\n}\n\nfn captured(s Sss, mut r Sss) string {\n\tg := fn [s, mut r] () string {\n\t\treturn s.which() + r.which()\n\t}\n\treturn g()\n}\n'
	})
	assert plain_calls(g, 'none_captured', 'which') == ['lib.m.Rrr.which:inferred']
	assert plain_calls(g, 'other_captured', 'which') == ['lib.m.Rrr.which:inferred']
	assert plain_calls(g, 'param_uncaptured', 'which') == ['lib.m.Rrr.which:inferred']
	// what it does capture it still has
	assert plain_calls(g, 'captured', 'which').map(it.all_before(':')) == ['lib.m.Sss.which']
	// compiled: and it keeps what a field of it was narrowed to, which prints Aaa
	narrowed := graph_of({
		'lib/n/n.v': 'module n\n\nstruct Aaa {}\n\nfn (a Aaa) which() string {\n\treturn ``\n}\n\nstruct Bbb {}\n\nfn (b Bbb) which() string {\n\treturn ``\n}\n\ntype Sum = Aaa | Bbb\n\nstruct Sss {\n\tk Sum\n}\n\nfn t(s Sss) string {\n\tif s.k is Aaa {\n\t\tg := fn [s] () string {\n\t\t\treturn s.k.which()\n\t\t}\n\t\treturn g()\n\t}\n\treturn ``\n}\n'
	})
	assert plain_calls(narrowed, 't', 'which') == ['lib.n.Aaa.which:inferred']
}

fn test_a_held_function_is_read_from_the_const_the_caller_sees() {
	// compiled: `v b.v` prints Bx.hello. A const's id is shared by every file of a directory.
	types := 'pub struct Ax {}\n\npub fn (a Ax) hello() string {\n\treturn ""\n}\n\npub struct Bx {}\n\npub fn (b Bx) hello() string {\n\treturn ""\n}\n'
	g := extract_graph_of({
		'app/t.v': 'module app\n\n${types}'
		'pr/a.v':  '${types}\nconst kf = fn () Ax {\n\treturn Ax{}\n}\n\nfn main() {\n\tx := kf()\n\tx.hello()\n}\n'
		'pr/b.v':  '${types}\nconst kf = fn () Bx {\n\treturn Bx{}\n}\n\nfn main() {\n\tx := kf()\n\tx.hello()\n}\n'
	})
	assert calls_from_file(g, 'main', 'pr/a.v', 'hello').all(it.contains('Ax.hello'))
	assert calls_from_file(g, 'main', 'pr/b.v', 'hello').all(it.contains('Bx.hello'))
	assert calls_from_file(g, 'main', 'pr/b.v', 'hello').len == 1
	// compiled on Windows: each platform's run uses its own file's const
	plat := extract_graph_of({
		'lib/x/t.v':         'module x\n\n${types}'
		'lib/x/x_linux.c.v': 'module x\n\nconst kf = fn () Ax {\n\treturn Ax{}\n}\n\npub fn run() string {\n\tx := kf()\n\treturn x.hello()\n}\n'
		'lib/x/x_windows.c.v': 'module x\n\nconst kf = fn () Bx {\n\treturn Bx{}\n}\n\npub fn run() string {\n\tx := kf()\n\treturn x.hello()\n}\n'
	})
	mut linked := plain_calls(plat, 'run', 'hello').map(it.all_before(':'))
	linked.sort()
	assert linked == ['lib.x.Ax.hello', 'lib.x.Bx.hello']
}

fn test_a_const_of_a_builtin_file_beside_a_program_is_seen() {
	// compiled, `v .`: a `module builtin` file is in the program, and prints Rx.hello
	g := extract_graph_of({
		'app/b.v':    'module builtin\n\npub struct Rx {}\n\npub fn (r Rx) hello() string {\n\treturn ""\n}\n\npub struct Rz {}\n\npub fn (r Rz) hello() string {\n\treturn ""\n}\n\npub const kk = Rx{}\n\npub const kz = Rz{}\n'
		'app/main.v': 'module main\n\nfn main() {\n\tc := kk\n\tc.hello()\n}\n'
	})
	assert plain_calls(g, 'main', 'hello') == ['app.Rx.hello:inferred']
}

fn test_a_module_importing_its_own_short_name_does_not_call_itself() {
	// compiled: a wrapper `module bar` with `import a.bar` reaches a.bar, not itself, and the
	// import outside the graph leaves the raw name
	g := extract_graph_of({
		'w/bar/bar.v': 'module bar\n\nimport a.bar\n\npub fn hello() string {\n\treturn bar.hello()\n}\n'
	})
	assert plain_calls(g, 'hello', 'hello') == ['a.bar.hello:extracted']
}

fn test_a_test_with_no_module_line_is_not_built_with_a_main_helper() {
	// compiled: V builds a helper in only when the test writes `module main`, so these are the
	// test's own `pick` and `foo`, and builtin's `copy`
	helper := '@[translated]\nmodule main\n\nconst pick = fn () string {\n\treturn ""\n}\n\nconst copy = fn (mut d []u8, s []u8) int {\n\treturn 99\n}\n\ntype foo = int\n'
	g := extract_graph_of({
		'vlib/builtin/a.v': builtin_fns
		'p/common.v':       helper
		'p/x_test.v':       'fn pick() string {\n\treturn ""\n}\n\nfn foo(x int) string {\n\treturn ""\n}\n\nfn test_a() {\n\tpick()\n\tfoo(1)\n\tcopy(mut d, b)\n}\n'
	})
	assert plain_calls(g, 'test_a', 'pick') == ['p.pick:extracted']
	assert plain_calls(g, 'test_a', 'foo') == ['p.foo@p/x_test.v:extracted']
	assert plain_calls(g, 'test_a', 'copy')[0].starts_with('vlib.builtin.copy:')
	// one writing it is
	w := extract_graph_of({
		'vlib/builtin/a.v': builtin_fns
		'p/common.v':       helper
		'p/x_test.v':       'module main\n\nfn test_a() {\n\tpick()\n}\n'
	})
	// with no function of the name, the const's id is the plain one
	assert plain_calls(w, 'test_a', 'pick') == ['p.pick:inferred']
}

fn test_the_value_of_builtins_function_over_an_own_type_is_builtins() {
	// as on master, builtin's function keeps the call, so the value has its result, though compiled,
	// V converts and panics on `v.msg()`
	g := extract_graph_of({
		'vlib/builtin/a.v': builtin_fns
		'lib/own/own.v':    '@[translated]\nmodule own\n\nstruct error {\n\tx int\n}\n\nfn (e error) msg() string {\n\treturn ""\n}\n\nfn val() {\n\tv := error("a")\n\tv.msg()\n}\n'
	})
	assert plain_calls(g, 'val', 'msg') == ['vlib.builtin.IError.msg:inferred']
}

fn test_a_type_of_a_module_beside_a_program_is_read_by_its_own_file() {
	// compiled in directory mode: prints `fn`. Whether a type's file is a `module main` one is
	// that file's, not the caller's
	bare := extract_graph_of({
		'solo/main.v': 'module main\n\nfn main() {\n\ttoken(0)\n}\n'
		'solo/lib.v':  '@[translated]\nmodule lib\n\npub enum token {\n\tzero\n}\n'
	})
	assert plain_calls(bare, 'main', 'token') == ['token:extracted']
	g := extract_graph_of({
		'solo/main.v': 'module main\n\nfn token(x int) string {\n\treturn ""\n}\n\nfn main() {\n\ttoken(0)\n}\n'
		'solo/lib.v':  '@[translated]\nmodule lib\n\npub enum token {\n\tzero\n}\n'
	})
	assert plain_calls(g, 'main', 'token').len == 1
	assert plain_calls(g, 'main', 'token')[0].contains('main.v')
}

fn test_a_test_with_no_module_line_reads_no_const_of_a_main_helper() {
	// compiled: such a test can't read the helper's const, and one writing `module main` can,
	// so of a const builtin has too, it reads builtin's
	builtin_const := 'module builtin\n\npub struct Rx {}\n\npub fn (r Rx) hello() {}\n\npub struct Rz {}\n\npub fn (r Rz) hello() {}\n\npub const kk = Rx{}\n'
	g := extract_graph_of({
		'vlib/builtin/a.v': builtin_const
		'p/common.v':       'module main\n\nconst kk = Rz{}\n'
		'p/x_test.v':       'fn test_a() {\n\tc := kk\n\tc.hello()\n}\n'
	})
	assert plain_calls(g, 'test_a', 'hello') == ['vlib.builtin.Rx.hello:inferred']
}

fn test_a_generic_function_elsewhere_does_not_stop_a_conversion() {
	// one of another module, or of a `module lib` file beside a program, is no function of
	// the caller's: `tok(1)` is still the conversion
	g := extract_graph_of({
		'lib/x/x.v':    'module x\n\npub fn tok[T](v T) int {\n\treturn 0\n}\n'
		'lib/own/o.v':  '@[translated]\nmodule own\n\nimport x\n\nenum tok {\n\tzero\n}\n\nfn conv() {\n\ttok(1)\n}\n'
		'solo/main.v':  '@[translated]\nmodule main\n\nenum tk {\n\tzero\n}\n\nfn main() {\n\ttk(0)\n}\n'
		'solo/lib.v':   'module lib\n\npub fn tk[T](v T) int {\n\treturn 0\n}\n'
	})
	assert plain_calls(g, 'conv', 'tok') == ['lib.own.tok:inferred']
	assert plain_calls(g, 'main', 'tk').len == 1
	assert plain_calls(g, 'main', 'tk')[0].ends_with(':inferred')
}

fn test_a_test_with_no_module_line_beside_one_main_is_built_alone() {
	// compiled: the test's own `pick` and builtin's `copy`, though main.v declares each. One
	// writing `module main` is built with main.v
	main_v := 'module main\n\nconst pick = fn () string {\n\treturn ""\n}\n\nconst copy = fn (x int) string {\n\treturn ""\n}\n\nfn main() {}\n'
	g := extract_graph_of({
		'vlib/builtin/a.v': builtin_fns
		'p/main.v':         main_v
		'p/x_test.v':       'fn pick() string {\n\treturn ""\n}\n\nfn test_a() {\n\tpick()\n\tcopy(mut d, s)\n}\n'
	})
	assert plain_calls(g, 'test_a', 'pick') == ['p.pick:extracted']
	assert plain_calls(g, 'test_a', 'copy')[0].starts_with('vlib.builtin.copy:')
	w := extract_graph_of({
		'p/main.v':   main_v
		'p/x_test.v': 'module main\n\nfn test_a() {\n\tpick()\n}\n'
	})
	assert plain_calls(w, 'test_a', 'pick') == ['p.pick:inferred']
}

fn test_a_function_of_a_module_beside_a_program_is_not_its_own() {
	// compiled: `copy` of `module lib` beside a program leaves builtin's. Read from the function's
	// own file, as caller's scope would take it for one of the program
	g := extract_graph_of({
		'vlib/builtin/a.v': builtin_fns
		'solo/main.v':      'module main\n\nfn main() {\n\tcopy(mut a, b)\n}\n'
		'solo/lib.v':       'module lib\n\npub fn copy() {}\n'
	})
	assert plain_calls(g, 'main', 'copy')[0].starts_with('vlib.builtin.copy:')
}

fn test_a_template_in_an_expression_sees_the_locals_it_names() {
	// compiled: prints `hello Sss`. The parser writes the literal it lowers `$tmpl` to, and its
	// capture list is no text of the file
	dir := os.join_path(os.temp_dir(), 'graphify_tmpl_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'x.txt'), 'hello @{r.which()}\n') or { panic(err) }
	path := os.join_path(dir, 'a.v')
	os.write_file(path, 'module m\n\n${which_types}\nfn wrap(s string) string {\n\treturn s\n}\n\nfn t() string {\n\tr := Sss{}\n\treturn wrap(\$tmpl("x.txt"))\n}\n') or {
		panic(err)
	}
	mut g := Graph{}
	syms, edges := extract_v_file(path, 'lib/m/a.v')
	g.symbols << syms
	g.edges << edges
	resolve_edges(mut g)
	assert plain_calls(g, 't', 'which').map(it.all_before(':')) == ['lib.m.Sss.which']
}

fn test_a_function_literal_reads_a_comptime_loop_variable_without_a_capture() {
	// compiled: prints NAME. V refuses an uncaptured `for` variable, `err` or `it`, but not this
	g := graph_of({
		'vlib/builtin/s.v': 'module builtin\n\npub struct string {}\n\npub fn (s string) to_upper() string {\n\treturn s\n}\n\npub struct FieldData {\npub:\n\tname string\n}\n'
		'lib/o/o.v':        'module o\n\npub fn (x Other) to_upper() {}\n\npub struct Other {}\n'
		'lib/m/m.v':        'module m\n\nimport o\n\nstruct Foo {\n\tname int\n}\n\nfn t() {\n\t\$for f in Foo.fields {\n\t\tg := fn () string {\n\t\t\treturn f.name.to_upper()\n\t\t}\n\t\t_ = g\n\t}\n}\n'
	})
	assert plain_calls(g, 't', 'to_upper') == ['vlib.builtin.string.to_upper:inferred']
}

fn test_a_held_function_of_one_platforms_file_types_no_call_from_another_file() {
	// each platform's const differs, and a file of neither can't say which it is
	types := 'pub struct Ax {}\n\npub fn (a Ax) hello() {}\n\npub struct Bx {}\n\npub fn (b Bx) hello() {}\n'
	g := extract_graph_of({
		'lib/x/t.v':           'module x\n\n${types}\nfn from_common() {\n\ty := kf()\n\ty.hello()\n}\n'
		'lib/x/x_linux.c.v':   'module x\n\nconst kf = fn () Ax {\n\treturn Ax{}\n}\n'
		'lib/x/x_windows.c.v': 'module x\n\nconst kf = fn () Bx {\n\treturn Bx{}\n}\n'
	})
	assert plain_calls(g, 'from_common', 'hello') == ['hello:extracted']
}

fn test_a_global_of_a_written_fn_type_holds_a_function() {
	// a function of another module doesn't take the call, and the value has the type's result
	g := extract_graph_of({
		'lib/a/a.v': 'module a\n\nstruct Rrr {}\n\nfn (r Rrr) which() {}\n\nstruct Sss {}\n\nfn (s Sss) which() {}\n\n__global work fn (int) Rrr\n\nfn run() {\n\ty := work(1)\n\ty.which()\n}\n'
		'lib/b/b.v': 'module b\n\npub fn work(x int) int {\n\treturn x\n}\n'
	})
	assert plain_calls(g, 'run', 'work') == ['lib.a.work:inferred']
	assert plain_calls(g, 'run', 'which') == ['lib.a.Rrr.which:inferred']
}

fn test_a_program_with_no_module_line_is_built_with_its_helper() {
	// compiled, `v run .`: only a test with no `module` line is built alone
	g := extract_graph_of({
		'p/a.v': 'fn main() {\n\thelper()\n}\n'
		'p/b.v': 'module main\n\nconst helper = fn () string {\n\treturn ""\n}\n'
		'q/o.v': 'module o\n\npub fn helper() {}\n'
	})
	assert plain_calls(g, 'main', 'helper') == ['p.helper:inferred']
}

fn test_a_capture_list_is_read_past_comments_and_line_breaks() {
	// compiled: each calls the captured local, and `b.m()` is the captured Baz's
	for list in ['/* c */ [f]', '\n\t[f]', '[mut\tf]', '[\n\tg, // count\n\tf,\n]', '[f /* the local */]'] {
		g := graph_of({
			'lib/m/a.v': 'module m\n\nfn f(x int) int {\n\treturn x\n}\n\nfn caller() {\n\tmut f := fn (x int) string {\n\t\treturn ""\n\t}\n\tg := 1\n\t_ = g\n\th := fn ${list} () {\n\t\tf(1)\n\t}\n\th()\n}\n'
		})
		assert plain_calls(g, 'caller', 'f') == ['f:undeclared'], list
	}
	g := graph_of({
		'lib/m/a.v': 'module m\n\nstruct Baz {}\n\nfn (b Baz) m() {}\n\nstruct Qux {}\n\nfn (q Qux) m() {}\n\nfn caller() {\n\tb := Baz{}\n\th := fn /* c */ [b] () {\n\t\tb.m()\n\t}\n\th()\n}\n'
	})
	assert plain_calls(g, 'caller', 'm').map(it.all_before(':')) == ['lib.m.Baz.m']
}

fn test_a_type_takes_no_call_the_lookup_leaves_open_between_functions_the_caller_sees() {
	// compiled: prints Baz, the .c.v copy, so the enum isn't what it calls, and the raw name stays
	g := extract_graph_of({
		'p/a.v':   '@[translated]\nmodule main\n\nenum tok {\n\ta\n\tb\n}\n\nfn caller() {\n\ttok(1)\n}\n\nfn main() {}\n'
		'p/f.c.v': 'module main\n\nstruct Baz {}\n\nfn tok(x int) Baz {\n\treturn Baz{}\n}\n'
		'p/f.js.v': 'module main\n\nstruct Baz2 {}\n\nfn tok(x int) Baz2 {\n\treturn Baz2{}\n}\n'
	})
	assert plain_calls(g, 'caller', 'tok') == ['tok:extracted']
}

fn test_a_function_of_a_program_beside_a_second_main_is_one_the_caller_may_see() {
	// compiled: each prints Baz, a function of a sibling file, though the directory has a second `fn
	// main`, one per platform or in a test. The type keeps no call from it
	helper := '@[translated]\nmodule main\n\nstruct Baz {}\n\nfn tok(x int) Baz {\n\treturn Baz{}\n}\n'
	common := '@[translated]\nmodule main\n\ntype tok = int\n\nfn caller() {\n\ttok(1)\n}\n'
	plat := extract_graph_of({
		'p/a_nix.c.v':     'module main\n\nfn main() {}\n'
		'p/a_windows.c.v': 'module main\n\nfn main() {}\n'
		'p/helper.v':      helper
		'p/common.v':      common
	})
	assert plain_calls(plat, 'caller', 'tok') == ['p.tok@p/helper.v:extracted']
	test := extract_graph_of({
		'p/a.v':      'module main\n\nfn main() {}\n'
		'p/z_test.v': 'module main\n\nfn main() {}\n'
		'p/helper.v': helper
		'p/common.v': common
	})
	assert plain_calls(test, 'caller', 'tok') == ['p.tok@p/helper.v:extracted']
	// and the edge and the value agree on the function, with copies for two platforms
	copies := extract_graph_of({
		'p/prog.v':          '@[translated]\nmodule main\n\ntype token = int\n\nstruct Other {}\n\nfn (t token) hi() {}\n\nfn (o Other) hi() {}\n\nfn run() {\n\tx := token(3)\n\tx.hi()\n}\n\nfn main() {}\n'
		'p/second.v':        'module main\n\nfn main() {}\n'
		'p/plat_linux.c.v':   'module main\n\nfn token(i int) Other {\n\treturn Other{}\n}\n'
		'p/plat_windows.c.v': 'module main\n\nfn token(i int) Other {\n\treturn Other{}\n}\n'
	})
	assert plain_calls(copies, 'run', 'hi').map(it.all_before(':').all_before('@')) == ['p.Other.hi']
	assert plain_calls(copies, 'run', 'token').all(it.contains('plat_'))
}

fn test_a_test_outside_its_builtin_copy_leaves_a_call_open_between_two_copies() {
	// `S:/vProjects/native-backend` holds two V clones: a module-less test in one's vlib/builtin
	// must not link to the other's, which it never compiles against
	g := extract_graph_of({
		'a/vlib/builtin/builtin.v': 'module builtin\n\npub fn say() {}\n'
		'b/vlib/builtin/builtin.v': 'module builtin\n\npub fn say() {}\n'
		'a/vlib/builtin/x_test.v':  'fn test_a() {\n\tsay()\n}\n'
		'b/vlib/builtin/y_test.v':  'fn test_b() {\n\tsay()\n}\n'
	})
	assert plain_calls(g, 'test_a', 'say') == ['say:extracted']
	assert plain_calls(g, 'test_b', 'say') == ['say:extracted']
	// with one tree, it is that tree's
	one := extract_graph_of({
		'vlib/builtin/builtin.v': 'module builtin\n\npub fn say() {}\n'
		'vlib/builtin/x_test.v':  'fn test_a() {\n\tsay()\n}\n'
	})
	assert plain_calls(one, 'test_a', 'say')[0].starts_with('vlib.builtin.say:')
}

fn test_a_held_function_is_only_one_the_caller_sees() {
	// V refuses each call, so nothing compiled says what it is: each stays the function a name
	// match finds, not a value out of the caller's sight. Of a test, of another module, and of a
	// `module lib` file beside a program
	two := 'module two\n\npub fn hf() {}\n\npub fn other_g() {}\n\npub fn lp() {}\n'
	g := extract_graph_of({
		'lib/two/far.v':  two
		'lib/app/a.v':    'module app\n\nfn run() {\n\thf()\n\tother_g()\n}\n'
		'lib/app/h_test.v': 'module app\n\nconst hf = fn () {}\n\nfn test_h() {}\n'
		'lib/three/g.v':  'module three\n\npub const other_g = fn () {}\n'
		'solo/main.v':    'module main\n\nfn main() {\n\tlp()\n}\n'
		'solo/lib.v':     'module lib\n\npub const lp = fn () {}\n'
	})
	assert plain_calls(g, 'run', 'hf') == ['lib.two.hf:extracted']
	assert plain_calls(g, 'run', 'other_g') == ['lib.two.other_g:extracted']
	assert plain_calls(g, 'main', 'lp') == ['lib.two.lp:extracted']
}

fn test_the_value_of_a_conversion_is_the_type_of_the_callers_module() {
	g := graph_of({
		'lib/aa/aa.v': 'module aa\n\npub enum token {\n\tzero\n}\n\npub fn (t token) tell() {}\n'
		'lib/gen/g.v': '@[translated]\nmodule gen\n\nenum token {\n\tzero\n}\n\nfn (t token) tell() {}\n\nfn conv() {\n\tx := token(0)\n\tx.tell()\n}\n'
		'lib/tok/t.v': 'module tok\n\npub fn token() {}\n'
	})
	assert plain_calls(g, 'conv', 'tell') == ['lib.gen.token.tell:inferred']
}

fn test_a_const_of_a_builtin_file_of_another_directory_is_not_seen() {
	g := extract_graph_of({
		'other/b.v':  'module builtin\n\npub struct Rx {}\n\npub fn (r Rx) hello() {}\n\npub struct Rz {}\n\npub fn (r Rz) hello() {}\n\npub const kk = Rx{}\n'
		'app/main.v': 'module main\n\nfn main() {\n\tc := kk\n\tc.hello()\n}\n'
	})
	assert plain_calls(g, 'main', 'hello') == ['hello:extracted']
}

fn test_a_function_literal_reads_the_variable_of_any_comptime_loop() {
	// compiled, for `.methods` as for `.fields`: V asks for no capture
	g := graph_of({
		'vlib/builtin/s.v': 'module builtin\n\npub struct string {}\n\npub fn (s string) to_upper() string {\n\treturn s\n}\n\npub struct FunctionData {\npub:\n\tname string\n}\n'
		'lib/o/o.v':        'module o\n\npub fn (x Other) to_upper() {}\n\npub struct Other {}\n'
		'lib/m/m.v':        'module m\n\nimport o\n\nstruct Foo {}\n\nfn t() {\n\t\$for f in Foo.methods {\n\t\tg := fn () string {\n\t\t\treturn f.name.to_upper()\n\t\t}\n\t\t_ = g\n\t}\n}\n'
	})
	assert plain_calls(g, 't', 'to_upper') == ['vlib.builtin.string.to_upper:inferred']
}

fn test_a_test_with_no_module_line_keeps_its_own_const_from_a_helpers_function() {
	// compiled: prints `own const`. It is built alone, so `common.v`'s function is out of its sight
	g := extract_graph_of({
		'p/common.v': 'module main\n\nfn pick() string {\n\treturn ""\n}\n'
		'p/x_test.v': 'const pick = fn () string {\n\treturn ""\n}\n\nfn test_a() {\n\tpick()\n}\n'
		'q/o.v':      'module o\n\npub fn other() {}\n'
	})
	assert plain_calls(g, 'test_a', 'pick') == ['p::const::pick:inferred']
}

fn test_a_function_of_a_builtin_file_beside_a_program_keeps_the_call_from_a_type() {
	// compiled: prints Baz. V compiles a `module builtin` file of the directory in, so the function
	// is one the caller may see
	g := extract_graph_of({
		'src/a.v': '@[translated]\nmodule main\n\ntype tok = int\n\nfn caller() {\n\ttok(1)\n}\n\nfn main() {}\n'
		'src/b.v': 'module builtin\n\npub struct Baz {}\n\npub fn tok(x int) Baz {\n\treturn Baz{}\n}\n'
	})
	assert plain_calls(g, 'caller', 'tok') == ['src.tok@src/b.v:extracted']
}

fn test_a_template_whose_position_holds_fn_text_keeps_its_locals() {
	// compiled: prints `hello Sss`. A lowered template's literal has a position in the text the parser
	// generated, here byte 5 of the file: `fn first`, which is no literal, and `fn (r Zed) ...`, which
	// could start one but doesn't end there.
	dir := os.join_path(os.temp_dir(), 'graphify_tmpl_pos_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'x.txt'), 'hello @{r.which()}\n') or { panic(err) }
	body := '${which_types}\nfn wrap(s string) string {\n\treturn s\n}\n\nfn t() string {\n\tr := Sss{}\n\treturn wrap(\$tmpl("x.txt"))\n}\n'
	calls_with := fn [dir, body] (head string) []string {
		path := os.join_path(dir, 'a.v')
		os.write_file(path, head + body) or { panic(err) }
		mut g := Graph{}
		syms, edges := extract_v_file(path, 'lib/m/a.v')
		g.symbols << syms
		g.edges << edges
		resolve_edges(mut g)
		return plain_calls(g, 't', 'which').map(it.all_before(':'))
	}
	// the literal's span ends at byte 97 here, so these three hold a `}` at byte 96
	no_fn := '// x\n// ( ${'c'.repeat(86)}}\n'
	no_list := '// x\nfn first() {\n// ${'c'.repeat(75)}}\n}\n\n'
	fooled := '// x\nfn (r Zed) later() {\n// ${'c'.repeat(67)}}\n}\n\nstruct Zed {}\n\n'
	for head in ['// x\nfn first() {}\n\n', '// x\nfn (r Zed) later() {}\n\nstruct Zed {}\n\n', no_fn, no_list] {
		assert calls_with(head) == ['lib.m.Sss.which'], head
	}
	// the limit FUTURE_WORK.md discloses: all of a literal's shape there by chance reads as one, and
	// the template loses its locals, where V still prints `hello Sss`
	assert calls_with(fooled) == ['which']
}

fn test_a_comment_in_or_before_a_capture_list_is_no_capture() {
	// compiled: each prints the module's `f`, as the literal doesn't capture the local `f`, whatever a
	// comment beside the list says
	for list in ['// c\n', '/* a /* b */ c */ ', '[g, // f\n]', '[/* f /* f */ f */ g]'] {
		g := graph_of({
			'lib/m/a.v': 'module m\n\nfn f(x int) int {\n\treturn x\n}\n\nfn caller() {\n\tmut f := fn (x int) string {\n\t\treturn ""\n\t}\n\t_ = f\n\tg := 1\n\t_ = g\n\th := fn ${list} () {\n\t\tf(1)\n\t}\n\th()\n}\n'
		})
		assert plain_calls(g, 'caller', 'f') == ['lib.m.f:extracted'], list
	}
}

fn test_an_alias_of_builtin_is_a_conversion_from_any_module() {
	// a type of the caller's own module isn't the only one a bare call converts to
	g := extract_graph_of({
		'vlib/builtin/alias.v': 'module builtin\n\npub type wide_t = int\n'
		'lib/app/app.v':        'module app\n\nfn run() {\n\twide_t(1)\n}\n'
	})
	assert plain_calls(g, 'run', 'wide_t') == ['vlib.builtin.wide_t:inferred']
}

fn test_a_const_naming_a_function_or_holding_a_call_is_not_read_as_holding_one() {
	// not what V does, which calls the const: only a literal or a written `fn` type says a value holds
	// a function, and the disclosed limit leaves the rest to the function lookup
	g := extract_graph_of({
		'lib/a/a.v': 'module a\n\nfn mk() fn () {\n\treturn fn () {}\n}\n\nfn real() {}\n\nconst by_call = mk()\n\nconst by_name = real\n\nfn run() {\n\tby_call()\n\tby_name()\n}\n'
		'lib/b/b.v': 'module b\n\npub fn by_call() {}\n\npub fn by_name() {}\n'
	})
	assert plain_calls(g, 'run', 'by_call') == ['lib.b.by_call:extracted']
	assert plain_calls(g, 'run', 'by_name') == ['lib.b.by_name:extracted']
}

fn test_a_dotted_import_may_name_a_module_beside_the_file() {
	// compiled, `v run .`: prints `beside`, by the last part of the path, though a.c exists and lacks it
	g := extract_graph_of({
		'run/main.v': 'module main\n\nimport a.c\n\nfn main() {\n\tprintln(c.pick())\n}\n'
		'run/c.v':    'module c\n\npub fn pick() string {\n\treturn "beside"\n}\n'
		'a/c/c.v':    'module c\n\npub fn other() string {\n\treturn "real"\n}\n'
	})
	assert plain_calls(g, 'main', 'pick') == ['run.pick:extracted']
}

fn test_a_copy_in_a_top_level_if_of_a_test_is_built_alone_too() {
	// such a copy's site is kept per file: it still says the test has no `module` line
	g := extract_graph_of({
		'p/common.v': 'module main\n\nfn pick() string {\n\treturn ""\n}\n'
		'p/x_test.v': 'const pick = fn () string {\n\treturn ""\n}\n\n\$if linux {\n\tfn go_on() {\n\t\tpick()\n\t}\n} \$else {\n\tfn go_on() {\n\t\tpick()\n\t}\n}\n\nfn test_a() {\n\tgo_on()\n}\n'
		'q/o.v':      'module o\n\npub fn other() {}\n'
	})
	assert plain_calls(g, 'go_on', 'pick') == ['p::const::pick:inferred']
}

// `c'x'` is a C string, which the parser keeps as a char literal. It is a `&u8`: `typeof` says so on both compilers, and their C calls u8's `vstring`. Compiled, `a.vstring()`,
// `msg.vstring()` on a const holding one and the same on `&c'hello'[1]` print `x`, `test`, `ello`.
fn test_a_c_string_literal_is_a_u8_pointer() {
	builtin := 'module builtin\n\npub struct string {}\n\npub fn (cp &char) vstring() string {\n\treturn ""\n}\n\npub fn (bp &u8) vstring() string {\n\treturn ""\n}\n\npub fn (r rune) vstring() string {\n\treturn ""\n}\n'
	g := extract_graph_of({
		'vlib/builtin/b.v': builtin
		'p/a.v':            'module main\n\nconst msg = c\'test\'\n\nfn local() {\n\ta := c\'x\'\n\ta.vstring()\n}\n\nfn from_const() {\n\tmsg.vstring()\n}\n\nfn indexed() {\n\tt := unsafe { &c\'hello\'[1] }\n\tt.vstring()\n}\n\nfn plain_rune() {\n\tr := `x`\n\tr.vstring()\n}\n\nfn in_an_array() {\n\txs := [c\'a\', c\'b\']\n\txs[1].vstring()\n}\n\nfn runes_in_an_array() {\n\trs := [`a`]\n\trs[0].vstring()\n}\n\nfn in_a_map() {\n\tm := {\n\t\t\'k\': c\'v\'\n\t}\n\tfor _, v in m {\n\t\tv.vstring()\n\t}\n}\n\nfn runes_in_a_map() {\n\tm := {\n\t\t\'k\': `v`\n\t}\n\tfor _, v in m {\n\t\tv.vstring()\n\t}\n}\n\nfn main() {}\n'
	})
	assert plain_calls(g, 'in_a_map', 'vstring') == ['vlib.builtin.u8.vstring:inferred']
	assert plain_calls(g, 'runes_in_a_map', 'vstring') == ['vlib.builtin.rune.vstring:inferred']
	assert plain_calls(g, 'in_an_array', 'vstring') == ['vlib.builtin.u8.vstring:inferred']
	assert plain_calls(g, 'runes_in_an_array', 'vstring') == ['vlib.builtin.rune.vstring:inferred']
	assert plain_calls(g, 'local', 'vstring') == ['vlib.builtin.u8.vstring:inferred']
	assert plain_calls(g, 'from_const', 'vstring') == ['vlib.builtin.u8.vstring:inferred']
	assert plain_calls(g, 'indexed', 'vstring') == ['vlib.builtin.u8.vstring:inferred']
	// a rune literal stays a rune
	assert plain_calls(g, 'plain_rune', 'vstring') == ['vlib.builtin.rune.vstring:inferred']
}

// compiled: after `import mod { Box }`, `Box.make()` prints `mod.Box.make`, and another
// module's `Box` with a `make` of its own doesn't take the call
fn test_a_static_call_through_a_selective_import_is_the_imported_modules() {
	g := extract_graph_of({
		'mod/mod.v':   'module mod\n\npub struct Box {}\n\npub fn Box.make() {}\n\npub enum Kind {\n\ta\n}\n'
		'other/o.v':   'module other\n\npub struct Box {}\n\npub fn Box.make() {}\n'
		'app/main.v':  'module main\n\nimport mod { Box, Kind }\nimport other\n\nfn go_on() {\n\tBox.make()\n}\n\nfn from_text() {\n\tKind.from_string("a") or { return }\n}\n\nfn through_other() {\n\tother.Box.make()\n}\n\nfn main() {}\n'
	})
	assert plain_calls(g, 'go_on', 'Box__static__make') == ['mod.Box__static__make:extracted']
	assert plain_calls(g, 'through_other', 'Box__static__make') == ['other.Box__static__make:extracted']
	// V writes an enum's from_string, in the module the import names
	assert plain_calls(g, 'from_text', 'Kind__static__from_string') == ['mod.Kind__static__from_string:undeclared']
}

// compiled: `MyAlias.new()` after `type MyAlias = MyStruct` prints `MyStruct.new`, and
// `MyAlias.new` when the alias declares its own
fn test_a_static_call_through_an_alias_reaches_the_type_unless_the_alias_has_its_own() {
	g := extract_graph_of({
		'p/a.v': 'module main\n\nstruct MyStruct {}\n\nfn MyStruct.new() MyStruct {\n\treturn MyStruct{}\n}\n\nfn (m MyStruct) hi() {}\n\ntype MyAlias = MyStruct\n\nstruct Owner {}\n\nfn Owner.new() {}\n\ntype Own = Owner\n\nfn Own.new() {}\n\nfn through() {\n\tMyAlias.new()\n}\n\nfn own() {\n\tOwn.new()\n}\n\nfn value() {\n\tv := MyAlias.new()\n\tv.hi()\n}\n\nfn main() {}\n'
		'q/o.v': 'module q\n\npub struct MyStruct {}\n\npub fn MyStruct.new() {}\n\npub fn (m MyStruct) hi() {}\n'
	})
	assert plain_calls(g, 'through', 'MyStruct__static__new') == ['p.MyStruct__static__new:inferred']
	assert plain_calls(g, 'own', 'Own__static__new') == ['p.Own__static__new:extracted']
	// the value of the call has the type's result, as the edge reads the call
	assert plain_calls(g, 'value', 'hi') == ['p.MyStruct.hi:inferred']
}

// compiled with V3: `.str()` on `union {}`, `union { number: 7 }` and `struct { number: 8 }`
// print the value. No declaration has them, so another type's `str` doesn't take the call.
fn test_str_on_an_anonymous_struct_or_union_is_one_v_writes() {
	g := extract_graph_of({
		'p/a.v': 'module main\n\nstruct Other {}\n\nfn (o Other) str() string {\n\treturn ""\n}\n\nfn empty() {\n\tv := union {}\n\tv.str()\n}\n\nfn typed() {\n\tv := union {\n\t\tnumber: 7\n\t}\n\tv.str()\n}\n\nfn from_local() {\n\ttext := "x"\n\tv := union {\n\t\ttext: text\n\t}\n\tv.str()\n}\n\nfn a_struct() {\n\tv := struct {\n\t\tnumber: 8\n\t}\n\tv.str()\n}\n\nfn a_method_it_lacks() {\n\tv := union {}\n\tv.other()\n}\n\nfn main() {}\n'
		'q/o.v': 'module q\n\npub struct Q {}\n\npub fn (o Q) str() string {\n\treturn ""\n}\n'
	})
	for caller in ['empty', 'typed', 'from_local', 'a_struct'] {
		assert plain_calls(g, caller, 'str') == ['str:undeclared'], caller
	}
	assert plain_calls(g, 'a_method_it_lacks', 'other') == ['other:extracted']
}

// compiled: through `type Aaa = Bbb` and `type Bbb = Ccc`, V3 prints `Bbb.new` for `Aaa.new()`, and
// `-old-compiler` prints `Ccc.new`. V3 looks one alias deep, so it refuses `Aaa.end()`, which only
// Ccc declares and `-old-compiler` prints `Ccc.end` for. The first type that declares it is taken.
fn test_a_static_call_through_a_chain_of_aliases_is_the_first_that_declares_it() {
	g := extract_graph_of({
		'p/a.v': 'module main\n\nstruct Ccc {}\n\nfn Ccc.new() {}\n\nfn Ccc.end() {}\n\ntype Bbb = Ccc\n\nfn Bbb.new() {}\n\ntype Aaa = Bbb\n\nfn middle() {\n\tAaa.new()\n}\n\nfn end_of_chain() {\n\tAaa.end()\n}\n\nfn no_such() {\n\tAaa.none_declares()\n}\n\nfn main() {}\n'
	})
	assert plain_calls(g, 'middle', 'Bbb__static__new') == ['p.Bbb__static__new:inferred']
	assert plain_calls(g, 'middle', 'Ccc__static__new') == []
	assert plain_calls(g, 'end_of_chain', 'Ccc__static__end') == ['p.Ccc__static__end:inferred']
	assert plain_calls(g, 'no_such', 'Aaa__static__none_declares') == ['Aaa__static__none_declares:extracted']
}

// compiled: each prints `mod.Box.hi`, though the caller's module has a Box too, and another
// module's type of the alias's own name takes neither the call nor its value
fn test_a_static_call_through_an_alias_of_another_module_reads_each_in_its_own_scope() {
	g := extract_graph_of({
		'mod/m.v':    'module mod\n\npub struct Box {}\n\npub fn Box.make() Box {\n\treturn Box{}\n}\n\npub fn (b Box) hi() {}\n\npub type Aaa = Box\n'
		'q/q.v':      'module q\n\npub struct Local {}\n\npub fn Local.make() Local {\n\treturn Local{}\n}\n\npub fn (l Local) hi() {}\n'
		'app/main.v': 'module main\n\nimport mod { Aaa }\n\nstruct Box {}\n\nfn Box.make() Box {\n\treturn Box{}\n}\n\nfn (b Box) hi() {}\n\ntype Local = mod.Box\n\nfn selected() {\n\tx := Aaa.make()\n\tx.hi()\n}\n\nfn qualified() {\n\tx := mod.Aaa.make()\n\tx.hi()\n}\n\nfn local() {\n\tx := Local.make()\n\tx.hi()\n}\n\nfn main() {}\n'
	})
	for caller in ['selected', 'qualified', 'local'] {
		assert plain_calls(g, caller, 'Box__static__make') == ['mod.Box__static__make:inferred'], caller
		assert plain_calls(g, caller, 'hi') == ['mod.Box.hi:inferred'], caller
	}
	assert plain_calls(g, 'local', 'Local__static__make') == []
}

// one call through an alias, on two lines, is one edge with both lines
fn test_two_static_calls_through_an_alias_are_one_edge() {
	g := extract_graph_of({
		'p/a.v': 'module main\n\nstruct Sss {}\n\nfn Sss.new() {}\n\ntype Aaa = Sss\n\ntype Bbb = Sss\n\nfn twice() {\n\tAaa.new()\n\tBbb.new()\n}\n\nfn main() {}\n'
	})
	edges := g.edges.filter(it.kind == .calls && it.to == 'p.Sss__static__new')
	assert edges.len == 1
	assert edges[0].lines == [12, 13]
}

// compiled: `SSLConn.new()` prints `mbd`, and `opn` with `-d use_opn`, as does `c.hi()` after it.
// A static only one build's type has is that build's alone, and an alias every build shares
// puts no build on the call.
fn test_a_static_call_through_an_alias_each_build_declares_reaches_each_builds_type() {
	g := extract_graph_of({
		'opn/opn.v':             'module opn\n\npub struct Conn {}\n\npub fn Conn.new() &Conn {\n\treturn &Conn{}\n}\n\npub fn Conn.only() {}\n\npub fn (c &Conn) hi() {}\n'
		'mbd/mbd.v':             'module mbd\n\npub struct Conn {}\n\npub fn Conn.new() &Conn {\n\treturn &Conn{}\n}\n\npub fn (c &Conn) hi() {}\n\npub struct Box {}\n\npub fn Box.new() {}\n'
		'ssl/ssl_d_use_opn.v':   'module ssl\n\nimport opn\n\npub type SSLConn = opn.Conn\n'
		'ssl/ssl_notd_use_opn.v': 'module ssl\n\nimport mbd\n\npub type SSLConn = mbd.Conn\n'
		'ssl/plain.v':            'module ssl\n\nimport mbd\n\npub type Plain = mbd.Box\n'
		'app/main.v':            'module main\n\nimport ssl\n\nfn both() {\n\tc := ssl.SSLConn.new()\n\tc.hi()\n}\n\nfn one() {\n\tssl.SSLConn.only()\n}\n\nfn shared() {\n\tssl.Plain.new()\n}\n\nfn main() {}\n'
	})
	built := fn [g] (from string, to string) []string {
		return g.edges.filter(it.kind == .calls && it.from == 'app.${from}' && it.to == to).map('${it.provenance}|${it.build}')
	}
	assert built('both', 'opn.Conn__static__new') == ['inferred|use_opn ?']
	assert built('both', 'mbd.Conn__static__new') == ['inferred|!use_opn ?']
	assert built('both', 'ssl.SSLConn__static__new') == []
	assert built('both', 'opn.Conn.hi') == ['inferred|use_opn ?']
	assert built('both', 'mbd.Conn.hi') == ['inferred|!use_opn ?']
	assert built('one', 'opn.Conn__static__only') == ['inferred|use_opn ?']
	assert built('shared', 'mbd.Box__static__new') == ['inferred|']
}

// compiled: `x.str()` on a C string, a `&u8`, and on a `&char` parameter runs on either compiler, and no rune's `str` takes it, nor an unrelated type's. Here no `u8.str` is declared, as is true of no real builtin, to show what the rule does with none. A `&char` has the builtin's own `str` (vlib/builtin/int.v), which V calls. Its value is a string.
fn test_str_on_a_c_string_is_one_v_writes() {
	g := extract_graph_of({
		'vlib/builtin/b.v': 'module builtin\n\npub struct string {}\n\npub fn (s string) len_of() int {\n\treturn 0\n}\n\npub fn (r rune) str() string {\n\treturn ""\n}\n\npub fn (cptr &char) str() string {\n\treturn ""\n}\n'
		'q/o.v':            'module q\n\npub struct Qqq {}\n\npub fn (o Qqq) len_of() int {\n\treturn 0\n}\n\npub fn (o Qqq) str() string {\n\treturn ""\n}\n'
		'p/a.v':            'module main\n\nfn local() {\n\tx := c\'abc\'\n\tx.str()\n}\n\nfn param(p &char) {\n\tp.str()\n}\n\nfn value() {\n\tx := c\'abc\'\n\ts := x.str()\n\ts.len_of()\n}\n\nfn a_rune() {\n\tr := `c`\n\tr.str()\n}\n\nfn main() {}\n'
	})
	assert plain_calls(g, 'local', 'str') == ['str:undeclared']
	assert plain_calls(g, 'param', 'str') == ['vlib.builtin.char.str:inferred']
	assert plain_calls(g, 'value', 'len_of') == ['vlib.builtin.string.len_of:inferred']
	assert plain_calls(g, 'a_rune', 'str') == ['vlib.builtin.rune.str:inferred']
	// without the builtin's `&char` str in the graph the call stays open: V doesn't write it
	bare := extract_graph_of({
		'p/a.v': 'module main\n\nfn param(p &char) {\n\tp.str()\n}\n\nfn main() {}\n'
	})
	assert plain_calls(bare, 'param', 'str') == ['str:extracted']
}

// an alias in another file of the caller's module is seen; another test's static method isn't,
// so a call that only it answers stays open
fn test_a_static_call_through_an_alias_sees_the_module_and_not_another_test() {
	g := extract_graph_of({
		'lib/a.v':      'module lib\n\nfn through() {\n\tAaa.new()\n}\n\nfn only_in_a_test() {\n\tAaa.tested()\n}\n'
		'lib/b.v':      'module lib\n\npub struct Sss {}\n\npub fn Sss.new() {}\n\npub type Aaa = Sss\n'
		'lib/b_test.v': 'module lib\n\nfn Sss.tested() {}\n\nfn test_b() {}\n'
	})
	assert plain_calls(g, 'through', 'Sss__static__new') == ['lib.Sss__static__new:inferred']
	assert plain_calls(g, 'only_in_a_test', 'Sss__static__tested') == []
	assert plain_calls(g, 'only_in_a_test', 'Aaa__static__tested') == ['Aaa__static__tested:extracted']
}

// static_calls are the calls `from` makes, as `to:provenance`, sorted.
fn static_calls(g Graph, from string) []string {
	mut out := g.edges.filter(it.kind == .calls && it.from.all_before('@').all_after_last('.') == from).map('${it.to}:${it.provenance}')
	out.sort()
	return out
}

// compiled with V3, which prints `Aaa.make` for via[Ali], then `Aaa.make`, `Bbb.make`, `Aaa.make`
// for build[Ali], `green`, `dark` from Shade's own from_string, `green`, `enum`, `Bbb.make`.
// -old-compiler refuses the generic from_string on a private enum. A static call on a type
// parameter is each instance's static.
fn test_a_static_call_on_a_type_parameter_is_each_instances_static() {
	g := extract_graph_of({
		'p/a.v': 'module main

struct Aaa {}

fn Aaa.make() string {
	return "Aaa.make"
}

struct Bbb {}

fn Bbb.make() string {
	return "Bbb.make"
}

type Ali = Aaa

enum Color {
	red
	green
}

enum Shade {
	dark
	light
}

fn Shade.from_string(s string) ?Shade {
	return .dark
}

fn build[T]() string {
	return T.make()
}

fn parse_enum[T](s string) ?T {
	return T.from_string(s)
}

fn only_enum[T](s string) !T {
	return T.from(s)
}

fn Color.make() string {
	return "Color.make"
}

fn guarded[T]() string {
	\$if T is \$enum {
		return "enum"
	} \$else {
		return T.make()
	}
}

fn never[T]() string {
	return T.make()
}

fn via[T]() string {
	return T.make()
}

fn main() {
	println(via[Ali]())
	println(build[Aaa]())
	println(build[Bbb]())
	println(build[Ali]())
	println(parse_enum[Color]("green") or { Color.red })
	println(parse_enum[Shade]("light") or { Shade.light })
	println(only_enum[Color]("green") or { Color.red })
	println(guarded[Color]())
	println(guarded[Bbb]())
}
'
	})
	// each instance's own static, and through the alias Ali the static Aaa declares
	assert static_calls(g, 'build') == ['p.Aaa__static__make:inferred',
		'p.Bbb__static__make:inferred']
	// the declared from_string is linked; Color's, which V generates, is left out
	assert static_calls(g, 'parse_enum') == ['p.Shade__static__from_string:inferred']
	// every instance is an enum declaring no `from`: V's
	assert static_calls(g, 'only_enum') == ['T__static__from:undeclared']
	// the `$else` isn't compiled for the enum Color, so its own make isn't reached
	assert static_calls(g, 'guarded') == ['p.Bbb__static__make:inferred']
	// with no instance it stays open
	assert static_calls(g, 'never') == ['T__static__make:extracted']
	// through the alias Ali alone, the static Aaa declares
	assert static_calls(g, 'via') == ['p.Aaa__static__make:inferred']
}

// an instance the reader can't type, `unread(ext.get())`, may be any type, so `T.from()` isn't
// taken as V's even though every instance it can type is an enum; nor is it with an instance
// that isn't an enum, which V refuses. Not compiled: ext is outside the graph
fn test_a_static_call_on_a_type_parameter_with_an_unread_instance_is_not_vs() {
	g := extract_graph_of({
		'p/a.v': 'module main

import ext

enum Color {
	red
	green
}

fn known[T](v T) !T {
	return T.from(1)
}

fn unread[T](v T) !T {
	return T.from(1)
}

struct Plain {}

fn mixed[T](v T) !T {
	return T.from(1)
}

fn vfrom[T](args ...T) !T {
	return T.from(1)
}

struct Box[U] {
	v U
}

fn Box.make() string {
	return "Box.make"
}

fn gbuild[T]() string {
	return T.make()
}

fn main() {
	gbuild[Box[int]]()
	known(Color.red) or {}
	unread(Color.red) or {}
	unread(ext.get()) or {}
	mixed(Color.red) or {}
	mixed(Plain{}) or {}
	vfrom(ext.get(), Color.red) or {}
}
'
	})
	// every value of a variadic `...T` is a T, so the one it can type, past the first, gives it
	assert static_calls(g, 'vfrom') == ['T__static__from:undeclared']
	// V refuses `T.make()` with T a generic struct's instance (`unknown function T.make` on V3)
	assert static_calls(g, 'gbuild') == ['T__static__make:extracted']
	assert static_calls(g, 'known') == ['T__static__from:undeclared']
	assert static_calls(g, 'unread') == ['T__static__from:extracted']
	// V generates `from` for an enum only; for Plain it is no method V writes
	assert static_calls(g, 'mixed') == ['T__static__from:extracted']
}

// compiled with V3, which prints `a`, `b`, `x`, `y` and `name`: each part of a `$for` over a
// string's split or fields is a string. -old-compiler doesn't know the form.
fn test_the_variable_of_a_comptime_for_over_a_string_is_a_string() {
	g := extract_graph_of({
		'vlib/builtin/s.v': 'module builtin

pub struct string {}

pub fn (s string) to_lower() string {
	return s
}

pub struct FieldData {
pub:
	name string
}
'
		'p/a.v':            'module main

struct Foo {
	name string
}

fn (f Foo) to_lower() string {
	return "Foo.to_lower"
}

fn parts() {
	\$for part in "A/B".split("/") {
		println(part.to_lower())
	}
}

fn words() {
	\$for word in " X Y ".fields() {
		println(word.to_lower())
	}
}

fn names() {
	\$for f in Foo.fields {
		println(f.name.to_lower())
	}
}

fn main() {
	parts()
	words()
	names()
}
'
	})
	assert plain_calls(g, 'parts', 'to_lower') == ['vlib.builtin.string.to_lower:inferred']
	assert plain_calls(g, 'words', 'to_lower') == ['vlib.builtin.string.to_lower:inferred']
	assert plain_calls(g, 'names', 'to_lower') == ['vlib.builtin.string.to_lower:inferred']
}

// compiled: -old-compiler prints `['Foo.str', 'Foo.str']`, `['Bar.str']`, `['Baz.str']`, `Foo.str`
// and `Bar.str`. Each argument of a variadic `...T` gives T, and a spread array `...xs` its
// elements. V3 prints the same, and builds `first(...xs)` as a first of Bar (its C names
// first_T_Bar), except that it builds `each(...xs)` as an each of `[]Bar`, which prints `['[]']`.
fn test_a_variadic_parameter_takes_each_argument_and_a_spread_arrays_elements() {
	g := extract_graph_of({
		'p/a.v': 'module main

struct Foo {}

fn (f Foo) str() string {
	return "Foo.str"
}

struct Bar {}

fn (b Bar) str() string {
	return "Bar.str"
}

struct Baz {}

fn (b Baz) str() string {
	return "Baz.str"
}

fn each[T](args ...T) {
	println(args.map(it.str()))
}

fn pass[T](args ...T) {
	each(...args)
}

fn first[T](args ...T) T {
	return args[0]
}

fn take() {
	xs := [Bar{}]
	y := first(...xs)
	println(y.str())
}

fn main() {
	each(Foo{}, Foo{})
	xs := [Bar{}]
	each(...xs)
	pass(Baz{})
	println(first(Foo{}))
	take()
}
'
	})
	assert static_calls(g, 'each').filter(it.contains('str')) == ['p.Bar.str:inferred',
		'p.Baz.str:inferred', 'p.Foo.str:inferred']
	assert plain_calls(g, 'take', 'str') == ['p.Bar.str:inferred']
}

// compiled with V3, which prints `5`, `3`, `20`, `_ty_val(gen._ty_vec{ x: 1 })` and `val`; -old-compiler
// refuses `fn _ty_point.new`, as V 0.5.2 has no `@[generated]` modules. A type named without a
// capital, which such a module may declare, is still a type: its static, the static's result, a
// conversion to it through its module and that conversion's result. A const named so is still a value.
fn test_a_type_named_without_a_capital_is_a_type() {
	g := extract_graph_of({
		'p/main.v':    '@[generated]
module main

import gen

const _c_list = [3, 4]

struct _ty_point {
	x int
}

fn _ty_point.new(x int) _ty_point {
	return _ty_point{
		x: x
	}
}

fn (p _ty_point) sum() int {
	return p.x + 1
}

struct Other {}

fn (o Other) sum() int {
	return 0
}

fn (o Other) first() int {
	return 0
}

fn (o Other) kind() string {
	return "other"
}

fn local() {
	println(_ty_point.new(4).sum())
	println(_c_list.first())
}

fn remote() {
	println(gen._ty_vec.make(2).total())
	v := gen._ty_val(gen._ty_vec.make(1))
	println(v)
	println(gen._ty_val(1).kind())
}

fn main() {
	local()
	remote()
}
'
		'p/gen/gen.v': '@[generated]
module gen

pub struct _ty_vec {
pub:
	x int
}

pub fn _ty_vec.make(x int) _ty_vec {
	return _ty_vec{
		x: x
	}
}

pub fn (v _ty_vec) total() int {
	return v.x * 10
}

pub type _ty_val = _ty_vec | int

pub fn (v _ty_val) kind() string {
	return "val"
}
'
	})
	assert static_calls(g, 'local') == ['first:undeclared', 'p._ty_point.sum:inferred',
		'p._ty_point__static__new:extracted', 'println:extracted']
	assert static_calls(g, 'remote') == ['p.gen._ty_val.kind:inferred', 'p.gen._ty_val:inferred', 'p.gen._ty_vec.total:extracted',
		'p.gen._ty_vec__static__make:extracted', 'println:extracted']
}

// compiled with V3, which prints `exact list`, `exact list`, `exact map`, `exact pair`, `exact box`,
// then `list pattern`, `map pattern`, `pair pattern`, `box pattern`; -old-compiler refuses the
// `Expect[Box[T]]` pattern, and prints the rest so without the boxes. Of the methods of one name a generic type declares
// for an instantiation and for a pattern, a receiver calls the one of its own type arguments, else
// the pattern they fit; an alias names the type it stands for.
fn test_a_method_declared_for_an_instantiation_comes_before_a_pattern() {
	g := extract_graph_of({
		'p/a.v': 'module main

struct Expect[T] {
	value T
}

type IntList = Expect[[]int]

type StrMap = Expect[map[string]int]

struct Pair[T, U] {
	a T
	b U
}

fn (e Expect[[]int]) m() string {
	return "exact list"
}

fn (e Expect[[]T]) m() string {
	return "list pattern"
}

fn (e Expect[map[string]int]) m() string {
	return "exact map"
}

fn (e Expect[map[K]V]) m() string {
	return "map pattern"
}

fn (p Pair[int, []string]) n() string {
	return "exact pair"
}

fn (p Pair[T, []U]) n() string {
	return "pair pattern"
}

struct Box[T] {
	v T
}

fn (e Expect[Box[int]]) m() string {
	return "exact box"
}

fn (e Expect[Box[T]]) m() string {
	return "box pattern"
}

fn exact() {
	println(Expect[[]int]{}.m())
	println(IntList{}.m())
	println(StrMap{}.m())
	println(Pair[int, []string]{}.n())
	println(Expect[Box[int]]{}.m())
}

fn pattern() {
	println(Expect[[]string]{}.m())
	println(Expect[map[string]bool]{}.m())
	println(Pair[int, []bool]{}.n())
	println(Expect[Box[string]]{}.m())
}

fn main() {
	exact()
	pattern()
}
'
	})
	assert static_calls(g, 'exact') == ['p.Expect[Box[int]].m:extracted', 'p.Expect[[]int].m:extracted',
		'p.Expect[map[string]int].m:inferred', 'p.Pair[int, []string].n:extracted', 'println:extracted']
	assert static_calls(g, 'pattern') == ['p.Expect[Box[T]].m:inferred', 'p.Expect[[]T].m:inferred',
		'p.Expect[map[K]V].m:inferred', 'p.Pair[T, []U].n:inferred', 'println:extracted']
}

// compiled with V3, which prints `prim` for on_value, on_field, on_chain and on_both, `kind` for in_block
// and negated, and `6`. After an assert, -old-compiler calls a sum type's own method and refuses
// `s.side()`, a method only the interface's variant declares. An
// `assert x is T` narrows what follows it as an `if` does its block, and its message runs where the
// check failed.
fn test_an_assert_narrows_what_follows_it() {
	g := extract_graph_of({
		'p/main.v': 'module main

struct Alias {
	base &Kind
}

struct Prim {
	bits int
}

type Kind = Alias | Prim

fn (k Kind) label() string {
	return "kind"
}

fn (p Prim) label() string {
	return "prim"
}

struct Other {}

fn (o Other) label() string {
	return "other"
}

interface Shape {
	area() int
}

struct Sq {}

fn (s Sq) area() int {
	return 4
}

fn (s Sq) side() int {
	return 2
}

fn on_value(k Kind) string {
	assert k is Prim
	return k.label()
}

fn on_field(a Alias) string {
	assert a.base is Prim
	return a.base.label()
}

fn on_chain(k Kind) string {
	assert k is Alias
	b := k.base
	assert b is Prim
	return b.label()
}

fn on_both(k Kind) string {
	assert k is Alias && k.base is Prim
	return k.base.label()
}

fn in_message(k Kind) string {
	assert k is Prim, k.label()
	return ""
}

fn in_block(k Kind) string {
	if k is Prim {
		assert k is Prim
	}
	return k.label()
}

fn negated(k Kind) string {
	assert k !is Alias
	return k.label()
}

fn on_iface(s Shape) int {
	assert s is Sq
	return s.area() + s.side()
}

fn main() {
	p := Kind(Prim{8})
	a := Alias{&p}
	println(on_value(p))
	println(on_field(a))
	println(on_chain(Kind(a)))
	println(on_both(Kind(a)))
	println(in_block(p))
	println(negated(p))
	println(on_iface(Sq{}))
	println(Other{}.label())
}
'
	})
	for f in ['on_value', 'on_field', 'on_chain', 'on_both'] {
		assert static_calls(g, f) == ['p.Prim.label:inferred'], f
	}
	for f in ['in_message', 'in_block', 'negated'] {
		assert static_calls(g, f) == ['p.Kind.label:extracted'], f
	}
	assert static_calls(g, 'on_iface') == ['p.Sq.area:inferred', 'p.Sq.side:extracted']
}

// compiled with V3, which prints foo, foo, ['name'], foo, foo, foo, foofoo, ['name'], name and
// otherfoo three times. V types a lambda's parameters from the function type its call expects
// there: an element of the array for `map`, else the parameter of the function, method or
// function value it is passed to, with a type parameter the call's other arguments or its type
// arguments give, and each parameter shadows an outer name. A field path on an element of a
// `[]T` is walked from each instance of T, in a lambda as in a `for` loop. A function value's
// type parameter is not followed: that lambda's call stays unresolved, not the outer `x`'s.
fn test_a_lambdas_parameters_have_the_types_its_call_expects() {
	g := extract_graph_of({
		'p/main.v': 'module main

struct Foo {}

struct Other {}

struct Name {}

struct User {
	name Name
}

struct Box {}

fn (f Foo) show() string {
	return "foo"
}

fn (o Other) show() string {
	return "other"
}

fn (n Name) up() string {
	return "name"
}

fn (o Other) up() string {
	return "other"
}

fn (b Box) each(f fn (Foo) string) string {
	return f(Foo{})
}

fn apply(f fn (Foo) string) string {
	return f(Foo{})
}

fn jts[T](a []T, f fn (T) string) string {
	return f(a[0])
}

fn abc[T](arg T, call fn (a T) string) string {
	return call(arg)
}

fn ddd[T](call fn (a T, b T) string, a T, b T) string {
	return call(a, b)
}

fn on_plain_fn() string {
	return apply(|y| y.show())
}

fn on_method(b Box) string {
	return b.each(|y| y.show())
}

fn on_array(xs []User) []string {
	return xs.map(|x| x.name.up())
}

fn on_generic_array(a []Foo) string {
	return jts(a, |x| x.show())
}

fn on_generic_value(x Foo) string {
	return abc(x, |y| y.show())
}

fn on_type_argument() string {
	return abc[Foo](Foo{}, |y| y.show())
}

fn in_generic[T](a T, b T) string {
	return ddd(|x, y| x.show() + y.show(), a, b)
}

fn elems_of_generic[T](xs []T) []string {
	return xs.map(|x| x.name.up())
}

fn loop_of_generic[T](xs []T) string {
	mut out := ""
	for x in xs {
		out += x.name.up()
	}
	return out
}

fn shadowed(x Other) string {
	return x.show() + apply(|x| x.show())
}

fn via_value(x Other, h fn (fn (Foo) string) string) string {
	return x.show() + h(|x| x.show())
}

fn via_generic_value[T](x Other, h fn (fn (T) string) string) string {
	return x.show() + h(|x| x.show())
}

fn main() {
	println(on_plain_fn())
	println(on_method(Box{}))
	println(on_array([User{}]))
	println(on_generic_array([Foo{}]))
	println(on_generic_value(Foo{}))
	println(on_type_argument())
	println(in_generic(Foo{}, Foo{}))
	println(elems_of_generic([User{}]))
	println(loop_of_generic([User{}]))
	println(shadowed(Other{}))
	println(via_value(Other{}, apply))
	println(via_generic_value[Foo](Other{}, apply))
}'
	})
	on := fn [g] (f string) []string {
		return static_calls(g, f).filter(it.all_before(':').all_after_last('.') in ['show', 'up'])
	}
	for f in ['on_plain_fn', 'on_method', 'on_generic_array', 'on_generic_value', 'on_type_argument',
		'in_generic'] {
		assert on(f) == ['p.Foo.show:inferred'], f
	}
	for f in ['on_array', 'elems_of_generic', 'loop_of_generic'] {
		assert on(f) == ['p.Name.up:inferred'], f
	}
	// the outer `x` is an Other, the lambda's a Foo
	for f in ['shadowed', 'via_value'] {
		assert on(f) == ['p.Foo.show:inferred', 'p.Other.show:extracted'], f
	}
	assert on('via_generic_value') == ['p.Other.show:extracted', 'show:extracted']
}
// compiled with V3, which prints ['foo'], ['name'], ['foo'], name, 1, only, name and foo. A type's
// own `map` types its lambda from its declaration, and so does an alias of an array that declares
// one, while one that doesn't takes builtin's (declared below as builtin does, on `array`, of
// voidptr); a lambda's parameter has the path its body takes from it (`x.name.up()`), a lambda in
// `it`'s call sees the outer `it`, and a lambda typed by the caller's T is walked from each instance.
fn test_a_lambdas_parameter_is_read_where_the_call_and_its_type_say() {
	g := extract_graph_of({
		'vlib/builtin/array.v': 'module builtin

pub struct array {}

pub fn (a array) filter(predicate fn (voidptr) bool) array

pub fn (a array) any(predicate fn (voidptr) bool) bool

pub fn (a array) map(callback fn (voidptr) voidptr) array

pub fn (mut a array) sort(callback fn (voidptr, voidptr) int)
'
		'p/main.v':             'module main

struct Foo {}

struct Other {}

struct Name {}

struct User {
	name Name
}

struct Group {
	users []User
}

struct Stream {
	items []Foo
}

type Users = []User

// an alias of an array that declares its own map
type Names = []User

fn (ns Names) map(f fn (Foo) string) []string {
	return [f(Foo{})]
}

fn (f Foo) show() string {
	return "foo"
}

fn (o Other) show() string {
	return "other"
}

fn (n Name) up() string {
	return "name"
}

fn (o Other) up() string {
	return "other"
}

fn (u User) ok() bool {
	return true
}

fn (o Other) ok() bool {
	return false
}

// a type"s own map, whose lambda takes a Foo, not an element
fn (s Stream) map(f fn (Foo) string) []string {
	return s.items.map(f)
}

fn apply(f fn (Foo) string) string {
	return f(Foo{})
}

fn jts[T](a []T, f fn (T) string) string {
	return f(a[0])
}

fn only[T](call fn (a T) string) string {
	return "only"
}

fn g[T](v T) string {
	return v.show()
}

fn own_map(s Stream) []string {
	return s.map(|x| x.show())
}

fn alias_map(us Users) []string {
	return us.map(|x| x.name.up())
}

fn alias_own_map(ns Names) []string {
	return ns.map(|x| x.show())
}

fn field_path(a []User) string {
	return jts(a, |x| x.name.up())
}

fn nested_it(gs []Group) []Group {
	return gs.filter(it.users.any(|u| u.ok()))
}

fn type_arg_only() string {
	return only[Foo](|y| y.show())
}

fn generic_field[T](a T, b T) string {
	return jts([a, b], |x| x.name.up())
}

fn sort_cmp(mut xs []User) {
	xs.sort_with_compare(fn (a &User, b &User) int {
		return 0
	})
	xs.sort(|a, b| a.ok() && !b.ok())
}

fn into_generic(a []Foo) string {
	return jts(a, |x| g(x))
}

fn main() {
	println(own_map(Stream{[Foo{}]}))
	println(alias_map([User{}]))
	println(alias_own_map(Names([User{}])))
	println(field_path([User{}]))
	println(nested_it([Group{[User{}]}]).len)
	println(type_arg_only())
	println(generic_field(User{}, User{}))
	mut us := [User{}, User{}]
	sort_cmp(mut us)
	println(into_generic([Foo{}]))
}'
	})
	on := fn [g] (f string) []string {
		return static_calls(g, f).filter(it.all_before(':').all_after_last('.') in ['show', 'up', 'ok'])
	}
	for f in ['own_map', 'alias_own_map', 'type_arg_only', 'g'] {
		assert on(f) == ['p.Foo.show:inferred'], f
	}
	for f in ['alias_map', 'field_path', 'generic_field'] {
		assert on(f) == ['p.Name.up:inferred'], f
	}
	for f in ['nested_it', 'sort_cmp'] {
		assert on(f) == ['p.User.ok:inferred'], f
	}
}