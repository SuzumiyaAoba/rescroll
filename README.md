# rescroll

A small, interactive Emacs mode-line scrollbar designed to keep editing and
redisplay cheap. Requires Emacs 29.1 or later; no package dependencies.

## Install

Put this directory on `load-path`:

```elisp
(add-to-list 'load-path "/path/to/rescroll")
(require 'rescroll)
(rescroll-mode 1)
```

Disable `mlscroll-mode` before enabling rescroll. The packages are independent;
rescroll is not a drop-in implementation of mlscroll's internal API.

For a custom mode line, insert `(:eval (rescroll-mode-line))` at the desired
location instead of enabling the global mode. The global mode prepends the bar
to the default `mode-line-end-spaces`, preserving its original contents. It does
not rewrite buffer-local mode lines or remove the existing position percentage.
The mode line needs enough free space to display the bar.

```elisp
(setq rescroll-width 24           ; character cells, clamped to 3–512
      rescroll-wheel-lines 3)
```

Customize faces `rescroll-track` and `rescroll-thumb` for your theme. GUI frames
use colored spaces; terminals use `-` and `=` as well as faces. For terminal
mouse input enable `(xterm-mouse-mode 1)` in a supported terminal.

- **Click:** move point and window start to that fraction of the accessible buffer.
- **Drag:** continuously seek, including to the two endpoints.
- **Wheel:** scroll the window under the pointer without selecting it permanently.

Seeking deliberately moves the target window's point so redisplay does not
immediately scroll back to the old point. Other windows keep their own points.
Narrowing is respected. Emacs may adjust the requested window start during
redisplay (for example at end of buffer or inside invisible text).

## Performance contract and tradeoffs

**The bar measures character positions, not logical or visual lines.** A long
line or folded section occupies its character-proportional share. This is not
an exact line-proportional replacement for mlscroll. It avoids both full-buffer
line counting and the complexity/memory/edit overhead of a maintained line index.

The mode-line evaluator:

- reads `point-min`, `point-max`, `window-start`, and cached `window-end`;
- does constant-count arithmetic independent of buffer size;
- reuses a per-window string if the quantized geometry has not changed;
- keeps the previous geometry's bar too, so scroll reversals and other
  two-position revisits skip rendering entirely;
- allocates at most a bounded-width bar when geometry changes, using a
  constant number of text-property intervals regardless of width, and
  reuses the per-window cache vector instead of allocating;
- installs no edit hooks, timers, overlays, font-lock rules, or file I/O;
- never forces redisplay or calls `window-end` with its update argument.

Before a window has a cached end, the thumb is minimal. Cached ends can lag edits
until the next redisplay. This avoids doing redisplay work recursively inside
mode-line evaluation. Width determines position resolution (24 cells by default).
Changing faces does not require rebuilding strings because they use face symbols.

Clicks locate the cell through a marker text property and interval boundaries,
including in concatenated mode-line strings. Two directly adjacent copies of the
same bar string share one marker run, so the second copy's cells clamp to its
right edge; a separating character avoids this.
Dragging outside the bar uses frame character width as a fallback; this can be
approximate with proportional mode-line fonts. Mouse movement across other windows
is ignored until it returns to the originating window. No SVG/image backend, right
alignment machinery, or automatic shortening of other mode-line elements is used.

These bounds describe **rescroll's evaluator**, not all of Emacs redisplay or the
cost of scrolling/fontifying a destination. Rendering a very long line can still
be expensive in Emacs. The package performs no seek-time line-boundary scans.

## Tests and benchmark

```sh
make check       # strict byte compilation and ERT, including compiled code
make benchmark   # synthetic batch evaluation/edit costs, not GUI input latency
make clean
```

Set `EMACS=/path/to/emacs` to choose the executable. The benchmark visits generated
50 KB, 5 MB, and 50 MB buffers, including a single-long-line case. It measures
cached evaluation, edit+evaluation, and cycling among three window positions
(true cache misses) separately, using temporary buffers only. Background native JIT is
disabled; `benchmark-run-compiled` compiles the measurement loops.
No user files, init, or package state are loaded. See `bench-rescroll.el` for the exact
workload. Repeat in fresh processes and compare medians; do not interpret a single
run as a universal latency or speedup claim.

ERT covers endpoints, narrowing, empty buffers, stale/unknown window ends,
cache reuse after edits, independent windows, undo, mouse coordinates/input
preservation, and reversible global-mode integration. GUI/TTY mouse behavior and
real redisplay should also be smoke-tested interactively; batch tests alone do
not validate platform mouse delivery or font geometry.

### Initial verification

On macOS / Emacs 31.1, strict byte compilation and all 14 ERT tests passed.
A real PTY redisplay smoke test also passed (bar inclusion, seeking, disable).
The GUI smoke invocation timed out; GUI rendering and physical mouse input
remain unverified. To run the isolated smoke test yourself:

```sh
emacs -Q -nw -L . -l test/rescroll-interactive-smoke.el
# Omit -nw to test a GUI frame. The test exits its Emacs process automatically.
```

One synthetic batch run (not a median or comparison against mlscroll):

| Buffer | Cached evaluation ×100,000 | Edit + evaluation ×10,000 | Changed geometry ×10,000 |
| --- | ---: | ---: | ---: |
| 50 KB | 36.1 ms | 14.1 ms | 18.4 ms |
| 5 MB | 35.5 ms | 10.4 ms | 17.9 ms |
| 50 MB | 38.7 ms | 17.4 ms | 16.8 ms |
| 50 MB, single line | 34.6 ms | 16.7 ms | 7.2 ms |

No measured path caused a GC in this run. This supports size-independent
evaluator work, not a claim about whole-editor input latency. The batch fixture
has no real redisplay and exercises cached/unknown window ends. Emacs 29/30 and
Linux have not yet been tested.

## License

[GPL-3.0-or-later](LICENSE).
