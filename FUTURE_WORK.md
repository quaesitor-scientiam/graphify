# Future work and known gaps

This file records the concrete limitations identified in the current Graphify
design. It is intentionally scoped to gaps that affect graph accuracy,
portability, or day-to-day use; completed features and exploratory ideas stay
in `README.md`.

## 1. Remaining call-edge ambiguity

The extractor uses V's parser and a per-file AST table. It resolves calls by
callee name, method/function shape, file/module locality, and import
visibility, but it does not run V's whole-program checker.

**Receiver type inference (October 2026).** A method call whose receiver's
type the code doesn't write now records a recipe for it at extraction
(`recipe` in backend_v.v): where the receiver comes from, such as a call's
result, a field, an element or a loop variable. `resolve_edges` follows the
recipe through the return and field types the whole graph records (infer.v)
and picks the method on the type it reaches. Extraction stays per file, so
caching, crash isolation and partially broken projects are unaffected. On the
V compiler's tree (b69f626f14) it cut unresolved calls from 28,642 to 7,733
(11.5% to 3.1% of calls), and it replaced 1,974 earlier locality guesses,
which a sample showed were mostly wrong (`name.contains('.')` on a string had
resolved to `v.types.Scope.contains`).

**Interface members and undeclared calls (October 2026).** An interface's
methods and fields are now symbols (`builtin.IError.msg`), so `err.msg()`
and any call on an interface-typed value resolve to the interface's method;
methods and fields reached through an embedded struct or interface are
followed too. A call with no declaration to resolve to, of a function value
(a variable, parameter or function-typed field), `thread.wait()` or an array
method the compiler provides, is marked `undeclared` instead of counting as
unresolved, and `explain` no longer lists it as a possible caller of a
same-named function. On the same tree: 3,775 calls unresolved (1.5%), 1,631
undeclared.

`Graph.index()` leaves undeclared calls unresolved, so query, path, explain
and communities don't link them to a same-named declaration by unique name
(109 did so on that tree).

**Consts, globals and function fields (October 2026).** A const records the
recipe of its value and a `__global` its type (globals are now symbols), so a
receiver that names one, `preface.bytes()` or `os.args.clone()`, is followed
through it. A call of a function-typed field, `s.on_running()`, resolves to
the field's declaration with provenance `inferred`, rather than being
undeclared. `str()` on a type that doesn't declare one, and a `@[flag]`
enum's `has()`/`set()`/..., are methods V writes itself and are marked
undeclared. On the V compiler's tree (245448b415): 2,748 calls unresolved
(1.1%), 2,159 undeclared; every changed resolution in a sample was a
correction (`a.flags.set(.noscan_data)` had resolved to `array.set`).

**Builtin calls, guard errors and qualified embeds (October 2026).** A plain
`error()` resolves by V's own rule: the caller's module's function, else
builtin's, since another module's needs its prefix (`log.error`); before,
an imported module's same-named function made it ambiguous. A function
with a variant per platform (`_windows.c.v`, `_linux.c.v`) is placed by the
file a call is in, where its shared id had left it with no location at all.
`err` in the `else` of `if x := f()` is `IError`, as in `or {}`. An embedded
`veb.Context` keeps its module on the `embeds` edge, so it no longer
resolves to the local `Context` that embeds it (51 structs had embedded
themselves); a module named through an import is the one `resolve_import`
found (`import wasm` is `vlib.wasm`, not `vlib.v.gen.wasm`), and never a
standalone program's directory (`examples/veb`). A dynamic array's fields
are `array`'s (`xs.flags.has()`), `first()`/`last()`/`pop()` give an
element rather than builtin's `voidptr`, and `type_name()` on a sum type or
interface is undeclared. On the V compiler's tree (245448b415): 1,561 calls
unresolved (0.61%), 2,237 undeclared; each changed resolution in a sample
was a correction (`db.DB.select()` through an embedded `sqlite.DB` had
resolved to the calling method itself).

**Qualified type references and conditional imports (October 2026).** A
`references` edge kept only a type's last name, so `img gfx.Image` in module
`gg`, which declares an `Image` of its own, pointed at `gg.Image`, and 66
declarations referenced themselves through a same-named type from another
module (50 of them structs embedding `veb.Context`). References now carry
the module as the embeds do (`type_ref` in backend_v.v), written, aliased or
selectively imported. An `import` inside `$if mysql ? { ... }` now counts
like any other, as every branch of a `$if` does: calls such as
`sgl.v2f()` in a wrapper of the same name had resolved to the wrapper
itself. On the V compiler's tree (a78037685a): unresolved references 1,283 ->
880, with 180 retargeted; unresolved calls 1,568 -> 1,516, with 80
retargeted.

**Generic call results (October 2026).** `json.decode[Config](s)!` returns
`T`; the recipe for it now carries the type arguments written in the call
(`p:` steps), and a free function's type parameters are read from its header
line (V3's parser drops them, and they go in the symbol's `recipe`), so `T`
becomes `Config`, and in `fold[T, R]` the second argument stands for `R`. An
argument that can't be named (`&T`, `[]T`) keeps its place, so the others
still line up. Receivers of a generic type are covered in the next entry. On the V compiler's tree (the same commit
as above): unresolved calls 1,516 -> 1,441 (0.56%), 64 more resolved, 1
retargeted from a same-named method in an unrelated module to the
`json2.Any` it returns, and 11 `str()`/`type_name()` calls marked undeclared
(`d.str()` on a struct without a `str` method).

**Generic receivers (October 2026).** A method or field of a generic type
takes its type arguments from the receiver's type: `q.pop()!` on a
`Queue[models.Config]` returns `models.Config`, and `q.items[0]` is a
`models.Config` where the field is `[]T`. A generic struct's type parameters
come from its header line (`struct Queue[T]`), and a method's from its
receiver (`&Queue[T]`), both kept on the symbol's recipe as for functions. The
arguments are qualified with the module they were written in before they are
substituted, so a type named in one module still means that type in another.
On the V compiler's tree: unresolved calls 1,441 -> 1,431 (0.56%), 19 more
resolved and 7 retargeted (`Foo[int].value` and `Cell[T].v` fields, a call
on `[]string` returned by `Queue[[]string].pop()`). Two earlier links, to an
unrelated `Test.v` method, now point at the `Cell.v` field they call.

**Smartcasts and match branches (October 2026).** Inside `if x is T { ... }`
and to the right of `x is T && ...`, `x` is a `T`; inside a `match x { T { ... } }`
branch with one type pattern, too. A narrowed receiver whose type lacks the method
falls back to its declared type, as V does (`x.name()` on a `Shape`, where `name` is
declared on the sum type): the call's recipe carries both, separated by `recipe_alt`,
and infer_call tries the declared one second. The walk also stops a narrowed
receiver from being resolved against its sum type, which had sent `e.method()` in a
`match e { Variant { ... } }` method of the sum type to the sum type's own method.
On the V compiler's tree: unresolved calls 1,431 -> 1,293 (0.51%), 116 more
resolved, 29 retargeted. Eight links removed were wrong: a call to a sum type's own
method (`Any.i64()` calling itself, where its `Number` branch calls `Number.i64`),
and `condition.contains` on a string resolved to two unrelated `contains` methods.
Undeclared rose by 54, all `has()` on a `@[flag]` enum, which V generates.

**Unsafe blocks and untyped map literals (October 2026).** An `unsafe { x }`
block has the type of its last expression, as `if` and `match` already did, so
`b := unsafe { xs[0] }` is the element type. A map literal written without a
type, `{ 'name': 'Joe' }`, has `map[K]V` when its keys and its values are each
one kind of literal (string, int, bool or float). On the V compiler's tree:
unresolved calls 1,293 -> 1,046 (0.41%), 240 more resolved, 34 retargeted, 23
more undeclared (`str()` on a map, which V writes). Four links removed were
guesses by name: `raw.bytestr()` on a `[]u8` had resolved to `Response.bytestr`,
and a call in a platform variant of `close_conn` to a `free` on an unrelated
Windows type.

