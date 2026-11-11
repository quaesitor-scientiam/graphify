#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Measures how often graphify's `inferred` call edges link the declaration that V's
// own compiler resolves the call to: a seeded random sample of their call sites,
// each asked of V3's go-to-definition.
//
//   v run bin/sample-accuracy.vsh S:\graph_data\vlang                  # 1000 sites, seed 20261110
//   v run bin/sample-accuracy.vsh <graph dir or graph.json> -n 2000 -seed 7
//   v run bin/sample-accuracy.vsh <graph> -out <dir>                   # where the results go
//   v run bin/sample-accuracy.vsh <graph> -v3 <binary>                 # use this V3, don't build one
//   v run bin/sample-accuracy.vsh <graph> -no-worlds                   # the default build only
//   v run bin/sample-accuracy.vsh <graph> -self-test                   # check the harness itself
//
// The graph's `root` must be a V checkout (it has vlib/v/v.v): its V3 is the oracle,
// built once per commit into the V temp folder (with `-gc none -prealloc`, as
// vlib/v/compiler_tests/vls_line_info_test.v builds it). The `v` launcher is not
// used, as it falls back to the old compiler when V3 fails.
//
// A unit is one call site of an inferred `calls` edge: its caller, its callee and
// one line of the edge's `lines`. V3 is asked `-vls-mode -line-info file:line:gd^col`
// at the callee's name on that line, inside a program that compiles the file. V3
// checks only the bodies a program reaches, so a site is asked in one program after
// another until one answers: the file itself (a test, or a main program), its
// directory, a main that imports its module, then the module's tests. A site still
// unanswered is asked again in the builds its file is compiled for: the `-os` and
// `-d` its name gives (`_linux.c.v`, `_d_ownership.v`), then each of `-os linux`,
// `-os macos` and `-os windows` other than the host's. A define V3 must be built
// with (`-d ownership`) builds that V3 too.
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
// An `extra` or `wrong` row is where to look by hand: V3 answers for one build,
// and an edge can be right for another one.
//
// It writes sample.csv (one row per sampled site), v3_raw.log (every V3 answer) and
// summary.txt into -out (default: accuracy-<seed>, or accuracy-<seed>-self-test,
// in the V temp folder).
//
// -self-test points each sampled edge at another function or method of the same
// name before asking, and fails if any of them is scored correct or none is scored.
import os
import math
import time
import strings
import hash.fnv1a
import x.json2

const kind_function = 2
const kind_method = 3
const edge_calls = 1
const prov_inferred = 1
const batch_size = 100

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
	id   string
	name string
	kind int
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
}

struct Options {
mut:
	graph     string
	n         int = 1000
	seed      u64 = 20261110
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
}

struct Row {
mut:
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
	variants  map[string]string // the V3 built with a define, by the define
	files     map[string][]string
	log       strings.Builder
}

