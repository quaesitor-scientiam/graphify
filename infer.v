module graphify

// Receiver type inference: resolve_edges' way of telling which `contains` a
// call `x.contains()` means when the code doesn't write x's type. At
// extraction, each such call records a recipe for x's type (see recipe in
// backend_v.v), such as "the return type of os.read_file, then the type of
// that type's field `name`". With the whole graph built, Infer follows the
// recipe through the signatures and field types the graph records, and picks
// the method of that name on the type it arrives at.
//
// It works only from declarations, never from the checker, so it stops where
// V would need inference of its own: a generic, an interface's methods, a
// module's const, a function value. Every such stop leaves the call to
// resolve_callee's usual narrowing.

// Infer holds what following a recipe needs to look up, built once per graph
// by resolve_edges.
struct Infer {
	by_name      map[string][]CallCand
	by_type_name map[string][]TypeCand
	site_of      map[string]DeclSite
	imports_of   map[string][]string
	scope_of     map[string]FileScope
	sig_of       map[string]string // fn/method id -> its signature
	name_of      map[string]string // fn/method id -> its name
	field_type   map[string]string // '<struct id>\x00<field>' -> its type
	alias_of     map[string]string // alias id -> the type it names (not a sum type)
mut:
	memo map[string]InferredType
}

// InferredType is a type as written in a declaration: `text` read in the
// scope of module `mod` and file `file`, where an unqualified name is that
// module's (or builtin's) and a qualified one names an import by its path.
struct InferredType {
mut:
	text string
	mod  string
	file string
}

// array_same_type are the array methods whose result has the receiver's type;
// builtin declares most of them as returning plain `array`, or not at all.
const array_same_type = ['clone', 'filter', 'reverse', 'sorted', 'sorted_with_compare', 'slice']

// infer_call resolves a call edge: a module-qualified callee by its prefix,
// and a method call by its receiver's inferred type when the name alone is
// ambiguous, falling back to resolve_callee's narrowing.
fn (mut inf Infer) infer_call(e Edge) ?CallResolution {
	if e.to.contains('.') {
		return resolve_qualified_callee(e, inf.by_name, inf.site_of, inf.scope_of)
	}
	if e.is_method && e.recv_type == '' && e.recv_recipe != '' {
		cands := inf.by_name[e.to] or { []CallCand{} }
		if _ := only_id(cands) {
		} else if t := inf.follow(e) {
			if id := inf.method_on(t, e.to, e.file) {
				return CallResolution{
					id:       id
					inferred: true
				}
			}
		}
	}
	return resolve_callee(e, inf.by_name, inf.site_of, inf.imports_of)
}

// follow evaluates the edge's recipe, or none where a step can't be taken.
fn (mut inf Infer) follow(e Edge) ?InferredType {
	key := '${e.file}\x00${e.from}\x00${e.recv_recipe}'
	if t := inf.memo[key] {
		return if t.text == '' { none } else { t }
	}
	t := inf.follow_steps(e) or { InferredType{} }
	inf.memo[key] = t
	return if t.text == '' { none } else { t }
}

fn (inf &Infer) follow_steps(e Edge) ?InferredType {
	steps := e.recv_recipe.split(recipe_sep)
	mut t := InferredType{}
	start := steps[0]
	if start.starts_with('t:') {
		scope := inf.scope_of[e.file] or { FileScope{} }
		t = InferredType{
			text: start[2..]
			mod:  scope.mod
			file: e.file
		}
	} else if start.starts_with('c:') {
		call := Edge{
			from: e.from
			to:   start[2..]
			kind: .calls
			file: e.file
		}
		mut id := ''
		if call.to.contains('.') {
			id = (resolve_qualified_callee(call, inf.by_name, inf.site_of, inf.scope_of)?).id
		} else {
			id = (resolve_callee(call, inf.by_name, inf.site_of, inf.imports_of)?).id
		}
		t = inf.returns(id)?
	} else {
		return none
	}
	for step in steps[1..] {
		t.text = bare_type(t.text)
		if t.text == '' {
			return none
		}
		if step.starts_with('m:') {
			name := step[2..]
			if t.text.starts_with('[') && name in array_same_type {
				continue
			}
			if t.text.starts_with('map[') && name in ['keys', 'values'] {
				k, v := map_parts(t.text)?
				t.text = '[]' + if name == 'keys' { k } else { v }
				continue
			}
			t = inf.returns(inf.method_on(t, name, e.file)?)?
		} else if step.starts_with('f:') {
			t = inf.field_of(t, step[2..], e.file)?
		} else if step == '[]' {
			t.text = elem_type(t.text)?
		} else if step == 'k' {
			if t.text.starts_with('map[') {
				k, _ := map_parts(t.text)?
				t.text = k
			} else {
				t.text = 'int'
			}
		} else if step == 'a' {
			t.text = '[]' + t.text
		} else if step.starts_with('#') {
			t.text = tuple_part(t.text, step[1..].int())?
		} else {
			return none
		}
	}
	t.text = bare_type(t.text)
	if t.text == '' {
		return none
	}
	return t
}

