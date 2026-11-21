#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Measures how often graphify's `inferred` call edges (or, with -kind references,
// its inferred reference edges; with -provenance extracted, the `extracted` ones) link
// the declaration that V's own compiler resolves
// the name to: a seeded random sample of their sites, each asked of V3's
// go-to-definition.
//
//   v run bin/sample-accuracy.vsh S:\graph_data\vlang                  # 1000 sites, seed 20261110
//   v run bin/sample-accuracy.vsh <graph> -kind references             # inferred reference edges
//   v run bin/sample-accuracy.vsh <graph> -kind missing-references     # type names no edge links
//   v run bin/sample-accuracy.vsh <graph> -kind missing-calls          # calls no edge links
//   v run bin/sample-accuracy.vsh <graph> -provenance extracted        # extracted edges instead
//   v run bin/sample-accuracy.vsh <graph> -provenance undeclared       # calls marked undeclared
//   v run bin/sample-accuracy.vsh <graph dir or graph.json> -n 2000 -seed 7
//   v run bin/sample-accuracy.vsh <graph> -out <dir>                   # where the results go
//   v run bin/sample-accuracy.vsh <graph> -v3 <binary>                 # use this V3, don't build one
//   v run bin/sample-accuracy.vsh <graph> -no-worlds                   # the default build only
//   v run bin/sample-accuracy.vsh <graph> -self-test                   # check the harness itself
//
// Without -v3 the graph's `root` must be a V checkout (it has vlib/v/v.v): its V3 is
// the oracle, built once per commit and change under vlib into the V temp folder
// (with `-gc none -prealloc`, as vlib/v/compiler_tests/vls_line_info_test.v builds
// it). The `v` launcher is not used, as it falls back to the old compiler when V3
// fails. With -v3 no V3 is built, not even one a `-d` needs.
//
// With -provenance extracted the edges sampled are the `extracted` ones (a unique name, or
// for a call a receiver the parser typed) whose target is a symbol of the graph, scored the
// same way. An edge to a built-in type, to a library declaration (a project graph's vlib), to
// a `C.`/`JS.` function or to an unresolved name can be stored as extracted too, and is left
// out, as the overview counts it apart. Inferred edges are all sampled, as before.
//
// With -provenance undeclared (calls only) the sites sampled are those of the calls the graph
// marks `undeclared`: a call it finds no declaration for and takes to be one V writes or a
// value it holds (`str()` on a type that declares none, a flag enum's `has`, a parameter
// holding a function). Their target is a name, not a symbol. Such a site is `correct` when V3
// names no function, method, or constant, global or field of the graph there (it names a
// local, a parameter, a type or nothing the graph has), `extra` when it names one another edge
// of the site links, and `wrong` when it names one no edge of the site links: the call has a
// declaration the graph missed. V3 gives no answer for a name nothing declares, and none
// for a body its program doesn't check either, so the other names on the line are asked
// too (control_columns): a site V3 is silent about, where it answers one of those in the
// same program and build, is `silent`; one where it answers neither is `no-answer`. Silent
// sites are not scored: V3 is silent about some calls that have a declaration too (`str()`
// on an int, whose declaration is builtin's), so its silence doesn't tell them apart.
//
// A unit is one site of an edge of the chosen kind and provenance: its caller (the symbol
// the edge is from), its callee (the declaration it is to) and one line of the
// edge's `lines`. A reference edge is scored whole (a signature's has no `lines`, and a
// body's are not used): its unit is the edge, asked at up to 8 lines of its `from` (in each file declaring that id) that name its target, and
// scored by its best one. V3 is asked `-vls-mode -line-info file:line:gd^col`
// at the callee's name on that line, inside a program that compiles the file. V3
// checks only the bodies a program reaches, so a site is asked in one program after
// another until one answers: the file itself (a test, or a main program), its
// directory, a main that imports its module, then the module's tests. A site still
// unanswered is asked again in the builds its file is compiled for: the `-os` and
// `-d` its name gives (`_linux.c.v`, `_d_ownership.v`), then each of `-os linux`,
// `-os macos` and `-os windows` other than the host's. Without -v3, a define V3 must
// be built with (`-d ownership`) builds that V3 too.
//
// Each sampled edge is then:
//   correct  V3's declaration is the edge's target
//   extra    the site has an edge to V3's declaration too: this one is another
//   wrong    no edge of the site goes to V3's declaration
//   not-in-graph     V3's declaration is not a graph symbol (a C header, say)
//   no-answer        no program or build gave an answer
//   name-not-on-line the callee's name is not on the line the edge gives
//   no-source        the line is not in the caller's file
// Accuracy is correct / (correct + extra + wrong), with a 95% Wilson interval.
// -kind missing-references scores places, not edges (see missing_places): linked,
// missing, not-a-type, not-in-graph or no-answer, and linked / (linked + missing).
// -kind missing-calls scores the places a body writes a call the same way (see
// missing_places and call_status): linked over the places V3 resolves to a function,
// method, field, constant or global of the graph, `other-line` apart.
// An `extra` or `wrong` row is where to look by hand: V3 answers for one build,
// and an edge can be right for another one.
//
// It writes sample.csv (one row per sampled site), v3_raw.log (every V3 answer) and
// summary.txt into -out (default: accuracy-<seed>, with -references,
// -missing-references or -missing-calls after it for that -kind, and -self-test after that for
// -self-test, in the V temp folder).
//
// -self-test points each sampled edge at another declaration of the same name before
// asking (a function or method for a call, one of the target's own kind for a
// reference; an edge whose name has no such declaration is left out), and fails if
// none is scored, or if one is scored correct where V3 also names the edge's own
// target. One scored correct where V3 never names the edge's own target means that
// edge is wrong and the stand-in is V's declaration: it is reported, not failed.
//
// The tree must be the one the graph was extracted from: its HEAD the manifest's
// source_commit, and each file the text the extract read (the manifest's source_files
// hashes, tree_drift). An edited or deleted file, or a new one beside them, refuses the run.
import os
import math
import time
import strings
import hash.fnv1a
import strconv
import x.json2
import crypto.sha256

const kind_function = 2
const kind_method = 3
const type_kinds = [4, 5, 6, 9] // struct, enum, interface, type alias
// what a call can name: a function, a method, and a constant, global or field holding one
const callable_kinds = [kind_function, kind_method, 7, 8, 10]
const edge_calls = 1
const edge_references = 5
const prov_extracted = 0
const prov_inferred = 1
const prov_undeclared = 2
// names written before `(` that are no call V3 can answer for: V's keywords (the `.key_`
// strings of vlib/v/token/token.v, some of them what the compiler provides with no
// declaration, `sizeof(x)`), and the primitive types a cast names (`int(x)`)
const call_keywords = ['as', 'asm', 'assert', 'atomic', 'break', 'const', 'continue', 'defer',
	'dump', 'else', 'enum', 'false', 'fn', 'for', '__global', 'go', 'goto', 'if', 'import', 'in',
	'interface', 'is', 'isreftype', '_likely_', 'lock', 'match', 'module', 'mut', 'nil', 'none',
	'__offsetof', 'or', 'pub', 'return', 'rlock', 'select', 'shared', 'sizeof', 'spawn', 'static',
	'struct', 'true', 'type', 'typeof', 'union', '_unlikely_', 'unsafe', 'volatile', 'i8', 'i16',
	'i32', 'int', 'i64', 'isize', 'u8', 'u16', 'u32', 'u64', 'usize', 'uint', 'byte', 'f32', 'f64',
	'rune', 'char', 'bool', 'string', 'voidptr', 'byteptr', 'charptr', 'chan', 'thread', 'any',
	'int_literal', 'float_literal']
// the statuses of a call place the graph doesn't link, in the order call_status tries them
// (after `other-line`, which is not scored: an edge to V3's declaration names other lines,
// which a call written over several lines is, placed on the line it starts, and so is a
// second call of one function whose own site has no edge; read those by hand)
const call_misses = ['other-target', 'undeclared', 'unresolved', 'missing']
const batch_size = 100
const max_mention_lines = 8 // the lines of a reference edge's `from` asked about it, at most

// a `_<marker>.` in a file's name, and an OS that compiles it, from the markers of
// `file_has_incompatible_os_only_suffix` in vlib/v/pref/pref.v; checked in this
// order, as `_termux.` is also in `_android_outside_termux.`
const os_markers = [
	['android_outside_termux', 'android'],
	['termux', 'termux'],
	['android', 'android'],
	['nix', 'linux'],
	['windows', 'windows'],
	['linux', 'linux'],
	['macos', 'macos'],
	['darwin', 'macos'],
	['bsd', 'freebsd'],
	['ios', 'ios'],
	['freebsd', 'freebsd'],
	['openbsd', 'openbsd'],
	['netbsd', 'netbsd'],
	['dragonfly', 'dragonfly'],
	['solaris', 'solaris'],
	['qnx', 'qnx'],
	['haiku', 'haiku'],
	['serenity', 'serenity'],
	['vinix', 'vinix'],
]