**Files of one program (October 2026).** A directory of `module main` files
with exactly one `fn main` is one program, which V compiles together, so its
files see each other's functions as they see a module's. Previously a `main`
caller could only see its own file, so a helper in a sibling file stayed
unresolved. A directory with several `fn main`s is several programs, which
still see only their own file (the examples directory has one program per
file). On the V compiler's tree: unresolved calls 1,046 -> 913 (0.36%), 141
more resolved and 9 retargeted to the same program's declaration rather than
an imported one with the same name (`vpm`'s `rmdir_all` for `os.rmdir_all`).
None dropped.

Shifts and bit operators keep their left operand's type, so `(u128(1) << 64).str()`
resolves to `u128.str`, and `str()` on a primitive that has no declaration (`u128`
in builds that lack one) is undeclared. On the V compiler's tree: unresolved calls
913 -> 900 (0.35%).

A declaration that exists once per platform (`open_tool_cache_entry_dir` in
`toolcache_nix.c.v` and `_windows.c.v`) can't be given one call edge that is right
on every OS, and the graph must be identical on every OS. A plain call to one now
links to every platform's version (`platform_variants`), each a real declaration,
so a change to any of them shows its caller. A method call to one used to stay
unresolved, since the receiver's type isn't checked (23 calls on the V compiler's
tree at an earlier commit). On `c6bb06f5` no unresolved call is a method call to a
per-platform declaration: the only unresolved calls that share a name with one are a
function-typed field's call and two array `index` calls. And a C function's result (`C.PQerrorMessage(...)`) has the C
type, which the graph doesn't name.

A call in a constant's, global's or struct field's initializer (`const x = f()`, `n int = f()`) is recorded as made by that declaration. Its caller id is set after the renames that give colliding declarations their own ids (`resolve_initializer_callers`), so a constant that shares a name with a function keeps its own calls. On the V compiler's tree that adds 2,023 call edges. On a 300-name sample per group, checking the graph's caller files against the source (string literals, comments and casts excluded): names declared once 98.2% → 98.7%, names declared in several files 97.5% → 98.2%.

V generates `T.zero()` for a `@[flag]` enum, and for no other enum, so an unresolved call of that form to a flag enum in the caller's module is undeclared (`enum_names` and `flag_here`, in resolve_edges). The flag is read from the attribute by `is_flag_enum` (backend_v.v) into the enum's signature. It only matches an unqualified name: a `zero()` on an enum from another module (`asn1.Integer.zero()`) stays unresolved.
A call on the result of a function declared once per platform is typed when every copy returns the same type (`same_return`, in infer.v), since the copies are renamed apart in a standalone program and no single one is the call's target. A call that reaches one copy of a function or method reaches all of them (`variants_of`, in resolve_edges), since the graph must match on every platform. A receiver's method is also found when its copy is named with its file (the base-name pass in resolve_callee). On the V compiler's tree that resolves 23 more calls and adds 39 call edges.

A fixed-size array literal (`['Jan', 'Feb']!`) is a postfix node over an array literal, which the recipe code didn't read, so its elements had no type. Its recipe is now the literal's (`.postfix` in recipe). On the V compiler's tree that resolves a loop over `const month_names = [...]!` and 28 other calls.

A call of a parameter of function type (`h fn () Doc`) has the function's return type (`fn_return`, in infer.v). A generic call's map or array type argument (`json.decode[map[string]json.Any](s)`) is named as written, so the type it returns is known. What's left among the receivers on the V compiler's tree is mostly generic: a return type that is a type parameter of a generic function (`extract[H]`), or of a method (`reflect[T]()`), whose own type parameters aren't stored, and a module the tree doesn't have (`markdown`). The variable of a `$for field in T.fields` loop is a builtin `FieldData` (`comptime_for` in the walk), so its `attrs` and `name` are typed.

A member of an enum (`Colour.red`) is a value of the enum's type, when the name before it is an enum and not a constant (`enum_type` and `is_enum`, in infer.v). A method on that value is then found as on any type: `str()` on an enum that declares none is one V writes, so it is undeclared, and a `@[flag]` enum's `has()` and `set()` are too. A local initialized from a member (`flags := ArrayFlags.is_slice | ...`) has the enum's type, so `flags.set(...)` no longer links to an unrelated `array.set`. On the V compiler's tree that is 23 fewer unresolved calls (791 → 768), 14 of them `str()`, and none newly unresolved.

A call of `str()` on a type that declares none is one V writes, and it returns a `string`, so a method called on the result (`x.str().contains(...)`) is found on `string`. `follow_steps` takes the type of the `str` step from the same rule that makes the call undeclared (`no_method`, in infer.v). On the V compiler's tree that resolves 42 calls on `string`, 25 of them `contains`, and none is newly unresolved.

A generic type argument written out (`json.decode[[]map[string]json.Any](s)`) is named through the file's imports like any other type text (`type_arg` calls `type_text`, in backend_v.v), so the element type it gives the result is found. Before, `json.Any` kept its alias, found no type, and `value.str()` on it linked by name to whichever `str` was declared. On the V compiler's tree that leaves 12 calls fewer unresolved (725 → 713), 11 of them `str()`, and the `int()` calls that had linked to `cmd.tools.vmcp.Args.int` now reach `json2.Any.int`.

A directory whose `alias.v` holds `@[alias: '@VMODROOT/<path>']` stands for the module at that path, as V's module aliasing does: `import x.json2` is `vlib/json2`. `alias_dir_target` (in backend_common.v) reads the target, and `resolve_import` names the module by it, so the module's calls and types resolve. The import keeps the path as written (`from` in its signature, and `f.imports`), since calls are spelled `x.json2.decode`. On the V compiler's tree that resolves 21 more calls, the 15 of `x.json2.decode` and `x.json2.encode` among them, and none is newly unresolved.

Inside `$if field.typ is T` (or `$if method.return_type is T`), the selector `x.$(field.name)` (or `x.$method()`) has the type T. `comptime_pin` reads the condition as the type it fixes, the walk carries it into the block in `pins` (set by the `.comptime_if` case), and the recipe reads it (`comptime_field_pin` and the method form). Unpinned, a field's type differs from field to field, so the call is left unresolved: a `$map` condition, a `!is`, or a compound one fixes nothing. On the V compiler's tree that resolves 5 calls more (692 → 687), 4 of them `str()`, and one `str()` on a struct that declares none is undeclared. What stays unresolved in this group is a generic receiver (`encode_struct[T]`), a field whose type differs by field with no check, and a method whose return type is the same for every method but not written as a check.
A map literal's entries are typed by `literal_type` (backend_v.v), which replaces the four-kind table: a rune, a nested literal, a cast or a conversion such as `Any(1)` or `json.Any(1)`, and an arithmetic or shift of these. So `{'a': `a`}` is a `map[string]rune`, and a `str()` on it is one V writes, not a call of some other type's `str`. `typeof(x)` is a string with `.idx` and `.name`, and `dump(x)` has x's type. `<-c` is the element of the channel `c` (`elem_type`, in infer.v). On the V compiler's tree that resolves 78 calls more (687 → 609), 17 of them `str()`, and 8 `str()` calls on values that declare none are undeclared. Left alone: comptime receivers (14 callers, covered by the comptime pins), `>>>` (its result is unsigned, which a plain recipe gets wrong), a `sql` block, and enum-literal keys.

A type parameter `T` is an unknown type to the graph, so a method on a value typed `T` finds nothing and falls to name matching. Inside `$if T is X { ... }`, V compiles the block only when `T` is `X`, so the block's `T` is `X` (`retyped`, in backend_v.v, and the `ct:` recipe step, read by `comptime_type`, in infer.v). The same holds for a variable of type `T` in `$if v is X`. An interface is not narrowed (`iface_ids`), since `T is Shape` holds for every type implementing `Shape`, and the call is not `Shape.str`. What stays unresolved in this group is a generic receiver with no check, which has one type per instantiation, and a `T` whose check is `$int` or another kind of type, which names no one type. On the V compiler's tree that resolves 6 calls more (609 → 603), 4 of them `str()`, and none is newly unresolved.

The first kind is 40 calls on the V compiler's tree at `c6bb06f5` (13 `str()`, 5 `type_name()`, and the rest, many of them in V's compiler tests and a few in `json2`, `json5`, `strconv`, `redis` and `cbor`). Linking them needs the types each generic is instantiated with, and most instantiations are inferred from the arguments rather than written: `format_thousands` has 2 explicit `[T]` call sites and 33 inferred ones, and `drop_owned` has 2 and 63. Resolving them means recording the type arguments at each generic call site, inferring those given as arguments, and linking each call to the method of every type it is instantiated with. That is now done for a non-method call of a free generic function (October 2026): each call records its argument recipes (`arg_sites`, in backend_v.v), the types a type parameter takes are read from them (`expand_type_param_calls`, in generics.v), and a method call on the parameter links to each type's method as an `inferred` edge. On the vlang tree that resolves 14 of the 82 bare-name calls on type parameters (343 → 329 unresolved), adds 38 inferred edges and removes none. The rest of that list is done too. A method of a generic struct links its type parameter to each instantiation of the struct, which is read from its receivers and field types (`expand_type_param_calls` and `instance_key`, in generics.v). An explicit type argument on a generic static method names its result, since the header `fn Box.new[T]` is found by its source name (`source_name`, in backend_v.v). A bare call in a method that no function of the module answers is the receiver's method of that name, as V calls it (`implicit_receiver_call`, in graphify.v). A type parameter passed on to another generic function, or built into a generic struct, takes the types of the one it comes from, followed to a fixed point (`Flow`, in generics.v). The `push_pq` case was a `mut` parameter: its signature writes the parameter as `&[]T`, which the parameter type did not strip, fixed in #65. A call on the result of such a call, `el.tag().bytes()`, takes the result type of each instance's method. With #65 to #67 and this change, the unresolved calls on the vlang tree fall from 364 to 348, and no call inside a generic struct stays unresolved. A call in a comptime branch on a type parameter, `$if T.unaliased_typ is string` or `$if T is X` with its `$else` blocks, is linked only to the instances that branch is compiled for, where the test is decided: an interface, an option, an array, a map, an enum, a sum type, a primitive, or a type's name (`guarded_instances`, in generics.v). A test on a generic or interface name, and `$struct`, keep every instance. Two edges this removed were wrong: `drop_owned[T]` to `IError.free`, which the `$interface` instance never compiles, and `ConcurrentMap.shard_for` to `string.str`, which the `$else` branch does not compile for a string key. Each call under a different branch is now its own edge, so a call that the old one-edge-per-callee merge hid can show as unresolved.

A value that is a `$if c { a } $else { b }` (vlib/builtin's `max_int`, and a local initialized from one) has the type its branches share. `recipe` takes the common recipe of the branches, and gives none when they differ or when a branch has no value, since V keeps one branch and the graph can't tell which. On the V compiler's tree that resolves 3 calls more (603 → 600), 2 of them the `str()` calls on `max_int`.

Four receivers the source states were lost. A `shared`, `atomic`, `volatile` or `static` statement writes its keyword in front of the declaration's name count, so `shared s := x` bound no name (`decl_count`, in backend_v.v). A qualified enum constant, `gg.HorizontalAlign.left`, looked up its enum by the short name and so found none (`enum_type`, in infer.v). A `sql db { select from T }!` block has the type the ORM transform gives it (`sql_expr` in the recipe). A map literal whose entries are enum members (`{.dog: 1, .cat: 2}`) had no type, since an enum member has none by `literal_type`, so the map had none (`literal_map_type` now takes the type from the entries that state one). A call of a method found in a same-named test file was linked across files, since the exact-id match skipped the test-only check (`resolve_callee`). On the V compiler's tree that resolves 22 more calls (600 → 578) and corrects two `Middleware[T].str` links to the enum methods they name.
Four receivers from the C and thread code. `spawn f()` had no recipe for the call's result, so `wait()` on the thread found no type; the spawn now carries `f`'s result, and `wait()` on a `thread` gives it (`thread T`, in infer.v). `str()` on a thread is one V writes (it prints `thread(int)`), so it is undeclared. A field of a C struct (`&C.addrinfo`) had no type, since `find_type` never matched the qualifier `C` and the `struct C.` declaration gave no field types; a field under the qualifier `C` now takes its type from that declaration. The unsigned right shift `a >>> b` has the unsigned type of `a` (`right_shift_unsigned`, in the recipe). What stays unresolved here: `C.getpgrp()`, since its declaration is in a system header the graph doesn't hold, and two C declarations with different results (`i32` and `int` for `strcmp`) would need one answer per platform. On the V compiler's tree that resolves 27 calls more (578 → 551), 3 of them `str()`.

**C function bindings (October 2026).** A `fn C.name(...) ret` declaration that vlib
writes in V source (3,063 across 422 files) was skipped, so a call of it had no
return type. It is a symbol now, with id `C.name` and signature `fn C.name(...) ret`,
so a call takes its result type from it (`extract_fn`, in backend_v.v). The `C.`
keeps it apart from a V function of the same name in the same file, the collision
the old skip guarded against. A binding is indexed under `C.name`, so a bare
`name(...)` never finds it, and `c_binding_callee` (graphify.v) resolves a
`C.name(...)` call to the one function of that name. Copies of a binding declared in
several files share one id, and the `unaddressable` rule does not apply to C ids,
since C has one namespace. A `type C.X = ...` declaration is a C type with the same
id form, and `C.X(v)` is a conversion to it, so it resolves as a call of the type.
On the vlib extract, 5,321 of the 5,329 calls to `C.` names now point at a binding
or a C type, and the 8 left undeclared name no declaration in the program. Before
this, every one of the 5,324 calls was raw.
A test copy of a binding in several files resolves to one of its copies, which may
carry the file as a suffix.

What is left of C is decided, not open (measured October 2026 on the full vlang
tree, 158,767 symbols). Calls to C names: 5,806, of which 5,798 resolve to a
binding or a C type. Type references to C names: 185, all resolved. The 8 that
stay undeclared name nothing a V file declares. Two are functions declared in a
C header in the repo (`add_two_numbers` and `hello_from_c`, in
`vlib/v/tests/include_c_gen_fn_headers/cheader.h`), and three are valgrind macros
(`VALGRIND_HG_DISABLE_CHECKING`, `ANNOTATE_HAPPENS_BEFORE`,
`ANNOTATE_HAPPENS_AFTER`) from headers the repo does not hold. Resolving the two
would take a parser for C headers, a backend this graph does not have (§3), and it
would still leave the valgrind macros unresolved. They stay undeclared.

Six receivers the source states were lost, in sum-type arms, method type parameters and array aliases. A `match` on a sum type narrowed its subject only for a capitalised name, so an arm that names a primitive (`i64 { val.str() }`), a module's type (`toml.Doc { doa.ast.table.str() }`) or an array (`[]int { ... }`) left its calls untyped (`match_pattern_type`, in backend_v.v). A method's own type parameter (`fn (d Doc) reflect[T]() T`) was not kept, so `x.reflect[User]()` returned an unknown `T`; a method now keeps its type parameters (`tparams`, which the batch protocol carries), and the type arguments the call writes stand for them (`p:` steps). An alias of an array (`type Sources = [2]Source`) took its element type by the alias's own name, so `source.map(it.value.str())` was lost; `[]`, `k`, and a method the alias doesn't have now unalias it first (`unalias`). A `map` whose closure states its return type is an array of that type (`mapto`). On the V compiler's tree that leaves 58 fewer unresolved calls (551 → 493): 43 now resolve, 4 are undeclared, and 11 merged into an identical edge of the same caller, which the resolver keeps once. Six of them are `str()` calls (41 → 35). The resolved edges that changed target, checked against the source by sample, each now name the type their receiver has in that arm: `Any.i8 → Any.i8` is `string.i8` in a string arm, and `hash.Hash.size` is `sha256.Digest.size` in its `sha256.Digest` arm.

A C struct is one name for the whole program, but V's C declarations are not unique: `C.Event`, `C.KEY_EVENT_RECORD` and `C.uChar` are declared in the terminal UI's Windows files and again in vlib's compiler tests and in `vlib/term`. `c_struct` (in infer.v) gave up when a name had more than one declaration, so a field of `C.Event` in `parse_events` had no type and its `str()` stayed unresolved. It now takes the nearest declaration: the one in the field's own file, then in its module, then in the program, and declarations of one id are one struct, one per platform (as `C.addrinfo` is). On the V compiler's tree that resolves one call (`parse_events`'s `str()` is `rune.str`) and changes no other edge.

An `if` or `match` expression's value was its first branch's value alone (`last_value` of the first block). A first branch that names no type, such as an interpolated string or a nested `if` with none, left the value untyped, though V requires the branches to share one type, so the value is the first branch that has a type (`if_expr` and `match_stmt` in backend_v.v). On the V compiler's tree that resolves four calls, all on string values: `display_host.contains` in `listen_host_display`, `name.contains` in `fn_text`, `constraint.bytes` in `check_inline_asm_intel_ios`, and `text.clone` in `drain_inbox`. A fifth, `name` in `check_lambda_expr`, now resolves to a `Type.name` edge the same caller already has, and the resolver keeps one edge for it.

