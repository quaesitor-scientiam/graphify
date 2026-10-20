#!/usr/bin/env python3
"""End-to-end check of graphify-mcp's daemon (cmd/mcp/daemon.v) on this OS.

    python3 daemon_smoke.py <graphify-mcp> <graph.json> <symbol>

Two servers, started as a client starts them, answer a get_node call through one
daemon: the first starts it and the second finds it. Each exits once its client
closes its stdin, which a handle of the client's left open in the daemon would stop.
The server's binary is then rebuilt (copied over itself) while the daemon runs, which
on Windows works only because the daemon runs from a copy of it, and the daemon,
with no server connected, goes away.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time


def fail(msg, log_dir=None):
    print('FAIL: ' + msg)
    if log_dir:
        for name in sorted(os.listdir(log_dir)):
            print('--- ' + name)
            if name.endswith('.log'):
                print(open(os.path.join(log_dir, name), errors='replace').read())
    sys.exit(1)


class Server:
    def __init__(self, exe, graph, env, cwd):
        self.p = subprocess.Popen([exe, graph], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env, cwd=cwd)
        self.lines = []
        self.err = []
        threading.Thread(target=self._read, args=(self.p.stdout, self.lines), daemon=True).start()
        threading.Thread(target=self._read, args=(self.p.stderr, self.err), daemon=True).start()

    @staticmethod
    def _read(stream, out):
        for line in iter(stream.readline, b''):
            out.append(line.decode(errors='replace'))

    def send(self, msg):
        self.p.stdin.write((json.dumps(msg) + '\n').encode())
        self.p.stdin.flush()

    def reply(self, id, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for line in self.lines:
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get('id') == id:
                    return m
            time.sleep(0.1)
        return None

    def ask(self, symbol, timeout=180):
        self.send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'smoke', 'version': '0'}}})
        if not self.reply(1, 30):
            return None
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                   'params': {'name': 'get_node', 'arguments': {'node': symbol}}})
        r = self.reply(2, timeout)
        if not r:
            return None
        return ''.join(c.get('text', '') for c in r.get('result', {}).get('content', []))

    def close(self, timeout=20):
        self.p.stdin.close()
        try:
            self.p.wait(timeout)
            return True
        except subprocess.TimeoutExpired:
            self.p.kill()
            return False


def socks(d):
    return [n for n in os.listdir(d) if n.endswith('.sock')]


def main():
    exe, graph, symbol = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), sys.argv[3]
    d = tempfile.mkdtemp(prefix='gfd')
    env = dict(os.environ, GRAPHIFY_DAEMON_DIR=d, GRAPHIFY_DAEMON_IDLE='5')
    env.pop('GRAPHIFY_MCP_DAEMON', None)
    env.pop('GRAPHIFY_MCP_EXE', None)
    cwd = os.path.dirname(graph)

    a = Server(exe, graph, env, cwd)
    text = a.ask(symbol)
    if text is None or symbol not in text:
        fail('the first server did not answer: %r\n%s' % (text, ''.join(a.err)), d)
    if len(socks(d)) != 1:
        fail('expected one daemon socket, found %s' % socks(d), d)
    if os.name == 'nt' and not [n for n in os.listdir(d) if n.endswith('.exe')]:
        fail('the daemon is not running from a copy of the binary', d)

    b = Server(exe, graph, env, cwd)
    text = b.ask(symbol)
    if text is None or symbol not in text:
        fail('the second server did not answer: %r\n%s' % (text, ''.join(b.err)), d)
    if len(socks(d)) != 1:
        fail('the second server started a daemon of its own: %s' % socks(d), d)

    for name, s in (('first', a), ('second', b)):
        if not s.close():
            fail('the %s server did not exit after its client closed stdin' % name, d)
    if not any('started the daemon' in l for l in a.err):
        fail('the first server did not start the daemon:\n' + ''.join(a.err), d)
    if any('started the daemon' in l for l in b.err):
        fail('the second server started a daemon:\n' + ''.join(b.err), d)

    # rebuild the server's binary while its daemon runs
    rebuilt = exe + '.rebuilt'
    shutil.copy2(exe, rebuilt)
    time.sleep(1.1)
    try:
        os.replace(rebuilt, exe)
    except OSError as e:
        fail('cannot replace %s while the daemon runs: %s' % (exe, e), d)
    os.utime(exe)

    end = time.time() + 90
    while socks(d) and time.time() < end:
        time.sleep(1)
    if socks(d):
        fail('the daemon did not go away after its binary was rebuilt and no server was connected', d)
    print('OK: two servers shared one daemon, each exited with its client, and the daemon went away')


if __name__ == '__main__':
    main()
