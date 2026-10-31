module graphify

import os
import v.flat
import v.parser
import v.pref

// The extractor. It reads V3's flat AST (v.flat, from v.parser): one node per
// syntax element with a kind, a value, a type written as source text, byte
// offsets and children. Its ids, signatures and lines follow the conventions
// of the V 0.5.2-based extractor it replaced in October 2026; FUTURE_WORK.md
// §6 records the mapping and where it deliberately differs.

pub fn extract_v_file(path string, rel string) ([]Symbol, []Edge) {
	fr := extract_v_file_result(path, rel)
	return fr.symbols, fr.edges
}

pub fn extract_v_file_result(path string, rel string) FileResult {
	src := os.read_file(path) or {
		return FileResult{
			parse_error: 'cannot read the file: ${err}'
		}
	}
	if src.contains('[if ') || src.contains(r'$match @') {
		// see without_if_attrs and with_every_match_branch: parse a rewritten copy
		return extract_v3_rewritten(src, rel, path)
	}
	return extract_v3(path, src, rel, path)
}

pub fn extract_v_text(source string, rel string) ([]Symbol, []Edge) {
	fr := extract_v_text_result(source, rel)
	return fr.symbols, fr.edges
}

// extract_v_text_result parses `source` through a temporary file: V3's parser
// reads only files. The file keeps `rel`'s name, which decides `_test.v`
// handling and platform suffixes.
pub fn extract_v_text_result(source string, rel string) FileResult {
	return extract_v3_rewritten(source, rel, '')
}

// extract_v3_rewritten parses the rewritten copy; `real_path` is the file it
// came from, if any, for resolving its imports.
fn extract_v3_rewritten(source string, rel string, real_path string) FileResult {
	dir := os.join_path(os.temp_dir(), 'graphify_text_${os.getpid()}')
	os.mkdir_all(dir) or {}
	path := os.join_path(dir, os.file_name(rel))
	// the extractor reads lines and slices from the `$match` rewrite, which
	// adds text; blanking the `@[if]` guards adds none, and the original
	// attribute lines stay visible to it
	text := with_every_match_branch(source)
	os.write_file(path, without_if_attrs(text)) or {
		return FileResult{
			parse_error: 'cannot write a temporary file: ${err}'
		}
	}
	defer {
		os.rm(path) or {}
	}
	return extract_v3(path, text, rel, real_path)
}

// V3File is one parsed file and what the walk needs to read it.
struct V3File {
mut:
	a           &flat.FlatAst
	src         string
	lines       []string
	line_starts []int
	rel         string
	// real_path is the file on disk, for resolve_import; '' for text
	real_path string
	mod_id    string
	// imports maps each name an import is used by in code (its alias, or the
	// last segment of its path) to the module's resolved path (resolve_import),
	// `geometry` -> `v.tests.geometry`
	imports map[string]string
	// selected maps each name brought in by a selective import, `import util
	// { shared }`, to its module's path
	selected map[string]string
	// anon maps each anonymous struct or union the parser made up for this
	// file, by the name anon_type gives it (`_VAnonStruct1`), to its
	// declaration (see add_type_ref)
	anon map[string]flat.NodeId
}

fn extract_v3(path string, src string, rel string, real_path string) FileResult {
	mut prefs := pref.new_preferences()
	// Keep every branch of a `$if`, at file scope and in bodies, instead of the
	// one this machine would compile: the graph then no longer depends on the
	// host's OS and architecture (FUTURE_WORK.md §8), and a call inside a
	// `$if debug {}` is still a call.
	prefs.preserve_comptime_conditionals = true
	// Inline assembly for another architecture parses fine; without this the
	// parser still reports it as unsupported by the backend, so which files are
	// flagged would depend on the host's architecture.
	prefs.supports_inline_asm = true
	mut p := parser.Parser.new(prefs)
	a := p.parse_file(path)
	// errors carry no severity text; warnings and notices say so
	errors := p.diagnostics.filter(it.severity == '' || it.severity.starts_with('error'))
	// the parser emits an empty `file` node first; the real one has children
	mut root := -1
	for i, n in a.nodes {
		if n.kind == .file && n.children_count > 0 {
			root = i
		}
	}
	if root < 0 {
		if errors.len == 0 && only_comments(src) {
			// an empty file, or one all comments (vlib/v/slow_tests/acommentedmodule),
			// declares nothing, and V builds it
			return FileResult{}
		}
		return FileResult{
			parse_error: if errors.len > 0 {
				'${errors[0].line}:${errors[0].column}: ${errors[0].message}'
			} else {
				'no file node'
			}
		}
	}
	mut starts := [0]
	for i, c in src {
		if c == `\n` {
			starts << i + 1
		}
	}
	// V3 declares an anonymous `struct { ... }` or `union { ... }` as a
	// struct_decl outside the file's statements, and lists the names it made up
	mut anon := map[string]flat.NodeId{}
	if a.synthesized_anon_struct_types.len > 0 {
		for i, n in a.nodes {
			if n.kind == .struct_decl && flat.source_type_id(n.value_text()) in a.synthesized_anon_struct_types {
				anon[anon_type(n.value_text())] = flat.NodeId(i)
			}
		}
	}
	mut f := V3File{
		a:           a
		src:         src
		lines:       src.split('\n')
		line_starts: starts
		rel:         rel
		real_path:   real_path
		anon:        anon
	}
	syms, edges := f.extract(flat.NodeId(root))
	mut parse_error := ''
	mut branches := map[string][]DeclBranch{}
	for d in errors {
		if d.message.starts_with('duplicate method `') {
			if branches.len == 0 {
				f.method_branches(f.kids(flat.NodeId(root)), '', mut branches)
			}
			if in_other_branches(branches, d.line) {
				continue
			}
		}
		parse_error = '${d.line}:${d.column}: ${d.message}'
		break
	}
	return FileResult{
		symbols:     syms
		edges:       edges
		parse_error: parse_error
	}
}

// only_comments reports whether `src` holds nothing but whitespace and comments,
// `// ...` and `/* ... */`, which V lets nest.
fn only_comments(src string) bool {
	mut i := 0
	for i < src.len {
		c := src[i]
		if c.is_space() {
			i++
		} else if c == `/` && i + 1 < src.len && src[i + 1] == `/` {
			for i < src.len && src[i] != `\n` {
				i++
			}
		} else if c == `/` && i + 1 < src.len && src[i + 1] == `*` {
			mut depth := 0
			for i < src.len {
				if src[i] == `/` && i + 1 < src.len && src[i + 1] == `*` {
					depth++
					i += 2
				} else if src[i] == `*` && i + 1 < src.len && src[i + 1] == `/` {
					depth--
					i += 2
					if depth == 0 {
						break
					}
				} else {
					i++
				}
			}
			if depth != 0 {
				return false
			}
		} else {
			return false
		}
	}
	return true
}

// DeclBranch is a method declared at file scope, with the branches of the
// file-scope `$if`s it is in, outermost first (see comptime_branch).
struct DeclBranch {
	line   int
	branch string
}

// method_branches finds the file's methods by their parser name (`Type.name`).
// With every branch of a `$if` kept (extract_v3), V3 reports a method declared
// in both branches, `$if darwin { fn (b B) f() } $else { fn (b B) f() }`, or
// under `$if x ?` and `$if !x ?`, as a duplicate method, though only one of them
// is ever compiled and both are read.
fn (f &V3File) method_branches(ids []flat.NodeId, branch string, mut out map[string][]DeclBranch) {
	for id in ids {
		n := f.node(id)
		match n.kind {
			.comptime_if {
				for i, k in f.kids(id) {
					f.method_branches([k], branch + comptime_branch(n.value_text(), i == 0), mut out)
				}
			}
			.block {
				f.method_branches(f.kids(id), branch, mut out)
			}
			.fn_decl {
				if n.value_text().contains('.') {
					out[n.value_text()] << DeclBranch{
						line:   f.line_of(n.pos.offset)
						branch: branch
					}
				}
			}
			else {}
		}
	}
}

// in_other_branches reports whether the method declared on `line` is in a
// different branch of a `$if` from each other declaration of its name, so that
// V3's duplicate method on it is not one V would report.
fn in_other_branches(branches map[string][]DeclBranch, line int) bool {
	for _, decls in branches {
		for d in decls {
			if d.line != line {
				continue
			}
			for o in decls {
				if o.line != line && !exclusive_branches(d.branch, o.branch) {
					return false
				}
			}
			return decls.len > 1
		}
	}
	return false
}

// comptime_branch is one step of a branch path: the condition of a `$if` and
// whether its block (`holds`) or its `$else` is taken, with a leading `!` read as
// the `$else` of the condition it negates, so `$if !x ? {}` is `$if x ? {} $else {}`'s
// `$else`. A step ends in \x1f.
fn comptime_branch(cond string, holds bool) string {
	c := cond.replace(' ', '')
	if c.starts_with('!') && !c.contains('&&') && !c.contains('||') {
		return '${c[1..]}=${!holds}\x1f'
	}
	return '${c}=${holds}\x1f'
}

// exclusive_branches reports whether two branch paths part at a condition, one
// taking its block and the other its `$else`.
fn exclusive_branches(a string, b string) bool {
	sa := a.split('\x1f')
	sb := b.split('\x1f')
	for i in 0 .. sa.len {
		if i >= sb.len || sa[i] == '' || sb[i] == '' {
			return false
		}
		if sa[i] != sb[i] {
			return sa[i].all_before_last('=') == sb[i].all_before_last('=')
		}
	}
	return false
}

// method_tparams reads the type parameters of the method `name` declared on
// `line`, `fn (d Doc) reflect[T]() T` -> [T]; V3's parser doesn't keep them.
fn (f &V3File) method_tparams(line int, name string) []string {
	if line < 1 || line > f.lines.len {
		return []string{}
	}
	text := f.lines[line - 1]
	at := text.index(' ${name}[') or { return []string{} }
	rest := text[at + name.len + 2..]
	end := rest.index(']') or { return []string{} }
	mut out := []string{}
	for p in rest[..end].split(',') {
		word := p.trim_space().all_before(' ')
		if word != '' {
			out << word
		}
	}
	return out
}

// generic_params reads the type parameters of the free function `name`
// declared on `line`, `fn fold[T, R](...)` -> [T, R]. V3's parser doesn't keep
// them, but the header line does; a constraint (`T Number`) is dropped.
fn (f &V3File) generic_params(line int, head string) []string {
	if line < 1 || line > f.lines.len {
		return []string{}
	}
	text := f.lines[line - 1]
	at := text.index('${head}[') or { return []string{} }
	rest := text[at + head.len + 1..]
	end := rest.index(']') or { return []string{} }
	mut out := []string{}
	for p in rest[..end].split(',') {
		word := p.trim_space().all_before(' ')
		if word != '' {
			out << word
		}
	}
	return out
}

// header_end_line is the line of the `{` that opens the body of the function
// declared at `offset`, as V 0.5.2 recorded a function's end_line: the last
// line of its header. It skips brackets and anonymous struct types, so a `{`
// in a parameter's or the return type doesn't count, and a declaration
// without a body ends on its own line.
fn (f &V3File) header_end_line(offset i32) int {
	mut depth := 0
	for i := int(offset); i < f.src.len; i++ {
		match f.src[i] {
			`(`, `[` {
				depth++
			}
			`)`, `]`, `}` {
				depth--
			}
			`{` {
				// an anonymous `struct {` in a parameter or return type
				// opens a type, not the body
				before := f.src[int(offset)..i].trim_right(' \t')
				if depth <= 0 && !before.ends_with('struct') && !before.ends_with('union') {
					return f.line_of(i32(i))
				}
				depth++
			}
			`\n` {
				// a header continues past a line break inside brackets, or
				// when the body's `{` starts the next line
				if depth <= 0 && !f.src[i + 1..].trim_left(' \t\r\n').starts_with('{') {
					// no body: the header ends on the line this newline ends
					return f.line_of(i32(i))
				}
			}
			else {}
		}
	}
	// the file ended inside the header, with no newline after it
	return f.line_of(i32(f.src.len - 1))
}

// subtree_span is the first byte a node and its descendants cover, and the
// byte after their last.
// A statement's own position can't be trusted for this: V3 places an
// expression statement after its expression.
fn (f &V3File) subtree_span(id flat.NodeId) (i32, i32) {
	n := f.node(id)
	mut lo := n.pos.offset
	mut hi := n.pos.end
	for k in f.kids(id) {
		klo, khi := f.subtree_span(k)
		if klo < lo {
			lo = klo
		}
		if khi > hi {
			hi = khi
		}
	}
	return lo, hi
}

// line_of returns the 1-based line of a byte offset.
fn (f &V3File) line_of(offset i32) int {
	mut lo := 0
	mut hi := f.line_starts.len - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if f.line_starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo + 1
}

fn (f &V3File) node(id flat.NodeId) &flat.Node {
	return f.a.node(id)
}

fn (f &V3File) kids(id flat.NodeId) []flat.NodeId {
	return f.a.children_of(f.a.node(id))
}

// line_is_pub reports whether the declaration on `line` is `pub`: V3's AST
// does not record visibility, the source line does.
fn (f &V3File) line_is_pub(line int) bool {
	return line >= 1 && line <= f.lines.len && f.lines[line - 1].trim_space().starts_with('pub ')
}

// is_flag_enum reports whether the declaration at `line` carries @[flag]. Its
// attribute lines sit above it, and the walk up passes over attributes and doc
// comments the way doc_from does.
fn (f &V3File) is_flag_enum(line int) bool {
	mut i := line - 2 // 0-based index of the line above the declaration
	for i >= 0 && i < f.lines.len {
		t := f.lines[i].trim_space()
		if t.starts_with('@[') {
			for attr in t.trim_string_left('@[').trim_string_right(']').split(';') {
				if attr.trim_space() == 'flag' {
					return true
				}
			}
		} else if !t.starts_with('//') {
			break
		}
		i--
	}
	return false
}

// declares_extern reports whether `line` declares a `fn C.` or `fn JS.`
// binding.
fn (f &V3File) declares_extern(line int) bool {
	if line < 1 || line > f.lines.len {
		return false
	}
	t := f.lines[line - 1]
	return t.contains('fn C.') || t.contains('fn JS.')
}

// declares_c_type reports whether `line` declares a C type, `type C.name = ...`.
fn (f &V3File) declares_c_type(line int) bool {
	if line < 1 || line > f.lines.len {
		return false
	}
	return f.lines[line - 1].contains('type C.')
}

// declares_c_extern reports whether `line` declares a C binding, `fn C.name(...)`.
fn (f &V3File) declares_c_extern(line int) bool {
	if line < 1 || line > f.lines.len {
		return false
	}
	return f.lines[line - 1].contains('fn C.')
}

// field_is_pub reports whether a struct field on `field_line` is public: under
// a `pub:` or `pub mut:` label, or, in a C struct, under no label at all, as V
// treats those.
fn (f &V3File) field_is_pub(struct_line int, field_line int, is_c bool) bool {
	for l := field_line - 1; l > struct_line && l >= 1; l-- {
		t := f.lines[l - 1].trim_space()
		if (t.ends_with(':') && !t.contains(' ')) || t == 'pub mut:' {
			return t.starts_with('pub')
		}
	}
	return is_c
}

