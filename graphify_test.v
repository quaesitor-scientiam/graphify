module graphify

const sample = 'module demo

import os

pub struct User {
pub:
	name string
	age  int
}

pub const max_users = 100

pub fn (u User) greeting() string {
	return greet(u.name)
}

fn greet(name string) string {
	return "hi " + name
}

fn main() {
	println(greet("world"))
}
'

fn test_extracts_core_symbols() {
	syms, edges := extract_v_text(sample, 'demo.v')

	mut kinds := map[string]int{}
	for s in syms {
		kinds[s.kind.str()]++
	}

	assert kinds['module'] == 1
	assert kinds['import'] == 1
	assert kinds['struct'] == 1
	assert kinds['const'] == 1
	assert kinds['method'] == 1 // greeting
	assert kinds['fn'] == 2 // greet, main

	// the method signature is body-less and includes the receiver
	method := syms.filter(it.name == 'greeting')[0]
	assert method.signature.starts_with('pub fn (u User) greeting()')
	assert method.signature.ends_with('string')

	// a calls edge from main/greeting to greet should exist
	mut has_call := false
	for e in edges {
		if e.kind == .calls && e.to == 'greet' {
			has_call = true
		}
	}
	assert has_call
}

fn test_skeleton_is_bodyless() {
	syms, _ := extract_v_text(sample, 'demo.v')
	mut g := Graph{}
	g.symbols = syms
	out := g.emit_skeleton()

	assert out.contains('module demo')
	assert out.contains('import os')
	assert out.contains('{ ... }') // fn bodies elided
	assert !out.contains('println') // no implementation leaked
}
