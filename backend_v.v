module graphify

import os
import v.ast
import v.parser
import v.pref
import v.token

// extract_v_file parses one .v file with V's own frontend and returns the
// symbols and edges found in it. `rel` is the path stored on each symbol
// (typically the path relative to the graph root).
//
// NOTE: a fresh ast.Table is created per file, so call edges are recorded as
// raw callee names and resolved later (see resolve_edges). Sharing one table
// across a whole project — for accurate cross-file resolution — is the next
// step.
pub fn extract_v_file(path string, rel string) ([]Symbol, []Edge) {
	mut table := ast.new_table()
	pref_ := pref.new_preferences()
	file := parser.parse_file(path, mut table, .skip_comments, pref_)
	src := os.read_file(path) or { '' }
	return extract_from_ast(file, mut table, rel, src.split('\n'))
}

// extract_v_text is the same as extract_v_file but takes source directly,
// which makes it convenient for tests.
pub fn extract_v_text(source string, rel string) ([]Symbol, []Edge) {
	mut table := ast.new_table()
	pref_ := pref.new_preferences()
	file := parser.parse_text(source, rel, mut table, .skip_comments, pref_)
	return extract_from_ast(file, mut table, rel, source.split('\n'))
}

fn extract_from_ast(file &ast.File, mut table ast.Table, rel string, src []string) ([]Symbol, []Edge) {
	mut syms := []Symbol{}
	mut edges := []Edge{}

	mod := file.mod.name
	mod_id := if mod == '' { 'main' } else { mod }

	// module node
	syms << Symbol{
		id:        mod_id
		name:      mod_id
		kind:      .mod_
		signature: 'module ${mod_id}'
		file:      rel
		line:      file.mod.pos.line_nr + 1
	}

	// imports
	for imp in file.imports {
		syms << Symbol{
			id:        '${mod_id}::import::${imp.mod}'
			name:      imp.mod
			kind:      .import_
			signature: 'import ${imp.mod}' + if imp.alias != imp.mod && imp.alias != '' {
				' as ${imp.alias}'
			} else {
				''
			}
			file:      rel
			line:      imp.pos.line_nr + 1
			parent:    mod_id
		}
		edges << Edge{
			from: mod_id
			to:   imp.mod
			kind: .imports
		}
	}

	// top-level declarations
	for stmt in file.stmts {
		match stmt {
			ast.FnDecl {
				id := fn_id(mod_id, stmt, mut table)
				syms << Symbol{
					id:        id
					name:      if stmt.short_name != '' { stmt.short_name } else { stmt.name }
					kind:      if stmt.is_method { SymbolKind.method } else { SymbolKind.function }
					signature: fn_signature(stmt, mut table, mod_id)
					file:      rel
					line:      stmt.name_pos.line_nr + 1
					end_line:  end_of(stmt.body_pos)
					is_pub:    stmt.is_pub
					parent:    mod_id
					doc:       doc_from(src, stmt.name_pos.line_nr + 1)
				}
				edges << Edge{
					from: mod_id
					to:   id
					kind: .defines
				}
				// type references: receiver, params, return
				mut rseen := map[string]bool{}
				if stmt.is_method {
					add_ref(id, base_type_name(table, stmt.receiver.typ, mod_id), mut edges, mut
						rseen)
				}
				pstart := if stmt.is_method { 1 } else { 0 }
				for i := pstart; i < stmt.params.len; i++ {
					add_ref(id, base_type_name(table, stmt.params[i].typ, mod_id), mut edges, mut
						rseen)
				}
				if stmt.return_type != ast.void_type && stmt.return_type != 0 {
					add_ref(id, base_type_name(table, stmt.return_type, mod_id), mut edges, mut
						rseen)
				}
				collect_calls(stmt.stmts, CallCtx{
					from:      id
					recv_name: if stmt.is_method { stmt.receiver.name } else { '' }
					recv_type: if stmt.is_method {
						'${mod_id}.' + clean_type(table, stmt.receiver.typ, mod_id).trim_left('&')
					} else {
						''
					}
					table:  table
					mod_id: mod_id
				}, mut edges)
			}
			ast.StructDecl {
				short := stmt.name.all_after_last('.')
				id := '${mod_id}.${short}'
				syms << Symbol{
					id:        id
					name:      short
					kind:      .struct_
					signature: (if stmt.is_pub { 'pub ' } else { '' }) + 'struct ${short}'
					file:      rel
					line:      stmt.pos.line_nr + 1
					end_line:  end_of(stmt.pos)
					is_pub:    stmt.is_pub
					parent:    mod_id
					doc:       doc_from(src, stmt.pos.line_nr + 1)
				}
				edges << Edge{
					from: mod_id
					to:   id
					kind: .defines
				}
				// fields as symbols, plus type-reference and embed edges
				mut rseen := map[string]bool{}
				for f in stmt.fields {
					tname := clean_type(table, f.typ, mod_id)
					syms << Symbol{
						id:        '${id}.${f.name}'
						name:      f.name
						kind:      .field
						signature: '${f.name} ${tname}'
						file:      rel
						line:      f.pos.line_nr + 1
						end_line:  end_of(f.pos)
						is_pub:    f.is_pub
						parent:    id
					}
					edges << Edge{
						from: id
						to:   '${id}.${f.name}'
						kind: .defines
					}
					base := base_type_name(table, f.typ, mod_id)
					if f.is_embed {
						edges << Edge{
							from: id
							to:   base
							kind: .embeds
						}
					}
					add_ref(id, base, mut edges, mut rseen)
				}
			}
			ast.EnumDecl {
				short := stmt.name.all_after_last('.')
				id := '${mod_id}.${short}'
				syms << Symbol{
					id:        id
					name:      short
					kind:      .enum_
					signature: (if stmt.is_pub { 'pub ' } else { '' }) + 'enum ${short}'
					file:      rel
					line:      stmt.pos.line_nr + 1
					end_line:  end_of(stmt.pos)
					is_pub:    stmt.is_pub
					parent:    mod_id
					doc:       doc_from(src, stmt.pos.line_nr + 1)
				}
				edges << Edge{
					from: mod_id
					to:   id
					kind: .defines
				}
			}
			ast.InterfaceDecl {
				short := stmt.name.all_after_last('.')
				id := '${mod_id}.${short}'
				syms << Symbol{
					id:        id
					name:      short
					kind:      .interface_
					signature: (if stmt.is_pub { 'pub ' } else { '' }) + 'interface ${short}'
					file:      rel
					line:      stmt.pos.line_nr + 1
					end_line:  end_of(stmt.pos)
					is_pub:    stmt.is_pub
					parent:    mod_id
					doc:       doc_from(src, stmt.pos.line_nr + 1)
				}
				edges << Edge{
					from: mod_id
					to:   id
					kind: .defines
				}
			}
			ast.ConstDecl {
				for cf in stmt.fields {
					id := '${mod_id}.${cf.name}'
					syms << Symbol{
						id:        id
						name:      cf.name.all_after_last('.')
						kind:      .constant
						signature: (if stmt.is_pub { 'pub ' } else { '' }) +
							'const ${cf.name.all_after_last('.')}'
						file:      rel
						line:      cf.pos.line_nr + 1
						end_line:  end_of(cf.pos)
						is_pub:    stmt.is_pub
						parent:    mod_id
						doc:       doc_from(src, stmt.pos.line_nr + 1)
					}
					edges << Edge{
						from: mod_id
						to:   id
						kind: .defines
					}
				}
			}
			else {}
		}
	}

	return syms, edges
}

