module graphify

import os
import x.json2
import strings

// save_graph writes the graph to `path` as JSON using a manual builder —
// json2.encode's reflection is far too slow at graph scale (616s for vlang's
// full 100k-symbol graph).
//
// The CLI used to need `-gc none` because Boehm GC made this encoder take
// minutes on V 0.5.2. Built by V3 with the GC, the vlang graph (98 MB) writes
// as fast as without it on macOS and Windows, at a third of the peak memory
// (1.3 GB vs 3.8 GB), so every binary now builds with the GC.
//
// The write itself is staged through a temp file and published with
// atomic_replace, so a reader of `path` (a long-lived graphify-mcp.exe, or a
// concurrent `graphify query`) never observes a partially-written file —
// only the complete previous content or the complete new content. The temp
// file's name includes this process's pid so two extracts racing on the same
// `path` never collide on the temp file itself (only one of them wins the
// final publish; the loser's own write is otherwise undisturbed).
pub fn save_graph(g Graph, path string) ! {
	tmp := '${path}.tmp.${os.getpid()}'
	os.write_file(tmp, graph_to_json(g)) or {
		os.rm(tmp) or {}
		return err
	}
	atomic_replace(tmp, path) or {
		os.rm(tmp) or {}
		return err
	}
}

$if windows {
	#include <windows.h>
}

fn C.MoveFileExW(lp_existing_file_name &u16, lp_new_file_name &u16, dw_flags u32) int

const move_file_replace_existing = 0x1

// atomic_replace moves `src` onto `dst`, replacing any existing `dst`, as a
// single filesystem operation — the whole point being that no reader of
// `dst` can ever observe a state that is neither the old content nor the new
// content.
//
// POSIX `rename()` (what os.rename wraps on non-Windows) already does this.
// Windows' C runtime `rename()` instead FAILS outright when `dst` already
// exists — confirmed empirically here, not assumed from documentation — so
// plain os.rename would error on every publish after the first one, when
// graph.json already exists. os.mv's cross-platform fallback for a failed
// rename is copy-then-delete-source, which reintroduces the exact torn-read
// window this function exists to avoid (a reader could see `dst` mid-copy),
// so it is deliberately not used here. Windows instead goes through
// MoveFileEx with MOVEFILE_REPLACE_EXISTING, which — like POSIX rename — is
// a single atomic filesystem operation when `src` and `dst` are on the same
// volume, which they always are here (same output directory).
fn atomic_replace(src string, dst string) ! {
	$if windows {
		ok := C.MoveFileExW(src.to_wide(), dst.to_wide(), u32(move_file_replace_existing))
		if ok == 0 {
			return error('failed to publish ${dst} (MoveFileEx)')
		}
	} $else {
		os.rename(src, dst)!
	}
}

// load_graph reads a graph previously written by save_graph.
pub fn load_graph(path string) !Graph {
	content := os.read_file(path)!
	return json2.decode[Graph](content)!
}

// graph_to_json manually builds compact JSON for the graph. Every field write
// goes through write_string/write_u8/write_decimal (all allocation-free) to
// avoid string interpolation, which allocates a fresh string per call.
fn graph_to_json(g Graph) string {
	mut sb := strings.new_builder(g.symbols.len * 120 + g.edges.len * 60)
	sb.write_string('{"root":')
	write_json_str(mut sb, g.root)
	sb.write_string(',"roots":{')
	mut ri := 0
	for label, root in g.roots {
		if ri > 0 {
			sb.write_u8(`,`)
		}
		write_json_str(mut sb, label)
		sb.write_u8(`:`)
		write_json_str(mut sb, root)
		ri++
	}
	sb.write_string('},"symbols":[')
	for i, s in g.symbols {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string('{"id":')
		write_json_str(mut sb, s.id)
		sb.write_string(',"name":')
		write_json_str(mut sb, s.name)
		sb.write_string(',"kind":')
		sb.write_decimal(i64(s.kind))
		sb.write_string(',"signature":')
		write_json_str(mut sb, s.signature)
		sb.write_string(',"file":')
		write_json_str(mut sb, s.file)
		sb.write_string(',"line":')
		sb.write_decimal(i64(s.line))
		sb.write_string(',"end_line":')
		sb.write_decimal(i64(s.end_line))
		sb.write_string(',"is_pub":')
		sb.write_string(if s.is_pub { 'true' } else { 'false' })
		sb.write_string(',"parent":')
		write_json_str(mut sb, s.parent)
		sb.write_string(',"doc":')
		write_json_str(mut sb, s.doc)
		sb.write_u8(`}`)
	}
	sb.write_string('],"edges":[')
	for i, e in g.edges {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string('{"from":')
		write_json_str(mut sb, e.from)
		sb.write_string(',"to":')
		write_json_str(mut sb, e.to)
		sb.write_string(',"kind":')
		sb.write_decimal(i64(e.kind))
		sb.write_string(',"provenance":')
		sb.write_decimal(i64(e.provenance))
		sb.write_u8(`}`)
	}
	sb.write_string(']}')
	return sb.str()
}

// write_json_str writes a JSON-escaped string (with surrounding quotes) to sb.
fn write_json_str(mut sb strings.Builder, s string) {
	sb.write_u8(`"`)
	// fast path: no escaping needed (covers almost all ids, names, file paths)
	if !s.contains_any('"\\\n\r\t') {
		sb.write_string(s)
	} else {
		for b in s {
			match b {
				`"` { sb.write_string('\\"') }
				`\\` { sb.write_string('\\\\') }
				`\n` { sb.write_string('\\n') }
				`\r` { sb.write_string('\\r') }
				`\t` { sb.write_string('\\t') }
				else { sb.write_u8(b) }
			}
		}
	}
	sb.write_u8(`"`)
}
