module graphify

import math
import os

// LaidOutNode is one symbol positioned for rendering, with the community it
// was assigned to (for color-coding) and its degree (for sizing).
struct LaidOutNode {
	id        string
	x         f64
	y         f64
	label     string
	kind      SymbolKind
	community int
	degree    int
}

// svg_max_nodes caps how many symbols a layout ever positions. An SVG with
// every symbol in a large real codebase (tens of thousands of nodes) would
// be too large to usefully render or even open; capping to the
// highest-degree members of each community keeps the output legible while
// still showing a proportional slice of every community, not just the
// single biggest one.
const svg_max_nodes = 300

// IdDegree pairs a symbol id with its degree, so it can be sorted directly
// -- a .sort() closure can't reach an outer-scope map like degree_of.
struct IdDegree {
	id     string
	degree int
}

// RingOpts positions and scales a ring layout -- shared by the top-level
// layout (layout_communities) and each drill-view's own nested layout (see
// graph_html.v), so both go through the identical trigonometry instead of
// two independently-maintained copies drifting apart.
struct RingOpts {
	center_x  f64
	center_y  f64
	max_nodes int
	// outer_r is the ring radius communities are placed on. 0 means "use
	// the default whole-canvas formula" (max(n_comms*70, 400)); a
	// drill-view passes an explicit smaller radius, measured from the
	// parent community's own rendered footprint, so its nested ring fits
	// within roughly the space that community already occupies rather than
	// reusing a scale meant for the whole canvas.
	outer_r f64
}

// layout_ring positions a set of communities on a 2D canvas: the
// communities are arranged around an outer circle, and each community's
// own members around a smaller circle centered on its spot -- a
// deterministic, structure-informed layout instead of an iterative
// force-directed simulation, which would need its own convergence/quality
// verification the way communities.v's Louvain implementation did. Genuine
// physical realism isn't the goal; showing which symbols cluster into which
// subsystem, and roughly how big each is relative to the others, is.
//
// Caps at opts.max_nodes total, keeping each community's highest-degree
// members in proportion to that community's own size, so a handful of
// giant communities can't crowd out every smaller one. Returns the
// laid-out (possibly capped) nodes and the true total node count (so
// callers can show an honest "N of M" instead of silently truncating).
fn layout_ring(comms []Community, idx Index, opts RingOpts) ([]LaidOutNode, int) {
	mut degree_of := map[string]int{}
	for id, neighbors in idx.adj {
		degree_of[id] = neighbors.len
	}

	mut total := 0
	for c in comms {
		total += c.members.len
	}

	mut kept_per_community := [][]string{}
	if total <= opts.max_nodes {
		for c in comms {
			kept_per_community << c.members
		}
	} else {
		for c in comms {
			mut want := int(f64(opts.max_nodes) * f64(c.members.len) / f64(total))
			if want < 1 {
				want = 1
			}
			// .sort()'s closure can't reach an outer variable like degree_of
			// (confirmed by the compiler, not assumed) -- pair id with its
			// own degree and sort that instead, the same workaround
			// top_by_degree already uses for the identical constraint.
			mut ranked := []IdDegree{cap: c.members.len}
			for id in c.members {
				ranked << IdDegree{
					id:     id
					degree: degree_of[id]
				}
			}
			ranked.sort(a.degree > b.degree)
			mut kept := []string{cap: want}
			for i := 0; i < ranked.len && i < want; i++ {
				kept << ranked[i].id
			}
			kept_per_community << kept
		}
	}

	mut out := []LaidOutNode{}
	n_comms := kept_per_community.len
	outer_r := if opts.outer_r > 0 {
		opts.outer_r
	} else if n_comms * 70 > 400 {
		f64(n_comms * 70)
	} else {
		400.0
	}
	for ci, members in kept_per_community {
		if members.len == 0 {
			continue
		}
		mut cx := opts.center_x
		mut cy := opts.center_y
		if n_comms > 1 {
			angle := 2.0 * math.pi * f64(ci) / f64(n_comms)
			cx = opts.center_x + outer_r * math.cos(angle)
			cy = opts.center_y + outer_r * math.sin(angle)
		}
		inner_r := 18.0 + 9.0 * math.sqrt(f64(members.len))
		for j, id in members {
			s := idx.by_id[id] or { continue }
			mut x := cx
			mut y := cy
			if members.len > 1 {
				m_angle := 2.0 * math.pi * f64(j) / f64(members.len)
				x = cx + inner_r * math.cos(m_angle)
				y = cy + inner_r * math.sin(m_angle)
			}
			out << LaidOutNode{
				id:        id
				x:         x
				y:         y
				label:     s.name
				kind:      s.kind
				community: ci
				degree:    degree_of[id]
			}
		}
	}
	return out, total
}

