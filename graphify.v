module graphify

import os
import runtime

struct WorkItem {
	path string
	rel  string
	hash string // sha256 of the file's content, for the next run's cache
}

// BatchJob pairs a slice of queued files with the temp files and live worker
// process handling them, so a wave of jobs can be spawned concurrently and
// harvested afterward.
struct BatchJob {
	batch    []WorkItem
	listfile string
	outfile  string
mut:
	proc &os.Process = unsafe { nil }
}

// ExtractReport carries metadata about one extract run that isn't intrinsic
// to the resulting Graph itself, but that a manifest or a caller needs: which
// binary produced it, which files failed to parse this run, and which files'
// contribution to the graph is currently stale (carried forward from an
// earlier successful parse because this run's attempt crashed).
// `stale` is always a subset of `failed`'s *files*, in the sense that every
// stale file failed this run too — but not every failed file is stale: a
// file crashing on its very first sighting has no prior extraction to fall
// back to, so it is in `failed` but not `stale`.
//
// `partial` lists files that parsed with syntax errors (see
// FileResult.parse_error). They are served from this run's recovered parse,
// not from an older cached copy: the recovered parse reflects the file's
// current content and line numbers, which get_body reads from, whereas an
// older copy's line ranges would point at the wrong code once anything moved.
pub struct ExtractReport {
pub:
	binary_hash string
	failed      []string
	stale       []string
	partial     []string
}

// stale_fallback_for looks up a file's last successful extraction to serve
// when this run's attempt to (re)parse it crashed, so a transient failure
// doesn't make the file's symbols vanish from the graph as if it had been
// deleted. Returns none when there is nothing to fall back to — a file
// crashing on its very first sighting was never in `old_cache` at all.
//
// The returned entry is always marked stale, regardless of the entry's own
// stale flag coming in: staleness reflects whether THIS run has verified the
// file's current content, and this call is happening precisely because it
// could not.
fn stale_fallback_for(old_cache map[string]CacheEntry, rel string) ?CacheEntry {
	cached := old_cache[rel] or { return none }
	mut carried := cached
	carried.stale = true
	return carried
}

// fresh_reuse_of returns `cached` with its extraction data unchanged but
// staleness cleared. Used when the file's current content hash matches this
// entry's hash: even if the entry was previously carried forward stale (an
// earlier attempt at some OTHER content crashed), a direct hash match means
// the current content has now been verified against this exact known-good
// extraction, so it is no longer merely assumed to be good — it is confirmed.
fn fresh_reuse_of(cached CacheEntry) CacheEntry {
	mut reused := cached
	reused.stale = false
	return reused
}

// build_graph_resilient builds a graph by parsing files in *worker processes*,
// running up to nr_cpus() of them concurrently (each parses its own batch),
// so a file that makes V's parser panic is skipped and reported instead of
// aborting the whole run. Only when a batch's worker crashes is the offending
// file isolated and the rest of that batch requeued for a later wave. When a
// crashed file has a prior successful extraction cached, that extraction is
// carried forward into the graph marked stale (see stale_fallback_for)
// instead of the file's symbols simply disappearing, indistinguishable from
// the file having been deleted.
//
// Files whose content hash matches `out_dir`'s cache from the previous run
// are reused directly, skipping re-parsing entirely — but only when that
// cache was also written by this same worker_exe binary; see cache.v.
// Returns the graph and a report of the binary hash used plus which files
// failed to parse and/or are being served stale this run.
pub fn build_graph_resilient(root string, worker_exe string, out_dir string) (Graph, ExtractReport) {
	return build_graph_with_library(root, worker_exe, out_dir, LibraryRoots{})
}

// build_graph_with_library is build_graph_resilient that also reads the modules the
// project imports from `lib` (VROOT's vlib and VMODULES), so the project's calls and
// type references into them resolve. Their declarations take part in resolution, and
// the ones the project's edges reach are kept in `g.library` (see FUTURE_WORK.md §10).
pub fn build_graph_with_library(root string, worker_exe string, out_dir string, lib LibraryRoots) (Graph, ExtractReport) {
	abs_root := os.real_path(root)
	mut g := Graph{
		root: abs_root
	}
	// save_cache below needs out_dir to exist; write_bundle also creates it
	// later, but that's after this function returns.
	os.mkdir_all(out_dir) or {}
	// the workers name an import of a vlib alias directory against the library
	// (library_import), and none when it is off
	lib.export_env()

	files := if os.is_dir(abs_root) {
		find_source_files(abs_root)
	} else {
		[abs_root]
	}

	// Hashed once and reused for both load and save below -- see cache.v for
	// why the cache is tied to the running binary's own content, not just
	// each source file's hash. With the library on, an import's name also
	// depends on its roots, so they are part of the key.
	bin_hash := file_hash(worker_exe)
	cache_key := if bin_hash != '' && lib.enabled() { '${bin_hash} ${lib.cache_tag()}' } else { bin_hash }
	mut run := ParseRun{
		worker_exe: worker_exe
		old_cache:  load_cache(out_dir, cache_key)
		pid:        os.getpid()
	}
	// each file's text hash as this run read it, for get_body (Graph.file_hashes)
	mut source_hashes := map[string]string{}
	mut items := []WorkItem{cap: files.len}
	for path in files {
		rel := rel_path(abs_root, path)
		hash := source_hash(path)
		if hash != '' {
			source_hashes[rel] = hash
		}
		items << WorkItem{
			path: path
			rel:  rel
			hash: hash
		}
	}
	run.parse(items)
	// the report is the project's: the library's files are parsed after this
	mut failed := run.failed.clone()
	mut stale := run.stale.clone()
	mut partial := run.partial.clone()

	for path in files {
		if fr := run.by_rel[rel_path(abs_root, path)] {
			g.symbols << fr.symbols
			g.edges << fr.edges
		}
	}
	project_len := g.symbols.len
	lib_rels := if lib.enabled() { run.parse_library(lib, g.symbols, abs_root) } else { []string{} }
	mut lib_files := map[string]bool{}
	for rel in lib_rels {
		if fr := run.by_rel[rel] {
			lib_files[rel] = true
			g.symbols << fr.symbols
			// a call inside vlib is not one of the project's; a module from VMODULES is
			// kept whole, calls and all (keep_reached_library). The edges say which file
			// they come from, which keep_reached_library goes by, since a `C.` binding's
			// id is one for the project and the library
			whole := rel.starts_with(lib_vmodules_prefix)
			for e in fr.edges {
				if e.kind != .calls || whole {
					g.edges << Edge{
						...e
						file: if e.file == '' { rel } else { e.file }
					}
				}
			}
		}
	}
	failed.sort()
	stale.sort()
	partial.sort()
	save_cache(out_dir, cache_key, run.new_cache)
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	if lib_rels.len > 0 {
		keep_reached_library(mut g, project_len, lib, lib_files)
	}
	g.file_hashes = source_hashes
	return g, ExtractReport{
		binary_hash: bin_hash
		failed:      failed
		stale:       stale
		partial:     partial
	}
}

// ParseRun is one extract's parsing: the files the cache answers and the ones the
// worker processes parse, with what each run of them found.
struct ParseRun {
	worker_exe string
	old_cache  map[string]CacheEntry
	pid        int
mut:
	// each file's result, by relative path; the graph is assembled from it in
	// `files` order at the end, so which of two same-id declarations comes
	// first doesn't depend on what was cached, retried or parsed when
	by_rel    map[string]FileResult
	new_cache []CacheEntry
	failed    []string
	stale     []string
	partial   []string
	batch_seq int
	// the files a worker has crashed on once, each parsed again in a worker of its
	// own: a crash that does not happen again, as one on a busy Windows runner,
	// costs the file nothing
	crashed map[string]bool
}

// parse extracts `items`, reusing the cache for a file whose content is unchanged
// since the last extract and parsing the rest in worker processes.
fn (mut run ParseRun) parse(items []WorkItem) {
	mut queue := []WorkItem{}
	for w in items {
		if w.hash != '' && w.rel in run.old_cache && run.old_cache[w.rel].hash == w.hash {
			// unchanged since the last extract — reuse its symbols/edges
			// instead of spending a worker parsing it again.
			reused := fresh_reuse_of(run.old_cache[w.rel])
			run.by_rel[w.rel] = reused.fr
			run.new_cache << reused
			if reused.fr.parse_error != '' {
				run.partial << w.rel
			}
			continue
		}
		queue << w
	}
	if run.worker_exe == '' {
		// no worker to isolate a crash in: each file is parsed here, as the tests
		// that build a graph with its library do
		for w in queue {
			fr := extract_v_file_result(w.path, w.rel)
			run.by_rel[w.rel] = fr
			if fr.parse_error != '' {
				run.partial << w.rel
			}
		}
		return
	}

	batch_size := 200
	parallel := if runtime.nr_cpus() > 0 { runtime.nr_cpus() } else { 1 }

	// the files that crashed a worker once, each to be parsed in a batch of its own
	mut solo := []WorkItem{}
	for queue.len > 0 || solo.len > 0 {
		// slice off up to `parallel` batches and spawn them all before waiting
		// on any of them, so they run concurrently instead of one at a time.
		mut jobs := []BatchJob{}
		for jobs.len < parallel && (queue.len > 0 || solo.len > 0) {
			mut batch := []WorkItem{}
			if solo.len > 0 {
				batch = [solo[0]]
				solo = solo#[1..].clone()
			} else {
				n := if queue.len < batch_size { queue.len } else { batch_size }
				batch = queue#[..n].clone()
				queue = queue#[n..].clone()
			}

			run.batch_seq++
			listfile := os.join_path(os.temp_dir(), 'gf_list_${run.pid}_${run.batch_seq}.txt')
			outfile := os.join_path(os.temp_dir(), 'gf_out_${run.pid}_${run.batch_seq}.ndjson')

			mut lines := []string{}
			for w in batch {
				lines << '${w.path}\t${w.rel}'
			}
			os.write_file(listfile, lines.join('\n')) or {
				// none of this batch's files got a parse attempt this run —
				// same class of gap as a crashed worker, so the same
				// stale-fallback treatment applies to each of them.
				for w in batch {
					run.failed << w.rel
					if fallback := stale_fallback_for(run.old_cache, w.rel) {
						run.by_rel[w.rel] = fallback.fr
						run.new_cache << fallback
						run.stale << w.rel
					}
				}
				continue
			}

			mut p := os.new_process(run.worker_exe)
			p.set_args(['_parse-batch', listfile, outfile])
			p.run()
			jobs << BatchJob{
				batch:    batch
				listfile: listfile
				outfile:  outfile
				proc:     p
			}
		}

		// wait for the whole wave, then harvest + recover each job on its own
		mut retry := []WorkItem{}
		mut alone := []WorkItem{}
		for mut job in jobs {
			job.proc.wait()
			job.proc.close()

			// each completed file wrote one NDJSON line of its FileResult, in
			// the same order as job.batch, so index i pairs with job.batch[i].
			results := os.read_lines(job.outfile) or { []string{} }
			for i, line in results {
				if line.trim_space() == '' {
					continue
				}
				fr := decode_file_result(line)
				if i < job.batch.len {
					run.by_rel[job.batch[i].rel] = fr
					if fr.parse_error != '' {
						run.partial << job.batch[i].rel
					}
					run.new_cache << CacheEntry{
						rel:  job.batch[i].rel
						hash: job.batch[i].hash
						fr:   fr
					}
				}
			}
			completed := results.len
			n := job.batch.len
			if completed < n && !run.crashed[job.batch[completed].rel] {
				// the file at index `completed` crashed this worker, the first time:
				// requeue it, alone, and the rest of the batch for the next wave.
				run.crashed[job.batch[completed].rel] = true
				alone << job.batch[completed]
				for i := completed + 1; i < n; i++ {
					retry << job.batch[i]
				}
			} else if completed < n {
				// it crashed again — skip it and requeue the rest of the batch
				// for the next wave.
				crashed_rel := job.batch[completed].rel
				run.failed << crashed_rel
				if fallback := stale_fallback_for(run.old_cache, crashed_rel) {
					run.by_rel[crashed_rel] = fallback.fr
					run.new_cache << fallback
					run.stale << crashed_rel
				}
				for i := completed + 1; i < n; i++ {
					retry << job.batch[i]
				}
			}
			os.rm(job.listfile) or {}
			os.rm(job.outfile) or {}
		}
		if retry.len > 0 {
			retry << queue
			queue = retry.clone()
		}
		solo << alone
	}
}