// anon_type renames V3's anonymous struct and union types, which embed the
// file's absolute path (`AnonStruct__x2f_Users_..._vcs_x2e_v_1`, and
// `AnonStruct_S_x3a__x5c_...` on Windows), to V 0.5.2's host-independent
// `_VAnonStruct1`, keeping V3's per-file counter.
fn anon_type(t string) string {
	if !t.contains('Anon') {
		return t
	}
	mut out := t
	for kind in ['Struct', 'Union'] {
		marker := 'Anon${kind}_'
		mut from := 0
		for {
			start := out.index_after(marker, from) or { break }
			mut end := start
			for end < out.len && (out[end].is_alnum() || out[end] == `_`) {
				end++
			}
			name := out[start..end]
			counter := name.all_after_last('_')
			if name.contains('_x2e_v_') && counter.len > 0 && counter.bytes().all(it.is_digit()) {
				repl := '_VAnon${kind}${counter}'
				out = out[..start] + repl + out[end..]
				from = start + repl.len
			} else {
				from = end
			}
		}
	}
	return out
}

// type_text renders a type as V 0.5.2 did for this file: each module
// qualifier, wherever it sits in the type, written as the module's resolved
// path (`[]flat.NodeId` -> `[]v.flat.NodeId`, `m4.Vec4` -> `gg.m4.Vec4`), a
// type brought in by a selective import qualified the same way, and a
// function type as `fn (...)`.
fn (f &V3File) type_text(t_ string) string {
	t := anon_type(t_)
	mut out := []u8{cap: t.len + 16}
	mut i := 0
	for i < t.len {
		c := t[i]
		if !(c.is_letter() || c == `_`) || (i > 0 && (t[i - 1].is_alnum() || t[i - 1] == `_`)) {
			out << c
			i++
			continue
		}
		// a dotted name, `a`, `flat.NodeId`, `gg.m4.Vec4`
		mut j := i
		for j < t.len {
			if t[j].is_alnum() || t[j] == `_` {
				j++
			} else if t[j] == `.` && j + 1 < t.len && (t[j + 1].is_letter() || t[j + 1] == `_`) {
				j++
			} else if t[j..].starts_with(flat.named_variant_marker) {
				// the struct V3 declares for a named variant, `Expr@variant@Count`, is
				// one name: its `Count` is the variant's, not a type an import selects
				j += flat.named_variant_marker.len
			} else {
				break
			}
		}
		mut word := t[i..j]
		if word == 'fn' && j < t.len && t[j] == `(` {
			word = 'fn '
		} else if word.contains('.') {
			if full := f.imports[word.all_before('.')] {
				word = full + '.' + word.all_after('.')
			}
		} else if word[0].is_capital() {
			// a type from a selective import, `import m { T }`, is `m.T`
			if mod := f.selected[word] {
				word = mod + '.' + word
			}
		}
		out << word.bytes()
		i = j
	}
	return out.bytestr()
}