// layout_communities lays out the whole graph's top-level communities --
// computing communities is the expensive part (communities.v's restart
// loop), so both emit_svg and emit_graph_html call this once each rather
// than recomputing it a second time just for a legend.
fn layout_communities(g Graph, idx Index) ([]LaidOutNode, int, []Community) {
	comms := g.communities()
	nodes, total := layout_ring(comms, idx, RingOpts{max_nodes: svg_max_nodes})
	return nodes, total, comms
}

// palette colors nodes by community. 16 visually distinct hues; communities
// beyond that cycle rather than run out, since a large real codebase can
// easily have more than 16 -- an approximate visual grouping past that
// point beats no color at all.
const palette = [
	'#e6194b', '#3cb44b', '#ffe119', '#4363d8', '#f58231', '#911eb4', '#46f0f0', '#f032e6',
	'#bcf60c', '#fabebe', '#008080', '#e6beff', '#9a6324', '#800000', '#aaffc3', '#000075',
]

fn node_color(community int) string {
	return palette[community % palette.len]
}

// community_location summarizes where a community's members actually live
// in the source tree. Exists because a community's own label (its most
// internally-connected member's name -- see label_community) doesn't say
// what part of the codebase it corresponds to; this does, using data
// graphify already captured (Symbol.file) rather than anything new.
// Reports the single directory most members share when there's a real
// (strict) majority, or a plain count of distinct directories when there
// isn't one -- guessing a "best" directory when members are actually
// scattered would misrepresent the community, not describe it. An exact tie
// (e.g. 1 of 2 members in each of two directories) is deliberately treated
// as no majority rather than >= 0.5: picking one side of a tie would be an
// arbitrary, non-deterministic choice (map iteration order isn't
// guaranteed), not a real finding about the community.
fn community_location(idx Index, members []string) string {
	mut dir_count := map[string]int{}
	for id in members {
		s := idx.by_id[id] or { continue }
		dir_count[os.dir(s.file)]++
	}
	if dir_count.len == 0 {
		return ''
	}
	if dir_count.len == 1 {
		for d, _ in dir_count {
			return d
		}
	}
	mut best_dir := ''
	mut best_n := 0
	for d, n in dir_count {
		if n > best_n {
			best_n = n
			best_dir = d
		}
	}
	if f64(best_n) / f64(members.len) > 0.5 {
		extra := dir_count.len - 1
		return '${best_dir} +${extra} more dir${if extra == 1 { '' } else { 's' }}'
	}
	return '${dir_count.len} directories'
}

// emit_svg renders the graph as a single self-contained SVG: nodes
// clustered and colored by community (see layout_communities), sized by
// degree, connected by lines for every resolved edge between two rendered
// nodes. A title comment at the top notes when the node count was capped,
// so a smaller rendering never silently passes as the whole graph.
pub fn (g Graph) emit_svg() string {
	idx := g.index()
	nodes, total, comms := layout_communities(g, idx)
	return render_svg(nodes, idx, total, comms, []string{}, map[int]bool{})
}

// drill_badge_markup renders a small "drill in" badge -- a circle with a
// "+" glyph -- next to a drillable community's in-canvas label. Kept as its
// own element rather than folded into cluster_label_markup since only some
// communities have one; its own generously-sized hit target mirrors the
// same oversized-hit-target pattern `.hit`/`.cluster-hit` already
// established, rather than trusting the small glyph's own painted pixels.
fn drill_badge_markup(cx f64, cy f64, extra_attr string) []string {
	mut sb := []string{}
	sb << '    <g class="drill-badge"${extra_attr}>'
	sb << '      <circle class="drill-badge-hit" cx="${cx:.1f}" cy="${cy:.1f}" r="12" fill="transparent"/>'
	sb << '      <circle class="drill-badge-dot" cx="${cx:.1f}" cy="${cy:.1f}" r="6" fill="white" stroke="#555" stroke-width="1"/>'
	sb << '      <text x="${cx:.1f}" y="${(cy + 3):.1f}" font-size="9" font-weight="bold" fill="#555" text-anchor="middle">+</text>'
	sb << '    </g>'
	return sb
}

// cluster_desc formats a community's on-canvas label text: name, member
// count, and (if known) where in the source tree it actually lives -- the
// same "name (count) — location" shape used by both the top-level cluster
// labels and each drill-view's own nested sub-community labels.
fn cluster_desc(idx Index, c Community) string {
	loc := community_location(idx, c.members)
	return if loc == '' {
		'${xml_escape(c.label)} (${c.members.len})'
	} else {
		'${xml_escape(c.label)} (${c.members.len}) — ${xml_escape(loc)}'
	}
}