// parse_library parses the library modules the project's `symbols` import, and the
// ones those import in turn, and returns their files' rels in the order they were
// read. A module is looked for only when no module of the project is what the import
// names, and one whose directory is inside the project is never read, so extracting
// the V tree itself reads none; builtin, which every file
// imports without saying so, is always read. A library file that fails to parse is
// left out; the report lists only the project's files, which are parsed first.
fn (mut run ParseRun) parse_library(lib LibraryRoots, symbols []Symbol, project_root string) []string {
	mut project_mods := []string{}
	for s in symbols {
		if s.kind == .mod_ && s.id !in project_mods {
			project_mods << s.id
		}
	}
	mut wanted := ['builtin']
	wanted << imports_of_symbols(symbols)
	mut seen_dirs := map[string]bool{}
	mut seen_imports := map[string]bool{}
	mut rels := []string{}
	for wanted.len > 0 {
		mut items := []WorkItem{}
		for imp in wanted {
			if seen_imports[imp] || project_mods.any(import_names(it, imp)) {
				continue
			}
			seen_imports[imp] = true
			m := lib.module_of(imp) or { continue }
			// a module linked into VMODULES from the project is the project's own
			// (resolve_import names it so), not a library
			real := os.real_path(m.dir)
			if seen_dirs[real] || real == project_root || real.starts_with(project_root + os.path_separator) {
				continue
			}
			seen_dirs[real] = true
			for name in m.files() {
				path := os.join_path(m.dir, name)
				items << WorkItem{
					path: path
					rel:  m.rel_dir + '/' + name
					hash: source_hash(path)
				}
			}
		}
		run.parse(items)
		mut next := []Symbol{}
		for w in items {
			if fr := run.by_rel[w.rel] {
				rels << w.rel
				next << fr.symbols
			}
		}
		wanted = imports_of_symbols(next)
	}
	return rels
}

// imports_of_symbols is the module paths the import symbols among `symbols` name.
fn imports_of_symbols(symbols []Symbol) []string {
	mut out := []string{}
	for s in symbols {
		if s.kind == .import_ && s.name !in out {
			out << s.name
		}
	}
	return out
}

// keep_reached_library moves the library's symbols, `g.symbols[project_len..]`, out
// of the project's: the declarations the project's calls, references and embeds reach
// go into `g.library` with their parents, one per id, each with the last line of its
// body, and the rest go, with every edge made in a library file (`lib_files`). An id
// the project declares too, a `C.` binding both have, stays the project's. A module
// from VMODULES is kept whole, with its edges, which reach into vlib as the project's
// do: it is what the project builds against, and the MCP server layers it under the
// project (layer_graph) so a traversal goes on into it (FUTURE_WORK.md §11).
fn keep_reached_library(mut g Graph, project_len int, lib LibraryRoots, lib_files map[string]bool) {
	lib_syms := g.symbols[project_len..].clone()
	mut project_ids := map[string]bool{}
	for s in g.symbols[..project_len] {
		project_ids[s.id] = true
	}
	mut by_id := map[string]Symbol{}
	for s in lib_syms {
		if s.id in project_ids {
			continue
		}
		if prev := by_id[s.id] {
			if shown_before(s, prev) {
				by_id[s.id] = s
			}
		} else {
			by_id[s.id] = s
		}
	}
	// an edge the library's own declarations make, by its file, or by its id when it
	// has none (regenerate_defines makes `defines` edges without one)
	in_library := fn [lib_files, by_id] (e Edge) bool {
		return if e.file != '' { e.file in lib_files } else { e.from in by_id }
	}
	// an edge a module from VMODULES makes, which is kept
	in_vmodules := fn [by_id] (e Edge) bool {
		return if e.file != '' {
			e.file.starts_with(lib_vmodules_prefix)
		} else {
			by_id[e.from].file.starts_with(lib_vmodules_prefix)
		}
	}
	mut keep := map[string]bool{}
	for id, s in by_id {
		if s.file.starts_with(lib_vmodules_prefix) {
			keep[id] = true
		}
	}
	for e in g.edges {
		if e.kind in [EdgeKind.calls, .references, .embeds] && e.to in by_id
			&& (!in_library(e) || in_vmodules(e)) {
			keep[e.to] = true
		}
	}
	for id in keep.keys() {
		mut p := by_id[id].parent
		for p != '' && p in by_id && p !in keep {
			keep[p] = true
			p = by_id[p].parent
		}
	}
	mut library := Library{}
	library.roots['vlib'] = lib.vroot
	if lib.vmodules != '' {
		library.roots['vmodules'] = lib.vmodules
	}
	// the graph keeps only some of a library file's declarations, so get_body could
	// not find where one ends from the next one kept: its end is found now, from all
	mut kept := []Symbol{}
	mut done := map[string]bool{}
	for s in lib_syms {
		if keep[s.id] && !done[s.id] {
			done[s.id] = true
			kept << by_id[s.id]
		}
	}
	library.symbols = with_body_ends(kept, lib_syms, library)
	g.library = library
	g.symbols = g.symbols[..project_len].clone()
	g.edges = g.edges.filter(!in_library(it) || in_vmodules(it))
}

// with_body_ends gives each of `kept` the last line of its declaration as its
// end_line, found as get_body finds it, among `all` the declarations of its file.
fn with_body_ends(kept []Symbol, all []Symbol, library Library) []Symbol {
	mut lines_of := map[string][]string{}
	mut out := []Symbol{cap: kept.len}
	for s in kept {
		if s.file !in lines_of {
			path := library.path_of(s.file) or { '' }
			src := os.read_file(path) or { '' }
			lines_of[s.file] = src.replace('\r\n', '\n').split('\n')
		}
		lines := lines_of[s.file] or { []string{} }
		mut t := s
		t.end_line = decl_end(lines, s, all)
		out << t
	}
	return out
}

// Options controls a graph build.
pub struct Options {
pub:
	root       string // directory (or single file) to analyze
	with_calls bool = true // record call edges between functions
}

// build_graph walks `opts.root`, parses every `.v` file, and returns the
// assembled Graph.
pub fn build_graph(opts Options) Graph {
	root := os.real_path(opts.root)
	mut g := Graph{
		root:        root
		file_hashes: map[string]string{}
	}

	files := if os.is_dir(root) {
		find_source_files(root)
	} else {
		[root]
	}

	for path in files {
		rel := rel_path(root, path)
		syms, edges := extract_v_file(path, rel)
		h := source_hash(path)
		if h != '' {
			g.file_hashes[rel] = h
		}

		g.symbols << syms
		if opts.with_calls {
			g.edges << edges
		} else {
			for e in edges {
				if e.kind != .calls {
					g.edges << e
				}
			}
		}
	}

	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	return g
}

// disambiguate_ids gives colliding declarations their own distinct node
// identity before resolve_edges runs, so Index.by_id (and everything built
// on it -- query/explain/get_node/communities/GraphML/Cypher) stops
// silently collapsing them into one. Uses the exact same classification
// resolve_edges' `unaddressable` check already does -- an id names more
// than one real declaration only when they sit in separate *build units*
// that happen to share a module name: every standalone `main` program, and
// every `_test.v` file, which V compiles as its own executable. Repeats
// inside an ordinary module cannot be distinct declarations -- V would
// reject the redeclaration -- so those are left untouched (they are one
// logical declaration, e.g. a per-platform variant like `os.setenv` in
// both environment.c.v and environment.js.v).
//
// Colliding declarations are renamed to `${id}@${file}` -- file-qualified,
// so provably unique for any two declarations V would actually accept as
// distinct. This can't be done correctly by retroactively rewriting an
// already-flattened Graph: several declarations share the *same* old id
// (that is the collision), so a bare find-and-replace can't tell which
// edge belongs to which one. Symbols carry their own `file`, so renaming
// them is unambiguous; edges historically didn't, which is what Edge.file
// exists for -- see its doc comment in model.v.
//
// Known residual, confirmed on the real V compiler repo (4 ids / 8 of
// 107,134 symbols -- 0.004%): a `fn C.foo(...)` or `fn JS.foo(...)` extern
// declaration and a same-named real V wrapper function in the *same* file
// (e.g. `fn C.get_string_array() ...` next to `pub fn get_string_array()
// { return C.get_string_array() }`) still collide, since fn_id's
// `short_name` doesn't preserve the `C.`/`JS.` prefix -- a `@file` suffix
// can't separate two declarations that share a file. Root-caused, not
// silently unexplained; a real fix belongs in fn_id (extraction), not
// here, since this function only disambiguates by build unit, and these
// two declarations are already in the same one.
// regenerate_defines replaces every `defines` edge with one built from the
// symbols' current parent and id.
fn regenerate_defines(mut g Graph) {
	mut rest := []Edge{cap: g.edges.len}
	for e in g.edges {
		if e.kind != .defines {
			rest << e
		}
	}
	for s in g.symbols {
		if s.parent != '' && s.kind != .import_ {
			rest << Edge{
				from: s.parent
				to:   s.id
				kind: .defines
			}
		}
	}
	g.edges = rest
}