struct GSymbol {
	id     string
	name   string
	kind   int
	file   string
	line   int
	parent string
}

// Spot is a line of a file to ask V3 about.
struct Spot {
	file string
	line int
}

struct GEdge {
	from       string
	to         string
	kind       int
	provenance int
	lines      []int
}

struct GGraph {
	root    string
	symbols []GSymbol
	edges   []GEdge
}

struct Manifest {
	source_commit string
	source_files  []SourceFile
}

// SourceFile is one file the extract read, root-relative, and its text hash (graphify's
// text_hash in cache.v: sha256 of the text with CRLF read as LF).
struct SourceFile {
	path string
	hash string
}

struct Options {
mut:
	graph     string
	kind      string = 'calls'    // or 'references', 'missing-references' or 'missing-calls'
	prov      string = 'inferred' // or 'extracted', or for calls 'undeclared': the edges sampled
	n         int    = 1000
	seed      u64    = 20261110
	out       string
	v3        string
	worlds    bool = true
	self_test bool
	timeout   int = 300
}

struct Unit {
	from string
	to   string
	line int
	orig string // -self-test: the edge's own target, which `to` stands in for
}

struct Row {
mut:
	group   int    // the sampled unit this row asks for: a reference edge has a row per line
	orig    string // -self-test: the edge's own target
	from    string
	to      string
	file    string
	line    int
	to_file string
	to_line int
	cols    []int
	progs   []string
	worlds  [][]string
	status  string
	answers []string
	ids     []string
	program string
	world   string
	note    string
	// -provenance undeclared: the other names on the line, asked too, and the first answer
	// to one: V3 checked the body, so its silence at the call is `silent`, not `no-answer`
	ctrl_cols []int
	ctrl      string
}

// settled tells whether V3 has said what it will about a row: an answer, or for an
// undeclared call an answer to another name on its line.
fn (row Row) settled() bool {
	return row.answers.len > 0 || row.ctrl != ''
}

// Rng is splitmix64: a seed draws the same sample with any V version.
struct Rng {
mut:
	s u64
}

