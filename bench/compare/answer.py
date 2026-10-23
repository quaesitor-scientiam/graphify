#!/usr/bin/env python3
"""Writes a benchmark run's answer from its transcript.

    python3 bench/compare/answer.py <transcript> <answer.md>

A transcript is a run's `claude -p --output-format stream-json` output. The answer is
the reply in which the agent first stopped: the first reply that calls no tool, which
ends its turn. That is its answer to the benchmark's prompt. In a plain run it is also
the final message, the transcript's result. But when something answers the stop with
more input (a Stop hook asking for another section, a classifier cutting a reply off),
the agent replies again, and the result holds only its last reply: a run that answered
and then added a short note would be graded on the note. What it writes after the first
stop is a reply to input the other runs don't get, so it isn't graded; it stays in the
transcript.

Replies of subagents, if a run starts any, are not the run's own and are skipped. The
file is written as UTF-8 with LF line ends on every platform; a run with no reply in
which it stopped gets the transcript's result.
"""
import json
import sys


def answer(path):
    text, tool, result = [], False, ''
    with open(path, encoding='utf-8') as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            kind = d.get('type')
            if d.get('parent_tool_use_id') and kind in ('assistant', 'user'):
                continue
            if kind == 'assistant':
                content = (d.get('message') or {}).get('content') or []
                if isinstance(content, str):
                    content = [{'type': 'text', 'text': content}]
                for c in content:
                    if c.get('type') == 'text' and c.get('text', '').strip():
                        text.append(c['text'].strip())
                    elif c.get('type') == 'tool_use':
                        tool = True
            elif kind in ('user', 'result'):
                # a user event ends a reply: a tool result, or input given after a stop
                if text and not tool:
                    return '\n\n'.join(text)
                text, tool = [], False
                if kind == 'result':
                    result = d.get('result') or ''
    if text and not tool:
        return '\n\n'.join(text)
    return result


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: answer.py <transcript> <answer.md>')
    with open(sys.argv[2], 'w', encoding='utf-8', newline='\n') as f:
        f.write(answer(sys.argv[1]) + '\n')


if __name__ == '__main__':
    main()
