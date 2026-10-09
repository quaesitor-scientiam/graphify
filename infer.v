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
// V would need inference of its own, such as a generic, and leaves the call
// to resolve_callee's usual narrowing. A const or global is followed through
// the recipe of its value. A call of a function-typed field resolves to the
// field, and one of a method V provides itself is marked `undeclared`.

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
	embeds_of    map[string][]Edge // struct or interface id -> its raw `embeds` edges
	field_id     map[string]string // '<struct id>\x00<field>' -> the field's symbol id
	consts       map[string][]Symbol // name -> the consts and globals with a recipe
	enum_ids     map[string]bool     // ids of enums
	dynamic_ids  map[string]bool     // ids of sum types and interfaces
	generics_of  map[string][]string // free function id -> its type parameters
	tparams_of   map[string][]string // method id -> its own type parameters
	iface_ids    map[string]bool     // ids of interfaces
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
	// field_id is the field's symbol id when the type is a field's (field_of)
	field_id string
}

// const_depth bounds following one const's recipe into another's.
const const_depth = 4

// array_same_type are the array methods whose result has the receiver's type;
// builtin declares most of them as returning plain `array`, or not at all.
const array_same_type = ['clone', 'filter', 'reverse', 'sorted', 'sorted_with_compare', 'slice']

// array_elem_methods are the array methods that return one element, which
// builtin declares as returning `voidptr`.
const array_elem_methods = ['first', 'last', 'pop', 'pop_left']

// array_builtins are array methods the compiler provides; builtin declares
// some of them, and a call of one it doesn't declare is `undeclared`.
const array_builtins = ['filter', 'map', 'any', 'all', 'count', 'sort', 'sorted', 'sort_with_compare',
	'sorted_with_compare', 'contains', 'index', 'last_index', 'wait', 'first', 'last', 'pop',
	'reverse', 'clone']

// flag_enum_methods are the methods V provides for a `@[flag]` enum, as
// cgen's is_flag_enum_method lists them.
const flag_enum_methods = ['has', 'all', 'set', 'clear', 'toggle', 'set_all', 'clear_all',
	'is_empty']

// embed_depth bounds following embedded types, which could name each other.
const embed_depth = 4

// infer_call resolves a call edge: a module-qualified callee by its prefix,
// and a method call by its receiver's type, given or inferred, falling back to
// resolve_callee's narrowing.
fn (mut inf Infer) infer_call(e Edge) ?CallResolution {
	if e.to.contains('.') {
		return resolve_qualified_callee(e, inf.by_name, inf.site_of, inf.scope_of)
	}
	if e.is_method {
		if t := inf.receiver(e) {
			mut found := inf.method_on(t, e.to, e.file, 0) or { '' }
			if found == '' {
				if alt := inf.fallback_receiver(e) {
					found = inf.method_on(alt, e.to, e.file, 0) or { '' }
				}
			}
			if found == '' {
				// before any name match: `b.cb()` on a function-typed field is
				// no call of some function that happens to be named `cb`
				if field := inf.no_method(t, e.to, e.file) {
					if field != '' {
						// it calls whatever the field holds; the field is
						// the declaration there is
						return CallResolution{
							id:       field
							inferred: true
						}
					}
					return CallResolution{
						undeclared: true
					}
				}
			}
			if found != '' {
				if e.recv_type != '' {
					// keep resolve_callee's provenance when it agrees
					if r := resolve_callee(e, inf.by_name, inf.site_of, inf.imports_of) {
						if r.id == found {
							return r
						}
					}
					return CallResolution{
						id:       found
						inferred: true
					}
				}
				cands := inf.by_name[e.to] or { []CallCand{} }
				return CallResolution{
					id:       found
					inferred: (only_id(cands) or { '' }) != found
				}
			}
		}
	}
	return resolve_callee(e, inf.by_name, inf.site_of, inf.imports_of)
}

