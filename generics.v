module graphify

// A method call on a type parameter of a generic function, `v.describe()` where
// `v T`, has no type of its own, so it is linked to the method of each type the
// function is called with. The types come from the call sites that resolved to
// the function: the type of an argument whose parameter is `T` (or the element of
// one whose parameter is `[]T`), read from the argument recipes the extraction
// recorded (Edge.arg_sites).

// Flow says the types of one type parameter are the types of another: a generic
// function that passes its own `T` on to another, `inner(x)` inside `outer[T]`, gives
// `inner`'s `T` the types `outer`'s `T` has. A flow is followed until nothing is new.
struct Flow {
	dst string
	src string
}

// expand_type_param_calls returns the edges with each method call on a type
// parameter replaced by the methods of the types the parameter stands for, as
// `inferred` edges. A call with no such type stays as it was. `funcs` holds the
// generic free functions and the methods and structs that have type parameters, by
// id. A method of a generic struct, `Box[T].show`, is called on the types its struct is
// instantiated with, at the receivers of its methods (`sources`, the edges as the
// extraction recorded them, since a resolved edge drops its receiver) and in the types
// of the struct fields that are generic instances (`fields`).
fn expand_type_param_calls(edges []Edge, sources []Edge, fields []Symbol, mut inf Infer, funcs map[string]Symbol, unaddressable map[string]bool, variants_of map[string][]string) []Edge {
	// the types each type parameter stands for, by instance_key
	mut instances := map[string][]InferredType{}
	mut flows := []Flow{}
	// the types a generic function's type parameter is given at its call sites, from
	// the argument recipes
	for e in edges {
		if e.kind != .calls || e.is_method || e.arg_sites == '' {
			continue
		}
		callee := funcs[e.to] or { continue }
		if callee.kind != .function {
			continue
		}
		tps := generic_params(callee)
		if tps.len == 0 {
			continue
		}
		caller := funcs[e.from] or { Symbol{} }
		caller_tps := generic_params(caller)
		ptypes := param_types(callee.signature)
		sites := e.arg_sites.split(arg_site_end)
		for si, site in sites {
			if si == sites.len - 1 || site == '' {
				continue
			}
			if site.starts_with('ta:') {
				// explicit type arguments, `f[Context]()`, name the types of f's type parameters in
				// order, as written in the caller's module
				mod := (inf.scope_of[e.file] or { FileScope{} }).mod
				for j, name in site[3..].split('\x0b') {
					if j >= tps.len || name == '' {
						continue
					}
					dst := callee.id + '\x00' + tps[j]
					if passed := plain_param(name, mod, caller_tps) {
						flows << Flow{
							dst: dst
							src: instance_key(caller, passed)
						}
						continue
					}
					if is_type_param_text(name) {
						continue
					}
					put_instance(mut instances, dst, InferredType{
						text: bare_type(name)
						mod:  mod
						file: e.file
					})
				}
				continue
			}
			args := site.split('\x0b')
			for j, recipe in args {
				if recipe == '' || j >= ptypes.len {
					continue
				}
				for tp in tps {
					// a function-typed parameter, `h fn () H`, is typed by what the function its argument
					// names returns: the argument is a function-typed value, or a function named as a value
					returns_tp := (fn_return(ptypes[j]) or { '' }) == tp
					if ptypes[j] != tp && ptypes[j] != '[]' + tp && !returns_tp {
						continue
					}
					edge := Edge{
						from:        e.from
						file:        e.file
						recv_recipe: recipe
					}
					t := inf.follow(edge) or { inf.fn_value_type(e, recipe) or { continue } }
					mut text := bare_type(t.text)
					if returns_tp {
						text = bare_type(fn_return(text) or { continue })
					} else if ptypes[j] != tp {
						if !text.starts_with('[]') {
							continue
						}
						text = text[2..]
					}
					if text == '' {
						continue
					}
					dst := callee.id + '\x00' + tp
					if passed := plain_param(text, t.mod, caller_tps) {
						flows << Flow{
							dst: dst
							src: instance_key(caller, passed)
						}
						continue
					}
					if is_type_param_text(text) {
						continue
					}
					put_instance(mut instances, dst, InferredType{
						text: text
						mod:  t.mod
						file: t.file
					})
				}
			}
		}
	}
	// the types a generic struct's type parameters are instantiated with, at the
	// receivers of its methods, and in the types of its fields
	for e in sources {
		if e.kind != .calls || !e.is_method {
			continue
		}
		recv := inf.receiver(e) or { continue }
		caller := funcs[e.from] or { Symbol{} }
		add_owner_instances(mut instances, mut flows, recv.text, recv.mod, recv.file, caller)
		// a method on a field of a generic struct, `m.work.block_size()` on an `m` that is a
		// `Hmac[D]`, names the struct's instance too: the field's owner is the recipe's prefix
		steps := e.recv_recipe.split(recipe_sep)
		if steps.len > 1 && steps[steps.len - 1].starts_with('f:') {
			if owner := inf.follow(Edge{
				from:        e.from
				file:        e.file
				recv_recipe: steps[..steps.len - 1].join(recipe_sep)
			}) {
				add_owner_instances(mut instances, mut flows, owner.text, owner.mod, owner.file, caller)
			}
		}
	}
	for f in fields {
		// a field's type is written in its struct's module, and the struct's own type
		// parameters pass on to it, as the parameters of a generic function do
		own := funcs[f.parent] or { Symbol{} }
		add_owner_instances(mut instances, mut flows, f.signature.all_after(' '), struct_module(f.parent, own), f.file, own)
	}
	// a type parameter that is passed on takes the types of the one it is passed from;
	// a chain of generic calls is short, so a few rounds reach the fixed point
	for _ in 0 .. 16 {
		mut changed := false
		for fl in flows {
			for t in instances[fl.src] or { []InferredType{} } {
				if put_instance(mut instances, fl.dst, t) {
					changed = true
				}
			}
		}
		if !changed {
			break
		}
	}
	if instances.len == 0 && !edges.any(it.is_method && has_field_any(it.recv_recipe)) {
		return edges
	}
	mut out := []Edge{cap: edges.len}
	// the edges of the calls in field loops, joined to the rest once every edge is out
	// (see merge_call_edges)
	mut field_edges := []Edge{}
	for e in edges {
		if e.kind != .calls || !e.is_method || e.to.contains('.') || e.provenance == .undeclared {
			out << e
			continue
		}
		if has_field_any(e.recv_recipe) {
			// a call on `x.$(field.name)` in a field loop is a call on each field the loop
			// reaches, in a function that may have no type parameters at all
			caller := funcs[e.from] or { Symbol{} }
			ids := field_any_ids(e, caller, generic_params(caller), instances, mut inf)
			if ids.len == 0 {
				field_edges << field_any_fallback(e, mut inf, unaddressable, variants_of)
				continue
			}
			// each platform's copy of a method, as resolve_edges links a call that reaches one
			for id in ids {
				for vid in variants_of[id] or { [id] } {
					field_edges << Edge{
						from:       e.from
						to:         vid
						kind:       .calls
						is_method:  true
						file:       e.file
						provenance: .comptime
						lines:      e.lines
						build:      e.build
					}
				}
			}
			continue
		}
		caller := funcs[e.from] or {
			out << e
			continue
		}
		tps := generic_params(caller)
		if tps.len == 0 {
			out << e
			continue
		}
		recv := inf.receiver(e) or {
			// a method on a field of a type parameter, `ctx.req.header.get()` on a `ctx T`, is a
			// call on that field of each instance; a call on the result of a call on a type
			// parameter, `el.tag().bytes()`, is a call on what each instance's tag() returns
			mut chained := path_method_ids(e, caller, tps, instances, mut inf)
			if chained.len == 0 {
				chained = chained_call_ids(e, caller, tps, instances, mut inf)
			}
			if chained.len == 0 {
				out << e
			}
			for id in chained {
				out << Edge{
					from:       e.from
					to:         id
					kind:       .calls
					is_method:  true
					file:       e.file
					provenance: .inferred
					lines:      e.lines
					build:      e.build
				}
			}
			continue
		}
		recv_text := plain_param(recv.text, recv.mod, tps) or {
			// a call of a field that holds a function, `self.func(a)` where `func T` and T
			// is instantiated with a function type, calls that value, as no_method has it
			if caller.kind == .method && owner_of(recv.text, recv.mod) == method_owner(caller) {
				if field := inf.field_of(recv, e.to, e.file, 0) {
					if field_text := plain_param(field.text, field.mod, tps) {
						if (instances[instance_key(caller, field_text)] or { []InferredType{} }).any(it.text.starts_with('fn')) {
							out << Edge{ ...e, provenance: .undeclared }
							continue
						}
					}
				}
			}
			out << e
			continue
		}
		insts := guarded_instances(instances[instance_key(caller, recv_text)] or { []InferredType{} }, e.guards, recv_text, mut inf)
		if insts.len == 0 {
			out << e
			continue
		}
		mut ids := []string{}
		for t in insts {
			id := inf.method_on(t, e.to, e.file, 0) or { continue }
			if id !in ids {
				ids << id
			}
		}
		if ids.len == 0 {
			out << e
			continue
		}
		for id in ids {
			out << Edge{
				from:       e.from
				to:         id
				kind:       .calls
				is_method:  true
				file:       e.file
				provenance: .inferred
				lines:      e.lines
				build:      e.build
			}
		}
	}
	merge_call_edges(mut out, field_edges)
	return out
}