// fn_id builds a stable id for a function or method.
fn fn_id(mod_id string, fd ast.FnDecl, mut table ast.Table) string {
	if fd.is_method {
		recv := clean_type(table, fd.receiver.typ, mod_id).trim_left('&')
		return '${mod_id}.${recv}.${fd.short_name}'
	}
	short := if fd.short_name != '' { fd.short_name } else { fd.name }
	return '${mod_id}.${short}'
}

// fn_signature renders a body-less signature: the token-lean essence.
fn fn_signature(fd ast.FnDecl, mut table ast.Table, mod_id string) string {
	mut s := ''
	if fd.is_pub {
		s += 'pub '
	}
	s += 'fn '
	if fd.is_method {
		s += '(${fd.receiver.name} ${clean_type(table, fd.receiver.typ, mod_id)}) '
	}
	s += if fd.short_name != '' { fd.short_name } else { fd.name }
	s += '('
	start := if fd.is_method { 1 } else { 0 } // params[0] is the receiver for methods
	mut parts := []string{}
	for i := start; i < fd.params.len; i++ {
		p := fd.params[i]
		parts << '${p.name} ${clean_type(table, p.typ, mod_id)}'
	}
	s += parts.join(', ')
	s += ')'
	if fd.return_type != ast.void_type && fd.return_type != 0 {
		s += ' ${clean_type(table, fd.return_type, mod_id)}'
	}
	return s
}