// receiver is the type of a method call's receiver: as the parser wrote it
// (recv_type, an id-like `<module>.<Type>` or an import-qualified type), or
// as its recipe works out.
fn (mut inf Infer) receiver(e Edge) ?InferredType {
	if e.recv_type != '' {
		scope := inf.scope_of[e.file] or { FileScope{} }
		qual := e.recv_type.all_before_last('.')
		if qual == scope.mod {
			return InferredType{
				text: e.recv_type.all_after_last('.')
				mod:  scope.mod
				file: e.file
			}
		}
		return InferredType{
			text: e.recv_type
			mod:  scope.mod
			file: e.file
		}
	}
	if e.recv_recipe != '' {
		return inf.follow(e)
	}
	return none
}

// no_method explains a call of `name` on `t` that matched no method: the id
// of the function-typed field it calls, or '' for a method V provides without
// declaring it (`thread.wait()`, a compiler-provided array method). none
// leaves the call to name matching. Call it only once method_on found none.
fn (inf &Infer) no_method(t InferredType, name string, file string) ?string {
	text := bare_type(t.text)
	if name == 'wait' && (text.starts_with('thread') || text.starts_with('[]thread')) {
		return ''
	}
	// `str()` on a primitive the builtin doesn't declare one for (`u128`), or on a
	// thread, which V writes as `thread(int)`
	if name == 'str' && (text in primitive_types || is_thread_type(text)) {
		return ''
	}
	if text.starts_with('[') && (name in array_builtins || name == 'str') {
		return ''
	}
	if text.starts_with('map[') && name == 'str' {
		return ''
	}
	if is_named_type(text) {
		named := strip_generic_args(text)
		short := named.all_after_last('.')
		qual := if named.contains('.') { named.all_before_last('.') } else { '' }
		if decl := inf.find_type(short, qual, t, file) {
			// V writes `str()` for any type that doesn't, the methods of a
			// `@[flag]` enum, and `type_name()` of a sum type or interface
			if name == 'str' || (decl.id in inf.enum_ids && name in flag_enum_methods)
				|| (decl.id in inf.dynamic_ids && name in ['type_name', 'type_idx']) {
				if _ := inf.field_of(t, name, file, 0) {
				} else {
					return ''
				}
			}
		}
	}
	ft := inf.field_of(t, name, file, 0)?
	if ft.field_id == '' {
		return none
	}
	ftext := bare_type(ft.text)
	if ftext.starts_with('fn ') || ftext.starts_with('fn(') {
		return ft.field_id
	}
	// a field whose type is a named function type, `cb Callback`
	if is_named_type(ftext) {
		named := strip_generic_args(ftext)
		qual := if named.contains('.') { named.all_before_last('.') } else { '' }
		decl := inf.find_type(named.all_after_last('.'), qual, ft, file)?
		target := inf.alias_of[decl.id] or { return none }
		if target.starts_with('fn ') || target.starts_with('fn(') {
			return ft.field_id
		}
	}
	return none
}

// embedded is the declarations of the types `decl` embeds.
fn (inf &Infer) embedded(decl TypeCand) []TypeCand {
	mut out := []TypeCand{}
	for e in inf.embeds_of[decl.id] or { return out } {
		res := resolve_type_ref(e, inf.by_type_name, inf.site_of, inf.imports_of) or { continue }
		for c in inf.by_type_name[e.to.all_after_last('.')] or { continue } {
			if c.id == res.id {
				out << c
				break
			}
		}
	}
	return out
}

// as_type is the type a declaration declares, in its own scope.
fn (c TypeCand) as_type() InferredType {
	return InferredType{
		text: c.id.all_before('@').all_after_last('.')
		mod:  c.mod
		file: c.file
	}
}

// follow evaluates the edge's recipe, or none where a step can't be taken.
fn (mut inf Infer) follow(e Edge) ?InferredType {
	// the narrowed type comes first; the declared one is for fallback_receiver
	primary := e.recv_recipe.all_before(recipe_alt)
	key := '${e.file}\x00${e.from}\x00${primary}'
	if t := inf.memo[key] {
		return if t.text == '' { none } else { t }
	}
	t := inf.follow_steps(Edge{ ...e, recv_recipe: primary }, 0) or { InferredType{} }
	inf.memo[key] = t
	return if t.text == '' { none } else { t }
}

