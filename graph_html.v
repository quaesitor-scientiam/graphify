module graphify

import math

// drill_min_members gates which top-level communities are even considered
// for their own drill-view. Empirically grounded, not a guess: tested
// against the classic Fortunato-Barthelemy "ring of cliques" resolution
// limit case (many small cliques in a ring, each linked to its neighbors
// by one edge) -- the shape that most realistically produces a large,
// still-splittable top-level community, since plain modularity provably
// cannot resolve individual cliques past a certain ring size and starts
// merging neighbors together instead. A ring of 5-node cliques reliably
// produced merged communities of 30+ members that communities_within then
// correctly split back into their real constituent cliques; smaller
// thresholds risked catching noise, per the 34-node Zachary's Karate Club
// benchmark itself needing 30 restarts to reliably separate real structure
// (see communities.v). Still worth re-tuning against a real large corpus's
// actual rendered crowding, the way ZOOM_LABEL_THRESHOLD was.
const drill_min_members = 30

// drill_max_candidates bounds how many communities actually get a scoped
// communities_within() run (each with its own restart loop) and how much
// extra HTML gets embedded -- not how many of them turn out genuinely
// splittable. The one knob that caps both the extra clustering cost and
// the payload growth at once.
const drill_max_candidates = 10

// drill_max_nodes caps each individual drill-view's own layout -- smaller
// than svg_max_nodes since a drill-view is meant to fit within roughly the
// space its parent community occupies, not the whole canvas.
const drill_max_nodes = 150

// DrillView is one drillable community's precomputed nested sub-layout.
struct DrillView {
	parent_ci int
	svg       string
}

// CiCount pairs a community index with its member count so the candidate
// list can be sorted directly -- a .sort() closure can't reach an
// outer-scope variable like `comms` (the same constraint layout_ring's own
// IdDegree already works around).
struct CiCount {
	ci    int
	count int
}

