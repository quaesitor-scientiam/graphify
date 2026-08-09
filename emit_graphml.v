module graphify

// emit_graphml serializes the graph as GraphML, a de facto standard for
// interchange with graph tools (Gephi, yEd, Cytoscape, NetworkX). Only
// resolved edges are emitted: GraphML's source/target attributes must
// reference declared nodes, and idx.edges already excludes anything that
// didn't resolve to a known symbol (external calls, still-ambiguous names)
// -- see Index's own doc comment. Emitting those anyway would mean either
// an invalid file or a synthetic placeholder node for every unresolved
// name, cluttering the output with symbols nothing actually resolved to.
//
// Nodes come from idx.by_id, not the raw g.symbols list: a raw id like
// `main` (the implicit module of every standalone V program) or `graphify`
// (this project's own module, declared identically in every one of its own
// files) is shared by several distinct real declarations -- the same
// collision resolve_edges' `unaddressable` check exists for on the calls
// side, and communities.v's doc comment documents at more length. Index
// already collapses that down to one node per id everywhere else (query,
// explain, path); emitting one <node> per raw symbol here instead would
// silently disagree with what idx.edges' endpoints actually reference.
pub fn (g Graph) emit_graphml() string {
	idx := g.index()
	mut sb := []string{}
	sb << '<?xml version="1.0" encoding="UTF-8"?>'
	sb << '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">'
	sb << '  <key id="d_name" for="node" attr.name="name" attr.type="string"/>'
	sb << '  <key id="d_kind" for="node" attr.name="kind" attr.type="string"/>'
	sb << '  <key id="d_file" for="node" attr.name="file" attr.type="string"/>'
	sb << '  <key id="d_line" for="node" attr.name="line" attr.type="int"/>'
	sb << '  <key id="d_sig" for="node" attr.name="signature" attr.type="string"/>'
	sb << '  <key id="e_kind" for="edge" attr.name="kind" attr.type="string"/>'
	sb << '  <key id="e_prov" for="edge" attr.name="provenance" attr.type="string"/>'
	sb << '  <graph id="graphify" edgedefault="directed">'
	for _, s in idx.by_id {
		sb << '    <node id="${xml_escape(s.id)}">'
		sb << '      <data key="d_name">${xml_escape(s.name)}</data>'
		sb << '      <data key="d_kind">${xml_escape(s.kind.str())}</data>'
		sb << '      <data key="d_file">${xml_escape(s.file)}</data>'
		sb << '      <data key="d_line">${s.line}</data>'
		sb << '      <data key="d_sig">${xml_escape(s.signature)}</data>'
		sb << '    </node>'
	}
	for e in idx.edges {
		sb << '    <edge source="${xml_escape(e.from)}" target="${xml_escape(e.to)}">'
		sb << '      <data key="e_kind">${xml_escape(edge_kind_str(e.kind))}</data>'
		if e.kind in [EdgeKind.calls, .embeds, .references] {
			prov := if e.provenance == .inferred { 'inferred' } else { 'extracted' }
			sb << '      <data key="e_prov">${prov}</data>'
		}
		sb << '    </edge>'
	}
	sb << '  </graph>'
	sb << '</graphml>'
	return sb.join('\n')
}

// xml_escape escapes the five characters that are unsafe inside XML text
// content or a double-quoted attribute value. `&` must go first -- escaping
// it after the others would double-escape the `&` those replacements
// themselves introduce (`<` -> `&lt;` contains a real `&`).
fn xml_escape(s string) string {
	if !s.contains_any('&<>"\'') {
		return s
	}
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"',
		'&quot;').replace("'", '&apos;')
}
