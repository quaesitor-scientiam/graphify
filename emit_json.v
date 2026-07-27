module graphify

import x.json2

// emit_json serializes the whole graph (symbols + edges) for tooling.
pub fn (g Graph) emit_json() string {
	return json2.encode(g)
}
