module graphify

import os
import v.flat
import v.parser
import v.pref

// The V3 extractor, built with `-d graphify_v3` under plain V (no
// -old-compiler). It produces the same symbols, ids and edges as the V 0.5.2
// extractor in backend_v_notd_graphify_v3.v, from V3's flat AST: one node per
// syntax element with a kind, a value, a type written as source text, byte
// offsets and children. See FUTURE_WORK.md §6 for the mapping it follows.

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
	dir := os.join_path(os.temp_dir(), 'graphify_v3_text_${os.getpid()}')
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
	mut parse_error := ''
	for d in p.diagnostics {
		// errors carry no severity text; warnings and notices say so
		if d.severity == '' || d.severity.starts_with('error') {
			parse_error = '${d.line}:${d.column}: ${d.message}'
			break
		}
	}
	// the parser emits an empty `file` node first; the real one has children
	mut root := -1
	for i, n in a.nodes {
		if n.kind == .file && n.children_count > 0 {
			root = i
		}
	}
	if root < 0 {
		return FileResult{
			parse_error: if parse_error != '' { parse_error } else { 'no file node' }
		}
	}
	mut starts := [0]
	for i, c in src {
		if c == `\n` {
			starts << i + 1
		}
	}
	mut f := V3File{
		a:           a
		src:         src
		lines:       src.split('\n')
		line_starts: starts
		rel:         rel
		real_path:   real_path
	}
	syms, edges := f.extract(flat.NodeId(root))
	return FileResult{
		symbols:     syms
		edges:       edges
		parse_error: parse_error
	}
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
					break
				}
			}
			else {}
		}
	}
	return f.line_of(offset)
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

