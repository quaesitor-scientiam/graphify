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

// file_hash returns the hex SHA256 of a file's content, or '' if it can't be
// read (the caller then treats the file as uncached and reparses it).
fn file_hash(path string) string {
	content := os.read_file(path) or { return '' }
	return sha256.hexhash(content)
}

// load_cache reads a previous run's cache file into rel_path -> CacheEntry.
// A missing or unparseable cache is treated as empty (full reparse), not an
// error — the cache is purely an optimization, never a correctness dependency.
fn load_cache(out_dir string) map[string]CacheEntry {
	mut out := map[string]CacheEntry{}
	content := os.read_file(os.join_path(out_dir, cache_file_name)) or { return out }
	for line in content.split_into_lines() {
		if line.trim_space() == '' {
			continue
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
// next extract can skip re-parsing whatever hasn't changed.
fn save_cache(out_dir string, entries []CacheEntry) {
	mut lines := []string{cap: entries.len}
	for e in entries {
		lines << '${e.rel}\t${e.hash}\t${encode_file_result(e.fr)}'
	}
	os.write_file(os.join_path(out_dir, cache_file_name), lines.join('\n')) or {}
}
