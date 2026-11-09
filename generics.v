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
// A call the expansion links, `t.put(Pen{})` on a `t T`, can reach a method with type
// parameters of its own, which the call's arguments give types; those are known only once
// the call is linked, so the expansion is done again from the start, over `edges`, while
// such calls give a type not known before (a chain of them is short, so a few passes reach
// the end).
fn expand_type_param_calls(edges []Edge, sources []Edge, fields []Symbol, mut inf Infer, funcs map[string]Symbol, unaddressable map[string]bool, variants_of map[string][]string) []Edge {
	// the types each type parameter stands for, by instance_key
	mut instances := map[string][]InferredType{}
	mut flows := []Flow{}
	// the type parameters a call site gives a type this can't read (collect_call_sites)
	mut opaque := map[string]bool{}
	collect_call_sites(edges, funcs, mut inf, mut instances, mut flows, mut opaque)
	collect_owner_instances(sources, fields, funcs, mut inf, mut instances, mut flows)
	settle_flows(mut instances, flows)
	// a call under a comptime check has a type with no instance at all (guarded_instances), and
	// only_v_provides needs none
	if instances.len == 0 && !edges.any(it.guards != '' || (it.is_method
		&& (has_field_any(it.recv_recipe) || it.to in v_provided_methods))) {
		return edges
	}
	// the passes that look for new types only collect the calls they link; the expanded edges
	// are built once, with every type known. Only a method with type parameters of its own
	// takes a type from a linked call (passes_own_params), so without one no pass is needed
	mut reached := []Edge{}
	if funcs.values().any(it.kind == .method && it.tparams != '') {
		_, reached = expand_edges(edges, instances, opaque, funcs, mut inf, unaddressable,
			variants_of, false)
	}
	for _ in 0 .. 4 {
		// the calls just linked give types to the methods they reach; when they give a new
		// one, the expansion is done again from the start, so a call it already linked, or
		// resolved by name for want of an instance, is linked with every type known now
		before := instance_count(instances)
		collect_call_sites(reached, funcs, mut inf, mut instances, mut flows, mut opaque)
		settle_flows(mut instances, flows)
		if instance_count(instances) == before {
			break
		}
		_, reached = expand_edges(edges, instances, opaque, funcs, mut inf, unaddressable,
			variants_of, false)
	}
	settle_opaque(mut opaque, flows)
	out, _ := expand_edges(edges, instances, opaque, funcs, mut inf, unaddressable, variants_of,
		true)
	return out
}

// instance_count is how many types `instances` records in all, which only grows
// (put_instance), so a change in it is a new type.
fn instance_count(instances map[string][]InferredType) int {
	mut n := 0
	for _, ts in instances {
		n += ts.len
	}
	return n
}

// collect_call_sites records the types a generic function's type parameters, or a method's
// own, are given at the call sites `edges` record, from their argument recipes: an instance
// of the parameter, or a flow from the caller's parameter it passes on. A call site that gives a
// parameter neither (an argument with no known type, a parameter such as `map[K]V`) marks it
// `opaque`: its instances are then not all known.
fn collect_call_sites(edges []Edge, funcs map[string]Symbol, mut inf Infer, mut instances map[string][]InferredType, mut flows []Flow, mut opaque map[string]bool) {
	for e in edges {
		if e.kind != .calls || e.arg_sites == '' {
			continue
		}
		callee := funcs[e.to] or { continue }
		if callee.kind != .function && callee.kind != .method {
			continue
		}
		// a method's receiver type parameters come from its receivers (below), its own from
		// its arguments
		tps := own_params(callee)
		if tps.len == 0 {
			continue
		}
		caller := funcs[e.from] or { Symbol{} }
		caller_tps := generic_params(caller)
		// a method's parameters are read past its receiver, `fn (e Encoder) encode(val T)`
		ptypes := param_types(if callee.kind == .method {
			callee.signature.all_after(') ')
		} else {
			callee.signature
		})
		sites := e.arg_sites.split(arg_site_end)
		// the parameters the call site being read has given a type, and whether one was begun
		mut given := []string{}
		mut in_site := false
		for si, site in sites {
			if site.starts_with('at:') || si == sites.len - 1 {
				if in_site {
					for tp in tps {
						if tp !in given {
							opaque[callee.id + '\x00' + tp] = true
						}
					}
				}
				given = []string{}
				in_site = site.starts_with('at:')
				continue
			}
			if site == '' {
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
						given << tps[j]
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
					given << tps[j]
				}
				continue
			}
			args := site.split('\x0b')
			variadic := if ptypes.len > 0 && ptypes.last().starts_with('...') {
				ptypes.last()
			} else {
				''
			}
			for j, arg in args {
				if arg == '' || (j >= ptypes.len && variadic == '') {
					continue
				}
				// each argument at or past a variadic parameter, `args ...T`, is one of its values,
				// a T, unless it spreads an array of them, `...xs`, a []T
				mut ptype := if j < ptypes.len { ptypes[j] } else { variadic }
				mut recipe := arg
				if ptype.starts_with('...') {
					if recipe.ends_with(recipe_sep + spread_step) {
						recipe = recipe[..recipe.len - recipe_sep.len - spread_step.len]
						ptype = '[]' + ptype[3..]
					} else {
						ptype = ptype[3..]
					}
				}
				for tp in tps {
					// a function-typed parameter, `h fn () H`, is typed by what the function its argument
					// names returns: the argument is a function-typed value, or a function named as a value
					returns_tp := (fn_return(ptype) or { '' }) == tp
					if ptype != tp && ptype != '[]' + tp && !returns_tp {
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
					} else if ptype != tp {
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
						given << tp
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
					given << tp
				}
			}
		}
	}
}