// declares_extern reports whether `line` declares a `fn C.` or `fn JS.`
// binding.
fn (f &V3File) declares_extern(line int) bool {
	if line < 1 || line > f.lines.len {
		return false
	}
	t := f.lines[line - 1]
	return t.contains('fn C.') || t.contains('fn JS.')
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
// `[]&ast.Expr` -> `Expr`, `veb.Middleware[Context]` -> `Middleware`.
fn base_name(t string) string {
	name := strip_generic_args(anon_type(t))
	mut out := ''
	for ch in name {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`) || (ch >= `0` && ch <= `9`)
			|| ch == `_` {
			out += ch.ascii_str()
		} else {
			out = ''
		}
	}
	return out
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

fn (mut f V3File) extract(root flat.NodeId) ([]Symbol, []Edge) {
	mut syms := []Symbol{}
	mut edges := []Edge{}
	top := f.kids(root)
	mut declared := 'main'
	mut mod_line := 1
	for id in top {
		n := f.node(id)
		if n.kind == .module_decl {
			declared = n.value
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
	for id in top {
		n := f.node(id)
		if n.kind != .import_decl {
			continue
		}
		written := n.value
		path := resolve_import(written, f.real_path, f.rel)
		alias := if n.typ != '' { n.typ } else { written.all_after_last('.') }
		f.imports[alias] = path
		for k in f.kids(id) {
			sel := f.node(k)
			if sel.kind == .ident {
				f.selected[sel.value] = path
			}
		}
		syms << Symbol{
			id:        import_id(mod_id, path)
			name:      path
			kind:      .import_
			signature: 'import ${path}' + if alias != path { ' as ${alias}' } else { '' }
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
	if declared == 'main' {
		f.extract_script_main(top, mut syms, mut edges)
	}
	for id in f.top_level_decls(top) {
		n := f.node(id)
		match n.kind {
			.fn_decl, .c_fn_decl { f.extract_fn(id, mut syms, mut edges) }
			.struct_decl { f.extract_struct(id, mut syms, mut edges) }
			.enum_decl { f.extract_enum(id, mut syms, mut edges) }
			.interface_decl { f.extract_interface(id, mut syms, mut edges) }
			.const_decl { f.extract_consts(id, mut syms, mut edges) }
			.type_decl { f.extract_type(id, mut syms, mut edges) }
			else {}
		}
	}
	return syms, edges
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
		if n.kind == .fn_decl && n.value == 'main' {
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
	v := n.value
	if (v.starts_with('C.') || v.starts_with('JS.')) && v.count('.') == 1 {
		// an extern binding; a method on a C type, `C.SSL.str`, is real V
		return
	}
	if n.kind == .c_fn_decl && f.declares_extern(f.line_of(n.pos.offset)) {
		// V3 parses both `fn C.puts(...)` and a body-less V declaration
		// (`fn slopediv(num u32) int` in a .c.v file) as c_fn_decl, with the
		// `C.` dropped from the name; only the source line tells them apart
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
		recv_name = r.value
		recv_typ = f.type_text(r.typ)
		fid = '${f.mod_id}.${recv_typ.trim_left('&')}.${name}'
	}
	mut sig := if f.line_is_pub(line) { 'pub fn ' } else { 'fn ' }
	if is_method {
		sig += '(${recv_name} ${recv_typ}) '
	}
	start := if is_method { 1 } else { 0 }
	mut parts := []string{}
	for i := start; i < params.len; i++ {
		pn := f.node(params[i])
		parts << '${pn.value} ${f.type_text(pn.typ)}'
	}
	sig += '${name}(${parts.join(', ')})'
	if n.typ != '' && n.typ != 'void' {
		sig += ' ${f.type_text(n.typ)}'
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
	})
	mut rseen := map[string]bool{}
	if is_method {
		add_ref(fid, base_name(recv_typ), f.rel, mut edges, mut rseen)
	}
	for i := start; i < params.len; i++ {
		add_ref(fid, base_name(f.node(params[i]).typ), f.rel, mut edges, mut rseen)
	}
	if n.typ != '' && n.typ != 'void' {
		add_ref(fid, base_name(n.typ), f.rel, mut edges, mut rseen)
	}
	mut locals := map[string]string{}
	for i := start; i < params.len; i++ {
		pn := f.node(params[i])
		t := f.recv_type(pn.typ)
		if pn.value != '' && pn.value != '_'
			&& t.bytes().all(it.is_alnum() || it == `_` || it == `.`)
			&& !is_generic_param(t.all_after_last('.')) {
			locals[pn.value] = t
		}
	}
	ctx := V3CallCtx{
		from:      fid
		recv_name: recv_name
		recv_type: if is_method { '${f.mod_id}.${recv_typ.trim_left('&')}' } else { '' }
		file:      f.rel
		locals:    locals
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

fn (mut f V3File) extract_struct(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value)
	if short == '' {
		return
	}
	sid := '${f.mod_id}.${short}'
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
	f.add_symbol(mut syms, mut edges, Symbol{
		id:        sid
		name:      short
		kind:      .struct_
		signature: (if is_pub { 'pub ' } else { '' }) + 'struct ${short}'
		file:      f.rel
		line:      line
		end_line:  f.line_of(n.pos.end)
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
	})
	mut rseen := map[string]bool{}
	for k in f.kids(id) {
		fd := f.node(k)
		if fd.kind != .field_decl {
			continue
		}
		base := base_name(fd.typ)
		if fd.value == fd.typ && base.len > 0 && base[0].is_capital() {
			// an embedded struct: V3 lists it as a field named by its type as
			// written, `Base`, `veb.Middleware[Context]`
			edges << Edge{
				from: sid
				to:   base
				kind: .embeds
				file: f.rel
			}
			add_ref(sid, base, f.rel, mut edges, mut rseen)
			continue
		}
		fline := f.line_of(fd.pos.offset)
		tname := f.type_text(fd.typ)
		fname := fd.value.trim_left('@')
		f.add_symbol(mut syms, mut edges, Symbol{
			id:        '${sid}.${fname}'
			name:      fname
			kind:      .field
			signature: '${fname} ${tname}'
			file:      f.rel
			line:      fline
			end_line:  f.line_of(fd.pos.end)
			is_pub:    f.field_is_pub(line, fline, n.value.starts_with('C.'))
			parent:    sid
		})
		add_ref(sid, base, f.rel, mut edges, mut rseen)
	}
}

fn (mut f V3File) extract_enum(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value)
	if short == '' {
		return
	}
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
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
		signature: (if is_pub { 'pub ' } else { '' }) + 'enum ${short}'
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
	short := decl_name(n.value)
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
		signature: (if is_pub { 'pub ' } else { '' }) + 'interface ${short}'
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
		// an embedded interface is a member with no type and a capitalized
		// name; methods and fields are lower case
		base := base_name(m.value)
		if m.kind == .interface_field && m.typ == '' && base.len > 0 && base[0].is_capital() {
			edges << Edge{
				from: iid
				to:   base
				kind: .embeds
				file: f.rel
			}
			add_ref(iid, base, f.rel, mut edges, mut rseen)
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
		name := decl_name(cf.value)
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
		})
	}
}

fn (mut f V3File) extract_type(id flat.NodeId, mut syms []Symbol, mut edges []Edge) {
	n := f.node(id)
	short := decl_name(n.value)
	if short == '' {
		return
	}
	tid := '${f.mod_id}.${short}'
	line := f.line_of(n.pos.offset)
	is_pub := f.line_is_pub(line)
	mut parts := []string{}
	mut rhs := ''
	variants := f.kids(id)
	if variants.len > 0 {
		for k in variants {
			parts << f.type_text(f.node(k).value)
		}
		rhs = parts.join(' | ')
	} else {
		rhs = f.type_text(n.typ)
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
		signature: (if is_pub { 'pub ' } else { '' }) + 'type ${short} = ${rhs}'
		file:      f.rel
		line:      line
		end_line:  line
		is_pub:    is_pub
		parent:    f.mod_id
		doc:       doc_from(f.lines, line)
	})
	mut rseen := map[string]bool{}
	for t in parts {
		add_ref(tid, base_name(t), f.rel, mut edges, mut rseen)
	}
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
// declaration, its receiver, and the locals whose type is written in the code.
struct V3CallCtx {
	from      string
	recv_name string
	recv_type string
	file      string
	locals    map[string]string
}

// walk_list walks sibling nodes in order. A `:=` that names its type
// (`x := Foo{}`) types `x` for the siblings after it and nothing outside this
// list, which is ordinary lexical scoping; see track_assign in the V 0.5.2
// extractor.
fn (mut f V3File) walk_list(ids []flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) {
	mut cur := ctx
	for id in ids {
		cur = f.walk(id, cur, mut edges, mut seen)
	}
}

fn (mut f V3File) walk(id flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) V3CallCtx {
	n := f.node(id)
	kids := f.kids(id)
	if n.kind == .call && kids.len > 0 {
		f.record_call(kids[0], ctx, mut edges, mut seen)
	}
	f.walk_list(kids, ctx, mut edges, mut seen)
	if n.kind == .decl_assign && kids.len == 2 {
		left := f.node(kids[0])
		if left.kind == .ident {
			if t := f.struct_init_type(kids[1]) {
				mut locals := ctx.locals.clone()
				locals[left.value] = f.recv_type(t)
				return V3CallCtx{
					...ctx
					locals: locals
				}
			}
		}
	}
	return ctx
}

// struct_init_type is the type of a struct literal written directly, `Foo{}`
// or `&Foo{}`.
fn (f &V3File) struct_init_type(id flat.NodeId) ?string {
	n := f.node(id)
	if n.kind == .struct_init && n.value != '' {
		return n.value
	}
	if n.kind == .prefix {
		kids := f.kids(id)
		if kids.len == 1 && f.node(kids[0]).kind == .struct_init {
			return f.node(kids[0]).value
		}
	}
	return none
}

// record_call adds one `calls` edge per distinct callee name in a body: a
// plain `foo()`, a module-qualified `os.join_path()` named by the module's
// path (`json.decode` -> `x.json2.decode`), a static `Box.new()` as
// `Box__static__new`, or a method `x.foo()` with the receiver's type when it is
// written in the code.
fn (mut f V3File) record_call(callee_id flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) {
	mut cid := callee_id
	if f.node(cid).kind == .index {
		// a generic call, `f[int](x)`
		ks := f.kids(cid)
		if ks.len == 0 {
			return
		}
		cid = ks[0]
	}
	c := f.node(cid)
	mut name := ''
	mut is_method := false
	mut rt := ''
	if c.kind == .ident {
		name = c.value.trim_left('@')
		if mod := f.selected[name] {
			name = '${mod}.${name}'
		}
	} else if c.kind == .selector {
		ks := f.kids(cid)
		if ks.len == 0 {
			return
		}
		target := f.node(ks[0])
		if target.kind == .selector && c.value.len > 0 && target.value.len > 0
			&& target.value[0].is_capital() {
			// a static method through its module, `flat.FlatAst.new()`
			tk := f.kids(ks[0])
			if tk.len > 0 && f.node(tk[0]).kind == .ident {
				if mod := f.imports[f.node(tk[0]).value] {
					name = '${mod}.${target.value}__static__${c.value}'
				}
			}
		}
		if name != '' {
		} else if target.kind == .ident && (target.value in ['C', 'JS'] || target.value in f.imports) {
			mod := f.imports[target.value] or { target.value }
			name = '${mod}.${c.value}'
		} else if target.kind == .ident && target.value.len > 0 && target.value[0].is_capital()
			&& target.value !in ctx.locals {
			name = '${target.value}__static__${c.value}'
		} else {
			name = c.value
			is_method = true
			if target.kind == .ident {
				if ctx.recv_name != '' && target.value == ctx.recv_name {
					rt = ctx.recv_type
				} else if t := ctx.locals[target.value] {
					rt = t
				}
			} else if target.kind == .struct_init && target.value != '' {
				rt = f.recv_type(target.value)
			}
		}
	}
	if name == '' || name in seen || name.starts_with('$') || name.starts_with('__v_') {
		// `$` and `__v_` names are compile-time forms and V3's own stand-ins
		return
	}
	seen[name] = true
	edges << Edge{
		from:      ctx.from
		to:        name
		kind:      .calls
		is_method: is_method
		recv_type: rt
		file:      ctx.file
	}
}