// edge_markup renders <line> elements for every edge in idx.edges whose
// endpoints are both present in `pos` -- shared by the top-level render and
// each drill-view's own nested render, which naturally restricts to that
// view's own edges since `pos` only contains that view's own nodes.
// data-from/data-to/data-id are inert in a plain SVG viewer but let
// emit_graph_html add hover-highlight interactivity by reusing this output
// directly instead of duplicating the rendering.
fn edge_markup(idx Index, pos map[string]LaidOutNode) []string {
	mut sb := []string{}
	for e in idx.edges {
		a := pos[e.from] or { continue }
		b := pos[e.to] or { continue }
		sb << '    <line data-from="${xml_escape(e.from)}" data-to="${xml_escape(e.to)}" x1="${a.x:.1f}" y1="${a.y:.1f}" x2="${b.x:.1f}" y2="${b.y:.1f}"/>'
	}
	return sb
}

// node_markup renders one <g class="node" data-id=...{extra_attr}> for a
// single laid-out node -- shared by the top-level render and each
// drill-view's nested render so the hit-circle/dot/label markup (and its
// hit-target sizing) can't drift between the two. `extra_attr` is the
// community-identifying attribute the caller wants on this node (top-level:
// ` data-community="N"`; a drill-view: ` data-drill-community="parent.sub"`,
// a different attribute name so the two levels' community indices -- both
// independently renumbered 0..M-1 -- can never collide in a query).
fn node_markup(n LaidOutNode, extra_attr string) []string {
	r := 3.0 + (if n.degree > 20 { 20.0 } else { f64(n.degree) }) * 0.4
	color := node_color(n.community)
	// `.hit` is a much larger invisible circle purely for hovering: the
	// visible dot stays small (its size encodes degree), but a real
	// mouse cursor hitting a 3-11 SVG-unit circle is unrealistic --
	// confirmed directly with a WebDriver-synthesized pointer move
	// landing dead-center on a node and finding its rendered size was
	// only ~4x4 CSS pixels. `opacity` on a <g> composites the whole
	// group as one unit, so emit_graph_html can dim/highlight an entire
	// node (dot + label) by toggling one class on this wrapper.
	hit_r := if r + 8.0 > 14.0 { r + 8.0 } else { 14.0 }
	mut sb := []string{}
	sb << '    <g class="node" data-id="${xml_escape(n.id)}"${extra_attr}>'
	sb << '      <circle class="hit" cx="${n.x:.1f}" cy="${n.y:.1f}" r="${hit_r:.1f}" fill="transparent"/>'
	sb << '      <circle class="dot" cx="${n.x:.1f}" cy="${n.y:.1f}" r="${r:.1f}" fill="${color}" fill-opacity="0.85" stroke="#333" stroke-width="0.4">'
	sb << '        <title>${xml_escape(n.label)} (${xml_escape(n.kind.str())})</title>'
	sb << '      </circle>'
	sb << '      <text class="node-label" x="${(n.x + r + 2):.1f}" y="${(n.y + 3):.1f}" font-size="7" fill="#222">${xml_escape(n.label)}</text>'
	sb << '    </g>'
	return sb
}

// cluster_label_markup renders one interactive cluster label -- a hit rect
// plus the visible text -- shared by the top-level cluster labels and any
// future interactive nested label. `group_class`/`extra_attr` let the
// caller pick the class JS hooks click handlers on and the
// community-identifying attribute, the same collision-avoidance reasoning
// as node_markup's `extra_attr`.
fn cluster_label_markup(idx Index, c Community, cx f64, cy f64, group_class string, extra_attr string) []string {
	desc := cluster_desc(idx, c)
	// `.cluster-hit` gives the label a real click target: the text
	// itself is `pointer-events: none` (see emit_graph_html's CSS, so
	// hover/click on a node underneath a label still reaches the node),
	// so without a separate hit rect the clickable area would be
	// whatever glyph pixels happen to be painted -- the same
	// too-small-to-actually-hit problem the node `.hit` circle above
	// exists to avoid, just for text instead of a dot. Width is a rough
	// per-character estimate for bold 9px sans-serif, generous rather
	// than exact since overshooting just makes clicking easier.
	text_w := f64(desc.len) * 5.5 + 20.0
	label_y := cy - 14.0
	mut sb := []string{}
	sb << '    <g class="${group_class}"${extra_attr}>'
	sb << '      <rect class="cluster-hit" x="${(cx - text_w / 2):.1f}" y="${(label_y - 10.0):.1f}" width="${text_w:.1f}" height="20" fill="transparent"/>'
	sb << '      <text class="cluster-label" x="${cx:.1f}" y="${label_y:.1f}" font-size="9" font-weight="bold" fill="#333" text-anchor="middle" paint-order="stroke" stroke="white" stroke-width="3">${desc}</text>'
	sb << '    </g>'
	return sb
}