// returns is the return type of the function or method with id `id`, in the
// scope it is declared in.
fn (inf &Infer) returns(id string) ?InferredType {
	sig := inf.sig_of[id] or { return none }
	name := inf.name_of[id] or { return none }
	ret := return_type(sig, name)
	if ret == '' {
		return none
	}
	site := inf.decl_site(id, name)?
	return InferredType{
		text: ret
		mod:  site.mod
		file: site.file
	}
}

fn (inf &Infer) decl_site(id string, name string) ?CallCand {
	for c in inf.by_name[name] or { return none } {
		if c.id == id {
			return c
		}
	}
	return none
}

// method_on is the id of the method `name` on type `t`, called from `file`.
// It looks where V would: for an array, a method declared on that array type
// (`[]string.join`) and then on `array`; for a named type, the declaration
// that its qualifier, or its module and builtin, make visible.
fn (inf &Infer) method_on(t InferredType, name string, file string) ?string {
	text := bare_type(t.text)
	cands := inf.by_name[name] or { return none }
	if text.starts_with('[') {
		if text.starts_with('[]') {
			if id := inf.pick_method(cands, name, text, '', t, file) {
				return id
			}
		}
		return inf.pick_method(cands, name, 'array', '', InferredType{ mod: 'builtin' }, file)
	}
	if text.starts_with('map[') {
		return inf.pick_method(cands, name, 'map', '', InferredType{ mod: 'builtin' }, file)
	}
	if text.starts_with('chan ') {
		return inf.pick_method(cands, name, 'chan', '', InferredType{ mod: 'builtin' }, file)
	}
	if !is_named_type(text) {
		return none
	}
	named := strip_generic_args(text)
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	if is_generic_param(short) {
		return none
	}
	if id := inf.pick_method(cands, name, short, qual, t, file) {
		return id
	}
	// a method on the type an alias names, `type Bytes = []u8`
	alias := inf.find_type(short, qual, t, file) or { return none }
	target := inf.alias_of[alias.id] or { return none }
	if bare_type(target) == text {
		return none
	}
	return inf.method_on(InferredType{ text: target, mod: alias.mod, file: alias.file }, name,
		file)
}

// pick_method keeps the methods declared on `owner` and narrows them the way
// resolve_by_receiver_type does: the type's own file, its module, then a module
// its qualifier names, or builtin.
fn (inf &Infer) pick_method(cands []CallCand, name string, owner string, qual string, t InferredType, file string) ?string {
	mut same_file := []CallCand{}
	mut own_mod := []CallCand{}
	mut reachable := []CallCand{}
	for c in cands {
		if !c.is_method || test_private(c.file, file) {
			continue
		}
		// the id is `<module>.<owner>.<name>`, where a generic owner keeps its
		// parameters, `Set[T]`
		id := c.id.all_before('@')
		if !id.starts_with(c.mod + '.') || !id.ends_with('.' + name) {
			continue
		}
		decl_owner := id[c.mod.len + 1..id.len - name.len - 1]
		if decl_owner != owner && (owner.starts_with('[') || strip_generic_args(decl_owner) != owner) {
			continue
		}
		if qual == '' && c.file == t.file {
			same_file << c
		}
		if qual == '' && c.mod == t.mod {
			own_mod << c
		}
		if import_reaches(c.mod, 'builtin') || (qual != '' && import_reaches(c.mod, qual)) {
			reachable << c
		}
	}
	if id := only_id(same_file) {
		return id
	}
	if id := only_id(own_mod) {
		return id
	}
	return only_id(reachable)
}

// find_type is the declaration of the type named `short`, qualified by `qual`,
// as seen from `t`'s scope.
fn (inf &Infer) find_type(short string, qual string, t InferredType, file string) ?TypeCand {
	cands := inf.by_type_name[short] or { return none }
	mut same_file := []TypeCand{}
	mut own_mod := []TypeCand{}
	mut reachable := []TypeCand{}
	for c in cands {
		if test_private(c.file, file) {
			continue
		}
		if qual == '' && c.file == t.file {
			same_file << c
		}
		if qual == '' && c.mod == t.mod {
			own_mod << c
		}
		if import_reaches(c.mod, 'builtin') || (qual != '' && import_reaches(c.mod, qual)) {
			reachable << c
		}
	}
	for tier in [same_file, own_mod, reachable] {
		if id := only_type_id(tier) {
			for c in tier {
				if c.id == id {
					return c
				}
			}
		}
	}
	return none
}

