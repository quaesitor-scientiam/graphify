#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Times a full extraction run against a target repo.
//
//   v run bench/extract_bench.vsh
//   v run bench/extract_bench.vsh -Source S:/repo/vlang -Runs 3
//   v run bench/extract_bench.vsh -Source S:/myproject -Out S:/temp/gf-bench-myproject

import os
import time
import json2

struct Config {
	vlang_repo string
	store      string
}

fn flag_value(args []string, name string) string {
	for i, a in args {
		if a == name && i + 1 < args.len {
			return args[i + 1]
		}
	}
	return ''
}

fn main() {
	args := os.args#[1..]
	mut source := flag_value(args, '-Source')
	mut out := flag_value(args, '-Out')
	if out == '' {
		out = os.join_path(os.temp_dir(), 'gf-bench')
	}
	mut exe := flag_value(args, '-Exe')
	runs_str := flag_value(args, '-Runs')
	runs := if runs_str != '' { runs_str.int() } else { 1 }

	if exe == '' {
		exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
		exe = os.join_path(@VMODROOT, 'bin', exe_name)
	}
	if source == '' {
		config_path := os.join_path(@VMODROOT, 'graphify.config.json')
		if !os.exists(config_path) {
			eprintln('No -Source given and missing config: ${config_path}\nCopy graphify.config.json.example to graphify.config.json and edit it, or pass -Source explicitly.')
			exit(1)
		}
		config_content := os.read_file(config_path) or {
			eprintln('Could not read config: ${err}')
			exit(1)
		}
		config := json2.decode[Config](config_content) or {
			eprintln('Could not parse config: ${err}')
			exit(1)
		}
		source = config.vlang_repo
	}

	if !os.exists(exe) {
		eprintln('graphify binary not found at: ${exe}')
		exit(1)
	}
	if !os.exists(source) {
		eprintln('Source path not found: ${source}')
		exit(1)
	}

	println('Exe  : ${exe}')
	println('Src  : ${source}')
	println('Out  : ${out}')
	println('Runs : ${runs}')
	println('')

	mut times := []int{}

	for i in 1 .. runs + 1 {
		if os.exists(out) {
			os.rmdir_all(out) or {}
		}
		os.mkdir_all(out) or {}

		start := time.now()
		result := os.execute('${os.quoted_path(exe)} extract ${os.quoted_path(source)} --out ${os.quoted_path(out)}')
		secs := int(time.now().unix() - start.unix())
		times << secs

		mut summary := ''
		for line in result.output.split_into_lines() {
			if line.contains('extracted') {
				summary = line
				break
			}
		}
		graph_path := os.join_path(out, 'graph.json')
		graph_mb := if os.exists(graph_path) {
			'${f64(os.file_size(graph_path)) / (1024.0 * 1024.0):.1f} MB'
		} else {
			'no graph.json'
		}

		println('Run ${i} : ${secs}s   ${summary}   graph=${graph_mb}')
	}

	if runs > 1 {
		mut min := times[0]
		mut max := times[0]
		mut sum := 0
		for t in times {
			if t < min {
				min = t
			}
			if t > max {
				max = t
			}
			sum += t
		}
		avg := sum / runs
		println('')
		println('min=${min}s  avg=${avg}s  max=${max}s')
	}
}