// main_unit_files returns the files that declare `module main` (or no module),
// read from their module symbol's signature. Module ids are built from the
// directory (see module_id in backend_common.v), so `cmd/tools/vself.v` has the
// parent `cmd.tools` although it is a standalone program like every other
// file there; only the declaration says so.
fn main_unit_files(g Graph) map[string]bool {
	mut m := map[string]bool{}
	for s in g.symbols {
		if s.kind == .mod_ && s.signature == 'module main' {
			m[s.file] = true
		}
	}
	return m
}

// in_main_unit reports whether `s` belongs to a standalone program. A parent
// of `main` covers a file with no directory, whose module id falls back to the
// declared name.
fn in_main_unit(s Symbol, mains map[string]bool) bool {
	return s.parent == 'main' || mains[s.file]
}

// separate_member_ids gives a field or const whose id is also another kind of
// symbol's id an id of its own, `<parent>::field::<name>` or
// `<parent>::const::<name>`, in the form import ids already use. V lets a
// method share its name with a field of its receiver type (`Server.username`
// in vlib/crypto/scram is both) and a const share its name with a function, and
// both used to come out as one id, so a `calls` edge to the method pointed as
// much at the field. The function, method or type keeps the plain id because
// edges point at it; fields and consts are only ever reached by their
// `defines` edge, which is rebuilt here.
fn separate_member_ids(mut g Graph) {
	mut other := map[string]bool{}
	for s in g.symbols {
		if s.kind != .field && s.kind != .constant {
			other[s.id] = true
		}
	}
	mut renamed := false
	for i in 0 .. g.symbols.len {
		s := g.symbols[i]
		if (s.kind == .field || s.kind == .constant) && other[s.id] {
			g.symbols[i].id = '${s.parent}::${s.kind}::${s.name}'
			renamed = true
		}
	}
	if renamed {
		regenerate_defines(mut g)
	}
}

// import_reaches reports whether an import of `imported` (the path as written,
// e.g. `v.ast`) can name the module with directory id `mod_id` (e.g.
// `vlib.v.ast`). Ids carry the path from the graph root, while an import is
// relative to a module root that differs between projects, so this matches the
// trailing segments. Where that leaves more than one module visible (`import
// rand` matches `vlib.rand` and `vlib.crypto.rand`), the callers' only_id finds
// several ids and resolves nothing rather than guessing.
fn import_reaches(mod_id string, imported string) bool {
	return mod_id == imported || mod_id.ends_with('.' + imported)
}

// import_names reports whether an import resolved to `imported` names the
// module `mod_id` exactly. resolve_import (backend_common.v) records the path
// from vlib, or from the graph root, so `import wasm` is `vlib.wasm` and not
// also `vlib.v.gen.wasm`, which import_reaches can't tell apart.
fn import_names(mod_id string, imported string) bool {
	return mod_id == imported || mod_id == 'vlib.' + imported
}

// exact_calls keeps the candidates `imported` names exactly (import_names),
// when there are any and they leave out others.
fn exact_calls(cands []CallCand, imported string) []CallCand {
	exact := cands.filter(import_names(it.mod, imported))
	return if exact.len > 0 { exact } else { cands }
}

// exact_types is exact_calls for type declarations.
fn exact_types(cands []TypeCand, imported string) []TypeCand {
	exact := cands.filter(import_names(it.mod, imported))
	return if exact.len > 0 { exact } else { cands }
}

// test_private reports whether a declaration in `decl_file` is hidden from code
// in `caller_file`: V compiles each `_test.v` file as its own program, so what
// one declares is visible only inside it. Without this, an `enum Color` in
// vlib/builtin/map_test.v counted as part of builtin and was visible from
// every file in the repo.
fn test_private(decl_file string, caller_file string) bool {
	return decl_file.ends_with('_test.v') && decl_file != caller_file
}

// visible_from reports whether a declaration in module `mod` can be reached
// from a file in `caller`'s module that imports `imports`: V's visibility rule
// of own module, imports, and the auto-imported builtin.
fn visible_from(mod string, caller DeclSite, imports []string) bool {
	if import_reaches(mod, 'builtin') {
		return true
	}
	for imp in imports {
		if import_reaches(mod, imp) {
			return true
		}
	}
	return mod == caller.mod && (!caller.is_main || caller.solo)
}

fn disambiguate_ids(mut g Graph) {
	kinds := [SymbolKind.function, .method, .struct_, .enum_, .interface_, .type_alias]
	mains := main_unit_files(g)
	mut id_count := map[string]int{}
	mut id_main := map[string]bool{}
	mut id_files := map[string][]string{}
	for s in g.symbols {
		if s.kind in kinds {
			id_count[s.id]++
			if in_main_unit(s, mains) {
				id_main[s.id] = true
			}
			id_files[s.id] << s.file
		}
	}
	mut collides := map[string]bool{}
	for id, n in id_count {
		if n < 2 {
			continue
		}
		if id_main[id] {
			collides[id] = true
			continue
		}
		mut tests := []string{}
		for f in id_files[id] or { []string{} } {
			if f.ends_with('_test.v') && f !in tests {
				tests << f
			}
		}
		if tests.len > 1 {
			collides[id] = true
		}
	}
	if collides.len == 0 {
		return
	}

	// Rename the colliding declarations themselves -- unambiguous, since
	// each Symbol carries its own file. renamed_at keeps which (id, file)
	// was renamed, for the edges below.
	mut renamed_at := map[string]bool{}
	for i in 0 .. g.symbols.len {
		s := g.symbols[i]
		if s.kind in kinds && collides[s.id] {
			g.symbols[i].id = '${s.id}@${s.file}'
			renamed_at[site_key(s.id, s.file)] = true
		}
	}
	// Cascade to field symbols, whose id/parent embed their struct's old id
	// as a literal prefix (fields aren't in `kinds` above -- a field's own
	// bare id never collides on its own -- but they must move with their
	// struct). Reads s.parent before this loop's own writes touch it, since
	// fields were untouched by the rename above.
	for i in 0 .. g.symbols.len {
		s := g.symbols[i]
		if s.kind == .field && collides[s.parent] {
			new_parent := '${s.parent}@${s.file}'
			old_prefix := s.parent + '.'
			if s.id.starts_with(old_prefix) {
				g.symbols[i].id = new_parent + '.' + s.id[old_prefix.len..]
			}
			g.symbols[i].parent = new_parent
		}
	}

	// `defines` edges are redundant with each symbol's own parent/id field,
	// so once those are renamed, the simplest correct move is to discard
	// the old edges (still holding pre-rename ids) and regenerate them from
	// the now-current symbol data, rather than trying to retroactively
	// patch them -- they have the same which-declaration-does-this-edge-
	// belong-to ambiguity as calls/embeds/references, just without an
	// Edge.file to resolve it, since regenerating is exact and just as
	// cheap here.
	regenerate_defines(mut g)

	// calls/embeds/references edges' `from` is the id of the declaration
	// that emitted them -- rename it the same way, using Edge.file (which
	// symbols don't need, since they carry `file` directly) to know which
	// of the several now-differently-renamed declarations a given edge
	// actually belongs to. Edge's fields are all `pub:` (read-only), so a
	// changed edge is a new value, same as resolve_edges builds below. Only
	// a renamed declaration's edges move: a global that shares a colliding
	// function's id keeps its id, and its edges keep it too.
	mut with_from_renamed := []Edge{cap: g.edges.len}
	for e in g.edges {
		if (e.kind == .calls || e.kind == .embeds || e.kind == .references)
			&& renamed_at[site_key(e.from, e.file)] {
			with_from_renamed << Edge{
				...e
				from: '${e.from}@${e.file}'
			}
		} else {
			with_from_renamed << e
		}
	}
	g.edges = with_from_renamed
}

// only_id returns the id that every candidate shares, or none if they disagree.
// Counting candidates would call a name ambiguous whenever a function is
// declared once per platform — `os.setenv` exists in both environment.c.v and
// environment.js.v — even though those are one logical function that the id
// addresses perfectly well. What matters is how many distinct *ids* remain,
// not how many symbols.
fn only_id(cands []CallCand) ?string {
	if cands.len == 0 {
		return none
	}
	id := cands[0].id
	for c in cands[1..] {
		if c.id != id {
			return none
		}
	}
	return id
}

// CallCand is one declaration that a raw callee name could refer to.
struct CallCand {
	id        string
	is_method bool
	mod       string // module the declaration lives in
	file      string
}

// DeclSite is where a declaration lives, used to score candidates by locality.
struct DeclSite {
	mod     string
	file    string
	is_main bool // in a standalone program, see main_unit_files
	// solo is set when the module's only `fn main` is this one's: the module
	// is one program, so its files are one another's module (see resolve_edges)
	solo bool
	// no_main is set when the module has no `fn main` at all: a directory of
	// translated or test files, built together. Only a type alias's lookup
	// (alias_conversion) takes the module as one program for this.
	no_main bool
}

// TypeCand is one declaration that a raw type name (on an `embeds` or
// `references` edge) could refer to.
struct TypeCand {
	id   string
	mod  string
	file string
	// c is set for a C struct, `struct C.name` (see extract_struct)
	c bool
	// js is set for a JS binding type, `interface JS.name` or `struct JS.name`
	js bool
}