// compute_drill_views decides which top-level communities are drillable and
// precomputes each one's own nested sub-layout, fully static -- consistent
// with this project's "compute once, embed the result" design, and
// necessary anyway since graph.html is a single static file with no server
// to compute anything on demand. Operates entirely on the `nodes`/`comms`
// emit_graph_html already has from its one call to layout_communities --
// never calls g.communities() again, since that call is randomized
// (rand.shuffle + restart-loop-keep-best, no fixed seed) and a second
// top-level call could return a different partition than the one already
// rendered, desyncing every id and membership list against it.
fn compute_drill_views(g Graph, idx Index, nodes []LaidOutNode, comms []Community) ([]DrillView, int) {
	mut ranked := []CiCount{}
	for ci, c in comms {
		if c.members.len >= drill_min_members {
			ranked << CiCount{
				ci:    ci
				count: c.members.len
			}
		}
	}
	ranked.sort(a.count > b.count)

	mut views := []DrillView{}
	for i := 0; i < ranked.len && i < drill_max_candidates; i++ {
		ci := ranked[i].ci
		c := comms[ci]
		// The real gate: a community whose induced subgraph is one
		// inseparable blob has nothing to drill into, regardless of size.
		sub_comms := g.communities_within(c.members, resolution: 1.0, restarts: 8)
		if sub_comms.len < 2 {
			continue
		}

		// Nest the drill-view within roughly the space this community
		// already occupies at the top level: center on its actual rendered
		// members' centroid, and scale the ring to its actual rendered
		// spread, rather than reusing a radius formula meant for the whole
		// canvas.
		mut px_sum, mut py_sum := 0.0, 0.0
		mut pcount := 0
		for n in nodes {
			if n.community == ci {
				px_sum += n.x
				py_sum += n.y
				pcount++
			}
		}
		if pcount == 0 {
			continue
		}
		pcx := px_sum / f64(pcount)
		pcy := py_sum / f64(pcount)
		mut max_dist := 0.0
		for n in nodes {
			if n.community == ci {
				dx := n.x - pcx
				dy := n.y - pcy
				d := math.sqrt(dx * dx + dy * dy)
				if d > max_dist {
					max_dist = d
				}
			}
		}
		drill_outer_r := max_dist * 0.6 + 20.0

		sub_nodes, _ := layout_ring(sub_comms, idx, RingOpts{
			center_x:  pcx
			center_y:  pcy
			max_nodes: drill_max_nodes
			outer_r:   drill_outer_r
		})

		mut pos := map[string]LaidOutNode{}
		for n in sub_nodes {
			pos[n.id] = n
		}

		mut sb := []string{}
		sb << '  <g class="drill-view" data-parent-community="${ci}">'
		sb << edge_markup(idx, pos)
		for n in sub_nodes {
			// Sub-community indices are independently renumbered 0..M-1,
			// same as top-level -- a compound "parent.sub" id, on a
			// different attribute name than top-level's data-community,
			// keeps the two levels' queries from ever colliding.
			sb << node_markup(n, ' data-drill-community="${ci}.${n.community}"')
		}
		mut centroid_x := map[int]f64{}
		mut centroid_y := map[int]f64{}
		mut centroid_n := map[int]int{}
		for n in sub_nodes {
			centroid_x[n.community] += n.x
			centroid_y[n.community] += n.y
			centroid_n[n.community] += 1
		}
		for sci, n in centroid_n {
			if n == 0 || sci >= sub_comms.len {
				continue
			}
			scx := centroid_x[sci] / f64(n)
			scy := centroid_y[sci] / f64(n)
			// Purely informational label, not a click-to-zoom target: no
			// further drill-down in v1 (see communities_within's doc
			// comment), so there's nothing for a second click to do here.
			desc := cluster_desc(idx, sub_comms[sci])
			sb << '    <text class="drill-sub-label" x="${scx:.1f}" y="${(scy - 14.0):.1f}" font-size="7" font-weight="bold" fill="#333" text-anchor="middle" paint-order="stroke" stroke="white" stroke-width="2">${desc}</text>'
		}
		sb << '  </g>'

		views << DrillView{
			parent_ci: ci
			svg:       sb.join('\n')
		}
	}
	return views, ranked.len
}

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
	drill_views, drill_candidates := compute_drill_views(g, idx, nodes, comms)
	mut drillable := map[int]bool{}
	mut drill_extra := []string{}
	for v in drill_views {
		drillable[v.parent_ci] = true
		drill_extra << v.svg
	}
	svg := render_svg(nodes, idx, total, comms, drill_extra, drillable)

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
		badge_html := if i in drillable {
			' <span class="drill-badge-legend" data-community="${i}" title="drill into ${xml_escape(c.label)}">+</span>'
		} else {
			''
		}
		legend << '    <div class="legend-item" data-community="${i}"><span class="swatch" style="background:${color}"></span>${xml_escape(c.label)} <span class="count">(${c.members.len})</span>${loc_html}${badge_html}</div>'
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
	sb << '  #drill-caption { position: fixed; top: 44px; right: 10px; background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 10px; font-size: 11px; color: #555; }'
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
	sb << '  #legend .drill-badge-legend { display: inline-block; margin-left: 6px; width: 14px; height: 14px; line-height: 14px; text-align: center; border-radius: 50%; background: #eee; color: #555; font-weight: bold; font-size: 11px; cursor: pointer; }'
	sb << '  #legend .drill-badge-legend:hover { background: #ddd; }'
	sb << '  svg .drill-badge { cursor: pointer; }'
	sb << '  svg .drill-badge .drill-badge-hit { pointer-events: all; }'
	sb << '  svg .drill-badge .drill-badge-dot { transition: fill 0.1s; }'
	sb << '  svg .drill-badge:hover .drill-badge-dot { fill: #eee; }'
	// A drilled-into community's flat top-level content hides (not just
	// dims) so it can't visually compete with its own drill-view nested
	// roughly in the same spot; hidden hit targets need the same explicit
	// pointer-events override the drill-view itself needs below, or they
	// would stay clickable underneath the now-visible drill-view sitting on
	// top of them. `.dot` needs the same override as `.hit`/`.cluster-hit`
	// -- confirmed the hard way with a real click landing exactly on a
	// hidden node's own visible dot: unlike `.hit`/`.cluster-hit`, `.dot`
	// has no explicit pointer-events anywhere else in this stylesheet, so
	// it keeps the browser's default (hit-testable) even at opacity 0 --
	// opacity alone never implies pointer-events:none.
	sb << '  svg .drill-hidden { opacity: 0; }'
	sb << '  svg .drill-hidden .hit, svg .drill-hidden .cluster-hit, svg .drill-hidden .dot { pointer-events: none; }'
	// A drill-view starts hidden and non-interactive: opacity alone does
	// not stop its .hit/.cluster-hit/.dot circles from intercepting clicks
	// meant for the very visible flat nodes they are nested on top of,
	// since `.hit`/`.cluster-hit` are given an explicit
	// `pointer-events: all` elsewhere in this stylesheet (and an explicit
	// declaration always wins over an inherited one regardless of DOM
	// nesting), while `.dot` keeps the browser's own default
	// (hit-testable) pointer-events with no override at all -- same gap as
	// `.drill-hidden` above, just for the reverse hidden state.
	sb << '  svg .drill-view { opacity: 0; transition: opacity 0.15s; }'
	sb << '  svg .drill-view .hit, svg .drill-view .cluster-hit, svg .drill-view .dot { pointer-events: none; }'
	sb << '  svg .drill-view.active { opacity: 1; }'
	sb << '  svg .drill-view.active .hit, svg .drill-view.active .cluster-hit, svg .drill-view.active .dot { pointer-events: all; }'
	sb << '  #back-btn { position: fixed; top: 10px; left: 50%; transform: translateX(-50%); background: white; border: 1px solid #ccc; border-radius: 4px; padding: 6px 14px; font-size: 12px; cursor: pointer; display: none; box-shadow: 0 1px 4px rgba(0,0,0,0.15); }'
	sb << '  #back-btn:hover { background: #f0f0f0; }'
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
	if drill_views.len < drill_candidates {
		sb << '<div id="drill-caption">${drill_views.len} of ${drill_candidates} large communities include a detail view</div>'
	}
	sb << '<div id="info"></div>'
	sb << '<div id="hint">scroll to zoom &middot; drag to pan &middot; hover a node &middot; click to lock &amp; trace${if drill_views.len > 0 { ' &middot; + to drill in' } else { '' }}</div>'
	sb << '<button id="back-btn">&#9668; back to overview</button>'
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
// held. Zooming to a community always drops any lock (unlock(), not just
// clear()) so lockedId and the visible highlight never drift out of sync
// with each other -- but panning does NOT drop a lock, only a transient
// hover highlight: a locked highlight is meant to survive exactly this,
// panning/zooming out to trace where a highlighted edge actually goes.
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
      // The browser still fires a trailing "click" at mouseup even after
      // real, substantial drag movement (confirmed directly: a synthesized
      // ~90px drag still produced one) -- without this guard, that
      // trailing click landing on a node would silently re-lock onto
      // whatever the drag happened to end over, right after the drag
      // itself already correctly left the real lock alone.
      if (dragged) return;
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
    // Same trailing-click-after-a-drag guard as the per-node click handler
    // above -- otherwise a drag that happens to end over empty canvas
    // (not any node) silently drops a lock the drag itself was just fixed
    // to preserve, via this completely different code path.
    if (dragged) return;
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
    // The dragged-check itself has to wait for the first real movement,
    // not fire on mousedown -- mousedown also fires for a plain click (no
    // drag), and acting there would step on the node\'s own click handler
    // comparing "lockedId === id" against its own re-click, permanently
    // breaking click-the-locked-node-again-to-unlock.
    //
    // A *locked* highlight deliberately survives panning -- that is the
    // whole point of locking it (see the click handler above: "lets you
    // pan/scroll around the highlighted neighbors"), including panning out
    // to see where a highlighted edge actually leads. Only a transient,
    // never-locked hover highlight gets cleared here, so a drag starting
    // mid-hover does not leave a stale highlight pointing at a node the
    // cursor is no longer over.
    if (!dragged) {
      dragged = true;
      if (!lockedId) {
        clear();
      }
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
    exitDrill(); // a plain zoom means "show me the flat top-level view"
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

  // --- drill-down: reveal a large community\'s own precomputed nested
  // sub-layout (see compute_drill_views) ---
  //
  // A separate "+" badge, not the existing legend/label click, triggers
  // this -- that click already means "zoom to fit" for every community,
  // and silently changing its meaning only for drillable ones would be a
  // real surprise. Exiting is a persistent, explicit button, not a
  // re-click toggle or an implicit zoom-out threshold: both of those are
  // the same "implicit gesture" bug class that already broke
  // click-the-locked-node-to-unlock once this session (see the pan
  // handler above) -- an explicit button is boring and correct.
  var activeDrillCi = null;
  var preDrillViewBox = null;
  var backBtn = document.getElementById("back-btn");

  // Bounding box scoped to one drill-view\'s own nodes -- a *different*
  // attribute (data-drill-community, compound "parent.sub" values) than
  // communityBBox\'s data-community query above, so a drill-view\'s own
  // community 0 can never be picked up by a top-level query for community
  // 0 (sub-community indices are independently renumbered 0..M-1, same as
  // top-level).
  function drillBBox(ci) {
    var els = svg.querySelectorAll(\'.node[data-drill-community^="\' + ci + \'."]\');
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

  function exitDrill() {
    if (activeDrillCi === null) return;
    var view = svg.querySelector(\'.drill-view[data-parent-community="\' + activeDrillCi + \'"]\');
    if (view) view.classList.remove("active");
    svg.querySelectorAll(\'.node[data-community="\' + activeDrillCi + \'"]\').forEach(function(n) {
      n.classList.remove("drill-hidden");
    });
    var label = svg.querySelector(\'.cluster-label-group[data-community="\' + activeDrillCi + \'"]\');
    if (label) label.classList.remove("drill-hidden");
    activeDrillCi = null;
    backBtn.style.display = "none";
    if (preDrillViewBox) {
      var vb = svg.viewBox.baseVal;
      vb.x = preDrillViewBox.x;
      vb.y = preDrillViewBox.y;
      vb.width = preDrillViewBox.width;
      vb.height = preDrillViewBox.height;
      preDrillViewBox = null;
    }
    updateZoomClass();
  }

  function drillInto(ci) {
    if (activeDrillCi === ci) return;
    var view = svg.querySelector(\'.drill-view[data-parent-community="\' + ci + \'"]\');
    if (!view) return;
    exitDrill(); // only one drill-view active at a time
    unlock();
    var vb = svg.viewBox.baseVal;
    preDrillViewBox = { x: vb.x, y: vb.y, width: vb.width, height: vb.height };
    svg.querySelectorAll(\'.node[data-community="\' + ci + \'"]\').forEach(function(n) {
      n.classList.add("drill-hidden");
    });
    var label = svg.querySelector(\'.cluster-label-group[data-community="\' + ci + \'"]\');
    if (label) label.classList.add("drill-hidden");
    view.classList.add("active");
    activeDrillCi = ci;
    var box = drillBBox(ci);
    if (box) {
      var pad = 30;
      var w = Math.max(box.w + pad * 2, 60);
      var h = Math.max(box.h + pad * 2, 60);
      vb.x = box.x + box.w / 2 - w / 2;
      vb.y = box.y + box.h / 2 - h / 2;
      vb.width = w;
      vb.height = h;
    }
    backBtn.style.display = "block";
    updateZoomClass();
  }

  document.querySelectorAll(".drill-badge-legend").forEach(function(el) {
    el.addEventListener("click", function(e) {
      e.stopPropagation(); // don\'t also trigger the parent legend-item\'s zoom-to-fit
      drillInto(el.getAttribute("data-community"));
    });
  });
  svg.querySelectorAll(".drill-badge").forEach(function(el) {
    el.addEventListener("click", function(e) {
      e.stopPropagation();
      drillInto(el.getAttribute("data-community"));
    });
  });
  backBtn.addEventListener("click", function() {
    exitDrill();
  });
})();
'
