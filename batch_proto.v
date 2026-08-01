module graphify

// Fast encode/decode for FileResult in the batch worker protocol.
// Uses ASCII control-char delimiters instead of JSON to avoid json2 overhead
// in the hot loop (5000+ calls per extraction).
//
// Format (one line per FileResult):
//   <sym_section>\x03<edge_section>
//   sym_section : sym\x02sym\x02...   (empty if no symbols)
//   edge_section: edge\x02edge\x02... (empty if no edges)
//   sym  : id\x01name\x01kind_int\x01sig\x01file\x01line\x01end_line\x01is_pub\x01parent\x01doc
//   edge : from\x01to\x01kind_int\x01is_method\x01recv_type
//
// \x01 = field sep, \x02 = record sep, \x03 = section sep.
// Signatures and doc strings may contain any printable char; the only chars
// scrubbed are \x01-\x03 (replaced with space, which never appear in V source).

const bp_fs = '\x01' // field separator
const bp_rs = '\x02' // record separator
const bp_ss = '\x03' // section separator

fn bp_clean(s string) string {
	if !s.contains_any('\x01\x02\x03') {
		return s
	}
	return s.replace('\x01', ' ').replace('\x02', ' ').replace('\x03', ' ')
}

pub fn encode_file_result(fr FileResult) string {
	mut sym_parts := []string{cap: fr.symbols.len}
	for s in fr.symbols {
		sym_parts << '${bp_clean(s.id)}${bp_fs}${bp_clean(s.name)}${bp_fs}${int(s.kind)}${bp_fs}${bp_clean(s.signature)}${bp_fs}${bp_clean(s.file)}${bp_fs}${s.line}${bp_fs}${s.end_line}${bp_fs}${if s.is_pub { '1' } else { '0' }}${bp_fs}${bp_clean(s.parent)}${bp_fs}${bp_clean(s.doc)}'
	}
	mut edge_parts := []string{cap: fr.edges.len}
	for e in fr.edges {
		edge_parts << '${bp_clean(e.from)}${bp_fs}${bp_clean(e.to)}${bp_fs}${int(e.kind)}${bp_fs}${if e.is_method {
			'1'
		} else {
			'0'
		}}${bp_fs}${bp_clean(e.recv_type)}'
	}
	return sym_parts.join(bp_rs) + bp_ss + edge_parts.join(bp_rs)
}

pub fn decode_file_result(line string) FileResult {
	sections := line.split(bp_ss)
	sym_sec  := sections[0]
	edge_sec := if sections.len > 1 { sections[1] } else { '' }

	mut symbols := []Symbol{}
	if sym_sec != '' {
		for sr in sym_sec.split(bp_rs) {
			f := sr.split(bp_fs)
			if f.len < 10 { continue }
			symbols << Symbol{
				id:        f[0]
				name:      f[1]
				kind:      unsafe { SymbolKind(f[2].int()) }
				signature: f[3]
				file:      f[4]
				line:      f[5].int()
				end_line:  f[6].int()
				is_pub:    f[7] == '1'
				parent:    f[8]
				doc:       f[9]
			}
		}
	}

	mut edges := []Edge{}
	if edge_sec != '' {
		for er in edge_sec.split(bp_rs) {
			f := er.split(bp_fs)
			if f.len < 3 { continue }
			edges << Edge{
				from: f[0]
				to:   f[1]
				kind: unsafe { EdgeKind(f[2].int()) }
				// tolerate the older 3-field form, so a cache written by a
				// previous build decodes instead of panicking on f[3]
				is_method: f.len > 3 && f[3] == '1'
				recv_type: if f.len > 4 { f[4] } else { '' }
			}
		}
	}

	return FileResult{ symbols: symbols, edges: edges }
}