fn main() {
	opts := parse_args(os.args[1..]) or {
		eprintln(err.msg())
		eprintln('usage: v run bin/sample-accuracy.vsh <graph dir or graph.json> [-n 1000] [-seed 20261110] [-out dir] [-v3 binary] [-no-worlds] [-self-test] [-timeout 300]')
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
	commit := if m := json2.decode[Manifest](os.read_file(os.join_path(os.dir(graph_path),
		'manifest.json')) or { '' })
	{
		m.source_commit
	} else {
		''
	}
	root := os.real_path(g.root)
	if !os.exists(os.join_path(root, 'vlib', 'v', 'v.v')) && opts.v3 == '' {
		eprintln('the graph root ${root} is not a V checkout (no vlib/v/v.v); pass -v3 <binary>')
		exit(1)
	}
	out_dir := if opts.out != '' {
		os.real_path(opts.out)
	} else {
		os.join_path(os.vtmp_dir(), 'accuracy-${opts.seed}${if opts.self_test {
			'-self-test'
		} else {
			''
		}}')
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
	ctx.v3 = if opts.v3 != '' {
		os.real_path(opts.v3)
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
	for s in g.symbols {
		syms[s.id] = s
		by_pos['${s.file}:${s.line}'] << s.id
	}
	mut units := []Unit{}
	for e in g.edges {
		if e.kind == edge_calls && e.provenance == prov_inferred {
			for ln in e.lines {
				units << Unit{
					from: e.from
					to:   e.to
					line: ln
				}
			}
		}
	}
	println('population: ${units.len} inferred call sites')
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
	mut site_targets := map[string]map[string]bool{}
	for u in sample {
		site_targets['${u.from}\t${u.line}'] = map[string]bool{}
	}
	for e in g.edges {
		if e.kind != edge_calls {
			continue
		}
		for ln in e.lines {
			key := '${e.from}\t${ln}'
			if key in site_targets {
				site_targets[key][e.to] = true
			}
		}
	}

	if opts.self_test {
		mut by_name := map[string][]string{}
		for s in g.symbols {
			if s.kind == kind_function || s.kind == kind_method {
				by_name[s.name] << s.id
			}
		}
		mut corrupted := []Unit{}
		for u in sample {
			name := if u.to in syms { syms[u.to].name } else { '' }
			others := by_name[name].filter(it != u.to && it !in site_targets['${u.from}\t${u.line}'])
			if others.len > 0 {
				corrupted << Unit{
					from: u.from
					to:   others[rng.below(others.len)]
					line: u.line
				}
			}
		}
		sample = corrupted.clone()
		println('self-test: ${sample.len} sampled edges pointed at another declaration of their name')
	}

	mut rows := []Row{}
	for u in sample {
		caller := syms[u.from] or { GSymbol{} }
		callee := syms[u.to] or { GSymbol{} }
		mut row := Row{
			from:    u.from
			to:      u.to
			file:    caller.file
			line:    u.line
			to_file: callee.file
			to_line: callee.line
		}
		src := ctx.lines_of(caller.file)
		if caller.file == '' || u.line < 1 || u.line > src.len {
			row.status = 'no-source'
			rows << row
			continue
		}
		name := if callee.name != '' {
			callee.name
		} else {
			u.to.all_before('@').all_after_last('.')
		}
		row.cols = name_columns(src[u.line - 1], name)
		if row.cols.len == 0 {
			row.status = 'name-not-on-line'
			rows << row
			continue
		}
		if row.cols.len > 1 {
			row.note = '${row.cols.len} occurrences'
		}
		row.progs = ctx.programs_for(caller.file)
		row.worlds = worlds_for(caller.file, os.user_os())
		rows << row
	}

	println('asking V3 in the default build...')
	ctx.ask_world(mut rows, []string{}, all_rows(rows))
	if opts.worlds {
		mut tried := map[string]bool{}
		for {
			// the next build some unanswered site is compiled for
			mut world := []string{}
			for row in rows {
				if row.status != '' || row.answers.len > 0 {
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
				if row.status == '' && row.answers.len == 0
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
			row.status = 'no-answer'
			continue
		}
		mut ids := []string{}
		for a in row.answers {
			path, ln := split_answer(a) or { continue }
			at := by_pos['${path}:${ln}']
			if at.len > 0 {
				ids << at
			} else {
				ids << '?${path}:${ln}'
			}
		}
		row.ids = dedupe(ids)
		targets := site_targets['${row.from}\t${row.line}']
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

	summary := summarize(rows, units.len, opts, commit, graph_path)
	println(summary)
	write_csv(os.join_path(out_dir, 'sample.csv'), rows)
	os.write_file(os.join_path(out_dir, 'summary.txt'), summary) or { eprintln(err) }
	os.write_file(os.join_path(out_dir, 'v3_raw.log'), ctx.log.str()) or { eprintln(err) }
	println('wrote sample.csv, summary.txt and v3_raw.log in ${out_dir}')

	if opts.self_test {
		correct := rows.filter(it.status == 'correct').len
		scored := rows.filter(it.status in ['correct', 'extra', 'wrong']).len
		if correct > 0 || scored == 0 {
			eprintln('SELF-TEST FAILED: ${correct} of ${scored} corrupted edges scored correct')
			exit(1)
		}
		println('self-test passed: none of ${scored} corrupted edges scored correct')
	}
}

fn parse_args(args []string) !Options {
	mut o := Options{}
	mut i := 0
	for i < args.len {
		a := args[i]
		match a {
			'-n', '-seed', '-out', '-v3', '-timeout' {
				if i + 1 >= args.len {
					return error('${a} needs a value')
				}
				v := args[i + 1]
				if a in ['-n', '-seed', '-timeout'] && (v.len == 0 || !v.bytes().all(it.is_digit())) {
					return error('${a} needs a whole number, not `${v}`')
				}
				match a {
					'-n' { o.n = v.int() }
					'-seed' { o.seed = v.u64() }
					'-out' { o.out = v }
					'-v3' { o.v3 = v }
					else { o.timeout = v.int() }
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
	if code != 0 || !os.exists(tmp) {
		os.rm(tmp) or {}
		return error('building V3 failed (exit ${code}):\n${out}')
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
	mut has_main := false
	for l in src {
		t := l.trim_space()
		if mod == 'main' && t.starts_with('module ') {
			mod = t.all_after('module ').trim_space()
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
			if row.answers.len == 0 && round < row.progs.len {
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
	for i in idxs {
		for c in rows[i].cols {
			specs << '${rows[i].file}:${rows[i].line}:gd^${c}'
			owner << i
		}
	}
	for start := 0; start < specs.len; start += batch_size {
		end := if start + batch_size < specs.len { start + batch_size } else { specs.len }
		chunk := specs[start..end].clone()
		got := ctx.ask(world, prog, chunk)
		for k, a in got {
			ri := owner[start + k]
			if is_answer(a) {
				rows[ri].answers << a
				rows[ri].program = prog
				rows[ri].world = world.join(' ')
			}
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
			ctx.variants[key] = ctx.build_v3(defines) or {
				eprintln(err.msg())
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
	s.writeln('population: ${population} inferred call sites; sample ${rows.len}, seed ${opts.seed}${if opts.self_test {
		', SELF-TEST'
	} else {
		''
	}}')
	for st in ['correct', 'extra', 'wrong', 'not-in-graph', 'no-answer', 'name-not-on-line', 'no-source'] {
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
