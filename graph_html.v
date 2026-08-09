module graphify

// emit_graph_html wraps emit_svg's rendering in an interactive HTML page: a
// legend mapping each community's color to its label and size,
// hover-to-highlight (a node and its direct neighbors light up, everything
// else dims) using the data-id/data-from/data-to attributes emit_svg's
// output already carries, and scroll-to-zoom + drag-to-pan on the SVG
// viewBox. No CDN dependency, no build step -- this is meant to be one
// self-contained file a browser opens directly, matching the rest of
// graphify's local-only design (nothing here calls out to anything, same as
// the CLI itself).
//
// The zoom/pan exists because the hover target otherwise isn't practically
// usable: confirmed directly with a real WebDriver-synthesized mouse move
// (not a JS-dispatched event) that a rendered node was only ~4x4 CSS
// pixels at the default view -- correct in principle, unusable in practice.
// Each node's actual hover target (emit_svg's `.hit` circle) is already
// enlarged independently of its visible size, and zooming in shrinks the
// gap the rest of the way.
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
	sb << '  #hint { position: fixed; bottom: 10px; right: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 10px; font-size: 11px; color: #888; }'
	sb << '  svg { display: block; width: 100vw; height: 100vh; cursor: grab; touch-action: none; }'
	sb << '  svg.panning { cursor: grabbing; }'
	sb << '  svg .node { cursor: pointer; }'
	sb << '  svg .node .hit { pointer-events: all; }'
	sb << '  svg .node, svg line { transition: opacity 0.1s; }'
	sb << '  svg text { pointer-events: none; }'
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
	sb << '<div id="hint">scroll to zoom &middot; drag to pan &middot; hover a node</div>'
	sb << svg
	sb << '<script>'
	sb << js_interactivity
	sb << '</script>'
	sb << '</body>'
	sb << '</html>'
	return sb.join('\n')
}

// js_interactivity is plain DOM/SVG API, no framework:
//   - hover a node (its .hit circle, larger than the visible .dot -- see
//     emit_svg) to dim everything except it, its direct neighbors (via
//     data-from/data-to on the edge lines), and the edges between them.
//   - scroll to zoom the SVG viewBox, centered on the cursor.
//   - drag the background to pan.
// Hover updates are suppressed while actively panning, and any current
// highlight is cleared the moment a pan starts, so a highlight can't get
// stuck showing a node the cursor is no longer over.
const js_interactivity = '
(function() {
  var svg = document.querySelector("svg");
  var info = document.getElementById("info");
  var nodes = svg.querySelectorAll(".node");
  var lines = svg.querySelectorAll("line[data-from]");
  var panning = false;

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
    nodes.forEach(function(n) {
      n.classList.toggle("dim", !keep[n.getAttribute("data-id")]);
    });
    lines.forEach(function(l) {
      var touches = keep[l.getAttribute("data-from")] && keep[l.getAttribute("data-to")];
      l.classList.toggle("dim", !touches);
    });
  }

  function clear() {
    nodes.forEach(function(n) { n.classList.remove("dim"); });
    lines.forEach(function(l) { l.classList.remove("dim"); });
    info.style.display = "none";
  }

  nodes.forEach(function(n) {
    n.addEventListener("mouseenter", function() {
      if (panning) return;
      var id = n.getAttribute("data-id");
      highlight(id);
      var title = n.querySelector("title");
      info.textContent = (title ? title.textContent : id) + "  --  " + id;
      info.style.display = "block";
    });
    n.addEventListener("mouseleave", function() {
      if (!panning) clear();
    });
  });

  // --- zoom (wheel, centered on cursor) ---
  function svgPoint(clientX, clientY) {
    var pt = svg.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    return pt.matrixTransform(svg.getScreenCTM().inverse());
  }

  svg.addEventListener("wheel", function(e) {
    e.preventDefault();
    var vb = svg.viewBox.baseVal;
    var factor = e.deltaY < 0 ? 0.88 : 1.14;
    var newW = vb.width * factor;
    // clamp so you cannot zoom out past ~4x the original extent or in
    // past a few SVG units wide
    if (newW < 20 || newW > svg._origW * 4) return;
    var p = svgPoint(e.clientX, e.clientY);
    vb.x = p.x - (p.x - vb.x) * factor;
    vb.y = p.y - (p.y - vb.y) * factor;
    vb.width = newW;
    vb.height = vb.height * factor;
  }, { passive: false });
  svg._origW = svg.viewBox.baseVal.width;

  // --- pan (drag) ---
  var lastX = 0, lastY = 0;
  svg.addEventListener("mousedown", function(e) {
    panning = true;
    lastX = e.clientX;
    lastY = e.clientY;
    svg.classList.add("panning");
    clear();
  });
  window.addEventListener("mousemove", function(e) {
    if (!panning) return;
    var vb = svg.viewBox.baseVal;
    var scale = vb.width / svg.clientWidth;
    vb.x -= (e.clientX - lastX) * scale;
    vb.y -= (e.clientY - lastY) * scale;
    lastX = e.clientX;
    lastY = e.clientY;
  });
  window.addEventListener("mouseup", function() {
    panning = false;
    svg.classList.remove("panning");
  });
})();
'
