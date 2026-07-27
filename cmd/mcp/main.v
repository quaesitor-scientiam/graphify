module main

// graphify MCP server — speaks JSON-RPC 2.0 over stdio (newline-delimited),
// the transport Claude Code uses for local MCP servers. It loads a persisted
// graph.json once and exposes graph traversal as tools, so the model queries
// the graph instead of re-reading source files.
//
//   v run cmd/mcp [graphify-out/graph.json]
//
// Tools: query_graph, get_node, get_neighbors, shortest_path.
import os
import x.json2
import graphify

fn main() {
	graph_path := if os.args.len > 1 {
		os.args[1]
	} else {
		os.join_path(graphify.out_dir_name, 'graph.json')
	}
	mut g := graphify.load_graph(graph_path) or {
		eprintln('graphify-mcp: cannot load ${graph_path}: ${err}')
		exit(1)
	}
	// optional 2nd arg / GRAPHIFY_SOURCE_DIR: override the extraction root so a
	// graph shared from another machine resolves get_body against local source.
	src_dir := if os.args.len > 2 { os.args[2] } else { os.getenv('GRAPHIFY_SOURCE_DIR') }
	if src_dir != '' {
		g.root = src_dir
	}
	eprintln('graphify-mcp: loaded ${g.symbols.len} symbols from ${graph_path}')

	for {
		raw := os.get_raw_line()
		if raw.len == 0 {
			break // EOF
		}
		line := raw.trim_space()
		if line == '' {
			continue
		}
		resp := handle(line, g)
		if resp != '' {
			println(resp)
			flush_stdout()
		}
	}
}

// handle parses one JSON-RPC request and returns the response line, or '' for
// notifications (no id) and unparseable input.
fn handle(line string, g graphify.Graph) string {
	any := json2.decode[json2.Any](line) or { return rpc_error(json2.null, -32700, 'parse error') }
	req := any.as_map()
	method := req['method'] or { return '' }.str()
	has_id := 'id' in req
	id := req['id'] or { json2.null }

	// notifications carry no id and expect no response
	if !has_id {
		return ''
	}

	match method {
		'initialize' {
			return rpc_result(id, initialize_result())
		}
		'tools/list' {
			return rpc_result(id, jobj({
				'tools': jarr(tool_list())
			}))
		}
		'tools/call' {
			params := (req['params'] or { json2.null }).as_map()
			name := (params['name'] or { json2.null }).str()
			args := (params['arguments'] or { json2.null }).as_map()
			return rpc_result(id, call_tool(name, args, g))
		}
		'ping' {
			return rpc_result(id, jobj(map[string]json2.Any{}))
		}
		else {
			return rpc_error(id, -32601, 'method not found: ${method}')
		}
	}
}

fn call_tool(name string, args map[string]json2.Any, g graphify.Graph) json2.Any {
	text := match name {
		'query_graph' {
			budget := if 'budget' in args { (args['budget'] or { json2.null }).int() } else { 2000 }
			dfs := if 'dfs' in args { (args['dfs'] or { json2.null }).bool() } else { false }
			g.query((args['text'] or { json2.null }).str(), budget, dfs)
		}
		'get_node' {
			g.explain((args['node'] or { json2.null }).str())
		}
		'get_body' {
			g.get_body((args['node'] or { json2.null }).str())
		}
		'overview' {
			g.report()
		}
		'get_neighbors' {
			names := g.neighbor_names((args['node'] or { json2.null }).str())
			if names.len == 0 {
				'(no neighbors / unknown node)'
			} else {
				names.join('\n')
			}
		}
		'shortest_path' {
			ids := g.shortest_path((args['a'] or { json2.null }).str(),
				(args['b'] or { json2.null }).str())
			if ids.len == 0 {
				'(no path)'
			} else {
				g.names(ids).join(' -> ')
			}
		}
		else {
			'unknown tool: ${name}'
		}
	}

	return jobj({
		'content': jarr([
			jobj({
				'type': jstr('text')
				'text': jstr(text)
			}),
		])
	})
}

// --- MCP metadata ---

fn initialize_result() json2.Any {
	return jobj({
		'protocolVersion': jstr('2024-11-05')
		'capabilities':    jobj({
			'tools': jobj(map[string]json2.Any{})
		})
		'serverInfo':      jobj({
			'name':    jstr('graphify')
			'version': jstr('0.0.1')
		})
	})
}

fn tool_list() []json2.Any {
	return [
		tool('query_graph',
			'Traverse the code graph from symbols matching a search text, breadth-first (or depth-first), returning a token-bounded body-less view with file:line locations. Use this instead of reading whole files.', schema({
			'text':   prop('string',
				'search text; seeds the traversal from matching symbol names/signatures')
			'budget': prop('integer', 'approximate token budget for the result (default 2000)')
			'dfs':    prop('boolean', 'walk depth-first instead of breadth-first (default false)')
		}, ['text'])),
		tool('get_node',
			'Summarize one symbol: signature, location, and its relationships (defines/defined-in, references/referenced-by, embeds, calls/called-by) — each with file:line.', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('get_body',
			'Return the source of ONE declaration by name, read by line range — fetch a single function/struct/const instead of reading the whole file.', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('overview',
			'A COMPACT summary: file/symbol/edge counts, symbols by kind, and the most-connected symbols with file:line. Small — orient with this, then query_graph/get_node to drill in. Not a full dump.', schema(map[string]json2.Any{},
			[]string{})),
		tool('get_neighbors',
			'List the names of all symbols directly linked to a symbol (calls, callers, defines, imports).', schema({
			'node': prop('string', 'symbol name or id')
		}, ['node'])),
		tool('shortest_path', 'Find the shortest relationship path between two symbols.', schema({
			'a': prop('string', 'start symbol name or id')
			'b': prop('string', 'goal symbol name or id')
		}, ['a', 'b'])),
	]
}

// --- json2 builders ---

fn jstr(s string) json2.Any {
	return json2.Any(s)
}

fn jobj(m map[string]json2.Any) json2.Any {
	return json2.Any(m)
}

fn jarr(a []json2.Any) json2.Any {
	return json2.Any(a)
}

fn prop(typ string, desc string) json2.Any {
	return jobj({
		'type':        jstr(typ)
		'description': jstr(desc)
	})
}

fn schema(props map[string]json2.Any, required []string) json2.Any {
	mut req := []json2.Any{}
	for r in required {
		req << jstr(r)
	}
	return jobj({
		'type':       jstr('object')
		'properties': jobj(props)
		'required':   jarr(req)
	})
}

fn tool(name string, desc string, input_schema json2.Any) json2.Any {
	return jobj({
		'name':        jstr(name)
		'description': jstr(desc)
		'inputSchema': input_schema
	})
}

fn rpc_result(id json2.Any, result json2.Any) string {
	return jobj({
		'jsonrpc': jstr('2.0')
		'id':      id
		'result':  result
	}).json_str()
}

fn rpc_error(id json2.Any, code int, message string) string {
	return jobj({
		'jsonrpc': jstr('2.0')
		'id':      id
		'error':   jobj({
			'code':    json2.Any(code)
			'message': jstr(message)
		})
	}).json_str()
}
