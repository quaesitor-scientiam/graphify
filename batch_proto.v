module graphify

// Fast encode/decode for FileResult in the batch worker protocol.
// Uses ASCII control-char delimiters instead of JSON to avoid json2 overhead
// in the hot loop (5000+ calls per extraction).
//
// Format (one line per FileResult):
//   <sym_section>\x03<edge_section>\x03<parse_error>
//   sym_section : sym\x02sym\x02...   (empty if no symbols)
//   edge_section: edge\x02edge\x02... (empty if no edges)
//   parse_error : FileResult.parse_error (empty if the file parsed cleanly)
//   sym  : id\x01name\x01kind_int\x01sig\x01file\x01line\x01end_line\x01is_pub\x01parent\x01doc\x01recipe\x01tparams\x01build
//   edge : from\x01to\x01kind_int\x01is_method\x01recv_type\x01file\x01recv_recipe\x01provenance_int\x01arg_sites\x01guards\x01lines\x01build
//   lines: a calls edge's call-site lines, joined by commas
//
// \x01 = field sep, \x02 = record sep, \x03 = section sep, \x04 = encoded
// newline. Signatures and doc strings may contain any printable char; the only
// chars scrubbed are \x01-\x04 (replaced with space, none of which appear in V
// source). Real newlines are encoded rather than scrubbed, so multi-line doc
// comments survive a protocol that is otherwise one-record-per-line.

const bp_fs = '\x01' // field separator
const bp_rs = '\x02' // record separator
const bp_ss = '\x03' // section separator
// Encoded newline. Doc comments are multi-line, but this protocol is strictly
// line-based -- the worker writes one line per FileResult and the parent reads
// it back with read_lines. A raw newline would split one record into several,
// silently truncating the doc AND inflating the line count the parent uses to
// identify which file killed a crashed worker.
const bp_nl = '\x04'

fn bp_clean(s string) string {
	if !s.contains_any('\x01\x02\x03\x04\n\r') {
		return s
	}
	return s.replace('\x01', ' ').replace('\x02', ' ').replace('\x03', ' ').replace('\x04',
		' ').replace('\r\n', bp_nl).replace('\n', bp_nl).replace('\r', bp_nl)
}

// bp_restore turns encoded newlines back into real ones on decode.
fn bp_restore(s string) string {
	return if s.contains(bp_nl) { s.replace(bp_nl, '\n') } else { s }
}

pub fn encode_file_result(fr FileResult) string {
	mut sym_parts := []string{cap: fr.symbols.len}
	for s in fr.symbols {
		sym_parts << '${bp_clean(s.id)}${bp_fs}${bp_clean(s.name)}${bp_fs}${int(s.kind)}${bp_fs}${bp_clean(s.signature)}${bp_fs}${bp_clean(s.file)}${bp_fs}${s.line}${bp_fs}${s.end_line}${bp_fs}${if s.is_pub { '1' } else { '0' }}${bp_fs}${bp_clean(s.parent)}${bp_fs}${bp_clean(s.doc)}${bp_fs}${bp_clean(s.recipe)}${bp_fs}${bp_clean(s.tparams)}${bp_fs}${bp_clean(s.build)}'
	}
	mut edge_parts := []string{cap: fr.edges.len}
	for e in fr.edges {
		edge_parts << '${bp_clean(e.from)}${bp_fs}${bp_clean(e.to)}${bp_fs}${int(e.kind)}${bp_fs}${if e.is_method {
			'1'
		} else {
			'0'
		}}${bp_fs}${bp_clean(e.recv_type)}${bp_fs}${bp_clean(e.file)}${bp_fs}${bp_clean(e.recv_recipe)}${bp_fs}${int(e.provenance)}${bp_fs}${bp_clean(e.arg_sites)}${bp_fs}${bp_clean(e.guards)}${bp_fs}${e.lines.map(it.str()).join(',')}${bp_fs}${bp_clean(e.build)}'
	}
	return sym_parts.join(bp_rs) + bp_ss + edge_parts.join(bp_rs) + bp_ss + bp_clean(fr.parse_error)
}