// clean_type renders a type name, dropping the current module's prefix so the
// skeleton reads like the original source (`User`, not `demo.User`).
fn clean_type(table &ast.Table, typ ast.Type, mod_id string) string {
	// drop the current module's prefix wherever it appears, so `&graphify.Graph`
	// and `[]graphify.Symbol` read as `&Graph` and `[]Symbol`.
	return table.type_to_str(typ).replace('${mod_id}.', '')
}

// doc_from collects the `//` block directly above `line` (1-based) from the
// source text. It stops at a blank line or anything that is not a comment, so a
// licence header, a section banner, or a note about the code *above* never gets
// attached to the declaration below it.
//
// Read from source rather than from the AST on purpose: in `.toplevel_comments`
// mode V surfaces only the *first* line of a contiguous block as a top-level
// node, which silently truncated every multi-line doc to one line. Reading the
// block directly is exact, and lets the parse stay in the cheaper
// `.skip_comments` mode.
fn doc_from(src []string, line int) string {
	mut out := []string{}
	mut i := line - 2 // 0-based index of the line above the declaration
	for i >= 0 && i < src.len {
		t := src[i].trim_space()
		if t.starts_with('@[') {
			i-- // attributes sit between the doc and the declaration
			continue
		}
		if !t.starts_with('//') {
			break
		}
		out.prepend(t.trim_string_left('//').trim_space())
		i--
	}
	return out.join('\n').trim_space()
}

// end_of returns the 1-based end line of an ast node from its position's
// last_line (set by the parser), falling back to the start line.
fn end_of(pos token.Pos) int {
	return if pos.last_line > pos.line_nr { pos.last_line + 1 } else { pos.line_nr + 1 }
}

// base_type_name reduces a (possibly decorated) type like `&User`, `[]User`, or
// `map[string]User` to its trailing identifier (`User`), so it can be matched to
// a declared type symbol. Builtins/externals simply won't resolve and are dropped.
fn base_type_name(table &ast.Table, typ ast.Type, mod_id string) string {
	name := clean_type(table, typ, mod_id)
	mut out := ''
	for ch in name {
		if (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `0` && ch <= `9`) || ch == `_` {
			out += ch.ascii_str()
		} else {
			out = '' // reset on a separator, keeping only the final identifier run
		}
	}
	return out
}

// add_ref records a `references` edge to a type name, deduped per declaration.
fn add_ref(from string, typename string, mut edges []Edge, mut seen map[string]bool) {
	if typename == '' || typename in seen {
		return
	}
	seen[typename] = true
	edges << Edge{
		from: from
		to:   typename
		kind: .references
	}
}

// CallCtx is what the call walkers need to know about the function being
// walked: who is calling, and -- when it is a method -- the name and type of
// its own receiver, so `t.foo()` can be attributed without type inference.
// table/mod_id serve the same purpose for a literal receiver (`Foo{}.bar()`):
// the type is on the literal itself, also with no inference needed, but
// reading it needs the table (see walk_call).
struct CallCtx {
	from      string
	recv_name string // receiver variable, '' when the caller is not a method
	recv_type string // id of the receiver's type, e.g. `v3.transform.Transformer`
	table     &ast.Table = unsafe { nil }
	mod_id    string
}