// declares_host reports whether the candidate declares a type of the host
// `C` or `JS` names: a C struct, a C type `type C.name` (whose id is
// `C.name`), or a JS binding type.
fn (c TypeCand) declares_host(host string) bool {
	return if host == 'C' { c.c || c.id.starts_with('C.') } else { c.js }
}

// only_type_id is only_id's counterpart for TypeCand -- V has no lightweight
// way to share one generic across both without an interface, and two
// three-line loops are cheaper to read than that indirection.
fn only_type_id(cands []TypeCand) ?string {
	if cands.len == 0 {
		return none
	}
	id := cands[0].id
	for c in cands[1..] {
		if c.id != id {
			return none
		}
	}
	return id
}

// CallResolution is what resolve_callee found for one call edge: which
// declaration it refers to, and whether picking it needed more than a name
// (see resolve_callee's doc comment for which steps set `inferred`).
struct CallResolution {
	id       string
	inferred bool
	// undeclared: the call has no declaration to resolve to (see
	// EdgeProvenance), and `id` is empty
	undeclared bool
}

// resolve_edges turns raw names into symbol ids where a single matching
// declaration can be identified: callee names on `calls` edges (via
// resolve_callee), and type names on `embeds`/`references` edges (via
// resolve_type_ref). Names that stay ambiguous are left as-is, so the caller
// can still see external/unknown/undecided references.
// resolve_initializer_callers gives each call in a constant's, global's or
// struct field's initializer the declaration's final id. That id is set by
// disambiguate_ids and separate_member_ids, after extraction, so the caller is
// keyed by initializer_from until now. A call whose declaration isn't in the
// graph is dropped rather than left pointing at nothing.
fn resolve_initializer_callers(mut g Graph) {
	mut final_id := map[string]string{}
	for s in g.symbols {
		if s.kind in [SymbolKind.constant, .global, .field] {
			final_id[initializer_from(s.kind, s.file, s.line, s.name)] = s.id
		}
	}
	mut out := []Edge{cap: g.edges.len}
	for e in g.edges {
		if !e.from.starts_with('init\x00') {
			out << e
			continue
		}
		id := final_id[e.from] or { continue }
		out << Edge{...e, from: id}
	}
	g.edges = out
}

