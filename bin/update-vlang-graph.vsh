#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Pulls the target repo and re-extracts only if there were new commits.
// Wired into a daily scheduler (Windows Task Scheduler / macOS launchd /
// Linux cron); can also be run by hand.
//
//   v run bin/update-vlang-graph.vsh              # git pull, extract only if new commits
//   v run bin/update-vlang-graph.vsh -NoPull       # skip the pull, always re-extract

import os
import time
import x.json2

struct Config {
	vlang_repo string
	store      string
}

fn log_line(log_path string, msg string) {
	line := '${time.now().format_ss()}  ${msg}'
	println(line)
	mut f := os.open_append(log_path) or { return }
	f.writeln(line) or {}
	f.close()
}

fn main() {
	config_path := os.join_path(@VMODROOT, 'graphify.config.json')
	if !os.exists(config_path) {
		eprintln('Missing config: ${config_path}\nCopy graphify.config.json.example to graphify.config.json and edit it for your setup.')
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

	vlang := config.vlang_repo
	store := config.store
	exe_name := $if windows { 'graphify.exe' } $else { 'graphify' }
	graphify_exe := os.join_path(@VMODROOT, 'bin', exe_name)
	log_path := os.join_path(store, 'update.log')

	no_pull := os.args.len > 1 && os.args[1] == '-NoPull'

	log_line(log_path, '--- vlang graph update start ---')

	if !no_pull {
		log_line(log_path, 'git pull...')
		pull := os.execute('git -C ${os.quoted_path(vlang)} pull --ff-only')
		log_line(log_path, pull.output.trim_space())
		if pull.output.contains('Already up to date') {
			log_line(log_path, 'No new commits. Skipping extract.')
			log_line(log_path, '--- done ---')
			exit(0)
		}
	}

	log_line(log_path, 'extracting graph...')
	start := time.now()
	result := os.execute('${os.quoted_path(graphify_exe)} extract ${os.quoted_path(vlang)} --store ${os.quoted_path(store)}')
	for line in result.output.split_into_lines() {
		if line.trim_space() != '' {
			log_line(log_path, line)
		}
	}
	elapsed_s := int(time.now().unix() - start.unix())
	log_line(log_path, 'done in ${elapsed_s}s')
	log_line(log_path, '--- done ---')
}
