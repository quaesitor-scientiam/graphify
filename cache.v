module graphify

import os
import crypto.sha256

// CacheEntry pairs a file's content hash with its previously-extracted
// symbols/edges, so an unchanged file can be reused without re-parsing.
struct CacheEntry {
	rel  string
	hash string
	fr   FileResult
mut:
	// stale is true exactly when `fr` has NOT been verified against the
	// file's current on-disk content this run: this run's attempt to parse
	// it crashed, and `fr`/`hash` are carried forward from the last run that
	// did succeed. false whenever `fr` is either freshly extracted this run
	// or reused because `hash` was directly matched against current content
	// (see stale_fallback_for/fresh_reuse_of in graphify.v). Mutable so those
	// two helpers can flip it on a cheap copy of an existing entry instead of
	// rebuilding one field-by-field.
	stale bool
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
const cache_format = 'graphify-cache-v7'

// build_cache_key is what bin/update-vlang-graph.vsh builds the CLI and its extractor
// with (`-d graphify_cache_key=...`, its parse_key): a hash of every V file compiled into
// the CLI, graphify's own and vlib's, of the C files and headers beside them, and of
// thirdparty. Not of the compiler: a change to how V compiles them that changes what a
// file extracts to keeps the key. '' in a build without it.
const build_cache_key = $d('graphify_cache_key', '')

// parse_key is what the parse cache is keyed on, given the hash of the binary that
// parses (`bin_hash`): build_cache_key, when the binary was built with one, so that a
// rebuild for a change that compiles in none of what extracts a file, such as a new
// compiler, keeps the cache; else the binary's own hash. The key's source is in it, so
// a key never matches a hash. '' when the binary can't be hashed, which trusts no cache.
fn parse_key(bin_hash string) string {
	if bin_hash == '' {
		return ''
	}
	return if build_cache_key != '' { 'build ${build_cache_key}' } else { bin_hash }
}

// file_hash returns the hex SHA256 of a file's content, or '' if it can't be
// read (the caller then treats the file as uncached and reparses it). Also
// used to hash the graphify binary itself -- see load_cache/save_cache.
fn file_hash(path string) string {
	content := os.read_file(path) or { return '' }
	return sha256.hexhash(content)
}

// source_hash is a source file's text hash (text_hash), or '' if it can't be
// read. Used for the extract's own files and the graph's record of them.
fn source_hash(path string) string {
	content := os.read_file(path) or { return '' }
	return text_hash(content)
}

// text_hash hashes source text with CRLF line ends read as LF, so a checkout
// with core.autocrlf hashes the same as one without. get_body compares the
// text it reads with the hash the extract recorded.
fn text_hash(text string) string {
	return sha256.hexhash(text.replace('\r\n', '\n'))
}

// load_cache reads a previous run's cache file into rel_path -> CacheEntry.
// A missing or unparseable cache is treated as empty (full reparse), not an
// error — the cache is purely an optimization, never a correctness
// dependency. `bin_hash` is the key of the graphify build about to run this extract
// (parse_key: what it was built from, or the binary's own SHA256; build_graph_with_library
// works it out once and passes it to both load_cache and save_cache) -- a cache written
// by a DIFFERENT build is discarded wholesale, even when every source file's own content
// hash still matches, because the build is what actually decides what a given file's
// content extracts to. A blank key means we couldn't even hash our own executable, so
// nothing is trustworthy either way.
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
		// rel, hash, stale flag ('1'/'0'), then the FileResult's own encoding
		// (which may itself contain further \x01-\x04-escaped structure, so it
		// is always the last, unsplit field — see batch_proto.v). Adding the
		// stale field here does not need a cache_format bump: a key mismatch
		// above already discards the whole cache before any per-line parsing
		// happens, and the key names graphify's own source, so a binary old
		// enough to predate this field can never misparse a line written by a
		// newer one, or vice versa.
		parts := line.split_nth('\t', 4)
		if parts.len < 4 {
			continue
		}
		out[parts[0]] = CacheEntry{
			rel:   parts[0]
			hash:  parts[1]
			stale: parts[2] == '1'
			fr:    decode_file_result(parts[3])
		}
	}
	return out
}

// save_cache persists this run's per-file hashes + extracted results, so the
// next extract can skip re-parsing whatever hasn't changed — provided a build
// with the same key is the one running next time (see load_cache).
fn save_cache(out_dir string, bin_hash string, entries []CacheEntry) {
	if bin_hash == '' {
		return // don't write a cache load_cache could never trust anyway
	}
	mut lines := []string{cap: entries.len + 2}
	lines << cache_format
	lines << 'binary:${bin_hash}'
	for e in entries {
		stale_flag := if e.stale { '1' } else { '0' }
		lines << '${e.rel}\t${e.hash}\t${stale_flag}\t${encode_file_result(e.fr)}'
	}
	os.write_file(os.join_path(out_dir, cache_file_name), lines.join('\n')) or {}
}