// base_name keeps a type's final identifier, as V 0.5.2's base_type_name did:
// `[]&ast.Expr` -> `Expr`, `veb.Middleware[Context]` -> `Middleware`. The
// struct of a named variant is one identifier, `Expr@variant@Count`: the sum
// type `type Expr = Count(int) | Void` declares it (see named_sum_type_decl in
// v/parser), and the variant's name alone, `Count`, names no type.
fn base_name(t string) string {
	name := strip_generic_args(anon_type(t))
	mut out := ''
	mut i := 0
	for i < name.len {
		ch := name[i]
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`)
			|| ch == `_` {
			out += ch.ascii_str()
		} else if out != '' && name[i..].starts_with(flat.named_variant_marker) {
			out += flat.named_variant_marker
			i += flat.named_variant_marker.len
			continue
		} else {
			out = ''
		}
		i++
	}
	return out
}

// type_ref names a type as an `embeds` or `references` edge records it: its
// bare name, `Base`, or with the path of the module it comes from,
// `veb.Context` -> `veb.Context`, `[]json.Any` -> `x.json2.Any`, and `Image`
// from `import sokol.gfx { Image }` -> `sokol.gfx.Image`, so that
// resolve_type_ref doesn't take a local type of the same name for it. A C or JS
// type keeps its qualifier, `C.Window` and `JS.Number`, since only a C or JS
// declaration is that type.
fn (f &V3File) type_ref(t string) string {
	base := base_name(t)
	name := strip_generic_args(anon_type(t))
	if base != '' && name.ends_with('.' + base) {
		head := name[..name.len - base.len - 1]
		mut i := head.len
		for i > 0 && (head[i - 1].is_alnum() || head[i - 1] == `_` || head[i - 1] == `.`) {
			i--
		}
		// a variadic `...JS.Any` leaves its dots on the qualifier
		qual := head[i..].trim_left('.')
		if qual in ['C', 'JS'] {
			return '${qual}.${base}'
		}
		// as written, `json.Any`, or as type_text renders it, `x.json2.Any`
		if path := f.imports[qual] {
			return '${path}.${base}'
		}
		for _, path in f.imports {
			if path == qual {
				return '${path}.${base}'
			}
		}
		return base
	}
	if path := f.selected[base] {
		return '${path}.${base}'
	}
	return base
}

// add_type_ref records that `from` references the type written `t`, as
// type_ref names it. An anonymous struct or union names no declaration: V3
// names it after the file and a counter that starts again in each file, so
// `_VAnonStruct1` is a different struct in each file that has one. `from`,
// the declaration that writes the `struct { ... }`, references the types of
// its fields instead, and of a nested one's fields.
fn (f &V3File) add_type_ref(from string, t string, mut edges []Edge, mut seen map[string]bool) {
	if f.anon.len > 0 {
		name := base_name(t)
		if id := f.anon[name] {
			if name in seen {
				return
			}
			seen[name] = true
			for k in f.kids(id) {
				fd := f.node(k)
				if fd.kind == .field_decl {
					f.add_type_ref(from, fd.typ_text(), mut edges, mut seen)
				}
			}
			return
		}
	}
	add_ref(from, f.type_ref(t), f.rel, mut edges, mut seen)
}

// recv_type renders a receiver type as walk_call stamps it: an unqualified type
// gets this module's id, a qualified one keeps its module.
fn (f &V3File) recv_type(t string) string {
	r := f.type_text(t).trim_left('&')
	return if r.contains('.') { r } else { '${f.mod_id}.${r}' }
}

// decl_name maps a V3 declaration name to V 0.5.2's: the static-method form
// `T@static@f` becomes `T__static__f`, and the `@` escape on a keyword name
// (`@type`) and a `C.`/`JS.` prefix are dropped.
fn decl_name(v string) string {
	return v.replace('@static@', '__static__').all_after_last('.').trim_left('@')
}

// host_qualifier is the `C.` or `JS.` a declaration name starts with, which
// decl_name drops, and '' for a V declaration.
fn host_qualifier(v string) string {
	return if v.starts_with('C.') {
		'C.'
	} else if v.starts_with('JS.') {
		'JS.'
	} else {
		''
	}
}

// source_name is a function's name as its declaration writes it: `Box.new` for the
// static method `Box__static__new` that decl_name gives, which its `fn Box.new[T]`
// header is found by.
fn source_name(name string) string {
	return name.replace('__static__', '.')
}

fn (mut f V3File) extract(root flat.NodeId) ([]Symbol, []Edge) {
	mut syms := []Symbol{}
	mut edges := []Edge{}
	top := f.kids(root)
	mut declared := 'main'
	mut mod_line := 1
	for id in top {
		n := f.node(id)
		if n.kind == .module_decl {
			declared = n.value_text()
			mod_line = f.line_of(n.pos.offset)
		}
	}
	f.mod_id = module_id(f.rel, declared)
	mod_id := f.mod_id
	syms << Symbol{
		id:        mod_id
		name:      mod_id
		kind:      .mod_
		signature: 'module ${declared}'
		file:      f.rel
		line:      mod_line
	}
	// an import inside `$if mysql ? { import db.mysql }` counts too, as every
	// branch of a `$if` does (extract_v3)
	for id in f.top_level_decls(top) {
		n := f.node(id)
		if n.kind != .import_decl {
			continue
		}
		written := n.value_text()
		path := resolve_import(written, f.real_path, f.rel)
		alias := if n.typ_text() != '' { n.typ_text() } else { written.all_after_last('.') }
		f.imports[alias] = path
		if n.typ_text() == '' && written != path {
			// an unaliased path that redirects (an alias directory, `x.json2`) is
			// still written as it was
			f.imports[written] = path
		}
		for k in f.kids(id) {
			sel := f.node(k)
			if sel.kind == .ident {
				f.selected[sel.value_text()] = path
			}
		}
		syms << Symbol{
			id:        import_id(mod_id, path)
			name:      path
			kind:      .import_
			signature: 'import ${path}' + if alias != path { ' as ${alias}' } else { '' } +
				if n.typ_text() == '' && written != path { ' from ${written}' } else { '' }
			file:      f.rel
			line:      f.line_of(n.pos.offset)
			parent:    mod_id
		}
		edges << Edge{
			from: mod_id
			to:   path
			kind: .imports
		}
	}
	f.extract_implied_imports(declared, mut syms, mut edges)
	if declared == 'main' {
		f.extract_script_main(top, mut syms, mut edges)
	}
	in_file := file_build(f.rel)
	mut branch_of := map[flat.NodeId]string{}
	f.top_level_builds(top, '', mut branch_of)
	for id in f.top_level_decls(top) {
		n := f.node(id)
		before := syms.len
		match n.kind {
			.fn_decl, .c_fn_decl { f.extract_fn(id, mut syms, mut edges) }
			.struct_decl { f.extract_struct(id, mut syms, mut edges) }
			.enum_decl { f.extract_enum(id, mut syms, mut edges) }
			.interface_decl { f.extract_interface(id, mut syms, mut edges) }
			.const_decl { f.extract_consts(id, mut syms, mut edges) }
			.global_decl { f.extract_globals(id, mut syms, mut edges) }
			.type_decl { f.extract_type(id, mut syms, mut edges) }
			else {}
		}
		build := join_build(in_file, branch_of[id] or { '' })
		if build != '' {
			for i in before .. syms.len {
				syms[i].build = build
			}
		}
	}
	return syms, edges
}

// extract_implied_imports records the modules V's parser imports by itself
// when a file uses certain syntax, as V 0.5.2's register_auto_import did:
// `builtin.closure` for an anonymous function, `sync.threads` for `spawn` or
// a `thread` type, `sync` for channels, `<-`, `shared`, `lock` and `select`,
// `math` for `**`, `v.preludes.embed_file` for `$embed_file` and `v.debug`
// for `$dbg`. Each is an import symbol whose signature ends in `(implied)`,
// on the line of its first use, so it serves dependency questions without
// passing for an import the file writes. A module doesn't imply itself, and
// an explicit import of the module comes first. Unlike V 0.5.2, it doesn't
// count an `it` expression (`a.map(it * 2)`) as a closure, since it compiles
// inline, nor a variable named `shared`.
fn (mut f V3File) extract_implied_imports(declared string, mut syms []Symbol, mut edges []Edge) {
	mut first := map[string]i32{}
	is_js := f.rel.ends_with('.js.v')
	for i, n in f.a.nodes {
		if i == 0 || n.pos.offset < 0 {
			continue
		}
		mut found := []string{}
		match n.kind {
			.fn_literal {
				// V 0.5.2 skipped it for the JS backend
				if !is_js {
					found << 'builtin.closure'
				}
			}
			.spawn_expr {
				found << 'sync.threads'
			}
			.lock_expr, .select_stmt {
				found << 'sync'
			}
			.debugger_stmt {
				found << 'v.debug'
			}
			.struct_init {
				if n.value_text() == 'embed_file.EmbedFileData' {
					found << 'v.preludes.embed_file'
					end := int_min(int(n.pos.end), f.src.len)
					if n.pos.offset < end && f.src[n.pos.offset..end].contains('.zlib') {
						found << 'v.preludes.embed_file.zlib'
					}
				} else if 'chan' in type_words(n.value_text()) {
					// a channel literal, `chan int{cap: 5}`
					found << 'sync'
				}
			}
			else {}
		}
		// `op` means an operator only on these; declarations reuse the field
		if n.kind in [.prefix, .infix, .assign, .selector_assign, .index_assign] {
			if n.op == .arrow {
				found << 'sync'
			} else if n.op in [.power, .power_assign] {
				found << 'math'
			}
		}
		if n.kind == .decl_assign && n.value_text() == 'shared' {
			found << 'sync'
		}
		if n.typ_text() != '' && n.kind != .struct_init {
			words := type_words(n.typ_text())
			if 'chan' in words || 'shared' in words {
				found << 'sync'
			}
			if 'thread' in words {
				found << 'sync.threads'
			}
		}
		for m in found {
			if m !in first || n.pos.offset < first[m] {
				first[m] = n.pos.offset
			}
		}
	}
	if first.len == 0 {
		return
	}
	mut written := map[string]bool{}
	for _, path in f.imports {
		written[path] = true
	}
	// a `module main` file, such as a test beside vlib/sync, imports `sync`
	own := if declared == 'main' { '' } else { own_module_name(f.rel) }
	mut mods := first.keys()
	mods.sort()
	for m in mods {
		if m == own || m in written {
			continue
		}
		syms << Symbol{
			id:        import_id(f.mod_id, m)
			name:      m
			kind:      .import_
			signature: 'import ${m} (implied)'
			file:      f.rel
			line:      f.line_of(first[m])
			parent:    f.mod_id
		}
		edges << Edge{
			from: f.mod_id
			to:   m
			kind: .imports
		}
	}
}

// type_words splits a type's text into its identifiers: `[]chan int` ->
// [chan, int].
fn type_words(t string) []string {
	mut words := []string{}
	mut start := -1
	for i := 0; i <= t.len; i++ {
		ident := i < t.len && (t[i].is_alnum() || t[i] == `_`)
		if ident && start < 0 {
			start = i
		} else if !ident && start >= 0 {
			words << t[start..i]
			start = -1
		}
	}
	return words
}

// own_module_name is the module a file in V's own `vlib` belongs to, as V
// names it (`vlib/sync/threads/x.v` -> `sync.threads`); '' elsewhere.
fn own_module_name(rel string) string {
	r := rel.replace('\\', '/')
	if !r.starts_with('vlib/') || !r[5..].contains('/') {
		return ''
	}
	return r[5..].all_before_last('/').replace('/', '.')
}

// script_stmt_kinds are the statements a V script may have at file scope.
const script_stmt_kinds = [flat.NodeKind.expr_stmt, .decl_assign, .assign, .selector_assign,
	.index_assign, .for_stmt, .for_in_stmt, .if_expr, .match_stmt, .defer_stmt, .return_stmt,
	.assert_stmt, .lock_expr, .select_stmt]

// extract_script_main gives a script, a `main` file with statements at file
// scope and no `fn main`, the `main` function V runs those statements as: V3
// leaves them at file scope, where V 0.5.2's script mode wrapped them.
fn (mut f V3File) extract_script_main(top []flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	mut stmts := []flat.NodeId{}
	for id in top {
		n := f.node(id)
		if n.kind == .fn_decl && n.value_text() == 'main' {
			return
		}
		if n.kind in script_stmt_kinds {
			stmts << id
		}
	}
	if stmts.len == 0 {
		return
	}
	fid := '${f.mod_id}.main'
	first, _ := f.subtree_span(stmts[0])
	_, last := f.subtree_span(stmts.last())
	line := f.line_of(first)
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        fid
		name:      'main'
		kind:      .function
		signature: 'fn main()'
		file:      f.rel
		line:      line
		// from the first statement to the end of the last, which V 0.5.2
		// recorded as line 1 to line 1
		end_line: f.line_of(if last > first { last - 1 } else { last })
		parent:    f.mod_id
	})
	mut seen := map[string]bool{}
	f.walk_list(stmts, V3CallCtx{
		from: fid
		file: f.rel
	}, mut edges, mut seen)
}

// top_level_decls flattens the `block` a file-scope `$if` leaves for the
// branch the parser kept (and, with every branch kept, the `comptime_if` that
// holds one block per branch) into the statements around it.
fn (f &V3File) top_level_decls(ids []flat.NodeId) []flat.NodeId {
	mut out := []flat.NodeId{cap: ids.len}
	for id in ids {
		n := f.node(id)
		if n.kind in [.block, .comptime_if] {
			out << f.top_level_decls(f.kids(id))
			continue
		}
		out << id
	}
	return out
}

// top_level_builds maps each declaration that top_level_decls flattens out of a
// file-scope `$if` to the condition of the branch it is in, `use_openssl ?` or
// `!windows`, nested ones joined by `&&` (see Symbol.build).
fn (f &V3File) top_level_builds(ids []flat.NodeId, cond string, mut out map[flat.NodeId]string) {
	for id in ids {
		n := f.node(id)
		match n.kind {
			.comptime_if {
				for i, k in f.kids(id) {
					// the block of `$if c`, then its `$else` (an `$else $if` is a
					// `$if` nested in the `$else`), as in method_branches
					c := f.build_cond(n)
					here := if i == 0 { c } else { negate_build(c) }
					f.top_level_builds([k], join_build(cond, here), mut out)
				}
			}
			.block {
				f.top_level_builds(f.kids(id), cond, mut out)
			}
			else {
				if cond != '' {
					out[id] = cond
				}
			}
		}
	}
}

// build_cond is the condition of the `$if` node `n` as its source writes it:
// `@OS == 'linux'`, `use_openssl ?`. The parser's own text for it has `@OS`
// replaced by the host's OS, `'macos'=='linux'`, which would make the graph differ
// by the OS that extracts it.
fn (f &V3File) build_cond(n flat.Node) string {
	at := int(n.pos.offset)
	if at >= 0 && at < f.src.len && f.src[at..].starts_with('\$if') {
		if end := f.src[at..].index('{') {
			return spaced_build(f.src[at + 3..at + end])
		}
	}
	// an arm of a file-scope `$match @OS` is a `$if` the parser makes, with no
	// source of its own and the host's OS for its subject
	c := spaced_build(n.value_text())
	host := "'${os.user_os()}' == "
	return if c.starts_with(host) { '@OS == ' + c[host.len..] } else { c }
}

// spaced_build is a `$if` condition, as the parser keeps it, `a?|| b?`, or as a
// file writes it, `a ?|| b ?`, spaced one way: `a ? || b ?`, `@OS == 'linux'`.
fn spaced_build(cond string) string {
	c := cond.replace(' ', '').replace('\t', '').replace('\n', '').replace('\r', '')
	return c.replace('?', ' ?').replace('&&', ' && ').replace('||', ' || ').replace('!=',
		'\x01').replace('==', ' == ').replace('\x01', ' != ')
}

// join_build is the condition that both `a` and `b` hold, either of which may be
// empty for every build.
fn join_build(a string, b string) string {
	if a == '' {
		return b
	}
	if b == '' {
		return a
	}
	return '${grouped_build(a)} && ${grouped_build(b)}'
}

// either_build is the condition that `a` or `b` holds, for two call sites of one
// edge: empty, every build, when either is, or when they have a condition and its
// opposite between them (`windows` and `!windows`, `windows || linux` and `!windows`,
// or `windows || linux` and `!(windows || linux)`).
fn either_build(a string, b string) string {
	if a == '' || b == '' {
		return ''
	}
	if a == b {
		return a
	}
	// each one's alternatives, and each as a whole
	mut alternatives := split_build(a, `|`)
	alternatives << split_build(b, `|`)
	alternatives << unbracketed(a)
	alternatives << unbracketed(b)
	for alt in alternatives {
		if opposite_term(alt) in alternatives {
			return ''
		}
	}
	if rest := absorbed_build(a, b) {
		return rest
	}
	return '${grouped_build(a)} || ${grouped_build(b)}'
}

// absorbed_build is the condition `(x && p) || (x && !p)` holds under, which is `x`: the
// terms of `a` other than `p`, when `b` has the opposite of `p` and the same other
// terms. none when no term of `a` is absorbed this way, so either_build joins them.
fn absorbed_build(a string, b string) ?string {
	at := split_build(a, `&`)
	bt := split_build(b, `&`)
	for p in at {
		q := opposite_term(p)
		if q !in bt {
			continue
		}
		rest := at.filter(it != p)
		others := bt.filter(it != q)
		mut sorted_rest := rest.clone()
		mut sorted_others := others.clone()
		sorted_rest.sort()
		sorted_others.sort()
		if sorted_rest == sorted_others {
			return rest.map(grouped_build(it)).join(' && ')
		}
	}
	return none
}

// grouped_build is `cond` in brackets when it has a `||` outside any brackets of its
// own, so that it keeps its meaning beside an `&&`.
fn grouped_build(cond string) string {
	mut depth := 0
	for i := 0; i < cond.len; i++ {
		match cond[i] {
			`(` {
				depth++
			}
			`)` {
				depth--
			}
			`|` {
				if depth == 0 && i + 1 < cond.len && cond[i + 1] == `|` {
					return '(${cond})'
				}
			}
			else {}
		}
	}
	return cond
}

// is_build_cond reports whether a `$if` condition, as the parser keeps it, picks
// builds: a flag, an OS, `@OS == 'linux'`, joined by `&&`, `||` and `!`. One that
// tests a type, `T is X` or `x in [A, B]`, or a member of a value, `field.is_option`
// in a `$for`, picks no build: every build compiles one branch or another of it.
fn is_build_cond(cond string) bool {
	mut c := cond
	// a string literal is no name: `@OS == 'macos'`
	for q in ['\'', '"'] {
		for {
			start := c.index(q) or { break }
			end := c.index_after(q, start + 1) or { break }
			c = c[..start] + c[end + 1..]
		}
	}
	if c.contains('.') {
		return false
	}
	for word in c.replace('(', ' ').replace(')', ' ').replace('!', ' ').fields() {
		if word in ['is', 'in'] {
			return false
		}
	}
	return true
}

// negate_build is the condition under which `cond` doesn't hold: `!x ?` for
// `x ?`, `windows` for `!windows`, `!(a || b)` for `a || b` and
// `!(@OS == 'linux')` for `@OS == 'linux'`.
fn negate_build(cond string) string {
	c := cond.trim_space()
	name := c.trim_left('!').trim_string_right(' ?')
	if name.len > 0 && name.bytes().all(it.is_letter() || it.is_digit() || it == `_`) {
		return if c.starts_with('!') { c[1..] } else { '!' + c }
	}
	return '!(${c})'
}

// os_file_builds are the OS a file-name suffix is for, as V decides which files
// to compile (pref.file_has_incompatible_os_only_suffix), as a `$if` condition.
// `_default` is left out: V compiles it on an OS without a file of its own, which
// no one condition says.
const os_file_builds = {
	'nix':                     '!windows'
	'windows':                 'windows'
	'linux':                   'linux'
	'macos':                   'macos'
	'darwin':                  'macos'
	'bsd':                     'bsd'
	'android_outside_termux':  'android && !termux'
	'termux':                  'termux'
	'android':                 'android'
	'ios':                     'ios'
	'freebsd':                 'freebsd'
	'openbsd':                 'openbsd'
	'netbsd':                  'netbsd'
	'dragonfly':               'dragonfly'
	'solaris':                 'solaris'
	'qnx':                     'qnx'
	'haiku':                   'haiku'
	'serenity':                'serenity'
	'vinix':                   'vinix'
	'wasm32_emscripten':       'wasm32_emscripten'
}

// arch_file_builds are the architectures a file-name suffix is for, as in
// pref.file_has_incompatible_target_suffix.
const arch_file_builds = ['amd64', 'x64', 'x86_64', 'arm64', 'aarch64', 'x86', 'i386', 'i486',
	'i586', 'i686', 'x32', 'x86_32', 'ia32', 'arm32', 'rv32', 'riscv32', 'rv64', 'riscv64', 'ppc',
	'ppc64', 'ppc64le', 's390x', 'loongarch64', 'sparc64', 'wasm32']

// file_build is the condition under which V compiles a file, from its name: a
// `_d_flag` or `_notd_flag` suffix (`flag ?`, `!flag ?`), an OS or architecture
// suffix (`_nix` is `!windows`), and the `.js.v` of the JavaScript backend (`js`).
// Empty for a file every build compiles.
fn file_build(rel string) string {
	name := rel.all_after_last('/')
	mut stem := name.all_before('.')
	mut conds := []string{}
	if name.ends_with('.js.v') {
		conds << 'js'
	}
	// a test is named as the file it tests, then `_test`
	stem = stem.trim_string_right('_test')
	for marker in ['_notd_', '_d_'] {
		if at := stem.last_index(marker) {
			flag := stem[at + marker.len..]
			if flag != '' {
				conds << if marker == '_d_' { '${flag} ?' } else { '!${flag} ?' }
				stem = stem[..at]
			}
			break
		}
	}
	mut os_cond := ''
	mut best := 0
	for suffix, cond in os_file_builds {
		// the longest suffix: `_android_outside_termux` before `_termux`
		if suffix.len > best && stem.ends_with('_' + suffix) {
			os_cond, best = cond, suffix.len
		}
	}
	if os_cond != '' {
		conds << os_cond
		stem = stem[..stem.len - best - 1]
	}
	for arch in arch_file_builds {
		if stem.ends_with('_' + arch) {
			conds << arch
			break
		}
	}
	// the conditions read from the end of the name; written from its start
	conds.reverse_in_place()
	return conds.join(' && ')
}

fn (mut f V3File) add_symbol(mut syms []Symbol, mut edges []Edge, s Symbol) {
	syms << s
	edges << Edge{
		from: s.parent
		to:   s.id
		kind: .defines
	}
}

fn (mut f V3File) extract_fn(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	kids := f.kids(id)
	v := n.value_text()
	if (v.starts_with('C.') || v.starts_with('JS.')) && v.count('.') == 1 {
		// an extern binding; a method on a C type, `C.SSL.str`, is real V
		return
	}
	// V3 parses both `fn C.puts(...)` and a body-less V declaration (`fn slopediv(num u32)
	// int` in a .c.v file) as c_fn_decl, with the `C.` dropped from the name; only the
	// source line tells them apart. A C binding is a function of the C namespace, with id
	// `C.name`, so it cannot collide with a V function of the same name in its file.
	c_extern := n.kind == .c_fn_decl && f.declares_c_extern(f.line_of(n.pos.offset))
	if n.kind == .c_fn_decl && f.declares_extern(f.line_of(n.pos.offset)) && !c_extern {
		// a `fn JS.name` binding: call resolution to it is not modelled
		return
	}
	if v.starts_with('__v_') {
		// a function V3 synthesizes, such as one per file-scope $compile_error
		return
	}
	is_static := v.contains('@static@')
	mut params := []flat.NodeId{}
	for k in kids {
		if f.node(k).kind == .param {
			params << k
		}
	}
	is_method := !is_static && v.contains('.') && params.len > 0
	name := decl_name(v)
	if name == '' {
		return
	}
	line := f.line_of(n.pos.offset)
	mut recv_name := ''
	mut recv_typ := ''
	mut fid := '${f.mod_id}.${name}'
	if is_method {
		r := f.node(params[0])
		recv_name = r.value_text()
		recv_typ = f.type_text(r.typ_text())
		fid = '${f.mod_id}.${recv_typ.trim_left('&')}.${name}'
	}
	if c_extern {
		fid = 'C.${name}'
	}
	mut sig := if c_extern {
		'fn C.'
	} else if f.line_is_pub(line) {
		'pub fn '
	} else {
		'fn '
	}
	if is_method {
		sig += '(${f.receiver_text(recv_name, recv_typ, f.node(params[0]).is_mut, line)}) '
	}
	start := if is_method { 1 } else { 0 }
	mut parts := []string{}
	for i := start; i < params.len; i++ {
		pn := f.node(params[i])
		parts << f.param_text(pn, f.type_text(pn.typ_text()))
	}
	sig += '${name}(${parts.join(', ')})'
	if n.typ_text() != '' && n.typ_text() != 'void' {
		sig += ' ${f.type_text(n.typ_text())}'
	}
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        fid
		name:      name
		kind:      if is_method { SymbolKind.method } else { SymbolKind.function }
		signature: sig
		file:      f.rel
		line:      line
		end_line:  f.header_end_line(n.pos.offset)
		is_pub:    f.line_is_pub(line)
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
		recipe:    if is_method { split_type_args(recv_typ).join(',') } else { f.generic_params(line, 'fn ${source_name(name)}').join(',') }
		tparams:   if is_method { f.method_tparams(line, name).join(',') } else { '' }
	})
	mut rseen := map[string]bool{}
	if is_method {
		f.add_type_ref(fid, recv_typ, mut edges, mut rseen)
	}
	for i := start; i < params.len; i++ {
		f.add_type_ref(fid, f.node(params[i]).typ_text(), mut edges, mut rseen)
	}
	if n.typ_text() != '' && n.typ_text() != 'void' {
		f.add_type_ref(fid, n.typ_text(), mut edges, mut rseen)
	}
	mut locals := map[string]string{}
	mut vars := map[string]string{}
	for pid in params {
		pn := f.node(pid)
		if pn.value_text() != '' && pn.value_text() != '_' {
			vars[pn.value_text()] = if pn.typ_text() != '' { 't:' + f.type_text(pn.typ_text()) } else { '' }
		}
	}
	for i := start; i < params.len; i++ {
		pn := f.node(params[i])
		if t := f.param_type(pn) {
			locals[pn.value_text()] = t
		}
	}
	ctx := V3CallCtx{
		from:      fid
		recv_name: recv_name
		recv_type: if is_method { '${f.mod_id}.${recv_typ.trim_left('&')}' } else { '' }
		file:      f.rel
		tparams:   if is_method { split_type_args(recv_typ) } else { f.generic_params(line, 'fn ${source_name(name)}') }
		locals:    locals
		vars:      vars
	}
	mut seen := map[string]bool{}
	mut body := []flat.NodeId{}
	for k in kids {
		if f.node(k).kind != .param {
			body << k
		}
	}
	f.walk_list(body, ctx, mut edges, mut seen)
}

// param_text renders a parameter as its declaration writes it, `mut buf []u8` and
// `shared s T`: V3 gives a `mut` parameter its type with a `&` for the reference it
// passes, `&[]u8`, and the source after its name says whether the `&` is written
// (`mut p &T`) or V's (`mut p T`); `shared` comes as part of its type.
fn (f &V3File) param_text(pn &flat.Node, typ string) string {
	if typ.starts_with('shared ') {
		return 'shared ${pn.value_text()} ${typ[7..]}'
	}
	if !pn.is_mut {
		return '${pn.value_text()} ${typ}'
	}
	after := f.src[int(pn.pos.end)..].trim_left(' \t')
	written := if typ.starts_with('&') && !after.starts_with('&') { typ[1..] } else { typ }
	return 'mut ${pn.value_text()} ${written}'
}

