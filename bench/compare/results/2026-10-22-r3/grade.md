All four answers are close to perfect. Runs 1–3 found every item, and run 4 missed one. No run gave a wrong item, and every run found all 10 [openssl] routes for Q3.

| Run | Items found / total | Wrong | Q3 extra found / total |
|---|---|---|---|
| run1 | 69 / 69 | 0 | 10 / 10 |
| run2 | 69 / 69 | 0 | 10 / 10 |
| run3 | 69 / 69 | 0 | 10 / 10 |
| run4 | 68 / 69 | 0 | 10 / 10 |

## Misses and wrong items per run

- **run1:** no misses, no wrong items.
- **run2:** no misses, no wrong items.
- **run3:** no misses, no wrong items. One slip that doesn't affect the score: its Q1 heading says "13 calls", but it lists 15 and then says "That is 15 lines in all".
- **run4:**
  - **Q2 miss: point 1.** It never points to `mut file := File{}` at os/os.c.v:1246, where `open_append` starts from the zero value. It does describe the temporary built in the Unix branch, but that is point 3. This is the one strict call; if you count it as found, run4 is 69/69.
  - **Not counted wrong:**
    - Its Q2 lines are one off (1263–1267, and `fd` at "1265" instead of 1264). The rule allows that.
    - In Q8 it calls the function at ftp.v:204 `ftp.FTP.new_dtp`, but it is the free function `ftp.new_dtp` (ftp.v:190). The line is right, so I counted it found; only the name is wrong.
    - Its Q8 heading says "14 functions, 15 calls" but it lists 13.
    - Its Q6 lists `s.on_running` at line 116, but it says that is not a method call.

No run gave something true at the source that the key lacks, so nothing was added to the key. Two extra claims checked out but aren't items: run1 cites os/file.js.v:63 (`fd: 0` in the JS backend) and builtin/cfns.c.v:144 (`C.fileno`), and run3 cites the h3 call at transport.v:723.

## The key's drift at ffc38ada48

The key's own "Changes at ffc38ada48" section is right on every point. I checked each item at the source:

- **Q1:** all 15 calls unchanged. The free-function call in `StreamListener.wait_for_accept` is now at unix/stream.c.v:346.
- **Q2:** the premise no longer holds. `open_append` now returns `File{ cfile: file.cfile, fd: fileno(file.cfile), is_opened: true }` (os/os.c.v:1262–1266, `fd` at 1264), and os/os_fd_test.v:102 tests the fix. Points 1–3 are at the same lines; point 4 is replaced by that return.
- **Q3:** no new routes and none gone. The transport.v and transport_h2.v lines moved exactly as the key lists:
  - transport.v: 742, 755, 757, 791, 807, 809, 822.
  - transport_h2.v: 469, 484, 495.
- **Q8:** the same 13 functions. Only `Transport.dial_h1_tcp` moved, to transport.v:791. No new callers outside tests.
- **Q4–Q7:** unchanged.

Two small things in the key itself:
- In the Q6 "not items", `s.on_stopped` at server.v:142 is in `Server.stop`, not in `listen_and_serve`. It doesn't affect any score.
- Q2 point 5's line, that the contrast "shows it is an omission", no longer fits, since `open_append` now sets `fd` like `open` and `create` do.

## Updated per-question totals

| Q | Items |
|---|---|
| 1 | 15 |
| 2 | 4 (points 1–4, with point 4 replaced) |
| 3 | 7 default-build routes, plus 10 [openssl] extra |
| 4 | 6 |
| 5 | 12 |
| 6 | 9 |
| 7 | 3 |
| 8 | 13 |
| **Total** | **69** (+10 extra) |

I made no file changes.
