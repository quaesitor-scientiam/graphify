module graphify

import os

// SourceFile is a discovered file plus the language it was matched as.
pub struct SourceFile {
pub:
	path string // absolute path
	lang string // 'v', and later 'go', 'py', ...
}

// extension -> language id. Extend as tree-sitter backends come online.
const lang_by_ext = {
	'.v': 'v'
}

// directories we never descend into (dot-prefixed dirs are also skipped globally).
const skip_dirs = ['node_modules', '_test', 'thirdparty']

// find_source_files walks `root` and returns every file whose extension maps
// to a supported language. `langs` filters the result ([] = all supported).
pub fn find_source_files(root string, langs []string) []SourceFile {
	mut out := []SourceFile{}
	walk(os.real_path(root), mut out, langs)
	return out
}

fn walk(dir string, mut out []SourceFile, langs []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		full := os.join_path(dir, e)
		if os.is_dir(full) {
			if e.starts_with('.') || e in skip_dirs {
				continue
			}
			walk(full, mut out, langs)
			continue
		}
		ext := os.file_ext(full)
		lang := lang_by_ext[ext] or { continue }
		if langs.len > 0 && lang !in langs {
			continue
		}
		out << SourceFile{
			path: full
			lang: lang
		}
	}
}