fn resolve_edges(mut g Graph) {
	resolve_initializer_callers(mut g)
	mut by_name := map[string][]CallCand{}
	// const_calls holds the constants by name: a constant that holds a function is
	// called as one, and it is the fallback when no function of that name fits (see infer_call)
	mut const_calls := map[string][]CallCand{}
	mut by_type_name := map[string][]TypeCand{}
	// type aliases by name, for a bare call of one (see alias_conversion)
	mut alias_by_name := map[string][]TypeCand{}
	// enum_names holds each enum by module and name, to recognise V's own zero()
	// on a flag enum (see below).
	mut enum_names := map[string]bool{}
	// flag_here says whether an enum is a @[flag] one, in its own file; flag_in_mod says
	// whether every enum of that name in a module is (see is_flag_enum)
	mut flag_here := map[string]bool{}
	mut flag_in_mod := map[string]bool{}
	// sym_ids holds every symbol id, to see whether an enum declares a method
	mut sym_ids := map[string]bool{}
	// c_declared holds the names of the C functions the program binds (`fn C.name`)
	mut c_declared := map[string]bool{}
	// a field's parent is its struct or interface, so each maps to its own module,
	// which is the field's (decl_mod)
	mut struct_mod := map[string]string{}
	for s in g.symbols {
		sym_ids[s.id] = true
		if (s.kind == .function || s.kind == .type_alias) && s.id.starts_with('C.') {
			c_declared[s.id.all_before('@')] = true
		}
		if s.kind == .enum_ {
			enum_names[s.parent + '\x00' + s.name] = true
			flagged := s.signature.starts_with('@[flag]')
			flag_here[s.parent + '\x00' + s.name + '\x00' + s.file] = flagged
			flag_in_mod[s.parent + '\x00' + s.name] = (flag_in_mod[s.parent + '\x00' + s.name] or { true }) && flagged
		}
		if s.kind in [SymbolKind.struct_, .interface_] {
			struct_mod[s.id] = s.parent
		}
	}
	// a module with exactly one `fn main` is one program, whose files see each
	// other as one module; a module with several has a program per `main`
	mut main_count := map[string]int{}
	for s in g.symbols {
		if s.kind == .function && s.name == 'main' && s.parent != '' {
			main_count[s.parent]++
		}
	}
	mut site_of := map[string]DeclSite{}
	mut id_count := map[string]int{}
	mains := main_unit_files(g)
	mut id_main := map[string]bool{}
	mut id_files := map[string][]string{}
	// id_kind is the kind of an id's first declaration, and id_mixed is set when another
	// is of a different kind: such copies are different declarations wherever they are
	mut id_kind := map[string]SymbolKind{}
	mut id_mixed := map[string]bool{}
	mut imports_of := map[string][]string{} // file -> modules it imports
	mut scope_of := map[string]FileScope{} // file -> what a callee prefix can name
	for s in g.symbols {
		// an import the parser implies (`sync` for a channel) is a dependency,
		// but the file can't name anything through it, so it widens neither
		// what a call may resolve to nor what a prefix means
		if s.kind == .import_ && !s.signature.ends_with('(implied)') {
			imports_of[s.file] << s.name
			mut sc := scope_of[s.file] or { FileScope{} }
			sc.prefixes[s.name] = s.name
			// the alias and the path as written are only on the signature:
			// `import x.json2 as json`, and `from x.json2` when the path redirects
			if s.signature.contains(' as ') {
				sc.prefixes[s.signature.all_after(' as ').all_before(' from ')] = s.name
			}
			if s.signature.contains(' from ') {
				sc.prefixes[s.signature.all_after(' from ')] = s.name
			}
			scope_of[s.file] = sc
		}
		if s.kind == .mod_ {
			mut sc := scope_of[s.file] or { FileScope{} }
			sc.mod = s.id
			sc.declared = s.signature.all_after('module ')
			sc.is_main = in_main_unit(s, mains)
			scope_of[s.file] = sc
		}
		if s.kind == .function || s.kind == .method {
			// a C binding is reached only as `C.name(...)`, so it is indexed under that
			// name, where a bare `name(...)` does not find it
			key := if s.id.starts_with('C.') { 'C.' + s.name } else { s.name }
			by_name[key] << CallCand{
				id:        s.id
				is_method: s.kind == .method
				mod:       s.parent // fn/method symbols hang off their module
				file:      s.file
			}
		}
		// a constant of a literal's type (`const sys_write = 1`, recipe `t:int`) is no
		// function, so a call of its name is some other function's
		if s.kind == .constant && !s.recipe.starts_with('t:') {
			const_calls[s.name] << CallCand{
				id:   s.id
				mod:  s.parent
				file: s.file
			}
		}
		if s.kind == .type_alias && s.id.starts_with('C.') {
			// a C type is reached only as `C.name(x)`, a conversion, so it is indexed
			// under that name, as a C function is (see c_binding_callee)
			by_name['C.' + s.name] << CallCand{
				id:   s.id
				mod:  s.parent
				file: s.file
			}
		}
		if s.kind == .type_alias && !s.id.starts_with('C.') {
			alias_by_name[s.name] << TypeCand{
				id:   s.id
				mod:  s.parent
				file: s.file
			}
		}
		if s.kind in [SymbolKind.struct_, .enum_, .interface_, .type_alias] {
			by_type_name[s.name] << TypeCand{
				id:   s.id
				mod:  s.parent
				file: s.file
				c:    s.signature.contains('struct C.')
				js:   s.signature.contains('interface JS.') || s.signature.contains('struct JS.')
			}
		}
		// site_of answers "where does this edge's `from` live", so it only
		// needs the kinds the extractor actually emits calls/embeds/references
		// edges from: fn/method (calls, and param/receiver/return-type
		// references), struct (field-type references and embeds), interface
		// (embeds), type alias (the types it is built from), and constant, global
		// and field (the calls in their initializers). Enums are only ever a `to`.
		if s.kind in [SymbolKind.function, .method, .struct_, .interface_, .type_alias, .constant, .global, .field] {
			mod := decl_mod(s, struct_mod)
			site_of[s.id] = DeclSite{
				mod:     mod
				file:    s.file
				is_main: in_main_unit(s, mains)
				solo:    main_count[mod] == 1
				no_main: main_count[mod] == 0
			}
		}
		// id_count/id_main/id_files feed the build-unit-aware duplicate check
		// below. It is shared, unqualified by kind, across every kind that
		// can be a resolution target (calls' fn/method ids and type refs'
		// struct/enum/interface/type_alias ids alike) rather than kept as
		// parallel per-kind maps: an id colliding *across* kinds would need a
		// function and a type to share an identifier in the same module,
		// which V's own naming rules make vanishingly rare, and the failure
		// mode of treating it as ambiguous anyway is losing one edge that
		// could have resolved, not resolving one wrong — the same
		// precision-over-recall direction this whole pass already takes.
		if s.kind in [SymbolKind.function, .method, .struct_, .enum_, .interface_, .type_alias] {
			id_count[s.id]++
			if in_main_unit(s, mains) {
				id_main[s.id] = true
			}
			id_files[s.id] << s.file
			if k := id_kind[s.id] {
				if k != s.kind {
					id_mixed[s.id] = true
				}
			} else {
				id_kind[s.id] = s.kind
			}
		}
	}
	// An id names more than one real function only when its declarations sit in
	// separate *build units* that happen to share a module name: every
	// standalone `main` program, and every `_test.v` file, which V compiles as
	// its own executable. Repeats inside one ordinary module cannot be distinct
	// functions — V would reject the redeclaration — so they are per-platform
	// variants (`os.setenv` in environment.c.v and environment.js.v) that the
	// shared id addresses correctly.
	mut unaddressable := map[string]bool{}
	for id, n in id_count {
		// a C binding's id names one C function, however many files declare it (C has
		// one namespace), so the copies are one function, not separate programs
		if n < 2 || id.starts_with('C.') {
			continue
		}
		files := id_files[id] or { []string{} }
		if id_main[id] {
			// copies of one kind in one file are one declaration in each branch of a
			// top-level `$if`, as copies in an ordinary module's files are one per platform;
			// disambiguate_ids leaves them one id, as it can't tell them apart by file
			if !id_mixed[id] && files.all(it == files[0]) {
				continue
			}
			unaddressable[id] = true
			continue
		}
		mut tests := []string{}
		for f in files {
			if f.ends_with('_test.v') && f !in tests {
				tests << f
			}
		}
		if tests.len > 1 {
			unaddressable[id] = true
		}
	}
	// Ids are not unique across a repo: every standalone program declares
	// `main.main`, so one id can name thousands of unrelated declarations.
	// Such an id pins down no single location, and guessing one would invent
	// edges between unrelated files — drop them so locality is only ever
	// applied to a caller whose position is actually known.
	for id, n in id_count {
		if n > 1 {
			site_of.delete(id)
		}
	}
	// An id repeated within one module names per-platform variants of one
	// function (see above), and a call edge says which file it is in, so
	// that variant's location is known: keyed by id and file (site_key). The
	// same holds for a type declared once per platform (`gg.Config` in gg.c.v
	// and gg.js.v), whose references say their file too, and for an id that
	// can't address one declaration but whose copies are all in one file (a
	// function in each branch of a top-level `$if` in a test).
	for s in g.symbols {
		if s.kind in [SymbolKind.function, .method, .struct_, .interface_, .type_alias]
			&& id_count[s.id] > 1
			&& (!unaddressable[s.id] || (id_files[s.id] or { []string{} }).all(it == s.file)) {
			mod := decl_mod(s, struct_mod)
			site_of[site_key(s.id, s.file)] = DeclSite{
				mod:     mod
				file:    s.file
				is_main: in_main_unit(s, mains)
				solo:    main_count[mod] == 1
				no_main: main_count[mod] == 0
			}
		}
	}
	mut sig_of := map[string]string{}
	mut fn_names := map[string]string{}
	mut field_type := map[string]string{}
	mut alias_of := map[string]string{}
	// alias id -> each type it names, in the order of its declarations: more than
	// one for an alias each build declares in its own file (`ssl.SSLConn`)
	mut alias_targets := map[string][]string{}
	// each type such an alias names -> the build of the declarations that name it
	mut target_build := map[string]string{}
	mut sum_variants := map[string][]string{}
	mut embeds_of := map[string][]Edge{}
	mut field_ids := map[string]string{}
	mut fields_of := map[string][]string{}
	mut consts := map[string][]Symbol{}
	mut enum_ids := map[string]bool{}
	mut dynamic_ids := map[string]bool{}
	mut iface_ids := map[string]bool{}
	mut generics_of := map[string][]string{}
	mut tparams_of := map[string][]string{}
	for e in g.edges {
		if e.kind == .embeds {
			embeds_of[e.from] << e
		}
	}
	for s in g.symbols {
		match s.kind {
			.struct_ {
				if s.recipe != '' {
					generics_of[s.id] = s.recipe.split(',')
				}
			}
			.function, .method {
				sig_of[s.id] = s.signature
				fn_names[s.id] = s.name
				if s.recipe != '' {
					generics_of[s.id] = s.recipe.split(',')
				}
				if s.tparams != '' {
					tparams_of[s.id] = s.tparams.split(',')
				}
			}
			.field {
				field_type['${s.parent}\x00${s.name}'] = s.signature.all_after(' ')
				field_ids['${s.parent}\x00${s.name}'] = s.id
				fields_of[s.parent] << s.name
			}
			.constant, .global {
				if s.recipe != '' {
					consts[s.name] << s
				}
			}
			.enum_ {
				enum_ids[s.id] = true
			}
			.type_alias {
				rhs := s.signature.all_after(' = ')
				if rhs.contains(' | ') {
					dynamic_ids[s.id] = true
					sum_variants[s.id] = rhs.split('|').map(it.trim_space())
				} else {
					alias_of[s.id] = rhs
					if rhs !in alias_targets[s.id] {
						alias_targets[s.id] << rhs
					}
					target := strip_generic_args(bare_type(rhs))
					target_build[target] = if b := target_build[target] {
						either_build(b, s.build)
					} else {
						s.build
					}
				}
			}
			.interface_ {
				dynamic_ids[s.id] = true
				iface_ids[s.id] = true
			}
			else {}
		}
	}
	mut inf := Infer{
		by_name:      by_name
		const_calls:  const_calls
		by_type_name: by_type_name
		site_of:      site_of
		imports_of:   imports_of
		scope_of:     scope_of
		sig_of:       sig_of
		name_of:      fn_names
		field_type:   field_type
		alias_of:     alias_of
		sum_variants: sum_variants
		embeds_of:    embeds_of
		field_id:     field_ids
		fields_of:    fields_of
		consts:       consts
		enum_ids:     enum_ids
		dynamic_ids:  dynamic_ids
		iface_ids:    iface_ids
		generics_of:  generics_of
		tparams_of:   tparams_of
	}
	// a comptime-narrowed type parameter is settled now that the interfaces are known (see
	// comptime_recipe), before any edge is followed, the expansion's sources included
	for i in 0 .. g.edges.len {
		e := g.edges[i]
		if e.recv_recipe.contains('ctp:') || e.arg_sites.contains('ctp:') {
			g.edges[i] = Edge{
				...e
				recv_recipe: inf.comptime_recipe(e.recv_recipe, e.file)
				arg_sites:   inf.comptime_sites(e.arg_sites, e.file)
			}
		}
	}
	mut builds := build_worlds(inf, alias_targets, g.symbols)
	// the build a call that comes out differently in another world needs: that of the
	// alias declarations that name its callee's type, `use_openssl ?` for
	// `openssl.SSLConn.dial` through `ssl.SSLConn`
	// (the type's id may have a label before the module the alias names it by:
	// `vlib.net.openssl.SSLConn`)
	world_build := fn [target_build] (e Edge, id string) string {
		owner := id.all_before('@').all_before_last('.')
		for target, b in target_build {
			if owner == target || owner.ends_with('.' + target) {
				return join_build(e.build, b)
			}
		}
		return e.build
	}
	mut resolved := []Edge{cap: g.edges.len}
	// variants_of maps each platform copy of a function or method to all of its
	// copies: the same id before the `@file`, in the same module.
	mut copies := map[string][]string{}
	for s in g.symbols {
		if s.kind in [SymbolKind.function, .method] && s.id.contains('@') && is_platform_file(s.file) {
			copies[s.id.all_before('@')] << s.id
		}
	}
	mut variants_of := map[string][]string{}
	for _, ids in copies {
		if ids.len > 1 {
			for id in ids {
				variants_of[id] = ids
			}
		}
	}
	// record_call keeps one edge per callee and receiver, so two raw edges
	// can resolve to the same declaration; keep one, `extracted` if either is
	mut seen_call := map[string]int{}
	for e in g.edges {
		if e.kind == .calls {
			// Refuse an id that cannot address one function (see above): an
			// edge to it would send every consumer to whichever declaration
			// happened to be indexed first. The raw name is honestly
			// ambiguous rather than falsely precise.
			if e.provenance == .undeclared {
				// a call of a function value, found at extraction
				key := '${e.from}\x00${e.to}'
				if at := seen_call[key] {
					add_lines(mut resolved, at, e)
				} else {
					seen_call[key] = resolved.len
					resolved << e
				}
				continue
			}
			// what the call is in a build that takes another side of an alias
			// (build_worlds), where that differs from what it is here
			here := inf.infer_call(e)
			mut in_builds := []CallResolution{}
			// a call on any field that infer_call left to expand_type_param_calls is not one
			// to link through another build's name match first
			deferred := e.is_method && has_field_any(e.recv_recipe) && here == none
			if e.is_method && e.to in builds.methods && !deferred {
				in_builds = builds.infer_call(e, here)
			}
			if in_builds.len > 0 && (here or { CallResolution{
				undeclared: true
			} }).undeclared {
				// only another build has the method
				for r in in_builds {
					if !unaddressable[r.id] {
						add_resolved_call(mut resolved, mut seen_call, Edge{
							...e
							build: world_build(e, r.id)
						}, r)
					}
				}
				continue
			}
			if res := here {
				if res.undeclared {
					key := '${e.from}\x00${e.to}'
					if at := seen_call[key] {
						add_lines(mut resolved, at, e)
					} else {
						seen_call[key] = resolved.len
						resolved << Edge{
							...e
							provenance: .undeclared
						}
					}
					continue
				}
				if !unaddressable[res.id] {
					for r in in_builds {
						if !unaddressable[r.id] {
							add_resolved_call(mut resolved, mut seen_call, Edge{
								...e
								build: world_build(e, r.id)
							}, r)
						}
					}
					// here's build too, when another world has a call of its own
					he := if in_builds.len > 0 {
						Edge{
							...e
							build: world_build(e, res.id)
						}
					} else {
						e
					}
					// a call that reaches one platform's copy of a function reaches every copy
					for id in variants_of[res.id] or { [res.id] } {
						key := '${e.from}\x00${id}'
						if at := seen_call[key] {
							add_lines(mut resolved, at, he)
							if !res.inferred && resolved[at].provenance == .inferred {
								resolved[at] = Edge{
									...resolved[at]
									provenance: .extracted
								}
							}
							continue
						}
						seen_call[key] = resolved.len
						resolved << Edge{
							from:       e.from
							to:         id
							kind:       .calls
							is_method:  e.is_method
							provenance: if res.inferred { .inferred } else { .extracted }
							file:       e.file
							arg_sites:  e.arg_sites
							lines:      e.lines
							build:      he.build
						}
					}
					continue
				}
			}
			if variants := platform_variants(e, by_name, site_of) {
				for v in variants {
					key := '${e.from}\x00${v.id}'
					if at := seen_call[key] {
						add_lines(mut resolved, at, e)
					} else {
						seen_call[key] = resolved.len
						resolved << Edge{
							from:       e.from
							to:         v.id
							kind:       .calls
							is_method:  e.is_method
							provenance: .inferred
							file:       e.file
							arg_sites:  e.arg_sites
							lines:      e.lines
							build:      e.build
						}
					}
				}
				continue
			}
		}
		if e.kind == .embeds || e.kind == .references {
			// Same refusal as above, generalized to type ids: a struct named
			// `Config` in one standalone `main` program is not the `Config`
			// referenced by an unrelated one.
			if res := resolve_type_ref(e, by_type_name, site_of, imports_of) {
				if !unaddressable[res.id] {
					resolved << Edge{
						from:       e.from
						to:         res.id
						kind:       e.kind
						provenance: if res.inferred { .inferred } else { .extracted }
						file:       e.file
	arg_sites:  e.arg_sites
					}
					continue
				}
			}
			// a C or JS type that no `struct C.`, `type C.` or `JS.` declaration
			// names is in a system header or the JS host, as an unbound C function
			// is; one that is declared but doesn't resolve stays unresolved
			if host_type_undeclared(e.to, by_type_name) {
				resolved << Edge{...e, provenance: .undeclared}
				continue
			}
		}
		if e.kind == .calls {
			mut key := call_key(e)
			// a call on any field of a type keeps its receiver until expand_type_param_calls
			// links it, so `k.str()` and `v.str()` in one field loop stay apart
			if e.is_method && has_field_any(e.recv_recipe) {
				key += '\x00' + e.recv_recipe
			}
			if at := seen_call[key] {
				add_lines(mut resolved, at, e)
				continue
			}
			seen_call[key] = resolved.len
		}
		// a bare call of a type alias is a conversion to it: `uintptr_t(x)` under
		// `type uintptr_t = usize`. Only the aliases the caller can see count (see
		// alias_conversion), and a method call is never one.
		if e.kind == .calls && !e.is_method && !e.to.contains('.') {
			if id := alias_conversion(e, alias_by_name, site_of, imports_of) {
				if !unaddressable[id] {
					resolved << Edge{
						from:       e.from
						to:         id
						kind:       .calls
						provenance: .inferred
						lines:      e.lines
						build:      e.build
					}
					continue
				}
			}
		}
		if e.kind == .calls && (e.to.ends_with('__static__zero') || e.to.ends_with('__static__from')
			|| e.to.ends_with('__static__from_string')) {
			// V generates `T.zero()` for a @[flag] enum T, and `T.from(x)` and
			// `T.from_string(s)` for every enum T. A call of one of them, to an enum T in
			// the caller's module that declares no method of that name, is one V provides.
			if site := caller_site(e, site_of) {
				mod := site.mod
				typ := e.to.all_before('__static__')
				method := e.to.all_after('__static__')
				if enum_names[mod + '\x00' + typ] && '${mod}.${typ}.${method}' !in sym_ids
					&& (method != 'zero' || (flag_here[mod + '\x00' + typ + '\x00' + site.file] or { flag_in_mod[mod + '\x00' + typ] or { false } })) {
					resolved << Edge{...e, provenance: .undeclared}
					continue
				}
			}
		}
		// the runtime helpers V's bare builtin declares in its own source, which the
		// default build doesn't compile, and the arena hooks it calls through: a call of
		// one that no program declaration resolves is into the runtime, not the program
		if e.kind == .calls && e.to in runtime_helpers {
			resolved << Edge{...e, provenance: .undeclared}
			continue
		}
		// a call of a C function the program binds nowhere (`C.close`, `C.memcpy`) is one a
		// system header declares, the same as a runtime helper; a binding that exists but
		// does not resolve (two copies that differ) is still unresolved
		if e.kind == .calls && e.to.starts_with('C.') && e.to.count('.') == 1 && e.to !in c_declared {
			resolved << Edge{...e, provenance: .undeclared}
			continue
		}
		// a bare call in a method that no function of the module has is the receiver's
		// method of that name, which V calls without the receiver (`describe(b.value)`)
		if e.kind == .calls && !e.is_method && !e.to.contains('.') {
			if id := implicit_receiver_call(e, by_name) {
				resolved << Edge{...e, to: id, is_method: true, provenance: .inferred}
				continue
			}
		}
		resolved << e
	}
	// a method call on a type parameter is linked to the methods of the types its
	// generic function, or its generic struct, is instantiated with (generics.v); only
	// functions and methods with type parameters carry a recipe
	mut generic_funcs := map[string]Symbol{}
	mut generic_fields := []Symbol{}
	for s in g.symbols {
		if (s.kind == .function || s.kind == .method || s.kind == .struct_) && s.recipe != '' {
			generic_funcs[s.id] = s
		}
		if s.kind == .field && s.signature.contains('[') {
			generic_fields << s
		}
	}
	g.edges = expand_type_param_calls(resolved, g.edges, generic_fields, mut inf, generic_funcs,
		unaddressable, variants_of)
}

