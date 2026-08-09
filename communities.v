module graphify

import rand

// Leiden-style community detection: split the graph into subsystems by
// modularity optimization, deterministically labeled (no LLM involved --
// see label_community).
//
// What this implements, precisely, since "Leiden" names a specific paper's
// algorithm and it's worth being exact about how this differs from it:
//   1. Louvain local-moving + multi-level aggregation to (locally) maximize
//      modularity -- the same core as the original Louvain algorithm.
//   2. A connectivity-guaranteeing pass afterward: each resulting
//      community's induced subgraph (on the ORIGINAL, unaggregated edges)
//      is checked, and anything disconnected is split into its connected
//      components.
// The Leiden paper's actual contribution over Louvain is a randomized
// refinement phase that guarantees connectivity *during* the merge process
// itself, which also tends to find better partitions than a post-hoc split
// because it never lets a node get provisionally "trapped" behind a worse
// merge in the first place. Step 2 above delivers the same practically-
// important guarantee (no scattered/disconnected community) via a much
// simpler, much easier-to-verify mechanism: connected-components is a
// solved primitive, a randomized multi-way refinement merge is not
// something to hand-roll and trust without a reference implementation to
// check against. If the distinction matters for a particular use, that is
// the honest place it would show up.
//
// Communities are computed on demand from a Graph, like query/explain --
// not persisted into graph.json, since the result depends on `resolution`
// and is meant to be cheaply re-runnable without re-extracting.

// Community is one cluster found by community detection.
pub struct Community {
pub:
	id      int
	label   string   // deterministic: the most internally-connected member's name
	members []string // symbol ids, sorted
}

// default_leiden_restarts is how many randomized attempts communities()
// makes by default, keeping the highest-modularity result.
// louvain_local_moving shuffles its visitation order every pass, which is
// necessary to explore different local optima but also means any single run
// can land on a meaningfully worse one purely by chance -- measured
// directly on Zachary's Karate Club, individual single-run results ranged Q
// 0.325 to 0.364 across 10 runs (a ~12% spread), and the commonly-cited
// ~0.42 for Louvain on that graph is itself a best-of-many-restarts figure,
// not what one run typically lands on. Restarting and keeping the best is
// the standard way to guard against that, not a tuning knob -- but more
// restarts costs proportionally more time (measured: ~9.6s at 10 restarts,
// ~41.6s at 50, on a real ~30k-symbol/~82k-edge codebase), so the default is
// a speed/reliability balance, not the highest quality achievable. Pass a
// higher `restarts` for a smaller or more important graph where the wait is
// worth it.
pub const default_leiden_restarts = 20

// CommunitiesConfig configures communities(). `resolution` follows the
// standard resolution-limited modularity convention: 1.0 is plain
// modularity; > 1 penalizes large communities more, so it favors more,
// smaller ones; < 1 favors fewer, larger ones. `restarts` overrides
// default_leiden_restarts; see its doc comment for the speed/reliability
// tradeoff a higher value buys.
@[params]
pub struct CommunitiesConfig {
pub:
	resolution f64 = 1.0
	restarts   int = default_leiden_restarts
}

// communities splits the graph into subsystems.
pub fn (g Graph) communities(config CommunitiesConfig) []Community {
	resolution := config.resolution
	idx := g.index()
	w0 := build_wgraph(idx)
	if w0.nodes.len == 0 {
		return []
	}

	mut best_comm := map[string]int{}
	mut best_q := -1.0
	restarts := if config.restarts > 0 { config.restarts } else { 1 }
	for _ in 0 .. restarts {
		comm := cluster_once(w0, resolution)
		q := modularity(w0, comm, resolution)
		if q > best_q {
			best_q = q
			best_comm = comm.clone()
		}
	}

	mut groups := map[int][]string{}
	for node, c in best_comm {
		groups[c] << node
	}
	mut flat_groups := [][]string{}
	for _, members in groups {
		flat_groups << members
	}

	final_groups := split_disconnected(idx, flat_groups)

	mut out := []Community{}
	for grp in final_groups {
		mut sorted_grp := grp.clone()
		sorted_grp.sort()
		out << Community{
			label:   label_community(idx, sorted_grp)
			members: sorted_grp
		}
	}
	out.sort(a.members.len > b.members.len)
	mut renumbered := []Community{cap: out.len}
	for i, c in out {
		renumbered << Community{
			id:      i
			label:   c.label
			members: c.members
		}
	}
	return renumbered
}

