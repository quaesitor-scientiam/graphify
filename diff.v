module graphify

import os

// FileLossStatus classifies why a file's symbols might be missing from a
// newer graph, for diff_graphs' grouping — distinct handling for "this file
// simply failed to parse this run" versus "this file is fine, but this
// specific symbol vanished from it anyway", which is the surprising case an
// audit is actually looking for.
pub enum FileLossStatus {
	unknown        // no manifest.json alongside `new` to consult
	parse_failed   // new-manifest lists this file as failed, no fallback
	stale          // new-manifest lists this file as stale (serving old data)
	partially_parsed // new-manifest lists this file as having parsed with syntax errors
	file_removed   // file has no symbols anywhere in `new`
	symbol_missing // file still has other symbols in `new`; this one specifically is gone
}

pub fn (s FileLossStatus) str() string {
	return match s {
		.unknown { 'unknown (no manifest.json found next to the new graph)' }
		.parse_failed { 'failed to parse this run — symbols genuinely dropped, not moved' }
		.stale { 'failed to reparse this run — new graph is serving a stale cached copy' }
		.partially_parsed { 'parsed with syntax errors this run — symbols near an error may be missing' }
		.file_removed { 'file has no symbols at all in the new graph' }
		.symbol_missing { 'file is still present in the new graph; this symbol specifically is gone' }
	}
}

// FileLoss groups every symbol from `old` that is missing from `new` under
// the file that declared it, plus that file's status in the new graph.
pub struct FileLoss {
pub:
	file    string
	status  FileLossStatus
	symbols []Symbol
}

// diff_graphs finds every symbol present in `old` but absent from `new` (by
// id), grouped by the file that declared it in `old`. This is deliberately
// broader than "what a merge might have lost": a walker change, a skip-list
// edit, or a genuine source deletion all show up the same way, which is the
// point — the caller decides whether a loss was expected.
//
// `new_manifest_dir`, if non-empty, is checked for a manifest.json (as
// write_bundle produces next to graph.json) to distinguish a file that
// merely failed to parse this run from one that is genuinely gone; pass ''
// to skip this and always report `.unknown`/`.file_removed`/`.symbol_missing`.
pub fn diff_graphs(old Graph, new Graph, new_manifest_dir string) []FileLoss {
	mut new_ids := map[string]bool{}
	mut new_files := map[string]bool{}
	for s in new.symbols {
		new_ids[s.id] = true
		new_files[s.file] = true
	}

	manifest_path := os.join_path(new_manifest_dir, 'manifest.json')
	has_manifest := new_manifest_dir != '' && os.exists(manifest_path)
	mut failed_files := map[string]bool{}
	mut stale_files := map[string]bool{}
	mut partial_files := map[string]bool{}
	if has_manifest {
		// best-effort: an unreadable/corrupt manifest is treated the same as
		// a missing one (`.unknown`), not a hard error for the whole diff.
		m := load_manifest(manifest_path) or { Manifest{} }
		for f in m.failed {
			failed_files[f] = true
		}
		for f in m.stale {
			stale_files[f] = true
		}
		for f in m.partial {
			partial_files[f] = true
		}
	}

	mut by_file := map[string][]Symbol{}
	mut order := []string{}
	for s in old.symbols {
		if s.id in new_ids {
			continue
		}
		if s.file !in by_file {
			order << s.file
		}
		by_file[s.file] << s
	}

	mut out := []FileLoss{cap: order.len}
	for file in order {
		status := if !has_manifest {
			FileLossStatus.unknown
		} else if file in failed_files {
			FileLossStatus.parse_failed
		} else if file in stale_files {
			FileLossStatus.stale
		} else if file in partial_files {
			FileLossStatus.partially_parsed
		} else if file in new_files {
			FileLossStatus.symbol_missing
		} else {
			FileLossStatus.file_removed
		}
		out << FileLoss{
			file:    file
			status:  status
			symbols: by_file[file]
		}
	}
	return out
}