// BuildWorlds is how resolve_edges sees the builds that take another side of an
// alias declared once per build: `ssl.SSLConn` is `mbedtls.SSLConn` in
// ssl_notd_use_openssl.v and `openssl.SSLConn` in ssl_d_use_openssl.v, one id that
// Infer reads as one of them. Each world is an Infer whose aliases name another of
// their types, so a call through one, `conn.connect()` on an `&ssl.SSLConn`,
// reaches every build's method, while a call that never goes through the alias
// resolves as it does without it.
struct BuildWorlds {
	// methods are the names of the methods of the types such aliases name: only a
	// call of one of them can come out differently in another world
	methods map[string]bool
mut:
	worlds []Infer
}

// build_worlds makes a world for each further type the aliases name, the most any
// alias has, less the one `inf` takes (the type of its last declaration).
fn build_worlds(inf Infer, alias_targets map[string][]string, symbols []Symbol) BuildWorlds {
	mut most := 1
	mut owners := map[string]bool{}
	for _, targets in alias_targets {
		if targets.len < 2 {
			continue
		}
		if targets.len > most {
			most = targets.len
		}
		for t in targets {
			// a named type: `i32` against `usize` would send every `str()` here
			short := strip_generic_args(bare_type(t)).all_after_last('.')
			if short.len > 0 && short[0].is_capital() {
				owners[short] = true
			}
		}
	}
	if most == 1 {
		return BuildWorlds{}
	}
	mut methods := map[string]bool{}
	for s in symbols {
		if s.kind == .method && s.id.all_before('@').all_before_last('.').all_after_last('.') in owners {
			methods[s.name] = true
		}
	}
	mut worlds := []Infer{}
	for k in 1 .. most {
		mut alias_of := inf.alias_of.clone()
		for id, targets in alias_targets {
			if targets.len > 1 {
				alias_of[id] = targets[(targets.len - 1 + k) % targets.len]
			}
		}
		worlds << Infer{
			...inf
			alias_of: alias_of
			memo:     map[string]InferredType{}
		}
	}
	return BuildWorlds{
		methods: methods
		worlds:  worlds
	}
}

// infer_call is what the call `e` resolves to in the other worlds, where that is
// a declaration and not `here`, what it resolves to without them.
fn (mut b BuildWorlds) infer_call(e Edge, here ?CallResolution) []CallResolution {
	here_id := if r := here {
		if r.undeclared { '' } else { r.id }
	} else {
		''
	}
	mut out := []CallResolution{}
	for mut w in b.worlds {
		r := w.infer_call(e) or { continue }
		if r.undeclared || r.id == '' || r.id == here_id || out.any(it.id == r.id) {
			continue
		}
		out << CallResolution{
			...r
			inferred: true
		}
	}
	return out
}

// add_resolved_call links the call `e` to `r`, or adds its lines to the edge that
// already does.
fn add_resolved_call(mut resolved []Edge, mut seen_call map[string]int, e Edge, r CallResolution) {
	key := '${e.from}\x00${r.id}'
	if at := seen_call[key] {
		add_lines(mut resolved, at, e)
		return
	}
	seen_call[key] = resolved.len
	resolved << Edge{
		from:       e.from
		to:         r.id
		kind:       .calls
		is_method:  e.is_method
		provenance: if r.inferred { .inferred } else { .extracted }
		file:       e.file
		arg_sites:  e.arg_sites
		lines:      e.lines
		build:      e.build
	}
}

// implicit_receiver_call is the id of the method, of the struct the calling method
// belongs to, that a bare call of `name` in that method names. none when the caller
// is not a method, or the struct has no method of that name.
fn implicit_receiver_call(e Edge, by_name map[string][]CallCand) ?string {
	base := e.from.all_before('@')
	dot := base.last_index('.') or { return none }
	want := strip_generic_args(base[..dot]) + '.' + e.to
	for c in by_name[e.to] or { []CallCand{} } {
		if c.is_method && strip_generic_args(c.id.all_before('@')) == want {
			return c.id
		}
	}
	return none
}

// runtime_helpers are the names of V's runtime helpers, as the bare builtin declares
// them (vlib/builtin/*/libc_impl.v) and the arena builtin's hooks (arena_d_builtin_arena.c.v)
const runtime_helpers = ['__malloc', 'bare_print', 'bare_eprint', 'bare_panic', 'bare_backtrace', 'sys_write',
	'g_arena_alloc_hook', 'g_arena_realloc_hook', 'g_arena_owns_hook']

// site_key is where site_of keeps the location of one variant of an id that
// several files declare (see resolve_edges).
fn site_key(id string, file string) string {
	return '${id}\x00${file}'
}

// caller_site is where the declaration an edge comes from lives: its id's
// only declaration, or, for an id with per-platform variants, the one in the
// file the edge was found in.
// decl_mod is the module a declaration is in: its parent, or for a field, the
// parent of its struct or interface (`struct_mod`).
fn decl_mod(s Symbol, struct_mod map[string]string) string {
	return if s.kind == .field { struct_mod[s.parent] or { s.parent } } else { s.parent }
}

fn caller_site(e Edge, site_of map[string]DeclSite) ?DeclSite {
	if site := site_of[e.from] {
		return site
	}
	if e.file != '' {
		if site := site_of[site_key(e.from, e.file)] {
			return site
		}
	}
	return none
}