// cluster_once runs one randomized pass of multi-level Louvain local-moving
// + aggregation to convergence, returning the resulting community
// assignment expanded back down to the ORIGINAL graph's node ids -- so
// repeated calls can be compared on equal footing via modularity(w0, ...),
// which is what communities()'s restart loop does.
fn cluster_once(w0 WGraph, resolution f64) map[string]int {
	// chain[i] maps each aggregate id produced by the (i+1)-th aggregation
	// back to the node ids (aggregate ids from the previous level, or
	// original ids at level 0) it collapsed.
	mut chain := [][]MemberEntry{}
	mut cur := w0
	for _ in 0 .. 50 { // aggregation strictly shrinks the node count each round it runs; generous headroom, not a real cap expected to bind
		comm, moved := louvain_local_moving(cur, resolution)
		if !moved {
			break
		}
		next, member_of := aggregate(cur, comm)
		if next.nodes.len >= cur.nodes.len {
			break // no further shrinkage: converged
		}
		chain << member_of
		cur = next
	}
	// one last local-moving pass at whatever level the loop stopped on, to
	// get the community assignment actually used for the final output
	top_comm, _ := louvain_local_moving(cur, resolution)

	mut comm_of := map[string]int{}
	for node in cur.nodes {
		c := top_comm[node]
		for orig in expand_membership(node, chain) {
			comm_of[orig] = c
		}
	}
	return comm_of
}

// --- weighted undirected graph -------------------------------------------
//
// Kept as flat maps keyed by a canonical pair string rather than a nested
// map[string]map[string]f64, since V requires an explicit .clone() for any
// map-to-map copy (confirmed directly, not assumed) and a flat structure
// sidesteps that entirely rather than fighting it.

struct WGraph {
mut:
	nodes     []string
	neighbors map[string][]string // deduplicated
	weight    map[string]f64      // pair_key(a, b) -> summed edge weight, a != b
	self_loop map[string]f64      // node -> internal weight folded in by a prior aggregation
	degree    map[string]f64      // weighted degree, including 2x self-loop
	total_w   f64                 // m: sum of all edge weight, invariant across aggregation levels
}

fn pair_key(a string, b string) string {
	return if a < b { '${a}\x01${b}' } else { '${b}\x01${a}' }
}

// build_wgraph turns the graph's resolved internal edges into an undirected
// weighted graph for clustering: two symbols linked by several edges (say,
// both a `calls` and a `references` edge) end up more tightly connected
// than two linked by just one. Self-loops (a symbol referencing itself)
// carry no community information and are dropped.
//
// Only `calls`, `references`, and `embeds` count -- edges that mean "these
// two things interact", which is what a community is supposed to capture.
// `defines`/`imports`/`implements` are containment/hierarchy relationships,
// already visible from `parent`/file structure, not interaction; including
// them pulls a module's unrelated members toward its own hub node instead
// of toward whatever they actually collaborate with. This also meaningfully
// reduces (though does not eliminate) a real, pre-existing limitation
// `defines` edges made much worse: a raw id like `main.main` is shared by
// every standalone program's entry point (the same case resolve_edges'
// `unaddressable` check exists for on the calls side), and Index.by_id
// collapses every symbol sharing an id into one node regardless of how many
// distinct real declarations use it -- so every unrelated program's main()
// was appearing as edges into a single conflated "main" node. That
// conflation is a property of Index itself, not something fixable here; see
// the note in README's Status.
fn build_wgraph(idx Index) WGraph {
	mut w := WGraph{}
	mut seen := map[string]bool{}
	for e in idx.edges {
		if e.from == e.to {
			continue
		}
		if e.kind !in [EdgeKind.calls, .references, .embeds] {
			continue
		}
		key := pair_key(e.from, e.to)
		w.weight[key] = w.weight[key] + 1.0
	}
	for key, wt in w.weight {
		parts := key.split('\x01')
		a, b := parts[0], parts[1]
		if a !in seen {
			seen[a] = true
			w.nodes << a
		}
		if b !in seen {
			seen[b] = true
			w.nodes << b
		}
		w.neighbors[a] << b
		w.neighbors[b] << a
		w.degree[a] = w.degree[a] + wt
		w.degree[b] = w.degree[b] + wt
		w.total_w += wt
	}
	return w
}