// field_any_fallback is the edges of a call `e` on any field of a type that no field
// answers, resolved as infer_call resolves a call on an unknown receiver: the method
// it then names, with every platform's copy of it as resolve_edges links one, or an
// undeclared call, or `e` itself when nothing resolves it.
fn field_any_fallback(e Edge, mut inf Infer, unaddressable map[string]bool, variants_of map[string][]string) []Edge {
	r := inf.infer_call(Edge{
		...e
		recv_recipe: ''
	}) or { return [e] }
	if r.undeclared {
		return [Edge{
			...e
			provenance: .undeclared
		}]
	}
	if r.id == '' || unaddressable[r.id] {
		return [e]
	}
	mut out := []Edge{}
	for id in variants_of[r.id] or { [r.id] } {
		out << Edge{
			from:       e.from
			to:         id
			kind:       .calls
			is_method:  e.is_method
			provenance: if r.inferred { .inferred } else { .extracted }
			file:       e.file
			lines:      e.lines
			build:      e.build
		}
	}
	return out
}

// merge_call_edges adds the calls edges `extra` to `edges`, each joining an edge of the
// same caller and callee that is there already, as resolve_edges keeps one edge per
// callee (and per raw name and comptime conditions, call_key): the edge there keeps its
// provenance and takes the lines.
fn merge_call_edges(mut edges []Edge, extra []Edge) {
	if extra.len == 0 {
		return
	}
	mut at := map[string]int{}
	for i, e in edges {
		if e.kind == .calls {
			k := call_key(e)
			if k !in at {
				at[k] = i
			}
		}
	}
	for e in extra {
		k := call_key(e)
		if i := at[k] {
			add_lines(mut edges, i, e)
			continue
		}
		at[k] = edges.len
		edges << e
	}
}