// collect_owner_instances records the types a generic struct's type parameters are
// instantiated with, at the receivers of its methods (`sources`), and in the types of its
// fields (`fields`).
fn collect_owner_instances(sources []Edge, fields []Symbol, funcs map[string]Symbol, mut inf Infer, mut instances map[string][]InferredType, mut flows []Flow) {
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
}

// settle_flows gives each type parameter that is passed on the types of the one it is
// passed from; a chain of generic calls is short, so a few rounds reach the fixed point.
fn settle_flows(mut instances map[string][]InferredType, flows []Flow) {
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
}

// settle_opaque marks a type parameter opaque when one it is passed from is: its types are the
// other's, not all known.
fn settle_opaque(mut opaque map[string]bool, flows []Flow) {
	for _ in 0 .. 16 {
		mut changed := false
		for fl in flows {
			if opaque[fl.src] && !opaque[fl.dst] {
				opaque[fl.dst] = true
				changed = true
			}
		}
		if !changed {
			break
		}
	}
}

// expand_edges is one pass of expand_type_param_calls over `edges`: each call on a type
// parameter that `instances` lets it link is replaced by the methods it reaches, each
// keeping the call's argument recipes. It also returns those new edges that pass arguments
// to a method with type parameters of its own (passes_own_params), whose types a next pass
// collects. Unless `keep`, it returns only those: the expanded edges, a copy of all of
// `edges`, are built once, by the last pass.
fn expand_edges(edges []Edge, instances map[string][]InferredType, opaque map[string]bool, funcs map[string]Symbol, mut inf Infer, unaddressable map[string]bool, variants_of map[string][]string, keep bool) ([]Edge, []Edge) {
	mut out := []Edge{cap: if keep { edges.len } else { 0 }}
	// the linked calls that pass arguments to a method with type parameters of its own
	mut reached := []Edge{}
	// the edges of the calls in field loops, joined to the rest once every edge is out
	// (see merge_call_edges)
	mut field_edges := []Edge{}
	for e in edges {
		// a static call on a type parameter, `T.parse(mut p)`, is each instance's static: its own,
		// or through an alias the first type that declares it (static_along), or for an enum the
		// `from` and `from_string` V generates. As for a method call below, the declared ones are
		// linked, and the call is V's only when every instance is known and gets it from V
		if e.kind == .calls && !e.is_method && e.provenance != .undeclared && !e.to.contains('.')
			&& e.to.contains('__static__') {
			if caller := funcs[e.from] {
				tp := e.to.all_before('__static__')
				if tp in generic_params(caller) {
					method := e.to.all_after('__static__')
					key := instance_key(caller, tp)
					insts := guarded_instances(instances[key] or { []InferredType{} }, e.guards,
						tp, e.file, mut inf)
					mut ids := []string{}
					mut generated := 0
					// an instance of a generic struct, `Box[int]`, finds no static: V refuses `T.make()` there
					for t in insts {
						scope := instance_scope(t, e.file, inf)
						if id := inf.type_static(t, method, scope) {
							if id !in ids {
								ids << id
							}
						} else if method in ['from', 'from_string'] && inf.is_enum(t, scope) {
							generated++
						}
					}
					if ids.len == 0 {
						if keep {
							out << if insts.len > 0 && generated == insts.len && !opaque[key] {
								Edge{
									...e
									provenance: .undeclared
								}
							} else {
								e
							}
						}
						continue
					}
					for id in ids {
						ne := Edge{
							from:       e.from
							to:         id
							kind:       .calls
							file:       e.file
							provenance: .inferred
							arg_sites:  e.arg_sites
							lines:      e.lines
							build:      e.build
						}
						if keep {
							out << ne
						}
						if passes_own_params(e, id, funcs) {
							reached << ne
						}
					}
					continue
				}
			}
		}
		if e.kind != .calls || !e.is_method || e.to.contains('.') || e.provenance == .undeclared {
			if keep {
				out << e
			}
			continue
		}
		if has_field_any(e.recv_recipe) {
			// a call on `x.$(field.name)` in a field loop is a call on each field the loop
			// reaches, in a function that may have no type parameters at all
			caller := funcs[e.from] or { Symbol{} }
			ids := field_any_ids(e, caller, generic_params(caller), instances, mut inf)
			if ids.len == 0 {
				fallback := field_any_fallback(e, mut inf, unaddressable, variants_of)
				for fe in fallback {
					if fe.to != e.to && passes_own_params(e, fe.to, funcs) {
						reached << fe
					}
				}
				field_edges << fallback
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
						arg_sites:  e.arg_sites
						lines:      e.lines
						build:      e.build
					}
					if passes_own_params(e, vid, funcs) {
						reached << field_edges.last()
					}
				}
			}
			continue
		}
		caller := funcs[e.from] or {
			if keep {
				out << e
			}
			continue
		}
		tps := generic_params(caller)
		if tps.len == 0 {
			if keep {
				out << e
			}
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
				if keep {
					out << e
				}
			}
			for id in chained {
				ne := Edge{
					from:       e.from
					to:         id
					kind:       .calls
					is_method:  true
					file:       e.file
					provenance: .inferred
					arg_sites:  e.arg_sites
					lines:      e.lines
					build:      e.build
				}
				if keep {
					out << ne
				}
				if passes_own_params(e, id, funcs) {
					reached << ne
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
							if keep {
								out << Edge{ ...e, provenance: .undeclared }
							}
							continue
						}
					}
				}
			}
			if keep {
				out << e
			}
			continue
		}
		insts := guarded_instances(instances[instance_key(caller, recv_text)] or { []InferredType{} }, e.guards, recv_text, e.file, mut inf)
		mut ids := []string{}
		for t in insts {
			id := inf.method_on(t, e.to, instance_scope(t, e.file, inf), 0) or { continue }
			if id !in ids {
				ids << id
			}
		}
		// with no instance that answers a method the block calls, its `$if T is Iface` makes it the
		// interface's, as on a value of that type
		if ids.len == 0 {
			if id := guard_interface_method(e, recv_text, mut inf) {
				ids << id
			}
		}
		if ids.len == 0 {
			if keep {
				out << if only_v_provides(e, inf) || (insts.len > 0
					&& !opaque[instance_key(caller, recv_text)] && written_for_all(e, insts, inf)) {
					Edge{
						...e
						provenance: .undeclared
					}
				} else {
					e
				}
			}
			continue
		}
		for id in ids {
			ne := Edge{
				from:       e.from
				to:         id
				kind:       .calls
				is_method:  true
				file:       e.file
				provenance: .inferred
				arg_sites:  e.arg_sites
				lines:      e.lines
				build:      e.build
			}
			if keep {
				out << ne
			}
			if passes_own_params(e, id, funcs) {
				reached << ne
			}
		}
	}
	if keep {
		merge_call_edges(mut out, field_edges)
	}
	return out, reached
}