fn (mut r Rng) next() u64 {
	r.s += 0x9e3779b97f4a7c15
	mut z := r.s
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

fn (mut r Rng) below(n int) int {
	return int(r.next() % u64(n))
}

struct Ctx {
mut:
	root      string
	vexe      string
	cache_dir string
	out_dir   string
	timeout   time.Duration
	v3        string
	can_build bool              // false with -v3: no V3 is built, not even for a define
	variants  map[string]string // the V3 built with a define, by the define
	files     map[string][]string
	log       strings.Builder
}

fn main() {
	opts := parse_args(os.args[1..]) or {
		eprintln(err.msg())
		eprintln('usage: v run bin/sample-accuracy.vsh <graph dir or graph.json> [-kind calls|references|missing-references|missing-calls] [-provenance inferred|extracted|undeclared] [-n 1000] [-seed 20261110] [-out dir] [-v3 binary] [-no-worlds] [-self-test] [-timeout 300]')
		exit(2)
	}
	graph_path := if os.is_dir(opts.graph) {
		os.join_path(opts.graph, 'graph.json')
	} else {
		opts.graph
	}
	println('loading ${graph_path}...')
	g := json2.decode[GGraph](os.read_file(graph_path) or {
		eprintln('cannot read ${graph_path}: ${err}')
		exit(1)
	}) or {
		eprintln('cannot parse ${graph_path}: ${err}')
		exit(1)
	}
	manifest := json2.decode[Manifest](os.read_file(os.join_path(os.dir(graph_path),
		'manifest.json')) or { '' }) or { Manifest{} }
	commit := manifest.source_commit
	root := os.real_path(g.root)
	if !os.exists(os.join_path(root, 'vlib', 'v', 'v.v')) && opts.v3 == '' {
		eprintln('the graph root ${root} is not a V checkout (no vlib/v/v.v); pass -v3 <binary>')
		exit(1)
	}
	if why := tree_mismatch(root, commit) {
		eprintln(why)
		exit(1)
	}
	if manifest.source_files.len == 0 {
		println('note: the manifest records no file hashes (a merged or older graph), so edits to the tree since the extract are not checked')
	} else {
		drift := tree_drift(root, manifest.source_files)
		if drift.len > 0 {
			eprintln('the tree at ${root} is not the one the graph was extracted from: ${drift.len} file(s) differ, so V3 would answer about other text')
			for d in drift#[..10] {
				eprintln('  ${d}')
			}
			if drift.len > 10 {
				eprintln('  ... and ${drift.len - 10} more')
			}
			eprintln('re-extract the graph, or run against a clean copy of the tree at the graph commit')
			exit(1)
		}
	}
	// absolute before the chdir into the root below, which a relative path would follow
	out_dir := if opts.out != '' {
		os.abs_path(opts.out)
	} else {
		kind_suffix := if opts.kind == 'calls' { '' } else { '-' + opts.kind }
		prov_suffix := if opts.prov == 'inferred' { '' } else { '-' + opts.prov }
		test_suffix := if opts.self_test { '-self-test' } else { '' }
		os.join_path(os.vtmp_dir(), 'accuracy-${opts.seed}${kind_suffix}${prov_suffix}${test_suffix}')
	}
	os.mkdir_all(out_dir) or {
		eprintln('cannot create ${out_dir}: ${err}')
		exit(1)
	}
	mut ctx := Ctx{
		root:      root
		vexe:      @VEXE
		cache_dir: os.join_path(os.vtmp_dir(), 'graphify-accuracy')
		out_dir:   out_dir
		timeout:   time.second * opts.timeout
		log:       strings.new_builder(1 << 16)
	}
	ctx.can_build = opts.v3 == ''
	ctx.v3 = if opts.v3 != '' {
		// absolute for the same reason as out_dir
		v3 := os.real_path(os.abs_path(opts.v3))
		if !os.is_file(v3) {
			eprintln('-v3 ${opts.v3}: no such file')
			exit(1)
		}
		v3
	} else {
		ctx.build_v3([]) or {
			eprintln(err.msg())
			exit(1)
		}
	}
	os.chdir(root) or {
		eprintln('cannot enter ${root}: ${err}')
		exit(1)
	}

	mut syms := map[string]GSymbol{}
	mut by_pos := map[string][]string{} // 'file:line' -> the symbols declared there
	// an id is callable when any symbol under it is (see missing_places)
	mut callable := map[string]bool{}
	for s in g.symbols {
		syms[s.id] = s
		by_pos['${s.file}:${s.line}'] << s.id
		if s.kind in callable_kinds {
			callable[s.id] = true
		}
	}
	if opts.kind in ['missing-references', 'missing-calls'] {
		missing_places(mut ctx, g, by_pos, opts, commit, graph_path)
		return
	}
	edge_kind := if opts.kind == 'references' { edge_references } else { edge_calls }
	// a reference edge is scored as one unit (line 0), asked at the lines of its `from`
	// declaration that name its target, as a signature's has no `lines`
	by_edge := edge_kind == edge_references
	prov := match opts.prov {
		'extracted' { prov_extracted }
		'undeclared' { prov_undeclared }
		else { prov_inferred }
	}
	mut units := []Unit{}
	for e in g.edges {
		// an edge to a built-in type, a library declaration, a `C.` function or an unresolved
		// name can be stored as extracted too, told apart by a target that is no symbol
		// (count_provenance in bundle.v); inferred ones stay unfiltered, as before, as on a
		// project graph many go to a library declaration
		// (an undeclared edge's target is a name, never a symbol)
		if e.kind == edge_kind && e.provenance == prov && (prov != prov_extracted || e.to in syms) {
			if by_edge {
				units << Unit{
					from: e.from
					to:   e.to
				}
				continue
			}
			for ln in e.lines {
				units << Unit{
					from: e.from
					to:   e.to
					line: ln
				}
			}
		}
	}
	println('population: ${units.len} ${opts.prov} ${unit_name(opts.kind)}')
	if units.len == 0 {
		exit(1)
	}

	// a partial Fisher-Yates shuffle draws the sample
	mut rng := Rng{
		s: opts.seed
	}
	mut picks := []int{len: units.len, init: index}
	n := if opts.n < units.len { opts.n } else { units.len }
	for i in 0 .. n {
		j := i + rng.below(units.len - i)
		picks[i], picks[j] = picks[j], picks[i]
	}
	mut sample := []Unit{cap: n}
	for i in 0 .. n {
		sample << units[picks[i]]
	}

	// every target the graph gives a sampled site, to tell an extra edge from a wrong one
	// (for a reference, every target its `from` references)
	mut site_targets := map[string]map[string]bool{}
	for u in sample {
		site_targets[site_key(u.from, u.line, by_edge)] = map[string]bool{}
	}
	for e in g.edges {
		if e.kind != edge_kind {
			continue
		}
		lines := if by_edge { [0] } else { e.lines }
		for ln in lines {
			key := site_key(e.from, ln, by_edge)
			if key in site_targets {
				site_targets[key][e.to] = true
			}
		}
	}

	if opts.self_test {
		mut by_name := map[string][]string{}
		for s in g.symbols {
			by_name[s.name] << s.id
		}
		mut corrupted := []Unit{}
		for u in sample {
			target := syms[u.to] or { GSymbol{} }
			others := by_name[target.name].filter(it != u.to
				&& it !in site_targets[site_key(u.from, u.line, by_edge)]
				&& same_role(syms[it].kind, target.kind, edge_kind))
			if others.len > 0 {
				corrupted << Unit{
					from: u.from
					to:   others[rng.below(others.len)]
					line: u.line
					orig: u.to
				}
			}
		}
		sample = corrupted.clone()
		println('self-test: ${sample.len} sampled edges pointed at another declaration of their name')
	}

	// a reference's `from` can be declared in several files under one id (a `C.`
	// declaration, a declaration per OS): each copy, and the declarations beside it
	mut copies := map[string][]GSymbol{}
	mut in_file := map[string][]GSymbol{}
	if by_edge {
		for s in g.symbols {
			copies[s.id] << s
			in_file[s.file] << s
		}
	}

	mut rows := []Row{}
	for gi, u in sample {
		caller := syms[u.from] or { GSymbol{} }
		callee := syms[u.to] or { GSymbol{} }
		name := if callee.name != '' {
			callee.name
		} else if prov == prov_undeclared {
			// the name called, as call_status reads an unresolved one: a static call keeps its
			// type before the method (`Foo__static__new`)
			u.to.all_before('[').all_after_last('.').all_after_last('__static__')
		} else {
			u.to.all_before('@').all_after_last('.')
		}
		// the lines to ask at: the site's, or a reference's mentions in its `from`
		spots := if by_edge {
			ctx.mention_spots(copies[u.from], in_file, name, caller)
		} else {
			[Spot{caller.file, u.line}]
		}
		for spot in spots {
			src := ctx.lines_of(spot.file)
			ln := spot.line
			mut row := Row{
				group:   gi
				orig:    u.orig
				from:    u.from
				to:      u.to
				file:    spot.file
				line:    ln
				to_file: callee.file
				to_line: callee.line
			}
			if spot.file == '' || ln < 1 || ln > src.len {
				row.status = 'no-source'
				rows << row
				continue
			}
			row.cols = if by_edge {
				mention_columns(src[ln - 1], name)
			} else {
				name_columns(src[ln - 1], name)
			}
			if row.cols.len == 0 {
				row.status = 'name-not-on-line'
				rows << row
				continue
			}
			if row.cols.len > 1 {
				row.note = '${row.cols.len} occurrences'
			}
			if prov == prov_undeclared {
				row.ctrl_cols = control_columns(src[ln - 1], row.cols)
			}
			row.progs = ctx.programs_for(spot.file)
			row.worlds = worlds_for(spot.file, os.user_os())
			rows << row
		}
	}

	println('asking V3 in the default build...')
	ctx.ask_world(mut rows, []string{}, all_rows(rows))
	if opts.worlds {
		mut tried := map[string]bool{}
		for {
			// the next build some unanswered site is compiled for
			mut world := []string{}
			for row in rows {
				if row.status != '' || row.settled() {
					continue
				}
				for w in row.worlds {
					if w.join(' ') !in tried {
						world = w.clone()
						break
					}
				}
				if world.len > 0 {
					break
				}
			}
			if world.len == 0 {
				break
			}
			tried[world.join(' ')] = true
			mut want := []int{}
			for i, row in rows {
				if row.status == '' && !row.settled()
					&& row.worlds.any(it.join(' ') == world.join(' ')) {
					want << i
				}
			}
			println('asking V3 again with ${world.join(' ')} (${want.len} sites)...')
			ctx.ask_world(mut rows, world, want)
		}
	}

	for mut row in rows {
		if row.status != '' {
			continue
		}
		if row.answers.len == 0 {
			row.status, row.note = unanswered(row, prov == prov_undeclared)
			continue
		}
		caller_name := if prov == prov_undeclared { syms[row.from].name } else { '' }
		row.ids = answer_ids(row, by_pos, caller_name)
		targets := site_targets[site_key(row.from, row.line, by_edge)]
		if prov == prov_undeclared {
			row.status = undeclared_status(row.ids, callable, targets)
			continue
		}
		row.status = if row.to in row.ids {
			'correct'
		} else if row.ids.any(it in targets) {
			'extra'
		} else if row.ids.all(it.starts_with('?')) {
			'not-in-graph'
		} else {
			'wrong'
		}
	}

	// one result per sampled unit: a reference edge's best row
	results := best_per_group(rows)
	mut summary := summarize(results, units.len, opts, commit, graph_path)
	if by_edge && !opts.self_test {
		summary += '  of the correct, ${mixed_groups(rows, results)} have a mention V3 resolves to a declaration their `from` has no edge to\n'
	}
	if prov == prov_undeclared {
		mut by_name := map[string]int{}
		for r in results {
			if r.status == 'silent' {
				by_name[r.to]++
			}
		}
		mut names := by_name.keys()
		names.sort_with_compare(fn [by_name] (a &string, b &string) int {
			return by_name[*b] - by_name[*a]
		})
		if names.len > 0 {
			more := if names.len > 8 { ', and ${names.len - 8} more names' } else { '' }
			summary += '  silent (V3 answers another name on the line, none at the call; not scored), by name: ${names#[..8].map('${it} ${by_name[it]}').join(', ')}${more}\n'
		}
	}
	println(summary)
	write_csv(os.join_path(out_dir, 'sample.csv'), rows)
	os.write_file(os.join_path(out_dir, 'summary.txt'), summary) or { eprintln(err) }
	os.write_file(os.join_path(out_dir, 'v3_raw.log'), ctx.log.str()) or { eprintln(err) }
	println('wrote sample.csv, summary.txt and v3_raw.log in ${out_dir}')

	if opts.self_test {
		faults, own_wrong, own_correct := self_test_counts(rows, results)
		scored := results.filter(it.status in ['correct', 'extra', 'wrong']).len
		if own_wrong > 0 {
			println("self-test: ${own_wrong} stand-in(s) scored correct where V3 never names the edge's own target: that edge is wrong, not the harness")
		}
		println('self-test: the original edges, from the same answers: ${own_correct} of ${scored} correct')
		if verdict := self_test_failure(scored, faults, own_correct) {
			eprintln('SELF-TEST FAILED: ${verdict}')
			exit(1)
		}
		println('self-test passed: no corrupted edge of ${scored} scored correct beside its own target')
	}
}

fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0
	for i < args.len {
		a := args[i]
		match a {
			'-kind', '-provenance', '-n', '-seed', '-out', '-v3', '-timeout' {
				if i + 1 >= args.len {
					return error('${a} needs a value')
				}
				v := args[i + 1]
				if a in ['-n', '-seed', '-timeout'] && (v.len == 0 || !v.bytes().all(it.is_digit())) {
					return error('${a} needs a whole number, not `${v}`')
				}
				// strconv refuses a number too big for its type; `.int()` would clamp it
				match a {
					'-kind' {
						if v !in ['calls', 'references', 'missing-references', 'missing-calls'] {
							return error('-kind is calls, references, missing-references or missing-calls, not `${v}`')
						}
						o.kind = v
					}
					'-provenance' {
						if v !in ['inferred', 'extracted', 'undeclared'] {
							return error('-provenance is inferred, extracted or undeclared, not `${v}`')
						}
						o.prov = v
					}
					'-n' { o.n = strconv.atoi(v) or { return error('-n ${v} is too big') } }
					'-seed' {
						o.seed = strconv.parse_uint(v, 10, 64) or {
							return error('-seed ${v} is too big')
						}
					}
					'-out' { o.out = v }
					'-v3' { o.v3 = v }
					else {
						o.timeout = strconv.atoi(v) or { return error('-timeout ${v} is too big') }
					}
				}
				i += 2
				continue
			}
			'-no-worlds' {
				o.worlds = false
			}
			'-self-test' {
				o.self_test = true
			}
			else {
				if a.starts_with('-') || o.graph != '' {
					return error('unexpected argument ${a}')
				}
				o.graph = a
			}
		}
		i++
	}
	if o.graph == '' {
		return error('no graph given')
	}
	if o.n < 1 || o.timeout < 1 {
		return error('-n and -timeout must be positive')
	}
	if o.self_test && o.kind in ['missing-references', 'missing-calls'] {
		return error('-self-test checks the edges a graph has, not those it lacks')
	}
	if o.prov != 'inferred' && o.kind in ['missing-references', 'missing-calls'] {
		return error('-provenance picks the edges a graph has; -kind ${o.kind} samples places in bodies')
	}
	if o.prov == 'undeclared' && o.kind != 'calls' {
		return error('-provenance undeclared samples calls; the undeclared references are to C and JS types')
	}
	if o.prov == 'undeclared' && o.self_test {
		return error('-self-test points an edge at another declaration, and an undeclared call has none')
	}
	return o
}