// call_key is what resolve_edges keeps one calls edge per: its caller and callee, and
// for an unresolved call the comptime conditions it is under.
fn call_key(e Edge) string {
	return if e.guards == '' { '${e.from}\x00${e.to}' } else { '${e.from}\x00${e.to}\x00${e.guards}' }
}

// instance_key is the key of the types a type parameter `tp` of the declaration
// `caller` stands for: `<function id>\x00<tp>` for a generic function, and
// `<struct id>\x00<position of tp>` for a type parameter of a generic struct, which a
// method or a field of the struct has. `tp` must be one of the caller's parameters.
fn instance_key(caller Symbol, tp string) string {
	if caller.kind == .function {
		return caller.id + '\x00' + tp
	}
	mut pos := 0
	for i, p in generic_params(caller) {
		if p == tp {
			pos = i
		}
	}
	owner := if caller.kind == .method { method_owner(caller) } else { caller.id }
	return owner + '\x00' + pos.str()
}

// plain_param is the type parameter a type text names, of those in `tps`: `T`, or
// `demo.T` for a field or element typed by its owner's parameter, which the module
// qualifies. none when the text names none of them.
fn plain_param(text string, mod string, tps []string) ?string {
	mut name := bare_type(text)
	if mod != '' && name.starts_with(mod + '.') {
		name = name[mod.len + 1..]
	}
	if name in tps {
		return name
	}
	return none
}

// struct_module is the module of the struct `id`, which `own` declares when it is a
// generic struct. Otherwise it is read off the id, past an `@file` that tells colliding
// ids apart and a C struct's `C.` (`vlib.os.C.stat`, see extract_struct).
fn struct_module(id string, own Symbol) string {
	if own.parent != '' {
		return own.parent
	}
	m := id.all_before('@').all_before_last('.')
	return if m.ends_with('.C') { m.all_before_last('.') } else { m }
}