A map literal was typed only when each of its keys and values stated its type in the text, so one variable value, or one empty `[]`, left the whole map untyped, and the calls on its values and keys went unresolved. V gives every entry the type the map has, so the map is the first key's type over the first value's, where the value is the first that has a recipe or states a type (`map_entries_recipe`, in backend_v.v, read by the `mapof:` step in infer.v). A number is left out of that choice, since an untyped number takes the type of the entries beside it. A negative number (`-1`) has the type of its literal (`literal_type`). On the V compiler's tree that resolves eight calls more, on maps and arrays: `keys`, `values` and `clone` on `const` map literals in `examples/gg` and `vlib/strings/lorem`, and `index` on the keys of one of them. Seven more merge into an identical edge of the same caller.

A call V generates is not a call into the program, so it is not unresolved. V generates `T.from(x)` and `T.from_string(s)` for every enum `T` (vlib/v/types/checker_tail.v), and `T.zero()` for a `@[flag]` enum. A call of one of them to an enum `T` in the caller's module, when `T` declares no method of that name, is marked undeclared (`resolve_edges`, in graphify.v). The check uses the symbol ids, so a declared `from` or `from_string` still resolves to its declaration. The `__addr` intrinsic and the `__v3_` forms (`__v3_isreftype`) are lowered by V's compiler or by V3 itself, so no edge is kept for them (`record_call`, in backend_v.v). On the V compiler's tree that marks 22 calls undeclared and removes 8 edges that were not calls. The runtime helpers `__malloc`, `bare_*`, `sys_write` and the `g_arena_*` hooks are not generated by the compiler: the bare builtin declares them in V source, so they stay unresolved. `T.type_name` and `T.new` on an alias or a generic owner are left unresolved as well, since V's rules for them don't reduce to a name. The `zero()` case also needs a `@[flag]` enum, as the caller's file sees it (see the flag paragraph below).

V's runtime helpers are calls into the runtime, not into the program. The bare builtin declares `__malloc`, `bare_print`, `bare_eprint`, `bare_panic`, `bare_backtrace` and `sys_write` in its own source (vlib/builtin/*/libc_impl.v), which the default build does not compile, and the arena builtin declares the `g_arena_*` hooks as function-valued globals it calls through (arena_d_builtin_arena.c.v). The graph leaves each call unresolved, since the names are declared more than once or only in a build it does not read. A call of one of these names that no declaration in the program resolves is marked undeclared (`runtime_helpers`, in graphify.v), after every other rule has had its chance, so a program declaration of the same name still resolves to it. On the V compiler's tree that marks 26 calls undeclared. A bare cast of a type alias, such as `uintptr_t(x)`, is a conversion to that alias, not a call, so it resolves to the alias when the alias is in scope (`alias_conversion` and `type_in_scope`, in graphify.v). A same-directory alias counts for a `module main` file when the directory has no `fn main`, since `v test` builds such a directory together, and an alias in a directory with several mains does not. On the V compiler's tree that resolves two casts in `translated_alias_casts`. Other C type names, which are not aliases, are still not covered.

A `@[flag]` enum is recorded as one. `is_flag_enum` (backend_v.v) reads the attribute lines above the declaration, and the signature carries it (`@[flag] pub enum Show`). The `zero()` check (`resolve_edges`, in graphify.v) marks a call undeclared only when the enum the caller's file sees is a flag enum: that file's own declaration first, else every enum of that name in the module, since two `_test.v` files can each declare one. On the V compiler's tree no edge changes. The eight `zero()` calls already name flag enums, and the 41 enums that carry the attribute are the 41 the source declares; the other 23 `@[flag]` lines in the tree are inside test fixture strings, not declarations.

A generic call's type argument can be a generic struct, as in `json.decode[AnyStruct[json.Any]](s)`. `type_arg` (backend_v.v) named only a plain name, a primitive, or a map or array literal, so the argument came through empty and the result's `T` stayed unknown. A field of that result, `.val`, then had no type, and `.int()` on it linked by name alone. That worked only while one `int` method was visible, so it broke once `vlib/builtin`'s `string.int` came into view. The argument is now named by its base and its own arguments, `AnyStruct[vlib.json2.Any]`, as the rest of the recipe names types, and the field's `T` takes `json.Any` (`owner_args`, in infer.v). On the V compiler's tree that resolves two `int()` calls in `vlib/json2/tests` to `Any.int` (inferred), and one `unix()` on `StructType[time.Time]` merges into the edge its caller already had to `time.Time.unix`. Unresolved calls go 416 → 413, and no resolved edge is removed.

A method a module declares on an array or map type is found from a file that names the type through an import. `method_on` (infer.v) tried only the builtin `array` and `map` methods on such a receiver, so toml's `value` on `map[string]Any`, `as_strings` on `[]Any` and `to_toml` never matched a receiver written `map[string]toml.Any`. `owner_matches` compares the declared owner with the written one token by token: each name must be the declared one, written from its own module or through an import that reaches that module, as the resolver matches imports (`import_reaches`). The exact-text match still goes first, so a generic `[]T` is unchanged. A candidate must also be in a module the file can name (its own, builtin, or imported), so the JS backend's `[]string.sort` does not stand in for the builtin one. On the V compiler's tree that resolves 12 calls. Sixteen `str()` calls, labelled undeclared, now go to the json2 `[]Any` and `map[string]Any` declarations they name. Left alone: an owner with a generic element (`[]T`, `map[K]V`), which the generic receivers already cover.

A `.map(...)` with no stated result gave its receiver builtin's `array` (`array.map` returns `array`), which no `[]string` owner matches, so a method the element type decides was lost. `follow_steps` (infer.v) now gives the result the type `[]`, an array of an element the graph doesn't know. `join` is then the one method V declares on a `[]string` alone, so `method_on` takes `[]string.join` for it (`string_array_methods`). The rule is limited to `join` on purpose: V generates `str()` for every array, so a builtin `[]string.str` says nothing about the receiver, and a rule over all names re-pointed `str` and a fixed-array `string` to the wrong declarations. On the V compiler's tree that resolves nine `join` calls, and two more on `string` (a `trim` and a `contains` after the `join`, now typed by its result). Two calls that linked to `net/http`'s `Header.join` by name are on a `[]string` and go to `[]string.join`. Left alone: a `.map(...)` followed by a method on the element (`trim`, `to_lower`), which needs the closure's own type.

Builtin declares `repeat` as returning an untyped `array`, as it does `map`, but a repeat keeps its elements: the result of `xs.repeat(n)` has `xs`'s own type. `follow_steps` (infer.v) gives it that type, so an element of it (`values.repeat(3)[0].change()`) and a method on it (`bs.repeat(2).hex()`) are found. Unlike `map`, the element type is known here, so the result is typed, not `[]`. On the V compiler's tree that resolves five calls: three new edges (`change` and `get_value` on a repeated interface value, `bytes` on a repeated string) and two `hex` calls on a repeated `[]u8`, which merge into `[]u8.hex` edges their functions already had.

A call through the name of the module the file is in (`semver.from(s)` inside `module semver`) was read as a method on a global of that name. `callee` (backend_v.v) now reads it as the module's own function, unless a local or a variable of the same name shadows it, the same way it reads a call through an import. On the V compiler's tree that resolves four `semver.from` calls, and a same-module call `same_module_type_name_fn.i64()` now goes to that module's `i64` instead of the builtin `string.i64` it had been linked to by name. The three `satisfies` calls on the result of `semver.from(...)` (a `Version`, whose `satisfies` is declared) stayed unresolved after that. The receiver's recipe named the callee by its module id (`c:vlib.semver.from`), and `resolve_qualified_callee` matched a prefix only against the module name as written (`semver`), so `call_result` found no `from` and the receiver had no type. A small fixture resolved only because its module had no other `satisfies`, so the name alone picked the method; the real `vlib/semver` also has `Range.satisfies`, `ComparatorSet.satisfies` and `Comparator.satisfies`. A prefix that is the file's module id now counts as its own module, and `test_a_method_on_a_module_call_result_is_typed_through_the_module_name` adds a second `satisfies` to the module, which fails without the fix. On the V compiler's tree at `c6bb06f5` unresolved calls go 381 → 378: the three `satisfies` edges go to `vlib.semver.Version.satisfies`, and no other edge changes.

**Range loop variables (October 2026).** A `for c in a .. b` loop variable was
typed `int` whatever its bounds. It now takes the type of the first bound that
states one (`range_recipe`, in backend_v.v): `u8(0) .. 255` loops over u8, and
`0 .. n` over n's type. On the V compiler's vlib tree, 3 `int.str` links are
replaced by the `str` methods of the types they loop over (`u32`, `u64`, `i64`,
`i32`), and `c.ascii_str().hex()` in `builtin/string_test.v` resolves. Unresolved
calls: 355 to 354.

What remains, measured on the vlib extract (October 2026, 272,668 calls): 354
calls are unresolved, and 3,013 bare-name calls are already undeclared (function
values, runtime helpers, `wait()` on a thread, and the rest of the rules above).
The cases checked are method calls on values of a type parameter, which the
generic receivers paragraph leaves unresolved (`work D` in `crypto/hmac`, and
`digest := h()` where `h fn () H` in `crypto/hkdf`), and JS declarations
(`JS.Array.prototype.constructor()`). A multi-line chain is not the cause: 2 of
the 3,368 bare-name calls sit on a continuation line of one. A string literal
receiver is typed and resolves (`'Hello World!'.hex()`).

JS host calls (October 2026). A `fn JS.name` binding is deliberately not a symbol
(`extract_from_ast` skips it), so a call into the JS host has no declaration to
resolve to, and it is `external`, the class `JS.parseInt` already had. Two shapes
were unresolved, or linked to a same-named V function, and are external now. A
static member of a binding, `JS.Promise.race(p)` or `JS.Math.abs(x)`, keeps its full
path as its callee (`js_path`, in backend_v.v). A method on a receiver typed by a
binding, `p.promise.then()` on a `JS.Promise`, resolves to the method of that type
when the program declares one, a V wrapper or the binding's own member, with
embedded types followed. Otherwise it is `JS.Promise.then`, which is not linked by
name to some other type's `then` (`same_type_method`, in infer.v). On the vlang
tree unresolved calls go 329 to 309, and external calls 32 to 66. Of the calls that
were resolved and now are host calls, 18 were links to a same-named V function
(`JS.Math.round` to `vlib.math.round`) or to an unrelated type's method
(`JS.Math.ceil` to `wasm.Function.ceil`). The `string` helpers' `s.str.slice` and
`s.str.split` now reach the binding's `String` members, which is where they go. Three JS builtin calls
stay unresolved: `reduce` on `[]int`, whose `array.reduce` is declared in module
`vlib.builtin.js`, which the array fallback does not look in; `push` on the result of
`JS.Array.prototype.constructor()`, which has no type; and `concat` on a `js'...'`
string literal, which is not typed as a JS string.

Function-typed parameters (October 2026). A parameter `h fn () D` of a generic function
takes D from the function its argument names: a function-typed variable, or a function named
as a value. A function named as a value is found by its id: `sha1.new`, recorded as
`g:crypto.sha1.new`, is matched with the vlib prefix an import path leaves out
(`import_names`), and a function of the caller's module is found by its own module
(`fn_value_type`, in generics.v). A method on a field of a generic struct instance,
`m.work.block_size()` on an `m` that is a `Hmac[D]`, names that instance too, through the
field's owner, the prefix of the recipe (`expand_type_param_calls`). On the vlang tree the
hkdf and hmac calls resolve: unresolved calls go from 309 to 297, 18 links are added, and
none is lost. The instances are the ones the extraction can see. `new_digest` in
`prekeyed_hmac` is a local `if` over function values, which has no recipe, so
`Hmac[D].reset` links to sha1's `copy_from` only, not to sha224's or sha256's. Not examined:
the `test_digest_implements_hash` calls in the crypto tests (`free`, `size`), and veb.

Fields of a type parameter, and explicit type arguments (October 2026). A method on a field
of a type parameter, `ctx.req.header.get()` on a `ctx T`, takes that field of each instance of
T: the recipe `t:T | f:req | f:header` is walked from each instance in place of T, in the file
the instance is written in (`path_method_ids`, in generics.v). A generic function called with
explicit type arguments, `decode_gzip[Context]()`, names the instances of its type parameters
in order. The call records them as a site of their own, `ta:` (`type_arg_site`, in
backend_v.v), and each is an instance in the caller's module. An instance's name is written
with its module (`vlib.veb.tests.Context`), and the walk drops the module, since the instance's
own file gives the name its scope (`path_method_ids`). On the vlang tree unresolved calls go
from 297 to 284, 21 links are added, and none is lost.