// receiver_text renders a method's receiver as its declaration writes it, `mut c T`,
// `c &T` or `mut c &T`, from the declaration's line: V3 gives a `mut` receiver the
// type `&T` and doesn't place the receiver's own span on it.
fn (f &V3File) receiver_text(name string, typ string, is_mut bool, line int) string {
	if !is_mut {
		return '${name} ${typ}'
	}
	mut written := typ
	if typ.starts_with('&') && line > 0 && line <= f.lines.len {
		decl := f.lines[line - 1]
		open := decl.index('fn (') or { decl.index('fn(') or { -1 } }
		recv := if open >= 0 { decl[open..].all_after('(').all_before(')') } else { '' }
		// `mut c &T` keeps its `&`; `mut c T` is V's
		if !recv.all_after(name).trim_space().starts_with('&') {
			written = typ[1..]
		}
	}
	return 'mut ${name} ${written}'
}

fn (mut f V3File) extract_struct(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value_text())
	if short == '' {
		return
	}
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
	// a C struct, `struct C.name`, keeps its `C.` on the signature, which tells it from
	// a V struct of the same name (see field_of), and a JS one its `JS.` (see
	// resolve_type_ref)
	host_prefix := host_qualifier(n.value_text())
	// and on its id, `<module>.C.name`: it is a type of its own, not the V type `name`
	// of its module, such as the alias `type name = C.name` beside it, which would
	// otherwise share the id. Its methods are `<module>.C.name.method` already.
	sid := if host_prefix == 'C.' { '${f.mod_id}.C.${short}' } else { '${f.mod_id}.${short}' }
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        sid
		name:      short
		kind:      .struct_
		signature: (if is_pub { 'pub ' } else { '' }) + 'struct ${host_prefix}${short}'
		file:      f.rel
		line:      line
		end_line:  f.line_of(n.pos.end)
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
		recipe:    f.generic_params(line, 'struct ${short}').join(',')
	})
	mut rseen := map[string]bool{}
	for k in f.kids(id) {
		fd := f.node(k)
		if fd.kind != .field_decl {
			continue
		}
		base := base_name(fd.typ_text())
		// an embedded struct with a default, `Base = value`, has no type of its own: V3
		// lists it as a field named by its type, with the default as its initializer
		embedded := if fd.value_text() == fd.typ_text() && base.len > 0 && base[0].is_capital() {
			fd.typ_text()
		} else if fd.typ_text() == '' && fd.value_text().len > 0 && fd.value_text()[0].is_capital() {
			fd.value_text()
		} else {
			''
		}
		if embedded != '' {
			// an embedded struct: V3 lists it as a field named by its type as
			// written, `Base`, `veb.Middleware[Context]`
			edges << Edge{
				from: sid
				to:   f.type_ref(embedded)
				kind: .embeds
				file: f.rel
			}
			add_ref(sid, f.type_ref(embedded), f.rel, mut edges, mut rseen)
			// a default `Base = value` is also the field its calls are made from, so it
			// continues below as before; only a written type, `Base Type`, ends here
			if fd.typ_text() != '' {
				continue
			}
		}
		fline := f.line_of(fd.pos.offset)
		tname := f.type_text(fd.typ_text())
		fname := fd.value_text().trim_left('@')
		f.add_symbol(mut syms, mut edges, Symbol{
			id:        '${sid}.${fname}'
			name:      fname
			kind:      .field
			signature: '${fname} ${tname}'
			file:      f.rel
			line:      fline
			end_line:  f.line_of(fd.pos.end)
			is_pub:    f.field_is_pub(line, fline, n.value_text().starts_with('C.'))
			parent:    sid
		})
		f.walk_initializer(.field, fname, fline, f.kids(k), mut edges)
		f.add_type_ref(sid, fd.typ_text(), mut edges, mut rseen)
	}
}

fn (mut f V3File) extract_enum(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value_text())
	if short == '' {
		return
	}
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
	// `zero()` is V's own only on a @[flag] enum, so the flag goes in the signature
	is_flag := f.is_flag_enum(line)
	// V3's enum_decl spans only its name: the enum ends at the `}` after its
	// last field
	mut after := int(n.pos.end)
	for k in f.kids(id) {
		e := int(f.node(k).pos.end)
		if e > after {
			after = e
		}
	}
	close := f.src.index_after('}', after) or { after }
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        '${f.mod_id}.${short}'
		name:      short
		kind:      .enum_
		signature: (if is_flag { '@[flag] ' } else { '' }) + (if is_pub { 'pub ' } else { '' }) + 'enum ${short}'
		file:      f.rel
		line:      line
		end_line:  f.line_of(i32(close))
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
	})
}

fn (mut f V3File) extract_interface(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value_text())
	if short == '' {
		return
	}
	iid := '${f.mod_id}.${short}'
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        iid
		name:      short
		kind:      .interface_
		signature: (if is_pub { 'pub ' } else { '' }) + 'interface ${host_qualifier(n.value_text())}${short}'
		file:      f.rel
		line:      line
		end_line:  f.line_of(n.pos.end)
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
	})
	mut rseen := map[string]bool{}
	for k in f.kids(id) {
		m := f.node(k)
		if m.kind != .interface_field {
			continue
		}
		mline := f.line_of(m.pos.offset)
		if m.op == .dot {
			// a method; V3 marks it with `op`, its parameters are its children
			mut parts := []string{}
			mut mseen := map[string]bool{}
			mid := '${iid}.${m.value_text()}'
			for pk in f.kids(k) {
				pn := f.node(pk)
				if pn.kind == .param {
					parts << f.param_text(pn, f.type_text(pn.typ_text()))
					f.add_type_ref(mid, pn.typ_text(), mut edges, mut mseen)
				}
			}
			mut sig := 'fn (${short}) ${m.value_text()}(${parts.join(', ')})'
			if m.typ_text() != '' && m.typ_text() != 'void' {
				sig += ' ${f.type_text(m.typ_text())}'
				f.add_type_ref(mid, m.typ_text(), mut edges, mut mseen)
			}
			f.add_symbol(mut syms, mut edges, Symbol{
				id:        mid
				name:      m.value_text()
				kind:      .method
				signature: sig
				file:      f.rel
				line:      mline
				end_line:  mline
				is_pub:    is_pub
				parent:    f.mod_id
				doc:       doc_from(f.lines, mline)
			})
			continue
		}
		// an embedded interface is a member with no type and a capitalized
		// name; fields are lower case
		base := base_name(m.value_text())
		if m.typ_text() == '' && base.len > 0 && base[0].is_capital() {
			edges << Edge{
				from: iid
				to:   f.type_ref(m.value_text())
				kind: .embeds
				file: f.rel
			}
			add_ref(iid, f.type_ref(m.value_text()), f.rel, mut edges, mut rseen)
			continue
		}
		if m.typ_text() != '' {
			f.add_symbol(mut syms, mut edges, Symbol{
				id:        '${iid}.${m.value_text()}'
				name:      m.value_text()
				kind:      .field
				signature: '${m.value_text()} ${f.type_text(m.typ_text())}'
				file:      f.rel
				line:      mline
				end_line:  mline
				is_pub:    is_pub
				parent:    iid
			})
			f.add_type_ref(iid, m.typ_text(), mut edges, mut rseen)
		}
	}
}

fn (mut f V3File) extract_consts(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	decl_line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(decl_line)
	for k in f.kids(id) {
		cf := f.node(k)
		if cf.kind != .const_field {
			continue
		}
		name := decl_name(cf.value_text())
		value := f.kids(k)
		f.add_symbol(mut syms, mut edges, Symbol{
			id:        '${f.mod_id}.${name}'
			name:      name
			kind:      .constant
			signature: (if is_pub { 'pub ' } else { '' }) + 'const ${name}'
			file:      f.rel
			line:      f.line_of(cf.pos.offset)
			end_line:  f.line_of(cf.pos.end)
			is_pub:    is_pub
			parent:    f.mod_id
			doc:       doc_from(f.lines, decl_line)
			// the type follows from the value, `const names = ['a']`
			recipe: if value.len > 0 { f.recipe(value[0], V3CallCtx{}) } else { '' }
		})
		f.walk_initializer(.constant, name, f.line_of(cf.pos.offset), value, mut edges)
	}
}

// extract_globals records each `__global` variable, with its type when the
// declaration writes one and the recipe of its value otherwise.
fn (mut f V3File) extract_globals(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	for k in f.kids(id) {
		g := f.node(k)
		if g.kind != .field_decl || g.value_text() == '' {
			continue
		}
		value := f.kids(k)
		typ := if g.typ_text() != '' { f.type_text(g.typ_text()) } else { '' }
		line := f.line_of(g.pos.offset)
		f.add_symbol(mut syms, mut edges, Symbol{
			id:        '${f.mod_id}.${g.value_text()}'
			name:      g.value_text()
			kind:      .global
			signature: '__global ${g.value_text()}' + if typ != '' { ' ${typ}' } else { '' }
			file:      f.rel
			line:      line
			end_line:  f.line_of(g.pos.end)
			parent:    f.mod_id
			doc:       doc_from(f.lines, line)
			recipe:    if typ != '' {
				't:' + typ
			} else if value.len > 0 {
				f.recipe(value[0], V3CallCtx{})
			} else {
				''
			}
		})
		f.walk_initializer(.global, g.value_text(), line, value, mut edges)
		if typ != '' {
			mut rseen := map[string]bool{}
			f.add_type_ref('${f.mod_id}.${g.value_text()}', g.typ_text(), mut edges, mut rseen)
		}
	}
}

fn (mut f V3File) extract_type(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value_text())
	if short == '' {
		return
	}
	line := f.line_of(n.pos.offset)
	// `type C.DWORD = u32` names a C type, one name for the program, as `fn C.name` names
	// a C function, so its id is C.DWORD and a `C.DWORD(x)` conversion reaches it
	c_type := f.declares_c_type(line)
	tid := if c_type { 'C.${short}' } else { '${f.mod_id}.${short}' }
	is_pub := f.line_is_pub(line)
	mut parts := []string{}
	mut rhs := ''
	variants := f.kids(id)
	if variants.len > 0 {
		for k in variants {
			parts << f.type_text(f.node(k).value_text())
		}
		rhs = parts.join(' | ')
	} else {
		rhs = f.type_text(n.typ_text())
		if rhs.starts_with('fn') {
			parts << fn_type_parts(rhs)
		} else {
			parts << rhs
		}
	}
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        tid
		name:      short
		kind:      .type_alias
		signature: (if is_pub { 'pub ' } else { '' }) + 'type ${if c_type { 'C.' } else { '' }}${short} = ${rhs}'
		file:      f.rel
		line:      line
		end_line:  line
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
	})
	mut rseen := map[string]bool{}
	for t in parts {
		f.add_type_ref(tid, t, mut edges, mut rseen)
	}
}

// param_type is the type id of a parameter whose type is a plain name, for
// V3CallCtx.locals.
fn (f &V3File) param_type(pn &flat.Node) ?string {
	// a function value keeps its written type, whose return type a call of it has
	if pn.value_text() != '' && pn.value_text() != '_' && pn.typ_text().starts_with('fn') {
		return pn.typ_text()
	}
	t := f.recv_type(pn.typ_text())
	if pn.value_text() != '' && pn.value_text() != '_' && t.bytes().all(it.is_alnum() || it == `_` || it == `.`)
		&& !is_generic_param(t.all_after_last('.')) {
		return t
	}
	return none
}

// fn_type_parts returns the parameter and return types of a function type
// written as text, `fn(id NodeId) bool` -> [NodeId, bool].
fn fn_type_parts(t string) []string {
	open := t.index('(') or { return [] }
	close := t.last_index(')') or { return [] }
	mut out := []string{}
	if close > open + 1 {
		for p in t[open + 1..close].split(',') {
			words := p.trim_space().split(' ')
			out << words.last()
		}
	}
	ret := t[close + 1..].trim_space()
	if ret != '' {
		out << ret
	}
	return out
}

// V3CallCtx is what the call walk knows at one point in a body: the enclosing
// declaration, its receiver, the locals whose type is written in the code, and
// a type recipe (see recipe) for each variable whose type can be worked out.
struct V3CallCtx {
	from      string
	recv_name string
	recv_type string
	file      string
	// tparams are the type parameters of the enclosing function, or of its
	// receiver's generic type, `T` in `fn encode[T](v T)`
	tparams []string
	// guards are the comptime conditions on a type parameter that the block being walked
	// is compiled under, each `+cond` or `-cond` (see guarded)
	guards []string
	// builds are the conditions of the `$if` branches around the block being walked,
	// outermost first, under which V compiles its calls (see built, Edge.build)
	builds []string
mut:
	locals map[string]string
	vars   map[string]string
	// fallbacks is the declared type of each variable narrowed by a type
	// check (see narrowed), where its narrowed type lacks a method
	fallbacks map[string]string
	// pins is the type recipe that a `$if` on a `$for` loop variable fixes
	// its selector to, keyed as comptime_pin keys it (see comptime_pin), and
	// under `kind:<variable>` the kinds of field the `$if`s around the block
	// narrow it to (see comptime_kind_pin)
	pins map[string]string
}

// TypeCheck is a variable, or a field of one (`x.base_type`), narrowed to a type by
// `name is typ`, as written.
struct TypeCheck {
	name string
	typ  string
}

// narrowed_by is `ctx` with each variable in `checks` narrowed to its type.
fn (ctx V3CallCtx) narrowed_by(checks []TypeCheck) V3CallCtx {
	mut out := ctx
	for c in checks {
		out = out.narrowed(c.name, 't:' + c.typ)
	}
	return out
}

// narrowed is `ctx` with the variable `name` taken to have the type `recipe`
// (see recipe). A narrowed receiver is no longer the receiver's own type, so a
// call on it goes by its recipe.
fn (ctx V3CallCtx) narrowed(name string, recipe string) V3CallCtx {
	// the declared type, which a method the narrowed type lacks is looked up on
	// (`x is Prim && x.name()` where `name` is on the sum type)
	declared := if name in ctx.fallbacks {
		ctx.fallbacks[name]
	} else if name in ctx.vars {
		ctx.vars[name]
	} else if name in ctx.locals {
		't:' + ctx.locals[name]
	} else if name == ctx.recv_name && ctx.recv_type != '' {
		't:' + ctx.recv_type
	} else {
		''
	}
	mut fallbacks := ctx.fallbacks.clone()
	fallbacks[name] = declared
	mut out := V3CallCtx{
		...ctx.with_vars([name], [recipe])
		fallbacks: fallbacks
	}
	if name == ctx.recv_name {
		out = V3CallCtx{
			...out
			recv_name: ''
			recv_type: ''
		}
	}
	return out
}

// comptime_type_is reads a `$if` condition that tests one type, `T is Empty`,
// as the name and the type: `T` and `Empty`. It is empty for any other
// condition, such as `T is $int`, which names a kind of types, not one type.
fn comptime_type_is(cond string) (string, string) {
	parts := cond.trim_space().split(' ')
	if parts.len != 3 || parts[1] != 'is' {
		return '', ''
	}
	typ := parts[2]
	if typ == '' || !(typ[0].is_letter() || typ[0] == `_`) {
		return '', ''
	}
	for c in typ {
		if !(c.is_alnum() || c == `_` || c == `.`) {
			return '', ''
		}
	}
	return parts[0], typ
}

