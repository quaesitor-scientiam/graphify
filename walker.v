module graphify

import os

// directories we never descend into (dot-prefixed dirs are also skipped globally).
const skip_dirs = ['node_modules', '_test', 'thirdparty']

// find_source_files walks `root` and returns the path of every `.v` file found.
pub fn find_source_files(root string) []string {
	mut out := []string{}
	walk(os.real_path(root), mut out)
	return out
}

fn walk(dir string, mut out []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		full := os.join_path(dir, e)
		if os.is_dir(full) {
			if e.starts_with('.') || e in skip_dirs {
				continue
			}
			walk(full, mut out)
			continue
		}
		if os.file_ext(full) == '.v' {
			out << full
		}
	}
}
