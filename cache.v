module graphify

import os
import crypto.sha256

// CacheEntry pairs a file's content hash with its previously-extracted
// symbols/edges, so an unchanged file can be reused without re-parsing.
struct CacheEntry {
	rel  string
	hash string
	fr   FileResult
}

// cache_file_name is the incremental-cache artifact written alongside
// graph.json in the output directory.
const cache_file_name = '.gf_cache.ndjson'

// cache_format is a fixed envelope-shape marker (the first line of the cache
// file), bumped only when the NUMBER OR MEANING of header lines changes --
// this file's own addition of the binary-hash line below was the last such
// change. It is deliberately NOT the thing that catches an extraction-logic
// change any more (see load_cache) -- that used to be its whole job, and it
// missed a real case: a fix that changes WHICH symbols get extracted from a
// file (e.g. skipping some FnDecls) without changing FileResult's on-disk
// shape left old, wrong per-file results cached indefinitely after a
// rebuild, because nothing about the wire format actually changed. Confirmed
// live: a production graph kept serving pre-fix results for weeks after the
// fix shipped, on a completely unchanged corpus, because only the source
// files' own hashes were ever checked. This marker now only guards the
// envelope itself from being misparsed by an older/newer build.
const cache_format = 'graphify-cache-v5'

// file_hash returns the hex SHA256 of a file's content, or '' if it can't be
// read (the caller then treats the file as uncached and reparses it). Also
// used to hash the graphify binary itself -- see load_cache/save_cache.
fn file_hash(path string) string {
	content := os.read_file(path) or { return '' }
	return sha256.hexhash(content)
}

// load_cache reads a previous run's cache file into rel_path -> CacheEntry.
// A missing or unparseable cache is treated as empty (full reparse), not an
// error — the cache is purely an optimization, never a correctness
// dependency. `bin_hash` is the SHA256 of the graphify binary about to run
// this extract (build_graph_resilient hashes os.executable() once and passes
// it to both load_cache and save_cache) -- a cache written by a DIFFERENT
// binary is discarded wholesale, even when every source file's own content
// hash still matches, because the binary is what actually decides what a
// given file's content extracts to. A blank bin_hash means we couldn't even
// hash our own executable, so nothing is trustworthy either way.
fn load_cache(out_dir string, bin_hash string) map[string]CacheEntry {
	mut out := map[string]CacheEntry{}
	if bin_hash == '' {
		return out
	}
	content := os.read_file(os.join_path(out_dir, cache_file_name)) or { return out }
	lines := content.split_into_lines()
	if lines.len < 2 || lines[0].trim_space() != cache_format
		|| lines[1].trim_space() != 'binary:${bin_hash}' {
		return out // absent, stale envelope, or written by a different binary
	}
	for i, line in lines {
		if i < 2 || line.trim_space() == '' {
			continue // [0] format marker, [1] binary hash, both already validated
		}
		parts := line.split_nth('\t', 3)
		if parts.len < 3 {
			continue
		}
		out[parts[0]] = CacheEntry{
			rel:  parts[0]
			hash: parts[1]
			fr:   decode_file_result(parts[2])
		}
	}
	return out
}

// save_cache persists this run's per-file hashes + extracted results, so the
// next extract can skip re-parsing whatever hasn't changed — provided the
// same binary is still the one running next time (see load_cache).
fn save_cache(out_dir string, bin_hash string, entries []CacheEntry) {
	if bin_hash == '' {
		return // don't write a cache load_cache could never trust anyway
	}
	mut lines := []string{cap: entries.len + 2}
	lines << cache_format
	lines << 'binary:${bin_hash}'
	for e in entries {
		lines << '${e.rel}\t${e.hash}\t${encode_file_result(e.fr)}'
	}
	os.write_file(os.join_path(out_dir, cache_file_name), lines.join('\n')) or {}
}
