module main

// One daemon answers the tool calls of every session's server, so that the V
// tree's graph, and its index, are read once and not once a session: each server is
// started by its client and relays the tool calls it gets to the daemon, over a
// Unix socket in the user's cache directory, as one line of JSON each way. The
// first server to find no daemon starts one. The daemon keeps an App for each
// session's directory, which share the base graphs (BaseCache), and goes away when
// no server has been connected to it for daemon_idle(), or once none is when
// its binary has been rebuilt; the socket is named after the binary, so a server
// built since starts a daemon of its own. GRAPHIFY_MCP_DAEMON=0 has each server read
// its graphs itself, as it does where there are no Unix sockets.
import os
import net.unix
import sync
import time
import x.json2
import crypto.sha256

// daemon_idle is how many seconds a daemon, and an App no session asks for, outlive
// their last use: GRAPHIFY_DAEMON_IDLE, or 15 minutes.
fn daemon_idle() i64 {
	n := os.getenv('GRAPHIFY_DAEMON_IDLE').i64()
	return if n > 0 { n } else { 15 * 60 }
}

// daemon_enabled reports whether the server relays to a daemon.
fn daemon_enabled() bool {
	$if windows {
		return false
	}
	return os.getenv('GRAPHIFY_MCP_DAEMON') != '0'
}

// daemon_dir is where the daemon's socket and log are: GRAPHIFY_DAEMON_DIR, or the
// user's cache directory; a directory of the user's under the system's temporary
// one when a socket's path there would be longer than a Unix socket's may be.
fn daemon_dir() string {
	dir := os.getenv('GRAPHIFY_DAEMON_DIR')
	wanted := if dir != '' { dir } else { os.join_path(os.cache_dir(), 'graphify') }
	// `/mcp-` + 16 + `.sock`, within the 103 bytes of sun_path
	if wanted.len + 26 <= 103 {
		return wanted
	}
	return os.join_path('/tmp', 'graphify-${os.getuid()}')
}

// daemon_name names the daemon for this server's binary and what it serves, so that
// servers started alike share one, and a server rebuilt since starts its own.
fn daemon_name(cfg Config) string {
	exe := os.executable()
	key := [file_stamp(exe), os.real_path(cfg.graph_path), cfg.projects_dir, cfg.src_dir].join('\n')
	return 'mcp-${sha256.hexhash(key)[..16]}'
}

// how long a server waits for the daemon's answer: longer than the daemon takes to
// read the V tree's graph, or to layer a project on it, for the first call
const answer_timeout = 10 * time.minute

// connect_daemon connects to the daemon for `cfg`, starting one when there is none,
// and waits for it to listen; nil when none can be had.
fn connect_daemon(cfg Config) &unix.StreamConn {
	dir := daemon_dir()
	os.mkdir_all(dir) or { return unsafe { nil } }
	socket := os.join_path(dir, daemon_name(cfg) + '.sock')
	if mut conn := unix.connect_stream(socket) {
		conn.set_read_timeout(answer_timeout)
		return conn
	}
	start_daemon(cfg) or {
		eprintln('graphify-mcp: cannot start the daemon: ${err}')
		return unsafe { nil }
	}
	// it listens before it reads a graph
	for _ in 0 .. 100 {
		time.sleep(100 * time.millisecond)
		if mut conn := unix.connect_stream(socket) {
			eprintln('graphify-mcp: started the daemon at ${socket}')
			conn.set_read_timeout(answer_timeout)
			return conn
		}
	}
	eprintln('graphify-mcp: the daemon did not listen at ${socket}')
	return unsafe { nil }
}

// start_daemon runs this server's binary as the daemon for `cfg`. Its stdio is
// pipes, not the client's: it puts its own in place of them (run_daemon).
fn start_daemon(cfg Config) ! {
	mut args := ['--daemon', cfg.graph_path]
	if cfg.src_dir != '' {
		args << cfg.src_dir
	}
	if cfg.projects_dir != '' {
		args << ['--projects', cfg.projects_dir]
	}
	mut p := os.new_process(os.executable())
	p.set_args(args)
	p.set_redirect_stdio()
	p.run()
	if p.status == .exited && p.code != 0 {
		return error('exit code ${p.code}')
	}
}

// ask relays the tool call to the daemon and reads its answer; none when the
// daemon has gone.
fn (mut s Session) ask(name string, arguments string) ?(string, bool) {
	mut conn := s.remote
	request := json2.encode({
		'dir':       json2.Any(s.here)
		'name':      json2.Any(name)
		'arguments': json2.Any(arguments)
	})
	conn.write_string(request + '\n') or { return none }
	line := read_line(mut conn, mut s.pending) or { return none }
	answer := (json2.decode[json2.Any](line) or { return none }).as_map()
	text := (answer['text'] or { return none }).str()
	is_error := (answer['is_error'] or { json2.Any(false) }).bool()
	return text, is_error
}

// read_line reads from `conn` up to a newline, keeping what it read past it in
// `pending` for the next line.
fn read_line(mut conn unix.StreamConn, mut pending []u8) !string {
	mut buf := []u8{len: 65536}
	for {
		i := pending.index(`\n`)
		if i >= 0 {
			line := pending[..i].bytestr()
			pending = pending[i + 1..].clone()
			return line
		}
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('closed')
		}
		pending << buf[..n]
	}
	return error('closed')
}

// Daemon is the state of the daemon: an App for each session's directory, the base
// graphs they share, and the servers connected. `mu` lets one tool call at a time
// use them.
@[heap]
struct Daemon {
	cfg Config
mut:
	mu      &sync.Mutex = sync.new_mutex()
	apps    map[string]&App
	bases   &BaseCache = &BaseCache{}
	conns   int
	used_at i64
}