// platform_variants returns the declarations a call reaches when the callee
// is one function declared once per platform in the caller's own module, such
// as `open_dir` in `dir_nix.c.v` and `dir_windows.c.v`. A call can't say which
// platform runs it, and the graph must be the same on every platform, so the
// call links to every variant: each is a real declaration, and the call shows
// up for a change to any of them. Only renamed variants reach this point (see
// disambiguate_ids); variants sharing one id already resolve through only_id.
fn platform_variants(e Edge, by_name map[string][]CallCand, site_of map[string]DeclSite) ?[]CallCand {
	// Only plain calls: a method call's receiver type decides which declaration
	// it means, and this doesn't check it.
	if e.is_method {
		return none
	}
	cands := by_name[e.to] or { return none }
	caller := caller_site(e, site_of) or { return none }
	mut local := []CallCand{}
	for c in cands {
		if c.mod == caller.mod && !c.is_method {
			local << c
		}
	}
	if local.len < 2 {
		return none
	}
	base := local[0].id.split('@')[0]
	for c in local {
		if c.id.split('@')[0] != base || !is_platform_file(c.file) {
			return none
		}
	}
	return local
}

// is_platform_file reports whether a file holds one build's version of a
// declaration: an OS suffix on the file name, such as `_nix` or `_windows`, a
// `_d_flag` or `_notd_flag` one, or the `.js.v` JavaScript backend.
fn is_platform_file(file string) bool {
	name := file.all_after_last('/')
	if name.ends_with('.js.v') {
		return true
	}
	stem := name.all_before('.')
	if stem.contains('_d_') || stem.contains('_notd_') {
		return true
	}
	for suffix in ['_nix', '_windows', '_linux', '_darwin', '_macos', '_android', '_freebsd', '_openbsd', '_netbsd', '_solaris', '_ios', '_wasm', '_haiku', '_serenity'] {
		if stem.ends_with(suffix) {
			return true
		}
	}
	return false
}

// resolve_callee picks the one declaration a call edge refers to, or none when
// the raw name stays ambiguous. Narrowing is progressive, strongest signal
// first: a globally unique name wins outright; then candidates of the matching
// kind (`x.foo()` can only be a method, `foo()` only a plain function); then
// the caller's own file; then its module. A step that would eliminate *every*
// candidate is skipped rather than applied, so a weaker signal can never
// discard what a stronger one kept.
//
// Precision is preferred over recall throughout: an edge pointing at the wrong
// declaration sends a reader somewhere false, which is worse than leaving the
// raw name for them to search on.
//
// Picking between same-named methods on different receivers (`str` has ~300
// declarations in the V repo) needs the receiver's type. Where the code
// writes it, recv_type carries it here; where it has to be worked out,
// Infer.infer_call (infer.v) does that before falling back to this.
//
// The returned `inferred` flag records which kind of step won: a globally
// unique name or a parser-typed receiver leaves no real candidate to choose
// between, so that is `extracted`; every later step chose among several real
// declarations by locality/visibility, so that is `inferred` — see
// EdgeProvenance.
fn resolve_callee(e Edge, by_name map[string][]CallCand, site_of map[string]DeclSite, imports_of map[string][]string) ?CallResolution {
	cands := by_name[e.to] or { return none }
	if cands.len == 0 {
		return none
	}
	if id := only_id(cands) {
		return CallResolution{ id: id, inferred: false }
	}
	// A receiver the parser could type without inference pins the call down
	// exactly — but only trust it when that method really exists, since the
	// call may be to an embedded type's method or a function-typed field.
	// `want` alone misses a disambiguated id (see disambiguate_ids in this
	// file): `e.recv_type` was built at extraction time, before any id could
	// have been renamed, so it can never carry the `@file` suffix a colliding
	// receiver type's real id now does — `want_suffixed` reconstructs it
	// using this edge's own file, matching how the receiver's declaration
	// would have been suffixed when co-located with the calling method (the
	// overwhelmingly common case for a self-receiver call).
	if e.recv_type != '' {
		want := e.recv_type + '.' + e.to
		want_suffixed := if e.file != '' { '${want}@${e.file}' } else { '' }
		for c in cands {
			if (c.id == want || (want_suffixed != '' && c.id == want_suffixed)) && !test_private(c.file, e.file) {
				return CallResolution{ id: c.id, inferred: false }
			}
		}
		// a platform copy's id carries its file (see disambiguate_ids), so the
		// receiver's own method may be a copy named without it; any copy will do,
		// since variants_of links them all
		for c in cands {
		if c.id.all_before('@') == want && !test_private(c.file, e.file) {
			return CallResolution{ id: c.id, inferred: false }
		}
	}
		if res := resolve_by_receiver_type(e, cands, site_of) {
			return res
		}
	}
	mut narrowed := []CallCand{}
	for c in cands {
		if c.is_method == e.is_method {
			narrowed << c
		}
	}
	if id := only_id(narrowed) {
		return CallResolution{ id: id, inferred: true }
	}
	if narrowed.len == 0 {
		// the kind filter matched nothing, which is not evidence about any
		// candidate — put them all back rather than resolving to nothing
		for c in cands {
			narrowed << c
		}
	}
	// no known caller location (unknown or duplicated id) means no locality
	// signal is trustworthy, so stop here rather than guess
	caller := caller_site(e, site_of) or { return none }
	mut same_file := []CallCand{}
	for c in narrowed {
		if c.file == caller.file {
			same_file << c
		}
	}
	if id := only_id(same_file) {
		return CallResolution{ id: id, inferred: true }
	}
	// Same-module is only evidence for a *real* module. `main` is the implicit
	// module of every standalone program, so a repo can contain thousands of
	// mutually unrelated `main` files; matching on it links programs that have
	// nothing to do with each other.
	if caller.mod != '' && (!caller.is_main || caller.solo) {
		mut same_mod := []CallCand{}
		for c in narrowed {
			if c.mod == caller.mod && !test_private(c.file, caller.file) {
				same_mod << c
			}
		}
		if id := only_id(same_mod) {
			return CallResolution{ id: id, inferred: true }
		}
	}
	// A plain `error()` names a function of the caller's own module or, when
	// there is none, of builtin: another module's function needs its prefix,
	// and a selective import's names already carry one (see callee in
	// backend_v.v), so `log.error` is no candidate here. In a standalone
	// program the "own module" is every program in its directory, which only
	// makes this skip more often.
	if !e.is_method && !e.to.contains('.') && !e.to.contains('__static__') {
		mut own := false
		mut builtins := []CallCand{}
		for c in narrowed {
			if test_private(c.file, caller.file) {
				continue
			}
			if c.mod == caller.mod {
				own = true
			} else if import_reaches(c.mod, 'builtin') {
				builtins << c
			}
		}
		if !own {
			if id := only_id(builtins) {
				return CallResolution{ id: id, inferred: true }
			}
		}
	}
	// Last, V's own visibility rule: a file can only call what it imports,
	// plus its own module and the auto-imported `builtin`. If exactly one
	// candidate is reachable from this file at all, that is the one the
	// compiler would bind, whichever module it lives in. `main` is left out
	// of the own-module part for the same reason as above — thousands of
	// unrelated programs share it, so it grants no real visibility.
	imports := imports_of[caller.file] or { []string{} }
	mut visible := []CallCand{}
	for c in narrowed {
		if visible_from(c.mod, caller, imports) && !test_private(c.file, caller.file) {
			visible << c
		}
	}
	if id := only_id(visible) {
		return CallResolution{ id: id, inferred: true }
	}
	return none
}

// FileScope is what a module prefix on a callee can name from one file: the
// file's own module and the modules it imports.
struct FileScope {
mut:
	mod      string            // module id
	declared string            // the name on the file's `module` line
	is_main  bool              // in a standalone program, see main_unit_files
	prefixes map[string]string // import path or alias -> import path
}

// resolve_by_receiver_type resolves a method call whose receiver type is known
// (see walk_call) but whose type id is not `e.recv_type` verbatim: the type is
// written as V names it, `string` or `strings.Builder`, while ids carry the
// declaring directory, `vlib.builtin.string` and `vlib.strings.Builder`. It
// takes the methods named `<Type>.<name>` and keeps the first tier with any:
// the caller's own file, its module, then a module the file imports or
// builtin, the places V would find that type. The first two are as certain as
// an exact match; matching an import by trailing segments is inferred.
fn resolve_by_receiver_type(e Edge, cands []CallCand, site_of map[string]DeclSite) ?CallResolution {
	tshort := e.recv_type.all_after_last('.')
	qual := e.recv_type.all_before_last('.')
	suffix := '.${tshort}.${e.to}'
	caller := caller_site(e, site_of) or { DeclSite{} }
	file := if e.file != '' { e.file } else { caller.file }
	mut same_file := []CallCand{}
	mut own_mod := []CallCand{}
	mut reachable := []CallCand{}
	for c in cands {
		if !c.is_method || !c.id.all_before('@').ends_with(suffix) || test_private(c.file, file) {
			continue
		}
		if c.file == file {
			same_file << c
		}
		if c.mod == qual && !caller.is_main {
			own_mod << c
		}
		// a type from another module is written with the module the file
		// imported it by (`strings.Builder`), so that names its module
		if import_reaches(c.mod, 'builtin') || (qual != caller.mod && import_reaches(c.mod, qual)) {
			reachable << c
		}
	}
	if id := only_id(same_file) {
		return CallResolution{ id: id, inferred: false }
	}
	if id := only_id(own_mod) {
		return CallResolution{ id: id, inferred: false }
	}
	if id := only_id(reachable) {
		return CallResolution{ id: id, inferred: true }
	}
	return none
}

