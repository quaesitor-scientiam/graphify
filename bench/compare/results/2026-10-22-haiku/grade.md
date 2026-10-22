The grading is done. Nothing was edited or created. Every claim was checked at ffc38ada48 by Read and Grep on the working tree, whose HEAD is that commit (`.git/refs/heads/master`).

## Results

| Run | Found (of 69) | Wrong | Q3 extra found (of 10) |
|---|---|---|---|
| run1 | 68 | 0 | 10 |
| run2 | 61 | 0 | 3 |
| run3 | 65 | 2 | 5 |
| run4 | 66 | 0 | 10 |

Per question, found/total:

| Q | Total | run1 | run2 | run3 | run4 |
|---|---|---|---|---|---|
| Q1 | 15 | 15 | 15 | 15 | 15 |
| Q2 | 4 | 3 | 3 | 3 | 1 |
| Q3 default | 7 | 7 | 4 | 4 | 7 |
| Q4 | 6 | 6 | 2 | 6 | 6 |
| Q5 | 12 | 12 | 12 | 12 | 12 |
| Q6 | 9 | 9 | 9 | 9 | 9 |
| Q7 | 3 | 3 | 3 | 3 | 3 |
| Q8 | 13 | 13 | 13 | 13 | 13 |

## Per run

**run1**
- Misses: Q2 point 1, the `File{}` zero start at `os/os.c.v:1246`. It explains the zero fd through the temporary File at 1255-1257 instead.
- Wrong: none.
- Heading says "18" for Q1 but lists 15 correct items. This is a count error in the header, not a wrong item.

**run2**
- Misses:
  - Q2 point 1 (as run1).
  - Q3 default routes 4, 6 and 7. These are the socks5 proxy routes: `connect_tcp` → `socks5_dial` → `socks5.v:20`, and `socks5_ssl_dial` → `socks5_dial`.
  - Q3 extra: only routes 8, 10 and 12 are given. It says it did not enumerate the rest, so 9, 11, 13, 14, 15, 16 and 17 are missing.
  - Q4: `veb/veb.v:1103`, `veb/veb_livereload.v:144`, `:166` and `:289`. It also states the total as "two" when it is six.
- Wrong: none.

**run3**
- Misses:
  - Q2 point 1 (as run1).
  - Q3 default routes 4, 6 and 7 (as run2).
  - Q3 extra: the Windows-only routes 9, 11, 13, 15 and 17. It disclosed "not traced".
- Wrong: Q2 says `fd: 0` appears at `os/file.c.v:168` and `:177`. Those are `fd: 1` and `fd: 2`.

**run4**
- Misses: Q2 points 1, 2 and 3. It gives the fixed behaviour (`fileno` at 1264) but never explains how the original fd 0 arose.
- Wrong: none.

## Key drift at ffc38ada48

- **Q2:** confirmed. `open_append` returns `fd: fileno(file.cfile)` at `os/os.c.v:1264`. Points 1-3 still hold at 1245-1246, 1253-1257 and `file.c.v:21`. Point 4 is replaced as the key says. `os_fd_test.v:102` starts the test and the assertion is at `:112`.
- **Q3:** confirmed. All 17 routes exist, and the moved lines are right: `transport.v` 742, 755, 757, 791, 807, 809 and 822, and `transport_h2.v` 469, 484 and 495. The other cited lines are unchanged. The grep found no other callers of any route step, so no new route exists.
- **Q8 item 9:** confirmed at `transport.v:791`, inside `dial_h1_tcp` at 790. No new non-test callers of `dial_tcp`.
- **Q1 non-item:** `unix/stream.c.v:346` confirmed.
- **Q4 to Q7:** unchanged, confirmed.
- **No dropped items and no new items.** I grepped each question's pattern across non-test vlib, and nothing new turned up.
- **Q6 alternate:** run4's `builtin/js/builtin.v:28` is the JS-build `IError.code`. It is a true alternate location for item 6, not a new item.
- **Not verified:** the commit ancestry, the "73 commits" count and `0cf85b0310`. Git commands needed approval here, so I checked the code, not the history.

## Updated totals

Q1 15, Q2 4, Q3 default 7 (extra 10), Q4 6, Q5 12, Q6 9, Q7 3, Q8 13. Total 69, unchanged.

**Judgment call on Q2:** I scored point 1 (`File{}` at 1246) as a miss for runs 1-3. If you count their temporary-File explanation at 1255-1257 as covering it, those runs go to 4/4, and the totals rise by 3.