// field_of is the type of field `name` of the struct `t` names.
fn (inf &Infer) field_of(t InferredType, name string, file string) ?InferredType {
	text := bare_type(t.text)
	if !is_named_type(text) {
		return none
	}
	named := strip_generic_args(text)
	short := named.all_after_last('.')
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	if is_generic_param(short) {
		return none
	}
	decl := inf.find_type(short, qual, t, file)?
	if ft := inf.field_type['${decl.id}\x00${name}'] {
		return InferredType{
			text: ft
			mod:  decl.mod
			file: decl.file
		}
	}
	target := inf.alias_of[decl.id] or { return none }
	if bare_type(target) == text {
		return none
	}
	return inf.field_of(InferredType{ text: target, mod: decl.mod, file: decl.file }, name,
		file)
}

// bare_type drops what doesn't change which methods a type has: `&`, `?`,
// `!`, `mut`, `shared` and `atomic`; a variadic `...T` is an array.
fn bare_type(t string) string {
	mut s := t.trim_space()
	for {
		if s.starts_with('&') || s.starts_with('?') || s.starts_with('!') {
			s = s[1..].trim_space()
		} else if s.starts_with('mut ') || s.starts_with('shared ') {
			s = s.all_after(' ').trim_space()
		} else if s.starts_with('atomic ') {
			s = s.all_after(' ').trim_space()
		} else if s.starts_with('...') {
			s = '[]' + s[3..]
		} else {
			break
		}
	}
	return s
}

// is_named_type reports whether `t` is a type's name, `Foo`, `os.File` or
// `Box[int]`, rather than a function type, a tuple or a builtin form.
fn is_named_type(t string) bool {
	if t == '' || t.starts_with('fn ') || t.starts_with('fn(') || t.starts_with('(')
		|| t.starts_with('thread') || t == 'void' {
		return false
	}
	c := t[0]
	return c.is_letter() || c == `_`
}

// elem_type is the type of one element: of an array, `[]T` and `[N]T`, a
// map's value, or a string's byte.
fn elem_type(t string) ?string {
	if t.starts_with('[') {
		close := t.index(']') or { return none }
		return t[close + 1..]
	}
	if t.starts_with('map[') {
		_, v := map_parts(t)?
		return v
	}
	if t == 'string' {
		return 'u8'
	}
	return none
}

// map_parts splits `map[K]V` into K and V.
fn map_parts(t string) ?(string, string) {
	mut depth := 0
	for i := 3; i < t.len; i++ {
		if t[i] == `[` {
			depth++
		} else if t[i] == `]` {
			depth--
			if depth == 0 {
				return t[4..i], t[i + 1..]
			}
		}
	}
	return none
}

// tuple_part is the `i`th type of a multi-value return, `(int, string)`.
fn tuple_part(t string, i int) ?string {
	if !t.starts_with('(') || !t.ends_with(')') {
		return none
	}
	inner := t[1..t.len - 1]
	mut parts := []string{}
	mut depth := 0
	mut start := 0
	for j, c in inner {
		if c in [`(`, `[`] {
			depth++
		} else if c in [`)`, `]`] {
			depth--
		} else if c == `,` && depth == 0 {
			parts << inner[start..j].trim_space()
			start = j + 1
		}
	}
	parts << inner[start..].trim_space()
	if i < 0 || i >= parts.len {
		return none
	}
	return parts[i]
}

// return_type reads the return type off a function's signature, `fn
// (b &Builder) str() string` -> `string`; '' when it returns nothing.
fn return_type(sig string, name string) string {
	mut at := 0
	for {
		i := sig.index_after(name, at) or { return '' }
		at = i + name.len
		if i > 0 && sig[i - 1] == ` ` && at < sig.len && sig[at] in [`(`, `[`] {
			break
		}
	}
	if sig[at] == `[` {
		// generic parameters, `fn map[T](...)`
		at = sig.index_after(']', at) or { return '' }
		at++
	}
	mut depth := 0
	for j := at; j < sig.len; j++ {
		if sig[j] == `(` {
			depth++
		} else if sig[j] == `)` {
			depth--
			if depth == 0 {
				ret := sig[j + 1..].trim_space()
				return if ret == 'void' { '' } else { ret }
			}
		}
	}
	return ''
}