// is_tparam_recipe reports whether a recipe is exactly a type parameter, `t:T`.
fn is_tparam_recipe(recipe string, tparams []string) bool {
	return recipe.starts_with('t:') && recipe[2..] in tparams
}

// guarded is `ctx` with the comptime condition `cond` known to hold (`+`) or to fail
// (`-`) in the block it walks: a `$if` block holds its condition, and the `$else`
// blocks after it fail it.
// built is `ctx` in the branch of a `$if` whose condition is `cond`, `linux` or
// `!use_openssl ?` (see Edge.build).
fn (ctx V3CallCtx) built(cond string) V3CallCtx {
	mut builds := ctx.builds.clone()
	builds << cond
	return V3CallCtx{
		...ctx
		builds: builds
	}
}

fn (ctx V3CallCtx) guarded(sign string, cond string) V3CallCtx {
	mut guards := ctx.guards.clone()
	guards << sign + cond
	return V3CallCtx{
		...ctx
		guards: guards
	}
}

// comptime_guard_tparam reports whether a `$if` condition tests a type parameter, `T is X`
// or `T.unaliased_typ is X`, so that its blocks are compiled only for some instances of T.
fn comptime_guard_tparam(cond string, tparams []string) bool {
	parts := cond.trim_space().split(' ')
	if parts.len != 3 || parts[1] != 'is' {
		return false
	}
	lhs := parts[0]
	name := if lhs.ends_with('.unaliased_typ') { lhs[..lhs.len - '.unaliased_typ'.len] } else { lhs }
	return name in tparams
}

// retyped is `ctx` with the type parameter `name` taken to be `typ`, in each
// variable, local and receiver whose type names it (`value T` becomes `value Empty`).
fn (ctx V3CallCtx) retyped(name string, typ string) V3CallCtx {
	mut vars := map[string]string{}
	for k, r in ctx.vars {
		vars[k] = retype_recipe(r, name, typ)
	}
	mut fallbacks := map[string]string{}
	for k, r in ctx.fallbacks {
		fallbacks[k] = retype_recipe(r, name, typ)
	}
	mut locals := map[string]string{}
	for k, t in ctx.locals {
		locals[k] = subst_word(t, name, typ)
	}
	return V3CallCtx{
		...ctx
		recv_type: subst_word(ctx.recv_type, name, typ)
		locals:    locals
		vars:      vars
		fallbacks: fallbacks
	}
}

// retype_recipe is `recipe` with the type parameter `name` replaced by `typ` in
// each step that names a type: the start `t:T`, and a generic call's type
// argument `p:T`.
fn retype_recipe(recipe string, name string, typ string) string {
	if !recipe.contains(name) {
		return recipe
	}
	mut alts := []string{}
	for alt in recipe.split(recipe_alt) {
		mut steps := []string{}
		for step in alt.split(recipe_sep) {
			if step.starts_with('t:') && subst_word(step[2..], name, typ) != step[2..] {
				// a type that names the parameter, narrowed to `typ`: both are kept, since whether
				// `typ` is an interface, which keeps the parameter, is known only to resolve_edges
				steps << 'ctp:' + step[2..] + ':' + subst_word(step[2..], name, typ)
			} else if step.starts_with('p:') {
				steps << 'p:' + subst_word(step[2..], name, typ)
			} else {
				steps << step
			}
		}
		alts << steps.join(recipe_sep)
	}
	return alts.join(recipe_alt)
}

// recipe_sep separates the steps of a type recipe. It is a control character
// that never occurs in V source and that the batch protocol passes through.
const recipe_sep = '\x05'

// recipe_alt separates a receiver's narrowed type recipe from the declared
// type recipe to fall back on, for a method the narrowed type doesn't have.
const recipe_alt = '\x06'

// methods_with_it are the array methods whose argument is an expression over
// each element, named `it`.
const methods_with_it = ['filter', 'map', 'any', 'all', 'count']

// with_vars returns `ctx` with `names` declared, each with its recipe ('' when
// its type is unknown); the new variable shadows any outer one.
fn (ctx V3CallCtx) with_vars(names []string, recipes []string) V3CallCtx {
	mut vars := ctx.vars.clone()
	mut locals := ctx.locals.clone()
	mut fallbacks := ctx.fallbacks.clone()
	// pins are rare (a `$if` on a loop variable), so they are copied only when some
	// are set, and a name declared here loses any pin it had
	mut pins := ctx.pins
	if pins.len > 0 {
		pins = pins.clone()
		for name in names {
			pins.delete('field:' + name)
			pins.delete('ret:' + name)
		}
	}
	for i, name in names {
		locals.delete(name)
		fallbacks.delete(name)
		vars[name] = recipes[i]
	}
	return V3CallCtx{
		...ctx
		locals:    locals
		vars:      vars
		fallbacks: fallbacks
		pins:      pins
	}
}

// comptime_kind_pin reads the condition of a `$if` as the kind of type it narrows a field
// loop's variable to: `field.typ is $map` and `field.is_map` give the key `kind:field`
// and `$map`. It returns none for a test that names one type (see comptime_pin) or no
// kind, such as `field.is_mut`.
fn comptime_kind_pin(cond string) ?(string, string) {
	c := cond.trim_space()
	if idx := c.index(' is ') {
		lhs := c[..idx].trim_space()
		rhs := c[idx + 4..].trim_space()
		if lhs.ends_with('.typ') && rhs.starts_with('$') && !rhs.contains(' ') {
			return 'kind:' + lhs[..lhs.len - 4], rhs
		}
		return none
	}
	dot := c.last_index('.') or { return none }
	kind := match c[dot + 1..] {
		'is_struct' { '$struct' }
		'is_array' { '$array' }
		'is_map' { '$map' }
		'is_option' { '$option' }
		'is_enum' { '$enum' }
		else { return none }
	}
	return 'kind:' + c[..dot], kind
}

// comptime_pin reads the condition of a `$if` as the type it fixes a `$for`
// loop variable's selector to. `field.typ is int` fixes `x.$(field.name)` to
// an int in its block, and `method.return_type is string` fixes `x.$method()`
// to a string. It returns the key that the selector looks up (see
// comptime_field_pin and comptime_ret_pin) and the recipe of the type. A test
// that names no one type (`$map`, `!is`, a compound condition) fixes nothing.
fn comptime_pin(cond string) ?(string, string) {
	if key, step := comptime_name_pin(cond) {
		return key, step
	}
	idx := cond.index(' is ') or { return none }
	lhs := cond[..idx].trim_space()
	rhs := cond[idx + 4..].trim_space()
	if rhs == '' || rhs.starts_with('$') || rhs.contains(' ') || is_generic_param(rhs) {
		return none
	}
	mut key := ''
	if lhs.ends_with('.typ') {
		key = 'field:' + lhs[..lhs.len - 4]
	} else if lhs.ends_with('.return_type') {
		key = 'ret:' + lhs[..lhs.len - 12]
	} else {
		return none
	}
	name := key.all_after(':')
	if name == '' || !name.bytes().all(it.is_alnum() || it == `_`) {
		return none
	}
	return key, 't:' + rhs
}

// comptime_name_pin is the pin a `$if field.name == 'x'` makes in a field loop: the loop's
// `y.$(field.name)` in its block is the field `x` of `y`, so the pin is that step
fn comptime_name_pin(cond string) ?(string, string) {
	idx := cond.index(' == ') or { return none }
	lhs := cond[..idx].trim_space()
	rhs := cond[idx + 4..].trim_space()
	if !lhs.ends_with('.name') || rhs.len < 3 || !rhs.starts_with("'") || !rhs.ends_with("'") {
		return none
	}
	name := rhs[1..rhs.len - 1]
	if !name.bytes().all(it.is_alnum() || it == `_`) {
		return none
	}
	return 'name:' + lhs[..lhs.len - 5], 'f:' + name
}

// comptime_name_step is the field step of `x.$(field.name)`, the selector `sel`, when a
// `$if field.name == 'x'` around it names the field: `f:x`, or '' when none does.
fn (f &V3File) comptime_name_step(sel flat.NodeId, ctx V3CallCtx) string {
	ks := f.kids(sel)
	if ks.len != 2 {
		return ''
	}
	inner := f.node(ks[1])
	ik := f.kids(ks[1])
	if inner.kind != .selector || inner.value_text() != 'name' || ik.len != 1 {
		return ''
	}
	if f.node(ik[0]).kind != .ident {
		return ''
	}
	return ctx.pins['name:' + f.node(ik[0]).value_text()] or { '' }
}

// comptime_field_pin is the recipe of `x.$(field.name)`, the selector `sel`
// whose inner name is `field.name`, when a `$if field.typ is T` around it
// fixes that field to T. The field is the one the loop walks, so its type is T
// wherever the `$if` holds.
fn (f &V3File) comptime_field_pin(sel flat.NodeId, ctx V3CallCtx) string {
	ks := f.kids(sel)
	if ks.len != 2 {
		return ''
	}
	inner := f.node(ks[1])
	ik := f.kids(ks[1])
	if inner.kind != .selector || inner.value_text() != 'name' || ik.len != 1 {
		return ''
	}
	if f.node(ik[0]).kind != .ident {
		return ''
	}
	return ctx.pins['field:' + f.node(ik[0]).value_text()] or { '' }
}

// field_any_step is the step of `x.$(field.name)`, the selector `sel`, in a `$for field
// in X.fields` loop that no `$if` fixes to one field or type: `fa:` and the kinds the
// enclosing `$if`s narrow the field to, `fa:$struct,!$map` (see comptime_kind_pin), or
// '' when the inner name is not a field loop's variable. Each iteration is another
// field, so the step stands for every field of x's type of those kinds.
fn (f &V3File) field_any_step(sel flat.NodeId, ctx V3CallCtx) string {
	ks := f.kids(sel)
	if ks.len != 2 {
		return ''
	}
	inner := f.node(ks[1])
	ik := f.kids(ks[1])
	if inner.kind != .selector || inner.value_text() != 'name' || ik.len != 1 {
		return ''
	}
	if f.node(ik[0]).kind != .ident {
		return ''
	}
	v := f.node(ik[0]).value_text()
	if (ctx.vars[v] or { '' }) != 't:builtin.FieldData' {
		return ''
	}
	return 'fa:' + (ctx.pins['kind:' + v] or { '' })
}

// is_dollar_selector reports whether `id` is a comptime selector, `x.$(...)` or
// `x.$method`, which the parser writes as a selector named `$` on `x`.
fn (f &V3File) is_dollar_selector(id flat.NodeId) bool {
	return f.node(id).kind == .selector && f.node(id).value_text() == '$' && f.kids(id).len == 2
}

// comptime_ret_pin is the recipe of `x.$method()`, the selector `sel` whose
// inner name is the method loop's variable, when a `$if method.return_type is T`
// around it fixes that method's return type to T.
fn (f &V3File) comptime_ret_pin(sel flat.NodeId, ctx V3CallCtx) string {
	ks := f.kids(sel)
	if ks.len != 2 || f.node(ks[1]).kind != .ident {
		return ''
	}
	return ctx.pins['ret:' + f.node(ks[1]).value_text()] or { '' }
}

// walk_initializer records the calls in a declaration's initializer as calls
// from the declaration itself: a constant, a global or a struct field's
// default value has no body to walk. The declaration is named by initializer_from
// because its final id isn't known yet (see resolve_initializer_callers).
fn (mut f V3File) walk_initializer(kind SymbolKind, name string, line int, ids []flat.NodeId, mut edges []Edge) {
	mut seen := map[string]bool{}
	f.walk_list(ids, V3CallCtx{
		from: initializer_from(kind, f.rel, line, name)
		file: f.rel
	}, mut edges, mut seen)
}

// initializer_from is the caller of a call in a constant's, global's or struct
// field's initializer, until resolve_initializer_callers gives it the
// declaration's final id. The file, line, kind and name are what the symbol
// keeps through the renames that set that id.
fn initializer_from(kind SymbolKind, file string, line int, name string) string {
	return 'init\x00${int(kind)}\x00${file}\x00${line}\x00${name}'
}

// walk_list walks sibling nodes in order. A `:=` types its variables for the
// siblings after it and nothing outside this list, which is ordinary lexical
// scoping.
fn (mut f V3File) walk_list(ids []flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) {
	mut cur := ctx
	for id in ids {
		cur = f.walk(id, cur, mut edges, mut seen)
	}
}