fn all_rows(rows []Row) []int {
	mut out := []int{}
	for i, row in rows {
		if row.status == '' {
			out << i
		}
	}
	return out
}

// v3_key names the V3 that `root`'s vlib builds: its commit, and a hash of the changes
// under vlib (edited or new files) when it has some. A root git can't read gets a
// new name each time, so its V3 is built every run.
fn v3_key(root string) string {
	rev := os.exec(['git', '-C', root, 'rev-parse', 'HEAD'])
	diff := os.exec(['git', '-C', root, 'diff', 'HEAD', '--', 'vlib'])
	untracked := os.exec(['git', '-C', root, 'ls-files', '--others', '--exclude-standard', '-z',
		'--', 'vlib'])
	head := rev.output.trim_space()
	if rev.exit_code != 0 || diff.exit_code != 0 || untracked.exit_code != 0 || head.len < 12
		|| !head.bytes().all(it.is_hex_digit()) {
		return 'nogit-${time.now().unix_milli()}'
	}
	mut dirty := diff.output
	for f in untracked.output.split('\0') {
		if f != '' {
			dirty += '\0${f}\0' + (os.read_file(os.join_path(root, f)) or { '' })
		}
	}
	return if dirty != '' {
		'${head[..12]}-dirty-${fnv1a.sum64_string(dirty):x}'
	} else {
		head[..12]
	}
}

// build_v3 builds the root's V3 compiler, with `defines`, once per v3_key.
fn (mut ctx Ctx) build_v3(defines []string) !string {
	mut key := v3_key(ctx.root)
	for d in defines {
		key += '-d-${d}'
	}
	exe := $if windows { '.exe' } $else { '' }
	path := os.join_path(ctx.cache_dir, 'v3-${key}${exe}')
	if os.exists(path) {
		return path
	}
	os.mkdir_all(ctx.cache_dir)!
	mut args := ['-gc', 'none', '-prealloc', '-path', '${ctx.root}/vlib|@vlib|@vmodules']
	for d in defines {
		args << ['-d', d]
	}
	// built under another name and moved into place, so a build cut short leaves
	// nothing a later run would take for a V3
	tmp := os.join_path(ctx.cache_dir, 'building-${key}-${os.getpid()}${exe}')
	args << ['-o', tmp, os.join_path(ctx.root, 'vlib', 'v', 'v.v')]
	println('building V3 (${key}) with ${ctx.vexe}...')
	code, out := run_bounded(ctx.vexe, args, ctx.root, 30 * time.minute)
	// on Windows V writes `<exe>.manifest` beside it (long paths), which goes with it
	tmp_manifest := tmp + '.manifest'
	if code != 0 || !os.exists(tmp) {
		os.rm(tmp) or {}
		os.rm(tmp_manifest) or {}
		return error('building V3 failed (exit ${code}):\n${out}')
	}
	if os.exists(tmp_manifest) {
		os.mv(tmp_manifest, path + '.manifest', overwrite: true) or {}
	}
	os.mv(tmp, path) or {
		// another run built the same V3 first
		os.rm(tmp) or {}
		if !os.exists(path) {
			return err
		}
	}
	return path
}

fn (mut ctx Ctx) lines_of(rel string) []string {
	if rel !in ctx.files {
		ctx.files[rel] = os.read_lines(os.join_path(ctx.root, rel)) or { []string{} }
	}
	return ctx.files[rel]
}

// programs_for is every program V3 can check that compiles `rel`, best first.
fn (mut ctx Ctx) programs_for(rel string) []string {
	src_dir := os.dir(rel).replace('\\', '/')
	fname := os.file_name(rel)
	if fname.contains('_test.') {
		return [rel, src_dir]
	}
	src := ctx.lines_of(rel)
	mut mod := 'main'
	mut seen_module := false
	mut has_main := false
	for l in src {
		t := l.trim_space()
		if !seen_module && t.starts_with('module ') {
			// the first one: a later `module x` is text, in a string say
			mod = t.all_after('module ').trim_space()
			seen_module = true
		}
		if t.starts_with('fn main()') {
			has_main = true
		}
	}
	if mod == 'main' {
		// a directory of separate programs, or one program over several files
		return if has_main { [rel, src_dir] } else { [src_dir] }
	}
	mut out := [src_dir]
	if src_dir.starts_with('vlib/') {
		out << ctx.synthetic_main(src_dir['vlib/'.len..].replace('/', '.'))
	}
	mut tests := (os.ls(os.join_path(ctx.root, src_dir)) or { []string{} }).filter(it.contains('_test.')
		&& it.ends_with('.v'))
	tests.sort()
	for t in tests#[..3] {
		out << '${src_dir}/${t}'
	}
	return out
}

// synthetic_main is a program that only imports `module`.
fn (mut ctx Ctx) synthetic_main(module_path string) string {
	prog_dir := os.join_path(ctx.out_dir, 'programs', module_path.replace('.', '_'))
	file := os.join_path(prog_dir, 'main.v')
	if !os.exists(file) {
		os.mkdir_all(prog_dir) or {}
		os.write_file(file, 'module main\n\nimport ${module_path} as _\n\nfn main() {}\n') or {}
	}
	return file
}

// worlds_for is each build, other than the host's default one, that compiles `rel`:
// the one its name asks for, then each of Linux, macOS and Windows that is not `host`.
fn worlds_for(rel string, host string) [][]string {
	flags := file_flags(rel, host)
	mut out := [][]string{}
	if flags.len > 0 {
		out << flags
	}
	for os_name in ['linux', 'macos', 'windows'] {
		if os_name == host {
			continue
		}
		w := ['-os', os_name]
		if w.join(' ') != flags.join(' ') {
			out << w
		}
	}
	return out
}

// file_flags is the `-d` or `-os` a file's name compiles it under, as
// get_v_files_from_dir_for_backend_target in vlib/v/pref/pref.v reads
// `_d_use_openssl.v` and `_linux.c.v`; none for a file the default build on `host`
// compiles. Everything after `_d_` is the define, and a `_d_` or `_notd_` file has
// no OS of its own.
fn file_flags(rel string, host string) []string {
	name := os.file_name(rel)
	if name.contains('_notd_') {
		return []
	}
	if i := name.index('_d_') {
		mut feature := name[i + 3..]
		if feature.ends_with('.c.v') {
			feature = feature[..feature.len - 4]
		} else if feature.ends_with('.v') {
			feature = feature[..feature.len - 2]
		}
		return if feature != '' { ['-d', feature] } else { [] }
	}
	for m in os_markers {
		if name.contains('_${m[0]}.') {
			on_host := match m[0] {
				'nix' { host != 'windows' }
				'bsd' { host in ['macos', 'freebsd', 'openbsd', 'netbsd', 'dragonfly'] }
				'android' { host in ['android', 'termux'] }
				else { m[1] == host }
			}
			return if on_host { [] } else { ['-os', m[1]] }
		}
	}
	return []
}

// tree_mismatch is why `root` can't be checked against a graph extracted at `commit`
// (its manifest's source_commit): the tree is at another commit, so the graph's lines
// are not its lines. None when they agree, or when either commit is unknown.
fn tree_mismatch(root string, commit string) ?string {
	if commit == '' {
		return none
	}
	rev := os.exec(['git', '-C', root, 'rev-parse', 'HEAD'])
	head := rev.output.trim_space()
	if rev.exit_code != 0 || head == '' || head == commit {
		return none
	}
	return 'the graph was extracted at ${commit#[..12]}, but ${root} is at ${head#[..12]}: re-extract it, or check out ${commit#[..12]}'
}

// tree_drift lists how the tree at `root` differs from the `files` the extract read,
// each as `changed <path>`, `missing <path>` or `new <path>`: a file whose text hash is
// not the recorded one, or that is gone, and an untracked `.v` file (as git lists them)
// in a folder that holds one of `files`, which changes that module's compile. A new file
// elsewhere changes no answer and is not listed (a folder the extract skips, such as
// `thirdparty`, holds none of `files`). An untracked file the extract read is one of
// `files`, not new. Not a git checkout, the new files are not looked for.
fn tree_drift(root string, files []SourceFile) []string {
	mut out := []string{}
	mut known := map[string]bool{}
	mut dirs := map[string]bool{}
	for f in files {
		known[f.path] = true
		dirs[folder_of(f.path)] = true
		text := os.read_file(os.join_path(root, f.path)) or {
			out << 'missing ${f.path}'
			continue
		}
		if sha256.hexhash(text.replace('\r\n', '\n')) != f.hash {
			out << 'changed ${f.path}'
		}
	}
	res := os.exec(['git', '-C', root, 'ls-files', '--others', '--exclude-standard', '-z', '--',
		'*.v'])
	if res.exit_code == 0 {
		for p in res.output.split('\0') {
			if p == '' || p in known || !dirs[folder_of(p)] {
				continue
			}
			out << 'new ${p}'
		}
	}
	return out
}