// decode_file_result reads back a line encode_file_result wrote. A record with too
// few fields is skipped. The line is scanned in place rather than split: the parent
// decodes every file of an extract, and splitting copied each record and field once
// more before the fields kept were copied again, most of the parent's garbage.
pub fn decode_file_result(line string) FileResult {
	ss1 := index_from(line, bp_ss[0], 0, line.len)
	ss2 := if ss1 < line.len { index_from(line, bp_ss[0], ss1 + 1, line.len) } else { line.len }
	ss3 := if ss2 < line.len { index_from(line, bp_ss[0], ss2 + 1, line.len) } else { line.len }
	parse_error := if ss2 < line.len { bp_restore(line[ss2 + 1..ss3]) } else { '' }

	mut f := []int{cap: 26}
	mut symbols := []Symbol{}
	for at := 0; at < ss1; {
		rec_end := index_from(line, bp_rs[0], at, ss1)
		bp_fields(line, at, rec_end, mut f)
		at = rec_end + 1
		if f.len < 20 {
			continue
		}
		symbols << Symbol{
			id:        bp_field(line, f, 0)
			name:      bp_field(line, f, 1)
			kind:      unsafe { SymbolKind(bp_int(line, f, 2)) }
			signature: bp_restore(bp_field(line, f, 3))
			file:      bp_field(line, f, 4)
			line:      bp_int(line, f, 5)
			end_line:  bp_int(line, f, 6)
			is_pub:    bp_is_one(line, f, 7)
			parent:    bp_field(line, f, 8)
			doc:       bp_restore(bp_field(line, f, 9))
			recipe:    bp_field(line, f, 10)
			tparams:   bp_field(line, f, 11)
			build:     bp_field(line, f, 12)
		}
	}

	mut edges := []Edge{}
	for at := ss1 + 1; at < ss2; {
		rec_end := index_from(line, bp_rs[0], at, ss2)
		bp_fields(line, at, rec_end, mut f)
		at = rec_end + 1
		if f.len < 6 {
			continue
		}
		edges << Edge{
			from:        bp_field(line, f, 0)
			to:          bp_field(line, f, 1)
			kind:        unsafe { EdgeKind(bp_int(line, f, 2)) }
			// tolerate the older 3-field form, so a cache written by a
			// previous build decodes instead of panicking on f[3]
			is_method:   bp_is_one(line, f, 3)
			recv_type:   bp_field(line, f, 4)
			// disambiguate_ids renames an edge's `from` by this file; without
			// it every call from a renamed declaration pointed at `id@`
			file:        bp_field(line, f, 5)
			recv_recipe: bp_field(line, f, 6)
			provenance:  if f.len > 14 {
				unsafe { EdgeProvenance(bp_int(line, f, 7)) }
			} else {
				.extracted
			}
			arg_sites:   bp_field(line, f, 8)
			guards:      bp_field(line, f, 9)
			lines:       bp_ints(line, f, 10)
			build:       bp_field(line, f, 11)
		}
	}

	return FileResult{ symbols: symbols, edges: edges, parse_error: parse_error }
}

// index_from returns the index of the first `c` in s[from..to], or `to`.
fn index_from(s string, c u8, from int, to int) int {
	for i in from .. to {
		if s[i] == c {
			return i
		}
	}
	return to
}

// bp_fields fills `f` with the start and end of each field of the record
// s[from..to], two ints per field, as `split(bp_fs)` would cut it.
fn bp_fields(s string, from int, to int, mut f []int) {
	f.clear()
	mut start := from
	for i in from .. to {
		if s[i] == bp_fs[0] {
			f << start
			f << i
			start = i + 1
		}
	}
	f << start
	f << to
}

// bp_field copies field `i` of the record bp_fields cut, '' past its last.
fn bp_field(s string, f []int, i int) string {
	if 2 * i + 1 >= f.len || f[2 * i] == f[2 * i + 1] {
		return ''
	}
	return s[f[2 * i]..f[2 * i + 1]]
}

fn bp_is_one(s string, f []int, i int) bool {
	return 2 * i + 1 < f.len && f[2 * i + 1] - f[2 * i] == 1 && s[f[2 * i]] == `1`
}

// bp_int reads field `i`, a decimal int as encode_file_result writes one, without
// copying it out. Unlike string.int(), it knows no `0x` prefix or `_` separator.
fn bp_int(s string, f []int, i int) int {
	if 2 * i + 1 >= f.len {
		return 0
	}
	return bp_int_at(s, f[2 * i], f[2 * i + 1])
}

fn bp_int_at(s string, from int, to int) int {
	mut i := from
	neg := i < to && s[i] == `-`
	if neg || (i < to && s[i] == `+`) {
		i++
	}
	mut n := 0
	for i < to && s[i] >= `0` && s[i] <= `9` {
		n = n * 10 + int(s[i] - `0`)
		i++
	}
	return if neg { -n } else { n }
}

// bp_ints reads field `i` as the comma-separated ints of a call's lines.
fn bp_ints(s string, f []int, i int) []int {
	if 2 * i + 1 >= f.len || f[2 * i] == f[2 * i + 1] {
		return []int{}
	}
	from, to := f[2 * i], f[2 * i + 1]
	mut out := []int{cap: 1}
	mut start := from
	for j in from .. to + 1 {
		if j == to || s[j] == `,` {
			out << bp_int_at(s, start, j)
			start = j + 1
		}
	}
	return out
}