// fallback_receiver is the declared type of a receiver the walk narrowed by a
// type check, for a method its narrowed type doesn't have, or none.
fn (mut inf Infer) fallback_receiver(e Edge) ?InferredType {
	idx := e.recv_recipe.index(recipe_alt) or { return none }
	return inf.follow(Edge{ ...e, recv_recipe: e.recv_recipe[idx + 1..] })
}

// unalias is `t` with the alias it names replaced by the type the alias names,
// read in the alias's own scope, following a chain of aliases: `Sources` of
// `type Sources = [2]Source` is `[2]Source`. A sum type is no alias here.
fn (inf &Infer) unalias(t InferredType, file string) InferredType {
	mut cur := t
	for _ in 0 .. embed_depth {
		text := bare_type(cur.text)
		if !is_named_type(text) {
			break
		}
		named := strip_generic_args(text)
		short := named.all_after_last('.')
		qual := if named.contains('.') { named.all_before_last('.') } else { '' }
		decl := inf.find_type(short, qual, cur, file) or { break }
		target := inf.alias_of[decl.id] or { break }
		if bare_type(target) == text {
			break
		}
		cur = InferredType{
			text: target
			mod:  decl.mod
			file: decl.file
		}
	}
	return cur
}

fn (inf &Infer) follow_steps(e Edge, depth int) ?InferredType {
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
	} else if start.starts_with('ct:') {
		t = inf.comptime_type(start[3..], e.file)?
	} else if start.starts_with('g:') {
		if c := inf.find_const(start[2..], e.file) {
			if depth >= const_depth {
				return none
			}
			// the const's own recipe, in the scope of the file declaring it
			t = inf.follow_steps(Edge{
				from:        c.id
				file:        c.file
				recv_recipe: c.recipe
			}, depth + 1)?
		} else {
			// `Colour.red` names a member of the enum Colour, a value of its type
			t = inf.enum_type(start[2..], e.file)?
		}
	} else if start.starts_with('c:') {
		t = inf.call_result(e, start[2..], steps) or {
			// a spawned call whose result isn't known is a thread of an unknown result
			if 'th' !in steps {
				return none
			}
			InferredType{}
		}
	} else {
		return none
	}
	rest := steps[1..]
	for si, step in rest {
		if step.starts_with('p:') || step.starts_with('mapto:') {
			continue
		}
		if step == 'th' {
			t = spawned_thread(t)
			continue
		}
		t.text = bare_type(t.text)
		if t.text == '' {
			return none
		}
		if step.starts_with('m:') {
			name := step[2..]
			if name == 'wait' && t.text.starts_with('thread ') {
				// a thread's wait() is the result of the function it runs
				t = InferredType{
					text: t.text[7..]
					mod:  t.mod
					file: t.file
				}
				continue
			}
			// a method the alias itself, or the type it names, has comes first; an alias
			// of an array or map (`type Sources = [2]Source`) otherwise has its methods
			if (inf.method_on(t, name, e.file, 0) or { '' }) == '' {
				t = inf.unalias(t, e.file)
			}
			if name == 'map' && t.text.starts_with('[') && si + 1 < rest.len
				&& rest[si + 1].starts_with('mapto:') {
				t.text = '[]' + rest[si + 1][6..]
				continue
			}
			if t.text.starts_with('[') && name in array_same_type {
				continue
			}
			if t.text.starts_with('[') && name in array_elem_methods {
				t.text = elem_type(t.text)?
				continue
			}
			if t.text.starts_with('map[') && name == 'clone' {
				continue
			}
			if t.text.starts_with('map[') && name in ['keys', 'values'] {
				k, v := map_parts(t.text)?
				t.text = '[]' + if name == 'keys' { k } else { v }
				continue
			}
			if found := inf.method_on(t, name, e.file, 0) {
				mut ret := inf.returns(found)?
				// `Queue[int].pop()` returns the `T` of `Queue[T]`, here `int`
				owner := found.all_before_last('.').all_after_last('.').all_before('[')
				ret.text = owner_args(ret.text, t, owner, inf.generics_of[found] or { []string{} })
				// `x.reflect[User]()` returns the `T` of `reflect[T]`, here `User`: the
				// `p:` steps right after this one are the type arguments, in order
				mut targs := []string{}
				for j := si + 1; j < rest.len; j++ {
					if !rest[j].starts_with('p:') {
						break
					}
					targs << rest[j][2..]
				}
				for i, param in inf.tparams_of[found] or { []string{} } {
					if i < targs.len && targs[i] != '' {
						ret.text = subst_word(ret.text, param, targs[i])
					}
				}
				t = ret
			} else {
				// V writes `str()` for a type that declares none, and it returns a string
				if name != 'str' || (inf.no_method(t, name, e.file) or { 'none' }) != '' {
					return none
				}
				t = InferredType{
					text: 'string'
					mod:  'builtin'
				}
			}
		} else if step.starts_with('f:') {
			// a selector on an enum names one of its members, a value of that type
			if inf.is_enum(t, e.file) {
				continue
			}
			t = inf.field_of(t, step[2..], e.file, 0)?
		} else if step == '[]' {
			// an alias of an array, `type Sources = [2]Source`, has its element type
			t = inf.unalias(t, e.file)
			t.text = elem_type(t.text)?
		} else if step == 'R' {
			// the return type of a function type, `fn (int) Doc`
			t.text = fn_return(t.text)?
		} else if step == 'us' {
			// `x >>> n` is unsigned, as wide as x
			t.text = unsigned_of(t.text)?
		} else if step == 'k' {
			t = inf.unalias(t, e.file)
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

// call_result is the return type of the call `to` made from e's file, its
// generic arguments (the `p:` steps of `steps`) put in place of its parameters.
fn (inf &Infer) call_result(e Edge, to string, steps []string) ?InferredType {
	call := Edge{
		from: e.from
		to:   to
		kind: .calls
		file: e.file
	}
	mut t := InferredType{}
	mut id := ''
	if call.to.contains('.') {
		id = (resolve_qualified_callee(call, inf.by_name, inf.site_of, inf.scope_of)?).id
		t = inf.returns(id)?
	} else if res := resolve_callee(call, inf.by_name, inf.site_of, inf.imports_of) {
		id = res.id
		t = inf.returns(id)?
	} else {
		// one function declared once per platform: its variants must all return
		// the same type, which is then the call's type
		variants := platform_variants(call, inf.by_name, inf.site_of)?
		ids := variants.map(it.id)
		t = inf.same_return(ids)?
		id = ids[0]
	}
	// the type arguments of a generic call (`p:` steps) stand for the
	// callee's type parameters, in order, in its return type
	mut targs := []string{}
	for step in steps[1..] {
		if !step.starts_with('p:') {
			break
		}
		targs << step[2..]
	}
	params := inf.generics_of[id] or { []string{} }
	for i, param in params {
		if i < targs.len && targs[i] != '' {
			t.text = subst_word(t.text, param, targs[i])
		}
	}
	return t
}

// spawned_thread is the type of the thread a spawned call starts, given the
// call's result t: `thread T`, or bare `thread` when T isn't a plain type name
// (a result, an option, a generic parameter) or isn't known.
fn spawned_thread(t InferredType) InferredType {
	plain := t.text != '' && !t.text.starts_with('thread')
		&& (is_named_type(t.text) || t.text.starts_with('['))
		&& !is_generic_param(t.text.trim_left('[]'))
	if !plain {
		return InferredType{
			text: 'thread'
			mod:  t.mod
			file: t.file
		}
	}
	return InferredType{
		text: 'thread ' + t.text
		mod:  t.mod
		file: t.file
	}
}

// is_thread_type reports whether a type is a thread: bare, or with the result it
// yields (`thread int`).
fn is_thread_type(t string) bool {
	return t == 'thread' || t.starts_with('thread ')
}

// unsigned_counterparts pairs each integer type with the unsigned type `x >>> n`
// has for an x of that type, the one of the same width (V's
// unsigned_shift_result_type). `int` is left out: its width is the platform's,
// and a literal operand has no type to name.
const unsigned_counterparts = {
	'i8':    'u8'
	'i16':   'u16'
	'i32':   'u32'
	'rune':  'u32'
	'i64':   'u64'
	'i128':  'u128'
	'isize': 'usize'
	'u8':    'u8'
	'u16':   'u16'
	'u32':   'u32'
	'u64':   'u64'
	'u128':  'u128'
	'usize': 'usize'
}

// unsigned_of is the unsigned type `x >>> n` has for an operand of type t.
fn unsigned_of(t string) ?string {
	return unsigned_counterparts[t] or { return none }
}

// comptime_type is the type a `$if T is X` block takes T to be, `name` read in
// `file`, where X may be wrapped as `&X` or `[]X`. Not when X is an interface:
// V's `T is Iface` holds for any T implementing it, so the block's T is not the
// interface, and nothing here says which type T is.
fn (inf &Infer) comptime_type(name string, file string) ?InferredType {
	scope := inf.scope_of[file] or { FileScope{} }
	mut base := name
	for {
		if base.starts_with('&') {
			base = base[1..]
		} else if base.starts_with('[]') {
			base = base[2..]
		} else {
			break
		}
	}
	if base !in primitive_types {
		short := base.all_after_last('.')
		qual := if base.contains('.') { base.all_before_last('.') } else { '' }
		decl := inf.find_type(short, qual, InferredType{ mod: scope.mod, file: file }, file)?
		if decl.id in inf.iface_ids {
			return none
		}
	}
	return InferredType{
		text: name
		mod:  scope.mod
		file: file
	}
}

// find_const is the const or global that `name` names from `file`: one of
// its module's (in a standalone program, of its own file), or of builtin;
// with a module path, `os.args`, one of that module's.
fn (inf &Infer) find_const(name string, file string) ?Symbol {
	short := name.all_after_last('.')
	qual := if name.contains('.') { name.all_before_last('.') } else { '' }
	cands := inf.consts[short] or { return none }
	scope := inf.scope_of[file] or { FileScope{} }
	mut own := []Symbol{}
	mut reachable := []Symbol{}
	for c in cands {
		if test_private(c.file, file) {
			continue
		}
		if qual == '' && c.parent == scope.mod && (!scope.is_main || c.file == file) {
			own << c
		}
		if (qual != '' && import_reaches(c.parent, qual))
			|| (qual == '' && import_reaches(c.parent, 'builtin')) {
			reachable << c
		}
	}
	for tier in [own, reachable] {
		if tier.len > 0 && tier.all(it.id == tier[0].id) {
			return tier[0]
		}
	}
	return none
}

// split_type_args are the arguments in a generic type's brackets, `Queue[[]string]`
// -> [[]string]: a nested bracket stays with the argument it is in. Empty for a
// type without brackets, and for an array or map, whose bracket isn't a
// generic one.
fn split_type_args(t string) []string {
	mut text := t.trim_space().trim_left('&')
	if text.starts_with('[') || text.starts_with('map[') || text.starts_with('chan ') {
		return []string{}
	}
	open := text.index('[') or { return []string{} }
	close := text.last_index(']') or { return []string{} }
	if close <= open + 1 {
		return []string{}
	}
	inner := text[open + 1..close]
	mut out := []string{}
	mut depth := 0
	mut cur := ''
	for i in 0 .. inner.len {
		c := inner[i]
		if c == `[` {
			depth++
		} else if c == `]` {
			depth--
		}
		if c == `,` && depth == 0 {
			out << cur.trim_space()
			cur = ''
			continue
		}
		cur += inner[i..i + 1]
	}
	out << cur.trim_space()
	return out
}

// qualify_type_names names the unqualified types in a type text as declared in
// module `mod`, so that a type argument taken from one module still means the
// same type where it is substituted into another module's declaration: `[]Config`
// in `main` becomes `[]main.Config`. A name already qualified stays as written.
fn qualify_type_names(t string, mod string) string {
	if mod == '' {
		return t
	}
	mut out := ''
	mut i := 0
	for i < t.len {
		if t[i].is_letter() || t[i] == `_` {
			mut j := i
			for j < t.len && (t[j].is_letter() || t[j].is_digit() || t[j] == `_` || t[j] == `.`) {
				j++
			}
			word := t[i..j]
			if word[0].is_capital() && !word.contains('.') {
				out += '${mod}.${word}'
			} else {
				out += word
			}
			i = j
			continue
		}
		out += t[i..i + 1]
		i++
	}
	return out
}

// owner_args substitutes the type arguments a generic receiver was written with
// (`Queue[int]`) for the type parameters its declaration names (`Queue[T]`), in
// the text a member of it returns or holds, `T` in `!T` or `[]T`. It does
// nothing unless `owner`, the type that declares the member, is the receiver's
// own type and the counts agree.
fn owner_args(text string, recv InferredType, owner string, params []string) string {
	args := split_type_args(recv.text)
	if params.len == 0 || params.len != args.len || owner != bare_name(recv.text) {
		return text
	}
	mut out := text
	for i, param in params {
		out = subst_word(out, param, qualify_type_names(args[i], recv.mod))
	}
	return out
}

// bare_name is the last name of a type text, without its module, `Queue` for
// `datatypes.Queue[int]` and `&Queue[T]`.
fn bare_name(t string) string {
	return strip_generic_args(bare_type(t)).all_after_last('.')
}

// subst_word replaces each `word` in a type text that stands alone, not as
// part of a longer name (`T` in `[]T` or `!T`, not in `Tree` or `x.T`).
fn subst_word(text string, word string, repl string) string {
	mut out := ''
	mut i := 0
	for i < text.len {
		end := i + word.len
		if end <= text.len && text[i..end] == word {
			before := if i > 0 { text[i - 1] } else { u8(` `) }
			after := if end < text.len { text[end] } else { u8(` `) }
			if !is_name_byte(before) && before != `.` && !is_name_byte(after) && after != `.` {
				out += repl
				i = end
				continue
			}
		}
		out += text[i..i + 1]
		i++
	}
	return out
}

fn is_name_byte(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// returns is the return type of the function or method with id `id`, in the
// scope it is declared in.
// fn_return is the return type of a function type written as text, `fn () Doc`,
// or none when it returns nothing.
fn fn_return(t string) ?string {
	close := t.last_index(')') or { return none }
	ret := t[close + 1..].trim_space()
	if ret == '' {
		return none
	}
	return ret
}

// same_return is the return type shared by every id, or none when they differ.
fn (inf &Infer) same_return(ids []string) ?InferredType {
	first := inf.returns(ids[0])?
	for id in ids[1..] {
		if inf.returns(id)?.text != first.text {
			return none
		}
	}
	return first
}

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
fn (inf &Infer) method_on(t InferredType, name string, file string, depth int) ?string {
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
	if depth >= embed_depth {
		return none
	}
	decl := inf.find_type(short, qual, t, file) or { return none }
	// a method on the type an alias names, `type Bytes = []u8`
	if target := inf.alias_of[decl.id] {
		if bare_type(target) == text {
			return none
		}
		return inf.method_on(InferredType{ text: target, mod: decl.mod, file: decl.file },
			name, file, depth + 1)
	}
	// a method of an embedded struct or interface
	mut found := []string{}
	for emb in inf.embedded(decl) {
		if id := inf.method_on(emb.as_type(), name, file, depth + 1) {
			if id !in found {
				found << id
			}
		}
	}
	return if found.len == 1 { found[0] } else { none }
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
	return only_id(if qual != '' { exact_calls(reachable, qual) } else { reachable })
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
	if qual != '' {
		reachable = exact_types(reachable, qual)
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

// enum_type is the enum `name` names from `file`, the type of a member selected
// from it. A qualified name, `gg.HorizontalAlign`, is an enum of that module.
fn (inf &Infer) enum_type(name string, file string) ?InferredType {
	scope := inf.scope_of[file] or { FileScope{} }
	short := name.all_after_last('.')
	qual := if name.contains('.') { name.all_before_last('.') } else { '' }
	decl := inf.find_type(short, qual, InferredType{ mod: scope.mod, file: file }, file)?
	if decl.id !in inf.enum_ids {
		return none
	}
	return decl.as_type()
}

// is_enum reports whether `t` names an enum.
fn (inf &Infer) is_enum(t InferredType, file string) bool {
	text := bare_type(t.text)
	if !is_named_type(text) {
		return false
	}
	named := strip_generic_args(text)
	qual := if named.contains('.') { named.all_before_last('.') } else { '' }
	decl := inf.find_type(named.all_after_last('.'), qual, t, file) or { return false }
	return decl.id in inf.enum_ids
}

// field_of is the type of field `name` of the struct `t` names.
fn (inf &Infer) field_of(t InferredType, name string, file string, depth int) ?InferredType {
	text := bare_type(t.text)
	// a dynamic array is builtin's `array` (`a.flags`), and a map its `map`;
	// a fixed array has no fields
	if text.starts_with('[]') || text.starts_with('map[') {
		return inf.field_of(InferredType{
			text: if text.starts_with('[]') { 'array' } else { 'map' }
			mod:  'builtin'
		}, name, file, depth)
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
	mut decl := TypeCand{}
	if qual == 'C' {
		decl = inf.c_struct(short, t)?
	} else {
		decl = inf.find_type(short, qual, t, file)?
	}
	key := '${decl.id}\x00${name}'
	if ft := inf.field_type[key] {
		// `s.items` of a `Stack[int]` is `[]int`, where the field is `[]T`
		return InferredType{
			text:     owner_args(ft, t, short, inf.generics_of[decl.id] or { []string{} })
			mod:      decl.mod
			file:     decl.file
			field_id: inf.field_id[key] or { '' }
		}
	}
	if depth >= embed_depth {
		return none
	}
	if target := inf.alias_of[decl.id] {
		if bare_type(target) == text {
			return none
		}
		return inf.field_of(InferredType{ text: target, mod: decl.mod, file: decl.file },
			name, file, depth + 1)
	}
	// a field of an embedded struct, or the embedded struct itself, `s.Base`
	mut found := []InferredType{}
	for emb in inf.embedded(decl) {
		et := emb.as_type()
		if et.text == name {
			return et
		}
		if ft := inf.field_of(et, name, file, depth + 1) {
			found << ft
		}
	}
	return if found.len == 1 { found[0] } else { none }
}

// c_struct is the C struct `C.name` names, as seen from t's file. V's C types are
// not qualified by a module: a C struct is one name for the whole program, so the
// declaration in the nearest scope is the one: t's file, then its module, then the
// program. Declarations of one id in that scope are one struct, one per platform;
// two ids leave it unknown, and a V struct of that name is none of it.
fn (inf &Infer) c_struct(name string, t InferredType) ?TypeCand {
	mut same_file := []TypeCand{}
	mut own_mod := []TypeCand{}
	mut all := []TypeCand{}
	for c in inf.by_type_name[name] or { return none } {
		if !c.c {
			continue
		}
		all << c
		if c.file == t.file {
			same_file << c
		}
		if c.mod == t.mod {
			own_mod << c
		}
	}
	for tier in [same_file, own_mod, all] {
		mut ids := []string{}
		for c in tier {
			if c.id !in ids {
				ids << c.id
			}
		}
		if ids.len == 1 {
			return tier[0]
		}
		if ids.len > 1 {
			return none
		}
	}
	return none
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
	// a channel's element, `chan T`, which `<-c` receives
	if t.starts_with('chan ') {
		return t[5..]
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
