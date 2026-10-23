#!/usr/bin/env python3
"""Checks answer.py against small made-up transcripts.

    python3 bench/compare/answer_test.py

The rule under test: a run's answer is the reply in which its agent first stopped, not
the transcript's result, which holds its last reply.
"""
import json
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.dont_write_bytecode = True  # no __pycache__ beside the benchmark
from answer import answer  # noqa: E402


def text(t):
    return {'type': 'assistant', 'message': {'id': 'm', 'content': [{'type': 'text', 'text': t}]}}


def tool(t=''):
    content = [{'type': 'text', 'text': t}] if t else []
    content.append({'type': 'tool_use', 'name': 'Grep', 'input': {}})
    return {'type': 'assistant', 'message': {'id': 'm', 'content': content}}


def tool_result():
    return {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'content': 'x'}]}}


def given(t):
    return {'type': 'user', 'message': {'content': t}}


def result(t):
    return {'type': 'result', 'subtype': 'success', 'result': t}


def transcript(events, junk=False):
    f = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False, encoding='utf-8')
    with f:
        for e in events:
            f.write(json.dumps(e) + '\n')
            if junk:
                f.write('not json\n')
    return f.name


def check(name, events, want, junk=False):
    path = transcript(events, junk)
    try:
        got = answer(path)
    finally:
        os.remove(path)
    assert got == want, f'{name}: got {got!r}, want {want!r}'


check('a plain run is its final message',
      [tool('Q4 done. Now Q5.'), tool_result(), text('ANSWER'), result('ANSWER')],
      'ANSWER')

check('a reply to a Stop hook after the answer is not the answer',
      [tool(), tool_result(), text('FULL ANSWER'), given('Stop hook feedback: add a review'),
       text('REVIEW'), result('REVIEW')],
      'FULL ANSWER')

check('nor is one after more tool calls',
      [tool(), tool_result(), text('FULL ANSWER'), given('Stop hook feedback: check Q4'),
       tool('Checking Q4.'), tool_result(), text('SHORT'), result('SHORT')],
      'FULL ANSWER')

check("a subagent's reply is not the run's",
      [dict(tool(), parent_tool_use_id=None), dict(text('SUBAGENT'), parent_tool_use_id='t1'),
       dict(tool_result(), parent_tool_use_id='t1'), tool_result(), text('ANSWER'),
       result('ANSWER')],
      'ANSWER')

check('a reply sent as several events is one reply',
      [tool(), tool_result(), text('part 1'), text('part 2'), result('part 2')],
      'part 1\n\npart 2')

check('a run that never stops with text gets its result',
      [tool(), tool_result(), result('R')],
      'R')

check('lines that are not JSON are skipped',
      [tool(), tool_result(), text('ANSWER'), result('ANSWER')],
      'ANSWER', junk=True)

# the file written: UTF-8 with LF line ends, whatever the platform
path = transcript([text('a → b — c\nnext'), result('x')])
out = path + '.md'
try:
    subprocess.run([sys.executable, os.path.join(here, 'answer.py'), path, out], check=True)
    with open(out, 'rb') as f:
        data = f.read()
finally:
    os.remove(path)
    if os.path.exists(out):
        os.remove(out)
assert data == 'a → b — c\nnext\n'.encode('utf-8'), f'file: got {data!r}'

print('answer_test: ok')