A tuple from an `if` or `match` (`compressed, ext := match n { ... c, '.zst' }`) gave each
name the first value's recipe with `#i` after it, and that value's `c` is declared inside its
branch, so no name got a type. Now each name takes the first branch's own value for its
position, read after the branch's `:=` names are declared (`tuple_recipes` and `branch_values`,
in backend_v.v). On the vlang tree unresolved calls go from 288 to 283: `bytestr` in
serve_compressed_static and send_compressed_response, `lock` and `unlock` in
channel_select_priv, and `bytes` in parse_memory_limit. The links are the methods of the
types those values have, and no call changes its target.

The nine veb calls left unresolved after that all resolve now (October 2026, #74 to #77).
`trim` and `to_lower` in parse_form_from_request follow a `.map(it.trim_left(' \t'))`, whose
recipe now carries the method called on `it` (`mapit:`), so the array's element type is that
method's return type. The two `clone` calls, in check_duplicate_routes_in_controllers and
run_new, sit under `$if T is ControllerInterface`, which retyped T to the interface and lost
the instance path. The check now keeps both (`ctp:T:X`), and resolve_edges settles it to the
parameter's instances when X is an interface (`comptime_recipe`). The four `app.$(field.name)`
calls in veb/middleware.v are pinned to the field that `$if field.name == 'Middleware'` names
(`comptime_name_pin`), and an argument narrowed by `$if A is I` passes its instance on to the
callee (`comptime_sites`). `set` in the closure of Throttle.acquire reads the instance
`ThrottleContext` in the test file that declares it, not in throttle.v, which can't see it
(`declared_file`). On vlang `4413ab4aaa` 271 calls are unresolved.

**Type references (October 2026).** On vlang `4413ab4aaa` 808 type references were
unresolved, besides the 47,959 to primitives, and most were not ambiguous names. A `C.` or
`JS.` type lost its qualifier: `C.Window` was recorded as `Window` and `JS.Number` as
`Number`, so it was matched by name against V types: it took a V struct `Cursor` for
`C.Cursor` when that was the only `Cursor`, and the 346 references in vlib/js/dom to
`JS.Number`, `JS.String`, `JS.Boolean`, `JS.Any` and `JS.Array` stayed ambiguous among
same-named V types, although vlib/builtin/js declares each one (`pub interface JS.Number`). `type_ref`
(backend_v.v) now keeps the qualifier, and a JS declaration keeps its `JS.` on its signature,
as a C struct keeps `C.`. `resolve_type_ref` (graphify.v) then names only a C or JS
declaration: the nearest one, in the referencing file, its module, a module it can see, then
the program (`nearest_type`, which `c_struct` in infer.v uses too). A bare name is a V type,
so a C or JS declaration is no longer a candidate for it: the bare `Window` in
`sokol/sapp/sapp_linux.c.v` had been ambiguous with `type C.Window`. A C or JS type that
nothing in the program declares is marked undeclared and counted as external
(`host_type_undeclared`). One that is declared in several modules, where the nearest scope
can't pick, stays unresolved, as an ambiguous C binding does: `C.timespec` is declared by os,
sync, time and sokol.sapp. `u128` and `i128`, V3's 128-bit integers, are counted as
primitives.

The 46 references to `string` itself that stayed unresolved had four causes. A type declared
once per platform (`gg.Config` in gg.c.v and gg.js.v) had no site, since only a function or
method got its per-file site back, so its references had no locality to pick builtin's
`string` by. A type now gets one too, and so does an id whose copies are all in one file (a
function in each branch of a top-level `$if` in a test). `import wasm` reached
vlib/builtin/wasm by its last segment as well as vlib/wasm, so the wasm builtin's `string`
competed with builtin's. A bare type name is now the caller's module's, or else builtin's,
before imports are looked at (`type_in_scope`). A global that shares its id with colliding
functions (`__global value` in a test) kept its id but had its edges renamed to an `id@file`
that named nothing. Only a renamed declaration's edges move now (`disambiguate_ids`).

On the same tree unresolved references go from 808 to 104: 635 more resolve, 36 are
external, and 35 more are primitives. No reference changes its target. Eleven lose one:
the ten typed arrays' `every(JS.EveryFn)` in vlib/builtin/js, which name the V alias `EveryFn`
through `JS.` (V3 keeps `C.` and `JS.` names in their own namespace, so they are external
now), and `&SSL` in net/openssl's `openssl_openbsd.c.v`, where only `struct C.SSL` is
declared. Calls are unchanged.

The 104 left come down to 18 (October 2026, same tree):

- An anonymous `struct { ... }` or `union { ... }` is named by V3 after its file and a
  counter that starts again in each file (`register_anonymous_aggregate_type`, in
  vlib/v/parser), so `_VAnonStruct1` was a different struct in each of 21 files, and a
  reference to it named no declaration. The declaration that writes one now references the
  types of its fields instead, nested ones included (`add_type_ref`, in backend_v.v):
  `cli.Command` references `cli.Defaults` and `cli.CommandFlag` through its anonymous
  `defaults` field, which nothing recorded before. 32 references go and 27 are added, 19 of
  them to primitives.
- A named variant, `type Expr = IntLit(int) | Void`, is a struct V3 declares for the sum
  type, `Expr@variant@IntLit { payload int }`. `@` can't be written in a source name
  (`named_variant_marker`, in vlib/v/flat), and elsewhere the variant is written
  `Expr.IntLit`, never by its name alone. The reference kept only `IntLit`, which nothing
  declares, or named another type of that name. `base_name` and `type_text` now read the
  struct's name whole, so the sum type references each variant's struct, and the struct
  references its payload's type. 33 resolve, and 4 that went to a wrong type are corrected:
  `Void` had gone to the alias `type Void = int` beside it, `Ref` to a `type Ref` in another
  program, and `Nil` to the checker's `v.types.Nil`.
- A C struct had the id of a V type of its name, `<module>.name`, so `type Size = C.Size`
  beside `struct C.Size` was one id for two declarations, which a test program couldn't
  address, and the alias referenced itself. Nine ids were shared this way on the tree,
  `vlib.builtin.IError` (the interface and `struct C.IError`) and `vlib.os.stat` (the
  function and `struct C.stat`) among them. A C struct's id is now `<module>.C.name`, as its
  methods' ids already were (`extract_struct`), and `find_type` (infer.v) takes a name
  qualified `C` only for a C declaration, as resolve_type_ref does. The 602 C structs and
  their fields change id, and the 329 edges that went to a shared id now go to the
  declaration they name: 216 references to `IError` go to the interface and 60 calls to
  `os.stat` go to the function. An id whose copies are all of one kind in one file of a
  program, one per branch of a top-level `$if`, is addressable now (`resolve_edges`), which
  also resolves the three `ret()` calls in the comptime_if_top tests: unresolved calls go
  from 271 to 268. 13 references resolve. A generic struct instance in a field of a struct
  whose id is told apart by file took its module from that id up to the last dot, which is
  in the file name (`struct_module`, in generics.v); that changes nothing on the tree.
- A variadic `...JS.Any` left its dots on the qualifier, so it was read as the bare `Any`
  and could go to `json2.Any` (`type_ref`). 7 resolve.
- A `module main` directory with no `fn main` is one program for type references too, as it
  already was for alias conversions, since `v test` builds such a directory together
  (`type_in_scope`): `Country` in vlib/v/tests/generic_calls resolves. With it, 15 `string`
  references in vlib/builtin/js's own `*_test.js.v` files go to the JS builtin's `string`,
  which their module declares, as the module's other files' references already do.

No reference or call loses its target. What remains is 18 references. Ten are C types that
several modules declare and the referencing file can't choose between (`C.timespec`,
`C.timeval`, `C.XEvent`). One is a type declared once per platform in one program
(`ToolCacheEntryDir` in cmd/v). Three name modules that are not in the tree (`js.promise`,
vdoc's `markdown`). One is a bare `SSL` where only `struct C.SSL` is declared, and three are
the checker's unknown-type fixture. A JS binding type still shares the id of a V type of its
name in two places (`vlib.builtin.js.Error`, `vlib.builtin.js.Promise`).

Comptime field selectors (measured October 2026): 11 of the 354 unresolved calls
go through a `$for` field, `x.$(field.name).m()`. Four are on a generic `A` in
`veb/middleware.v`, which resolve now (see the veb paragraph above), and seven are
in vlang's comptime test fixtures. Resolving the rest would give one
call an edge to the method of every field type that declares it. The
one-edge-per-call model does not express that, so they stay unresolved. Still
open: a receiver from a call with a computed argument.

**The rest of the unresolved calls outside tests (October 2026).** Of the 279
unresolved calls on the V tree (614db074f6), 83 were outside test code. Most were a
sum type's value read after a type check the walk didn't follow: a value built in a
branch, `clean := if t is Alias { t.base_type } else { t }`, or in a `match` on it;
a check on a field, `match x.base_type { Alias { x.base_type.base_type } ... }`;
`t !is Struct || t.f()`; and the code after `if t !is Struct { return }`, or in its
`else`. These now narrow as `if t is T { ... }` and `&&` did (`false_checks`,
`value_path`, `always_leaves` in backend_v.v). A recipe also follows:

- a field that every variant of a sum type has, `k.text` of `type Key = Bare | Quoted`
  (one that only some variants have, `str` of `string` in `int | string`, is not the
  sum type's);
- a call of a function-typed field, `p.conn_factory()`;
- a slice of a fixed array, `digest[..]`, as a `[]u8`;
- an element read through a pointer, `b.data[i]`;
- the value of an `rlock` block;
- a branch's own `:=` names when typing the branch's value;
- a struct literal with `...spread`;
- the variable of `$for a in T.attributes` (a `VAttribute`);
- a `@[flag]` enum's `T.zero()`;
- a const in another file of a `main` module that is one program, `cmd/tools/vpm`;
- a generic call's type argument in the caller's module, so `json.decode[[]Envelope](s)`
  in mcp gives mcp's `Envelope`.

Unresolved calls go from 279 to 225, and from 83 to 39 outside tests. Five more are
undeclared (a `@[flag]` enum's `has` and `set`). References are unchanged. In 27
functions a call changes target, each a correction checked against the source: in 23
it now goes to the narrowed type's own method (`Type.source_type_id` to
`Struct.source_type_id`, which V calls on a value narrowed to `Struct`, or
`IError.msg` to `CommandError.msg` after `err is CommandError`), and four had been name
matches (`msg[..n].bytestr()` on a `[4096]u8` had gone to
`http.Response.bytestr`, `c.client.close()` to `websocket.Server.close`). Ten edges
merge with an edge of the same function that now has the same target. Of the 39 left, 26 are calls on a type parameter that no
instance in the tree decides, 6 are in modules outside the tree (vdoc's `markdown`,
the JS prelude's `stats_import`), 3 are JS-only, and 4 are single cases: a const
holding a function, `ctx` in a veb example that never declares it, an untyped
array literal, and json2's `T{}.clear()`.

The raw edge is retained and `explain` reports ambiguous callers rather than
inventing links. A future opt-in deep mode could run the checker over a whole
project, but given the small remainder, it would need to address these
constraints first:

- checker state would make extraction results depend on the whole project;
- per-file cache entries could become stale when another file changes;
- parser worker crash isolation and parallel extraction would no longer be
  independent per file;
- partially broken projects must remain navigable, even when they do not
  typecheck.

Any implementation should preserve unresolved edges, provenance, incremental
cache correctness, and the current performance path. It should be benchmarked
against the parser-only mode rather than silently replacing it.

## 2. Structural `implements` edges

V interfaces are satisfied structurally and have no explicit `impl` declaration
for the parser to extract. Detecting these edges requires matching resolved
methods and fields, including embeds, against visible interfaces with a
whole-program type table.

Graphify currently does not emit `implements` edges. This should remain an
evidence-gated feature: measurements recorded in `README.md` found almost no
project-specific interface relationships across the tested corpora. If the
feature is revisited, first establish a corpus where the additional edges
materially improve navigation, then decide whether an opt-in checker-backed
mode justifies its cost and compiler dependency.

## 3. Language scope remains V-only

The live backend is deliberately V-specific and uses V's own compiler
frontend. The earlier tree-sitter scaffolding was removed because it did not
provide a working second backend.

Supporting another language would require a real backend, language-specific
symbol identity and resolution rules, tests, cache behavior, and an explicit
CLI/MCP contract. Do not reintroduce placeholder language switches without an
implemented backend behind them.

## 4. Graph freshness and source availability

Structural queries work from `graph.json`, but the graph must be refreshed
after source changes. `get_body` additionally needs access to the source
checkout because it reads the captured line range from disk.

**Freshness check (October 2026).** `stale_note` (freshness.v) compares the
manifest's `source_commit` with the checkout's commit and its `binary_hash`
with the graphify CLI that would re-extract it; the CLI prints the note on
stderr and the MCP server puts it at the top of a tool result, rechecking at
most once a minute (one `git rev-parse` and one hash of the CLI). The MCP
server also reloads `graph.json` when an extract replaces it, and
`update-vlang-graph.vsh` rebuilds graphify when its code or the `vlib/v`
directories it compiles in changed. Nothing re-extracts on its own: an automatic refresh would make a
read-only query pay for an extract.

**Source drift check (October 2026).** Each extract writes a text hash of
every source file to `manifest.json` (`source_files`, with CRLF read as LF so a
Windows checkout matches). `get_body` hashes the file it reads and, when that
differs from the extract's hash, puts a note on the header line: the file has
changed since the graph was built, or a `--source-dir` holds different text.
Hashing one file per call is cheap next to the read `get_body` already does.
Over the V compiler's `vlib` (7,845 files) every recorded hash matched the
unchanged tree. A merged graph has no hashes and no check.

Still open: the check covers only the file `get_body` reads. Uncommitted
edits elsewhere aren't reported (they're the normal state of a checkout being
worked on, and hashing every file per query would cost more than the query),
and a query result names symbols from the graph, not their current text.

## 5. Large-graph visualization limits

SVG and HTML exports intentionally cap the rendered view at 300 symbols so
the result remains legible. GraphML and Cypher are the uncapped outputs for
large repositories.

Future visualization work could add user-selected filters, community-focused
exports, or a generated index for navigating very large graphs. It should not
silently render a partial graph: truncation must remain visible to the user.

## 6. Porting the extractor to V3 (done, October 2026)

Done on 7 October 2026: the extractor (`backend_v.v`) reads V3's flat AST,
graphify builds and tests with plain `v`, and the V 0.5.2 extractor and
`-old-compiler` are gone. CI tests on Linux, macOS and Windows and checks
that all three extract the same graph of one vlang commit
(`extract-on-every-os`, `same-graph`). The rest of this section is the
history: why the port was needed, the spike, and how V3's output was matched
to the old extractor's, including where it deliberately differs.

The extractor (`backend_v.v`, since split into
`backend_v_notd_graphify_v3.v` and `backend_common.v`) imports `v.ast`,
`v.parser`, `v.pref`, and `v.token` from V's V1 compiler frontend. Upstream V removed V1 and made V3 the default compiler
(vlang commit `2a7447b5e5`, #28556): `vlib/v/ast` no longer exists, and
`v.parser`, `v.pref`, and `v.token` are now V3 modules with different APIs.

Graphify no longer uses the V 0.5.2 fallback. It builds and tests with plain
`v`, the CI workflow sets no `-old-compiler`, and the V 0.5.2 extractor is
gone. The costs of that fallback no longer apply: a per-machine V 0.5.2
install, the Windows `make v1` recipe, the V 0.5.2 parser's failure on newer
syntax, and the September 2027 deadline by which the port had to land.

The eventual fix is porting the extractor to V3's frontend. V3's parser
produces a flat arena AST (`vlib/v/flat`: `NodeId` indices into a node array,
a single `NodeKind` enum, and node payloads held in a process-global table).
That is an internal compiler representation, not a stable API. Before any port,
establish the following (the feasibility spike below answers all three):

- whether the V3 parser can parse a single file in isolation, as the
  per-file workers, crash isolation, and incremental cache require;
- how declarations, line ranges, and call edges map onto the flat AST, and
  whether existing symbol ids can be preserved or must change under an
  explicit schema version;
- how graphify will track V3's frontend as it changes.

The incremental cache is already keyed on the extractor binary's hash, so a
ported extractor will not reuse cache entries produced by the V1-based one.

### Feasibility spike (October 2026)

Run against vlang `612eda2c73` (7,467 `.v` files), with a fresh V1 extraction
of the same commit as the baseline. Conclusion: a V3 port is feasible, and it
is needed sooner than the fallback deadline, because the V1 extractor is
already losing code.

**Silent truncation in the V1 extractor (since fixed, see below).** When V
0.5.2's parser met syntax it did not know, it stopped and returned what it had
read so far. graphify's parse worker discarded stderr and stored that partial
result, so the file was not counted as unparseable. Compared with V3, 190
files lost functions: about 3,500 of roughly 70,000 (5%), while the update log
reported 3 unparseable files.

- 153 files stop partway; every function V3 finds after that point is missing
  (2,957);
- 26 files yield no functions at all (232);
- 11 files differ in the middle (311).

177 of the 190 fail V 0.5.2's `-check-syntax`. Grouped by the commit that last
touched the failing line: 75 files (1,988 functions) come from vlang
`70ee511b35`, which migrated `os` command strings to argument arrays using the
array spread `[..., ...(expr), ...]`; 102 files (1,431 functions) use V3-only
features with no V1 form (raw and Intel inline-asm blocks, sum types with
named variants, newer generics rules); 13 files (81 functions) have no V1
syntax error and differ for other reasons. The spread has appeared in later
vlang commits too, so the loss grows regardless of the port.

**Fixed (October 2026).** The stopping was graphify's configuration, not a
limit of the parser: in its default `.stdout` output mode V 0.5.2's parser
aborts at the first syntax error, while in `.silent` mode it records the
error, skips the bad token and keeps going, as `v -check-syntax` does.
Extraction now parses in `.silent` mode. On vlang `414f15fb7b` that brought
the functions missing relative to V3 from 3,548 down to 561, with no function
lost and no spurious one added. The remaining 561 sat in 45 files (320 in
`vlib/v/types/checker_ownership_d_ownership.v` alone).

**Per-declaration re-parse (October 2026).** The 320 were not outside a syntax
error, as first written here. That file shadows a local with a loop variable
(`name := ...`, then `for name, typ in m`), which V3 accepts and V 0.5.2
rejects. The parser returns from the middle of the `for` without closing its
scope, so every later method whose receiver is also `tc` fails as a
"redefinition of parameter" and its body is read as garbage at file scope;
only functions with other parameter names survived. Recovery cannot fix that
inside one parse, so a file whose parse reports an error is now parsed again
one top-level declaration at a time (`reparse_by_declaration` in
`backend_v.v`): each declaration behind the file's module and imports, padded
so line numbers stay the file's own, with boundaries taken from scanner tokens
in column 1 so code quoted in a string is never split on. Anything the
whole-file parse found that the per-declaration parses did not is kept too. On
vlang `1b4ecb9c05` this added 394 symbols (295 methods, 74 functions, the rest
types and fields), 298 of them in the ownership file, which now has all 501
of its functions; it lost none, and corrected the line numbers of the few
methods the broken parse had placed at the top of the file. A full extraction
still takes about 3.4 seconds.

Recovery has one side effect: in script-style files (top-level statements, no
`fn main`), skipping a statement can land the parser on an anonymous `fn`
inside a top-level call, which it records as a declaration with no name.
Extraction drops nameless function declarations; on vlang there were 338.

Nameless struct and `type` declarations are not dropped. Each is a real
declaration that V 0.5.2 could not parse and returned empty. On vlang `abcebfc16d` (graph of 7 October) there are 27 such symbols in
25 files, 21 structs and 6 `type` declarations, with an empty name, the id
`<module>.` and, since the parser gives them no position, mostly line 1. By
the first error `-check-syntax` reports for each file: 8 files declare a
single-letter capital name (`pub struct M`), which V 0.5.2 reserves for
generic parameters and which vlang's own tests use; the rest have newer syntax
inside the declaration, such as a generic type alias, sum types with named
variants, or `mut` or an embedded struct in a struct body. In
`vlib/v/tests/single_letter_result/single_letter_result.v` the graph has the
module and the two functions but neither struct `M` nor its field `x`, so the
`!M` and `?M` in the signatures stay unresolved. Within a module the nameless
ids collide and are separated as `<id>@<file>`. The effect is small (27 of
135,723 symbols; 8 of the files are test fixtures for single-letter names) and
is left as is, because the V3 port removes the class.

Two fixes were considered and not made. Dropping them like nameless functions
would remove the noise but gain nothing, since the declaration is already
lost. Reading the name and line from the declaration's first source line in
`reparse_by_declaration` (`pub struct M {`) would put the struct back and let
references to it resolve, but not its fields. Neither was checked for edges
that already point at the nameless ids. One nameless struct, in
`vlib/strconv/format_thousands.v`, was not traced to a declaration: that
file's syntax error is a generic constraint on a function, and the function
itself survives with its parameters and return type missing.

Files whose parse reported an error are listed in the manifest's new `partial`
list (245 on vlang), counted in `graphify extract`'s output, and classified by
`graphify diff` as parsed with syntax errors. They are served from the
current, recovered parse rather than from an older cached copy: an older
copy's line ranges would point `get_body` at the wrong code once anything in
the file moved. Compared with V 0.5.2's own `-check-syntax`, the list agrees
on 212 files; the 33 it lists that the check does not are script-style files,
whose top-level statements the check accepts as a standalone program but which
recover fully here (since parsed in script mode instead, and no longer listed); and the 37 the check flags that are not listed are type
conflicts from `-check-syntax` registering vlib/builtin types twice (33), the
3 files that crash the parser (listed under `failed`), and one call to a
function named `byte` that only parses without the built-in type table.

**Single-file isolation (first question): yes.** `parser.Parser.new(prefs)`
and `parse_file(path)` return a `flat.FlatAst` for one file, from a program
built with plain V (no `-old-compiler`). All 7,467 files parse in one process
in 1.85 s with no crashes. A per-file hash over every node's kind, value,
type, position and child count is identical whether the file is parsed in a
shared process or in its own, for every file but one:
`vlib/v/tests/comptime/comptime_at_test.v`, whose `@BUILD_DATE`, `@BUILD_TIME`
and `@BUILD_TIMESTAMP` are filled from the clock at parse time, so it differs
between isolated runs as well. Batching files per worker process, as today, is
therefore safe. Speed is not an argument either way: V1's full extraction of
the same tree takes 2.4 s with parallel workers.

**Declarations, ranges, calls and ids (second question): yes, with known
work.**

- Every kind graphify extracts has a V3 node kind (`module_decl`,
  `import_decl`, `fn_decl`, `struct_decl`/`field_decl`, `enum_decl`,
  `interface_decl`, `type_decl`, `const_field`, `global_decl`). Extern `fn
  C.foo()` is a separate `c_fn_decl`, so it no longer needs special handling.
- `fn_decl.value` is receiver-qualified for methods (`Point.dist`) and `typ`
  holds the return type. A call's callee is its first child: an `ident`, or a
  `selector` whose own child is the receiver or module. That is the same
  information the V1 extractor records.
- Struct line ranges are correct. `fn_decl` has no end offset (`pos.end` is 0)
  and `enum_decl` spans only its name, so end lines must be derived, for
  example from the last descendant and the closing brace. `get_body` depends
  on this.
- `import_decl.value` is the module path as written and `typ` the alias. V1
  recorded the resolved path (`import json2` became `x.json2`), so matching it
  needs module resolution in graphify (196 imports differ).
- Of 125,665 symbols found by both at the same file and line, 97.8% get
  identical ids from a naive mapping (`<module_id>.<value>`). Nearly all of
  the rest follow three rules: strip the `C.`/`JS.` prefix V3 keeps on C and
  JS declarations (2,236), map V3's static-method form `T@static@f` to V1's
  `T__static__f` (297), and strip V's `@` escape on keyword names (`@type`). A
  few remaining differences are V1 bugs, such as `shared St.g`, where V1 kept
  the receiver modifier in the id.
- On one side only: V1's 1,741 extra imports are compiler-injected pseudo-
  imports (`builtin.closure`, `sync.threads`) placed where a closure or
  `spawn` occurs, not real imports. V3 additionally yields type aliases
  (1,976) and globals (256), kinds the V1 extractor never emitted.

**Tracking V3's frontend (third question).** Depend on the narrowest surface:
`Parser.new`, `parse_file`, the parser's `diagnostics`, and each node's
`kind`, `value`, `typ`, children and byte offsets, computing line numbers from
the source rather than through `token.File`. Pin the vlang commit graphify
builds against, and keep the spike's comparison (V3-derived ids against a V1
extraction of the same commit, grouped by cause) as a check when moving that
pin, for as long as V1 still builds.

**Errors.** V3 also stops at a syntax error, but it records the error in the
parser's `diagnostics` with line and column, so a ported extractor can mark
the file degraded instead of hiding it.

**Running both.** A V1 and a V3 backend cannot share one binary: they need
different compilers, and both define `v.parser`. They can coexist as two
worker binaries behind the existing `_parse-batch` protocol, which would allow
V1 as a per-file fallback and as a cross-check during the transition. That
requires the core module to build without either frontend, under both
compilers.

**The core builds under V3 (checked October 2026).** With `backend_v.v`
replaced by a stub that keeps its public functions (`extract_v_file`,
`extract_v_text` and their `_result` forms, plus the frontend-free helpers
`module_id`, `import_id`, `strip_generic_args`, `is_generic_param`) and
returns no symbols, every other file compiles under plain V3 (vlang
`abcebfc16d`) without a change: `cmd/cli`, `cmd/mcp` and the hook script all
build. Of the 104 tests, the 61 that do not extract source pass; the other 43
fail only because the stub extracts nothing. On the real vlang graph, the
V3-built CLI gives byte-identical output to the V1-built one for `overview`,
`explain`, `query`, `path` and `diff`, and with `-prod` loads and summarizes
the graph in 0.47 s against 0.38 s. So the port is confined to the
extractor: a V3 `backend_v.v` behind the same functions, with the rest of
graphify unchanged. Only `backend_v.v` imports V's frontend (`v.ast`,
`v.parser`, `v.pref`, `v.token`, `v.scanner`).

On macOS 27, build V with `-cc cc` for this: a V compiler linked by the
bundled TCC can start with garbage in its zero-initialized globals and panic
or hang on any program (vlang/v#29744; TCC's Mach-O writer).

### The V3 extractor (October 2026)

Until the switch, the V3 extractor lived in `backend_v3_d_graphify_v3.v`,
built in place of the V 0.5.2 one with plain V and `-d graphify_v3`, while
the default build still used `-old-compiler`.
The test suite passes against both, with the tests of V 0.5.2's own syntax
errors and pseudo-imports returning early under `-d graphify_v3` and the
tests of a file-level `$if` expecting every branch there.

It parses with `preserve_comptime_conditionals`, so every branch of a `$if`
is kept, at file scope and in function bodies: the host dependence of §8 goes
away, and a call inside `$if debug {}` is still a call. On vlang `abcebfc16d`,
against the V 0.5.2 extractor on the same tree:

| | V 0.5.2 | V3 |
|---|---|---|
| symbols | 135,746 | 136,165 |
| calls resolved / total | 209,831 / 243,794 | 214,703 / 248,638 |
| type references resolved / total | 80,442 / 117,066 | 82,273 / 120,023 |
| embeds resolved / total | 668 / 678 | 668 / 678 |
| files flagged with syntax errors | 220 (+3 unparseable) | 5 |
| full extraction | 2.90 s | 2.14 s |

The symbols only V 0.5.2 has are its pseudo-imports (`builtin.closure`,
2,042), nameless declarations from its parse failures, and generic receivers
it spelled `Arc<T>` where every other id uses `Arc[T]`. The ones only V3 has
are other platforms' declarations, the three files V 0.5.2 could not parse,
and declarations V 0.5.2 lost to syntax it did not know. The 5 flagged
files are in `x/multiwindow` (methods defined in more than one `$if` branch,
which keeping every branch makes duplicates) and two test fixtures. Inline
assembly for another architecture parses fine but is reported as unsupported
by the backend unless `prefs.supports_inline_asm` is set, which the extractor
does, so the flagged list doesn't depend on the host.

Under V3, `import graphify` in `cmd/` in a worktree under `.claude/worktrees/`
resolved to the main checkout's files, not the worktree's; `graphify/alias.v`
fixed that (§9).

Imports are resolved (`resolve_import` in backend_common.v, October 2026): V3
records the path as written, so `import helper` in `vlib/v/tests/x` was just
`helper`, ambiguous among the many test modules of that name. The lookup
follows V3's order (the nearest v.mod's root, the importing file's
directory, `vlib`, then ancestors) but only inside the extracted tree, so it
stays host-independent, and names the module below `vlib` (`v.tests.helper`,
`os`) or below the tree's root (`cmd.tools.vpm.test_utils`). It corrects
V 0.5.2's nearest-first walk, which took `import rand` in `vlib/crypto/...`
for `crypto.rand` and `import json2` for `x.json2`. On vlang: 23 fewer
unresolved calls and 7 fewer unresolved type references; extraction 0.4 s
slower (2.8 s). The Mac and Windows graphs were still identical after it.

Signatures are written as V 0.5.2 wrote them (October 2026): each module
qualifier in a type, wherever it sits, becomes the module's resolved path
(`[]flat.NodeId` -> `[]v.flat.NodeId`), a type from a selective import is
qualified the same way, and a function type is `fn (...)`. On vlang the
signatures that differ fell from 10,312 to 1,036, and those are almost all
V 0.5.2's errors, which V3 doesn't copy: 362 function-type aliases it wrote
as `type X = X`, 225 variadics without their `...`, 41 generics in the old
`<T>` spelling, signatures missing their return type or parameters, `mut x
&T` written as `&&T`, and module qualifiers it left as written (`color.RGBA64`
for `image.color.RGBA64`) or named by its own import resolution. Fixed-array
sizes differ in 27, because each parser substitutes some constants
(`[node_payload_max_chunks]` is `[4096]` in V3) and neither matches the
source exactly; and 7 module symbols show the declared module name where
V 0.5.2 showed the directory's.

Line numbers follow V 0.5.2's (October 2026): a function's `end_line` is the
last line of its header, the line of the `{` that opens its body, and a
script's `main` spans its first statement to the end of its last (V 0.5.2
said line 1 to line 1). Of 479 symbols whose lines still differ on vlang,
the rest are V 0.5.2's errors or deliberate: its end lines run past a
generic header, a `&[]T` return type or a body-less declaration into the
next one; a module's line is the `module` keyword's where V 0.5.2 gave the
attribute above it (159 files start with an attribute); a declaration
repeated in several `$if` branches is listed at the first, since V3 keeps
them all; and a struct field's end line covers a default value spanning
several lines.

