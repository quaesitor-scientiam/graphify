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

	mut queue := []WorkItem{}
	for path in files {
		rel := rel_path(abs_root, path)
		hash := file_hash(path)
		if hash != '' && rel in old_cache && old_cache[rel].hash == hash {
			// unchanged since the last extract — reuse its symbols/edges
			// instead of spending a worker parsing it again.
			reused := fresh_reuse_of(old_cache[rel])
			g.symbols << reused.fr.symbols
			g.edges << reused.fr.edges
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
						g.symbols << fallback.fr.symbols
						g.edges << fallback.fr.edges
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
				g.symbols << fr.symbols
				g.edges << fr.edges
				if i < job.batch.len {
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
					g.symbols << fallback.fr.symbols
					g.edges << fallback.fr.edges
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
// directory (see module_id in backend_v.v), so `cmd/tools/vself.v` has the
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
	return mod == caller.mod && !caller.is_main
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
}

// resolve_edges turns raw names into symbol ids where a single matching
// declaration can be identified: callee names on `calls` edges (via
// resolve_callee), and type names on `embeds`/`references` edges (via
// resolve_type_ref). Names that stay ambiguous are left as-is, so the caller
// can still see external/unknown/undecided references.
fn resolve_edges(mut g Graph) {
	mut by_name := map[string][]CallCand{}
	mut by_type_name := map[string][]TypeCand{}
	mut site_of := map[string]DeclSite{}
	mut id_count := map[string]int{}
	mains := main_unit_files(g)
	mut id_main := map[string]bool{}
	mut id_files := map[string][]string{}
	mut imports_of := map[string][]string{} // file -> modules it imports
	for s in g.symbols {
		if s.kind == .import_ {
			imports_of[s.file] << s.name
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
		// needs the kinds backend_v.v actually emits calls/embeds/references
		// edges from: fn/method (calls, and param/receiver/return-type
		// references) and struct (field-type references and embeds). Enums,
		// interfaces, and type_aliases are only ever a `to`, never a `from`.
		if s.kind in [SymbolKind.function, .method, .struct_] {
			site_of[s.id] = DeclSite{
				mod:     s.parent
				file:    s.file
				is_main: in_main_unit(s, mains)
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
	mut resolved := []Edge{cap: g.edges.len}
	for e in g.edges {
		if e.kind == .calls {
			// Refuse an id that cannot address one function (see above): an
			// edge to it would send every consumer to whichever declaration
			// happened to be indexed first. The raw name is honestly
			// ambiguous rather than falsely precise.
			if res := resolve_callee(e, by_name, site_of, imports_of) {
				if !unaddressable[res.id] {
					resolved << Edge{
						from:       e.from
						to:         res.id
						kind:       .calls
						is_method:  e.is_method
						provenance: if res.inferred { .inferred } else { .extracted }
					}
					continue
				}
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
		resolved << e
	}
	g.edges = resolved
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
// Note what this deliberately does not attempt: picking between same-named
// methods on different receivers (`str` has ~300 declarations in the V repo).
// That needs the receiver's resolved type, which only the checker computes —
// see the call-edge disambiguation note in README's Status section.
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
			if c.id == want || (want_suffixed != '' && c.id == want_suffixed) {
				return CallResolution{ id: c.id, inferred: false }
			}
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
	caller := site_of[e.from] or { return none }
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
	if caller.mod != '' && !caller.is_main {
		mut same_mod := []CallCand{}
		for c in narrowed {
			if c.mod == caller.mod {
				same_mod << c
			}
		}
		if id := only_id(same_mod) {
			return CallResolution{ id: id, inferred: true }
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
		if visible_from(c.mod, caller, imports) {
			visible << c
		}
	}
	if id := only_id(visible) {
		return CallResolution{ id: id, inferred: true }
	}
	return none
}

// resolve_type_ref picks the one declaration a raw type name (on an `embeds`
// or `references` edge) refers to, or none when it stays ambiguous. Same
// progressive-narrowing shape as resolve_callee -- unique name, then the
// referencing declaration's own file, then its module, then V's visibility
// rule -- minus the method-vs-function kind filter and the self-receiver
// shortcut, which are calls-specific: a type name carries no notion of
// "method vs function", and there is no receiver to type without inference.
fn resolve_type_ref(e Edge, by_type_name map[string][]TypeCand, site_of map[string]DeclSite, imports_of map[string][]string) ?CallResolution {
	cands := by_type_name[e.to] or { return none }
	if cands.len == 0 {
		return none
	}
	if id := only_type_id(cands) {
		return CallResolution{ id: id, inferred: false }
	}
	// no known site for the referencing declaration means no locality signal
	// is trustworthy, so stop here rather than guess
	caller := site_of[e.from] or { return none }
	mut same_file := []TypeCand{}
	for c in cands {
		if c.file == caller.file {
			same_file << c
		}
	}
	if id := only_type_id(same_file) {
		return CallResolution{ id: id, inferred: true }
	}
	if caller.mod != '' && !caller.is_main {
		mut same_mod := []TypeCand{}
		for c in cands {
			if c.mod == caller.mod {
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
		if visible_from(c.mod, caller, imports) {
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
