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

// type_ref names a type as an `embeds` or `references` edge records it: its
// bare name, `Base`, or with the path of the module it comes from,
// `veb.Context` -> `veb.Context`, `[]json.Any` -> `x.json2.Any`, and `Image`
// from `import sokol.gfx { Image }` -> `sokol.gfx.Image`, so that
// resolve_type_ref doesn't take a local type of the same name for it.
fn (f &V3File) type_ref(t string) string {
	base := base_name(t)
	name := strip_generic_args(anon_type(t))
	if base != '' && name.ends_with('.' + base) {
		head := name[..name.len - base.len - 1]
		mut i := head.len
		for i > 0 && (head[i - 1].is_alnum() || head[i - 1] == `_` || head[i - 1] == `.`) {
			i--
		}
		qual := head[i..]
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
	// an import inside `$if mysql ? { import db.mysql }` counts too, as every
	// branch of a `$if` does (extract_v3)
	for id in f.top_level_decls(top) {
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
	f.extract_implied_imports(declared, mut syms, mut edges)
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
			.global_decl { f.extract_globals(id, mut syms, mut edges) }
			.type_decl { f.extract_type(id, mut syms, mut edges) }
			else {}
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
				if n.value == 'embed_file.EmbedFileData' {
					found << 'v.preludes.embed_file'
					end := int_min(int(n.pos.end), f.src.len)
					if n.pos.offset < end && f.src[n.pos.offset..end].contains('.zlib') {
						found << 'v.preludes.embed_file.zlib'
					}
				} else if 'chan' in type_words(n.value) {
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
		if n.kind == .decl_assign && n.value == 'shared' {
			found << 'sync'
		}
		if n.typ != '' && n.kind != .struct_init {
			words := type_words(n.typ)
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
		recipe:    if is_method { split_type_args(recv_typ).join(',') } else { f.generic_params(line, 'fn ${name}').join(',') }
	})
	mut rseen := map[string]bool{}
	if is_method {
		add_ref(fid, f.type_ref(recv_typ), f.rel, mut edges, mut rseen)
	}
	for i := start; i < params.len; i++ {
		add_ref(fid, f.type_ref(f.node(params[i]).typ), f.rel, mut edges, mut rseen)
	}
	if n.typ != '' && n.typ != 'void' {
		add_ref(fid, f.type_ref(n.typ), f.rel, mut edges, mut rseen)
	}
	mut locals := map[string]string{}
	mut vars := map[string]string{}
	for pid in params {
		pn := f.node(pid)
		if pn.value != '' && pn.value != '_' {
			vars[pn.value] = if pn.typ != '' { 't:' + f.type_text(pn.typ) } else { '' }
		}
	}
	for i := start; i < params.len; i++ {
		pn := f.node(params[i])
		if t := f.param_type(pn) {
			locals[pn.value] = t
		}
	}
	ctx := V3CallCtx{
		from:      fid
		recv_name: recv_name
		recv_type: if is_method { '${f.mod_id}.${recv_typ.trim_left('&')}' } else { '' }
		file:      f.rel
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
		recipe:    f.generic_params(line, 'struct ${short}').join(',')
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
				to:   f.type_ref(fd.typ)
				kind: .embeds
				file: f.rel
			}
			add_ref(sid, f.type_ref(fd.typ), f.rel, mut edges, mut rseen)
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
		f.walk_initializer(.field, fname, fline, f.kids(k), mut edges)
		add_ref(sid, f.type_ref(fd.typ), f.rel, mut edges, mut rseen)
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
		if m.kind != .interface_field {
			continue
		}
		mline := f.line_of(m.pos.offset)
		if m.op == .dot {
			// a method; V3 marks it with `op`, its parameters are its children
			mut parts := []string{}
			mut mseen := map[string]bool{}
			mid := '${iid}.${m.value}'
			for pk in f.kids(k) {
				pn := f.node(pk)
				if pn.kind == .param {
					parts << '${pn.value} ${f.type_text(pn.typ)}'
					add_ref(mid, f.type_ref(pn.typ), f.rel, mut edges, mut mseen)
				}
			}
			mut sig := 'fn (${short}) ${m.value}(${parts.join(', ')})'
			if m.typ != '' && m.typ != 'void' {
				sig += ' ${f.type_text(m.typ)}'
				add_ref(mid, f.type_ref(m.typ), f.rel, mut edges, mut mseen)
			}
			f.add_symbol(mut syms, mut edges, Symbol{
				id:        mid
				name:      m.value
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
		base := base_name(m.value)
		if m.typ == '' && base.len > 0 && base[0].is_capital() {
			edges << Edge{
				from: iid
				to:   f.type_ref(m.value)
				kind: .embeds
				file: f.rel
			}
			add_ref(iid, f.type_ref(m.value), f.rel, mut edges, mut rseen)
			continue
		}
		if m.typ != '' {
			f.add_symbol(mut syms, mut edges, Symbol{
				id:        '${iid}.${m.value}'
				name:      m.value
				kind:      .field
				signature: '${m.value} ${f.type_text(m.typ)}'
				file:      f.rel
				line:      mline
				end_line:  mline
				is_pub:    is_pub
				parent:    iid
			})
			add_ref(iid, f.type_ref(m.typ), f.rel, mut edges, mut rseen)
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
		if g.kind != .field_decl || g.value == '' {
			continue
		}
		value := f.kids(k)
		typ := if g.typ != '' { f.type_text(g.typ) } else { '' }
		line := f.line_of(g.pos.offset)
		f.add_symbol(mut syms, mut edges, Symbol{
			id:        '${f.mod_id}.${g.value}'
			name:      g.value
			kind:      .global
			signature: '__global ${g.value}' + if typ != '' { ' ${typ}' } else { '' }
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
		f.walk_initializer(.global, g.value, line, value, mut edges)
		if typ != '' {
			mut rseen := map[string]bool{}
			add_ref('${f.mod_id}.${g.value}', f.type_ref(g.typ), f.rel, mut edges, mut rseen)
		}
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
		add_ref(tid, f.type_ref(t), f.rel, mut edges, mut rseen)
	}
}

// param_type is the type id of a parameter whose type is a plain name, for
// V3CallCtx.locals.
fn (f &V3File) param_type(pn &flat.Node) ?string {
	// a function value keeps its written type, whose return type a call of it has
	if pn.value != '' && pn.value != '_' && pn.typ.starts_with('fn') {
		return pn.typ
	}
	t := f.recv_type(pn.typ)
	if pn.value != '' && pn.value != '_' && t.bytes().all(it.is_alnum() || it == `_` || it == `.`)
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
mut:
	locals map[string]string
	vars   map[string]string
	// fallbacks is the declared type of each variable narrowed by a type
	// check (see narrowed), where its narrowed type lacks a method
	fallbacks map[string]string
}

// TypeCheck is a variable narrowed to a type by `name is typ`, as written.
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
	}
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
				f.record_call(kids[0], ctx, mut edges, mut seen)
				callee := f.node(kids[0])
				ck := f.kids(kids[0])
				if callee.kind == .selector && ck.len > 0
					&& (callee.value in methods_with_it || callee.value in ['sort', 'sorted']) {
					// `xs.filter(it.ok())`: `it` is one element of `xs`, and so
					// are `a` and `b` in `xs.sort(a.x < b.x)`
					r := f.recipe(ck[0], ctx)
					f.walk(kids[0], ctx, mut edges, mut seen)
					elem := if r == '' { '' } else { r + recipe_sep + '[]' }
					it_ctx := if callee.value in methods_with_it {
						ctx.with_vars(['it'], [elem])
					} else {
						ctx.with_vars(['a', 'b'], [elem, elem])
					}
					f.walk_list(kids[1..], it_ctx, mut edges, mut seen)
					return ctx
				}
			}
		}
		.comptime_for {
			// `$for field in T.fields`: each field is a builtin FieldData
			parts := n.value.split('|')
			if parts.len == 2 && parts[1] == 'fields' {
				f.walk_list(kids, ctx.with_vars([parts[0]], ['t:builtin.FieldData']), mut edges, mut seen)
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
					names << f.node(kids[0]).value
					recipes << 't:int'
				} else if int(kids[1]) < 0 {
					names << f.node(kids[0]).value
					recipes << if r == '' { '' } else { r + recipe_sep + '[]' }
				} else {
					names << f.node(kids[0]).value
					recipes << if r == '' { '' } else { r + recipe_sep + 'k' }
					names << f.node(kids[1]).value
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
			// branches keep the type it had
			if kids.len >= 2 {
				f.walk(kids[0], ctx, mut edges, mut seen)
				f.walk(kids[1], ctx.narrowed_by(f.type_checks(kids[0])), mut edges, mut seen)
				f.walk_list(kids[2..], ctx, mut edges, mut seen)
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
		}
		.match_stmt {
			// `match x { T { ... } }`: `x` is a T in a branch with one type
			// pattern; a branch of values or `else` keeps its type
			if kids.len >= 1 {
				subject := f.node(kids[0])
				f.walk(kids[0], ctx, mut edges, mut seen)
				for k in kids[1..] {
					branch := f.kids(k)
					mut body := ctx
					if subject.kind == .ident && f.node(k).value == '1' && branch.len >= 2 {
						pat := f.node(branch[0])
						if pat.kind == .ident && pat.value.len > 0 && pat.value[0].is_capital() {
							body = ctx.narrowed(subject.value, 't:' + f.type_text(pat.value))
						}
					}
					f.walk_list(branch, body, mut edges, mut seen)
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
				if p.kind == .param && p.value != '' {
					names << p.value
					recipes << if p.typ != '' { 't:' + f.type_text(p.typ) } else { '' }
				}
			}
			mut inner := ctx.with_vars(names, recipes)
			for k in kids {
				p := f.node(k)
				if p.kind == .param {
					if t := f.param_type(p) {
						inner.locals[p.value] = t
					}
				}
			}
			f.walk_list(kids, inner, mut edges, mut seen)
			return ctx
		}
		else {}
	}
	f.walk_list(kids, ctx, mut edges, mut seen)
	if n.kind == .decl_assign {
		return f.declare(n, kids, ctx)
	}
	return ctx
}

// declare returns `ctx` with the variables a `:=` declares. `a := x` has the
// children [a, x], `a, b := x, y` [a, x, b, y], and `a, b := f()` [a, f(), b].
fn (f &V3File) declare(n &flat.Node, kids []flat.NodeId, ctx V3CallCtx) V3CallCtx {
	count := if n.value == '' { 1 } else { n.value.int() }
	mut names := []string{}
	mut recipes := []string{}
	if kids.len == 2 * count {
		for i := 0; i < kids.len; i += 2 {
			names << f.node(kids[i]).value
			recipes << f.recipe(kids[i + 1], ctx)
		}
	} else if count > 1 && kids.len == count + 1 {
		r := f.recipe(kids[1], ctx)
		mut lhs := [kids[0]]
		lhs << kids[2..]
		for i, k in lhs {
			names << f.node(k).value
			recipes << if r == '' { '' } else { r + recipe_sep + '#${i}' }
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

// type_checks are the `x is T` checks that hold where `cond` is true: the
// check itself, or the checks on both sides of an `&&`.
fn (f &V3File) type_checks(cond flat.NodeId) []TypeCheck {
	if int(cond) < 0 {
		return []TypeCheck{}
	}
	n := f.node(cond)
	kids := f.kids(cond)
	if n.kind == .is_expr && kids.len == 1 && n.value != '' && n.op != .not {
		if f.node(kids[0]).kind == .ident {
			return [TypeCheck{
				name: f.node(kids[0]).value
				typ:  n.value
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

// type_arg names a type argument of a generic call (`Config` in
// `json.decode[Config](s)`, `json.Any`) as a recipe step needs it: a primitive
// as it is, anything else qualified with its module. An index that isn't a
// type, `a[i](x)` or `[]T`, has no such name.
fn (f &V3File) type_arg(id flat.NodeId) ?string {
	n := f.node(id)
	mut name := ''
	if n.kind == .ident {
		name = n.value
	} else if n.kind == .selector {
		ks := f.kids(id)
		if ks.len != 1 || f.node(ks[0]).kind != .ident {
			return none
		}
		name = '${f.node(ks[0]).value}.${n.value}'
	} else if n.kind == .map_init || n.kind == .array_init {
		// a map or array type written out, `map[string]json.Any`, as the type itself
		t := if n.typ != '' { n.typ } else { n.value }
		return if t == '' { none } else { t }
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
			if n.value in ctx.vars {
				return ctx.vars[n.value]
			}
			// not a variable in scope: a const or global of this module
			return 'g:' + n.value
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
			}
		}
		.struct_init, .cast_expr, .as_expr {
			if n.value != '' {
				return 't:' + f.type_text(n.value)
			}
		}
		.map_init {
			if n.value != '' {
				return 't:' + f.type_text(n.value)
			}
			// `{ 'name': 'Joe' }` with no type written: its keys and values
			// are literals of one kind each
			if t := literal_map_type(f, kids) {
				return 't:' + t
			}
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
			t := if n.typ != '' { n.typ } else { n.value }
			if t != '' {
				return 't:' + f.type_text(t)
			}
		}
		.spawn_expr {
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
				if r == '' || n.value == 'range' {
					// a slice has the type of what it slices
					return r
				}
				return r + recipe_sep + '[]'
			}
		}
		.selector {
			if n.value in ['len', 'cap'] {
				return 't:int'
			}
			if kids.len == 1 {
				t := f.node(kids[0])
				if t.kind == .ident && t.value in ['C', 'JS'] {
					return ''
				}
				if t.kind == .ident && t.value in f.imports && t.value !in ctx.vars {
					// another module's const or global, `os.args`
					return 'g:' + f.imports[t.value] + '.' + n.value
				}
				r := f.recipe(kids[0], ctx)
				if r != '' {
					return r + recipe_sep + 'f:' + n.value
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
			r := f.recipe(target, ctx)
			if r != '' {
				return r + recipe_sep + 'm:' + name
			}
		}
		.if_expr {
			for k in kids {
				if f.node(k).kind == .block {
					return f.last_value(k, ctx)
				}
			}
		}
		.match_stmt {
			for k in kids {
				if f.node(k).kind == .match_branch {
					return f.last_value(k, ctx)
				}
			}
		}
		.infix {
			if n.op in [.eq, .ne, .lt, .gt, .le, .ge, .logical_and, .logical_or] {
				return 't:bool'
			}
			if n.op in [.plus, .minus, .mul, .div, .mod, .amp, .pipe, .left_shift, .right_shift]
				&& kids.len > 0 {
				return f.recipe(kids[0], ctx)
			}
		}
		else {}
	}
	return ''
}

// last_value is the recipe of the value a block or match branch ends with.
// literal_map_type is the type of a map literal written without one, when
// its keys are all one kind of literal and so are its values: `map[string]string`
// for `{ 'name': 'Joe' }`.
fn literal_map_type(f &V3File, kids []flat.NodeId) ?string {
	if kids.len == 0 || kids.len % 2 != 0 {
		return none
	}
	mut key := ''
	mut val := ''
	for i := 0; i < kids.len; i += 2 {
		k := literal_type_name(f.node(kids[i]).kind)
		v := literal_type_name(f.node(kids[i + 1]).kind)
		if k == '' || v == '' || (key != '' && k != key) || (val != '' && v != val) {
			return none
		}
		key = k
		val = v
	}
	return 'map[${key}]${val}'
}

// literal_type_name is the type of a literal expression of this kind, or ''.
fn literal_type_name(k flat.NodeKind) string {
	return match k {
		.string_literal, .string_interp { 'string' }
		.int_literal { 'int' }
		.bool_literal { 'bool' }
		.float_literal { 'f64' }
		else { '' }
	}
}

fn (f &V3File) last_value(id flat.NodeId, ctx V3CallCtx) string {
	kids := f.kids(id)
	if kids.len == 0 {
		return ''
	}
	last := f.node(kids.last())
	lk := f.kids(kids.last())
	if last.kind == .expr_stmt && lk.len > 0 {
		return f.recipe(lk[0], ctx)
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
		mut name := c.value.trim_left('@')
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
	if target.kind == .selector && c.value.len > 0 && target.value.len > 0
		&& target.value[0].is_capital() {
		// a static method through its module, `flat.FlatAst.new()`
		tk := f.kids(ks[0])
		if tk.len > 0 && f.node(tk[0]).kind == .ident {
			if mod := f.imports[f.node(tk[0]).value] {
				return '${mod}.${target.value}__static__${c.value}', false, flat.NodeId(-1)
			}
		}
	}
	if target.kind == .ident && (target.value in ['C', 'JS'] || target.value in f.imports)
		&& target.value !in ctx.vars {
		mod := f.imports[target.value] or { target.value }
		return '${mod}.${c.value}', false, flat.NodeId(-1)
	}
	if target.kind == .ident && target.value.len > 0 && target.value[0].is_capital()
		&& target.value !in ctx.locals {
		return '${target.value}__static__${c.value}', false, flat.NodeId(-1)
	}
	return c.value, true, ks[0]
}

// record_call adds one `calls` edge per distinct callee in a body (see
// callee). A method call carries its receiver's type when the code writes it
// (recv_type), and otherwise the recipe for working it out (recv_recipe), so
// `a.len()` and `b.len()` on different types are separate edges.
fn (mut f V3File) record_call(callee_id flat.NodeId, ctx V3CallCtx, mut edges []Edge, mut seen map[string]bool) {
	name, is_method, target_id := f.callee(callee_id, ctx)
	mut rt := ''
	mut recipe := ''
	if is_method {
		target := f.node(target_id)
		if target.kind == .ident {
			if ctx.recv_name != '' && target.value == ctx.recv_name {
				rt = ctx.recv_type
			} else if t := ctx.locals[target.value] {
				rt = t
			}
		} else if target.kind == .struct_init && target.value != '' {
			rt = f.recv_type(target.value)
		}
		if rt == '' {
			recipe = f.recipe(target_id, ctx)
			// a narrowed variable also carries its declared type (see narrowed)
			if target.kind == .ident && target.value in ctx.fallbacks && recipe != '' {
				recipe += recipe_alt + ctx.fallbacks[target.value]
			}
		}
	}
	if name == '' || name.starts_with('$') || name.starts_with('__v_') {
		// `$` and `__v_` names are compile-time forms and V3's own stand-ins
		return
	}
	// `f()` where `f` is a variable or parameter calls a function value
	value_call := !is_method && name in ctx.vars
	key := '${name}\x00${rt}\x00${recipe}\x00${value_call}'
	if key in seen {
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
	}
}