// add_owner_instances records the type arguments of one instance of a generic struct,
// `Box[Pen]` written in module `mod` inside the declaration `caller`. A concrete
// argument is an instance of the struct at its position. An argument that is a type
// parameter of `caller` passes that parameter's instances on, as a flow.
fn add_owner_instances(mut instances map[string][]InferredType, mut flows []Flow, text string, mod string, file string, caller Symbol) {
	args := split_type_args(text)
	if args.len == 0 {
		return
	}
	caller_tps := generic_params(caller)
	owner := owner_of(text, mod)
	for i, arg in args {
		arg_text := bare_type(arg)
		if arg_text == '' {
			continue
		}
		dst := owner + '\x00' + i.str()
		if passed := plain_param(arg_text, mod, caller_tps) {
			flows << Flow{
				dst: dst
				src: instance_key(caller, passed)
			}
			continue
		}
		put_instance(mut instances, dst, InferredType{
			text: arg_text
			mod:  mod
			file: file
		})
	}
}

// fn_value_type is the type of a function named as a value and passed to a function-typed
// parameter: `sha256.new`, recorded as the recipe `g:crypto.sha256.new`, or `new_digest`, a
// function of the caller's module, recorded as `g:new_digest`. Its type is `fn () <return
// type>`, with the module the function is declared in. none when the recipe names no function.
fn (inf &Infer) fn_value_type(e Edge, recipe string) ?InferredType {
	if !recipe.starts_with('g:') {
		return none
	}
	name := recipe[2..]
	mut id := name
	if !name.contains('.') {
		id = (inf.scope_of[e.file] or { return none }).mod + '.' + name
	} else if name !in inf.sig_of {
		// an import is named as written, `crypto.sha1.new`, and the module of a file in vlib is
		// `vlib.crypto.sha1` (import_names)
		id = 'vlib.' + name
	}
	ret := inf.returns(id)?
	return InferredType{
		text: 'fn () ' + ret.text
		mod:  ret.mod
		file: ret.file
	}
}

// owner_of is the qualified id of the generic struct a type text instantiates,
// `demo.Box` for `Box[int]` in module `demo`.
fn owner_of(text string, mod string) string {
	return qualify_type_names(strip_generic_args(bare_type(text)), mod)
}

// put_instance records one type under a key unless it is recorded already, and
// reports whether it was new.
fn put_instance(mut instances map[string][]InferredType, key string, t InferredType) bool {
	existing := instances[key] or { []InferredType{} }
	if existing.any(it.text == t.text) {
		return false
	}
	mut known := existing.clone()
	known << t
	instances[key] = known
	return true
}

// generic_params are a generic function's type parameters, a method's receiver type
// parameters, `T` in `fn (b Box[T]) show()`, or a generic struct's own, which the
// symbol records comma-separated in its recipe; none for one that has none.
fn generic_params(s Symbol) []string {
	if (s.kind != .function && s.kind != .method && s.kind != .struct_) || s.recipe == '' {
		return []string{}
	}
	return s.recipe.split(',')
}

// chained_call_ids are the methods a call reaches on the result of a method call on a
// type parameter: `el.tag().bytes()` where `el` is T has the receiver recipe
// `t:Choi[T] | f:src | [] | m:tag`, and the receiver of bytes() is what tag() returns on
// each instance of T. Empty unless the receiver is such a call.
fn chained_call_ids(e Edge, caller Symbol, tps []string, instances map[string][]InferredType, mut inf Infer) []string {
	steps := e.recv_recipe.split(recipe_sep)
	if steps.len < 2 || !steps[steps.len - 1].starts_with('m:') {
		return []string{}
	}
	prefix := inf.follow(Edge{
		from:        e.from
		file:        e.file
		recv_recipe: steps[..steps.len - 1].join(recipe_sep)
	}) or { return []string{} }
	tp := plain_param(prefix.text, prefix.mod, tps) or { return []string{} }
	method := steps[steps.len - 1][2..]
	mut ids := []string{}
	for t in guarded_instances(instances[instance_key(caller, tp)] or { []InferredType{} }, e.guards, tp, mut inf) {
		result_id := inf.method_on(t, method, e.file, 0) or { continue }
		result := inf.returns(result_id) or { continue }
		id := inf.method_on(result, e.to, e.file, 0) or { continue }
		if id !in ids {
			ids << id
		}
	}
	return ids
}