// written_for_all reports whether the call `e` on a type parameter is one V writes for each of its
// known instances, `insts`, none of which declares it, as no_method decides for a receiver of that
// type: `str()`, or `type_name()` and `type_idx()` on a sum type or interface, say. An instance
// with no declaration in the tree isn't one V's rule can be read for.
fn written_for_all(e Edge, insts []InferredType, inf &Infer) bool {
	for t in insts {
		if (inf.no_method(t, e.to, instance_scope(t, e.file, inf)) or { return false }) != '' {
			return false
		}
	}
	return true
}

// guard_interface_method is the method of the call `e` on the interface a positive comptime
// condition of the call holds the type parameter `tp` to, or none. Never `str()`, which V writes
// for a type that declares none, an implementer of the interface or not.
fn guard_interface_method(e Edge, tp string, mut inf Infer) ?string {
	if e.guards == '' || e.to == 'str' {
		return none
	}
	for g in e.guards.split(recipe_sep) {
		if g.len < 3 {
			continue
		}
		parts := g[1..].trim_space().split(' ')
		if g[0] != `+` || parts.len != 3 || parts[0].trim_string_right('.unaliased_typ') != tp
			|| parts[1] != 'is' || !names_one_interface(parts[2], e.file, inf) {
			continue
		}
		scope := inf.scope_of[e.file] or { FileScope{} }
		if id := inf.method_on(InferredType{ text: parts[2], mod: scope.mod, file: e.file }, e.to, e.file, 0) {
			return id
		}
	}
	return none
}

