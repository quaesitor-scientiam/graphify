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
fn expand_type_param_calls(edges []Edge, sources []Edge, fields []Symbol, mut inf Infer, funcs map[string]Symbol) []Edge {
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
	if instances.len == 0 {
		return edges
	}
	mut out := []Edge{cap: edges.len}
	for e in edges {
		if e.kind != .calls || !e.is_method || e.to.contains('.') || e.provenance == .undeclared {
			out << e
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
			}
		}
	}
	return out
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