// resolve_qualified_callee resolves a raw callee that the parser reported with
// a module prefix, `os.join_path` for `os.join_path(...)`. resolve_callee
// looks names up bare, so these were never resolved, though the prefix pins
// the module down better than any locality signal can.
//
// The parser has already replaced an import alias with the imported path
// (`json.decode()` after `import x.json2 as json` comes out as
// `x.json2.decode`), but the alias is mapped as well rather than relied on
// never to appear. A prefix counts only when it is one of the file's own
// imports, matched to module ids by trailing segments (import_reaches), or the
// file's own declared module. The parser also prefixes some unqualified calls
// with the *current* module -- a keyword-named function (`select(...)` in
// vlib/net is `net.select`), and a selectively imported one (`shared()` after
// `import util { shared }` is `app.shared`) -- so that prefix is taken to mean
// exactly the caller's module id: matching it by trailing segments would pin
// `app.shared` on some unrelated module that happens to end in `app`, while
// the real `util.shared` is beyond what the name records. Only plain
// functions qualify: a prefixed callee is never a method call, and a static
// method (`Type.new()`) is a function whose name carries `__static__`.
//
// More than one fitting id resolves nothing (only_id), as everywhere else in
// this pass. A single fit is `extracted`, since the source itself named the
// module and there was nothing left to choose between.
fn resolve_qualified_callee(e Edge, by_name map[string][]CallCand, site_of map[string]DeclSite, scope_of map[string]FileScope) ?CallResolution {
	if e.to.starts_with('C.') {
		return c_binding_callee(e, by_name)
	}
	prefix := e.to.all_before_last('.')
	cands := by_name[e.to.all_after_last('.')] or { return none }
	file := if e.file != '' { e.file } else { (site_of[e.from] or { return none }).file }
	scope := scope_of[file] or { return none }
	imported := scope.prefixes[prefix] or { '' }
	mut fits := []CallCand{}
	for c in cands {
		if c.is_method {
			continue
		}
		// `main` is shared by every standalone program, so the own-module
		// match there is held to the caller's own file
		// the module id too: a call through the file's own module name is recorded
		// with the id (callee, in backend_v.v), as `vlib.semver.from` where the file
		// writes `semver`, and a receiver's type is read through that name (call_result)
		own :=(prefix == scope.declared || prefix == scope.mod) && c.mod == scope.mod && (!scope.is_main || c.file == file)
		if own {
			if !test_private(c.file, file) {
				fits << c
			}
		} else if imported != '' && import_reaches(c.mod, imported) && importable(c.id, c.file, file, site_of) {
			fits << c
		}
	}
	id := only_id(if imported != '' { exact_calls(fits, imported) } else { fits })?
	return CallResolution{
		id:       id
		inferred: false
	}
}

// c_binding_callee resolves a call of a C binding, `C.name(...)`, to the function of
// that name in the C namespace. A binding that more than one file declares is one
// function when the copies share a base id; the call reaches each through variants_of.
fn c_binding_callee(e Edge, by_name map[string][]CallCand) ?CallResolution {
	cands := by_name[e.to] or { return none }
	// every candidate is a declaration of the same C name, so they share one id, which
	// names the function
	return CallResolution{
		id:       cands[0].id
		inferred: false
	}
}

// importable reports whether the declaration `id` in `decl_file` can be
// reached through an import from `caller_file`: not when it is private to a
// test, nor when it is part of a standalone program, which no import names
// (`import veb` matches the trailing segments of `examples.veb` too).
fn importable(id string, decl_file string, caller_file string, site_of map[string]DeclSite) bool {
	if test_private(decl_file, caller_file) {
		return false
	}
	if site := site_of[id] {
		return !site.is_main
	}
	return true
}

// resolve_type_ref picks the one declaration a raw type name (on an `embeds`
// or `references` edge) refers to, or none when it stays ambiguous. Same
// progressive-narrowing shape as resolve_callee -- unique name, then the
// referencing declaration's own file, then its module, then V's visibility
// rule -- minus the method-vs-function kind filter and the self-receiver
// shortcut, which are calls-specific: a type name carries no notion of
// "method vs function", and there is no receiver to type without inference.
fn resolve_type_ref(e Edge, by_type_name map[string][]TypeCand, site_of map[string]DeclSite, imports_of map[string][]string) ?CallResolution {
	named := by_type_name[e.to.all_after_last('.')] or { return none }
	if named.len == 0 {
		return none
	}
	host := e.to.all_before('.')
	if host in ['C', 'JS'] && e.to.count('.') == 1 {
		// `C.Window` or `JS.Number`: a C or JS type is one name for the whole
		// program, so the nearest declaration of that host is the one: in the
		// referencing file, its module, a module it can see, then the program. A
		// V type of the same name is none of it, `EveryFn` for `JS.EveryFn`
		// included. With no such declaration the edge keeps its name and is
		// undeclared (host_type_undeclared); with two in the nearest scope that
		// has any, it stays unresolved.
		hosts := named.filter(it.declares_host(host))
		site := caller_site(e, site_of) or { DeclSite{
			file: e.file
		} }
		imports := imports_of[site.file] or { []string{} }
		c := nearest_type(hosts.filter(it.file == site.file), hosts.filter(it.mod == site.mod),
			hosts.filter(visible_from(it.mod, site, imports)), hosts)?
		// one declaration in the program is a unique name; several, a locality pick
		unique := if _ := only_type_id(hosts) { true } else { false }
		return CallResolution{
			id:       c.id
			inferred: !unique
		}
	}
	// any other name is a V type: a C or JS declaration is named only with its
	// qualifier, which type_ref keeps
	cands := named.filter(!it.declares_host('C') && !it.declares_host('JS'))
	if e.to.contains('.') {
		// named through its module (embed_name in backend_v.v): that
		// module's type, never a local one of the same name
		qual := e.to.all_before_last('.')
		file := if e.file != '' { e.file } else { (caller_site(e, site_of) or { DeclSite{} }).file }
		mut in_mod := []TypeCand{}
		for c in cands {
			if import_reaches(c.mod, qual) && importable(c.id, c.file, file, site_of) {
				in_mod << c
			}
		}
		id := only_type_id(exact_types(in_mod, qual))?
		return CallResolution{
			id:       id
			inferred: false
		}
	}
	if id := only_type_id(cands) {
		return CallResolution{ id: id, inferred: false }
	}
	// no known site for the referencing declaration means no locality signal
	// is trustworthy, so stop here rather than guess
	caller := caller_site(e, site_of) or { return none }
	return type_in_scope(cands, caller, imports_of)
}

// type_in_scope picks the one candidate a name in the caller's scope refers to, by
// locality: the caller's own file, then its module, then builtin when the module
// declares none, then what its imports reach.
// none when no candidate is in scope or a step stays ambiguous. A caller in a
// `module main` directory with no `fn main` sees its module's files as one program,
// since `v test` builds such a directory together: `Country` in country.v is the
// type `fn Country.cases() []Country` in country_cases.v names.
fn type_in_scope(cands []TypeCand, caller DeclSite, imports_of map[string][]string) ?CallResolution {
	mut same_file := []TypeCand{}
	for c in cands {
		if c.file == caller.file {
			same_file << c
		}
	}
	if id := only_type_id(same_file) {
		return CallResolution{ id: id, inferred: true }
	}
	if caller.mod != '' && (!caller.is_main || caller.solo || caller.no_main) {
		mut same_mod := []TypeCand{}
		for c in cands {
			if c.mod == caller.mod && !test_private(c.file, caller.file) {
				same_mod << c
			}
		}
		if id := only_type_id(same_mod) {
			return CallResolution{ id: id, inferred: true }
		}
	}
	// a bare type name is the caller's module's or builtin's, as V reads it:
	// `import wasm` must not make vlib/builtin/wasm's `string` a candidate,
	// though import_reaches matches it by its last segment
	mut own := false
	mut builtins := []TypeCand{}
	for c in cands {
		if test_private(c.file, caller.file) {
			continue
		}
		if c.mod == caller.mod {
			own = true
		} else if import_reaches(c.mod, 'builtin') {
			builtins << c
		}
	}
	if !own {
		if id := only_type_id(builtins) {
			return CallResolution{ id: id, inferred: true }
		}
	}
	imports := imports_of[caller.file] or { []string{} }
	mut visible := []TypeCand{}
	for c in cands {
		if visible_from(c.mod, caller, imports) && !test_private(c.file, caller.file) {
			visible << c
		}
	}
	if id := only_type_id(visible) {
		return CallResolution{ id: id, inferred: true }
	}
	return none
}

// host_type_undeclared reports whether `name` is a C or JS type, `C.Window` or
// `JS.Number`, that no declaration of that host in the program names.
fn host_type_undeclared(name string, by_type_name map[string][]TypeCand) bool {
	host := name.all_before('.')
	if host !in ['C', 'JS'] || name.count('.') != 1 {
		return false
	}
	cands := by_type_name[name.all_after('.')] or { return true }
	return !cands.any(it.declares_host(host))
}

// nearest_type is the one declaration in the first of tiers that has any, the
// scopes from nearest to widest. Declarations of one id in a scope are one type,
// declared once per platform; two ids in that scope leave it unknown.
fn nearest_type(tiers ...[]TypeCand) ?TypeCand {
	for tier in tiers {
		if tier.len > 0 {
			only_type_id(tier)?
			return tier[0]
		}
	}
	return none
}

// alias_conversion is the type alias a bare call names when the call is a conversion
// to it: V reads `uintptr_t(x)` under `type uintptr_t = usize` as a conversion, not a
// call of a function. Unlike resolve_type_ref there is no unique-name step: a bare
// name the caller cannot see is not a conversion of that alias elsewhere in the program.
fn alias_conversion(e Edge, alias_by_name map[string][]TypeCand, site_of map[string]DeclSite, imports_of map[string][]string) ?string {
	cands := alias_by_name[e.to] or { return none }
	caller := caller_site(e, site_of) or { return none }
	res := type_in_scope(cands, caller, imports_of)?
	return res.id
}

fn rel_path(root string, path string) string {
	if path == root {
		// single-file run: use the bare file name as the header
		return os.base(path)
	}
	// Case-insensitive comparison only: Windows/macOS filesystems are
	// case-insensitive-but-preserving, so a casing mismatch between how
	// `root` and a walked `path` were constructed already worked there by
	// accident. Linux's case-sensitive filesystem is the one place that
	// mismatch would otherwise fall through to the raw absolute path
	// instead of the intended relative one.
	rel := if path.to_lower().starts_with(root.to_lower()) {
		path[root.len..].trim_left('\\/')
	} else {
		path
	}
	// store with forward slashes so the graph resolves on any OS
	return rel.replace('\\', '/')
}

// add_lines adds the call sites of `e`, another raw edge that resolved to the same
// call, to the resolved edge at `at`: their lines, and the builds that make them.
fn add_lines(mut edges []Edge, at int, e Edge) {
	edges[at] = Edge{
		...edges[at]
		lines: merge_lines(edges[at].lines, e.lines)
		build: either_build(edges[at].build, e.build)
	}
}