Imports V's parser implies (October 2026) are recorded by both extractors as
import symbols signed `import m (implied)`: `builtin.closure` for an
anonymous function, `sync.threads` for `spawn` or a `thread` type, `sync` for
channels, `<-`, `shared`, `lock` and `select`, `math` for `**`, and the
`embed_file` and `debug` preludes. V 0.5.2's come from its parser's
`auto_imports`; V3's from the same syntax in the flat AST
(`extract_implied_imports`). On vlang V3 finds 1,235 to V 0.5.2's 1,829: it
doesn't count an `it` expression such as `a.map(it * 2)` as a closure (602),
which compiles inline, nor a variable named `shared` (5), and it adds 13 in
code V 0.5.2 didn't see. The resolver ignores implied imports for
visibility, since a file can't name anything through one; counting them had
left 160 calls such as `ch.close()` unresolved in V 0.5.2's graph.

Mapping notes, for whoever moves this forward: methods are `fn_decl`s whose
value is `Recv.name` with the receiver as the first `param`; a static method
is `T@static@f` (graphify's `T__static__f`); a body-less V declaration in a
`.c.v` file is a `c_fn_decl` like `fn C.puts`, with the `C.` dropped, so only
the source line tells them apart; an embedded struct is a `field_decl` named
by its type as written; V3 records no visibility, so `pub` is read from the
source line and a field's from the nearest access label; an error diagnostic
has an empty severity.

It became the default on 7 October 2026, once its tests passed on all three
OSes in CI and the remaining differences from the V 0.5.2 extractor were
either fixed or recorded above as that extractor's errors.

Mac and Windows graphs of vlang `abcebfc16d` were compared in October 2026:
same 136,165 symbols, 3 edges apart. Each difference depended on the host and
is fixed for both extractors where it applied: directories are walked in
sorted order (the first of two same-id declarations wins, and `os.ls` order
differs between APFS and NTFS: 1,734 symbols took another file's line or
signature), the graph is assembled in file order whatever the cache held,
V3's anonymous struct names (which embed the absolute path) become
`_VAnonStructN`, inline assembly for another architecture isn't flagged, and
`@[if cond]` guards are blanked before V3 parses, since it drops a guarded
body when the condition is false on the host (79 calls on vlang). The rerun
then matched in every edge and all but one symbol: a `const` inside a
file-scope `$match @OS`, which V3 resolves for the host even with every `$if`
kept. The extractor now writes `$match @X` as `$match mut @X`, which makes
the parser build the `$if` chain and keep every branch (3 consts on vlang).
V 0.5.2's extractor records nothing declared inside a file-scope `$match`.

The spike's probe programs were not kept; the method above is enough to repeat
it.

## 7. Publishing, degraded extractions, and manifest detail

A full three-way reconciliation between a common-base graph, another
branch's overlay, and the graph rebuilt from a merged commit is not needed.
Git already reconciles the *source*; the graph is derived only from current
source plus the extractor, so anything another branch contributed that
survived the merge is already reachable from current source, and anything
that did not survive is correctly excluded by the rule that the graph must
not retain symbols whose source is gone. The one real gap — a file that
fails to extract on the current commit — is already covered by the
incremental cache's own prior result for that file, not by another branch's
graph.

**Done (commit `22023d8`).** The three narrower gaps this section identified,
plus the audit command, are all implemented:

- **`graph.json` publishes atomically.** `save_graph` writes to a temp file
  and publishes it with `atomic_replace`. Windows needed real attention:
  `os.rename` FAILS outright there when the destination already exists
  (verified against the actual Windows C runtime), so Windows publishes via
  `MoveFileExW`/`MOVEFILE_REPLACE_EXISTING`, a genuine single-operation
  replace — `os.mv`'s fallback (copy then delete the source) would have
  reintroduced the exact torn-read window this exists to avoid.
- **A file that fails to parse now falls back to its last successful
  extraction, marked stale**, instead of silently vanishing from the graph.
  `CacheEntry` gained a `stale` flag; `stale_fallback_for`/`fresh_reuse_of`
  in `graphify.v` decide when to serve it and when to clear it (a hash match
  against current content directly reverifies the file, clearing `stale`
  even if it was previously carried forward). Both places in
  `build_graph_resilient` that used to drop a file's symbols outright — a
  crashed worker, and a listfile write failure — use this now.
- **`manifest.json` records `binary_hash`, a best-effort `source_commit`,
  and `failed`/`stale` file lists**, via a new `ExtractReport` threaded from
  `build_graph_resilient` through `write_bundle`.
- **`graphify diff <old.json> <new.json>`** lists symbols in `old` missing
  from `new`, grouped by file, classified from `new`'s manifest as
  parse-failed / stale / file-removed / symbol-specifically-missing — this
  is the audit trail, and it does cover losses beyond a merge, such as a
  walker or skip-list change.

The stale-carry-forward *wiring* inside `build_graph_resilient` is tested
through a real child process that dies partway through its batch. The test
passes a stand-in worker as `worker_exe`, a small V program the test compiles
with `@VEXE`. It copies each file's canned worker line to the output and panics
on `crash.v`, so the extract's own spawn, harvest and recovery run unchanged,
on every platform. It checks three things: a crashed file carries its last
extract forward marked stale, a file queued behind the crash is parsed in the
next wave, and a file that crashes on its first sighting has no symbols and is
not stale. Breaking the carry-forward makes the test fail.

## 8. Extraction depends on the build host's OS and architecture

Resolved in October 2026 by the V3 extractor, which keeps every branch of a
platform conditional (`extract_v3` sets `preserve_comptime_conditionals`; see
the end of this section); CI checks that the Mac, Windows and Linux graphs
match. The "Consequences" and "Options" below are from the V 0.5.2 extractor,
since removed, and no longer apply.

The same vlang commit can extract to different graphs on different hosts.
Compared on vlang `1b4ecb9c05` (October 2026), an arm64 Mac against an x86_64
Windows machine, after symbol ids were made independent of the working
directory (`5170207`) and extraction began recovering past syntax errors
(`b2f253b`): of 132,735 symbols found on both, none differ in id. What remains
is 3 import symbols and 11 call edges, all inside `$if darwin` or
`$if windows` blocks, plus one file, `vlib/net/http/util.v`, that only the Mac
reports as having a syntax error, in its Windows-only branch.

An earlier comparison (vlang `d2a18d9`, September 2026: 108,812 versus 108,848
symbols) attributed most of its gap, 37 more symbols on x86_64 in five
inline-assembly tests (`vlib/v/slow_tests/assembly/*.amd64.v` and `*.i386.v`),
to the CPU architecture. That was mistaken. V 0.5.2 cannot parse those tests'
asm syntax on either host, and before `b2f253b` each host's parser stopped at
its first error, at different points. With recovery both hosts read all 16
such files in full and extract the same symbols from them. The architecture
played no part beyond where the parser happened to stop.

Host dependence now comes only from platform conditionals. Extraction parses
with preferences from `pref.new_preferences()` (`extract_prefs` in
`backend_v.v`), which default the target OS and architecture to the host's,
and the V1 parser evaluates conditionals against them at parse time: a
top-level `$if` whose condition is false for the target is skipped
(`comptime_skip_curr_stmts` and `skip_scope()` in V 0.5.2's
`vlib/v/parser/if_match.v`). That holds for architecture conditions such as
`$if amd64` as well as for OS conditions.

Graphify's own extractor used not to descend into top-level `$if` blocks, so
a declaration inside one was missing on every host, not only on the platforms
where the condition is false. (Imports were unaffected: the parser collects
those itself.) Fixed in October 2026: `top_level_decls` in `backend_v.v`
flattens the branch the parser kept into the file's top-level statements. On
vlang `414f15fb7b` that added 180 symbols in 25 files (functions, methods,
constants, structs, enums and fields; an earlier count of 16 covered functions
only) and lost none. One id changed form: three test files each declare `ret`
inside a top-level `$if`, so it is now split per file by the usual collision
disambiguation. The fix makes the platform difference below somewhat larger,
since declarations in a taken branch now appear on the hosts that take it
instead of on none.

Consequences:

- graphs in a store shared between machines differ by platform, even after
  symbol ids were made independent of the working directory (`5170207`);
- `graphify diff` across two machines' graphs reports symbols as missing that
  are only another platform's code;
- the difference is small for vlang today (3 symbols and 11 edges between the
  Mac and Windows), but grows with the amount of platform-specific code in a
  project.

Options:

- pin the target OS and architecture in the parser preferences, so every host
  extracts one canonical view. This would be deterministic but omit code that
  only exists for other platforms, and it is not known to work in V1 (see
  below);
- extract every branch of each platform conditional. V3 supports this
  (`preserve_comptime_conditionals`, measured below). V1 does not: see the
  experiment below.

**V1 has no usable keep-all-branches mode (checked October 2026, vlang
`414f15fb7b`).** V 0.5.2's parser skips false top-level `$if` branches unless
`is_fmt` (set for `vfmt`) or `output_cross_c` (`-os cross`) is set, so both
were tried as extraction preferences, against V3 as ground truth: V3 in
preserve mode finds 2,254 symbols that its default mode does not, the code
other platforms see, and today's graph has none of them. Formatter mode
captured 48 of the 2,254, lost 62 real symbols (44 of them functions) and
added 22 that V3 does not find; cross mode captured the same 48, lost 101
(mostly struct fields) and added 8. Both only pick up some platform-gated
imports, and both change parsing elsewhere.

Overriding the target OS in V1's preferences also does not behave like a
different host. In a fixture with `$if windows { import winonly }` and
`$if macos { import maconly }`, the Mac with the target OS set to `windows`
still resolved to `maconly`, and combined with formatter mode it lost
`winonly` again. This was observed, not root-caused. It means cross-host
behavior can only be verified on a real second host, and that pinning the
preferences would need such a check before being relied on.

Host independence therefore belongs to the V3 port (§6) rather than to the V1
path.

**The V3 extractor is host-independent (verified October 2026, vlang
`abcebfc16d`).** Built with `-d graphify_v3` and extracted on the arm64 Mac
and the x86_64 Windows machine, the two graphs have the same 136,168 symbols
and 498,034 edges, field for field, and the same 5 flagged files; only
`root`, the binary hash and the timestamp differ. Getting there took the
fixes listed in §6: every `$if` and `$match` branch kept, `@[if]` guards
blanked, inline assembly for another architecture not flagged, anonymous
struct names without the path, and files walked and assembled in sorted
order. The last also applies to the V1 extractor, whose graphs still differ
by platform conditionals as described above.

**V3 resolves this (October 2026, §6).** V3's parser has a
`preserve_comptime_conditionals` preference, and `extract_v3` sets it. Every
platform branch is kept, inside `comptime_if` nodes that carry the condition
text (`windows`, `macos`), so the graph does not depend on the host, and
Linux-only code is in it: the vlang extract has 1,667 symbols in `*_linux*`
files. The graph does not record which platform a declaration belongs to.

The effect is larger than the Mac/Windows comparison suggests. On the Mac,
V3's default mode hides 892 functions, 205 structs, 863 fields and 19,030
calls in vlang compared with preserve mode, mostly Linux-only code (X11,
Wayland, `sapp_wayland_linux.v`). Today's V1 graph matches V3's default mode
on those files. Linux-only code is therefore missing from graphs built on both
the Mac and Windows, and can never show up in a comparison between the two.
Preserve mode parsed all 7,467 files without crashing, and no file had fewer
functions than in default mode.

With every branch kept, V3 reports a method declared once per branch as a
duplicate method: `$if darwin { fn (b B) f() } $else { fn (b B) f() }`, or under
`$if d3d ? {}` and `$if !d3d ? {}`. Both copies are read and calls to them
resolve, but the file was listed as `partial`. `extract_v3` now passes over
that error when each copy is in another branch of a condition than the rest
(`method_branches`), and reports it as before when two copies can be compiled
together. On vlang (adea615a6b) the three `vlib/x/multiwindow` files it flagged
leave the `partial` list, and `graph.json` is unchanged byte for byte. A file of
nothing but comments, `vlib/v/slow_tests/acommentedmodule/commentedfile.v`, gives V3
no file node and no error; it declares nothing and V builds it, so it is no longer
`partial` either (`only_comments`). What remains is the checker fixture whose error is
its point, `module_alias_started_with_underscore`.

**The declaration shown is the host's (October 2026).** A function declared once per
platform, as `os.ls` is in os_nix.c.v and os_windows.c.v, is one id, and the index shows
one of its declarations (`shown_before`). Between files of one backend that was the later
in the graph, so on macOS `get_node`, `get_body` and a call's location went to
os_windows.c.v. A file that this host compiles now comes first, then a `_default` one,
which V compiles only when the OS has no file of its own, then one for another OS or
architecture, as V itself decides (`pref.file_has_incompatible_target_suffix`, in
`host_rank`). This is the index's choice, made when a graph is read, so graph.json is
unchanged and stays the same on every host. On the V compiler's tree, on macOS, 612 of
the 3,789 shared ids are shown from another file, 592 of them from one macOS doesn't
compile; 84 are still shown from such a file, having no copy for macOS.

## 9. Building inside a git worktree compiles the main checkout (fixed, October 2026)

`cmd/cli`, `cmd/mcp`, and `cmd/hooks/graphify_hook.vsh` all `import graphify`.
V3 looks for an imported module beside the importing file, then at the
project root (the nearest `v.mod`), then in vlib and `~/.vmodules`, and last
in each directory above the importer (`resolve_ancestor_module_path` in
`vlib/v/driver/driver.v`). graphify's sources are the project root itself,
not a `graphify/` directory in it, so only that last walk found them, and it
took the first directory named `graphify` above the program. Claude Code
worktrees live at `.claude/worktrees/<name>/`, so from a worktree that was
the main checkout: every binary built there silently contained the main
checkout's code. A checkout in a directory with any other name, and no
`graphify` above it, didn't build at all.

`graphify/alias.v` makes the project root resolve to itself:

```v ignore
@[alias: '@VMODROOT']
module graphify
```

V checks for a module alias at the project root before vlib or the walk up, and
`@VMODROOT` is the checkout holding `alias.v`, so `import graphify` now
means the checkout being built, whatever its directory is called. CI builds
a copy of the checkout from inside the main one, the worktree layout, and
fails if any graphify source comes from outside it. `v -print-v-files
cmd/cli` shows which sources a build uses.

Still true: `v test .` from the main checkout also descends into
`.claude/worktrees/` and runs every worktree's copy of the tests, each against
whatever commit that worktree has checked out. Since `77742d7` and `e48a80c`
those copies no longer race on shared temp directories, but their results
describe stale code; the main checkout's own result is the line for
`graphify_test.v` at the root. (With V 0.5.2, `v test graphify_test.v`
tested just that file; V3 compiles a file given that way on its own, without
the rest of the module, so it fails.)

## 10. Calls into vlib and ~/.vmodules from a project outside the V tree (done, October 2026)

A project is extracted on its own, so the modules it imports from vlib and
`~/.vmodules` are not in its tree, and nothing they declare can be resolved to.
Measured October 2026 with the current extractor:

| Project | Files | Unresolved calls | Unresolved type references |
|---|---|---|---|
| `~/.vmodules/gui` | 343 | 2,201 of 11,990 (18%) | 1,377 |
| vebidor | 95 | 850 of 2,273 (37%) | 397 |
| vglyph | 68 | 508 of 1,689 (30%) | 176 |
| vxui | 53 | 611 of 1,433 (43%) | 416 |
| graphify | 27 | 936 of 2,546 (37%) | 360 |

On the V tree itself it is 268 of 304,579 (0.09%). The top unresolved callees in gui
are `panic`, `contains`, `trim_space`, `msg`, `error`, `starts_with`, `os.join_path`
and `time.now`, and `string` itself is an unresolved type reference 1,159 times:
builtin declares it as a struct, and builtin is not in the tree. Each miss also
breaks the receiver inference after it (`x.trim_space().split(',')`).

The upper bound, measured by extracting a tree that holds the project and all of
vlib (and vglyph for gui): gui's unresolved calls go from 2,201 to 12, 2,468 calls
resolve into the library, and no type reference stays unresolved; graphify's go
from 936 to 27, most of the 27 an artifact of that tree's layout.

### Design

**Which declarations.** The modules a project imports that are not in its tree,
looked up as V3 does after the project: `$VROOT/vlib/<path>`, then
`$VMODULES/<path>` (`~/.vmodules` by default), followed through each loaded
module's own imports, plus builtin, which every file imports. A module is the
`.v` files directly in its directory, without `_test.v` files; every platform
file is read, as for the project. VROOT is the `VROOT` environment variable, or
the directory of the `v` on PATH when it holds `vlib/builtin`. Nothing is loaded
for a module that the project's tree has, so extracting the V tree itself loads
nothing. For gui that is 92 vlib module directories and 879 files, for graphify
35 and 448; a cold extract of the whole V tree takes about 6 s, so the closure
costs well under a second, and it is cached like the project's files.

**How they get into resolution.** Library files are parsed by the same workers
and cache as the project's, before `disambiguate_ids` and `resolve_edges`. Their
symbols and their `embeds` and `references` edges join the project's for
resolution, so `resolve_edges` and infer.v see their declarations, return types,
fields and embeds. Their `calls` edges are dropped: calls inside the library are
not the project's. `resolve_import` gains the same two lookups after the
project's, so a project's `import x.json2` is `json2` (vlib/x/json2 is an alias
directory) as it is inside the V tree; the library roots are part of the cache
envelope, since an import's name now depends on them.

**How ids line up.** A vlib file is extracted with VROOT as its root, so its rel
is `vlib/os/os.v` and its ids are `vlib.os.join_path`, `vlib.builtin.string`,
exactly as in the V tree's own graph. Imports already name vlib modules without
the prefix (`os`), and `import_names` and `import_reaches` already match
`vlib.os` to it. A `~/.vmodules` file gets the rel `vmodules/vglyph/x.v`, so its
ids are `vmodules.vglyph.Foo`, and `import_names` matches `vmodules.` as it
matches `vlib.`. The prefix keeps a library module apart from a project module of
the same name (`ui` in the project and `~/.vmodules/ui`).

**What goes into graph.json.** After resolution only the library declarations
the project's edges reach are kept, with their parents (a method's struct, a
module), in a separate `library` section: `{"roots": {"vlib": VROOT,
"vmodules": VMODULES}, "symbols": [...]}`. They are not in `symbols`. Measured:
431 for gui (10,257 project symbols) and 140 for graphify (926). Edges keep the
library ids as their `to`. Old readers skip the unknown key. The alternatives
were worse: putting library symbols in `symbols` makes `string`, `contains` and
`panic` the top hubs of `query`, `path`, the report, communities and the SVG
layout, lets `Index.resolve`'s unique-name fallback hijack or drop project
edges, churns `diff` as the project's stdlib use changes, and makes the hook
match `vlib/os/os.v` against project files; keeping only ids, with no
declarations, leaves `explain` and `get_body` nothing to show; and putting the
library under `roots` turns off the drift check and confuses `merge-graphs`.