// path_method_ids are the methods a call reaches through a field, or a call, of a type
// parameter's instances: `ctx.req.header.get()` on a `ctx T` walks the recipe `t:T | f:req |
// f:header` from each instance of T in place of T, in the file the instance is written in,
// and finds `get` on the header the instance's field has. Empty unless the recipe starts at a
// type parameter and has steps after it.
fn path_method_ids(e Edge, caller Symbol, tps []string, instances map[string][]InferredType, mut inf Infer) []string {
	steps := e.recv_recipe.split(recipe_sep)
	if steps.len < 2 || !steps[0].starts_with('t:') {
		return []string{}
	}
	tp := plain_param(steps[0][2..], '', tps) or { return []string{} }
	rest := steps[1..].join(recipe_sep)
	mut ids := []string{}
	for t in guarded_instances(instances[instance_key(caller, tp)] or { []InferredType{} }, e.guards, tp, mut inf) {
		// the instance as its own module writes it: the qualified `vlib.veb.tests.Context` does not
		// find its fields, the name in the instance's file does
		mut name := t.text
		if t.mod != '' && name.starts_with(t.mod + '.') {
			name = name[t.mod.len + 1..]
		}
		// the instance is read in the file that declares its type: the file of the call that made
		// it is not one a test-only declaration is visible from (see declared_file)
		recv := inf.follow_steps(Edge{
			from:        e.from
			file:        inf.declared_file(strip_generic_args(name).all_after_last('.'), t.mod, t.file)
			recv_recipe: 't:' + name + recipe_sep + rest
		}, 0) or { continue }
		id := inf.method_on(recv, e.to, e.file, 0) or { continue }
		if id !in ids {
			ids << id
		}
	}
	return ids
}

// has_field_any reports whether a receiver recipe has the `fa:` step of a call on any
// field of a type (see field_any_step).
fn has_field_any(recipe string) bool {
	return recipe.starts_with('fa:') || recipe.contains(recipe_sep + 'fa:')
}

// field_any_on_tparam reports whether the receiver of a call on any field of a type is
// one of `tps`, the caller's type parameters, whose instances are known only once the
// call sites are read (see field_any_ids).
fn (mut inf Infer) field_any_on_tparam(e Edge, tps []string) bool {
	_, tp, _ := inf.field_any_receiver(e, tps) or { return false }
	return tp != ''
}

// field_any_receiver reads a receiver recipe with an `fa:` step (see field_any_step): the
// index of the step, and what the receiver before it is, the caller's type parameter of
// `tps` it names or else the one type it follows to. none when there is no such step or
// the receiver can't be followed.
fn (mut inf Infer) field_any_receiver(e Edge, tps []string) ?(int, string, InferredType) {
	steps := e.recv_recipe.split(recipe_sep)
	mut at := -1
	for i, s in steps {
		if s.starts_with('fa:') {
			at = i
			break
		}
	}
	if at < 1 {
		return none
	}
	prefix := steps[..at]
	if prefix.len == 1 && prefix[0].starts_with('t:') {
		if tp := plain_param(prefix[0][2..], '', tps) {
			return at, tp, InferredType{}
		}
	}
	t := inf.follow(Edge{
		from:        e.from
		file:        e.file
		recv_recipe: prefix.join(recipe_sep)
	})?
	if tp := plain_param(t.text, t.mod, tps) {
		return at, tp, InferredType{}
	}
	return at, '', t
}