// folder_of is the folder of `path`, root-relative with `/` separators ('' at the root).
fn folder_of(path string) string {
	p := path.replace('\\', '/')
	return if p.contains('/') { p.all_before_last('/') } else { '' }
}

// unit_name is what one sampled unit of `kind` is, in the plural.
fn unit_name(kind string) string {
	return match kind {
		'references' { 'reference edges' }
		'missing-references' { 'type names in bodies' }
		'missing-calls' { 'calls written in bodies' }
		else { 'call sites' }
	}
}

// missing_places measures what the edges leave out, which the other kinds, asking only
// about edges the graph has, cannot. With -kind missing-references it takes a seeded
// sample of the places a function's or method's body writes a capitalized name (type_name_columns), each asked of V3. A place
// V3 resolves to a type of the graph is `linked` when the graph has a `references` or
// `embeds` edge from that declaration to it, and `missing` when it has none; one V3
// resolves to something else (a function, an enum value, a constant) is `not-a-type`. A
// declaration's first line is its signature's, which is not asked, but a signature written
// over several lines has its later lines asked, and their types count as linked through the
// signature's edge. The scan reads one line at a time: a `/* */` comment, a string over
// several lines or a raw string's `\` is read as code (a place V3 gives no answer for), and a
// `${...}` in a string is not read. A `missing` place whose
// name is followed by `.` (`Color.red`, `Foo.new()`) is counted apart: the graph reads
// one as a type by its capital (see body_type_refs in backend_v.v), so one still missing
// is a name it read some other way.
//
// With -kind missing-calls it does the same for calls: the places a body writes a
// name followed by `(` (call_name_columns). A place V3 resolves to a function, method, or
// a constant, global or field holding one, is `linked` when the graph has a `calls` edge
// from that declaration to it whose lines hold the place's line. One that isn't is, in
// this order:
//   other-line   an edge to it exists, but its lines don't hold this one: not scored
//                (see call_misses), to be read by hand
//   other-target an edge on the line, of the call's name, goes to another declaration
//   undeclared   one on the line, of that name, is marked undeclared
//   unresolved   one on the line, of that name, is left unresolved
//   missing      no edge of that name on the line at all
// and recall is linked over linked and the last four. A place V3 resolves to a type (a
// cast) is `not-a-call`; one it resolves to a declaration that is no graph symbol (a local
// variable holding a function, a C header, or a parameter: an answer on the caller's own
// first line, for another name than the caller's) is `not-in-graph`. As for types, a line
// is read on its own, so a call inside a string's `${...}` is not sampled, nor is a generic
// call written with its type arguments (`f[int](x)`), nor a cast to a primitive type. An
// edge records lines, not the file, so a function declared once per platform under one id
// counts a place as linked when another copy has an edge to V3's declaration on the same
// line number.
fn missing_places(mut ctx Ctx, g GGraph, by_pos map[string][]string, opts Options, commit string, graph_path string) {
	calls := opts.kind == 'missing-calls'
	mut kind_of := map[string]int{}
	mut name_of := map[string]string{}
	// an id is callable when any symbol under it is: a module and its function can share one
	// (`vlib.rand.seed`), and kind_of keeps only the last
	mut callable := map[string]bool{}
	mut in_file := map[string][]GSymbol{}
	for s in g.symbols {
		kind_of[s.id] = s.kind
		name_of[s.id] = s.name
		if s.kind in callable_kinds {
			callable[s.id] = true
		}
		in_file[s.file] << s
	}
	mut linked := map[string]bool{} // from \t to, and for a call from \t to \t line
	mut on_line := map[string][]GEdge{} // a call's edges, by from \t line
	for e in g.edges {
		if calls && e.kind == edge_calls {
			linked['${e.from}\t${e.to}'] = true
			for ln in e.lines {
				linked['${e.from}\t${e.to}\t${ln}'] = true
				on_line['${e.from}\t${ln}'] << e
			}
		} else if !calls && e.kind in [edge_references, 4] {
			linked['${e.from}\t${e.to}'] = true
		}
	}
	mut units := []Row{}
	for s in g.symbols {
		if s.kind !in [kind_function, kind_method] {
			continue
		}
		src := ctx.lines_of(s.file)
		if s.line < 1 || s.line > src.len {
			continue
		}
		for ln in s.line + 1 .. decl_last_line(src, s, in_file[s.file]) + 1 {
			cols := if calls {
				call_name_columns(src[ln - 1])
			} else {
				type_name_columns(src[ln - 1])
			}
			for col in cols {
				units << Row{
					from: s.id
					file: s.file
					line: ln
					cols: [col]
				}
			}
		}
	}
	println('population: ${units.len} ${unit_name(opts.kind)}')
	if units.len == 0 {
		exit(1)
	}
	mut rng := Rng{
		s: opts.seed
	}
	mut picks := []int{len: units.len, init: index}
	n := if opts.n < units.len { opts.n } else { units.len }
	for i in 0 .. n {
		j := i + rng.below(units.len - i)
		picks[i], picks[j] = picks[j], picks[i]
	}
	mut rows := []Row{cap: n}
	for i in 0 .. n {
		mut row := units[picks[i]]
		row.group = i
		text := ctx.lines_of(row.file)[row.line - 1]
		name := name_at(text, row.cols[0])
		row.to = name
		end := row.cols[0] + name.len
		if calls {
			if row.cols[0] > 0 && text[row.cols[0] - 1] == `.` {
				row.note = 'method or qualified'
			}
		} else if end < text.len && text[end] == `.` {
			row.note = 'followed by .'
		}
		row.progs = ctx.programs_for(row.file)
		row.worlds = worlds_for(row.file, os.user_os())
		rows << row
	}
	println('asking V3 in the default build...')
	ctx.ask_world(mut rows, []string{}, all_rows(rows))
	if opts.worlds {
		mut tried := map[string]bool{}
		for {
			mut world := []string{}
			for row in rows {
				if row.answers.len > 0 {
					continue
				}
				for w in row.worlds {
					if w.join(' ') !in tried {
						world = w.clone()
						break
					}
				}
				if world.len > 0 {
					break
				}
			}
			if world.len == 0 {
				break
			}
			tried[world.join(' ')] = true
			mut want := []int{}
			for i, row in rows {
				if row.answers.len == 0 && row.worlds.any(it.join(' ') == world.join(' ')) {
					want << i
				}
			}
			println('asking V3 again with ${world.join(' ')} (${want.len} places)...')
			ctx.ask_world(mut rows, world, want)
		}
	}
	for mut row in rows {
		if row.answers.len == 0 {
			row.status = 'no-answer'
			continue
		}
		mut ids := []string{}
		for a in row.answers {
			path, ln := split_answer(a) or { continue }
			at := by_pos['${path}:${ln}']
			if calls && row.from in at && name_of[row.from] != row.to {
				// the caller's own first line, for a name that isn't its own: a parameter
				ids << '?parameter ${path}:${ln}'
			} else if at.len > 0 {
				ids << at
			} else {
				ids << '?${path}:${ln}'
			}
		}
		row.ids = dedupe(ids)
		if calls {
			row.status = call_status(row, callable, name_of, linked, on_line)
			continue
		}
		types := row.ids.filter(kind_of[it] in type_kinds)
		row.status = if types.any('${row.from}\t${it}' in linked) {
			'linked'
		} else if types.len > 0 {
			'missing'
		} else if row.ids.all(it.starts_with('?')) {
			'not-in-graph'
		} else {
			'not-a-type'
		}
	}
	mut counts := map[string]int{}
	for row in rows {
		counts[row.status]++
	}
	found := counts['linked']
	misses := if calls { call_misses } else { ['missing'] }
	mut scored := found
	for st in misses {
		scored += counts[st]
	}
	lo, hi := wilson(found, scored)
	mut s := strings.new_builder(1024)
	s.writeln('graph: ${graph_path}${if commit != '' { ' (' + commit#[..10] + ')' } else { '' }}')
	s.writeln('population: ${units.len} ${unit_name(opts.kind)}; sample ${rows.len}, seed ${opts.seed}')
	unscored := if calls { 'not-a-call' } else { 'not-a-type' }
	mut listed := ['linked']
	listed << misses
	if calls {
		listed << 'other-line'
	}
	listed << [unscored, 'not-in-graph', 'no-answer']
	for st in listed {
		if counts[st] > 0 {
			s.writeln('  ${st:-17} ${counts[st]}')
		}
	}
	noted := rows.filter(it.status in misses && it.note != '').len
	if scored > 0 {
		s.writeln('linked: ${found}/${scored} = ${100 * f64(found) / f64(scored):.2f}% (95% Wilson ${100 * lo:.2f}-${100 * hi:.2f}%)')
		if calls {
			s.writeln("  of the not linked, ${noted} are a name after `.` (a method, or a module's function)")
		} else {
			s.writeln('  of the missing, ${noted} are a name followed by `.` (an enum value or a static call)')
		}
	}
	summary := s.str()
	println(summary)
	write_csv(os.join_path(ctx.out_dir, 'sample.csv'), rows)
	os.write_file(os.join_path(ctx.out_dir, 'summary.txt'), summary) or { eprintln(err) }
	os.write_file(os.join_path(ctx.out_dir, 'v3_raw.log'), ctx.log.str()) or { eprintln(err) }
	println('wrote sample.csv, summary.txt and v3_raw.log in ${ctx.out_dir}')
}

