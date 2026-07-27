module graphify

// tree-sitter backend for non-V languages.
//
// This is the second half of the design: V files go through `backend_v.v`
// (the native frontend), and everything else goes through the `tree_sitter`
// wrapper at S:\vProjects\tree_sitter. Each language gets a small profile that
// maps tree-sitter node kinds (e.g. `function_declaration`, `struct_specifier`)
// to graphify SymbolKinds.
//
// Prerequisites before this can do real work (tracked separately):
//   1. Extend the tree_sitter binding with node byte-ranges, named-child
//      iteration, and field-by-name access (it currently exposes only
//      kind()/child_count()).
//   2. Vendor a complete grammar per target language.
//
// Until then this returns nothing, so the V path works end-to-end on its own.

pub fn extract_ts_file(path string, rel string, lang string) ([]Symbol, []Edge) {
	// TODO: parse `path` with tree_sitter.new_parser() + the grammar for `lang`,
	// walk the tree via a LanguageProfile, and emit symbols/edges.
	return []Symbol{}, []Edge{}
}
