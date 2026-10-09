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
	abs_root := os.real_path(root)
	mut g := Graph{
		root: abs_root
	}
	mut failed := []string{}
	mut stale := []string{}
	mut partial := []string{}
	// save_cache below needs out_dir to exist; write_bundle also creates it
	// later, but that's after this function returns.
	os.mkdir_all(out_dir) or {}

	files := if os.is_dir(abs_root) {
		find_source_files(abs_root)
	} else {
		[abs_root]
	}

	// Hashed once and reused for both load and save below -- see cache.v for
	// why the cache is tied to the running binary's own content, not just
	// each source file's hash.
	bin_hash := file_hash(worker_exe)
	old_cache := load_cache(out_dir, bin_hash)
	mut new_cache := []CacheEntry{cap: files.len}
	// each file's result, by relative path; the graph is assembled from it in
	// `files` order at the end, so which of two same-id declarations comes
	// first doesn't depend on what was cached, retried or parsed when
	mut by_rel := map[string]FileResult{}

	mut queue := []WorkItem{}
	for path in files {
		rel := rel_path(abs_root, path)
		hash := file_hash(path)
		if hash != '' && rel in old_cache && old_cache[rel].hash == hash {
			// unchanged since the last extract — reuse its symbols/edges
			// instead of spending a worker parsing it again.
			reused := fresh_reuse_of(old_cache[rel])
			by_rel[rel] = reused.fr
			new_cache << reused
			if reused.fr.parse_error != '' {
				partial << rel
			}
			continue
		}
		queue << WorkItem{
			path: path
			rel:  rel
			hash: hash
		}
	}

	batch_size := 200
	parallel := if runtime.nr_cpus() > 0 { runtime.nr_cpus() } else { 1 }
	pid := os.getpid()
	mut batch_seq := 0

	for queue.len > 0 {
		// slice off up to `parallel` batches and spawn them all before waiting
		// on any of them, so they run concurrently instead of one at a time.
		mut jobs := []BatchJob{}
		for jobs.len < parallel && queue.len > 0 {
			n := if queue.len < batch_size { queue.len } else { batch_size }
			batch := queue#[..n].clone()
			queue = queue#[n..].clone()

			batch_seq++
			listfile := os.join_path(os.temp_dir(), 'gf_list_${pid}_${batch_seq}.txt')
			outfile := os.join_path(os.temp_dir(), 'gf_out_${pid}_${batch_seq}.ndjson')

			mut lines := []string{}
			for w in batch {
				lines << '${w.path}\t${w.rel}'
			}
			os.write_file(listfile, lines.join('\n')) or {
				// none of this batch's files got a parse attempt this run —
				// same class of gap as a crashed worker, so the same
				// stale-fallback treatment applies to each of them.
				for w in batch {
					failed << w.rel
					if fallback := stale_fallback_for(old_cache, w.rel) {
						by_rel[w.rel] = fallback.fr
						new_cache << fallback
						stale << w.rel
					}
				}
				continue
			}

			mut p := os.new_process(worker_exe)
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
					by_rel[job.batch[i].rel] = fr
					if fr.parse_error != '' {
						partial << job.batch[i].rel
					}
					new_cache << CacheEntry{
						rel:  job.batch[i].rel
						hash: job.batch[i].hash
						fr:   fr
					}
				}
			}
			completed := results.len
			n := job.batch.len
			if completed < n {
				// the file at index `completed` crashed this worker — skip it
				// and requeue the rest of the batch for the next wave.
				crashed_rel := job.batch[completed].rel
				failed << crashed_rel
				if fallback := stale_fallback_for(old_cache, crashed_rel) {
					by_rel[crashed_rel] = fallback.fr
					new_cache << fallback
					stale << crashed_rel
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
	}

	for path in files {
		if fr := by_rel[rel_path(abs_root, path)] {
			g.symbols << fr.symbols
			g.edges << fr.edges
		}
	}
	failed.sort()
	stale.sort()
	partial.sort()
	save_cache(out_dir, bin_hash, new_cache)
	disambiguate_ids(mut g)
	separate_member_ids(mut g)
	resolve_edges(mut g)
	return g, ExtractReport{
		binary_hash: bin_hash
		failed:      failed
		stale:       stale
		partial:     partial
	}
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
		root: root
	}

	files := if os.is_dir(root) {
		find_source_files(root)
	} else {
		[root]
	}

	for path in files {
		rel := rel_path(root, path)
		syms, edges := extract_v_file(path, rel)

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
	// each Symbol carries its own file.
	for i in 0 .. g.symbols.len {
		s := g.symbols[i]
		if s.kind in kinds && collides[s.id] {
			g.symbols[i].id = '${s.id}@${s.file}'
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
	// changed edge is a new value, same as resolve_edges builds below.
	mut with_from_renamed := []Edge{cap: g.edges.len}
	for e in g.edges {
		if (e.kind == .calls || e.kind == .embeds || e.kind == .references) && collides[e.from] {
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
}

// TypeCand is one declaration that a raw type name (on an `embeds` or
// `references` edge) could refer to.
struct TypeCand {
	id   string
	mod  string
	file string
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
	mut by_type_name := map[string][]TypeCand{}
	// enum_names holds each enum by module and name, to recognise V's own zero()
	// on a flag enum (see below).
	mut enum_names := map[string]bool{}
	// a field's site is its struct, so a struct maps to its own module
	mut struct_mod := map[string]string{}
	for s in g.symbols {
		if s.kind == .enum_ {
			enum_names[s.parent + '\x00' + s.name] = true
		}
		if s.kind == .struct_ {
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
			by_name[s.name] << CallCand{
				id:        s.id
				is_method: s.kind == .method
				mod:       s.parent // fn/method symbols hang off their module
				file:      s.file
			}
		}
		if s.kind in [SymbolKind.struct_, .enum_, .interface_, .type_alias] {
			by_type_name[s.name] << TypeCand{
				id:   s.id
				mod:  s.parent
				file: s.file
			}
		}
		// site_of answers "where does this edge's `from` live", so it only
		// needs the kinds the extractor actually emits calls/embeds/references
		// edges from: fn/method (calls, and param/receiver/return-type
		// references), struct (field-type references and embeds), interface
		// (embeds), type alias (the types it is built from), and constant, global
		// and field (the calls in their initializers). Enums are only ever a `to`.
		if s.kind in [SymbolKind.function, .method, .struct_, .interface_, .type_alias, .constant, .global, .field] {
			site_of[s.id] = DeclSite{
				mod:     s.parent
				file:    s.file
				is_main: in_main_unit(s, mains)
				solo:    main_count[s.parent] == 1
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
		if n < 2 {
			continue
		}
		if id_main[id] {
			unaddressable[id] = true
			continue
		}
		mut tests := []string{}
		for f in id_files[id] or { []string{} } {
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
	// that variant's location is known: keyed by id and file (site_key).
	for s in g.symbols {
		if s.kind in [SymbolKind.function, .method] && id_count[s.id] > 1 && !unaddressable[s.id] {
			site_of[site_key(s.id, s.file)] = DeclSite{
				mod:     s.parent
				file:    s.file
				is_main: in_main_unit(s, mains)
				solo:    main_count[s.parent] == 1
			}
		}
	}
	mut sig_of := map[string]string{}
	mut fn_names := map[string]string{}
	mut field_type := map[string]string{}
	mut alias_of := map[string]string{}
	mut embeds_of := map[string][]Edge{}
	mut field_ids := map[string]string{}
	mut consts := map[string][]Symbol{}
	mut enum_ids := map[string]bool{}
	mut dynamic_ids := map[string]bool{}
	mut iface_ids := map[string]bool{}
	mut generics_of := map[string][]string{}
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
			}
			.field {
				field_type['${s.parent}\x00${s.name}'] = s.signature.all_after(' ')
				field_ids['${s.parent}\x00${s.name}'] = s.id
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
				} else {
					alias_of[s.id] = rhs
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
		by_type_name: by_type_name
		site_of:      site_of
		imports_of:   imports_of
		scope_of:     scope_of
		sig_of:       sig_of
		name_of:      fn_names
		field_type:   field_type
		alias_of:     alias_of
		embeds_of:    embeds_of
		field_id:     field_ids
		consts:       consts
		enum_ids:     enum_ids
		dynamic_ids:  dynamic_ids
		iface_ids:    iface_ids
		generics_of:  generics_of
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
				if key !in seen_call {
					seen_call[key] = resolved.len
					resolved << e
				}
				continue
			}
			if res := inf.infer_call(e) {
				if res.undeclared {
					key := '${e.from}\x00${e.to}'
					if key !in seen_call {
						seen_call[key] = resolved.len
						resolved << Edge{
							...e
							provenance: .undeclared
						}
					}
					continue
				}
				if !unaddressable[res.id] {
					// a call that reaches one platform's copy of a function reaches every copy
					for id in variants_of[res.id] or { [res.id] } {
						key := '${e.from}\x00${id}'
						if at := seen_call[key] {
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
						}
					}
					continue
				}
			}
			if variants := platform_variants(e, by_name, site_of) {
				for v in variants {
					key := '${e.from}\x00${v.id}'
					if key !in seen_call {
						seen_call[key] = resolved.len
						resolved << Edge{
							from:       e.from
							to:         v.id
							kind:       .calls
							is_method:  e.is_method
							provenance: .inferred
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
					}
					continue
				}
			}
		}
		if e.kind == .calls {
			key := '${e.from}\x00${e.to}'
			if key in seen_call {
				continue
			}
			seen_call[key] = resolved.len
		}
		if e.kind == .calls && e.to.ends_with('__static__zero') {
			// V generates `T.zero()` for a @[flag] enum T and for no other enum, so a
			// call of it with no zero declared, to an enum T in the caller's module, is
			// one V provides.
			if site := caller_site(e, site_of) {
				mod := struct_mod[site.mod] or { site.mod }
				if enum_names[mod + '\x00' + e.to.all_before('__static__')] {
					resolved << Edge{...e, provenance: .undeclared}
					continue
				}
			}
		}
		resolved << e
	}
	g.edges = resolved
}

// site_key is where site_of keeps the location of one variant of an id that
// several files declare (see resolve_edges).
fn site_key(id string, file string) string {
	return '${id}\x00${file}'
}

// caller_site is where the declaration an edge comes from lives: its id's
// only declaration, or, for an id with per-platform variants, the one in the
// file the edge was found in.
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

// is_platform_file reports whether a file holds one platform's version of a
// declaration: an OS suffix on the file name, such as `_nix` or `_windows`, or
// the `.js.v` JavaScript backend.
fn is_platform_file(file string) bool {
	name := file.all_after_last('/')
	if name.ends_with('.js.v') {
		return true
	}
	stem := name.all_before('.')
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
		own := prefix == scope.declared && c.mod == scope.mod && (!scope.is_main || c.file == file)
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
	cands := by_type_name[e.to.all_after_last('.')] or { return none }
	if cands.len == 0 {
		return none
	}
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
	mut same_file := []TypeCand{}
	for c in cands {
		if c.file == caller.file {
			same_file << c
		}
	}
	if id := only_type_id(same_file) {
		return CallResolution{ id: id, inferred: true }
	}
	if caller.mod != '' && (!caller.is_main || caller.solo) {
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
