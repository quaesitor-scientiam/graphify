# graphify vs grep: questions

Eight questions about V's standard library, at a fixed vlang commit, for comparing a
session that answers with graphify's MCP tools against one that answers with grep
alone. Each is scored against `key.md` for completeness (items found of those in the
key) and precision (items given that are wrong), not only for cost: a search that
stops early is cheap, but its misses count against it.

The questions are balanced. Three suit grep: a text search (7), a list of callers of
one function (8), and the callers of a method name no other type uses (1). Four suit
the graph: callers of a method whose name many types share (4), every route between
two functions (3), the direct calls of a function (5), and the receiver type of every
method call in one function (6). One needs reading either way (2).

Scope for every question: vlib in the vlang tree only. Non-test code only: leave out
`_test.v` and `_test.c.v` files and anything under a `tests`, `slow_tests` or
`testdata` directory. A call is a call site in code; a commented-out call is not one.

1. List every call of any `wait_for_read` *method* in vlib/net, on any receiver type,
   each with the file:line of the call. Calls of the free functions named
   `wait_for_read` don't count.
2. Why does `os.open_append` return a File whose `fd` field is 0 on Unix? Point to the
   lines that show it.
3. List every route by which `http.get` reaches `net.dial_tcp` through chains of
   direct calls, each step with the file:line of the call. A route visits no function
   twice. Give all the routes, not only the shortest.
4. List every call of `net.TcpConn.write_string` in vlib, with the file:line of the
   call and the function it is in. Calls of other types' `write_string` (such as
   `strings.Builder`'s) don't count.
5. List every function `os.cp_all` calls directly, with the line or lines of each
   call. Count V builtins (such as `error`) too.
6. In `http.Server.listen_and_serve` (vlib/net/http/server.v), list every method call,
   with the line, the receiver's type and the declaration (file:line) it calls.
7. List every place in vlib/net/http that returns or raises an error whose message
   mentions a redirect, with its file:line.
8. List every function in vlib that calls `net.dial_tcp` directly, with the file:line
   of each call.
