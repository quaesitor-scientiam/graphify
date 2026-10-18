module graphify

// A method call on a type parameter of a generic function, `v.describe()` where
// `v T`, has no type of its own, so it is linked to the method of each type the
// function is called with. The types come from the call sites that resolved to
// the function: the type of an argument whose parameter is `T` (or the element of
// one whose parameter is `[]T`), read from the argument recipes the extraction
// recorded (Edge.arg_sites).

// expand_type_param_calls returns the edges with each method call on a type
// parameter replaced by the methods of the types its function is called with, as
// `inferred` edges. A call with no such type stays as it was. `funcs` holds the
// generic free functions and the methods of generic structs, by id. A method of a
// generic struct, `Box[T].show`, is called on the types its struct is instantiated
// with, at the receivers of its methods (`sources`, the edges as the extraction
// recorded them, since a resolved edge drops its receiver) and in the types of the
// struct fields that are generic instances (`fields`).
fn expand_type_param_calls(edges []Edge, sources []Edge, fields []Symbol, mut inf Infer, funcs map[string]Symbol) []Edge {
	// the types each type parameter of a generic function was given at its call
	// sites, by `<function id>\x00<type parameter>`
	mut types := map[string][]InferredType{}
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
		ptypes := param_types(callee.signature)
		sites := e.arg_sites.split(arg_site_end)
		for si, site in sites {
			if si == sites.len - 1 || site == '' {
				continue
			}
			args := site.split('\x0b')
			for j, recipe in args {
				if recipe == '' || j >= ptypes.len {
					continue
				}
				for tp in tps {
					if ptypes[j] != tp && ptypes[j] != '[]' + tp {
						continue
					}
					t := inf.follow(Edge{
						from:        e.from
						file:        e.file
						recv_recipe: recipe
					}) or { continue }
					mut text := bare_type(t.text)
					if ptypes[j] != tp {
						if !text.starts_with('[]') {
							continue
						}
						text = text[2..]
					}
					if text == '' || is_type_param_text(text) {
						continue
					}
					key := callee.id + '\x00' + tp
					existing := types[key] or { []InferredType{} }
					if !existing.any(it.text == text) {
						mut known := existing.clone()
						known << InferredType{
							text: text
							mod:  t.mod
							file: t.file
						}
						types[key] = known
					}
				}
			}
		}
	}
	// the types each type parameter of a generic struct was instantiated with, by
	// `<struct id>\x00<position of the parameter>`: at the receivers of its methods, and
	// in the type of a field, `c Choi[Aa]`
	mut owner_types := map[string][]InferredType{}
	for e in sources {
		if e.kind != .calls || !e.is_method {
			continue
		}
		recv := inf.receiver(e) or { continue }
		add_owner_types(mut owner_types, recv.text, recv.mod, recv.file, generic_params(funcs[e.from] or { Symbol{} }))
	}
	for f in fields {
		// a field's type is written in its struct's module, and a type parameter of its
		// struct is not an instance of anything
		add_owner_types(mut owner_types, f.signature.all_after(' '), f.parent.all_before_last('.'), f.file, generic_params(funcs[f.parent] or { Symbol{} }))
	}
	if types.len == 0 && owner_types.len == 0 {
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
			out << e
			continue
		}
		mut recv_text := bare_type(recv.text)
		// a field or element typed by its owner's type parameter comes back qualified by
		// the module, `demo.T` for `T`, which is still the parameter
		if recv.mod != '' && recv_text.starts_with(recv.mod + '.')
			&& recv_text[recv.mod.len + 1..] in tps {
			recv_text = recv_text[recv.mod.len + 1..]
		}
		if recv_text !in tps {
			out << e
			continue
		}
		mut insts := []InferredType{}
		if caller.kind == .method {
			mut pos := 0
			for i, tp in tps {
				if tp == recv_text {
					pos = i
				}
			}
			insts = owner_types[method_owner(caller) + '\x00' + pos.str()] or {
				out << e
				continue
			}
		} else {
			insts = types[caller.id + '\x00' + recv_text] or {
				out << e
				continue
			}
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
			}
		}
	}
	return out
}

// add_owner_types records one instance of a generic struct, `Box[Pen]` written in
// module `mod`, under the struct and the position of each type argument. An argument
// in `skip`, a type parameter of the enclosing declaration, is not a type.
fn add_owner_types(mut owner_types map[string][]InferredType, text string, mod string, file string, skip []string) {
	args := split_type_args(text)
	if args.len == 0 {
		return
	}
	owner := qualify_type_names(strip_generic_args(bare_type(text)), mod)
	for i, arg in args {
		arg_text := bare_type(arg)
		if arg_text == '' || arg_text in skip {
			continue
		}
		key := owner + '\x00' + i.str()
		existing := owner_types[key] or { []InferredType{} }
		if !existing.any(it.text == arg_text) {
			mut known := existing.clone()
			known << InferredType{
				text: arg_text
				mod:  mod
				file: file
			}
			owner_types[key] = known
		}
	}
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
