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
// free functions that have type parameters, by id.
fn expand_type_param_calls(edges []Edge, mut inf Infer, funcs map[string]Symbol) []Edge {
	// the types each type parameter of a generic function was given at its call
	// sites, by `<function id>\x00<type parameter>`
	mut types := map[string][]InferredType{}
	for e in edges {
		if e.kind != .calls || e.is_method || e.arg_sites == '' {
			continue
		}
		callee := funcs[e.to] or { continue }
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
	if types.len == 0 {
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
		recv_text := bare_type(recv.text)
		if recv_text !in tps {
			out << e
			continue
		}
		insts := types[caller.id + '\x00' + recv_text] or {
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
			}
		}
	}
	return out
}

// generic_params are a free function's type parameters, which its symbol records
// comma-separated in its recipe; none for a function that has none, or a method.
fn generic_params(s Symbol) []string {
	if s.kind != .function || s.recipe == '' {
		return []string{}
	}
	return s.recipe.split(',')
}

// is_type_param_text reports whether a type text is a single capital letter, as a
// type parameter is written (`T`, `R`, `K`).
fn is_type_param_text(t string) bool {
	return t.len > 0 && t.len <= 2 && t[0] >= u8(`A`) && t[0] <= u8(`Z`)
}

// param_types are the type texts of a free function's parameters, read from its
// signature: `pub fn f(a int, b []T) R` gives int and []T.
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
			types << t[sp + 1..].trim_space()
		} else {
			types << t
		}
	}
	return types
}
