module graphify

// SymbolKind classifies a declaration node in the graph.
pub enum SymbolKind {
	mod_    // `module xyz`
	import_ // `import abc`
	function
	method
	struct_
	enum_
	interface_
	constant
	global
	type_alias
	field
}

// EdgeKind classifies a relationship between two symbols.
pub enum EdgeKind {
	defines    // container -> member (file -> fn, struct -> method)
	calls      // fn -> fn
	imports    // module -> module
	implements // type -> interface
	embeds     // struct -> embedded struct
	references // symbol -> type it mentions
}

// EdgeProvenance marks how confidently an edge's `to` was determined.
// Meaningful only for `calls` edges: every other kind is read straight off
// the AST (a declared id, an embedded field's type, an import's module name)
// with no ambiguity to resolve, so they are always `extracted`. A `calls`
// edge is `extracted` when the callee name was globally unique or its
// receiver's type came straight from the parser (see resolve_callee's
// self-receiver shortcut); it is `inferred` when several real declarations
// shared the name and one was picked by a locality/visibility heuristic.
pub enum EdgeProvenance {
	extracted
	inferred
}

// Symbol is one node in the graph: a single declaration.
pub struct Symbol {
pub mut:
	id        string // stable identity, e.g. 'mymod.User.name' or 'mymod.add'
	name      string // short display name
	kind      SymbolKind
	signature string // token-lean essence, e.g. 'pub fn add(a int, b int) int'
	file      string // path relative to graph root
	line      int    // 1-based start line
	end_line  int    // 1-based end line (for fetching the body); 0 if unknown
	is_pub    bool
	parent    string // id of containing symbol, '' for top-level
	doc       string // leading doc comment, if any
}

// Edge is one relationship between two symbols (by id).
pub struct Edge {
pub:
	from string
	to   string // resolved symbol id, or a raw name when unresolved
	kind EdgeKind
	// provenance is only meaningful for a resolved `calls` edge — see
	// EdgeProvenance. Every other edge keeps the zero value, `extracted`,
	// which is simply true for them.
	provenance EdgeProvenance
	// is_method marks a `calls` edge that came from `x.foo()` rather than
	// `foo()`. It is an extraction-time hint consumed by resolve_edges to
	// narrow candidates; it is deliberately not written to graph.json, since
	// once resolution has run it carries no further meaning.
	is_method bool
	// recv_type is the id of the receiver's type when the parser can see it
	// without inference — currently `t.foo()` inside a method whose own
	// receiver is `t`, where the type is written on the enclosing FnDecl.
	// Empty whenever the receiver would need the checker to type. Like
	// is_method, it is extraction-only and not persisted.
	recv_type string
}

// FileResult is one file's extracted symbols and edges — the unit passed back
// from a per-file worker process to the resilient orchestrator.
pub struct FileResult {
pub mut:
	symbols []Symbol
	edges   []Edge
}

// Graph is the whole project: every symbol and relationship discovered.
pub struct Graph {
pub mut:
	root    string
	symbols []Symbol
	edges   []Edge
	// roots maps a merged graph's namespace label chain (matching the
	// `label::` prefix merge_graphs gives that source's symbol ids) to that
	// source's own original absolute root. Empty for a graph extracted
	// directly, where `root` above is the only root there is — get_body
	// falls back to it whenever roots is empty, so existing single-source
	// graph.json files keep working unchanged.
	roots map[string]string
}

// add_symbol appends a symbol and returns its id for convenient edge wiring.
pub fn (mut g Graph) add_symbol(s Symbol) string {
	g.symbols << s
	return s.id
}

// add_edge appends a relationship, skipping obviously empty ones.
pub fn (mut g Graph) add_edge(e Edge) {
	if e.from == '' || e.to == '' {
		return
	}
	g.edges << e
}

// loc renders a clickable `file:line` location for a symbol.
pub fn (s Symbol) loc() string {
	return '${s.file}:${s.line}'
}

// render returns a one-line, body-less view of a symbol with its location,
// e.g. `pub fn add(a int, b int) int { ... }   // math.v:12`.
pub fn (s Symbol) render() string {
	body := if s.kind == .function || s.kind == .method { ' { ... }' } else { '' }
	return '${s.signature}${body}   // ${s.loc()}'
}

// kind_str renders a SymbolKind as the keyword a reader expects.
pub fn (k SymbolKind) str() string {
	return match k {
		.mod_ { 'module' }
		.import_ { 'import' }
		.function { 'fn' }
		.method { 'method' }
		.struct_ { 'struct' }
		.enum_ { 'enum' }
		.interface_ { 'interface' }
		.constant { 'const' }
		.global { 'global' }
		.type_alias { 'type' }
		.field { 'field' }
	}
}
