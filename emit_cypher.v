module graphify

// emit_cypher serializes the graph as a Cypher script for Neo4j
// (`cypher-shell < graph.cypher`). Nodes are created directly; edges are
// created via MATCH-by-id rather than referencing a CREATE statement's
// variable from a later, separate statement -- variables don't survive
// across individual statements in a script run this way, only within one
// query. A uniqueness constraint on `id` is emitted first specifically so
// those MATCHes get an index lookup instead of a full node scan. Only
// resolved edges are emitted, for the same reason emit_graphml gives: an
// edge to an external/still-ambiguous raw name has no node to MATCH.
//
// Nodes come from idx.by_id, not the raw g.symbols list -- a real
// correctness requirement here, not just consistency with the rest of the
// codebase's Index-based view: this project's own files all declare
// `module graphify`, so a naive one-CREATE-per-raw-symbol loop emits
// `CREATE (:Symbol:Module {id: 'graphify', ...})` once per file, and the
// *second* one would fail outright against the uniqueness constraint above
// (confirmed directly -- this was caught by actually running the export
// against this repo, not by inspection). Every standalone V program's
// `main` module collides the same way. idx.by_id already collapses same-id
// symbols to one everywhere else (query, explain, path); doing anything
// else here would also silently disagree with what idx.edges' endpoints
// reference.
pub fn (g Graph) emit_cypher() string {
	idx := g.index()
	mut sb := []string{}
	sb << 'CREATE CONSTRAINT graphify_id IF NOT EXISTS FOR (n:Symbol) REQUIRE n.id IS UNIQUE;'
	sb << ''
	for _, s in idx.by_id {
		sb << 'CREATE (:Symbol:${cypher_label(s.kind)} {id: ${cypher_str(s.id)}, name: ${cypher_str(s.name)}, file: ${cypher_str(s.file)}, line: ${s.line}, signature: ${cypher_str(s.signature)}});'
	}
	sb << ''
	for e in idx.edges {
		mut props := ''
		if e.kind in [EdgeKind.calls, .embeds, .references] {
			prov := if e.provenance == .inferred { 'inferred' } else { 'extracted' }
			props = ' {provenance: ${cypher_str(prov)}}'
		}
		sb << 'MATCH (a:Symbol {id: ${cypher_str(e.from)}}), (b:Symbol {id: ${cypher_str(e.to)}}) CREATE (a)-[:${cypher_rel_type(e.kind)}${props}]->(b);'
	}
	return sb.join('\n')
}

// cypher_str renders a Cypher single-quoted string literal, escaping
// backslashes before quotes so an escaped quote's own backslash can't be
// mistaken for escaping whatever follows it.
fn cypher_str(s string) string {
	escaped := s.replace('\\', '\\\\').replace("'", "\\'")
	return "'${escaped}'"
}

// cypher_label maps a SymbolKind to a Cypher-safe node label: an
// identifier, so the trailing underscores this project's own SymbolKind
// names carry (mod_, struct_, ...) to dodge V keyword clashes can't be used
// verbatim.
fn cypher_label(k SymbolKind) string {
	return match k {
		.mod_ { 'Module' }
		.import_ { 'Import' }
		.function { 'Function' }
		.method { 'Method' }
		.struct_ { 'Struct' }
		.enum_ { 'Enum' }
		.interface_ { 'Interface' }
		.constant { 'Constant' }
		.global { 'Global' }
		.type_alias { 'TypeAlias' }
		.field { 'Field' }
	}
}

// cypher_rel_type maps an EdgeKind to the UPPER_SNAKE_CASE Cypher
// convention for relationship types.
fn cypher_rel_type(k EdgeKind) string {
	return match k {
		.defines { 'DEFINES' }
		.calls { 'CALLS' }
		.imports { 'IMPORTS' }
		.implements { 'IMPLEMENTS' }
		.embeds { 'EMBEDS' }
		.references { 'REFERENCES' }
	}
}