// field_any_ids are the methods a call on `x.$(field.name)` reaches in a field loop that
// no `$if` fixes to one field (the `fa:` step, see field_any_step): the method on the
// type of each field of x's type that the step's narrowings keep, with the recipe's steps
// after it followed from that field's type. x's type is each instance of the caller's
// type parameter that x is, or else the one type its recipe follows to, and it must be the
// type the loop walks (the step's `L:`), whose fields the loop names. Empty when no field
// has the method.
fn field_any_ids(e Edge, caller Symbol, tps []string, instances map[string][]InferredType, mut inf Infer) []string {
	at, tp, recv_type := inf.field_any_receiver(e, tps) or { return []string{} }
	steps := e.recv_recipe.split(recipe_sep)
	mut loop := ''
	mut kinds := []string{}
	for k in steps[at][3..].split(';') {
		if k.starts_with('L:') {
			loop = k[2..]
		} else if k != '' {
			kinds << k
		}
	}
	rest := steps[at + 1..]
	mut owners := []InferredType{}
	if tp != '' {
		if loop != '' && bare_type(loop) != tp {
			return []string{}
		}
		owners = guarded_instances(instances[instance_key(caller, tp)] or { []InferredType{} },
			e.guards, tp, mut inf)
	} else {
		if loop != '' && !inf.names_same_type(recv_type, loop, e.file) {
			return []string{}
		}
		owners << recv_type
	}
	mut ids := []string{}
	for o in owners {
		// the type as its own module writes it, read in the file that declares it, as
		// path_method_ids reads an instance
		name := own_name(o)
		named := strip_generic_args(bare_type(name))
		short := named.all_after_last('.')
		qual := if named.contains('.') { named.all_before_last('.') } else { '' }
		file := inf.declared_file(short, o.mod, o.file)
		owner := InferredType{
			...o
			text: name
			file: file
		}
		decl := inf.find_type(short, qual, owner, file) or { continue }
		for fname in inf.fields_of[decl.id] or { []string{} } {
			// field_of reads a generic instance's arguments into the field; a type written
			// through another module (`a.S` in module b) it can miss, and the field is then
			// its declared type, read in the struct's own module
			ft := inf.field_of(owner, fname, file, 0) or {
				InferredType{
					text:     inf.field_type['${decl.id}\x00${fname}'] or { continue }
					mod:      decl.mod
					file:     decl.file
					field_id: inf.field_id['${decl.id}\x00${fname}'] or { '' }
				}
			}
			if !field_kind_holds(fname, ft, kinds, e.file, mut inf) {
				continue
			}
			mut recv := ft
			if rest.len > 0 {
				recv = inf.follow_steps(Edge{
					from:        e.from
					file:        ft.file
					recv_recipe: 't:' + own_name(ft) + recipe_sep + rest.join(recipe_sep)
				}, 0) or { continue }
			}
			id := inf.method_on(recv, e.to, e.file, 0) or {
				inf.platform_copy_method(recv, e.to) or { continue }
			}
			if id !in ids {
				ids << id
			}
		}
	}
	return ids
}

// platform_copy_method is one copy of the method `name` of the type `t` when the method is
// declared once per platform (`main.Doc.close@p_nix.c.v`, `...@p_windows.c.v`), which
// method_on takes for several methods; variants_of links every copy of it. none when `t`
// has no such method.
fn (inf &Infer) platform_copy_method(t InferredType, name string) ?string {
	named := strip_generic_args(bare_type(t.text))
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	decl := inf.find_type(short, qual, t, t.file)?
	want := decl.id + '.' + name
	for c in inf.by_name[name] or { []CallCand{} } {
		if c.is_method && c.id.contains('@') && c.id.all_before('@') == want {
			return c.id
		}
	}
	return none
}

// own_name is a type's text as its own module writes it: `Context` for
// `vlib.veb.tests.Context` in module `vlib.veb.tests`.
fn own_name(t InferredType) string {
	if t.mod != '' && t.text.starts_with(t.mod + '.') {
		return t.text[t.mod.len + 1..]
	}
	return t.text
}

// field_kind_holds reports whether the field `fname` of type `ft` meets every narrowing
// in `kinds`, as field_any_step records them: a kind, `$map`, tested on the type as
// declared, or `~$map` on the type it aliases, as V's FieldData flags are; the field
// `n:name`; or the type `t:int`; each negated by a leading `!`. A kind that can't be told
// keeps the field, but a primitive, array, map, channel or function type is never a
// struct, enum, sum type or interface.
fn field_kind_holds(fname string, ft InferredType, kinds []string, file string, mut inf Infer) bool {
	for k in kinds {
		negated := k.starts_with('!')
		mut test := if negated { k[1..] } else { k }
		mut t := ft
		if test.starts_with('~') {
			test = test[1..]
			t = inf.unalias(ft, ft.file)
		}
		text := bare_type(t.text)
		mut holds := false
		if test.starts_with('n:') {
			holds = fname == test[2..]
		} else if test.starts_with('t:') {
			holds = inf.same_type(t, test[2..], file) or { continue }
		} else if test == '$array' {
			holds = text.starts_with('[')
		} else if test in ['$struct', '$enum', '$sumtype', '$interface'] && !is_declared_kind(text) {
			holds = false
		} else if test == '$struct' {
			holds = inf.is_struct_type(t) or { continue }
		} else {
			holds = type_is(t, test, false, mut inf) or { continue }
		}
		if holds == negated {
			return false
		}
	}
	return true
}

