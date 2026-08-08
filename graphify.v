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

// build_graph_resilient builds a graph by parsing files in *worker processes*,
// running up to nr_cpus() of them concurrently (each parses its own batch),
// so a file that makes V's parser panic is skipped and reported instead of
// aborting the whole run. Only when a batch's worker crashes is the offending
// file isolated and the rest of that batch requeued for a later wave.
//
// Files whose content hash matches `out_dir`'s cache from the previous run
// are reused directly, skipping re-parsing entirely — see cache.v. Returns
// the graph and the list of files that failed to parse.
pub fn build_graph_resilient(root string, worker_exe string, out_dir string) (Graph, []string) {
	abs_root := os.real_path(root)
	mut g := Graph{
		root: abs_root
	}
	mut failed := []string{}
	// save_cache below needs out_dir to exist; write_bundle also creates it
	// later, but that's after this function returns.
	os.mkdir_all(out_dir) or {}

	files := if os.is_dir(abs_root) {
		find_source_files(abs_root, ['v'])
	} else {
		[SourceFile{
			path: abs_root
			lang: 'v'
		}]
	}

	old_cache := load_cache(out_dir)
	mut new_cache := []CacheEntry{cap: files.len}

	mut queue := []WorkItem{}
	for f in files {
		rel := rel_path(abs_root, f.path)
		hash := file_hash(f.path)
		if hash != '' && rel in old_cache && old_cache[rel].hash == hash {
			// unchanged since the last extract — reuse its symbols/edges
			// instead of spending a worker parsing it again.
			cached := old_cache[rel]
			g.symbols << cached.fr.symbols
			g.edges << cached.fr.edges
			new_cache << cached
			continue
		}
		queue << WorkItem{
			path: f.path
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
				for w in batch {
					failed << w.rel
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
				failed << job.batch[completed].rel
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

	save_cache(out_dir, new_cache)
	resolve_edges(mut g)
	return g, failed
}

// Options controls a graph build.
pub struct Options {
pub:
	root       string // directory (or single file) to analyze
	languages  []string = ['v'] // language ids to include; [] = all supported
	with_calls bool     = true  // record call edges between functions
}

// build_graph walks `opts.root`, parses every supported file with the right
// backend, and returns the assembled Graph.
pub fn build_graph(opts Options) Graph {
	root := os.real_path(opts.root)
	mut g := Graph{
		root: root
	}

	files := if os.is_dir(root) {
		find_source_files(root, opts.languages)
	} else {
		[
			SourceFile{
				path: root
				lang: lang_by_ext[os.file_ext(root)] or { '' }
			},
		]
	}

	for f in files {
		rel := rel_path(root, f.path)
		syms, edges := match f.lang {
			'v' { extract_v_file(f.path, rel) }
			else { extract_ts_file(f.path, rel, f.lang) }
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

	resolve_edges(mut g)
	return g
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
	mod  string
	file string
}

// CallResolution is what resolve_callee found for one call edge: which
// declaration it refers to, and whether picking it needed more than a name
// (see resolve_callee's doc comment for which steps set `inferred`).
struct CallResolution {
	id       string
	inferred bool
}

// resolve_edges turns raw callee names on `calls` edges into symbol ids when a
// single matching declaration can be identified. Names that stay ambiguous are
// left as-is, so the caller can still see external/unknown/undecided calls.
fn resolve_edges(mut g Graph) {
	mut by_name := map[string][]CallCand{}
	mut site_of := map[string]DeclSite{}
	mut id_count := map[string]int{}
	mut id_mod := map[string]string{}
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
			id_count[s.id]++
			id_mod[s.id] = s.parent
			id_files[s.id] << s.file
			site_of[s.id] = DeclSite{
				mod:  s.parent
				file: s.file
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
		if n < 2 {
			continue
		}
		if id_mod[id] or { '' } == 'main' {
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
	if e.recv_type != '' {
		want := e.recv_type + '.' + e.to
		for c in cands {
			if c.id == want {
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
	if caller.mod != '' && caller.mod != 'main' {
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
		if c.mod == 'builtin' || c.mod in imports
			|| (c.mod == caller.mod && caller.mod != 'main') {
			visible << c
		}
	}
	if id := only_id(visible) {
		return CallResolution{ id: id, inferred: true }
	}
	return none
}

fn rel_path(root string, path string) string {
	if path == root {
		// single-file run: use the bare file name as the header
		return os.base(path)
	}
	rel := if path.starts_with(root) { path[root.len..].trim_left('\\/') } else { path }
	// store with forward slashes so the graph resolves on any OS
	return rel.replace('\\', '/')
}