// call_status is what a sampled call place is, once V3 has answered it (see missing_places):
// `callable` holds the ids of functions, methods, and constants, globals and fields that can
// hold one; `name_of` every symbol's name by id; `linked` from \t to and from \t to \t line
// for each calls edge; and `on_line` a caller's calls edges by from \t line.
fn call_status(row Row, callable_ids map[string]bool, name_of map[string]string, linked map[string]bool, on_line map[string][]GEdge) string {
	callable := row.ids.filter(it in callable_ids)
	if callable.len == 0 {
		return if row.ids.all(it.starts_with('?')) { 'not-in-graph' } else { 'not-a-call' }
	}
	if callable.any('${row.from}\t${it}\t${row.line}' in linked) {
		return 'linked'
	}
	if callable.any('${row.from}\t${it}' in linked) {
		return 'other-line'
	}
	// the edges on the line that are of this call's name: a resolved one by its target's
	// name, an unresolved one by its raw name's last part
	mut seen := map[string]bool{}
	for e in on_line['${row.from}\t${row.line}'] {
		// (an unresolved static call keeps its type before the method: `Foo__static__new`)
		target := name_of[e.to] or {
			e.to.all_before('[').all_after_last('.').all_after_last('__static__')
		}
		if target != row.to {
			continue
		}
		seen[if e.to in name_of {
			'other-target'
		} else if e.provenance == prov_undeclared {
			'undeclared'
		} else {
			'unresolved'
		}] = true
	}
	for st in call_misses {
		if st in seen {
			return st
		}
	}
	return 'missing'
}

// unanswered is the status and note of a row V3 gave no answer at the call for: `silent`
// for an undeclared call (`undeclared`) when V3 answered another name on its line (its
// `ctrl`), as it checked the body; not scored, as V3 is silent about some calls of a
// declaration too (`i.str()` on an int). `no-answer` otherwise.
fn unanswered(row Row, undeclared bool) (string, string) {
	if !undeclared || row.ctrl == '' {
		return 'no-answer', row.note
	}
	answered := 'answers ${normalize_answer(row.ctrl)} on the line'
	return 'silent', if row.note == '' { answered } else { '${row.note}; ${answered}' }
}

// answer_ids is what each of `row`'s answers names: the symbols declared on its line
// (`by_pos`), or `?file:line` when none is. With a `caller_name` (for an undeclared call),
// an answer on the caller's own first line, for a call of another name than the caller's,
// is a parameter, `?parameter file:line`, as missing_places reads it.
fn answer_ids(row Row, by_pos map[string][]string, caller_name string) []string {
	called := row.to.all_before('[').all_after_last('.').all_after_last('__static__')
	mut ids := []string{}
	for a in row.answers {
		path, ln := split_answer(a) or { continue }
		at := by_pos['${path}:${ln}']
		if caller_name != '' && row.from in at && caller_name != called {
			ids << '?parameter ${path}:${ln}'
		} else if at.len > 0 {
			ids << at
		} else {
			ids << '?${path}:${ln}'
		}
	}
	return dedupe(ids)
}

// take records answer `a` to one of `row`'s questions, asked in program `prog` and build
// `world`: at the call, or (`ctrl`) at another name on its line, of which the first answer
// is kept. Either names where the row was answered, an answer at the call first.
fn (mut row Row) take(a string, ctrl bool, prog string, world string) {
	if ctrl {
		if row.ctrl == '' {
			row.ctrl = a
		}
		if row.answers.len == 0 {
			row.program = prog
			row.world = world
		}
		return
	}
	row.answers << a
	row.program = prog
	row.world = world
}

// undeclared_status scores a site of a call the graph marks undeclared, from the ids V3's
// answers name there: `correct` when none is in `callable` (a function, method, or constant,
// global or field of the graph), `extra` when one is and the site has an edge to it too
// (`targets`), and `wrong` when the site has no edge to any: a declaration the graph missed.
fn undeclared_status(ids []string, callable map[string]bool, targets map[string]bool) string {
	named := ids.filter(it in callable)
	return if named.len == 0 {
		'correct'
	} else if named.any(it in targets) {
		'extra'
	} else {
		'wrong'
	}
}

// control_columns is where to ask V3 about other names on `text` than the call at `cols`,
// nearest first and at most 4: an answer to one shows V3 checked the body, which tells a
// silent site from one never reached. Keywords, primitive types (call_keywords) and numbers are
// left out, as V3 names no declaration for them.
fn control_columns(text string, cols []int) []int {
	mut found := []int{}
	for span in code_names(text) {
		if span.start in cols || text[span.start].is_digit()
			|| text[span.start..span.end] in call_keywords {
			continue
		}
		found << span.start
	}
	at := if cols.len > 0 { cols[0] } else { 0 }
	found.sort_with_compare(fn [at] (a &int, b &int) int {
		return math.abs(*a - at) - math.abs(*b - at)
	})
	return found#[..4]
}

// NameSpan is a name a line writes: its first byte's column, the column after it, and
// the byte before it (a space at the line's start).
struct NameSpan {
	start int
	end   int
	prev  u8
}

// code_names is every name `text`, a line of a body, writes outside strings and before
// any `//`: none on an attribute line.
fn code_names(text string) []NameSpan {
	mut out := []NameSpan{}
	if text.trim_left(' \t').starts_with('@[') {
		return out
	}
	mut quote := u8(0)
	mut i := 0
	for i < text.len {
		c := text[i]
		if quote != 0 {
			if c == `\\` {
				i += 2
				continue
			}
			if c == quote {
				quote = 0
			}
			i++
			continue
		}
		if c in [`'`, `"`, `\``] {
			quote = c
			i++
			continue
		}
		if c == `/` && i + 1 < text.len && text[i + 1] == `/` {
			break
		}
		if is_name_byte(c) {
			start := i
			for i < text.len && is_name_byte(text[i]) {
				i++
			}
			out << NameSpan{
				start: start
				end:   i
				prev:  if start > 0 { text[start - 1] } else { ` ` }
			}
			continue
		}
		i++
	}
	return out
}

// call_name_columns is the 0-based byte columns where `text`, a line of a body, writes a
// call: a name right before `(`, not a keyword or primitive type (call_keywords) unless
// after a `.`, a number, a `$` or `@` name, or a capitalized one (a cast or a struct's
// name), except a `C.` or `JS.` function's.
fn call_name_columns(text string) []int {
	mut out := []int{}
	for n in code_names(text) {
		if n.end >= text.len || text[n.end] != `(` || n.prev in [`$`, `@`]
			|| text[n.start].is_digit() {
			continue
		}
		name := text[n.start..n.end]
		// after a `.` the name is a member, which may be named as a keyword or a primitive
		// type is (`m.lock()`, `s.int()`)
		if n.prev != `.` && name in call_keywords {
			continue
		}
		if text[n.start].is_capital() {
			before := text[..n.start]
			mut foreign := false
			for p in ['C.', 'JS.'] {
				if before.ends_with(p) {
					k := before.len - p.len
					foreign = k == 0 || !is_name_byte(before[k - 1])
				}
			}
			if !foreign {
				continue
			}
		}
		out << n.start
	}
	return out
}

// type_name_columns is the 0-based byte columns where `text`, a line of a body, writes a
// name that starts with a capital and is two characters long or more, as V names a type
// (a one-letter one is a type parameter): outside strings and after no `//`, and not
// part of a longer name, of a `$` or `@` one, or of an attribute line.
fn type_name_columns(text string) []int {
	mut out := []int{}
	for n in code_names(text) {
		if text[n.start].is_capital() && n.end - n.start >= 2 && n.prev !in [`$`, `@`] {
			out << n.start
		}
	}
	return out
}

// name_at is the name written at column `col` of `text`.
fn name_at(text string, col int) string {
	mut e := col
	for e < text.len && is_name_byte(text[e]) {
		e++
	}
	return text[col..e]
}

// site_key names a site: the caller and line of a call; for a reference, which is
// scored whole, the symbol it is from.
fn site_key(from string, line int, by_edge bool) string {
	return if by_edge { from } else { '${from}\t${line}' }
}

