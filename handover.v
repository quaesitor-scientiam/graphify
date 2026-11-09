module graphify

// win_quote quotes one argument of a Windows command line so that the program's
// argv has it as it is: in quotes when it has a space, a tab or a quote, with a
// quote and the backslashes before one, or before the closing quote, escaped.
// The MCP server starts its daemon with it, and the CLI its extractor (run_waiting).
pub fn win_quote(arg string) string {
	if arg != '' && !arg.contains_any(' \t"') {
		return arg
	}
	mut out := []u8{cap: arg.len + 2}
	out << `"`
	mut slashes := 0
	for c in arg {
		if c == `\\` {
			slashes++
			continue
		}
		if c == `"` {
			for _ in 0 .. slashes * 2 + 1 {
				out << `\\`
			}
		} else {
			for _ in 0 .. slashes {
				out << `\\`
			}
		}
		slashes = 0
		out << c
	}
	for _ in 0 .. slashes * 2 {
		out << `\\`
	}
	out << `"`
	return out.bytestr()
}