// only_v_provides reports whether the call `e` on a type parameter can only be a method V writes
// for a sum type or interface: whichever instance it compiles for has the method, and nothing in
// the graph declares one of the name, so no instance known or not need be read. A type that isn't
// part of the graph could still declare it, as a struct may.
fn only_v_provides(e Edge, inf &Infer) bool {
	return e.to in v_provided_methods && e.to !in inf.by_name && !inf.has_fn_field(e.to)
}

// has_fn_field reports whether a struct declares a field `name` a call can be of: one of a function
// type, written or named. A field of another type can't be called.
fn (inf &Infer) has_fn_field(name string) bool {
	suffix := '\x00${name}'
	for key, text in inf.field_type {
		if !key.ends_with(suffix) {
			continue
		}
		bare := bare_type(text)
		if holds_fns(bare) {
			return true
		}
		cands := inf.by_type_name[strip_generic_args(bare).all_after_last('.')] or { continue }
		if cands.any(holds_fns(inf.alias_of[it.id] or { '' })) {
			return true
		}
	}
	return false
}

// names_one_interface reports whether a comptime test names an interface itself, not a kind, an
// array of one or a pointer to one (`[]Iface`, `&Iface`, each a concrete type), read in `file`.
fn names_one_interface(test string, file string, inf &Infer) bool {
	return !test.starts_with('$') && !test.starts_with('[') && !test.starts_with('&')
		&& inf.names_interface(test, file)
}

// is_interface_member reports whether a method's signature is that of a method an interface's body
// declares, `fn (Speaker) say()`, whose receiver has no name, which an implementer must have. A
// method written with a body, `fn (s Speaker) shout()`, has one, and isn't asked of an implementer.
fn is_interface_member(sig string) bool {
	return sig.starts_with('fn (') && !sig.all_after('fn (').all_before(')').all_before('[').contains(' ')
}

// v_provided_methods are the methods V writes for a sum type or interface, and refuses or ignores a
// declaration of.
const v_provided_methods = ['type_name', 'type_idx']