// decl_end is the last line (1-based) of the declaration that starts on line `start`
// of `src`: where the brackets opened from `start` are all closed again. Brackets in
// strings (a string can run over several lines), runes and after `//` are not counted.
fn decl_end(src []string, start int) int {
	mut depth := 0
	mut quote := u8(0)
	for ln in start .. src.len + 1 {
		text := src[ln - 1]
		mut i := 0
		for i < text.len {
			c := text[i]
			if quote != 0 {
				if c == `\\` {
					i++
				} else if c == quote {
					quote = 0
				}
			} else if c in [`'`, `"`, `\``] {
				quote = c
			} else if c == `/` && i + 1 < text.len && text[i + 1] == `/` {
				break
			} else if c in [`{`, `(`, `[`] {
				depth++
			} else if c in [`}`, `)`, `]`] {
				depth--
			}
			i++
		}
		if depth <= 0 {
			return ln
		}
	}
	return src.len
}

// mention_spots is where to ask V3 about a reference to `name` from the declaration
// `decls` are the copies of (one per file declaring its id; `in_file` holds every
// file's declarations): the lines of each copy that name it, 8 at most in all, or
// `caller`'s own line when none does, which is then reported as name-not-on-line.
fn (mut ctx Ctx) mention_spots(decls []GSymbol, in_file map[string][]GSymbol, name string, caller GSymbol) []Spot {
	mut spots := []Spot{}
	for c in decls {
		src := ctx.lines_of(c.file)
		if c.line < 1 || c.line > src.len {
			continue
		}
		for ln in c.line .. decl_last_line(src, c, in_file[c.file]) + 1 {
			if spots.len < max_mention_lines && mention_columns(src[ln - 1], name).len > 0 {
				spots << Spot{c.file, ln}
			}
		}
	}
	if spots.len == 0 {
		spots << Spot{caller.file, caller.line}
	}
	return spots
}

// self_test_counts is, of the -self-test `results` (one per edge), how many stand-ins
// scored correct while V3 also names the edge's own target (a fault of the harness),
// and how many scored correct where V3 never names it (the edge itself is wrong: V3's
// answer does not depend on the edge's target, so the stand-in is V's declaration).
// `rows` are every row asked, whose answers the own target is looked for in. The third
// count is how many of the scored edges' own targets V3 names: the originals, scored
// from the same answers, which a harness that misreads V3 would score badly.
fn self_test_counts(rows []Row, results []Row) (int, int, int) {
	mut group_ids := map[int][]string{}
	for row in rows {
		group_ids[row.group] << row.ids
	}
	mut faults := 0
	mut own_wrong := 0
	mut own_correct := 0
	for r in results {
		// (an unscored edge never names its own target: a row that does is scored)
		own_named := r.orig in group_ids[r.group]
		if own_named {
			own_correct++
		}
		if r.status == 'correct' {
			if own_named {
				faults++
			} else {
				own_wrong++
			}
		}
	}
	return faults, own_wrong, own_correct
}

// self_test_failure is why the self-test fails, if it does: no corrupted edge scored;
// one scored correct while V3 also names its edge's own target; or fewer than 90% of
// the original edges correct from the same answers, which V3's own answers give for a
// sound harness (99.7% and more on vlang) and a harness misreading them would not.
fn self_test_failure(scored int, faults int, own_correct int) ?string {
	if scored == 0 {
		return 'no corrupted edge could be scored'
	}
	if faults > 0 {
		return '${faults} of ${scored} corrupted edges scored correct beside their own target'
	}
	if own_correct * 10 < scored * 9 {
		return 'only ${own_correct} of ${scored} original edges are correct from the same answers (90% at least)'
	}
	return none
}

// decl_last_line is the last line of `d`, a declaration in `src`, whose file declares
// `in_file`: where its brackets close (decl_end), but no later than the line before the
// next declaration after it that is not one of its members (a field of a struct), as
// a quote decl_end takes for a string's (in a `/* */` comment, say) leaves it open.
// Left open to the end of the file with nothing after it, it ends at the last `}`
// written alone at its own indentation, as vfmt closes a body.
fn decl_last_line(src []string, d GSymbol, in_file []GSymbol) int {
	mut last := decl_end(src, d.line)
	for o in in_file {
		if o.parent != d.id && o.line > d.line && o.line - 1 < last {
			last = o.line - 1
		}
	}
	// a later declaration bounds it before the last line, so this is only when none does
	if last == src.len {
		first := src[d.line - 1]
		close := first[..first.len - first.trim_left(' \t').len] + '}'
		for e := src.len; e > d.line; e-- {
			if src[e - 1].trim_right(' \t\r') == close {
				return e
			}
		}
	}
	return last
}

// mixed_groups is how many of the reference edges scored correct (`results`, one per
// edge) also have a mention V3 resolves to a declaration their `from` has no edge to
// (a `wrong` row among `rows`): a mention of the name that means something else, such
// as a method call, or an edge the graph lacks.
fn mixed_groups(rows []Row, results []Row) int {
	mut has_wrong := map[int]bool{}
	for row in rows {
		if row.status == 'wrong' {
			has_wrong[row.group] = true
		}
	}
	return results.filter(it.status == 'correct' && has_wrong[it.group]).len
}

// best_per_group is one row per sampled unit: of a unit's rows, the one whose status
// counts most (correct, then extra, wrong, not-in-graph, no-answer, name-not-on-line,
// no-source), the first of them on a tie.
fn best_per_group(rows []Row) []Row {
	order := ['correct', 'extra', 'wrong', 'not-in-graph', 'no-answer', 'name-not-on-line', 'no-source']
	mut best := map[int]int{} // group -> index of its best row
	mut groups := []int{}
	for i, row in rows {
		if row.group !in best {
			best[row.group] = i
			groups << row.group
			continue
		}
		if order.index(row.status) < order.index(rows[best[row.group]].status) {
			best[row.group] = i
		}
	}
	return groups.map(rows[best[it]])
}

// same_role tells whether a declaration of kind `kind` could stand in for an edge's
// target of kind `target` in the self-test: for a call any function or method, for a
// reference a declaration of the target's own kind.
fn same_role(kind int, target int, edge_kind int) bool {
	if edge_kind == edge_calls {
		return kind == kind_function || kind == kind_method
	}
	return kind == target
}

// mention_columns is the 0-based byte columns where `name` is written on `text`, every
// one: a reference's type can sit beside a call of a method with its name
// (`x.string()` and `string`), and only V3 tells them apart.
fn mention_columns(text string, name string) []int {
	mut out := []int{}
	if name == '' {
		return out
	}
	for i := 0; i + name.len <= text.len; i++ {
		if text[i..i + name.len] == name && (i == 0 || !(is_name_byte(text[i - 1])
			|| text[i - 1] == `$`)) && (i + name.len == text.len
			|| !is_name_byte(text[i + name.len])) {
			out << i
		}
	}
	return out
}

// name_columns is the 0-based byte columns where `name` is called on `text`, or,
// when it is not called there, where it is written at all.
fn name_columns(text string, name string) []int {
	mut calls := []int{}
	mut mentions := []int{}
	if name == '' {
		return calls
	}
	for i := 0; i + name.len <= text.len; i++ {
		if text[i..i + name.len] != name {
			continue
		}
		if i > 0 && (is_name_byte(text[i - 1]) || text[i - 1] == `$`) {
			continue
		}
		mut k := i + name.len
		if k < text.len && is_name_byte(text[k]) {
			continue
		}
		mentions << i
		for k < text.len && text[k] == ` ` {
			k++
		}
		if k < text.len && text[k] == `[` {
			mut depth := 0
			for k < text.len {
				if text[k] == `[` {
					depth++
				} else if text[k] == `]` {
					depth--
					if depth == 0 {
						k++
						break
					}
				}
				k++
			}
		}
		if k < text.len && text[k] == `(` {
			calls << i
		}
	}
	return if calls.len > 0 { calls } else { mentions }
}