// run_daemon is the daemon: it leaves its client's session, so that it outlives the
// server that started it, listens, reads the base graph, and answers the servers
// that connect until none has for daemon_idle().
fn run_daemon(cfg Config) {
	$if windows {
		eprintln('graphify-mcp: no daemon on Windows')
		exit(1)
	} $else {
		dir := daemon_dir()
		os.mkdir_all(dir) or { exit(1) }
		name := daemon_name(cfg)
		detach(os.join_path(dir, name + '.log'))
		socket := os.join_path(dir, name + '.sock')
		// another started at the same time
		if mut other := unix.connect_stream(socket) {
			other.close() or {}
			exit(0)
		}
		os.rm(socket) or {}
		remove_dead_daemons(dir)
		mut listener := unix.listen_stream(socket) or {
			eprintln('graphify-mcp daemon: cannot listen at ${socket}: ${err}')
			exit(1)
		}
		eprintln('graphify-mcp daemon: listening at ${socket}')
		exe := os.executable()
		exe_stamp := file_stamp(exe)
		mut d := &Daemon{
			cfg:     cfg
			used_at: time.now().unix()
		}
		// the base graph is read while the first server waits for its answer
		d.mu.lock()
		d.bases.get(cfg.graph_path, cfg.src_dir) or {
			eprintln('graphify-mcp daemon: cannot load ${cfg.graph_path}: ${err}')
		}
		gc_collect()
		d.mu.unlock()
		// look whether it is done at least once a minute
		listener.set_accept_timeout(time.second * if daemon_idle() < 60 {
			daemon_idle()
		} else {
			60
		})
		for {
			// accept blocks with no timeout of its own: wait_for_accept has one
			listener.wait_for_accept() or {
				if d.done(exe, exe_stamp) {
					break
				}
				continue
			}
			mut conn := listener.accept() or { continue }
			// a server is quiet between its client's tool calls, for as long as it is
			conn.set_read_timeout(time.infinite)
			d.mu.lock()
			d.conns++
			d.used_at = time.now().unix()
			d.mu.unlock()
			spawn d.serve_conn(mut conn)
		}
		listener.close() or {}
		os.rm(socket) or {}
		eprintln('graphify-mcp daemon: done')
	}
}

// remove_dead_daemons removes the socket, and the log, of each daemon in `dir` that
// no longer listens: one killed, or one of a binary since rebuilt that went down
// before it could.
fn remove_dead_daemons(dir string) {
	for name in os.ls(dir) or { return } {
		if !name.ends_with('.sock') {
			continue
		}
		path := os.join_path(dir, name)
		if mut conn := unix.connect_stream(path) {
			conn.close() or {}
			continue
		}
		os.rm(path) or {}
		os.rm(path.all_before_last('.') + '.log') or {}
	}
}

// done drops each App no session has asked for in daemon_idle(), and reports whether
// the daemon is done: no server connected, and none for daemon_idle(), or the binary
// rebuilt since it started.
fn (mut d Daemon) done(exe string, exe_stamp string) bool {
	d.mu.lock()
	defer {
		d.mu.unlock()
	}
	now := time.now().unix()
	idle := daemon_idle()
	mut used := {
		d.cfg.graph_path: true
	}
	for dir, app in d.apps {
		if now - app.used_at >= idle {
			d.apps.delete(dir)
			continue
		}
		used[app.base_path] = true
	}
	d.bases.keep(used)
	gc_collect()
	if d.conns > 0 {
		return false
	}
	return now - d.used_at >= idle || file_stamp(exe) != exe_stamp
}

// serve_conn answers the tool calls one server relays, one line each, until it
// disconnects.
fn (mut d Daemon) serve_conn(mut conn unix.StreamConn) {
	mut pending := []u8{}
	for {
		line := read_line(mut conn, mut pending) or { break }
		text, is_error := d.answer(line)
		answer := json2.encode({
			'text':     json2.Any(text)
			'is_error': json2.Any(is_error)
		})
		conn.write_string(answer + '\n') or { break }
	}
	conn.close() or {}
	d.mu.lock()
	d.conns--
	d.used_at = time.now().unix()
	d.mu.unlock()
}

// answer runs the tool call in `line` on the App of the session's directory it
// names, made when it is the first call from there.
fn (mut d Daemon) answer(line string) (string, bool) {
	request := (json2.decode[json2.Any](line) or { return 'bad request', true }).as_map()
	dir := (request['dir'] or { json2.Any('') }).str()
	name := (request['name'] or { json2.Any('') }).str()
	args := (request['arguments'] or { json2.Any('{}') }).str()
	d.mu.lock()
	defer {
		d.mu.unlock()
	}
	key := if dir == '' { '' } else { os.real_path(dir) }
	mut app := d.apps[key] or {
		eprintln('graphify-mcp daemon: a session in ${dir}')
		a := new_app(d.cfg, dir, d.bases) or { return 'graphify-mcp: ${err}', true }
		d.apps[key] = a
		a
	}
	return app.answer(name, args)
}

fn C.setsid() int

// detach puts the daemon in a session of its own, so that it outlives its client's,
// with its output going to `log`, and closes what it got from the server that
// started it: a copy of the client's stdin kept open would keep that server from
// seeing its client go.
fn detach(log string) {
	$if !windows {
		C.setsid()
		for fd in 3 .. 256 {
			os.fd_close(fd)
		}
		// open_file sets a File's fd; os.open and open_append leave it 0
		null := os.open_file('/dev/null', 'r') or { return }
		os.fd_dup2(null.fd, 0)
		out := os.open_file(log, 'a') or { return }
		os.fd_dup2(out.fd, 1)
		os.fd_dup2(out.fd, 2)
	}
}