// passes_own_params reports whether the call `e`, linked to `id`, passes arguments to a
// method with type parameters of its own, which they give types (see own_params).
fn passes_own_params(e Edge, id string, funcs map[string]Symbol) bool {
	callee := funcs[id] or { return false }
	return callee.kind == .method && e.arg_sites != '' && own_params(callee).len > 0
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
			arg_sites:  e.arg_sites
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
// method or a field of the struct has, and `<method id>\x00<tp>` for a method's own.
// `tp` must be one of the caller's parameters.
fn instance_key(caller Symbol, tp string) string {
	if caller.kind == .function || (caller.kind == .method && tp in own_params(caller)) {
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
// symbol records comma-separated in its recipe, and then a method's own, `X` in
// `fn (b Box[T]) put[X]()`, from its tparams; none for one that has none.
fn generic_params(s Symbol) []string {
	if s.kind != .function && s.kind != .method && s.kind != .struct_ {
		return []string{}
	}
	mut out := if s.recipe == '' { []string{} } else { s.recipe.split(',') }
	if s.kind == .method && s.tparams != '' {
		out << s.tparams.split(',')
	}
	return out
}

// own_params are a method's own type parameters, `X` in `fn (b Box[T]) put[X]()`, which
// its call sites give types as a generic function's do; a free function's are all its own.
fn own_params(s Symbol) []string {
	if s.kind == .method {
		return if s.tparams == '' { []string{} } else { s.tparams.split(',') }
	}
	return generic_params(s)
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
	for t in guarded_instances(instances[instance_key(caller, tp)] or { []InferredType{} }, e.guards, tp, e.file, mut inf) {
		// one element of an array is what path_method_ids reads, not the voidptr builtin declares
		if t.text.starts_with('[') && method in array_elem_methods {
			continue
		}
		result_id := inf.method_on(t, method, instance_scope(t, e.file, inf), 0) or { continue }
		result := inf.returns(result_id) or { continue }
		id := inf.method_on(result, e.to, instance_scope(result, e.file, inf), 0) or { continue }
		if id !in ids {
			ids << id
		}
	}
	return ids
}

// instance_scope is the file a method of `t`, an instance of a type parameter or a type reached
// from one, is looked up from for a call in `file`. A generic function in a non-test file that a
// `_test.v` file instantiates is compiled with that test, so a type the test declares has the
// methods the test file sees: `t` is read in the file that declares it, as path_method_ids reads
// an instance. A call in a test file keeps its own file, since no test file sees another.
fn instance_scope(t InferredType, file string, inf &Infer) string {
	if is_test_file(file) {
		return file
	}
	short := strip_generic_args(bare_type(t.text)).all_after_last('.')
	declared := inf.declared_file(short, t.mod, t.file)
	return if is_test_file(declared) { declared } else { file }
}

// path_method_ids are the methods a call reaches through a field, or a call, of a type
// parameter's instances: `ctx.req.header.get()` on a `ctx T` walks the recipe `t:T | f:req |
// f:header` from each instance of T in place of T, in the file the instance is written in,
// and finds `get` on the header the instance's field has. Empty unless the recipe starts at a
// type parameter, an element of a `[]T` or a lambda's parameter typed T, and has steps after it.
fn path_method_ids(e Edge, caller Symbol, tps []string, instances map[string][]InferredType, mut inf Infer) []string {
	steps := e.recv_recipe.split(recipe_sep)
	if steps.len < 2 {
		return []string{}
	}
	mut start := 1
	mut tp := ''
	if steps[0].starts_with('t:') {
		// an element of a `[]T`, `x.name.up()` for `x` in `xs []T` (a `for` loop, `it`, or a lambda
		// of builtin's array methods, whose `lm:` step is an element, see
		// Infer.method_lambda_param), is a T: the path is walked from each instance as it is from a T
		mut text := steps[0][2..]
		elem_step := steps[1] == '[]'
			|| (steps[1].starts_with('lm:') && steps[1][3..].all_before(':') in lambda_elem_methods)
		if text.starts_with('[]') && elem_step && steps.len > 2 {
			text = text[2..].trim_left('&')
			start = 2
		}
		tp = plain_param(text, '', tps) or { return []string{} }
	} else if steps[0].starts_with('lc:') {
		// a lambda's parameter a call types as the caller's T, `ddd(|x, y| x.name.up(), a, b)` with
		// `a T` (Infer.lambda_param): the path after its `lp:` step, as field_any_receiver follows
		// a prefix to a type parameter
		at := steps.index(steps.filter(it.starts_with('lp:'))[0] or { return []string{} })
		if at + 1 >= steps.len {
			return []string{}
		}
		t := inf.follow(Edge{
			from:        e.from
			file:        e.file
			recv_recipe: steps[..at + 1].join(recipe_sep)
		}) or { return []string{} }
		tp = plain_param(t.text, t.mod, tps) or { return []string{} }
		start = at + 1
	} else {
		return []string{}
	}
	rest := steps[start..].join(recipe_sep)
	mut ids := []string{}
	for t in guarded_instances(instances[instance_key(caller, tp)] or { []InferredType{} }, e.guards, tp, e.file, mut inf) {
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
		id := inf.method_on(recv, e.to, instance_scope(recv, e.file, inf), 0) or { continue }
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
			e.guards, tp, e.file, mut inf)
	} else {
		if loop != '' && !inf.names_same_type(recv_type, loop, e.file) {
			return []string{}
		}
		owners << recv_type
	}
	mut ids := []string{}
	for o in owners {
		// builtin's `map` stands for a map (guarded_instances), and V's loop walks no field of one
		if tp != '' && o.text == 'map' {
			continue
		}
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
			id := inf.method_on(recv, e.to, instance_scope(recv, e.file, inf), 0) or {
				inf.platform_copy_method(recv, e.to, e.file) or { continue }
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
// method_on takes for several methods; variants_of links every copy of it. Only copies in
// platform files count, as variants_of groups them, and not one that a `_test.v` file
// keeps to itself, which `file`, the caller's, can't see (test_private). none when `t` has
// no such method.
fn (inf &Infer) platform_copy_method(t InferredType, name string, file string) ?string {
	named := strip_generic_args(bare_type(t.text))
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	decl := inf.find_type(short, qual, t, t.file)?
	want := decl.id + '.' + name
	for c in inf.by_name[name] or { []CallCand{} } {
		if c.is_method && c.id.contains('@') && c.id.all_before('@') == want
			&& is_platform_file(c.file) && !test_private(c.file, file) {
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
// `[]Foo` are not `Foo`. The wrapping `&`, `?` and array brackets must match as written
// (split_type_shape); inside them a primitive is its name, a named type its declaration,
// read where each side is written, and a map, function or generic instance its text, in
// one module only. none when that can't be told.
fn (inf &Infer) same_type(t InferredType, want string, file string) ?bool {
	// `&`, `?` and the array brackets are compared as written, and the type inside them as
	// the rest of this function compares a type
	raw_shape, raw := split_type_shape(t.text)
	want_shape, w := split_type_shape(want)
	if raw_shape != want_shape {
		return false
	}
	if raw in primitive_types || w in primitive_types {
		return raw == w
	}
	scope := inf.scope_of[file] or { FileScope{} }
	if !is_declared_kind(raw) || !is_declared_kind(w) || raw.contains('[') || w.contains('[') {
		// a map, a function or a generic instance: the same text names the same type only in
		// one module, since the names inside it are each module's own
		if t.mod != scope.mod {
			return none
		}
		if raw == w {
			return true
		}
		if raw.contains('.') || w.contains('.') {
			return none
		}
		return false
	}
	t_inner := InferredType{
		...t
		text: raw
	}
	// `Foo` in the struct's module and `Foo` in the loop's can be two types: each is the
	// declaration its own file sees, and the same text only when one has none
	rd := inf.find_type(raw.all_after_last('.'), if raw.contains('.') {
		raw.all_before_last('.')
	} else {
		''
	}, t_inner, t.file) or {
		if raw == w && t.mod == scope.mod {
			return true
		}
		return none
	}
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
		// the same text names the same type only in one module: a selectively imported
		// `Foo` in the loop's file is another module's
		if raw == w && t.mod == scope.mod {
			return true
		}
		return none
	}
	return rd.id == wd.id
}

// split_type_shape splits a type text into what wraps a named type, its leading `&`, `?`
// and `!` and array brackets (`[]`, `[4]`), and the type inside: `&[]Foo` is `&[]` and
// `Foo`. A map, a function or a generic instance stays whole inside.
fn split_type_shape(text string) (string, string) {
	mut s := text.trim_space()
	mut shape := ''
	for s.len > 0 {
		if s[0] in [`&`, `?`, `!`] {
			shape += s[..1]
			s = s[1..].trim_space()
		} else if s.starts_with('[') {
			end := s.index(']') or { break }
			shape += s[..end + 1]
			s = s[end + 1..]
		} else {
			break
		}
	}
	return shape, s
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

// param_types are the type texts of a function's parameters, read from its signature
// (a method's from past its receiver): `pub fn f(a int, b []T) R` gives int and []T. A `mut` parameter is
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
		// a parameter of a function type written without names, `fn (fn (Foo) string)`, is all type
		if t.starts_with('fn ') || t.starts_with('fn(') {
			types << t
		} else if sp := t.index(' ') {
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
// decide keeps the instance. When a positive condition names a type and no instance meets it,
// the block still compiles for that type, as a function nothing in the tree instantiates with
// it still says: `$if T.unaliased_typ is string` is `string`, read in `file`, and a kind is its
// builtin type (builtin_of_kind), each of them when a condition names several kinds
// (`$array_dynamic|$map`, see comptime_kind_union). This is what the walk does for `$if T is X`,
// which retypes a variable typed T as X (backend_v.v, comptime_type_is) whatever the instances are;
// this covers the forms it doesn't read, such as `T.unaliased_typ`. An interface has no stand-in: a
// block under it keeps T, and guard_interface_method reads it for a method no instance answers.
fn guarded_instances(insts []InferredType, guards string, tp string, file string, mut inf Infer) []InferredType {
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
		tests := parts[2].split('|')
		// an interface is met by a type that has its methods (lacks_interface), not by its name (see
		// type_is). The name is the guard's own file's: an instance's file may not see it, and would
		// then compare the instance's name with it
		undecided := names_one_interface(parts[2], file, inf)
		// the block of `$if T is Foo`, the form the walk retypes, is only read for an interface: V's
		// `is` also takes an alias of Foo, and Foo may be another type parameter
		_, retyped := comptime_type_is(g[1..])
		if positive && !unaliased && !undecided && retyped != '' {
			continue
		}
		mut kept := []InferredType{}
		for t in out {
			if undecided {
				if !positive || !inf.lacks_interface(t, parts[2], file) {
					kept << t
				}
				continue
			}
			holds := type_is_any(t, tests, unaliased, mut inf) or {
				kept << t
				continue
			}
			if holds == positive {
				kept << t
			}
		}
		// a stand-in for each kind or for none: one alone would read as all the block calls
		if kept.len == 0 && positive && tests.len > 1
			&& tests.all(if _ := builtin_of_kind(it) { true } else { false }) {
			scope := inf.scope_of[file] or { FileScope{} }
			for test in tests {
				kept << InferredType{
					text: builtin_of_kind(test) or { continue }
					mod:  scope.mod
					file: file
				}
			}
		}
		named := builtin_of_kind(parts[2]) or { parts[2] }
		if kept.len == 0 && positive && !named.starts_with('$') && !undecided {
			scope := inf.scope_of[file] or { FileScope{} }
			mut stand := InferredType{
				text: named
				mod:  scope.mod
				file: file
			}
			// a qualified name is the type its declaration names, as type_text reads `$if T is X`
			// for the walk: `json.Any` after `import x.json2 as json` is json2's `Any` (its
			// alias mapped to the import's path), as path_method_ids writes an instance
			if named.contains('.') {
				short := named.all_after_last('.')
				written := named.all_before_last('.')
				qual := scope.prefixes[written] or { written }
				if decl := inf.find_type(short, qual, stand, file) {
					stand = InferredType{
						text: short
						mod:  decl.mod
						file: decl.file
					}
				}
			}
			kept << stand
		}
		out = kept.clone()
	}
	return out
}

// builtin_of_kind is the builtin type every value of a comptime kind is, or none for another test:
// `map`, or `[]`, an array of an element not known, whose `first()` has no type (bare `array`'s is
// the voidptr builtin declares).
fn builtin_of_kind(test string) ?string {
	return match test {
		'$map' { 'map' }
		'$array_dynamic' { '[]' }
		else { none }
	}
}

// lacks_interface reports whether the instance `t` can't implement the interface `name` names in
// `file`: of what the interface declares it has no method of a name, a method with another number
// of parameters, or no field. It doesn't compare parameter types. false for a type no declaration
// names, which isn't read, and `str()` is not looked for, since V writes it.
fn (inf &Infer) lacks_interface(t InferredType, name string, file string) bool {
	text := bare_type(t.text)
	if is_named_type(text) {
		named := strip_generic_args(text)
		qual := if named.contains('.') { named.all_before_last('.') } else { '' }
		inf.named_decl(named.all_after_last('.'), qual, t, t.file) or { return false }
	}
	scope := inf.scope_of[file] or { FileScope{} }
	short := bare_type(name).all_after_last('.')
	qual := if name.contains('.') { name.all_before_last('.') } else { '' }
	decl := inf.find_type(short, qual, InferredType{ mod: scope.mod, file: file }, file) or {
		return false
	}
	return inf.lacks_members(t, decl, instance_scope(t, file, inf), 0)
}

// lacks_members is lacks_interface for the declaration of an interface, or of one it embeds. A
// member the lookups don't answer may still be there (see may_have_member), and a method they can't
// pick one of has no one parameter count to compare.
fn (inf &Infer) lacks_members(t InferredType, decl TypeCand, file string, depth int) bool {
	for method in inf.iface_fns[decl.id] {
		if method == 'str' {
			continue
		}
		id := inf.method_on(t, method, file, 0) or {
			if inf.may_have_member(t, method, true, file, 0) {
				continue
			}
			return true
		}
		wanted := inf.sig_of['${decl.id}.${method}'] or { continue }
		has := inf.sig_of[id] or { continue }
		// past the receiver, which param_types would read as the parameters
		if param_types(has.all_after(') ')).len != param_types(wanted.all_after(') ')).len {
			return true
		}
	}
	for field in inf.fields_of[decl.id] {
		inf.field_of(t, field, file, 0) or {
			if inf.may_have_member(t, field, false, file, 0) {
				continue
			}
			return true
		}
	}
	if depth < embed_depth {
		for emb in inf.embedded(decl) {
			if inf.lacks_members(t, emb, file, depth + 1) {
				return true
			}
		}
	}
	return false
}

// may_have_member reports whether `t` could have the method or field `name` that method_on or
// field_of didn't answer, which also means they couldn't tell: a declaration they can't pick one of
// (a copy per platform, `Box[int]` and `Box[string]`, a test file's, two embeds), an embed they don't
// follow this deep or that's outside the graph, a type no declaration names. Only a type whose whole
// declaration was read, with no such member, has none.
fn (inf &Infer) may_have_member(t InferredType, name string, method bool, file string, depth int) bool {
	text := bare_type(t.text)
	if !is_named_type(text) {
		return false
	}
	named := strip_generic_args(text)
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	decl := inf.named_decl(short, qual, t, file) or { return true }
	if method {
		for c in inf.by_name[name] or { []CallCand{} } {
			id := c.id.all_before('@')
			if c.is_method && c.mod == decl.mod && id.starts_with('${c.mod}.') && id.ends_with('.${name}')
				&& strip_generic_args(id[c.mod.len + 1..id.len - name.len - 1]) == short {
				return true
			}
		}
	} else if '${decl.id}\x00${name}' in inf.field_type {
		return true
	}
	// past its own, an alias has what it names
	if target := inf.alias_of[decl.id] {
		return bare_type(target) == text || depth >= embed_depth
			|| inf.may_have_member(InferredType{ text: target, mod: decl.mod, file: decl.file }, name, method, file, depth + 1)
	}
	embeds := inf.embedded(decl)
	if embeds.len != (inf.embeds_of[decl.id] or { []Edge{} }).len {
		return true
	}
	if embeds.len > 0 && depth >= embed_depth {
		return true
	}
	return embeds.any(inf.may_have_member(it.as_type(), name, method, file, depth + 1))
}

// type_is_any reports whether an instance meets any of `tests`: none when none of them is met and
// type_is doesn't decide one. A kind sees through an alias however the condition is written, as V's
// does, except `$bool`, which an alias of bool never meets, even as `T.unaliased_typ`.
fn type_is_any(t InferredType, tests []string, unaliased bool, mut inf Infer) ?bool {
	mut undecided := false
	for test in tests {
		through := test != '$bool' && (unaliased || test.starts_with('$'))
		holds := type_is(t, test, through, mut inf) or {
			undecided = true
			continue
		}
		if holds {
			return true
		}
	}
	return if undecided { none } else { false }
}

// type_is_kinds are the comptime kinds type_is decides.
const type_is_kinds = ['$interface', '$option', '$array_dynamic', '$array_fixed', '$map', '$enum',
	'$sumtype', '$int', '$float', '$bool', '$string']

// type_is reports whether the type an instance stands for meets a comptime test: a
// kind (`$interface`, `$option`, `$array_dynamic`, `$array_fixed`, `$map`, `$enum`,
// `$sumtype`, `$int`, `$float`, `$bool`, `$string`) or a type's name. none for a test
// it does not decide, such as `$struct`, or a type that no declaration names.
fn type_is(t InferredType, test string, unaliased bool, mut inf Infer) ?bool {
	u := if unaliased { inf.unalias(t, t.file) } else { t }
	raw := u.text.trim_space()
	text := bare_type(raw)
	// an alias of a pointer, `type Pint = &int`, meets no type's name nor a kind read here, unaliased
	// or not. It does meet `$alias` and `T.unaliased_typ is $pointer`, which aren't, so stay undecided
	if unaliased && raw.starts_with('&') && bare_type(t.text) != text
		&& (!test.starts_with('$') || test in type_is_kinds) {
		return false
	}
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
			// bare `map` is the stand-in builtin_of_kind gives
			return text.starts_with('map[') || text == 'map'
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