fn (mut f V3File) walk(id flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) V3CallCtx {
	if int(id) < 0 {
		return ctx
	}
	n := f.node(id)
	kids := f.kids(id)
	match n.kind {
		.call {
			if kids.len > 0 {
				f.record_call(kids[0], kids[1..], ctx, mut edges, mut seen)
				callee := f.node(kids[0])
				ck := f.kids(kids[0])
				if callee.kind == .selector && ck.len > 0
					&& (callee.value_text() in methods_with_it || callee.value_text() in ['sort', 'sorted']) {
					// `xs.filter(it.ok())`: `it` is one element of `xs`, and so
					// are `a` and `b` in `xs.sort(a.x < b.x)`
					r := f.recipe(ck[0], ctx)
					f.walk(kids[0], ctx, mut edges, mut seen)
					elem := if r == '' { '' } else { r + recipe_sep + '[]' }
					it_ctx := if callee.value_text() in methods_with_it {
						ctx.with_vars(['it'], [elem])
					} else {
						ctx.with_vars(['a', 'b'], [elem, elem])
					}
					f.walk_list(kids[1..], it_ctx, mut edges, mut seen)
					return ctx
				}
			}
		}
		.comptime_if {
			// `$if T is Empty { ... }` in a generic function: V compiles the block
			// only when T is Empty, so a variable typed T is an Empty in it; the
			// other branches keep T
			if kids.len >= 1 {
				name, typ := comptime_type_is(n.value_text())
				if name != '' && name in ctx.tparams {
					f.walk(kids[0], ctx.retyped(name, f.type_text(typ)), mut edges, mut seen)
					f.walk_list(kids[1..], ctx.guarded('-', n.value_text()), mut edges, mut seen)
					return ctx
				}
				// `$if data is bool` on a variable of type T: `data` is a bool in the block
				if name != '' && name in ctx.vars && is_tparam_recipe(ctx.vars[name], ctx.tparams) {
					f.walk(kids[0], ctx.with_vars([name], ['ct:' + f.type_text(typ)]), mut edges, mut seen)
					f.walk_list(kids[1..], ctx, mut edges, mut seen)
					return ctx
				}
			}
			// `$if T.unaliased_typ is string { ... }` in a generic function: the block is
			// compiled only for the instances of T that meet the condition, so its calls
			// carry it as a guard, and the blocks after it carry the negation
			if kids.len >= 1 && comptime_guard_tparam(n.value_text(), ctx.tparams) {
				f.walk(kids[0], ctx.guarded('+', n.value_text()), mut edges, mut seen)
				f.walk_list(kids[1..], ctx.guarded('-', n.value_text()), mut edges, mut seen)
				return ctx
			}
			// `$if field.typ is int { x.$(field.name) }` in a field loop: the
			// block's selector is an int (see comptime_pin). The branches after
			// it keep the context they had.
			if kids.len > 0 {
				if key, recipe := comptime_pin(n.value_text()) {
					mut pins := ctx.pins.clone()
					pins[key] = recipe
					f.walk(kids[0], V3CallCtx{ ...ctx, pins: pins }, mut edges, mut seen)
					f.walk_list(kids[1..], ctx, mut edges, mut seen)
					return ctx
				}
			}
			// `$if field.is_struct { x.$(field.name).init() }` in a field loop: the block's
			// selector is a field of that kind, and the branches after it are fields of
			// another kind (see field_any_step)
			if kids.len > 0 {
				if key, kind := comptime_kind_pin(n.value_text()) {
					old := ctx.pins[key] or { '' }
					mut held := ctx.pins.clone()
					held[key] = if old == '' { kind } else { old + ',' + kind }
					mut failed := ctx.pins.clone()
					failed[key] = if old == '' { '!' + kind } else { old + ',!' + kind }
					f.walk(kids[0], V3CallCtx{ ...ctx, pins: held }, mut edges, mut seen)
					f.walk_list(kids[1..], V3CallCtx{ ...ctx, pins: failed }, mut edges, mut
						seen)
					return ctx
				}
			}
			// `$if linux { ... }`, `$if use_openssl ? { ... }`: a branch's calls are made
			// only in the builds that take it, the block's when the condition holds and
			// an `$else`'s when it doesn't (an `$else $if` is a `$if` nested in it)
			if kids.len > 0 && is_build_cond(n.value_text()) {
				c := f.build_cond(n)
				for i, k in kids {
					f.walk(k, ctx.built(if i == 0 { c } else { negate_build(c) }), mut edges, mut
						seen)
				}
				return ctx
			}
		}
		.comptime_for {
			// `$for field in T.fields`: each field is a builtin FieldData, and each of
			// `$for a in T.attributes` a VAttribute
			parts := n.value_text().split('|')
			if parts.len == 2 && parts[1] in ['fields', 'attributes'] {
				typ := if parts[1] == 'fields' { 'FieldData' } else { 'VAttribute' }
				f.walk_list(kids, ctx.with_vars([parts[0]], ['t:builtin.${typ}']), mut edges, mut
					seen)
				return ctx
			}
		}
		.for_in_stmt {
			if kids.len >= 3 {
				// `for v in xs`, `for k, v in xs`: the second slot is empty
				// without a key
				iter := f.node(kids[2])
				r := f.recipe(kids[2], ctx)
				mut names := []string{}
				mut recipes := []string{}
				if iter.kind == .range {
					names << f.node(kids[0]).value_text()
					recipes << range_recipe(f, kids[2], ctx)
				} else if int(kids[1]) < 0 {
					names << f.node(kids[0]).value_text()
					recipes << if r == '' { '' } else { r + recipe_sep + '[]' }
				} else {
					names << f.node(kids[0]).value_text()
					recipes << if r == '' { '' } else { r + recipe_sep + 'k' }
					names << f.node(kids[1]).value_text()
					recipes << if r == '' { '' } else { r + recipe_sep + '[]' }
				}
				f.walk_list(kids, ctx.with_vars(names, recipes), mut edges, mut seen)
				return ctx
			}
		}
		.if_expr {
			// `if x := f() { ... } else { ... }`: `x` is declared for the
			// first branch, and the error is `err` in the rest
			if kids.len >= 2 && f.node(kids[0]).kind == .decl_assign {
				guard := f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], guard, mut edges, mut seen)
				f.walk_list(kids[2..], ctx.with_vars(['err'], ['t:IError']), mut edges, mut
					seen)
				return ctx
			}
			// `if x is T { ... }`: `x` is a T in the block, and the else
			// branches keep the type it had. `if x !is T { ... }` makes `x` a T in the
			// else branches, and after the `if` when its block always leaves
			// (`return`, `continue`, `panic()`)
			if kids.len >= 2 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], ctx.narrowed_by(f.type_checks(kids[0])), mut edges, mut seen)
				otherwise := ctx.narrowed_by(f.false_checks(kids[0]))
				f.walk_list(kids[2..], otherwise, mut edges, mut seen)
				if kids.len == 2 && f.always_leaves(kids[1]) {
					return otherwise
				}
				return ctx
			}
		}
		.infix {
			// `x is T && x.f()`: the right side sees `x` as a T
			if n.op == .logical_and && kids.len == 2 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], ctx.narrowed_by(f.type_checks(kids[0])), mut edges, mut seen)
				return ctx
			}
			// `x !is T || x.f()`: so does the right side of an `||`
			if n.op == .logical_or && kids.len == 2 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], ctx.narrowed_by(f.false_checks(kids[0])), mut edges, mut seen)
				return ctx
			}
		}
		.match_stmt {
			// `match x { T { ... } }`: `x` is a T in a branch with one type
			// pattern; a branch of values or `else` keeps its type
			if kids.len >= 1 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				for k in kids[1..] {
					f.walk_list(f.kids(k), f.match_branch_ctx(kids[0], k, ctx), mut edges, mut
						seen)
				}
				return ctx
			}
		}
		.or_expr {
			// inside `or { ... }`, `err` is the error
			if kids.len == 2 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], ctx.with_vars(['err'], ['t:IError']), mut edges, mut seen)
				return ctx
			}
		}
		.fn_literal {
			mut names := []string{}
			mut recipes := []string{}
			for k in kids {
				p := f.node(k)
				if p.kind == .param && p.value_text() != '' {
					names << p.value_text()
					recipes << if p.typ_text() != '' { 't:' + f.type_text(p.typ_text()) } else { '' }
				}
			}
			mut inner := ctx.with_vars(names, recipes)
			for k in kids {
				p := f.node(k)
				if p.kind == .param {
					if t := f.param_type(p) {
						inner.locals[p.value_text()] = t
					}
				}
			}
			f.walk_list(kids, inner, mut edges, mut seen)
			return ctx
		}
		else {}
	}
	if n.kind == .expr_stmt && kids.len == 1 && f.node(kids[0]).kind == .if_expr {
		// an `if` statement can narrow what follows it (see the if_expr case)
		return f.walk(kids[0], ctx, mut edges, mut seen)
	}
	f.walk_list(kids, ctx, mut edges, mut seen)
	if n.kind == .decl_assign {
		return f.declare(n, kids, ctx)
	}
	return ctx
}

// match_branch_ctx is `ctx` in the match branch `branch` on `subject`: a branch with
// one type pattern, `T { ... }`, sees a subject it can name (value_path) as a T; a
// branch of values or `else` keeps its type.
fn (f &V3File) match_branch_ctx(subject flat.NodeId, branch flat.NodeId, ctx V3CallCtx) V3CallCtx {
	path := f.value_path(subject)
	bk := f.kids(branch)
	if path != '' && f.node(branch).value_text() == '1' && bk.len >= 2 {
		if pt := f.match_pattern_type(bk[0]) {
			return ctx.narrowed(path, 't:' + f.type_text(pt))
		}
	}
	return ctx
}

// always_leaves reports whether a block never runs past its end: its last statement is a
// `return`, `break`, `continue` or `goto`, or a call of `panic` or `exit`.
fn (f &V3File) always_leaves(block flat.NodeId) bool {
	kids := f.kids(block)
	if kids.len == 0 {
		return false
	}
	last := f.node(kids.last())
	if last.kind in [.return_stmt, .break_stmt, .continue_stmt, .goto_stmt] {
		return true
	}
	if last.kind == .expr_stmt {
		lk := f.kids(kids.last())
		if lk.len == 1 && f.node(lk[0]).kind == .call {
			ck := f.kids(lk[0])
			return ck.len > 0 && f.node(ck[0]).kind == .ident
				&& f.node(ck[0]).value_text() in ['panic', 'exit']
		}
	}
	return false
}

// declare returns `ctx` with the variables a `:=` declares. `a := x` has the
// children [a, x], `a, b := x, y` [a, x, b, y], and `a, b := f()` [a, f(), b].
fn (f &V3File) declare(n &flat.Node, kids []flat.NodeId, ctx V3CallCtx) V3CallCtx {
	count := decl_count(n.value_text())
	mut names := []string{}
	mut recipes := []string{}
	if kids.len == 2 * count {
		for i := 0; i < kids.len; i += 2 {
			names << f.node(kids[i]).value_text()
			recipes << f.recipe(kids[i + 1], ctx)
		}
	} else if count > 1 && kids.len == count + 1 {
		mut lhs := [kids[0]]
		lhs << kids[2..]
		// `a, b := if ... { x, y } else { ... }`: each name takes the type of its own value,
		// not the first value's with `#i` after it, so a branch's `c` never types `b`
		if f.node(kids[1]).kind in [.if_expr, .match_stmt] {
			elems := f.tuple_recipes(kids[1], count, ctx)
			for i, k in lhs {
				names << f.node(k).value_text()
				recipes << elems[i]
			}
		} else {
			r := f.recipe(kids[1], ctx)
			for i, k in lhs {
				names << f.node(k).value_text()
				recipes << if r == '' { '' } else { r + recipe_sep + '#${i}' }
			}
		}
	} else {
		return ctx
	}
	mut out := ctx.with_vars(names, recipes)
	if count == 1 && f.node(kids[0]).kind == .ident {
		// a struct literal names its type outright, which resolves without
		// the graph (recv_type)
		if t := f.struct_init_type(kids[1]) {
			mut locals := out.locals.clone()
			locals[names[0]] = f.recv_type(t)
			out = V3CallCtx{
				...out
				locals: locals
			}
		}
	}
	return out
}

// tuple_recipes is the recipe of each value of an `if` or `match` that yields several, as
// `compressed, ext := match n { ... }` does: each value takes the recipe of the first branch
// that types it. A branch's own `:=` names are declared first, so the `c` in `c, '.zst'` is
// typed by the `c := f()` above it. A value no branch types has an empty recipe.
fn (f &V3File) tuple_recipes(id flat.NodeId, count int, ctx V3CallCtx) []string {
	mut out := []string{len: count}
	mut blocks := []flat.NodeId{}
	for k in f.kids(id) {
		if f.node(k).kind in [.block, .match_branch] {
			blocks << k
		}
	}
	for b in blocks {
		bctx, vals := f.branch_values(f.kids(b), ctx)
		if vals.len != count {
			continue
		}
		for i, v in vals {
			if out[i] == '' {
				out[i] = f.recipe(v, bctx)
			}
		}
	}
	return out
}

// branch_values is the context a branch's values are read in, and the values. The names a
// branch declares come first, and its values are the expressions of the block it ends in.
fn (f &V3File) branch_values(body []flat.NodeId, ctx V3CallCtx) (V3CallCtx, []flat.NodeId) {
	if body.len == 0 {
		return ctx, []flat.NodeId{}
	}
	mut bctx := ctx
	for s in body[..body.len - 1] {
		if f.node(s).kind == .decl_assign {
			bctx = f.declare(f.node(s), f.kids(s), bctx)
		}
	}
	last := body.last()
	mut vals := []flat.NodeId{}
	if f.node(last).kind == .block {
		for v in f.kids(last) {
			vals << if f.node(v).kind == .expr_stmt && f.kids(v).len > 0 { f.kids(v)[0] } else { v }
		}
	} else if f.node(last).kind == .expr_stmt && f.kids(last).len > 0 {
		vals << f.kids(last)[0]
	}
	return bctx, vals
}

// decl_count is how many names a `:=` declares, from the node's value. The
// parser leaves it empty for one name and writes the count for several. A
// `shared`, `atomic`, `volatile` or `static` in front of the statement is written
// in front of that: `shared s := x` has the value 'shared', `shared a, b := f()`
// 'shared:2'. Any other value declares none, as before.
fn decl_count(value string) int {
	last := value.all_after_last(':')
	if last == '' || last in ['shared', 'atomic', 'volatile', 'static'] {
		return 1
	}
	for i in 0 .. last.len {
		if !last[i].is_digit() {
			return 0
		}
	}
	return last.int()
}

// type_checks are the `x is T` checks that hold where `cond` is true: the
// check itself, or the checks on both sides of an `&&`.
fn (f &V3File) type_checks(cond flat.NodeId) []TypeCheck {
	if int(cond) < 0 {
		return []TypeCheck{}
	}
	n := f.node(cond)
	kids := f.kids(cond)
	if n.kind == .is_expr && kids.len == 1 && n.value_text() != '' && n.op != .not {
		path := f.value_path(kids[0])
		if path != '' {
			return [TypeCheck{
				name: path
				typ:  n.value_text()
			}]
		}
	}
	if n.kind == .infix && n.op == .logical_and && kids.len == 2 {
		mut out := f.type_checks(kids[0])
		out << f.type_checks(kids[1])
		return out
	}
	if n.kind == .paren && kids.len == 1 {
		return f.type_checks(kids[0])
	}
	return []TypeCheck{}
}

// false_checks are the `x is T` checks that hold where `cond` is false: those of
// `x !is T` (`!(x is T)`), or of both sides of an `||`.
fn (f &V3File) false_checks(cond flat.NodeId) []TypeCheck {
	if int(cond) < 0 {
		return []TypeCheck{}
	}
	n := f.node(cond)
	kids := f.kids(cond)
	if n.kind == .prefix && n.op == .not && kids.len == 1 {
		mut inner := kids[0]
		for f.node(inner).kind == .paren && f.kids(inner).len == 1 {
			inner = f.kids(inner)[0]
		}
		if f.node(inner).kind == .is_expr {
			return f.type_checks(inner)
		}
	}
	if n.kind == .infix && n.op == .logical_or && kids.len == 2 {
		mut out := f.false_checks(kids[0])
		out << f.false_checks(kids[1])
		return out
	}
	if n.kind == .paren && kids.len == 1 {
		return f.false_checks(kids[0])
	}
	return []TypeCheck{}
}

// value_path is the variable or field a type check can narrow, as written: `x`, or
// `x.base_type`; '' for any other expression.
fn (f &V3File) value_path(id flat.NodeId) string {
	n := f.node(id)
	if n.kind == .ident {
		return n.value_text()
	}
	if n.kind == .selector && n.value_text() != '$' {
		kids := f.kids(id)
		if kids.len == 1 {
			base := f.value_path(kids[0])
			if base != '' {
				return base + '.' + n.value_text()
			}
		}
	}
	return ''
}

// struct_init_type is the type of a struct literal written directly, `Foo{}`
// or `&Foo{}`.
fn (f &V3File) struct_init_type(id flat.NodeId) ?string {
	n := f.node(id)
	if n.kind == .struct_init && n.value_text() != '' {
		return n.value_text()
	}
	if n.kind == .prefix {
		kids := f.kids(id)
		if kids.len == 1 && f.node(kids[0]).kind == .struct_init {
			return f.node(kids[0]).value_text()
		}
	}
	return none
}

// plain_callee reports whether a call names the function it calls: `f(...)`,
// `m.f(...)`, or a generic `f[T](...)` whose every type argument is a type. A
// variable called as a function, `g := ...; g()`, or a value called by index,
// `fns['k'](...)`, is not one, since its recipe would name a function `g` or `fns`.
fn (f &V3File) plain_callee(call flat.NodeId, ctx V3CallCtx) bool {
	ks := f.kids(call)
	if ks.len == 0 {
		return false
	}
	c := f.node(ks[0])
	if c.kind == .ident {
		return c.value_text() !in ctx.vars
	}
	if c.kind == .selector {
		return true
	}
	if c.kind != .index {
		return false
	}
	ik := f.kids(ks[0])
	if ik.len < 2 || f.node(ik[0]).kind !in [.ident, .selector] {
		return false
	}
	for ta in ik[1..] {
		if (f.type_arg(ta) or { '' }) == '' {
			return false
		}
	}
	return true
}

