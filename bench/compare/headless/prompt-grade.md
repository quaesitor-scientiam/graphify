Grade four answers to a fixed set of questions about V's standard library, against an answer key, checking at the source.

Files (in the current directory):
- questions.md: the questions. Their scope rules matter (non-test vlib code only, etc.).
- key.md: the answer key, keyed at the vlang commit it names. Its sections after the questions say how items are counted (the Q3 [openssl] routes are counted apart as "extra") and what changed at later commits.
- run1.md, run2.md, run3.md, run4.md: the answers. You don't know how each was produced, and it doesn't matter.
- The source to check against is {{VLANG}}, at commit {{COMMIT}}. Use Grep and Read on it; it is the truth.

Steps:
1. Re-key at {{COMMIT}}. For every key item, check it still holds at the current source. An item whose code is the same at another line still counts, at its new line. Note items that no longer exist, and new items the current source has that the key lacks.
2. Grade each answer against the updated key. For each run and question: items found, items missed (list them), items wrong (given but false at the source; list them). A line off by one or two for the same call is found, not wrong. An item an answer gives that is true at the source but missing from the updated key is not wrong: add it to the key and recheck the other runs for it.
3. Q3: score the default-build routes as items, and count the [openssl] routes apart as "extra".

This is read-only: don't edit or create any file.

Final message:
- A table with one row per run: items found/total, wrong, Q3 extra found/total.
- Per run, the misses and wrong items.
- The key's drift at {{COMMIT}}, if any.
- Updated per-question totals.
