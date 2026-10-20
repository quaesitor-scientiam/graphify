#!/usr/bin/env -S v -raw-vsh-tmp-prefix tmp

// Runs `v test .` on a checkout of HEAD with CRLF line ends, as Windows CI checks it
// out (core.autocrlf), so that a test which only fails there, such as one comparing
// a multi-line string literal, fails here before a push.
//
//   v run bin/test-crlf.vsh            # test HEAD with CRLF line ends
//   v run bin/test-crlf.vsh <commit>   # test that commit instead
//   v run bin/test-crlf.vsh -Keep      # keep the checkout afterwards, to look at
//
// It tests what is committed: uncommitted changes aren't in the checkout, and it
// says so when there are any. It doesn't catch the other ways Windows differs
// (`\` in paths, drive letters, `$if windows`), only the line ends.
import os

fn git(dir string, args ...string) os.Result {
	mut cmd := ['git', '-C', dir]
	cmd << args
	return os.exec(cmd)
}

fn main() {
	code := run()
	exit(code)
}

// run tests the CRLF checkout and returns the exit code, having removed the checkout
// unless -Keep; exit() would skip a defer.
fn run() int {
	keep := '-Keep' in os.args[1..]
	rev := os.args[1..].filter(!it.starts_with('-'))
	root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	head := git(root, 'rev-parse', '--verify', if rev.len > 0 {
		'${rev[0]}^{commit}'
	} else {
		'HEAD'
	})
	if head.exit_code != 0 {
		eprintln('test-crlf: no such commit in ${root}: ${head.output.trim_space()}')
		return 1
	}
	sha := head.output.trim_space()
	if rev.len == 0 && git(root, 'status', '--porcelain', '--untracked-files=no').output.trim_space() != '' {
		println('test-crlf: uncommitted changes are not tested; only ${sha[..10]}')
	}
	dir := os.join_path(os.temp_dir(), 'graphify-crlf-${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		if keep {
			println('test-crlf: kept ${dir}')
		} else {
			os.rmdir_all(dir) or {}
		}
	}
	clone := os.exec(['git', 'clone', '-q', '--no-checkout', '--no-hardlinks', root, dir])
	if clone.exit_code != 0 {
		eprintln('test-crlf: cannot clone ${root}: ${clone.output}')
		return 1
	}
	git(dir, 'config', 'core.autocrlf', 'true')
	checkout := git(dir, 'checkout', '-q', sha)
	if checkout.exit_code != 0 {
		eprintln('test-crlf: cannot check out ${sha}: ${checkout.output}')
		return 1
	}
	model := os.read_file(os.join_path(dir, 'model.v')) or { '' }
	if !model.contains('\r\n') {
		eprintln('test-crlf: the checkout has no CRLF line ends')
		return 1
	}
	println('test-crlf: testing ${sha[..10]} with CRLF line ends in ${dir}')
	code := os.system('cd ${os.quoted_path(dir)} && v test .')
	if code != 0 {
		eprintln('test-crlf: FAILED with CRLF line ends')
	}
	return code
}