// collect_calls records one `calls` edge per *distinct* callee invoked anywhere
// in a function body. It walks the full statement/expression tree — if/match/for
// bodies, or-blocks, call args, index/infix/selector chains, string
// interpolation, array/map/struct initializers, and nested closures — so the
// call graph has high recall. Callees are recorded by raw name, resolved later.
fn collect_calls(stmts []ast.Stmt, ctx CallCtx, mut edges []Edge) {
	mut seen := map[string]bool{}
	walk_stmts(stmts, ctx, mut edges, mut seen)
}

fn walk_stmts(stmts []ast.Stmt, ctx CallCtx, mut edges []Edge, mut seen map[string]bool) {
	for stmt in stmts {
		walk_stmt(stmt, ctx, mut edges, mut seen)
	}
}

fn walk_stmt(stmt ast.Stmt, ctx CallCtx, mut edges []Edge, mut seen map[string]bool) {
	match stmt {
		ast.ExprStmt {
			walk_expr(stmt.expr, ctx, mut edges, mut seen)
		}
		ast.Return {
			for e in stmt.exprs {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.AssignStmt {
			for e in stmt.left {
				walk_expr(e, ctx, mut edges, mut seen)
			}
			for e in stmt.right {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.AssertStmt {
			walk_expr(stmt.expr, ctx, mut edges, mut seen)
			walk_expr(stmt.extra, ctx, mut edges, mut seen)
		}
		ast.ForStmt {
			walk_expr(stmt.cond, ctx, mut edges, mut seen)
			walk_stmts(stmt.stmts, ctx, mut edges, mut seen)
		}
		ast.ForInStmt {
			walk_expr(stmt.cond, ctx, mut edges, mut seen)
			walk_expr(stmt.high, ctx, mut edges, mut seen)
			walk_stmts(stmt.stmts, ctx, mut edges, mut seen)
		}
		ast.ForCStmt {
			walk_stmt(stmt.init, ctx, mut edges, mut seen)
			walk_expr(stmt.cond, ctx, mut edges, mut seen)
			walk_stmt(stmt.inc, ctx, mut edges, mut seen)
			walk_stmts(stmt.stmts, ctx, mut edges, mut seen)
		}
		ast.Block {
			walk_stmts(stmt.stmts, ctx, mut edges, mut seen)
		}
		ast.DeferStmt {
			walk_stmts(stmt.stmts, ctx, mut edges, mut seen)
		}
		else {}
	}
}

fn walk_call(ce ast.CallExpr, ctx CallCtx, mut edges []Edge, mut seen map[string]bool) {
	if ce.name != '' && ce.name !in seen {
		seen[ce.name] = true
		// `t.foo()` inside `fn (t &Transformer) ...` needs no inference: the
		// receiver's type is written on the enclosing declaration. A literal
		// receiver (`Foo{}.bar()`) needs no inference either — the type is
		// the literal's own — but StructInit.typ_str cannot be trusted for
		// it: the parser always prefixes it with the *current* module rather
		// than whatever module was actually written, so `other.Bar{}` inside
		// `demo` reports itself as `demo.Bar` (confirmed empirically, not
		// from the field's doc comment). `.typ`, resolved through the table,
		// does not have that bug. Any other receiver shape is left blank
		// rather than guessed at.
		mut rt := ''
		if ce.is_method {
			left := ce.left
			if left is ast.Ident && ctx.recv_name != '' && left.name == ctx.recv_name {
				rt = ctx.recv_type
			} else if left is ast.StructInit && left.typ != ast.void_type && left.typ != 0 {
				resolved := clean_type(ctx.table, left.typ, ctx.mod_id).trim_left('&')
				rt = if resolved.contains('.') { resolved } else { '${ctx.mod_id}.${resolved}' }
			}
		}
		edges << Edge{
			from:      ctx.from
			to:        ce.name
			kind:      .calls
			is_method: ce.is_method
			recv_type: rt
		}
	}
	walk_expr(ce.left, ctx, mut edges, mut seen)
	for arg in ce.args {
		walk_expr(arg.expr, ctx, mut edges, mut seen)
	}
	walk_stmts(ce.or_block.stmts, ctx, mut edges, mut seen)
}

fn walk_expr(expr ast.Expr, ctx CallCtx, mut edges []Edge, mut seen map[string]bool) {
	match expr {
		ast.CallExpr {
			walk_call(expr, ctx, mut edges, mut seen)
		}
		ast.InfixExpr {
			walk_expr(expr.left, ctx, mut edges, mut seen)
			walk_expr(expr.right, ctx, mut edges, mut seen)
			walk_stmts(expr.or_block.stmts, ctx, mut edges, mut seen)
		}
		ast.PrefixExpr {
			walk_expr(expr.right, ctx, mut edges, mut seen)
			walk_stmts(expr.or_block.stmts, ctx, mut edges, mut seen)
		}
		ast.PostfixExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.ParExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.SelectorExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
			walk_stmts(expr.or_block.stmts, ctx, mut edges, mut seen)
		}
		ast.IndexExpr {
			walk_expr(expr.left, ctx, mut edges, mut seen)
			walk_expr(expr.index, ctx, mut edges, mut seen)
			walk_stmts(expr.or_expr.stmts, ctx, mut edges, mut seen)
		}
		ast.RangeExpr {
			walk_expr(expr.low, ctx, mut edges, mut seen)
			walk_expr(expr.high, ctx, mut edges, mut seen)
		}
		ast.CastExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
			walk_expr(expr.arg, ctx, mut edges, mut seen)
		}
		ast.AsCast {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.ConcatExpr {
			for e in expr.vals {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.ArrayInit {
			for e in expr.exprs {
				walk_expr(e, ctx, mut edges, mut seen)
			}
			walk_expr(expr.len_expr, ctx, mut edges, mut seen)
			walk_expr(expr.cap_expr, ctx, mut edges, mut seen)
			walk_expr(expr.init_expr, ctx, mut edges, mut seen)
		}
		ast.ArrayDecompose {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.MapInit {
			for e in expr.keys {
				walk_expr(e, ctx, mut edges, mut seen)
			}
			for e in expr.vals {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.StructInit {
			for f in expr.init_fields {
				walk_expr(f.expr, ctx, mut edges, mut seen)
			}
			if expr.has_update_expr {
				walk_expr(expr.update_expr, ctx, mut edges, mut seen)
			}
		}
		ast.StringInterLiteral {
			for e in expr.exprs {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.IfExpr {
			walk_expr(expr.left, ctx, mut edges, mut seen)
			for b in expr.branches {
				walk_expr(b.cond, ctx, mut edges, mut seen)
				walk_stmts(b.stmts, ctx, mut edges, mut seen)
			}
		}
		ast.IfGuardExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.MatchExpr {
			walk_expr(expr.cond, ctx, mut edges, mut seen)
			for b in expr.branches {
				for e in b.exprs {
					walk_expr(e, ctx, mut edges, mut seen)
				}
				walk_stmts(b.stmts, ctx, mut edges, mut seen)
			}
		}
		ast.OrExpr {
			walk_stmts(expr.stmts, ctx, mut edges, mut seen)
		}
		ast.UnsafeExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.LockExpr {
			walk_stmts(expr.stmts, ctx, mut edges, mut seen)
			for e in expr.lockeds {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		ast.GoExpr {
			walk_call(expr.call_expr, ctx, mut edges, mut seen)
		}
		ast.SpawnExpr {
			walk_call(expr.call_expr, ctx, mut edges, mut seen)
		}
		ast.AnonFn {
			walk_stmts(expr.decl.stmts, ctx, mut edges, mut seen)
		}
		ast.LambdaExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.Likely {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.DumpExpr {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.SizeOf {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.IsRefType {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.TypeOf {
			walk_expr(expr.expr, ctx, mut edges, mut seen)
		}
		ast.Assoc {
			for e in expr.exprs {
				walk_expr(e, ctx, mut edges, mut seen)
			}
		}
		else {}
	}
}