// same_type reports whether a field of type `t` is of the type `want`, written in `file`,
// as V's `field.typ is want` decides it: on the whole type, so `&Foo`, `?Foo` and
// `[]Foo` are not `Foo`. A reference, option, array, map or primitive is that type as
// written; a named type is its declaration, read where each is written. none when that
// can't be told, such as `[]Foo` against `[]mod.Foo`.
fn (inf &Infer) same_type(t InferredType, want string, file string) ?bool {
	raw := t.text.trim_space()
	w := want.trim_space()
	if !is_declared_kind(raw) || !is_declared_kind(w) || raw.contains('[') || w.contains('[') {
		if raw == w {
			return true
		}
		if raw.contains('.') || w.contains('.') {
			return none
		}
		return false
	}
	// `Foo` in the struct's module and `Foo` in the loop's can be two types: each is the
	// declaration its own file sees, and the same text only when one has none
	rd := inf.find_type(raw.all_after_last('.'), if raw.contains('.') {
		raw.all_before_last('.')
	} else {
		''
	}, t, t.file) or {
		if raw == w {
			return true
		}
		return none
	}
	scope := inf.scope_of[file] or { FileScope{} }
	wt := InferredType{
		text: w
		mod:  scope.mod
		file: file
	}
	wd := inf.find_type(w.all_after_last('.'), if w.contains('.') {
		w.all_before_last('.')
	} else {
		''
	}, wt, file) or {
		if raw == w {
			return true
		}
		return none
	}
	return rd.id == wd.id
}

// names_same_type reports whether `t`, a receiver's type, is the type `loop` that a
// field loop in `file` walks the fields of (`$for field in Data.fields`): the same
// declaration, a reference to it included, or the same text when neither is declared.
fn (inf &Infer) names_same_type(t InferredType, loop string, file string) bool {
	rt := strip_generic_args(bare_type(own_name(t)))
	lt := strip_generic_args(bare_type(loop))
	rd := inf.find_type(rt.all_after_last('.'), if rt.contains('.') {
		rt.all_before_last('.')
	} else {
		''
	}, t, t.file) or { return rt == lt }
	scope := inf.scope_of[file] or { FileScope{} }
	lw := InferredType{
		text: lt
		mod:  scope.mod
		file: file
	}
	ld := inf.find_type(lt.all_after_last('.'), if lt.contains('.') {
		lt.all_before_last('.')
	} else {
		''
	}, lw, file) or { return rt == lt }
	return rd.id == ld.id
}

// is_declared_kind reports whether a type text can name a struct, enum, sum type or
// interface: a named type that is not a primitive, an array, a map, a channel or a
// function type.
fn is_declared_kind(text string) bool {
	return is_named_type(text) && text !in primitive_types && !text.starts_with('map[')
		&& !text.starts_with('chan ') && !text.starts_with('fn ') && !text.starts_with('fn(')
		&& !text.starts_with('thread')
}

// is_struct_type reports whether `t` names a struct: a named type that is not a
// primitive, an array, a map, an enum, a sum type, an interface or an alias. none when
// no declaration names it.
fn (inf &Infer) is_struct_type(t InferredType) ?bool {
	text := bare_type(t.text)
	if !is_declared_kind(text) {
		return false
	}
	named := strip_generic_args(text)
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	decl := inf.find_type(short, qual, t, t.file)?
	return !inf.enum_ids[decl.id] && !inf.dynamic_ids[decl.id] && decl.id !in inf.alias_of
}

// method_owner is the id of the struct a method belongs to, `mod.Box` for
// `mod.Box[T].show` (or `mod.Box[T].show@file`).
fn method_owner(s Symbol) string {
	id := s.id.all_before('@')
	return strip_generic_args(id[..id.len - s.name.len - 1])
}

// is_type_param_text reports whether a type text is a single capital letter, as a
// type parameter is written (`T`, `R`, `K`).
fn is_type_param_text(t string) bool {
	return t.len > 0 && t.len <= 2 && t[0] >= u8(`A`) && t[0] <= u8(`Z`)
}