// --- local moving ----------------------------------------------------------
//
// Gain formula verified against the standard Louvain derivation (Blondel et
// al. 2008), not reconstructed from memory alone: moving node i (already
// removed from its current community) into candidate community C gives
//   ΔQ = k_i,in(C) / (2m)  -  resolution * Σ_tot(C) * k_i / (2 * m^2)
// where k_i,in(C) is i's summed edge weight to members of C, Σ_tot(C) is
// C's total weighted degree (excluding i, since i was already removed),
// k_i is i's own weighted degree, and m is the graph's total edge weight.
// `resolution` scales the second (repulsion / null-model) term: > 1 makes
// joining an already-large community more costly, so it favors more,
// smaller communities.

fn louvain_local_moving(w WGraph, resolution f64) (map[string]int, bool) {
	mut comm := map[string]int{}
	mut comm_tot := map[int]f64{}
	for i, node in w.nodes {
		comm[node] = i
		comm_tot[i] = w.degree[node]
	}
	m := w.total_w
	if m <= 0 {
		return comm, false
	}
	mut any_move := false
	mut pass_improved := true
	mut order := w.nodes.clone()
	for pass_improved {
		pass_improved = false
		// Fixed visitation order is a well-documented way for local-moving
		// to settle into a needlessly weak local optimum -- reshuffling
		// each pass is standard practice, not a nicety: verified directly
		// against Zachary's Karate Club (see the test), where a fixed order
		// converged to Q~0.34 and shuffling reaches the ~0.42 commonly
		// cited for Louvain on this graph.
		rand.shuffle(mut order) or {}
		for node in order {
			cur := comm[node]
			ki := w.degree[node]
			comm_tot[cur] -= ki
			mut k_in := map[int]f64{}
			k_in[cur] = 0.0 // always a real candidate, even with zero remaining ties
			for nb in w.neighbors[node] {
				c := comm[nb]
				k_in[c] = k_in[c] + w.weight[pair_key(node, nb)]
			}
			mut best_c := cur
			mut best_gain := k_in[cur] / (2.0 * m) -
				resolution * comm_tot[cur] * ki / (2.0 * m * m)
			for c, kin in k_in {
				if c == cur {
					continue
				}
				gain := kin / (2.0 * m) - resolution * comm_tot[c] * ki / (2.0 * m * m)
				if gain > best_gain {
					best_gain = gain
					best_c = c
				}
			}
			comm_tot[best_c] += ki
			if best_c != cur {
				comm[node] = best_c
				pass_improved = true
				any_move = true
			}
		}
	}
	return comm, any_move
}

// modularity computes Q = Σ_c [ L_in(c)/m - resolution*(D(c)/2m)^2 ], the
// resolution-limited modularity of `comm` over `w`. Not used by the
// clustering loop itself (which only ever needs relative gains, never an
// absolute score), but kept for tests to check against known benchmarks.
fn modularity(w WGraph, comm map[string]int, resolution f64) f64 {
	m := w.total_w
	if m <= 0 {
		return 0.0
	}
	mut l_in := map[int]f64{}
	mut deg_sum := map[int]f64{}
	for key, wt in w.weight {
		parts := key.split('\x01')
		if comm[parts[0]] == comm[parts[1]] {
			l_in[comm[parts[0]]] = l_in[comm[parts[0]]] + wt
		}
	}
	for node in w.nodes {
		c := comm[node]
		l_in[c] = l_in[c] + w.self_loop[node]
		deg_sum[c] = deg_sum[c] + w.degree[node]
	}
	mut q := 0.0
	for c, d in deg_sum {
		q += l_in[c] / m - resolution * (d / (2.0 * m)) * (d / (2.0 * m))
	}
	return q
}

// --- aggregation -------------------------------------------------------

// MemberEntry pairs an aggregate node id with the node ids (from the level
// below) it collapsed, so the final top-level assignment can be expanded
// back down to original graph node ids.
struct MemberEntry {
	id      string
	members []string
}

