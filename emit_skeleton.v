module graphify

// emit_skeleton renders the graph as a compact, body-less view of every file:
// the module line, its imports, and the signature of each declaration. This is
// the token-lean representation intended to be fed to an AI tool in place of
// full source.
pub fn (g Graph) emit_skeleton() string {
	// group symbols by file, preserving discovery order
	mut files := []string{}
	mut by_file := map[string][]Symbol{}
	for s in g.symbols {
		if s.file !in by_file {
			files << s.file
		}
		by_file[s.file] << s
	}

	mut sb := []string{}
	for f in files {
		sb << '// ${f}'
		syms := by_file[f]
		// module + imports first
		for s in syms {
			if s.kind == .mod_ {
				sb << s.signature
			}
		}
		for s in syms {
			if s.kind == .import_ {
				sb << '  ${s.signature}'
			}
		}
		// declarations
		for s in syms {
			if s.kind in [SymbolKind.mod_, .import_] {
				continue
			}
			if s.kind == .function || s.kind == .method {
				sb << '${s.signature} { ... }'
			} else {
				sb << s.signature
			}
		}
		sb << ''
	}
	return sb.join('\n')
}