**Consumers.** The index keeps library declarations apart (`lib_by_id`): they
label edges in `explain` and answer `get_body` (read from the library's root),
but never join traversal (`query`, `path`, neighbours), ranking (most connected,
communities, SVG and HTML) or name resolution, and `diff`, the skeleton and the
hook see only project symbols, as before. The report counts an edge into the
library as `library`, apart from `extracted` and `inferred`, so `unresolved`
stays an honest count of what the project's own names leave open. The manifest
records each library root with its commit (`git rev-parse` in VROOT) so a stale
note can say the library moved.

**Switch.** On by default when a VROOT is found; `graphify extract --no-library`
turns it off, and so does an empty `VROOT`. The in-process `build_graph` that the
tests and `skeleton` use stays without a library.

**Risks.** The `v` on PATH may not be the V the project builds with. A function
declared once per platform in vlib resolves to the shared id, as it does inside
the V tree. `get_body` on a library declaration reads the file the library has
now.

### What was built, and measured

As designed above (`library.v`, `build_graph_with_library`, `keep_reached_library`
in graphify.v), with these details found on the way:

- An id can be both the project's and the library's: a `fn C.name` binding both
  declare is `C.name` for each. The library's edges are therefore told apart by
  the file they were made in, not by their `from`, and such an id stays the
  project's. Copies of a library id, one per platform, are kept once, the one the
  index shows (`shown_before`).
- A function's `end_line` is the end of its header, and get_body finds the end of
  a body from the next declaration of its file, which the library section keeps
  only some of. A kept library declaration's `end_line` is set to the last line
  of its body at extraction, from all the declarations of its file
  (`with_body_ends`, `decl_end`).
- `~/.vmodules/vebidor` is a link to the vebidor checkout, so `import
  vebidor.webdriver` in vebidor's own examples was its own module, read again as
  a library, and its calls went to that copy. A VMODULES module whose real path is
  inside the tree is named by its path in the tree (`resolve_import`), and is
  never read as a library.
- A call in a field's default value, `bg Color = rgba(0, 0, 0, 50)`, was placed
  by module only through its struct: a field's site took the struct as its
  module. With `rgba` declared by gui and by vlib's gg and gx, that left it
  unresolved. A field's site is its struct's module now (`decl_mod`). It changes
  nothing on the V tree.

Measured with each project extracted on its own, against the extractor before
this change (vlang adea615a6b as VROOT):

| Project | Unresolved calls | Into the library | Library declarations kept | Cold extract |
|---|---|---|---|---|
| `~/.vmodules/gui` | 2,201 → 6 | 2,468 | 429 | 0.7 s |
| vebidor | 850 → 0 | 824 | 131 | 0.3 s |
| vglyph | 508 → 0 | 537 | 116 | 0.4 s |
| vxui | 611 → 7 | 707 | 164 | 0.3 s |
| vpm | 145 → 2 | 175 | 114 | 0.3 s |
| graphify | 970 → 2 | 1,311 | 144 | 0.3 s |

Unresolved type references go to 0 in each. No project edge loses its
target. The edges that change target were name matches to a project declaration
of the same name, checked by sample in each project: `s.split(...)` had gone to
gui's own `split`, `m.lock()` on a `sync.Mutex` to `gui.Window.lock`, `x.str()`
on a `json2.Any` to vebidor's only `str` (54 calls) and vxui's (44), `err.msg()`
to `VxuiErrorDetail.msg`, and `text_width` to gui's own where vglyph's is called.
The V tree's graph is the same byte for byte with the library on, off, and
before the change, since it imports nothing from outside itself.

Still open:

- `merge-graphs` keeps no library: the merged graph's edges into one name ids it
  doesn't have, so they count as unresolved there.
- A library file's syntax errors and crashes are not reported, and a library is
  re-read from the project's own cache, so two projects read vlib twice.
- The `v` on PATH decides which vlib is read. A graph's library section names the
  roots, and the stale note says when VROOT's commit moved, but not when a
  project builds with another V.
- A call inside a library generic function that an instance from the project
  makes (`arrays.map[T]` calling `T.str()`) is not recorded.

## 11. A project's graph layered on the V tree's

A project's graph (§10) holds the vlib declarations its calls reach, but not what they
call in turn, so a problem that goes deeper into vlib had to be followed in a second
graph by hand. A bug found in gui usually ends in gg, sokol or builtin.

### Design

**The join.** A project's library ids are the V tree's own (`vlib.gg.Context.draw_text`
in both), so the two graphs join without renaming anything. `layer_graph` (layer.v)
puts the project's symbols first, then each V tree symbol declared in a `vlib/` file
whose id the project doesn't have; the project's edges, then the V tree's edges from
those symbols, resolved by the V tree's own index first, so a raw name is resolved
among the V tree's declarations, not the project's. The project's library section
keeps only what the V tree doesn't stand in for: modules from VMODULES
(`vmodules.vglyph...`), and a vlib id the V tree's graph doesn't have. The V tree's
`cmd/`, `examples/` and tests stay out: a project calls vlib, nothing else.

**The project comes first.** Ids from the V tree are marked (`Graph.base`). An edge's
raw name is still resolved among the project's declarations only, as before, so a
name that is unique in the project stays linked although vlib has one too. A search
(`query`) seeds from the project's matches, and from the V tree's only when the
project has none; a name names the project's declaration before the V tree's. The
overview is the project's own report, with a line saying what it is layered on.
explain and the path tools treat both alike, which is what crossing the boundary
needs, and mark a V tree symbol `[library]`, as a library declaration was.

**Bodies and freshness.** A V tree symbol's body is read from the V tree's root, and
its drift check uses the V tree's file hashes. Each graph keeps its own manifest, so
the stale note is the project's and the V tree's, joined. The join is exact only when
the project read vlib from the checkout the V tree's graph is of, at the same commit:
the project's manifest names the library root and commit it read (§10), and the
note says when they differ from the V tree graph's root and `source_commit`.

**Which project.** The MCP server takes the V tree's graph as before and, with
`--projects <dir>`, a directory of project graphs (`<store>/<name>/graph.json`, as
`extract --store` writes them). It serves the project whose root holds its working
directory, the deepest such root, so a session in a worktree inside the project gets
the project's graph too; elsewhere, or in the V tree itself, it serves the V tree's
graph alone. A replaced graph.json of either is reloaded, as one was before.

**Extracting projects.** `graphify.config.json` gains `projects`, the roots to
extract. The update script extracts each project after the V tree when the project's
commit differs from its graph's `source_commit`, when graphify was rebuilt, when the
V tree moved, or when it has no graph yet. It doesn't pull a project: they are the
user's own checkouts.

### What was built, and measured

As designed (layer.v, `--projects` in cmd/mcp, `projects` in update-vlang-graph.vsh).
vlib's tests stay out with the rest of the tree's tests: a `_test.v` file, a platform's
`_test.c.v`, and the `tests`, `slow_tests`, `compiler_tests` and `testdata`
directories. Before that, gg's module symbol was shown from
`wayland_pipe_abi_test.c.v`.

Measured on gui and vebidor, each extracted against the vlang checkout its graph is of
(1e63d0f20e):

| Project | vlib declarations its calls reach | Missing from the vlang graph | Edges into them | vlib symbols layered under it |
|---|---|---|---|---|
| `~/.vmodules/gui` | 388 (and 41 from VMODULES, kept as library) | 0 | 3,845 | 69,888 |
| vebidor | 131 | 0 | 1,187 | 69,888 |

From inside gui, `shortest_path` from `gui.draw_rounded_image_batch` to
`vlib.sokol.sgl.v2f` is one query, and `get_node` on `vlib.gg.Context.draw_image` lists
its gui callers at their gui locations next to its own calls in gg. Loading and answering
three tools takes 1.4 s and 1.5 GB at most, against 1.6 s and 1.8 GB for the vlang graph
served alone, whose index holds all 163,000 symbols, not vlib's 70,000.

Still open:

- ~~A project's modules from VMODULES are layered only as the library declarations
  its calls reach.~~ Done, see below.
- ~~A worktree inside a project gets the graph of the project's checkout, as a
  worktree of vlang gets vlang's.~~ Done, see below.
- Each session's server holds its own copy of the vlang graph, as one did before.

**The index is built once (October 2026).** Each tool call built the whole index
again, and some twice: on the V tree that was about 0.4 s a call, and the garbage
it left raised the server's peak memory with every call. The server now keeps the
index of the graph it serves (`cache_index`), rebuilt when a graph.json is replaced.
Loading the vlang graph and answering ten typical calls went from 4.6 s and 2.75 GB
to 0.8 s and 1.0 GB (gui layered: 2.7 s and 1.75 GB to 1.0 s and 1.25 GB), with the
same answers byte for byte. A module, whose symbol each of its files declares, is
shown from one of its own files rather than the last one read, which was often a
test (`vlib.gg` from `wayland_pipe_abi_test.c.v`): `shown_before` puts a non-test
file first.

**Modules from VMODULES, whole (October 2026).** A module the project imports from
VMODULES was kept only as the declarations the project reaches, so a traversal from
gui stopped at vglyph as it had stopped at vlib. It is now kept whole when the project
is extracted, with its own edges, calls included, resolved as the project's are
(`keep_reached_library`); the MCP server layers it under the project with vlib
(`layer_graph`). This is the module the project builds against, at the version
installed, with the library's ids, so it needs no graph of its own: a clone being
worked on, `~/repo/vglyph`, has its own project graph. vlib is still pruned to what is
reached, and the V tree's graph stands in for the rest. The project's report counts
its own edges only.

Kept whole, vglyph showed that a VMODULES module's own submodule wasn't read:
`import accessibility` in vglyph names `vglyph/accessibility`, which V finds beside the
module's v.mod, but the library looked only in vlib and at the top of VMODULES, so
`ts.am.commit()` on an `accessibility.AccessibilityManager` resolved by locality to
`TextSystem.commit` itself. Such an import is now resolved beside the importing
module's v.mod first (`vmodules_own_import`, in library.v). A test fixture whose
VMODULES directory was named `vmodules`, as the rels are, had hidden it: the files'
paths ended in their rels, so they were taken for the tree's.

On gui, the only one of the five projects that imports from VMODULES: the library
goes from 429 to 1,680 declarations (vglyph and `vglyph.accessibility` whole), with
3,557 edges of vglyph's own, none of them unresolved calls (6 before the submodule
was read); graph.json from 5.1 MB to 5.8 MB. gui's own edges are unchanged. One
`shortest_path` goes from `gui.renderers_draw` through `vglyph.TextSystem.commit` to
`vglyph.accessibility.AccessibilityManager.commit`, or through
`vglyph.Renderer.commit` to `vlib.gg.Image.update_pixel_data`.

