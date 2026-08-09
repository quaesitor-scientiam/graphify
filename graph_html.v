module graphify

// emit_graph_html wraps emit_svg's rendering in an interactive HTML page: a
// legend mapping each community's color to its label and size, and
// hover-to-highlight (a node and its direct neighbors light up, everything
// else dims) using the data-id/data-from/data-to attributes emit_svg's
// output already carries. No CDN dependency, no build step -- this is
// meant to be one self-contained file a browser opens directly, matching
// the rest of graphify's local-only design (nothing here calls out to
// anything, same as the CLI itself).
pub fn (g Graph) emit_graph_html() string {
	idx := g.index()
	nodes, total, comms := layout_communities(g, idx)
	svg := render_svg(nodes, idx, total)

	mut shown_communities := map[int]bool{}
	for n in nodes {
		shown_communities[n.community] = true
	}

	mut legend := []string{}
	for i, c in comms {
		if i !in shown_communities {
			continue // every member of this community got cut by the svg_max_nodes cap
		}
		color := node_color(i)
		legend << '    <div><span class="swatch" style="background:${color}"></span>${xml_escape(c.label)} <span class="count">(${c.members.len})</span></div>'
	}

	mut sb := []string{}
	sb << '<!doctype html>'
	sb << '<html>'
	sb << '<head>'
	sb << '<meta charset="utf-8">'
	sb << '<title>graphify: ${xml_escape(g.root)}</title>'
	sb << '<style>'
	sb << '  body { margin: 0; font-family: -apple-system, sans-serif; background: #fafafa; }'
	sb << '  h2.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0,0,0,0); }'
	sb << '  #legend { position: fixed; top: 10px; left: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 8px 12px; font-size: 12px; max-height: 85vh; overflow-y: auto; box-shadow: 0 1px 4px rgba(0,0,0,0.15); }'
	sb << '  #legend div { margin: 3px 0; white-space: nowrap; }'
	sb << '  #legend .swatch { display: inline-block; width: 10px; height: 10px; margin-right: 6px; border-radius: 2px; vertical-align: middle; }'
	sb << '  #legend .count { color: #888; }'
	sb << '  #caption { position: fixed; top: 10px; right: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 10px; font-size: 11px; color: #555; }'
	sb << '  #info { position: fixed; bottom: 10px; left: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 8px 12px; font-size: 12px; display: none; box-shadow: 0 1px 4px rgba(0,0,0,0.15); }'
	sb << '  svg { display: block; width: 100vw; height: 100vh; }'
	sb << '  svg circle { cursor: pointer; transition: opacity 0.1s; }'
	sb << '  svg text { transition: opacity 0.1s; pointer-events: none; }'
	sb << '  svg line { transition: opacity 0.1s; }'
	sb << '  svg .dim { opacity: 0.12; }'
	sb << '</style>'
	sb << '</head>'
	sb << '<body>'
	sb << '<h2 class="sr-only">Code graph for ${xml_escape(g.root)}, ${nodes.len} symbols across ${comms.len} communities, rendered as a clustered node-link diagram. Hover a node to highlight its neighbors.</h2>'
	sb << '<div id="legend">'
	sb << legend.join('\n')
	sb << '</div>'
	if nodes.len < total {
		sb << '<div id="caption">showing ${nodes.len} of ${total} symbols (highest-degree per community)</div>'
	}
	sb << '<div id="info"></div>'
	sb << svg
	sb << '<script>'
	sb << js_interactivity
	sb << '</script>'
	sb << '</body>'
	sb << '</html>'
	return sb.join('\n')
}

// js_interactivity is plain DOM/SVG API, no framework: on hover, dim every
// circle/line/text except the hovered node, its direct neighbors (via
// data-from/data-to), and the edges between them; on mouseout, undim.
const js_interactivity = '
(function() {
  var svg = document.querySelector("svg");
  var info = document.getElementById("info");
  var circles = svg.querySelectorAll("circle[data-id]");
  var texts = svg.querySelectorAll("text[data-id]");
  var lines = svg.querySelectorAll("line[data-from]");

  function neighborsOf(id) {
    var set = {};
    set[id] = true;
    lines.forEach(function(l) {
      var from = l.getAttribute("data-from");
      var to = l.getAttribute("data-to");
      if (from === id) set[to] = true;
      if (to === id) set[from] = true;
    });
    return set;
  }

  function highlight(id) {
    var keep = neighborsOf(id);
    circles.forEach(function(c) {
      c.classList.toggle("dim", !keep[c.getAttribute("data-id")]);
    });
    texts.forEach(function(t) {
      t.classList.toggle("dim", !keep[t.getAttribute("data-id")]);
    });
    lines.forEach(function(l) {
      var touches = keep[l.getAttribute("data-from")] && keep[l.getAttribute("data-to")];
      l.classList.toggle("dim", !touches);
    });
  }

  function clear() {
    circles.forEach(function(c) { c.classList.remove("dim"); });
    texts.forEach(function(t) { t.classList.remove("dim"); });
    lines.forEach(function(l) { l.classList.remove("dim"); });
    info.style.display = "none";
  }

  circles.forEach(function(c) {
    c.addEventListener("mouseenter", function() {
      var id = c.getAttribute("data-id");
      highlight(id);
      var title = c.querySelector("title");
      info.textContent = (title ? title.textContent : id) + "  --  " + id;
      info.style.display = "block";
    });
    c.addEventListener("mouseleave", clear);
  });
})();
'