// type_arg names a type argument of a generic call (`Config` in
// `json.decode[Config](s)`, `json.Any`) as a recipe step needs it: a primitive
// as it is, anything else qualified with its module. An index that isn't a
// type, `a[i](x)` or `[]T`, has no such name. A generic struct, `AnyStruct[json.Any]`,
// is named by its base and its type arguments.
fn (f &V3File) type_arg(id flat.NodeId) ?string {
	n := f.node(id)
	mut name := ''
	if n.kind == .ident {
		name = n.value_text()
	} else if n.kind == .selector {
		ks := f.kids(id)
		if ks.len != 1 || f.node(ks[0]).kind != .ident {
			return none
		}
		name = '${f.node(ks[0]).value_text()}.${n.value_text()}'
	} else if n.kind == .map_init || n.kind == .array_init {
		// a map or array type written out, `map[string]json.Any`, as the type itself,
		// with its module names as the file's imports give them
		t := if n.typ_text() != '' { n.typ_text() } else { n.value_text() }
		return if t == '' { none } else { f.type_text(t) }
	} else if n.kind == .index {
		// a generic struct written out, `AnyStruct[json.Any]`: its name and its type
		// arguments, each named as above
		ks := f.kids(id)
		if ks.len < 2 {
			return none
		}
		base := f.type_arg(ks[0]) or { return none }
		mut args := []string{}
		for ta in ks[1..] {
			args << f.type_arg(ta) or { return none }
		}
		return '${base}[${args.join(',')}]'
	} else {
		return none
	}
	if name == '' {
		return none
	}
	if name in primitive_types {
		return name
	}
	if !name.all_after_last('.')[0].is_capital() {
		return none
	}
	return f.recv_type(name)
}

// primitive_types are the built-in types, which have no declaration to name.
const primitive_types = ['bool', 'string', 'rune', 'byte', 'voidptr', 'charptr', 'i8', 'i16',
	'i32', 'i64', 'i128', 'u8', 'u16', 'u32', 'u64', 'u128', 'int', 'f32', 'f64', 'usize', 'isize']

// recipe says how to find the type of the expression `id` from what the file
// states, as steps that resolve_edges follows through the whole graph (see
// infer.v): a start, `t:<type>` for a type written here (in this file's
// terms, as type_text renders it) or `c:<callee>` for the return type of a
// call, named as record_call names it; then any of `m:<name>` (the return type
// of that method), `f:<name>` (that field's type), `[]` (an element), `k` (a
// map's key, or an array's index), `a` (an array of it) and `#<i>` (that value
// of a multi-value return), joined by recipe_sep. A const or global starts
// it as `g:<name>`, or `g:<module>.<name>` from another module, and is
// followed through its own recipe (Symbol.recipe). It is '' when the type
// can't be worked out this way.
fn (f &V3File) recipe(id flat.NodeId, ctx V3CallCtx) string {
	if int(id) < 0 {
		return ''
	}
	n := f.node(id)
	kids := f.kids(id)
	match n.kind {
		.string_literal, .string_interp {
			return 't:string'
		}
		.int_literal {
			return 't:int'
		}
		.float_literal {
			return 't:f64'
		}
		.bool_literal {
			return 't:bool'
		}
		.char_literal {
			return 't:rune'
		}
		.ident {
			if n.value_text() in ctx.vars {
				return ctx.vars[n.value_text()]
			}
			// not a variable in scope: a const or global of this module
			return 'g:' + n.value_text()
		}
		.paren, .or_expr {
			return if kids.len > 0 { f.recipe(kids[0], ctx) } else { '' }
		}
		.prefix {
			if kids.len == 1 {
				if n.op in [.amp, .mul, .minus, .bit_not] {
					return f.recipe(kids[0], ctx)
				}
				if n.op == .not {
					return 't:bool'
				}
				if n.op == .arrow {
					// `<-c` receives an element of the channel `c`
					r := f.recipe(kids[0], ctx)
					if r != '' {
						return r + recipe_sep + '[]'
					}
				}
			}
		}
		.in_expr, .is_expr {
			// `x in xs` and `x is T` are bools
			return 't:bool'
		}
		.typeof_expr {
			// `typeof(x)` is the name of x's type, a string
			return 't:string'
		}
		.dump_expr {
			// `dump(x)` prints x and has x's value
			if kids.len == 1 {
				return f.recipe(kids[0], ctx)
			}
		}
		.struct_init, .cast_expr, .as_expr {
			if n.value_text() != '' {
				return 't:' + f.type_text(n.value_text())
			}
		}
		.assoc {
			// `Foo{ ...x, a: 1 }`, or `{ ...x, a: 1 }` with the type of the `x` it copies
			if n.value_text() != '' {
				return 't:' + f.type_text(n.value_text())
			}
			if kids.len > 0 {
				return f.recipe(kids[0], ctx)
			}
		}
		.map_init {
			if n.value_text() != '' {
				return 't:' + f.type_text(n.value_text())
			}
			// `{ 'name': 'Joe' }` with no type written: its keys and values
			// are literals of one kind each
			if t := literal_map_type(f, kids) {
				return 't:' + t
			}
			// with a value that names no type (a variable, an empty array), the key's
			// type and the first value's that has one are the map's: V gives every entry
			// the same types
			if r := map_entries_recipe(f, kids, ctx) {
				return r
			}
		}
		.comptime_if {
			// `$if c { a } $else { b }` as a value, as vlib/builtin's max_int is: V keeps
			// one branch, so the value has the type of both when they agree, else none
			mut r := ''
			for k in kids {
				br := f.recipe(k, ctx)
				if br == '' || (r != '' && br != r) {
					return ''
				}
				r = br
			}
			return r
		}
		.block {
			// `unsafe { x }`: the value of its last expression
			return f.last_value(id, ctx)
		}
		.postfix {
			// `[a, b]!`, a fixed-size array literal, has the type of the literal
			if kids.len > 0 && f.node(kids[0]).kind == .array_literal {
				return f.recipe(kids[0], ctx)
			}
		}
		.array_init {
			t := if n.typ_text() != '' { n.typ_text() } else { n.value_text() }
			if t != '' {
				return 't:' + f.type_text(t)
			}
		}
		.sql_expr {
			// `sql db { select from T }!` has the type the ORM transform gives the block:
			// `![]T` for a select, `!int` for a write or a count, `!orm.AggregateValue`
			// for an aggregate. The parser writes it as `typ`; `!void` has no value.
			if n.typ_text().len > 1 && n.typ_text().starts_with('!') && n.typ_text() != '!void' {
				return 't:' + f.type_text(n.typ_text()[1..])
			}
		}
		.spawn_expr {
			// `spawn f(...)` is a thread of f's result, which its `wait()` gives back
			// (the `th` step of follow_steps); a callee that isn't a plain `c:` one stays
			// a bare thread
			if kids.len == 1 && f.node(kids[0]).kind == .call && f.plain_callee(kids[0], ctx) {
				steps := f.recipe(kids[0], ctx).split(recipe_sep)
				if steps[0].starts_with('c:') && steps[1..].all(it.starts_with('p:')) {
					return steps.join(recipe_sep) + recipe_sep + 'th'
				}
			}
			return 't:thread'
		}
		.array_literal {
			if kids.len > 0 {
				r := f.recipe(kids[0], ctx)
				if r != '' {
					return r + recipe_sep + 'a'
				}
			}
		}
		.index {
			if kids.len > 0 {
				r := f.recipe(kids[0], ctx)
				if r == '' {
					return r
				}
				if n.value_text() == 'range' {
					// a slice has the type of what it slices, or a fixed array's elements
					return r + recipe_sep + 'sl'
				}
				return r + recipe_sep + '[]'
			}
		}
		.selector {
			// a field a type check narrowed, `x.base_type` in `if x.base_type is Alias { ... }`
			if n.value_text() != '$' && ctx.vars.len > 0 {
				path := f.value_path(id)
				if path != '' && path in ctx.vars {
					return ctx.vars[path]
				}
			}
			if n.value_text() == '$' && kids.len == 2 {
				// `x.$(field.name)` is the field an enclosing `$if field.name == 'x'` names, of
				// x's type, or else has the type an enclosing `$if` fixes its field to
				step := f.comptime_name_step(id, ctx)
				if step != '' {
					base := f.recipe(kids[0], ctx)
					return if base == '' { '' } else { base + recipe_sep + step }
				}
				pinned := f.comptime_field_pin(id, ctx)
				if pinned != '' {
					return pinned
				}
				// otherwise it is any field of x's type that the loop reaches
				any := f.field_any_step(id, ctx)
				if any != '' {
					base := f.recipe(kids[0], ctx)
					return if base == '' { '' } else { base + recipe_sep + any }
				}
				return ''
			}
			if n.value_text() in ['len', 'cap'] {
				return 't:int'
			}
			if kids.len == 1 {
				t := f.node(kids[0])
				if t.kind == .typeof_expr {
					// the fields of `typeof(x)`: its name, index and indirections
					match n.value_text() {
						'name' { return 't:string' }
						'idx' { return 't:int' }
						'indirections' { return 't:u8' }
						else { return '' }
					}
				}
				if t.kind == .ident && t.value_text() in ['C', 'JS'] {
					return ''
				}
				if t.kind == .ident && t.value_text() in f.imports && t.value_text() !in ctx.vars {
					// another module's const or global, `os.args`
					return 'g:' + f.imports[t.value_text()] + '.' + n.value_text()
				}
				r := f.recipe(kids[0], ctx)
				if r != '' {
					return r + recipe_sep + 'f:' + n.value_text()
				}
			}
		}
		.call {
			if kids.len == 0 {
				return ''
			}
			name, is_method, target := f.callee(kids[0], ctx)
			if name == '' {
				return ''
			}
			if !is_method {
			// a call of a function value (a parameter of function type) has its return type
			if t := ctx.locals[name] {
				if t.starts_with('fn') {
					return 't:' + t + recipe_sep + 'R'
				}
			}
				mut rec := 'c:' + name
				// `f[Config](x)`: the type arguments, `p:` steps in order,
				// that follow_steps substitutes into the return type
				if f.node(kids[0]).kind == .index {
					ik := f.kids(kids[0])
					if ik.len > 1 {
						// an argument that can't be named (`&T`, `[]T`) keeps its
						// place as an empty step, so the others still line up
						for ta in ik[1..] {
							arg := f.type_arg(ta) or { '' }
							rec += recipe_sep + 'p:' + arg
						}
					}
				}
				return rec
			}
			// `x.$method()` under `$if method.return_type is T` returns a T
			if f.is_dollar_selector(kids[0]) {
				ret := f.comptime_ret_pin(kids[0], ctx)
				if ret != '' {
					return ret
				}
			}
			r := f.recipe(target, ctx)
			if r != '' {
				mut rec := r + recipe_sep + 'm:' + name
				// `x.reflect[User]()`: the type arguments, `p:` steps in order, that
				// follow_steps substitutes for the method's own type parameters
				if f.node(kids[0]).kind == .index {
					ik := f.kids(kids[0])
					if ik.len > 1 {
						for ta in ik[1..] {
							arg := f.type_arg(ta) or { '' }
							rec += recipe_sep + 'p:' + arg
						}
					}
				}
				// `xs.map(fn (x T) R { ... })`: the closure's written return type, R,
				// is the element type of the array it makes
				if name == 'map' && kids.len == 2 && f.node(kids[1]).kind == .fn_literal
					&& f.node(kids[1]).typ_text() != '' {
					rec += recipe_sep + 'mapto:' + f.type_text(f.node(kids[1]).typ_text())
				}
				// `xs.map(it.trim_left(' '))`: the result of the method called on one element
				if name == 'map' && kids.len == 2 && f.it_method(kids[1]) != '' {
					rec += recipe_sep + 'mapit:' + f.it_method(kids[1])
				}
				return rec
			}
		}
		.if_expr {
			// a branch that names no type (an interpolated string, say) is passed over: V
			// gives the expression the type its branches share, so the first branch that
			// has one gives it. A branch sees what its condition narrows, as the walk does:
			// `if x is Alias { x.base_type } else { x }`
			if kids.len >= 2 && f.node(kids[0]).kind != .decl_assign {
				r := f.last_value(kids[1], ctx.narrowed_by(f.type_checks(kids[0])))
				if r != '' {
					return r
				}
				otherwise := ctx.narrowed_by(f.false_checks(kids[0]))
				for k in kids[2..] {
					kind := f.node(k).kind
					e := if kind == .block {
						f.last_value(k, otherwise)
					} else if kind == .if_expr {
						f.recipe(k, otherwise)
					} else {
						''
					}
					if e != '' {
						return e
					}
				}
				return ''
			}
			for k in kids {
				if f.node(k).kind == .block {
					r := f.last_value(k, ctx)
					if r != '' {
						return r
					}
				}
			}
		}
		.lock_expr {
			// `rlock s { s.items[i] }` has the value of its block
			if kids.len > 0 && f.node(kids.last()).kind == .block {
				return f.last_value(kids.last(), ctx)
			}
		}
		.match_stmt {
			for k in kids {
				if f.node(k).kind == .match_branch {
					r := f.last_value(k, f.match_branch_ctx(kids[0], k, ctx))
					if r != '' {
						return r
					}
				}
			}
		}
		.infix {
			// a comparison, a logical operator, or a membership or type test (`x in xs`,
			// `x is T`) is a bool, so a method on it (`('a' in xs).str()`) has that type
			if n.op in [.eq, .ne, .lt, .gt, .le, .ge, .logical_and, .logical_or] {
				return 't:bool'
			}
			if n.op in [.plus, .minus, .mul, .div, .mod, .amp, .pipe, .xor, .left_shift, .right_shift]
				&& kids.len > 0 {
				return f.recipe(kids[0], ctx)
			}
			// `x >>> n` is the unsigned type of x, as wide as x (the `us` step, which
			// leaves an untyped literal, `int`, unnamed)
			if n.op == .right_shift_unsigned && kids.len > 0 {
				r := f.recipe(kids[0], ctx)
				if r != '' {
					return r + recipe_sep + 'us'
				}
			}
		}
		else {}
	}
	return ''
}

// it_method is the name of the method a call makes on `it`, as in `it.trim_left(' ')`, or ''
// for any other call
fn (f &V3File) it_method(id flat.NodeId) string {
	if f.node(id).kind != .call {
		return ''
	}
	ks := f.kids(id)
	if ks.len == 0 || f.node(ks[0]).kind != .selector {
		return ''
	}
	cs := f.kids(ks[0])
	if cs.len != 1 || f.node(cs[0]).kind != .ident || f.node(cs[0]).value_text() != 'it' {
		return ''
	}
	return f.node(ks[0]).value_text()
}

// match_pattern_type is the type a `match` branch's pattern names, which a subject
// of a sum type takes in that branch: a type name, a primitive (`i64`), a module's
// type (`toml.Doc`) or an array type (`[]int`). none for a value.
fn (f &V3File) match_pattern_type(pat flat.NodeId) ?string {
	n := f.node(pat)
	kids := f.kids(pat)
	match n.kind {
		.ident {
			if n.value_text() in primitive_types || (n.value_text().len > 0 && n.value_text()[0].is_capital()) {
				return n.value_text()
			}
		}
		.selector {
			if kids.len == 1 && f.node(kids[0]).kind == .ident && f.node(kids[0]).value_text() in f.imports
				&& n.value_text().len > 0 && n.value_text()[0].is_capital() {
				return '${f.node(kids[0]).value_text()}.${n.value_text()}'
			}
		}
		.array_init {
			if kids.len == 0 && n.typ_text().starts_with('[') {
				return n.typ_text()
			}
		}
		else {}
	}
	return none
}