**A worktree's own graph (October 2026).** A session in a git worktree got the graph of
the checkout, so what its branch had added or changed was missing or out of date, in
the code being worked on. The MCP server now finds the worktree it starts in
(`worktree_graph`, in worktree.v): one of a project in the store or of the V tree,
told by its repository (`git rev-parse --git-common-dir`), inside the checkout or
beside it, with the project's root at its place in the worktree for a project in a
directory of its repository. It extracts the worktree with the CLI beside it into a
store of its own (`worktree_store`, under the user's cache directory), seeded with
the checkout's `.gf_cache.ndjson`, which is keyed by each file's text, so only the
files the branch changed are parsed, and serves that graph, layered as the project's
is, in place of the checkout's. The extract runs in a thread of its own; the
checkout's graph is served, with a note, until it is there. The worktree's commit
and the size and time of each V file git reports as changed (`worktree_state`) are
looked at on a tool call at most every two seconds, and a change starts another
extract, so the graph has edits not yet committed. A store whose worktree is gone is
removed when a server starts.

Measured on vebidor (1,273 symbols) layered on vlang: a warm extract of the worktree
takes 0.5 s, and is done before the vlang graph is read, which the server starts it
ahead of, so the worktree's graph is the first served; gui's takes 0.5 s, and the
whole V tree's 6.2 s, in a process of its own peaking at 2.2 GB. A session with one
edit made during it, so served twice, peaked at 1.65 GB, against 1.36 GB for the same
session in the checkout. The graph served before is let go before the next is built
(`gc_collect`), which took about 0.1 GB off that.

Still open: two sessions in one worktree extract into one store, each its own extract;
and a worktree of a project the store has no graph of gets none, as before.
