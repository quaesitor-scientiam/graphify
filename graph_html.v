module graphify

// emit_graph_html wraps emit_svg's rendering in an interactive HTML page: a
// legend mapping each community's color to its label, size, and location in
// the source tree; hover-to-highlight (a node and its direct neighbors
// light up, everything else dims) using the data-id/data-from/data-to
// attributes emit_svg's output already carries; clicking a node locks that
// highlight so it survives the mouse moving away, and clicking a legend
// entry or an in-canvas cluster label zooms the viewBox to fit that
// community -- both let you explore without the highlight or the view
// resetting itself out from under you; and scroll-to-zoom + drag-to-pan on
// the SVG viewBox. No CDN dependency, no build step -- this is meant to be
// one self-contained file a browser opens directly, matching the rest of
// graphify's local-only design (nothing here calls out to anything, same as
// the CLI itself).
//
// Semantic zoom: at the default view only the per-community labels are
// visible (name, member count, and where in the source tree that community
// actually lives -- see community_location; a community's label alone,
// its most internally-connected member's name, doesn't say what part of
// the codebase it corresponds to). Individual symbol labels fade in once
// zoomed in past a threshold, so the first thing shown is a high-level map
// you can then drill into, not a wall of overlapping per-symbol text.
//
// The zoom/pan also exists because the hover target otherwise isn't
// practically usable: confirmed directly with a real WebDriver-synthesized
// mouse move (not a JS-dispatched event) that a rendered node was only
// ~4x4 CSS pixels at the default view -- correct in principle, unusable in
// practice. Each node's actual hover target (emit_svg's `.hit` circle) is
// already enlarged independently of its visible size, and zooming in
// shrinks the gap the rest of the way.
pub fn (g Graph) emit_graph_html() string {
	idx := g.index()
	nodes, total, comms := layout_communities(g, idx)
	svg := render_svg(nodes, idx, total, comms)

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
		loc := community_location(idx, c.members)
		loc_html := if loc == '' { '' } else { '<span class="loc">${xml_escape(loc)}</span>' }
		legend << '    <div class="legend-item" data-community="${i}"><span class="swatch" style="background:${color}"></span>${xml_escape(c.label)} <span class="count">(${c.members.len})</span>${loc_html}</div>'
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
	sb << '  #legend .loc { display: block; color: #aaa; font-size: 10px; margin-left: 16px; }'
	sb << '  #legend .legend-item { cursor: pointer; border-radius: 3px; }'
	sb << '  #legend .legend-item:hover { background: #f0f0f0; }'
	sb << '  #caption { position: fixed; top: 10px; right: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 10px; font-size: 11px; color: #555; }'
	sb << '  #info { position: fixed; bottom: 10px; left: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 8px 12px; font-size: 12px; display: none; box-shadow: 0 1px 4px rgba(0,0,0,0.15); }'
	sb << '  #hint { position: fixed; bottom: 10px; right: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 10px; font-size: 11px; color: #888; }'
	sb << '  svg { display: block; width: 100vw; height: 100vh; cursor: grab; touch-action: none; }'
	sb << '  svg.panning { cursor: grabbing; }'
	sb << '  svg .node { cursor: pointer; }'
	sb << '  svg .node .hit { pointer-events: all; }'
	sb << '  svg .cluster-label-group { cursor: pointer; }'
	sb << '  svg .cluster-label-group .cluster-hit { pointer-events: all; }'
	sb << '  svg .node, svg line { transition: opacity 0.1s; }'
	sb << '  svg line { transition: stroke 0.1s, stroke-width 0.1s; }'
	sb << '  svg text { pointer-events: none; }'
	sb << '  svg .dim { opacity: 0.12; }'
	sb << '  svg .node.selected .dot { stroke: #000; stroke-width: 2px; fill-opacity: 1; }'
	sb << '  svg .node.neighbor .dot { stroke: #ff8f00; stroke-width: 1.6px; fill-opacity: 1; }'
	// Edges get the same orange accent as .neighbor dots, so a line
	// visually reads as "this is why that node is highlighted" rather than
	// just relying on "everything else got dimmer" to imply connectivity --
	// especially for edges reaching into an otherwise-dimmed community,
	// where a merely-undimmed line was easy to lose against all the other
	// dimmed clutter around it.
	sb << '  svg line.active { stroke: #ff8f00; stroke-width: 1.6px; }'
	// Semantic zoom: at the default, zoomed-out view only the bold
	// per-community labels (emit_svg's "cluster-label") are visible, so the
	// first thing you see is a high-level map, not a wall of overlapping
	// per-symbol text. Individual "node-label"s fade in once svg.zoomed-in
	// is set (see the wheel handler below); the cluster labels stay visible
	// throughout since there are only a few dozen of them at most, not
	// enough to be clutter.
	sb << '  svg text.node-label { opacity: 0; transition: opacity 0.15s; }'
	sb << '  svg.zoomed-in text.node-label { opacity: 1; }'
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
	sb << '<div id="hint">scroll to zoom &middot; drag to pan &middot; hover a node &middot; click to lock &amp; trace</div>'
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
//     The node itself and its neighbors also get a distinct stroke
//     ("selected"/"neighbor") so they're still easy to pick out once
//     everything else is dimmed, not just "not dimmed".
//   - click a node to lock that highlight (lockedId) so it survives the
//     mouse moving away -- click a different node to re-lock onto it
//     (tracing a path across clusters one click at a time), click the same
//     node or empty canvas to drop the lock, or just hover normally when
//     nothing is locked.
//   - click a legend entry, or a cluster label on the canvas, to zoom the
//     viewBox to fit that community (see zoomToCommunity/communityBBox).
//   - scroll to zoom the SVG viewBox, centered on the cursor.
//   - drag the background to pan.
// Hover updates are suppressed while actively panning or while a lock is
// held, and starting a pan or zooming to a community always drops any lock
// (unlock(), not just clear()) so lockedId and the visible highlight never
// drift out of sync with each other.
const js_interactivity = '
(function() {
  var svg = document.querySelector("svg");
  var info = document.getElementById("info");
  var nodes = svg.querySelectorAll(".node");
  var lines = svg.querySelectorAll("line[data-from]");
  var panning = false;
  var lockedId = null;

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

  // "selected" marks the exact node a click locked onto; "neighbor" marks
  // everything else the lock keeps visible -- both on top of the plain
  // dim/not-dim split, so a locked node and its cross-cluster neighbors are
  // still findable at a glance even once their own cluster is otherwise
  // dimmed away.
  function highlight(id) {
    var keep = neighborsOf(id);
    nodes.forEach(function(n) {
      var nid = n.getAttribute("data-id");
      // classList.toggle(cls, x) treats an explicit `undefined` x as "no
      // force argument given" (falls back to flip-on-current-presence, i.e.
      // ADDS an absent class) rather than "force absent" -- and
      // `keep[nid] && nid !== id` is `undefined`, not `false`, whenever
      // keep[nid] itself is unset (the raw short-circuit value of &&, not
      // a coerced boolean). Without the `!!`, every non-neighbor node ended up
      // wrongly marked "neighbor" too, on top of correctly being "dim".
      n.classList.toggle("dim", !keep[nid]);
      n.classList.toggle("selected", nid === id);
      n.classList.toggle("neighbor", !!keep[nid] && nid !== id);
    });
    lines.forEach(function(l) {
      // Coerce to a real boolean up front, not just at the `!touches` call
      // site -- `keep[a] && keep[b]` is `undefined` (not `false`) whenever
      // either lookup misses, and passing that raw `undefined` to the
      // second toggle() below would hit the exact same force-argument
      // gotcha the node classes above already had to work around.
      var touches = !!(keep[l.getAttribute("data-from")] && keep[l.getAttribute("data-to")]);
      l.classList.toggle("dim", !touches);
      l.classList.toggle("active", touches);
    });
  }

  function clear() {
    nodes.forEach(function(n) { n.classList.remove("dim", "selected", "neighbor"); });
    lines.forEach(function(l) { l.classList.remove("dim", "active"); });
    info.style.display = "none";
  }

  // Dropping the lock is always a full clear -- an unlock that left stale
  // highlight classes in place would leave lockedId null but the diagram
  // still showing the old selection, or vice versa.
  function unlock() {
    lockedId = null;
    clear();
  }

  function showInfo(n) {
    var title = n.querySelector("title");
    var id = n.getAttribute("data-id");
    info.textContent = (title ? title.textContent : id) + "  --  " + id;
    info.style.display = "block";
  }

  nodes.forEach(function(n) {
    n.addEventListener("mouseenter", function() {
      if (panning || lockedId) return;
      highlight(n.getAttribute("data-id"));
      showInfo(n);
    });
    n.addEventListener("mouseleave", function() {
      if (!panning && !lockedId) clear();
    });
    // Click locks the current highlight so it survives the mouse moving
    // away -- lets you pan/scroll around the highlighted neighbors, or
    // click one of those (now-visible) neighbors in turn to trace a path
    // across clusters, instead of the highlight vanishing the instant the
    // cursor leaves the node.
    n.addEventListener("click", function(e) {
      e.stopPropagation();
      var id = n.getAttribute("data-id");
      if (lockedId === id) {
        unlock();
        return;
      }
      lockedId = id;
      highlight(id);
      showInfo(n);
    });
  });

  // Clicking anywhere else on the canvas (background, or bubbled up from a
  // cluster-label click) drops the lock.
  svg.addEventListener("click", function() {
    if (lockedId) unlock();
  });

  // --- zoom (wheel, centered on cursor) ---
  function svgPoint(clientX, clientY) {
    var pt = svg.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    return pt.matrixTransform(svg.getScreenCTM().inverse());
  }

  // Individual symbol labels only earn their clutter once you have
  // deliberately zoomed in on something -- past ~35% of the original
  // extent, chosen so a couple of scroll notches on a specific cluster
  // reveals its member names without needing to zoom in so far that you
  // lose the surrounding context entirely.
  var ZOOM_LABEL_THRESHOLD = 0.35;
  function updateZoomClass() {
    var ratio = svg.viewBox.baseVal.width / svg._origW;
    svg.classList.toggle("zoomed-in", ratio < ZOOM_LABEL_THRESHOLD);
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
    updateZoomClass();
  }, { passive: false });
  svg._origW = svg.viewBox.baseVal.width;

  // --- pan (drag) ---
  var lastX = 0, lastY = 0, dragged = false;
  svg.addEventListener("mousedown", function(e) {
    panning = true;
    dragged = false;
    lastX = e.clientX;
    lastY = e.clientY;
    svg.classList.add("panning");
  });
  window.addEventListener("mousemove", function(e) {
    if (!panning) return;
    // Unlocking has to wait for the first real movement, not fire on
    // mousedown itself -- mousedown also fires for a plain click (no drag),
    // and unlocking there would null out lockedId before the node\'s own
    // click handler gets to compare "lockedId === id" against its own
    // re-click, permanently breaking click-the-locked-node-again-to-unlock.
    if (!dragged) {
      dragged = true;
      unlock();
    }
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

  // --- click a legend entry or an in-canvas cluster label to zoom to it ---
  // Bounding box comes from the rendered .node groups themselves (getBBox
  // includes each node.hit circle, so the fit already has the same margin
  // a single node gets), not from recomputing community layout math in JS.
  function communityBBox(id) {
    var els = svg.querySelectorAll(\'.node[data-community="\' + id + \'"]\');
    if (els.length === 0) return null;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    els.forEach(function(el) {
      var b = el.getBBox();
      minX = Math.min(minX, b.x);
      minY = Math.min(minY, b.y);
      maxX = Math.max(maxX, b.x + b.width);
      maxY = Math.max(maxY, b.y + b.height);
    });
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
  }

  function zoomToCommunity(id) {
    var box = communityBBox(id);
    if (!box) return;
    var pad = 40;
    var vb = svg.viewBox.baseVal;
    var w = Math.max(box.w + pad * 2, 60);
    var h = Math.max(box.h + pad * 2, 60);
    vb.x = box.x + box.w / 2 - w / 2;
    vb.y = box.y + box.h / 2 - h / 2;
    vb.width = w;
    vb.height = h;
    unlock();
    updateZoomClass();
  }

  document.querySelectorAll(".legend-item").forEach(function(el) {
    el.addEventListener("click", function() {
      zoomToCommunity(el.getAttribute("data-community"));
    });
  });
  svg.querySelectorAll(".cluster-label-group").forEach(function(el) {
    el.addEventListener("click", function() {
      zoomToCommunity(el.getAttribute("data-community"));
    });
  });
})();
'