fn is_name_byte(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// ask_world asks V3, in the build `world`, about the sites `want`, each in its
// programs one after another until one answers.
fn (mut ctx Ctx) ask_world(mut rows []Row, world []string, want []int) {
	mut round := 0
	for {
		mut queries := map[string][]int{} // program -> rows asked in it
		for i in want {
			row := rows[i]
			if !row.settled() && round < row.progs.len {
				queries[row.progs[round]] << i
			}
		}
		if queries.len == 0 {
			return
		}
		mut progs := queries.keys()
		progs.sort()
		for pi, prog in progs {
			print('\r  round ${round}: program ${pi + 1}/${progs.len}   ')
			flush_stdout()
			ctx.ask_program(mut rows, world, prog, queries[prog])
		}
		println('')
		round++
	}
}

fn (mut ctx Ctx) ask_program(mut rows []Row, world []string, prog string, idxs []int) {
	mut specs := []string{}
	mut owner := []int{}
	mut owner_col := []int{}
	mut is_ctrl := []bool{}
	for i in idxs {
		for c in rows[i].cols {
			specs << '${rows[i].file}:${rows[i].line}:gd^${c}'
			owner << i
			owner_col << c
			is_ctrl << false
		}
		for c in rows[i].ctrl_cols {
			specs << '${rows[i].file}:${rows[i].line}:gd^${c}'
			owner << i
			owner_col << c
			is_ctrl << true
		}
	}
	for start := 0; start < specs.len; start += batch_size {
		end := if start + batch_size < specs.len { start + batch_size } else { specs.len }
		chunk := specs[start..end].clone()
		got := ctx.ask(world, prog, chunk)
		for k, a in got {
			ri := owner[start + k]
			if !is_answer(a) || at_question(a, rows[ri].file, rows[ri].line, owner_col[start + k]) {
				continue
			}
			rows[ri].take(a, is_ctrl[start + k], prog, world.join(' '))
		}
	}
}

// ask asks V3 the `specs` in one run, and returns each one's answer ('' for none).
fn (mut ctx Ctx) ask(world []string, prog string, specs []string) []string {
	mut joined := specs.join('\t')
	if specs.len == 1 {
		// a lone question is answered without its index
		joined += '\t' + specs[0]
	}
	mut args := world.clone()
	args << ['-w', '-check', '-nocolor', '-vls-mode', '-line-info', joined, prog]
	mut v3 := ctx.v3
	mut code, mut out := run_bounded(v3, args, ctx.root, ctx.timeout)
	if out.contains('is not compiled into this v3 executable') {
		// a define V3 must be built with
		defines := define_flags(world)
		key := defines.join(',')
		if key != '' && key !in ctx.variants {
			ctx.variants[key] = if ctx.can_build {
				ctx.build_v3(defines) or {
					eprintln(err.msg())
					''
				}
			} else {
				eprintln('the -v3 binary was not built with -d ${defines.join(' -d ')}: its sites stay unanswered')
				''
			}
		}
		if ctx.variants[key] != '' {
			v3 = ctx.variants[key]
			code, out = run_bounded(v3, args, ctx.root, ctx.timeout)
		}
	}
	ctx.log.writeln('### ${world.join(' ')} ${prog} (${specs.len} questions, exit ${code})')
	ctx.log.writeln(out)
	mut got := []string{len: specs.len}
	for line in out.split_into_lines() {
		idx := line.all_before('\t')
		if idx == line || idx.len == 0 || !idx.bytes().all(it.is_digit()) {
			continue
		}
		k := idx.int()
		if k < specs.len {
			got[k] = line.all_after('\t').trim_space()
		}
	}
	return got
}

fn define_flags(world []string) []string {
	mut out := []string{}
	for i, w in world {
		if w == '-d' && i + 1 < world.len {
			out << world[i + 1]
		}
	}
	return out
}

// run_bounded runs `exe` with `args` in `dir`, and kills it after `limit`.
fn run_bounded(exe string, args []string, dir string, limit time.Duration) (int, string) {
	mut p := os.new_process(exe)
	p.set_args(args)
	p.set_work_folder(dir)
	p.set_redirect_stdio()
	p.run()
	sw := time.new_stopwatch()
	mut out := strings.new_builder(4096)
	mut killed := false
	for p.is_alive() {
		for p.is_pending(.stdout) {
			out.write_string(p.stdout_read())
		}
		for p.is_pending(.stderr) {
			out.write_string(p.stderr_read())
		}
		if sw.elapsed() > limit {
			p.signal_kill()
			killed = true
			break
		}
		time.sleep(10 * time.millisecond)
	}
	p.wait()
	out.write_string(p.stdout_slurp())
	out.write_string(p.stderr_slurp())
	code := if killed { -1 } else { p.code }
	p.close()
	if killed {
		out.write_string('\nTIMEOUT after ${limit}')
	}
	return code, out.str()
}

// at_question tells whether answer `a` is the very place it was asked about: `file`,
// `line`, 0-based byte column `col` (as V3 gives its own). The name written there is
// then declared there (a parameter, a field, the declaration's own name), and names
// no declaration elsewhere.
fn at_question(a string, file string, line int, col int) bool {
	path, ln := split_answer(a) or { return false }
	return path == file && ln == line && a.all_after_last(':').trim_space() == col.str()
}

fn is_answer(a string) bool {
	_, _ := split_answer(a) or { return false }
	return true
}

// split_answer is the root-relative file and the line of a `path:line:col` answer.
fn split_answer(a string) ?(string, int) {
	c := a.last_index(':') or { return none }
	l := a[..c].last_index(':') or { return none }
	ln := a[l + 1..c]
	if ln.len == 0 || !ln.bytes().all(it.is_digit()) {
		return none
	}
	return normalize(a[..l]), ln.int()
}

fn normalize(path string) string {
	mut p := path.replace('\\', '/')
	root := os.getwd().replace('\\', '/') + '/'
	if p.to_lower().starts_with(root.to_lower()) {
		p = p[root.len..]
	}
	return p
}

fn dedupe(a []string) []string {
	mut seen := map[string]bool{}
	mut out := []string{}
	for x in a {
		if x !in seen {
			seen[x] = true
			out << x
		}
	}
	return out
}

fn wilson(k int, n int) (f64, f64) {
	if n == 0 {
		return 0, 0
	}
	z := 1.96
	p := f64(k) / f64(n)
	nn := f64(n)
	den := 1 + z * z / nn
	center := (p + z * z / (2 * nn)) / den
	half := z * math.sqrt(p * (1 - p) / nn + z * z / (4 * nn * nn)) / den
	return center - half, center + half
}

// unanswered_cause groups a site V3 never answered by what its file is.
fn unanswered_cause(rel string) string {
	name := os.file_name(rel)
	if name.contains('_test.') {
		return 'test file'
	}
	if name.ends_with('.js.v') || name.ends_with('.wasm.v') {
		return 'other backend'
	}
	flags := file_flags(rel, os.user_os())
	if '-d' in flags {
		return '-d file'
	}
	if '-os' in flags {
		return 'other-OS file'
	}
	return 'other'
}

fn summarize(rows []Row, population int, opts Options, commit string, graph_path string) string {
	mut counts := map[string]int{}
	for row in rows {
		counts[row.status]++
	}
	correct := counts['correct']
	scored := correct + counts['extra'] + counts['wrong']
	lo, hi := wilson(correct, scored)
	mut s := strings.new_builder(1024)
	s.writeln('graph: ${graph_path}${if commit != '' { ' (' + commit#[..10] + ')' } else { '' }}')
	s.writeln('population: ${population} ${opts.prov} ${unit_name(opts.kind)}; sample ${rows.len}, seed ${opts.seed}${if opts.self_test {
		', SELF-TEST'
	} else {
		''
	}}')
	for st in ['correct', 'extra', 'wrong', 'not-in-graph', 'silent', 'no-answer', 'name-not-on-line', 'no-source'] {
		if counts[st] > 0 {
			s.writeln('  ${st:-17} ${counts[st]}')
		}
	}
	if scored > 0 {
		s.writeln('accuracy: ${correct}/${scored} = ${100 * f64(correct) / f64(scored):.2f}% (95% Wilson ${100 * lo:.2f}-${100 * hi:.2f}%)')
	}
	mut by_world := map[string]int{}
	for row in rows {
		if row.answers.len > 0 {
			by_world[if row.world == '' { 'default build' } else { row.world }]++
		}
	}
	for w, c in by_world {
		s.writeln('  answered in ${w}: ${c}')
	}
	mut causes := map[string]int{}
	for row in rows {
		if row.status == 'no-answer' {
			causes[unanswered_cause(row.file)]++
		}
	}
	if causes.len > 0 {
		s.writeln('no answer, by file:')
		for c, k in causes {
			s.writeln('  ${c:-17} ${k}')
		}
	}
	return s.str()
}

fn csv_field(s string) string {
	if s.contains_any(',"\n') {
		return '"' + s.replace('"', '""') + '"'
	}
	return s
}

fn write_csv(path string, rows []Row) {
	mut sb := strings.new_builder(rows.len * 200)
	sb.writeln('status,from,to,file,line,to_file,to_line,oracle,oracle_ids,program,world,note')
	for r in rows {
		fields := [r.status, r.from, r.to, r.file, r.line.str(), r.to_file, r.to_line.str(),
			dedupe(r.answers.map(normalize_answer(it))).join(' | '), r.ids.join(' | '), r.program,
			r.world, r.note]
		sb.writeln(fields.map(csv_field(it)).join(','))
	}
	os.write_file(path, sb.str()) or { eprintln(err) }
}

fn normalize_answer(a string) string {
	path, ln := split_answer(a) or { return a }
	return '${path}:${ln}'
}