// last_value is the recipe of the value a block or match branch ends with.
// literal_map_type is the type of a map literal written without one, when
// its keys are all one type and so are its values: `map[string]string` for
// `{ 'name': 'Joe' }`, `map[string]map[string]int` for a nested literal.
fn literal_map_type(f &V3File, kids []flat.NodeId) ?string {
	if kids.len == 0 || kids.len % 2 != 0 {
		return none
	}
	mut key := ''
	mut val := ''
	for i := 0; i < kids.len; i += 2 {
		k := f.literal_type(kids[i])
		v := f.literal_type(kids[i + 1])
		// a `.dog` shorthand (an enum_val) has the type the other entries have, which V
		// requires them to share; any other entry must state its type
		if (k == '' && f.node(kids[i]).kind != .enum_val)
			|| (v == '' && f.node(kids[i + 1]).kind != .enum_val) {
			return none
		}
		if (key != '' && k != '' && k != key) || (val != '' && v != '' && v != val) {
			return none
		}
		if k != '' {
			key = k
		}
		if v != '' {
			val = v
		}
	}
	if key == '' || val == '' {
		return none
	}
	return 'map[${key}]${val}'
}

// range_recipe is the element type of `a .. b` in a for loop: the type of the
// first bound that states one. An untyped number takes the other bound's type, so
// `u8(0) .. 255` is u8 and `0 .. n` is n's type; int when neither bound says.
fn range_recipe(f &V3File, range_id flat.NodeId, ctx V3CallCtx) string {
	for b in f.kids(range_id) {
		if f.node(b).kind == .int_literal {
			continue
		}
		r := f.recipe(b, ctx)
		if r != '' {
			return r
		}
	}
	return 't:int'
}

// map_entries_recipe is the recipe of a map literal that no entry-by-entry literal
// type gives: the type of its first key that states one, and the type of its first
// value that has a recipe or states one, the key and value of a map V types from
// its entries.
fn map_entries_recipe(f &V3File, kids []flat.NodeId, ctx V3CallCtx) ?string {
	if kids.len < 2 || kids.len % 2 != 0 {
		return none
	}
	mut key := ''
	for i := 0; i < kids.len; i += 2 {
		if k := stated_literal_type(f, kids[i]) {
			key = k
			break
		}
	}
	if key == '' {
		return none
	}
	for i := 1; i < kids.len; i += 2 {
		r := f.recipe(kids[i], ctx)
		if r != '' {
			return r + recipe_sep + 'mapof:' + key
		}
	}
	for i := 1; i < kids.len; i += 2 {
		if v := stated_literal_type(f, kids[i]) {
			return 't:' + v + recipe_sep + 'mapof:' + key
		}
	}
	return none
}

// stated_literal_type is literal_type of an entry whose text states its type, but
// not of a number: an untyped number takes the type of the entries beside it, so
// it names none.
fn stated_literal_type(f &V3File, id flat.NodeId) ?string {
	if f.node(id).kind in [.int_literal, .float_literal, .prefix] {
		return none
	}
	t := f.literal_type(id)
	if t == '' {
		return none
	}
	return t
}

// literal_type is the type of an expression whose text states it: a literal,
// a cast or a struct or map written with its type, a nested untyped literal
// map or array, a type conversion `Any(1)` or `json.Any(1)`, and a shift or
// arithmetic of one of these. '' when the text doesn't say (a variable, a
// call of a function, an enum value).
fn (f &V3File) literal_type(id flat.NodeId) string {
	if int(id) < 0 {
		return ''
	}
	n := f.node(id)
	kids := f.kids(id)
	match n.kind {
		.string_literal, .string_interp {
			return 'string'
		}
		.int_literal {
			return 'int'
		}
		.bool_literal {
			return 'bool'
		}
		.float_literal {
			return 'f64'
		}
		.char_literal {
			return 'rune'
		}
		.selector {
			// `Animal.cat`, a member of an enum, has the enum's type: the name before a
			// member is capitalized, which is a type's
			if kids.len == 1 && f.node(kids[0]).kind == .ident && f.node(kids[0]).value_text().len > 0
				&& f.node(kids[0]).value_text()[0].is_capital() && n.value_text().len > 0 && !n.value_text()[0].is_capital() {
				return f.type_text(f.node(kids[0]).value_text())
			}
		}
		.prefix {
			// `-1` and `+1.5` have the type of their number
			if kids.len == 1 && n.op in [.minus, .plus] {
				return f.literal_type(kids[0])
			}
		}
		.cast_expr, .struct_init {
			if n.value_text() != '' {
				return f.type_text(n.value_text())
			}
		}
		.map_init {
			if n.value_text() != '' {
				return f.type_text(n.value_text())
			}
			if t := literal_map_type(f, kids) {
				return t
			}
		}
		.array_literal {
			if kids.len > 0 {
				e := f.literal_type(kids[0])
				if e != '' {
					return '[]' + e
				}
			}
		}
		.call {
			// `Any(1)`, `json.Any(1)`: a capitalized callee is a type, not a function
			if kids.len > 0 {
				c := f.node(kids[0])
				if c.kind == .ident && c.value_text() != '' && (c.value_text() in primitive_types || c.value_text()[0].is_capital()) {
					return f.type_text(c.value_text())
				}
				if c.kind == .selector && c.value_text().len > 0 && c.value_text()[0].is_capital() {
					ck := f.kids(kids[0])
					if ck.len == 1 && f.node(ck[0]).kind == .ident {
						return f.type_text('${f.node(ck[0]).value_text()}.${c.value_text()}')
					}
				}
			}
		}
		.infix {
			if n.op in [.plus, .minus, .mul, .div, .mod, .amp, .pipe, .xor, .left_shift, .right_shift]
				&& kids.len > 0 {
				return f.literal_type(kids[0])
			}
		}
		.paren {
			if kids.len > 0 {
				return f.literal_type(kids[0])
			}
		}
		else {}
	}
	return ''
}

fn (f &V3File) last_value(id flat.NodeId, ctx V3CallCtx) string {
	kids := f.kids(id)
	if kids.len == 0 {
		return ''
	}
	last := f.node(kids.last())
	lk := f.kids(kids.last())
	if last.kind == .expr_stmt && lk.len > 0 {
		// the block's own `:=` names type its value, `parts := s.split('/'); parts[0]`
		mut bctx := ctx
		for k in kids[..kids.len - 1] {
			if f.node(k).kind == .decl_assign {
				bctx = f.declare(f.node(k), f.kids(k), bctx)
			}
		}
		return f.recipe(lk[0], bctx)
	}
	return ''
}

// callee names the function a call refers to: a plain `foo()`, a
// module-qualified `os.join_path()` named by the module's path (`json.decode`
// -> `x.json2.decode`), a static `Box.new()` as `Box__static__new`, or a
// method `x.foo()` as `foo`, with the receiver expression `x`.
fn (f &V3File) callee(callee_id flat.NodeId, ctx V3CallCtx) (string, bool, flat.NodeId) {
	mut cid := callee_id
	if f.node(cid).kind == .index {
		// a generic call, `f[int](x)`
		ks := f.kids(cid)
		if ks.len == 0 {
			return '', false, flat.NodeId(-1)
		}
		cid = ks[0]
	}
	c := f.node(cid)
	if c.kind == .ident {
		mut name := c.value_text().trim_left('@')
		if mod := f.selected[name] {
			name = '${mod}.${name}'
		}
		return name, false, flat.NodeId(-1)
	}
	if c.kind != .selector {
		return '', false, flat.NodeId(-1)
	}
	ks := f.kids(cid)
	if ks.len == 0 {
		return '', false, flat.NodeId(-1)
	}
	target := f.node(ks[0])
	if target.kind == .selector && c.value_text().len > 0 && target.value_text().len > 0
		&& target.value_text()[0].is_capital() {
		// a static method through its module, `flat.FlatAst.new()`
		tk := f.kids(ks[0])
		if tk.len > 0 && f.node(tk[0]).kind == .ident {
			if mod := f.imports[f.node(tk[0]).value_text()] {
				return '${mod}.${target.value_text()}__static__${c.value_text()}', false, flat.NodeId(-1)
			}
		}
	}
	if target.kind == .ident && (target.value_text() in ['C', 'JS'] || target.value_text() in f.imports)
		&& target.value_text() !in ctx.vars {
		mod := f.imports[target.value_text()] or { target.value_text() }
		return '${mod}.${c.value_text()}', false, flat.NodeId(-1)
	}
	// a function of the module the file is in, called through the module's own name
	// (`semver.from(s)` inside `module semver`): not a method on a global of that name,
	// unless a local or a variable of the same name shadows it
	if target.kind == .ident && target.value_text().len > 0 && target.value_text() == f.mod_id.all_after_last('.')
		&& target.value_text() !in ctx.vars && target.value_text() !in ctx.locals {
		return '${f.mod_id}.${c.value_text()}', false, flat.NodeId(-1)
	}
	if target.kind == .ident && target.value_text().len > 0 && target.value_text()[0].is_capital()
		&& target.value_text() !in ctx.locals {
		return '${target.value_text()}__static__${c.value_text()}', false, flat.NodeId(-1)
	}
	// a static member of a JS binding, `JS.Promise.race(p)` or `JS.Array.prototype.constructor()`,
	// is a call into the JS host as `JS.parseInt` is, so its full path is its name
	if js := f.js_path(ks[0]) {
		return '${js}.${c.value_text()}', false, flat.NodeId(-1)
	}
	return c.value_text(), true, ks[0]
}

// js_path is the dotted path of a selector chain that starts at the `JS` binding:
// `JS.Array.prototype` for the target of `JS.Array.prototype.constructor()`. none for any
// other chain.
fn (f &V3File) js_path(id flat.NodeId) ?string {
	n := f.node(id)
	if n.kind == .ident {
		if n.value_text() == 'JS' {
			return 'JS'
		}
		return none
	}
	ks := f.kids(id)
	if n.kind != .selector || ks.len == 0 {
		return none
	}
	root := f.js_path(ks[0]) or { return none }
	return '${root}.${n.value_text()}'
}

// record_call adds one `calls` edge per distinct callee in a body (see
// callee). A method call carries its receiver's type when the code writes it
// (recv_type), and otherwise the recipe for working it out (recv_recipe), so
// `a.len()` and `b.len()` on different types are separate edges.
fn (mut f V3File) record_call(callee_id flat.NodeId, args []flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) {
	name, is_method, target_id := f.callee(callee_id, ctx)
	mut rt := ''
	mut recipe := ''
	if is_method {
		target := f.node(target_id)
		if target.kind == .ident {
			if ctx.recv_name != '' && target.value_text() == ctx.recv_name {
				rt = ctx.recv_type
			} else if t := ctx.locals[target.value_text()] {
				rt = t
			}
		} else if target.kind == .struct_init && target.value_text() != '' {
			rt = f.recv_type(target.value_text())
		}
		if rt == '' {
			recipe = f.recipe(target_id, ctx)
			// a narrowed variable also carries its declared type (see narrowed)
			if target.kind == .ident && target.value_text() in ctx.fallbacks && recipe != '' {
				recipe += recipe_alt + ctx.fallbacks[target.value_text()]
			}
		}
	}
	if name == '' || name.starts_with('$') || name.starts_with('__v_') || name.starts_with('__v3_')
		|| name == '__addr' {
		// `$`, `__v_` and `__v3_` names are compile-time forms and V3's own stand-ins, and
		// `__addr` is a compiler intrinsic that V lowers: V keeps no call of any of them
		return
	}
	// `f()` where `f` is a variable or parameter calls a function value
	value_call := !is_method && name in ctx.vars
	// a method call keeps the comptime conditions it is under (see guarded), so calls
	// under different ones are different edges
	guards := if is_method { ctx.guards.join(recipe_sep) } else { '' }
	key := '${name}\x00${rt}\x00${recipe}\x00${value_call}\x00${guards}'
	// the builds that compile this call site (Edge.build)
	mut build := ''
	for c in ctx.builds {
		build = join_build(build, c)
	}
	// a non-method call keeps its argument recipes, one site at a time, since a generic
	// callee's type parameters come from every call site; a repeat call merges into the
	// edge its first call made
	site := if is_method { '' } else { f.type_arg_site(callee_id) + f.arg_site(args, ctx) }
	line := f.line_of(f.node(callee_id).pos.offset)
	if key in seen {
		add_call_site(mut edges, ctx.from, name, rt, recipe, guards, site, line, build)
		return
	}
	seen[key] = true
	edges << Edge{
		from:        ctx.from
		to:          name
		kind:        .calls
		is_method:   is_method
		recv_type:   rt
		recv_recipe: recipe
		file:        ctx.file
		provenance:  if value_call { EdgeProvenance.undeclared } else { .extracted }
		arg_sites:   if is_method { '' } else { site + arg_site_end }
		guards:      guards
		lines:       [line]
		build:       build
	}
}

// arg_site_end ends each call site's argument recipes in an edge's arg_sites.
const arg_site_end = '\x08'

// arg_site is the recipes of a call's arguments, joined by \x0b. One with no
// recipe is ''.
fn (mut f V3File) arg_site(args []flat.NodeId, ctx V3CallCtx) string {
	mut parts := []string{}
	for a in args {
		parts << f.recipe(a, ctx)
	}
	return parts.join('\x0b')
}

// type_arg_site is the explicit type arguments of a generic call, `decode_gzip[Context]()`:
// a site of its own, `ta:` and the names joined by \x0b, ended by arg_site_end, before the
// argument recipes. '' when the call names none, or none that can be named.
fn (f &V3File) type_arg_site(callee_id flat.NodeId) string {
	if f.node(callee_id).kind != .index {
		return ''
	}
	ks := f.kids(callee_id)
	if ks.len < 2 {
		return ''
	}
	mut names := []string{}
	for ta in ks[1..] {
		names << f.type_arg(ta) or { '' }
	}
	if names.all(it == '') {
		return ''
	}
	return 'ta:' + names.join('\x0b') + arg_site_end
}

// add_call_site records one more call site of a call that an edge from `from` in this
// body already records: its line, the build that compiles it, and for a non-method call
// its argument recipes.
fn add_call_site(mut edges []Edge, from string, to string, recv_type string, recipe string, guards string, site string, line int, build string) {
	for i := edges.len - 1; i >= 0 && edges[i].from == from; i-- {
		e := edges[i]
		if e.to == to && e.kind == .calls && e.recv_type == recv_type
			&& e.recv_recipe == recipe && e.guards == guards {
			edges[i] = Edge{
				...e
				arg_sites: if e.is_method { '' } else { e.arg_sites + site + arg_site_end }
				lines:     add_line(e.lines, line)
				build:     either_build(e.build, build)
			}
			return
		}
	}
}

// add_line is `lines`, in order and without repeats, with `line` in it.
fn add_line(lines []int, line int) []int {
	if line <= 0 || line in lines {
		return lines
	}
	mut out := lines.clone()
	out << line
	out.sort()
	return out
}

// merge_lines is the lines of `a` and `b`, in order and without repeats.
fn merge_lines(a []int, b []int) []int {
	mut out := a.clone()
	for l in b {
		out = add_line(out, l)
	}
	return out
}