// param_types are the type texts of a free function's parameters, read from its
// signature: `pub fn f(a int, b []T) R` gives int and []T. A `mut` parameter is
// written with a leading `&` (`mut b []T` is `b &[]T`), which is not part of its type.
fn param_types(sig string) []string {
	open := sig.index('(') or { return []string{} }
	mut depth := 0
	mut parts := []string{}
	mut cur := ''
	for i := open + 1; i < sig.len; i++ {
		c := sig[i]
		if c == `)` && depth == 0 {
			break
		}
		if c == `(` || c == `[` || c == `{` {
			depth++
		} else if c == `)` || c == `]` || c == `}` {
			depth--
		}
		if c == `,` && depth == 0 {
			parts << cur
			cur = ''
			continue
		}
		cur += c.ascii_str()
	}
	if cur.trim_space() != '' {
		parts << cur
	}
	mut types := []string{}
	for p in parts {
		mut t := p.trim_space()
		for pre in ['mut ', 'shared ', 'noinit '] {
			if t.starts_with(pre) {
				t = t[pre.len..]
			}
		}
		if sp := t.index(' ') {
			types << t[sp + 1..].trim_space().trim_left('&')
		} else {
			types << t.trim_left('&')
		}
	}
	return types
}

// guarded_instances keeps the instances of the type parameter `tp` that the comptime
// conditions of a call (`guards`, see V3CallCtx.guarded) let the call compile for. A
// condition on another type parameter does not apply, and a test that type_is does not
// decide keeps the instance.
fn guarded_instances(insts []InferredType, guards string, tp string, mut inf Infer) []InferredType {
	if guards == '' {
		return insts
	}
	mut out := insts.clone()
	for g in guards.split(recipe_sep) {
		if g.len < 3 {
			continue
		}
		parts := g[1..].trim_space().split(' ')
		if parts.len != 3 || parts[1] != 'is' {
			continue
		}
		unaliased := parts[0].ends_with('.unaliased_typ')
		name := if unaliased { parts[0][..parts[0].len - '.unaliased_typ'.len] } else { parts[0] }
		if name != tp {
			continue
		}
		positive := g[0] == `+`
		mut kept := []InferredType{}
		for t in out {
			holds := type_is(t, parts[2], unaliased, mut inf) or {
				kept << t
				continue
			}
			if holds == positive {
				kept << t
			}
		}
		out = kept.clone()
	}
	return out
}

// type_is reports whether the type an instance stands for meets a comptime test: a
// kind (`$interface`, `$option`, `$array_dynamic`, `$array_fixed`, `$map`, `$enum`,
// `$sumtype`, `$int`, `$float`, `$bool`, `$string`) or a type's name. none for a test
// it does not decide, such as `$struct`, or a type that no declaration names.
fn type_is(t InferredType, test string, unaliased bool, mut inf Infer) ?bool {
	u := if unaliased { inf.unalias(t, t.file) } else { t }
	raw := u.text.trim_space()
	text := bare_type(raw)
	if !test.starts_with('$') {
		// an interface, or a generic one, is met by a type that has its methods, which is
		// not read here, so such a test keeps every instance
		if test.contains('[') {
			return none
		}
		test_short := test.all_after_last('.')
		test_qual := if test.contains('.') { test.all_before_last('.') } else { '' }
		if decl := inf.find_type(test_short, test_qual, u, t.file) {
			if inf.iface_ids[decl.id] {
				return none
			}
		}
		return text.all_after_last('.') == test_short
	}
	match test {
		'$option' {
			return raw.starts_with('?')
		}
		'$array_dynamic' {
			return text.starts_with('[]')
		}
		'$array_fixed' {
			return text.starts_with('[') && !text.starts_with('[]')
		}
		'$map' {
			return text.starts_with('map[')
		}
		'$int' {
			return text in ['int', 'i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'isize',
				'usize', 'byte', 'rune']
		}
		'$float' {
			return text in ['f32', 'f64']
		}
		'$bool' {
			return text == 'bool'
		}
		'$string' {
			return text == 'string'
		}
		'$interface', '$enum', '$sumtype' {
			named := strip_generic_args(text)
			short := named.all_after_last('.')
			qual := if named.contains('.') { named.all_before_last('.') } else { '' }
			decl := inf.find_type(short, qual, u, t.file) or { return none }
			return match test {
				'$interface' { inf.iface_ids[decl.id] }
				'$enum' { inf.enum_ids[decl.id] }
				else { inf.dynamic_ids[decl.id] && !inf.iface_ids[decl.id] }
			}
		}
		else {
			return none
		}
	}
}