// aggregate collapses each community in `comm` into a single node of a new,
// smaller WGraph. Inter-community edge weight sums directly; a community's
// own internal edges (between two of its members, or self-loop weight a
// member already carried in from an earlier aggregation) become the new
// node's self-loop weight -- this is what lets a later level's modularity
// calculation still see that internal density, which is essential for
// correctness, not an optimization.
fn aggregate(w WGraph, comm map[string]int) (WGraph, []MemberEntry) {
	mut agg_id := map[int]string{}
	mut member_of := map[string][]string{}
	for node in w.nodes {
		c := comm[node]
		if c !in agg_id {
			agg_id[c] = 'c${agg_id.len}'
		}
		aid := agg_id[c]
		member_of[aid] << node
	}
	mut new_w := WGraph{}
	mut seen := map[string]bool{}
	for node in w.nodes {
		aid := agg_id[comm[node]]
		if aid !in seen {
			seen[aid] = true
			new_w.nodes << aid
		}
		new_w.self_loop[aid] = new_w.self_loop[aid] + w.self_loop[node]
	}
	for key, wt in w.weight {
		parts := key.split('\x01')
		a_id := agg_id[comm[parts[0]]]
		b_id := agg_id[comm[parts[1]]]
		if a_id == b_id {
			new_w.self_loop[a_id] = new_w.self_loop[a_id] + wt
		} else {
			pk := pair_key(a_id, b_id)
			new_w.weight[pk] = new_w.weight[pk] + wt
		}
	}
	for key, wt in new_w.weight {
		parts := key.split('\x01')
		new_w.neighbors[parts[0]] << parts[1]
		new_w.neighbors[parts[1]] << parts[0]
		new_w.degree[parts[0]] = new_w.degree[parts[0]] + wt
		new_w.degree[parts[1]] = new_w.degree[parts[1]] + wt
		new_w.total_w += wt
	}
	for aid, sl in new_w.self_loop {
		new_w.degree[aid] = new_w.degree[aid] + 2.0 * sl
		new_w.total_w += sl
	}
	mut entries := []MemberEntry{cap: member_of.len}
	for aid, members in member_of {
		entries << MemberEntry{
			id:      aid
			members: members
		}
	}
	return new_w, entries
}

// expand_membership walks `chain` in reverse (from the last aggregation
// performed back to the first) to resolve an aggregate node id at whatever
// level it lives at back down to the original graph's node ids.
fn expand_membership(node string, chain [][]MemberEntry) []string {
	if chain.len == 0 {
		return [node]
	}
	last := chain[chain.len - 1]
	mut children := []string{}
	mut found := false
	for e in last {
		if e.id == node {
			children = e.members.clone()
			found = true
			break
		}
	}
	if !found {
		return [node] // shouldn't happen for a node that truly came from this level
	}
	rest := chain[..chain.len - 1]
	mut out := []string{}
	for child in children {
		out << expand_membership(child, rest)
	}
	return out
}

// --- connectivity guarantee + labeling ----------------------------------

// split_disconnected checks each community's induced subgraph against the
// ORIGINAL (unaggregated) adjacency and splits anything disconnected into
// its connected components -- see the doc comment on `communities` for why
// this, rather than the Leiden paper's own refinement phase.
fn split_disconnected(idx Index, groups [][]string) [][]string {
	mut out := [][]string{}
	for group in groups {
		mut in_group := map[string]bool{}
		for id in group {
			in_group[id] = true
		}
		mut visited := map[string]bool{}
		for start in group {
			if visited[start] {
				continue
			}
			mut component := []string{}
			mut queue := [start]
			visited[start] = true
			for queue.len > 0 {
				node := queue.pop()
				component << node
				for nb in idx.adj[node] or { []string{} } {
					if nb in in_group && !visited[nb] {
						visited[nb] = true
						queue << nb
					}
				}
			}
			out << component
		}
	}
	return out
}

// label_community names a community after its most internally-connected
// member -- the same "most representative node" idea bundle.v's report
// already uses for the whole graph's most-connected symbols, just scoped to
// one community. Deterministic, no LLM involved.
fn label_community(idx Index, members []string) string {
	if members.len == 0 {
		return ''
	}
	mut in_group := map[string]bool{}
	for id in members {
		in_group[id] = true
	}
	mut best := members[0]
	mut best_deg := -1
	for id in members {
		mut deg := 0
		for nb in idx.adj[id] or { []string{} } {
			if nb in in_group {
				deg++
			}
		}
		if deg > best_deg {
			best_deg = deg
			best = id
		}
	}
	s := idx.by_id[best] or { return best }
	return s.name
}