// render_svg builds the actual `<svg>...</svg>` markup from an
// already-computed layout -- split out so emit_graph_html can reuse it
// without recomputing communities a second time (see layout_communities).
// `comms` is the full (uncapped) community list, needed for the on-canvas
// cluster labels: a community's true member count and its label/location
// both come from here, not from whatever subset actually got rendered.
// `extra` is appended verbatim just before the closing `</svg>` -- used by
// emit_graph_html to embed each drillable community's own nested drill-view
// `<g>` inside the same SVG root, not tacked on after it (which would put
// them outside the SVG entirely, breaking both `viewBox` sizing and any
// `svg.querySelectorAll(...)` lookup over them). `drillable` marks which
// community indices get an in-canvas "drill in" badge next to their label;
// empty for the plain, JS-less emit_svg() path.
fn render_svg(nodes []LaidOutNode, idx Index, total int, comms []Community, extra []string, drillable map[int]bool) string {
	if nodes.len == 0 {
		return '<svg xmlns="http://www.w3.org/2000/svg"><text x="10" y="20">empty graph</text></svg>'
	}

	mut pos := map[string]LaidOutNode{}
	for n in nodes {
		pos[n.id] = n
	}

	mut min_x, mut min_y := nodes[0].x, nodes[0].y
	mut max_x, mut max_y := nodes[0].x, nodes[0].y
	for n in nodes {
		if n.x < min_x {
			min_x = n.x
		}
		if n.x > max_x {
			max_x = n.x
		}
		if n.y < min_y {
			min_y = n.y
		}
		if n.y > max_y {
			max_y = n.y
		}
	}
	pad := 60.0
	vb_x := min_x - pad
	vb_y := min_y - pad
	vb_w := (max_x - min_x) + 2 * pad
	vb_h := (max_y - min_y) + 2 * pad

	mut sb := []string{}
	if nodes.len < total {
		sb << '<!-- showing ${nodes.len} of ${total} symbols (svg_max_nodes cap); the highest-degree members of each community were kept -->'
	}
	sb << '<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb_x:.1f} ${vb_y:.1f} ${vb_w:.1f} ${vb_h:.1f}" font-family="sans-serif">'
	sb << '  <rect x="${vb_x:.1f}" y="${vb_y:.1f}" width="${vb_w:.1f}" height="${vb_h:.1f}" fill="white"/>'

	sb << '  <g stroke="#ccc" stroke-width="0.6">'
	sb << edge_markup(idx, pos)
	sb << '  </g>'

	sb << '  <g>'
	for n in nodes {
		sb << node_markup(n, ' data-community="${n.community}"')
	}
	sb << '  </g>'

	// One label per community, at the centroid of whichever of its members
	// actually got rendered (not the community's theoretical unclipped
	// center -- if the svg_max_nodes cap trimmed some members, the centroid
	// of what's really on screen is the honest place to put the label).
	// This is the primary thing visible at the default zoomed-out view
	// (see emit_graph_html's "node-label" CSS, which hides individual node
	// labels until zoomed in); a plain static SVG has no zoom to gate
	// anything behind, so both this and every node-label stay visible
	// there unconditionally, same as before this existed.
	mut centroid_x := map[int]f64{}
	mut centroid_y := map[int]f64{}
	mut centroid_n := map[int]int{}
	for n in nodes {
		centroid_x[n.community] += n.x
		centroid_y[n.community] += n.y
		centroid_n[n.community] += 1
	}
	sb << '  <g class="cluster-labels">'
	for ci, n in centroid_n {
		if n == 0 || ci >= comms.len {
			continue
		}
		cx := centroid_x[ci] / f64(n)
		cy := centroid_y[ci] / f64(n)
		sb << cluster_label_markup(idx, comms[ci], cx, cy, 'cluster-label-group', ' data-community="${ci}"')
		if ci in drillable {
			// A fixed small offset from centroid put the badge *inside* a
			// large community's own member ring (inner_r grows with
			// sqrt(member count) -- confirmed directly with a real
			// WebDriver click on a 30+-member community: the point
			// resolved to a member node's own .dot, not the badge,
			// because the badge sat well within that ring's actual
			// radius). Measure this community's real rendered spread and
			// clear it, the same way compute_drill_views sizes a
			// drill-view's own ring from the parent's real spread.
			mut max_dist := 0.0
			for m in nodes {
				if m.community == ci {
					dx := m.x - cx
					dy := m.y - cy
					d := math.sqrt(dx * dx + dy * dy)
					if d > max_dist {
						max_dist = d
					}
				}
			}
			sb << drill_badge_markup(cx, cy - max_dist - 20.0, ' data-community="${ci}"')
		}
	}
	sb << '  </g>'

	sb << extra
	sb << '</svg>'
	return sb.join('\n')
}
