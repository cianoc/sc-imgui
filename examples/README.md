# Examples

Runnable examples for `sc-imgui`. Each file defines state variables, `define-gui`
panels and `example-*` helper functions, and none calls `gui:start`.

First set up your REPL so `gui:start` can work: see "Running from SLIME or Sly"
in the [top-level README](../README.md) (SLIME needs
`(setf swank::*main-thread-used* t)` in `~/.swank.lisp`).

For each example, run these three steps from the repository root:

```lisp
(ql:quickload :sc-imgui)
(gui:start)
(load "examples/<file>.lisp")
```

You only need the first two once per session. Loading several examples gives
several windows, and loading one again simply redefines it.

| File | Shows |
| --- | --- |
| `hello.lisp` | `text`, a click-counting `button`, a `slider` and a `checkbox` on plain variables |
| `layout.lisp` | `with-row`, a four-column `with-grid`, `with-section`, a scrolling `with-child` |
| `plots.lisp` | A live sine with `plot-lines`, plus `plot-bars` and `plot-scatter`, from float vectors |
| `custom-knob.lisp` | `example-knob`, a draggable knob built from `invisible-button`, `mouse-drag-delta`, `draw-circle` and `draw-arc` |
| `error-recovery.lisp` | A broken panel beside a healthy one; fix it with `(setf *example-break* nil)` and Retry, or by re-evaluating |

Each file starts with a comment saying what to try. Edit a panel and
re-evaluate it with C-c C-c to see the window update.
