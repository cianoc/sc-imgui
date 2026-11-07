# Audio Editors (Part 3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an envelope editor, a drum sequencer, and a melodic sequencer to the `gui` package, Ableton Live-style, editing immutable values in Lisp places.

**Architecture:** A pure-Lisp *data layer* (envelopes, patterns, timing remaps, scales, selection and clipboard operations, undo history) lives in `src/gui/editors/` and is tested without ImGui. On top of it, a shared *sequencer grid* (layout, drawing, scrolling, end marker, focus, keyboard commands, Select-mode mouse) is used by both sequencers, and each editor adds only its own drawing and Draw-mode interaction. Editors reuse the part 3a control core for rem sizing, theme colours, wheel handling, and typed entry. No native changes.

**Tech Stack:** SBCL, CFFI, the generated `%imgui` bindings, FiveAM.

**Spec:** `docs/superpowers/specs/2026-11-06-audio-editors-design.md`. Executors read the spec alongside this plan. The plan names the files, interfaces, and tests; the spec holds the full behaviour that tasks refer to by section.

## Global Constraints

- No changes to `native/`, `src/bindings/`, or the generated files. Every ImGui call uses existing bindings.
- Exports:
    - Every public name in the spec is exported from `gui` in `src/gui/package.lisp`.
    - Internal helpers stay unexported, and tests reach them with `gui::`.
- Values are immutable:
    - Nothing ever modifies an envelope, a pattern, or a step after it is constructed.
    - Every change builds a new value, through a validating constructor.
    - Arrays inside values are never handed to callers.
- sc-imgui doesn't depend on cl-collider at load time. `envelope-env` finds `cl-collider:env` with `find-symbol` when it is called.
- Sizes are in rem through `gui::rem-px`. Colours come only from the theme, through `gui::control-color` or `gui::control-shade`, never as literals.
- Cmd on macOS and Ctrl elsewhere are both read from `io.key-ctrl`; never read `key-super`. Alt/Option is `io.key-alt`.
- Drawing an editor never writes its place. Only user input does.
- Type, value, and argument errors are signalled before any foreign call:
    - A wrong type in the place signals `gui:widget-value-error`, naming the label.
    - Invalid data signals `gui:editor-data-error`.
    - Invalid editor arguments signal `gui:control-spec-error`, naming the label.
- No vertex is drawn outside an editor's item rectangle. Clip drawing with `push-clip-rect` and `pop-clip-rect`.
- Tests:
    - FiveAM, new suite `editors`, run with `make test SUITE=editors`.
    - Every headless test ends with `(is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))`.

## Review Focus

Inputs the spec implies but doesn't spell out, most likely first. Each is pinned by a test in the owning task.

| # | Input or condition | Expected behaviour | Pinned in |
| --- | --- | --- | --- |
| 1 | B, Delete, or an arrow key typed while a text field has focus: another widget's field, or the editor's own Cmd-click field | The field gets the key. The editor ignores keys whenever `io.want-text-input` is true. | Task 11 `keys-ignored-while-typing` |
| 2 | The place is replaced from code (REPL or pattern thread) in the middle of a drag | The drag gesture ends at once and the code's value wins. It is recorded as an undo step, and the drag's partial edit is dropped. | Task 9 `code-change-ends-gesture`, Task 11 `code-change-mid-drag` |
| 3 | Timing or rows changed from code so the selection, insert marker, or scroll position is out of range | Out-of-range selection entries are dropped, and the marker and scroll are clamped. No error. | Task 11 `selection-survives-shrink` |
| 4 | An `:exp` segment whose levels differ in sign, or an envelope whose duration is 0 | Draws without an arithmetic error. `:exp` across a sign change, or touching 0, is drawn linear. A 0 duration gets a 1 s view. | Task 3 `exp-across-zero-is-linear`, Task 15 `zero-duration-envelope-draws` |
| 5 | With `:fold`, a melodic note that isn't in the scale | It isn't lost. It is drawn as a half-height block on the row of the nearest visible note below it, can be selected and moved, and its tooltip gives its real note. | Task 13 `off-scale-note-is-drawn`, Task 14 `off-scale-note-selectable` |

## File Structure

```
src/gui/editors/
  conditions.lisp      editor-data-error
  envelope.lisp        envelope value, normalization, readers, copies, constructors, env args
  curves.lisp          SuperCollider curve shapes
  pattern.lisp         timing base struct, readers, pattern-with-length
  drum-pattern.lisp    drum patterns
  melodic-pattern.lisp note steps, melodic patterns
  notes.lisp           note names, scales, scale-note-p
  remap.lisp           pattern-with-bars / -bar-length / -step-resolution
  events.lisp          pattern-events
  selection.lisp       selections, clipboard, move, toggle (pure)
  editor-state.lisp    per-editor state table, undo history, focus
  grid.lisp            sequencer grid layout, drawing, scroll, end marker, header
  grid-edit.lisp       shared keyboard commands and Select-mode mouse
  drum-grid.lisp       gui:drum-grid
  melodic.lisp         gui:melodic-sequencer
  envelope-editor.lisp gui:envelope-editor
src/gui/theme.lisp            (modify) grid roles
src/gui/controls/core.lisp    (modify) text-entry :parse
src/gui/package.lisp          (modify) exports
sc-imgui.asd                  (modify) editors module, test files
tests/suites.lisp             (modify) add `editors`
tests/headless.lisp           (modify) :alt key, right-click, multi-point drags
tests/test-editor-data.lisp   pure-Lisp tests (tasks 2-9)
tests/test-editors.lisp       headless tests (tasks 10-16)
examples/editors.lisp
```

`sc-imgui.asd`: in the `gui` module, after the `controls` module, add `(:module "editors" :serial t :components (...))` with the files above in the order listed. Each task adds its own files to that list when it creates them.

---

### Task 1: Grid theme roles and the `editors` suite

**Files:**
- Modify: `src/gui/theme.lisp` (`*palette-roles*`, both shipped themes), `tests/test-theme.lisp`, `tests/suites.lisp` (add `editors` to `define-suites`), `sc-imgui.asd` (add `test-editor-data` and `test-editors` test files after `test-controls`, both starting with `(in-package #:sc-imgui.tests) (in-suite editors)`)

**Interfaces:**
- Produces: `(gui:theme-color :grid-bar)`, `(gui:theme-color :grid-beat)`, `(gui:theme-color :grid-step)`.

- [ ] **Step 1: Write the failing tests in `tests/test-theme.lisp`**

```lisp
(test shipped-themes-define-grid-roles
  (loop for (theme bar beat step) in '((:mid-light "#4a4a4a" "#7f7f7f" "#9a9a9a")
                                       (:dark "#6a6a6a" "#3d3d3d" "#2a2a2a"))
        for palette = (gui::theme-palette (gui::find-theme theme))
        do (is (equal (rgba bar) (getf palette :grid-bar)))
           (is (equal (rgba beat) (getf palette :grid-beat)))
           (is (equal (rgba step) (getf palette :grid-step)))))

(test theme-without-base-needs-grid-roles
  (with-test-themes (:test-no-grid)
    (let ((palette (loop for (k v) on (gui::theme-palette (gui::find-theme :dark)) by #'cddr
                         unless (eq k :grid-beat) append (list k v))))
      (signals error (gui:define-theme :test-no-grid :palette palette)))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=theme`. Expected: FAIL; `:grid-bar` is missing from the palette.

- [ ] **Step 3: Add the roles** to `*palette-roles*` after `:error`, and to both shipped palettes with the values in the test.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=theme`, then `make test`. Expected: all pass, including the existing theme tests (their derived themes inherit through `:base`).

- [ ] **Step 5: Commit**

```bash
git add src/gui/theme.lisp tests/test-theme.lisp tests/suites.lisp tests/test-editor-data.lisp tests/test-editors.lisp sc-imgui.asd
git commit -m "feat: grid palette roles and the editors test suite"
```

---

### Task 2: Envelope values

**Files:**
- Create: `src/gui/editors/conditions.lisp`, `src/gui/editors/envelope.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Produces:
    - `gui:editor-data-error`, an `error` with reader `editor-data-error-problem` (a string). It reports as `"Invalid editor data: <problem>"`. Signal it with the internal `(data-error format-string &rest args)`.
    - The `envelope` struct (read-only slots: `levels`, `times`, `curves`, `release-node`, `loop-node`). `gui:envelope-p`.
    - `(gui:make-envelope levels times &key (curves :lin) release-node loop-node)`. Every copy and constructor below goes through it. It does the following:
        - Validates against the spec's Errors section.
        - Normalizes aliases: `:linear`→`:lin`, `:exponential`→`:exp`, `:sin`→`:sine`, `:wel`→`:welch`, `:cub`→`:cubed`.
        - Expands a single curve to a list of n−1.
        - Replaces a level of exactly 0 that is an endpoint of an `:exp` segment with `0.00001` (`+exp-floor+`).
        - Stores levels and times as lists of reals.
    - Readers: `gui:envelope-levels`, `gui:envelope-times`, `gui:envelope-curves`, `gui:envelope-release-node`, `gui:envelope-loop-node`, `gui:envelope-duration`. Each returns a fresh list.
    - `(gui:envelope-env-args e)` → `(list levels times curves release-or--99 loop-or--99)`.
    - `(gui:envelope-env e)` → `(apply cl-collider:env (envelope-env-args e))`. It finds the symbol with `(find-symbol "ENV" "CL-COLLIDER")`. With no package, or the symbol not fbound, it signals `editor-data-error` with problem `"cl-collider isn't loaded"`.
    - Copies:
        - `gui:envelope-with-level e i level`
        - `gui:envelope-with-time e i time`, where segment `i` runs from point `i` to `i+1`
        - `gui:envelope-with-curve e i curve`
        - `gui:envelope-with-release-node e node-or-nil`
        - `gui:envelope-with-loop-node e node-or-nil`
    - Internal: `(envelope-insert-point e time level)` → new envelope:
        - The point is inserted at absolute `time`.
        - Inside a segment, that segment is split. Both halves keep its curve, and node indexes after the new point go up by 1.
        - Past the end, the point is appended with the last segment's curve.
    - Internal: `(envelope-delete-point e i)` → new envelope:
        - Merges the two segments either side of the point. Their times add, and the earlier segment's curve is kept. Deleting point 0 drops segment 0.
        - A node on the deleted point is cleared; clearing the release node also clears the loop node.
        - Later node indexes go down by 1.
        - Fewer than 2 points remaining is an `editor-data-error`.
    - Constructors `gui:envelope-triangle`, `-sine`, `-perc`, `-linen`, `-cutoff`, `-dadsr`, `-adsr`, `-asr` take `&optional` arguments with the spec table's defaults. Their levels and times are as in cl-collider's `EnvGen.lisp`:
        - triangle and sine: `(0 level 0)`, times `(dur/2 dur/2)`.
        - perc: `(0 level 0)`.
        - linen: `(0 level level 0)`.
        - cutoff: `(level 0)`, release node 0, so the `:exp` substitution happens through `make-envelope`.
        - dadsr: `(0 0 peak peak×sustain 0)` + bias.
        - adsr: `(0 peak peak×sustain 0)` + bias.
        - asr: `(0 sustain 0)`.

- [ ] **Step 1: Write the failing tests in `tests/test-editor-data.lisp`**

```lisp
(test envelope-normalizes-and-validates
  (let ((e (gui:make-envelope '(0 1 0) '(0.1 0.5) :curves :linear)))
    (is (equal '(:lin :lin) (gui:envelope-curves e)))
    (is (= 0.6 (gui:envelope-duration e))))
  (is (equal '(:sine :welch :cubed :exp)
             (gui:envelope-curves (gui:make-envelope '(1 1 1 1 1) '(1 1 1 1)
                                                     :curves '(:sin :wel :cub :exponential)))))
  (dolist (bad '((() ()) ((0 1) (1 2)) ((0 1) (-1)) ((0 1) (1) :curves :squared)
                 ((0 1) (1) :release-node 2) ((0 1 0) (1 1) :release-node 1 :loop-node 1)
                 ((0 1 0) (1 1) :release-node 0 :loop-node 1)))
    (signals gui:editor-data-error (apply #'gui:make-envelope bad))))

(test exp-zero-becomes-floor
  (is (equal '(1 0.00001) (gui:envelope-levels (gui:envelope-cutoff 0.1 1 :exp))))
  (is (equal '(1 0) (gui:envelope-levels (gui:envelope-cutoff 0.1 1 :lin)))))

(test constructors-match-cl-collider
  (flet ((args (e) (gui:envelope-env-args e)))
    (is (equal '((0 1.0 0) (0.5 0.5) (:lin :lin) -99 -99) (args (gui:envelope-triangle))))
    (is (equal '((0 1.0 0) (0.5 0.5) (:sine :sine) -99 -99) (args (gui:envelope-sine))))
    (is (equal '((0 1.0 0) (0.01 1.0) (-4.0 -4.0) -99 -99) (args (gui:envelope-perc))))
    (is (equal '((0 1.0 1.0 0) (0.01 1.0 1.0) (:lin :lin :lin) -99 -99) (args (gui:envelope-linen))))
    (is (equal '((1.0 0) (0.1) (:lin) 0 -99) (args (gui:envelope-cutoff))))
    (is (equal '((0.0 0.0 1.0 0.5 0.0) (0.1 0.01 0.3 1.0) (-4.0 -4.0 -4.0 -4.0) 3 -99)
               (args (gui:envelope-dadsr))))
    (is (equal '((0.0 1.0 0.5 0.0) (0.01 0.3 1.0) (-4.0 -4.0 -4.0) 2 -99) (args (gui:envelope-adsr))))
    (is (equal '((0 1.0 0) (0.01 1.0) (-4.0 -4.0) 1 -99) (args (gui:envelope-asr))))))

(test envelope-env-calls-cl-collider
  (signals gui:editor-data-error (gui:envelope-env (gui:envelope-adsr)))   ; no CL-COLLIDER package
  (let ((pkg (make-package "CL-COLLIDER" :use '())))
    (unwind-protect
         (progn
           (setf (fdefinition (intern "ENV" pkg)) (lambda (&rest args) (cons :env args)))
           (is (equal (cons :env (gui:envelope-env-args (gui:envelope-adsr)))
                      (gui:envelope-env (gui:envelope-adsr)))))
      (delete-package pkg))))

(test insert-and-delete-points-keep-nodes
  (let* ((e (gui:envelope-adsr))                         ; points at 0, 0.01, 0.31, 1.31
         (e2 (gui::envelope-insert-point e 0.11 0.7)))
    (is (= 5 (length (gui:envelope-levels e2))))
    (is (= 3 (gui:envelope-release-node e2)))
    (is (every (lambda (a b) (< (abs (- a b)) 1e-5))
               '(0.01 0.1 0.2 1.0) (gui:envelope-times e2)))
    (let ((e3 (gui::envelope-delete-point e2 3)))       ; delete the release point
      (is (null (gui:envelope-release-node e3)))
      (is (= 4 (length (gui:envelope-levels e3)))))
    (signals gui:editor-data-error
      (gui::envelope-delete-point (gui:make-envelope '(0 1) '(1)) 0))))
```

(Exact float tests: write the expected constructor values to match what `make-envelope` stores for the given arguments, e.g. `(* 1.0 0.5)` = `0.5`. If SBCL's float printing differs, compare with `=` element by element rather than `equal`.)

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=editors`. Expected: FAIL; `gui:make-envelope` undefined.

- [ ] **Step 3: Implement `conditions.lisp` and `envelope.lisp`, and export the names**

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=editors`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: envelope values with cl-collider constructors"
```

---

### Task 3: Curve shapes

**Files:**
- Create: `src/gui/editors/curves.lisp`
- Modify: `sc-imgui.asd`, `tests/test-editor-data.lisp`

**Interfaces:**
- Produces:
    - `(curve-level curve y1 y2 pos)` → the level at `pos` ∈ [0, 1] of a segment from `y1` to `y2`. Never signals for finite input.
    - `(envelope-level-at e time)` → the level at absolute `time`, clamped to the envelope's span.
    - `(envelope-point-times e)` → absolute time of each point, starting at 0.

Formulas, from SuperCollider (cl-collider's `EnvGen.lisp` interpolation functions):

| Curve | Level at `pos` |
| --- | --- |
| `:step` | `y2` for `pos` > 0, else `y1` |
| `:hold` | `y1` for `pos` < 1, else `y2` |
| `:lin` | `y1 + (y2 − y1)·pos` |
| `:exp` | `y1·(y2/y1)^pos`, but linear when `y1` or `y2` is 0 or they differ in sign |
| `:sine` | `y1 + (y2 − y1)·(0.5 − 0.5·cos(π·pos))` |
| `:welch` | if `y1 < y2`: `y1 + (y2 − y1)·sin(π/2·pos)`, else `y2 − (y2 − y1)·sin(π/2·(1 − pos))` |
| `:sqr` | `(√y1 + (√y2 − √y1)·pos)²`, using `|y|` under the root |
| `:cubed` | `(∛y1 + (∛y2 − ∛y1)·pos)³`, with a sign-preserving cube root |
| number `c` | linear if `|c|` < 0.0001, else `y1 + (y2 − y1)·(1 − e^(c·pos)) / (1 − e^c)` |

- [ ] **Step 1: Write the failing tests**

```lisp
(test curve-shapes-match-supercollider
  (flet ((near (a b) (< (abs (- a b)) 1e-4)))
    (is (near 0.5 (gui::curve-level :lin 0 1 0.5)))
    (is (near 0.1 (gui::curve-level :exp 0.01 1 0.5)))
    (is (near 0.5 (gui::curve-level :sine 0 1 0.5)))
    (is (near (sin (/ pi 4)) (gui::curve-level :welch 0 1 0.5)))
    (is (near 0.25 (gui::curve-level :sqr 0 1 0.5)))
    (is (near 0.125 (gui::curve-level :cubed 0 1 0.5)))
    (is (near (/ (- 1 (exp -2.0)) (- 1 (exp -4.0))) (gui::curve-level -4 0 1 0.5)))
    (is (near 0.5 (gui::curve-level 0.00001 0 1 0.5)))
    (is (= 1 (gui::curve-level :step 0 1 0.01)))
    (is (= 0 (gui::curve-level :hold 0 1 0.99)))))

(test exp-across-zero-is-linear                        ; Review Focus 4
  (is (= 0.0 (gui::curve-level :exp -1 1 0.5)))
  (is (= 0.5 (gui::curve-level :exp 0 1 0.5))))

(test envelope-level-at-follows-segments
  (let ((e (gui:make-envelope '(0 1 0) '(1 1))))
    (is (equal '(0 1 2) (gui::envelope-point-times e)))
    (is (= 0.5 (gui::envelope-level-at e 0.5)))
    (is (= 0 (gui::envelope-level-at e 5)))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`. Expected: FAIL; `curve-level` undefined.

- [ ] **Step 3: Implement `curves.lisp`.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/curves.lisp sc-imgui.asd tests/test-editor-data.lisp
git commit -m "feat: SuperCollider envelope curve shapes"
```

---

### Task 4: Pattern timing and drum patterns

**Files:**
- Create: `src/gui/editors/pattern.lisp`, `src/gui/editors/drum-pattern.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Consumes: `data-error` (Task 2).
- Produces:
    - `pattern`: an abstract struct (`(:constructor nil)`) with read-only slots `bars`, `bar-length`, `step-resolution`, `length`. The slot readers are the exported `gui:pattern-bars`, `gui:pattern-bar-length`, `gui:pattern-step-resolution`, `gui:pattern-length`.
    - `gui:pattern-steps-per-bar` and `gui:pattern-max-steps` (capacity).
    - `(gui:pattern-step-position p step)` → `(values bar beat step-in-beat)`, counted from 1.
    - `(check-timing bars bar-length step-resolution length)` → the length to store (capacity when `length` is nil). It signals `editor-data-error` per the spec.
    - `(gui:pattern-with-length p length)`, a generic over the pattern kinds that copies with a new length.
    - `drum-pattern` includes `pattern`, with read-only slots:
        - `row-names`: a list.
        - `velocities`: a `(simple-array single-float (rows capacity))`.
        - `gates`: an array of the same shape, or nil.
    - `(gui:make-drum-pattern &key (rows 8) (bars 1) (bar-length 4) (step-resolution 4) length gates)`. New gates are 0.5.
    - `gui:drum-pattern-p`, `gui:drum-pattern-rows` (the count), `gui:drum-row-names` (a fresh list), `gui:drum-pattern-gates-p`.
    - `(gui:drum-step p row step)` → velocity, and `(gui:drum-gate p row step)` → gate or nil. Both signal `editor-data-error` for an index out of range.
    - `(gui:drum-row-index p name)` compares with `equal`.
    - `(gui:drum-pattern-with-step p row step velocity &key (gate nil gate-p))`. On a gated pattern, a missing gate means 0.5.
    - Internal: `(drum-pattern-with-cells p cells)`, a bulk copy. `cells` is a list of `(row step velocity gate)`; a nil gate keeps the cell's current gate. Selection operations build on it.

- [ ] **Step 1: Write the failing tests**

```lisp
(test timing-capacity-and-positions
  (let ((p (gui:make-drum-pattern :bars 2 :bar-length 5 :step-resolution 4)))
    (is (= 40 (gui:pattern-max-steps p) (gui:pattern-length p)))
    (is (= 20 (gui:pattern-steps-per-bar p)))
    (is (equal '(1 1 1) (multiple-value-list (gui:pattern-step-position p 0))))
    (is (equal '(2 3 2) (multiple-value-list (gui:pattern-step-position p 29))))
    (is (= 12 (gui:pattern-length (gui:pattern-with-length p 12))))
    (is (= 40 (gui:pattern-length p))))
  (dolist (bad '((:bars 0) (:bar-length -1) (:step-resolution 1.5) (:length 0) (:length 17)))
    (signals gui:editor-data-error (apply #'gui:make-drum-pattern bad))))

(test drum-cells-rows-and-gates
  (let* ((p (gui:make-drum-pattern :rows '(:kick "snare" 3)))
         (p2 (gui:drum-pattern-with-step p 1 4 0.5)))
    (is (= 3 (gui:drum-pattern-rows p)))
    (is (equal '(:kick "snare" 3) (gui:drum-row-names p)))
    (is (= 1 (gui:drum-row-index p "snare")))
    (signals gui:editor-data-error (gui:drum-row-index p :hat))
    (is (= 0 (gui:drum-step p 1 4)))
    (is (= 0.5 (gui:drum-step p2 1 4)))
    (is (null (gui:drum-gate p2 1 4)))
    (signals gui:editor-data-error (gui:drum-pattern-with-step p 0 0 1.0 :gate 2))
    (signals gui:editor-data-error (gui:drum-pattern-with-step p 0 0 1.5)))
  (is (equal '(0 1 2 3) (gui:drum-row-names (gui:make-drum-pattern :rows 4))))
  (signals gui:editor-data-error (gui:make-drum-pattern :rows '(:a :a)))
  (let ((g (gui:drum-pattern-with-step (gui:make-drum-pattern :gates t) 0 0 1.0 :gate 2.5)))
    (is (gui:drum-pattern-gates-p g))
    (is (= 2.5 (gui:drum-gate g 0 0)))
    (signals gui:editor-data-error (gui:drum-pattern-with-step g 0 0 1.0 :gate 0))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `pattern.lisp` and `drum-pattern.lisp`, and export the names.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: pattern timing and drum patterns"
```

---

### Task 5: Melodic patterns, note names, and scales

**Files:**
- Create: `src/gui/editors/melodic-pattern.lisp`, `src/gui/editors/notes.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Consumes: `pattern`, `check-timing` (Task 4).
- Produces:
    - Steps:
        - The `note-step` struct, with `:conc-name step-` and read-only slots `note`, `velocity`, `gate`, `on`.
        - `(gui:make-step note &key (velocity 0.8) (gate 0.5) (on t))` validates per the spec. The note must be an integer from 0 to 127.
        - Readers: `gui:step-note`, `gui:step-velocity`, `gui:step-gate`, and `gui:step-on-p` (which reads `on`).
        - Internal: `(step-with s &key note velocity gate on)`, a validated copy.
    - Patterns:
        - `melodic-pattern` includes `pattern`, with a read-only `steps` slot (a simple-vector of `note-step` or nil).
        - `(gui:make-melodic-pattern &key (bars 1) (bar-length 4) (step-resolution 4) length)`, and `gui:melodic-pattern-p`.
        - `(gui:melodic-step p i)` and `(gui:melodic-pattern-with-step p i step-or-nil)`.
        - Internal: `(melodic-pattern-with-steps p alist)`, a bulk copy where `alist` is `((i . step-or-nil) …)`.
    - Note names:
        - `(note-name n)` → `"C4"` for 60, using sharps: `C C# D D# E F F# G G# A A# B`. Octave is `floor(n/12) − 1`.
        - `(parse-note-name string)` → `(values note ok)`. It accepts note names in any case, with `#` or `b` and an octave that may be negative (`c-1`), or a plain integer. Results outside 0–127 are not ok.
    - Scales:
        - `*scales*` is a plist: `:major (0 2 4 5 7 9 11)`, `:minor (0 2 3 5 7 8 10)`, `:dorian (0 2 3 5 7 9 10)`, `:mixolydian (0 2 4 5 7 9 10)`, `:pentatonic (0 2 4 7 9)`, `:minor-pentatonic (0 3 5 7 10)`, `:blues (0 3 5 6 7 10)`, `:chromatic (0 1 … 11)`.
        - `(scale-intervals scale)` signals `editor-data-error` for an unknown name or a bad list.
        - `(gui:scale-note-p note scale root)` → generalized boolean.
        - `(scale-transpose note degrees scale root)` → the note moved by `degrees` scale notes. A note not in the scale first snaps to the nearest scale note in the direction of the move.
    - Row labels:
        - `(row-label name)` → display string. Strings as written, numbers with `princ`, symbols as `(string-downcase (symbol-name name))`.
        - `(melodic-row-label note low row-names)` → the entry at `note − low` when that is in range and non-nil, else `(note-name note)`.

- [ ] **Step 1: Write the failing tests**

```lisp
(test melodic-steps-and-patterns
  (let* ((s (gui:make-step 60))
         (p (gui:melodic-pattern-with-step (gui:make-melodic-pattern) 3 s)))
    (is (= 0.8 (gui:step-velocity s)))
    (is (gui:step-on-p s))
    (is (eq s (gui:melodic-step p 3)))
    (is (null (gui:melodic-step p 2))))
  (dolist (bad '((60.5) (128) (60 :velocity 2) (60 :gate 0)))
    (signals gui:editor-data-error (apply #'gui:make-step bad))))

(test note-names
  (is (string= "C4" (gui::note-name 60)))
  (is (string= "A#-1" (gui::note-name 10)))
  (loop for (text note) in '(("C#3" 49) ("eb4" 63) ("60" 60) ("c-1" 0) ("G9" 127))
        do (is (equal (list note t) (multiple-value-list (gui::parse-note-name text)))))
  (dolist (bad '("H2" "C" "" "128" "G#9"))
    (is (null (nth-value 1 (gui::parse-note-name bad))))))

(test scales
  (is (gui:scale-note-p 64 :major 60))
  (is (not (gui:scale-note-p 61 :major 60)))
  (is (gui:scale-note-p 63 '(0 3 7) 48))
  (is (= 67 (gui::scale-transpose 64 2 :major 60)))
  (is (= 62 (gui::scale-transpose 61 1 :major 60)))
  (signals gui:editor-data-error (gui:scale-note-p 60 :lydian-dominant 60)))

(test row-labels
  (is (equal '("kick" "Snare" "3") (mapcar #'gui::row-label '(:kick "Snare" 3))))
  (is (string= "root" (gui::melodic-row-label 60 60 '("root"))))
  (is (string= "C#4" (gui::melodic-row-label 61 60 '("root" nil))))
  (is (string= "D4" (gui::melodic-row-label 62 60 #("root")))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement both files and export the names.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: melodic patterns, note names and scales"
```

---

### Task 6: Timing remaps

**Files:**
- Create: `src/gui/editors/remap.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Consumes: the pattern structs and bulk copies (Tasks 4 and 5).
- Produces: `gui:pattern-with-bars`, `gui:pattern-with-bar-length`, and `gui:pattern-with-step-resolution`. Each takes `p` and a positive integer, and is generic over both kinds.

Rules. "Earlier wins" means steps are processed in ascending order and a target that's already taken is skipped; for drums this applies per row.

- **`with-bars`:** step indexes are unchanged. Steps at or past the new capacity are dropped.
- **`with-bar-length`:**
    - Each step keeps its bar and its position in the bar. Step `s` maps to `bar·(b'·r) + (s mod (b·r))`.
    - Steps whose position in the bar is past the new bar length are dropped.
    - The length maps the same way, clamped to the bar's end and to [1, capacity].
- **`with-step-resolution`:**
    - Step `s` maps to `round-half-down(s·r'/r)`, where `round-half-down(x) = ceiling(x − 1/2)`. Collisions follow "earlier wins".
    - The length maps the same way, clamped to [1, capacity].
    - Gates (melodic, and gated drum) are multiplied by `r'/r`.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun %melodic (notes &rest timing)
  "A melodic pattern with NOTES, ((step note) ...), and TIMING keywords."
  (let ((p (apply #'gui:make-melodic-pattern timing)))
    (loop for (i n) in notes
          do (setf p (gui:melodic-pattern-with-step p i (gui:make-step n :gate 1))))
    p))

(defun %notes (p)
  (loop for i below (gui:pattern-max-steps p)
        for s = (gui:melodic-step p i)
        when s collect (list i (gui:step-note s))))

(test remap-step-resolution
  (let ((p (%melodic '((0 60) (1 61) (2 62) (3 63) (4 64)) :step-resolution 4)))
    (is (equal '((0 60) (2 61) (4 62) (6 63) (8 64)) (%notes (gui:pattern-with-step-resolution p 8))))
    (is (= 2.0 (gui:step-gate (gui:melodic-step (gui:pattern-with-step-resolution p 8) 2))))
    ;; 4 -> 3 per beat: 1 -> 0.75 -> 1, 2 -> 1.5 -> 1 (tie: earlier, and taken: dropped), 3 -> 2.25 -> 2
    (is (equal '((0 60) (1 61) (2 63) (3 64)) (%notes (gui:pattern-with-step-resolution p 3))))
    (is (= 0.75 (gui:step-gate (gui:melodic-step (gui:pattern-with-step-resolution p 3) 1))))))

(test remap-bar-length-keeps-bar-positions
  (let* ((p (%melodic '((0 60) (3 63) (4 64) (7 67)) :bars 2 :bar-length 2 :step-resolution 2))
         (q (gui:pattern-with-bar-length p 3)))       ; bars of 4 steps -> 6 steps
    (is (equal '((0 60) (3 63) (6 64) (9 67)) (%notes q)))
    (is (= 12 (gui:pattern-length q)))
    (is (equal '((0 60) (2 64)) (%notes (gui:pattern-with-bar-length p 1))))))

(test remap-bars-and-length
  (let ((p (gui:pattern-with-length (%melodic '((0 60) (15 75)) :bars 2 :bar-length 2) 10)))
    (is (equal '((0 60)) (%notes (gui:pattern-with-bars p 1))))
    (is (= 8 (gui:pattern-length (gui:pattern-with-bars p 1))))
    (is (equal '((0 60) (15 75)) (%notes (gui:pattern-with-bars p 3))))
    (is (= 10 (gui:pattern-length (gui:pattern-with-bars p 3))))))

(test remap-drum-gates-per-row
  (let* ((p (gui:drum-pattern-with-step (gui:make-drum-pattern :rows 2 :gates t) 1 1 0.7 :gate 1.0))
         (q (gui:pattern-with-step-resolution p 8)))
    (is (= 0.7 (gui:drum-step q 1 2)))
    (is (= 2.0 (gui:drum-gate q 1 2)))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `remap.lisp` and export the names.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/remap.lisp sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: musical remapping when pattern timing changes"
```

---

### Task 7: `pattern-events`

**Files:**
- Create: `src/gui/editors/events.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Produces: `(gui:pattern-events p step &key include-muted)`, generic over both kinds.
    - The result is described in the spec's "Reading a whole step" section.
    - Keys come in the spec's order: drum `:row :name :velocity [:gate]`; melodic `:note :velocity :gate [:on nil]`.
    - Velocities and gates are the stored numbers.
    - `step` must be an integer. It is taken with `(mod step length)`, so negative counters wrap too.

- [ ] **Step 1: Write the failing tests**

```lisp
(test drum-events
  (let ((p (gui:drum-pattern-with-step
            (gui:drum-pattern-with-step (gui:make-drum-pattern :rows '(:kick :snare :hat) :length 8)
                                        2 1 0.6)
            0 1 1.0)))
    (is (equal '((:row 0 :name :kick :velocity 1.0) (:row 2 :name :hat :velocity 0.6))
               (gui:pattern-events p 1)))
    (is (equal (gui:pattern-events p 1) (gui:pattern-events p 9)))
    (is (null (gui:pattern-events p 2)))
    (is (not (eq (gui:pattern-events p 1) (gui:pattern-events p 1)))))
  (let ((g (gui:drum-pattern-with-step (gui:make-drum-pattern :rows 1 :gates t) 0 0 1.0 :gate 1.5)))
    (is (equal '((:row 0 :name 0 :velocity 1.0 :gate 1.5)) (gui:pattern-events g 0)))))

(test melodic-events-and-mutes
  (let ((p (gui:melodic-pattern-with-step
            (gui:melodic-pattern-with-step (gui:make-melodic-pattern) 0 (gui:make-step 60))
            1 (gui:make-step 62 :on nil))))
    (is (equal '((:note 60 :velocity 0.8 :gate 0.5)) (gui:pattern-events p 0)))
    (is (null (gui:pattern-events p 1)))
    (is (equal '((:note 62 :velocity 0.8 :gate 0.5 :on nil))
               (gui:pattern-events p 1 :include-muted t)))
    (is (equal (gui:pattern-events p 0) (gui:pattern-events p -16)))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `events.lisp` and export the name.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/events.lisp sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: pattern-events reads everything at a step"
```

---

### Task 8: Selections, clipboard, moving, and toggling (pure)

**Files:**
- Create: `src/gui/editors/selection.lisp`
- Modify: `sc-imgui.asd`, `tests/test-editor-data.lisp`

**Interfaces:**
- Consumes: the bulk copies (Tasks 4 and 5), `scale-transpose` (Task 5).
- Produces. Selections are sorted lists without duplicates:
    - A drum selection holds `(row . step)` conses, which may be empty cells.
    - A melodic selection holds step indexes, always of non-empty steps.
- Generic functions, specialized on `drum-pattern` and `melodic-pattern`:
    - `(selection-elements-in p rows steps)`, where `rows` and `steps` are inclusive `(lo . hi)` ranges in pattern coordinates (drum row indexes, or MIDI notes for melodic). Drum gives every cell in the rectangle; melodic gives steps whose note lies in the note range.
    - `(selection-all p)`. Drum gives every set cell; melodic gives every non-empty step.
    - `(selection-valid p sel)` → `sel` with entries out of range, or (melodic) now empty, removed.
    - `(selection-copy p sel)` → a `clip` struct:
        - `kind`: `:drum` or `:melodic`.
        - `span`: last step − first step + 1, over the whole selection.
        - `entries`: `(row offset velocity gate)` for set drum cells only, or `(offset . note-step)`.
    - `(selection-clear p sel)` → `p'`.
    - `(clip-paste p clip at &key (default-gate 0.5))` → `(values p' new-sel)`:
        - Drum merges; melodic replaces whole steps.
        - Entries landing at or past capacity are skipped, and `new-sel` holds only what was pasted.
        - Drum gate conversion follows the spec: a missing gate becomes `default-gate`, and gates are dropped on an ungated pattern.
        - A clip of the other kind signals `editor-data-error`.
    - `(selection-duplicate p sel &key default-gate)`: `clip-paste` of the selection's copy at first step + span.
    - `(selection-move p sel dsteps &key (dpitch 0) copy (policy :clamp) scale root degrees)` → `(values p' sel')`:
        - First the delta is limited so every element stays within steps [0, capacity−1] and notes [0, 127]:
            - `:clamp` reduces the delta toward 0 until everything fits (dragging).
            - `:exact` returns `p` and `sel` unchanged unless the full delta fits (nudges).
        - The move itself:
            - Drum moves only in time.
            - Melodic moves in time and adds `dpitch`. With `degrees` (an integer), each note goes through `scale-transpose` instead of `dpitch`, and `:clamp` reduces `degrees` toward 0 until every note fits.
            - Sources are cleared unless `copy`, then the moved elements are written over their targets: drum merges, melodic replaces.
    - `(pattern-toggle p row-key step &key (velocity 1.0) (gate 0.5))` → `p'`. `row-key` is a drum row or a melodic note.
        - Drum: a set cell is cleared, otherwise it is set to `velocity` (and `gate` if gated).
        - Melodic: a step holding that note is emptied, otherwise the step is replaced by a new note.
- Globals: `*drum-clipboard*` and `*melodic-clipboard*`, both nil at load. `(clipboard-for p)` and `(setf (clipboard-for p) clip)` choose by kind.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun %drum (cells &rest args)
  "A drum pattern with CELLS, ((row step velocity) ...), and ARGS for make-drum-pattern."
  (let ((p (apply #'gui:make-drum-pattern args)))
    (loop for (r s v) in cells do (setf p (gui:drum-pattern-with-step p r s v)))
    p))

(defun %cells (p)
  (loop for r below (gui:drum-pattern-rows p)
        append (loop for s below (gui:pattern-max-steps p)
                     unless (zerop (gui:drum-step p r s)) collect (list r s (gui:drum-step p r s)))))

(test drum-paste-merges-keeps-rows-and-skips-overflow
  (let* ((p (%drum '((0 0 1.0) (1 2 0.5) (2 14 0.3)) :rows 3))
         (clip (gui::selection-copy p '((0 . 0) (1 . 1) (1 . 2)))))   ; (1 . 1) is empty
    (is (= 3 (gui::clip-span clip)))
    (multiple-value-bind (q sel) (gui::clip-paste p clip 13)
      (is (equal '((0 0 1.0) (0 13 1.0) (1 2 0.5) (1 15 0.5) (2 14 0.3)) (%cells q)))
      (is (equal '((0 . 13) (1 . 15)) sel)))
    (multiple-value-bind (q sel) (gui::clip-paste p clip 15)
      (is (equal '((0 . 15)) sel))
      (is (= 4 (length (%cells q)))))))

(test melodic-paste-replaces-and-wrong-kind-errors
  (let* ((p (%melodic '((0 60) (1 62) (4 70))))
         (clip (gui::selection-copy p '(0 1))))
    (multiple-value-bind (q sel) (gui::clip-paste p clip 4)
      (is (equal '((0 60) (1 62) (4 60) (5 62)) (%notes q)))
      (is (equal '(4 5) sel)))
    (signals gui:editor-data-error
      (gui::clip-paste (gui:make-drum-pattern) clip 0))))

(test drum-gate-conversion-on-paste
  (let* ((plain (%drum '((0 0 1.0))))
         (gated (gui:drum-pattern-with-step (gui:make-drum-pattern :gates t) 0 3 1.0 :gate 2.0)))
    (is (= 0.25 (gui:drum-gate (gui::clip-paste gated (gui::selection-copy plain '((0 . 0))) 0
                                                :default-gate 0.25)
                               0 0)))
    (let ((q (gui::clip-paste (gui:make-drum-pattern) (gui::selection-copy gated '((0 . 3))) 0)))
      (is (= 1.0 (gui:drum-step q 0 0)))
      (is (null (gui:drum-gate q 0 0))))))

(test moves-stop-at-edges
  (let ((p (%melodic '((1 60) (14 126)))))          ; capacity 16
    (multiple-value-bind (q sel) (gui::selection-move p '(1 14) 5)
      (is (equal '((2 60) (15 126)) (%notes q)))     ; clamped to +1
      (is (equal '(2 15) sel)))
    (multiple-value-bind (q sel) (gui::selection-move p '(1 14) 0 :dpitch 12 :policy :exact)
      (is (eq p q))
      (is (equal '(1 14) sel)))
    (is (equal '((1 61) (14 127)) (%notes (gui::selection-move p '(1 14) 0 :dpitch 12))))
    (is (equal '((0 60) (1 60) (14 126))
               (%notes (gui::selection-move p '(1) -1 :copy t))))))

(test duplicate-and-toggle
  (let ((p (%drum '((0 0 1.0) (0 1 0.5)))))
    (multiple-value-bind (q sel) (gui::selection-duplicate p '((0 . 0) (0 . 1)))
      (is (equal '((0 . 2) (0 . 3)) sel))
      (is (= 4 (length (%cells q)))))
    (is (= 0 (gui:drum-step (gui::pattern-toggle p 0 0) 0 0)))
    (is (= 0.9 (gui:drum-step (gui::pattern-toggle p 0 5 :velocity 0.9) 0 5))))
  (let ((m (%melodic '((0 60)))))
    (is (null (gui:melodic-step (gui::pattern-toggle m 60 0) 0)))
    (is (= 64 (gui:step-note (gui:melodic-step (gui::pattern-toggle m 64 0) 0))))))
```

(The clip's offsets are 0 and 2, so pasting at 13 lands on 13 and 15, which fit in a capacity of 16; pasting at 15 keeps only the first.)

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `selection.lisp`.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/selection.lisp sc-imgui.asd tests/test-editor-data.lisp
git commit -m "feat: selection, clipboard and move operations on patterns"
```

---

### Task 9: Editor state and undo

**Files:**
- Create: `src/gui/editors/editor-state.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editor-data.lisp`

**Interfaces:**
- Produces:
    - The `editor-state` struct. Every editor uses it; slots the envelope doesn't need stay nil.
        - Undo: `undo` and `redo` (lists of values, newest first), `last-written`, `gesture-start` (the value when the open gesture began, or nil).
        - Mode and selection: `mode` (`:select` or `:draw`, default `:select`), `selection`, `marker` (an insert step, default 0).
        - View: `scroll` (first visible row), `view` (the last frame's layout, for hit testing and tests).
        - `drag`: a plist describing the gesture in progress, owned by each editor.
        - `fit`: the frozen envelope view span.
    - `*editor-states*`: an `equal` hash table keyed by ImGui ID. It is never swept, and cleared only by `gui:clear-editor-history` (exported, which clears the table) and by the save hook (as `*control-states*` is).
    - `(editor-state id)` → get or create.
    - `+undo-limit+` = 100.
    - `(editor-sync state value)`:
        - Call it first each frame with the place's value.
        - If `last-written` is non-nil and not `eq` to `value`, the code's change is recorded:
            - The undo entry is `last-written`, or `gesture-start` if a gesture is open (which drops the gesture).
            - The redo list is cleared.
            - The function returns `:code-change`.
        - It always sets `last-written` to `value`.
    - `(editor-begin-gesture state value)` sets `gesture-start` unless a gesture is already open.
    - `(editor-end-gesture state value)`:
        - Closes the gesture. If `value` isn't `eq` to `gesture-start`, it pushes `gesture-start` onto `undo` and clears `redo`.
        - It sets `last-written` to `value`.
    - `(editor-commit state old new)` is a one-shot gesture.
    - `(editor-undo state current)` → the previous value, or nil when there's none; it pushes `current` onto `redo`. `(editor-redo state current)` mirrors it. Both set `last-written`.
    - `(editor-wrote state value)` sets `last-written`. Call it whenever an editor returns a changed value mid-gesture.
    - Both `undo` and `redo` are trimmed to `+undo-limit+`.
    - `*focused-editor*`: the ID of the editor last pressed in, or nil.

- [ ] **Step 1: Write the failing tests**

```lisp
(defmacro with-fresh-editor-states (() &body body)
  `(let ((gui::*editor-states* (make-hash-table :test 'equal))
         (gui::*focused-editor* nil))
     ,@body))

(test gestures-group-into-one-undo-step
  (with-fresh-editor-states ()
    (let ((s (gui::editor-state 1)))
      (gui::editor-sync s :a)
      (gui::editor-begin-gesture s :a)
      (gui::editor-wrote s :b)
      (gui::editor-sync s :b)
      (gui::editor-wrote s :c)
      (gui::editor-end-gesture s :c)
      (is (eq :a (gui::editor-undo s :c)))
      (is (null (gui::editor-undo s :a)))
      (is (eq :c (gui::editor-redo s :a))))))

(test code-change-ends-gesture                       ; Review Focus 2
  (with-fresh-editor-states ()
    (let ((s (gui::editor-state 1)))
      (gui::editor-sync s :a)
      (gui::editor-begin-gesture s :a)
      (gui::editor-wrote s :b)
      (is (eq :code-change (gui::editor-sync s :from-code)))
      (is (null (gui::editor-state-gesture-start s)))
      (is (eq :a (gui::editor-undo s :from-code))))))

(test code-change-clears-redo-and-limit-holds
  (with-fresh-editor-states ()
    (let ((s (gui::editor-state 1)))
      (gui::editor-sync s 0)
      (loop for i from 1 to 150 do (gui::editor-commit s (1- i) i))
      (is (= 100 (length (gui::editor-state-undo s))))
      (gui::editor-undo s 150)
      (gui::editor-sync s :code)
      (is (null (gui::editor-state-redo s)))
      (gui:clear-editor-history)
      (is (zerop (hash-table-count gui::*editor-states*))))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `editor-state.lisp` and export `clear-editor-history`.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/editor-state.lisp sc-imgui.asd src/gui/package.lisp tests/test-editor-data.lisp
git commit -m "feat: per-editor state and undo history"
```

---

### Task 10: Sequencer grid display and the drum grid's first draw

**Files:**
- Create: `src/gui/editors/grid.lisp`, `src/gui/editors/drum-grid.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/headless.lisp`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 4, 5, and 9; from the control core, `rem-px`, `control-color`, `control-shade`, `text-width`, `visible-label`, `wheel-steps`, and the wheel claim `set-item-key-owner-nil`.
- Produces:
    - The `grid-view` struct, built each frame and stored in `editor-state-view`, and in `*last-grid-view*` for tests. Slots:
        - `id`, `label`, `pattern`.
        - `row-keys`: a vector, top row first, of drum row indexes or MIDI notes.
        - `row-labels`: a vector of strings. `row-styles`: a vector of `:plain` `:alt` `:black` `:scale`.
        - `cell` (px), `visible` (rows shown), `scroll` (first row shown).
        - `visible-steps` (steps shown), `hscroll` (first step shown).
        - `x`, `y`: the item origin. `grid-x`, `grid-y`: the top-left of the cell area.
        - `label-width`, `ruler-height`, `header-height`, `lane-height` (0 for drums), `width`, `height`.
    - `(grid-begin id label pattern row-keys row-labels row-styles state &key cell visible-rows max-display-width (lane-height 0) keyboard)` → view. It works out the layout and reserves the whole item with `invisible-button`.
    - Layout:
        - Header: height `(%imgui:get-frame-height)`.
        - Ruler: 1.2 rem.
        - Label column: the widest label + 0.75 rem, at least 2.5 rem, plus 0.75 rem for the keyboard strip when `keyboard`.
        - Cells: `visible-steps` × cell wide, by `visible` rows. `visible-steps` is `(min bars max-display-width) × steps-per-bar`, or the capacity when `max-display-width` is nil.
        - A vertical scrollbar 0.62 rem wide when there are more rows than `visible`.
        - Then the lane, then a horizontal scrollbar 0.62 rem high when `visible-steps` < capacity.
        - `visible` is `(min visible-rows total)`, with `visible-rows` nil meaning all.
    - Hit testing and geometry:
        - `(grid-cell-at view mx my)` → `(values row-pos step)` for the cell area, else nil. `row-pos` counts from 0 at the top of all rows, and `step` from 0 at the start of the pattern; both include the scroll offsets.
        - `(grid-cell-rect view row-pos step)` → `(values x1 y1 x2 y2)` in screen pixels, or nil when the row or the step is scrolled out.
        - `(grid-step-x view step)` → the screen x of a step boundary, used by the ruler, lane, end marker, and playhead. Anything outside the cell area is clipped.
        - `(grid-ruler-step view mx)` → the nearest step boundary, 0 to capacity.
        - Tests use `(grid-cell-center view row-pos step)`.
    - Drawing:
        - `(draw-grid view state &key playhead)` draws the background, beat shading, row styles, lines, row labels, ruler (bar numbers and beat labels), playhead column, length dimming, end marker, and scrollbar, all clipped to the item.
        - `(draw-grid-header view state)` draws the label, the timing text, and the pencil toggle. It returns true when the pencil was clicked.
        - Timing text: `"~D bar~:P · ~D beat~:P · ~D step~:P"`, with `·` being U+00B7.
        - Beat labels: `"N"` at a bar start, `"N.B"` otherwise, dropped when wider than the beat less 0.25 rem. Bar labels are thinned to every k-th bar, the smallest k that fits.
    - Scrolling, in `(grid-scroll view state)`:
        - The wheel scrolls one row per notch, using `wheel-steps` for fractions.
        - It claims the wheel only when the grid scrolls.
        - The scrollbar thumb can be dragged.
        - The scroll is clamped to [0, total − visible].
        - Horizontal: `io.mouse-wheel-h`, or the vertical wheel with Shift, scrolls by one step per notch, using `wheel-steps`, and the horizontal thumb can be dragged. `hscroll` is clamped to [0, capacity − visible-steps], and the wheel is claimed only when the grid scrolls that way. (Task 14 adds the exception over a selected melodic note.)
    - `gui:drum-grid` (a macro, via `define-place-widget`) and `(gui:drum-grid-value label value &key (cell 1.25) visible-rows max-display-width playhead (default-velocity 1.0) (default-gate 0.5))` → `(values new changed-p)`. In this task it only checks its arguments, syncs undo state, and draws; it never changes the value.
    - Argument checks:
        - `widget-value-error` unless the value is a `drum-pattern`.
        - `control-spec-error` for a bad `visible-rows` or `max-display-width` (not a positive integer), `cell` (via `check-control-sizes`), or `playhead` (not an integer or nil), and for a `default-velocity` outside (0, 1] or a `default-gate` not above 0.
    - Drum cell drawing:
        - Background `:frame`. Alternate beats use `(control-shade :frame -0.04)`.
        - Set cells: `:accent` at alpha `0.25 + 0.75·velocity`, inset 1 px. Gated cells are as wide as their gate, cut at the next set cell in the row.
        - Selected cells are outlined in `:text`, 2 px.
        - Lines: step lines `:grid-step`, beat lines `:grid-beat`, bar lines `:grid-bar`.
        - Steps past the length are overlaid with `:background` at alpha 0.35.
        - Playhead: `:accent` at alpha 0.2 over the column `(mod playhead length)`.
        - End marker: an `:accent` triangle in the ruler at the length.
- Harness, in `tests/headless.lisp`:
    - `:alt` in `%modifier-key` → `%imgui:+mod-alt+`.
    - `(frames-with-right-click x y draw-fn)`.
    - `(drag-through points draw-fn)`: move to the first point, press, move through the rest (one frame each), release.

- [ ] **Step 1: Write the failing tests in `tests/test-editors.lisp`**

```lisp
(defmacro with-editors-env (() &body body)
  `(with-controls-env ()
     (with-fresh-editor-states () ,@body)))

(defun draw-drum (p &rest args)
  (lambda () (in-window (apply #'gui:drum-grid-value "Kit" p args))))

(test drum-grid-size-follows-visible-rows-and-cell
  (with-editors-env ()
    (let ((p (gui:make-drum-pattern :rows 8)))
      (dotimes (i 2) (with-test-frame () (funcall (draw-drum p :visible-rows 4))))
      (let ((v gui::*last-grid-view*))
        (is (= 4 (gui::grid-view-visible v)))
        (is (< (abs (- (gui::grid-view-cell v) (gui::rem-px 1.25))) 0.01))
        (is (< (abs (- (* 16 (gui::rem-px 1.25))
                       (- (gui::grid-view-width v) (gui::grid-view-label-width v)
                          (gui::rem-px 0.62))))
               1))))
      (dotimes (i 2) (with-test-frame () (funcall (draw-drum (gui:make-drum-pattern :rows 3)
                                                             :visible-rows 10))))
      (is (= 3 (gui::grid-view-visible gui::*last-grid-view*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test drum-grid-wheel-scrolls-rows
  (with-editors-env ()
    (let ((p (gui:make-drum-pattern :rows 8)) (draw nil))
      (setf draw (draw-drum p :visible-rows 4))
      (dotimes (i 2) (with-test-frame () (funcall draw)))
      (multiple-value-bind (x y) (gui::grid-cell-center gui::*last-grid-view* 0 0)
        (frames-with-wheel x y -3 draw))
      (is (= 3 (gui::editor-state-scroll (gui::editor-state (gui::grid-view-id gui::*last-grid-view*)))))
      (multiple-value-bind (x y) (gui::grid-cell-center gui::*last-grid-view* 3 0)
        (frames-with-wheel x y -5 draw))
      (is (= 4 (gui::editor-state-scroll (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test drum-grid-draws-everything-without-changing-the-value
  (with-editors-env ()
    (let* ((p (gui:pattern-with-length
               (%drum '((0 0 1.0) (1 3 0.2)) :rows '(:kick "snare") :bars 2 :gates t) 20))
           (results (loop repeat 3 collect
                          (with-test-frame () (multiple-value-list
                                               (funcall (draw-drum p :playhead 37)))))))
      (is (every (lambda (r) (and (eq p (first r)) (null (second r)))) results)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test drum-grid-argument-errors
  (with-editors-env ()
    (signals gui:widget-value-error (with-test-frame () (funcall (draw-drum (gui:make-melodic-pattern)))))
    (dolist (args '((:visible-rows 0) (:playhead 1.5) (:cell -1) (:default-velocity 0)))
      (signals gui:control-spec-error
        (with-test-frame () (funcall (apply #'draw-drum (gui:make-drum-pattern) args)))))))

(test max-display-width-scrolls-horizontally
  (with-editors-env ()
    (let* ((p (gui:make-drum-pattern :bars 4)) (draw (draw-drum p :max-display-width 2)))
      (dotimes (i 2) (with-test-frame () (funcall draw)))
      (let ((v gui::*last-grid-view*))
        (is (= 32 (gui::grid-view-visible-steps v)))
        (multiple-value-bind (x y) (gui::grid-cell-center v 0 4)
          (frames-with-wheel x y -10 draw :horizontal t)
          (is (= 10 (gui::grid-view-hscroll gui::*last-grid-view*)))
          (is (equal '(0 14) (multiple-value-list (gui::grid-cell-at gui::*last-grid-view* x y)))))
        (is (null (gui::grid-cell-rect gui::*last-grid-view* 0 0))))
      (dotimes (i 2) (with-test-frame () (funcall (draw-drum (gui:make-drum-pattern :bars 1)
                                                             :max-display-width 2))))
      (is (= 16 (gui::grid-view-visible-steps gui::*last-grid-view*)))
      (signals gui:control-spec-error
        (with-test-frame () (funcall (draw-drum p :max-display-width 0)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test header-timing-text
  (is (string= "2 bars · 5 beats · 4 steps" (gui::timing-text (gui:make-drum-pattern :bars 2 :bar-length 5))))
  (is (string= "1 bar · 1 beat · 1 step"
               (gui::timing-text (gui:make-drum-pattern :bar-length 1 :step-resolution 1)))))
```

(`timing-text` is the header text helper. `with-controls-env` is in `tests/test-controls.lisp`, which loads first. `with-fresh-editor-states` and `%drum` are in `tests/test-editor-data.lisp`.)

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `grid.lisp` and the display half of `drum-grid.lisp`, extend the harness, and export `drum-grid` and `drum-grid-value`.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`, then `make test`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors sc-imgui.asd src/gui/package.lisp tests/headless.lisp tests/test-editors.lisp
git commit -m "feat: sequencer grid display and gui:drum-grid drawing"
```

---

### Task 11: Shared grid editing: focus, keys, Select mode, end marker

**Files:**
- Create: `src/gui/editors/grid-edit.lisp`
- Modify: `src/gui/editors/drum-grid.lisp`, `sc-imgui.asd`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 8, 9, and 10.
- Produces:
    - `(grid-row-key view row-pos)` → the drum row or MIDI note at that row.
    - `(grid-element-at view row-pos step)`, a generic function:
        - Drum: `(row . step)`.
        - Melodic: the step, if its note sits on that row (an off-scale note counts on the row it is drawn on), else nil.
    - `(grid-edit view state value &key (default-velocity 1.0) (default-gate 0.5) draw-mode-fn)` → `(values new-value changed-p)`. Both sequencers call it after `grid-begin` and before drawing. In order, it:
        1. Ends any gesture after a `:code-change` from `editor-sync`, and drops the drag.
        2. Repairs the state against the current pattern with `selection-valid`, clamping the marker to [0, capacity−1] and the scroll.
        3. Sets `*focused-editor*` on any mouse press inside the item.
        4. Handles a click on the pencil toggle.
        5. Handles the end marker. A press within 0.4 rem of it in the ruler starts a drag; the length follows `grid-ruler-step`, snapping to a multiple of the step resolution with Shift. Minimum is 1, or the step resolution with Shift.
        6. Mouse input:
            - In `:draw` mode it calls `draw-mode-fn`, a function of `(view state value)` returning `(values new changed-p)`.
            - In `:select` mode it applies the mouse rules below.
        7. Keyboard commands, only when the editor is focused, `io.want-text-input` is false, and no popup is open:
            - B with no modifiers toggles the mode.
            - Escape clears the selection.
            - Cmd-A selects all.
            - Cmd-C, Cmd-X, Cmd-V (paste at the marker), Cmd-D.
            - Delete or Backspace clears the selection.
            - Left and Right nudge by a step (`:exact`).
            - Up and Down: drum ignores them. Melodic transposes by ±1, or ±12 with Shift, using `:exact`.
            - Cmd-Z undoes; Cmd-Shift-Z redoes.
    - Each command is one `editor-commit`. Drags open a gesture at the press, call `editor-wrote` each frame, and end it at release.
- Select-mode mouse:
    - **Click on an element:** select it (Shift toggles it in the selection) and set the marker to its step.
    - **Click on empty space:** clear the selection unless Shift is held, and set the marker.
        - Drum: an empty cell is an element, so a click selects it. Pressing on a set or selected cell can start a move; pressing on an empty, unselected cell starts a marquee.
    - **Marquee:** rows and steps from press to mouse. The selection becomes `selection-elements-in`, or is added to with Shift. Draw it in `:accent` at alpha 0.15, with a 1 px `:accent` border.
    - **Move:**
        - The move is computed from the gesture-start value, with `selection-move :policy :clamp`.
        - `dsteps` is the cursor's step travel, rounded to a whole beat with Shift. `dpitch` is the row travel mapped through row keys (melodic only).
        - Alt held at the press makes it a copy.
    - **Double-click:** `pattern-toggle` at the cell, as one undo step.
    - **Draw-mode double-click:** the second click of a double-click is ignored, so one double-click toggles once.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun cell-xy (row step)
  (gui::grid-cell-center gui::*last-grid-view* row step))

(defmacro with-drum-place ((var pattern &rest args) &body body)
  "Bind VAR to PATTERN and DRAW to a function drawing gui:drum-grid on it with ARGS, primed."
  `(let ((,var ,pattern))
     (flet ((draw () (in-window (gui:drum-grid "Kit" ,var ,@args))))
       (dotimes (i 2) (with-test-frame () (draw)))
       ,@body)))

(test marquee-copy-paste-cut-duplicate-delete
  (with-editors-env ()
    (with-drum-place (p (%drum '((0 0 1.0) (1 1 0.5))))
      ;; Press on the empty cell (1 . 0), so it is a marquee rather than a move.
      (drag-through (list (multiple-value-list (cell-xy 1 0)) (multiple-value-list (cell-xy 0 1)))
                    #'draw)
      (is (equal '((0 . 0) (0 . 1) (1 . 0) (1 . 1))
                 (gui::editor-state-selection (gui::editor-state (gui::grid-view-id gui::*last-grid-view*)))))
      (with-keys-held (:ctrl) (press-key %imgui:+key-c+ #'draw))
      (multiple-value-bind (x y) (cell-xy 3 8) (frames-with-click x y #'draw))
      (with-keys-held (:ctrl) (press-key %imgui:+key-v+ #'draw))
      (is (equal '((0 0 1.0) (0 8 1.0) (1 1 0.5) (1 9 0.5)) (%cells p)))
      (with-keys-held (:ctrl) (press-key %imgui:+key-d+ #'draw))
      (is (equal '((0 0 1.0) (0 8 1.0) (0 10 1.0) (1 1 0.5) (1 9 0.5) (1 11 0.5)) (%cells p)))
      (press-key %imgui:+key-delete+ #'draw)
      (is (= 4 (length (%cells p))))
      (with-keys-held (:ctrl) (press-key %imgui:+key-z+ #'draw))
      (is (= 6 (length (%cells p))))
      (with-keys-held (:ctrl :shift) (press-key %imgui:+key-z+ #'draw))
      (is (= 4 (length (%cells p)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test drag-moves-and-alt-drag-copies
  (with-editors-env ()
    (with-drum-place (p (%drum '((0 2 1.0))))
      (multiple-value-bind (x y) (cell-xy 0 2) (frames-with-click x y #'draw))
      (multiple-value-bind (x y) (cell-xy 0 2)
        (multiple-value-bind (x2) (cell-xy 0 5) (frames-with-drag x y (- x2 x) 0 #'draw)))
      (is (equal '((0 5 1.0)) (%cells p)))
      (multiple-value-bind (x y) (cell-xy 0 5)
        (multiple-value-bind (x2) (cell-xy 0 30)                 ; past the end: clamps to 15
          (with-keys-held (:alt) (frames-with-drag x y (- x2 x) 0 #'draw))))
      (is (equal '((0 5 1.0) (0 15 1.0)) (%cells p)))
      (press-key %imgui:+key-right-arrow+ #'draw)                ; selection is (0 . 15): can't move
      (is (equal '((0 5 1.0) (0 15 1.0)) (%cells p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test end-marker-drag-sets-length
  (with-editors-env ()
    (with-drum-place (p (gui:make-drum-pattern))
      (let* ((v gui::*last-grid-view*)
             (y (+ (gui::grid-view-y v) (gui::grid-view-header-height v)
                   (/ (gui::grid-view-ruler-height v) 2)))
             (x-end (+ (gui::grid-view-grid-x v) (* 16 (gui::grid-view-cell v)))))
        (frames-with-drag x-end y (- (* 6.2 (gui::grid-view-cell v))) 0 #'draw)
        (is (= 10 (gui:pattern-length p)))
        (frames-with-drag (- x-end (* 6 (gui::grid-view-cell v))) y (* 1.4 (gui::grid-view-cell v)) 0
                          #'draw :shift t)
        (is (= 12 (gui:pattern-length p)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test keys-ignored-while-typing                       ; Review Focus 1
  (with-editors-env ()
    (let ((text "") (p (%drum '((0 0 1.0)))))
      (flet ((draw () (in-window (gui:drum-grid "Kit" p) (gui:input-text "name" text))))
        (dotimes (i 2) (with-test-frame () (draw)))
        (multiple-value-bind (x y) (cell-xy 0 0) (frames-with-click x y #'draw))
        (click-item #'draw)                                    ; the text field, last item
        (press-key %imgui:+key-b+ #'draw)
        (press-key %imgui:+key-delete+ #'draw)
        (is (eq :select (gui::editor-state-mode (gui::editor-state (gui::grid-view-id gui::*last-grid-view*)))))
        (is (= 1 (length (%cells p))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test code-change-mid-drag                            ; Review Focus 2
  (with-editors-env ()
    (with-drum-place (p (%drum '((0 2 1.0))))
      (multiple-value-bind (x y) (cell-xy 0 2) (frames-with-click x y #'draw))
      (let ((replacement (%drum '((1 7 0.5)))))
        (multiple-value-bind (x y) (cell-xy 0 2)
          ;; Press, replace the place from code, then move and release.
          (let ((io (%imgui:get-io-nil)))
            (%imgui:im-gui-io-add-mouse-pos-event io (float x 1.0f0) (float y 1.0f0))
            (with-test-frame () (draw))
            (%imgui:im-gui-io-add-mouse-button-event io 0 t)
            (with-test-frame () (draw))
            (setf p replacement)
            (%imgui:im-gui-io-add-mouse-pos-event io (float (+ x 60) 1.0f0) (float y 1.0f0))
            (with-test-frame () (draw))
            (%imgui:im-gui-io-add-mouse-button-event io 0 nil)
            (with-test-frame () (draw))))
        (is (eq replacement p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test selection-survives-shrink                       ; Review Focus 3
  (with-editors-env ()
    (with-drum-place (p (%drum '((0 20 1.0) (1 30 0.5)) :rows 8 :bars 2) :visible-rows 4)
      (multiple-value-bind (x y) (cell-xy 0 20) (frames-with-click x y #'draw))   ; focus
      (with-keys-held (:ctrl) (press-key %imgui:+key-a+ #'draw))
      (multiple-value-bind (x y) (cell-xy 2 28)                                    ; marker 28
        (with-keys-held (:shift) (frames-with-click x y #'draw)))
      (setf p (gui:pattern-with-bars p 1))
      (dotimes (i 2) (with-test-frame () (draw)))
      (let ((s (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))))
        (is (null (gui::editor-state-selection s)))
        (is (= 15 (gui::editor-state-marker s)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement `grid-edit.lisp`, and call `grid-edit` from `drum-grid-value` with a `draw-mode-fn` that returns the value unchanged** (Task 12 fills it in).

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors sc-imgui.asd tests/test-editors.lisp
git commit -m "feat: shared sequencer editing: selection, clipboard, moves, undo, end marker"
```

---

### Task 12: Drum grid Draw mode and row menu

**Files:**
- Modify: `src/gui/editors/drum-grid.lisp`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Task 11's `draw-mode-fn` hook, and `pattern-toggle` and `drum-pattern-with-cells` (Tasks 4 and 8).
- Produces:
    - Drum `draw-mode-fn`:
        - **Click:** toggle with `default-velocity` and `default-gate`.
        - **Drag:** paints along the cells the mouse crosses, applying the first click's action (set or clear) to each cell that isn't already in that state.
        - **Alt-drag on a set cell:** changes its velocity by −dy over 5 rem for a full range, clamped to [0.01, 1].
        - **Gated pattern, press within 0.3 rem of a set block's right edge:** drags its gate to `(mx − cell-left)/cell`, rounded to a whole step (at least 1) unless Shift is held (then at least 0.05).
        - Each drag is one gesture.
    - The row menu, opened by right-clicking a row label:
        - The pure `(drum-row-menu-items p row)` → a list of `(label . function-of-pattern)`:
            - `"Clear row"`.
            - `"Fill every 2 steps"`, `"Fill every 3 steps"`, `"Fill every 4 steps"`, `"Fill every 8 steps"`, and `"Fill every beat"` (every `step-resolution` steps).
        - Fills set velocity to `default-velocity` from step 0 up to the capacity, leaving other cells alone.
        - Choosing an item is one undo step.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun %mode ()
  (gui::editor-state-mode (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))))

(test draw-mode-toggles-and-paints
  (with-editors-env ()
    (with-drum-place (p (gui:make-drum-pattern) :default-velocity 0.8)
      (multiple-value-bind (x y) (cell-xy 0 0) (frames-with-click x y #'draw))
      (press-key %imgui:+key-b+ #'draw)
      (is (eq :draw (%mode)))
      (multiple-value-bind (x y) (cell-xy 0 1) (frames-with-click x y #'draw))
      (is (equal '((0 1 0.8)) (%cells p)))
      (drag-through (list (multiple-value-list (cell-xy 1 0)) (multiple-value-list (cell-xy 1 1))
                          (multiple-value-list (cell-xy 1 2)) (multiple-value-list (cell-xy 1 3)))
                    #'draw)
      (is (= 5 (length (%cells p))))
      (with-keys-held (:ctrl) (press-key %imgui:+key-z+ #'draw))
      (is (= 1 (length (%cells p))))
      (multiple-value-bind (x y) (cell-xy 0 1) (frames-with-double-click x y #'draw))
      (is (null (%cells p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test alt-drag-velocity-and-gate-edge
  (with-editors-env ()
    (with-drum-place (p (gui:drum-pattern-with-step (gui:make-drum-pattern :gates t) 0 0 0.5 :gate 1.0))
      (setf (gui::editor-state-mode (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))) :draw)
      (multiple-value-bind (x y) (cell-xy 0 0)
        (with-keys-held (:alt) (frames-with-drag x y 0 (- (gui::rem-px 2.5)) #'draw)))
      (is (< (abs (- (gui:drum-step p 0 0) 1.0)) 0.02))
      (let ((v gui::*last-grid-view*))
        (multiple-value-bind (x1 y1 x2 y2) (gui::grid-cell-rect v 0 0)
          (declare (ignore x1 y2))
          (frames-with-drag (- x2 1) (+ y1 3) (* 2.2 (gui::grid-view-cell v)) 0 #'draw)))
      (is (= 3.0 (gui:drum-gate p 0 0))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test row-menu-items
  (let* ((p (gui:make-drum-pattern :step-resolution 4))
         (items (gui::drum-row-menu-items p 1 1.0)))
    (is (equal '("Clear row" "Fill every 2 steps" "Fill every 3 steps" "Fill every 4 steps"
                 "Fill every 8 steps" "Fill every beat")
               (mapcar #'car items)))
    (is (equal '((1 0 1.0) (1 3 1.0) (1 6 1.0) (1 9 1.0) (1 12 1.0) (1 15 1.0))
               (%cells (funcall (cdr (third items)) p))))))
```

(The signature is `(drum-row-menu-items p row default-velocity)`.)

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement Draw mode and the row menu** (`open-popup-str` on a right-click over the label column, `begin-popup`, `menu-item-bool` per item).

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/drum-grid.lisp tests/test-editors.lisp
git commit -m "feat: drum grid draw mode, velocity, gates and row menu"
```

---

### Task 13: Melodic sequencer display

**Files:**
- Create: `src/gui/editors/melodic.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 5, 10, and 11.
- Produces:
    - `gui:melodic-sequencer` (a macro) and `(gui:melodic-sequencer-value label value &key (cell 1.25) (visible-rows 12) max-display-width playhead (low 48) (high 84) scale (root 60) fold row-names (default-velocity 0.8) (default-gate 0.5))`.
    - Argument checks, in addition to Task 10's:
        - `control-spec-error` for `low` not below `high`, either outside 0–127, or `row-names` not a list or vector.
        - `editor-data-error` for an unknown scale.
    - `(melodic-rows low high scale root fold)` → the vector of notes, high to low. With `fold` and a `scale`, only scale notes are included; `fold` without a scale is ignored.
    - `(melodic-note-row view note)` → `(values row-pos off-scale-p)`, the row of the note or of the nearest row below it, or nil when the note is outside low–high.
    - Row styles:
        - Without `row-names`: black keys `:black`, scale notes `:scale` when a scale is given, others `:plain`.
        - With `row-names`: alternating `:plain` and `:alt`, with `:scale` still applied.
        - `keyboard` is true unless `row-names` is given.
    - Initial scroll, set once per editor when its state is new:
        - The row of `(round (+ min max) 2)` over the pattern's notes, or of `root` when the pattern is empty, placed at the middle of the visible rows.
        - Clamped.
    - Note drawing:
        - A block `:accent` at alpha `0.35 + 0.65·velocity`, as wide as `min(gate, steps to the next non-empty step)`.
        - Muted notes as an `:accent` outline.
        - Off-scale notes (fold) as a block of half the row height, at the bottom of their row.
        - Notes outside low–high as `:accent` triangles at the top or bottom edge of the note lane, in their column.
    - Keyboard strip: white keys `:control`, black keys `(control-shade :text 0.2)`. The C rows also show the note name.
    - Velocity lane: 2 rem high, under the note lane. Each note is a bar of height velocity × lane in `:accent`.
    - Tooltip: hovering a row label or a note shows `"name · (60)"` for a named row, or `"C4 (60)"` otherwise, via `begin-tooltip`, `text`, `end-tooltip`.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun draw-melodic (p &rest args)
  (lambda () (in-window (apply #'gui:melodic-sequencer-value "Bass" p args))))

(test melodic-rows-fold-and-names
  (is (equalp #(64 63 62 61 60) (gui::melodic-rows 60 64 nil 60 nil)))
  (is (equalp #(64 62 60) (gui::melodic-rows 60 64 :major 60 t)))
  (is (equalp #(64 63 62 61 60) (gui::melodic-rows 60 64 nil 60 t))))

(test visible-rows-count-folded-rows
  (with-editors-env ()
    (dotimes (i 2) (with-test-frame () (funcall (draw-melodic (gui:make-melodic-pattern)
                                                              :scale :major :fold t :visible-rows 12))))
    (let ((v gui::*last-grid-view*))
      (is (= 12 (gui::grid-view-visible v)))
      (is (every (lambda (n) (gui:scale-note-p n :major 60)) (gui::grid-view-row-keys v))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test initial-scroll-centres-the-notes
  (with-editors-env ()
    (let ((p (%melodic '((0 72) (1 76)))))
      (dotimes (i 2) (with-test-frame () (funcall (draw-melodic p))))
      (let* ((v gui::*last-grid-view*)
             (row (position 74 (gui::grid-view-row-keys v))))
        (is (= (- row 6) (gui::grid-view-scroll v)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test row-names-turn-off-the-keyboard
  (with-editors-env ()
    (dotimes (i 2) (with-test-frame () (funcall (draw-melodic (gui:make-melodic-pattern) :low 60 :high 64
                                                              :row-names '(:kick nil "snare")))))
    (let ((v gui::*last-grid-view*))
      (is (equalp #("E4" "D#4" "snare" "C#4" "kick") (gui::grid-view-row-labels v)))
      (is (notany (lambda (s) (eq s :black)) (gui::grid-view-row-styles v))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test off-scale-note-is-drawn                         ; Review Focus 5
  (with-editors-env ()
    (let ((p (%melodic '((0 61) (1 100) (2 60)))))       ; 61 off C major, 100 above range
      (dotimes (i 3) (with-test-frame () (funcall (draw-melodic p :scale :major :fold t))))
      (let ((v gui::*last-grid-view*))
        (is (equal (list (position 60 (gui::grid-view-row-keys v)) t)
                   (multiple-value-list (gui::melodic-note-row v 61))))
        (is (null (gui::melodic-note-row v 100)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement the display in `melodic.lisp`, calling `grid-begin`, `grid-edit` (with a `draw-mode-fn` that returns the value unchanged), and `draw-grid`. Export the names.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/melodic.lisp sc-imgui.asd src/gui/package.lisp tests/test-editors.lisp
git commit -m "feat: gui:melodic-sequencer display"
```

---

### Task 14: Melodic sequencer editing

**Files:**
- Modify: `src/gui/editors/melodic.lisp`, `src/gui/editors/grid-edit.lisp` (the wheel rule), `src/gui/controls/core.lisp` (`text-entry` gains `&key parse`), `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 8, 11, and 13.
- Produces:
    - `text-entry (id state spec like value-rect &key parse)`. With `parse`, a function of the text returning `(values value ok)`, it replaces `parse-control-text` and the clamp. The existing behaviour without `parse` is unchanged, and the existing controls tests still pass.
    - Melodic `draw-mode-fn`:
        - **Click a cell:** `pattern-toggle` with the row's note and the defaults.
        - **Press within 0.3 rem of a note block's right edge:** drags the gate, as for drums.
        - **Alt-drag on a note:** changes its velocity, as for drums.
    - **Velocity lane, both modes:** pressing and dragging sets the velocity of the non-empty step under the mouse to `1 − (my − lane-top)/lane-height`, clamped to [0.01, 1]. It's one gesture.
    - **Wheel over a selected note:** transposes the selection by one semitone per notch (12 with Shift, taking the notches from whichever wheel axis is non-zero), with `selection-move :policy :clamp`. With a `scale` and `fold`, it moves by `:degrees` instead. Elsewhere, Task 10's scrolling applies.
    - **Cmd-click a note:** opens a text field over the note's block, at least 3 rem wide, using `parse-note-name`. A commit sets the note, as one undo step.
    - Up and Down move by a semitone, or an octave with Shift (Task 11's key handling, now live for melodic).

- [ ] **Step 1: Write the failing tests**

```lisp
(defmacro with-melodic-place ((var pattern &rest args) &body body)
  `(let ((,var ,pattern))
     (flet ((draw () (in-window (gui:melodic-sequencer "Bass" ,var ,@args))))
       (dotimes (i 2) (with-test-frame () (draw)))
       ,@body)))

(defun note-xy (note step)
  (gui::grid-cell-center gui::*last-grid-view*
                         (position note (gui::grid-view-row-keys gui::*last-grid-view*)) step))

(test melodic-draw-add-remove-and-gate
  (with-editors-env ()
    (with-melodic-place (p (gui:make-melodic-pattern) :low 60 :high 72)
      (setf (gui::editor-state-mode (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))) :draw)
      (multiple-value-bind (x y) (note-xy 64 2) (frames-with-click x y #'draw))
      (is (equal '((2 64)) (%notes p)))
      (is (= 0.5 (gui:step-gate (gui:melodic-step p 2))))
      (let ((v gui::*last-grid-view*))
        (multiple-value-bind (x1 y1) (gui::grid-cell-rect v (position 64 (gui::grid-view-row-keys v)) 2)
          (frames-with-drag (+ x1 (* 0.5 (gui::grid-view-cell v)) -1) (+ y1 3)
                            (* 1.6 (gui::grid-view-cell v)) 0 #'draw)))
      (is (= 2 (gui:step-gate (gui:melodic-step p 2))))
      (multiple-value-bind (x y) (note-xy 64 2) (frames-with-click x y #'draw))
      (is (null (%notes p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test transpose-with-wheel-and-arrows
  (with-editors-env ()
    (with-melodic-place (p (%melodic '((0 60) (1 64))) :low 48 :high 84)
      (multiple-value-bind (x y) (note-xy 60 0) (frames-with-click x y #'draw))   ; focus
      (with-keys-held (:ctrl) (press-key %imgui:+key-a+ #'draw))
      (multiple-value-bind (x y) (note-xy 64 1) (frames-with-wheel x y 2 #'draw))
      (is (equal '((0 62) (1 66)) (%notes p)))
      (with-keys-held (:shift) (press-key %imgui:+key-down-arrow+ #'draw))
      (is (equal '((0 50) (1 54)) (%notes p)))
      (with-keys-held (:shift) (press-key %imgui:+key-up-arrow+ #'draw))
      (is (equal '((0 62) (1 66)) (%notes p)))
      ;; Shift+wheel as macOS sends it (horizontal axis) still transposes by octaves here.
      (multiple-value-bind (x y) (note-xy 66 1) (frames-with-wheel x y 1 #'draw :shift t :horizontal t))
      (is (equal '((0 74) (1 78)) (%notes p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test wheel-scrolls-when-not-over-a-selected-note
  (with-editors-env ()
    (with-melodic-place (p (%melodic '((0 60))) :low 48 :high 84)
      (let ((before (gui::grid-view-scroll gui::*last-grid-view*)))
        (multiple-value-bind (x y) (note-xy 60 5) (frames-with-wheel x y -2 #'draw))
        (is (= (+ before 2) (gui::grid-view-scroll gui::*last-grid-view*)))
        (is (equal '((0 60)) (%notes p)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test velocity-lane-and-typed-note
  (with-editors-env ()
    (with-melodic-place (p (%melodic '((0 60))) :low 48 :high 84)
      (let* ((v gui::*last-grid-view*)
             (lane-bottom (+ (gui::grid-view-y v) (gui::grid-view-height v))))
        (multiple-value-bind (x) (note-xy 60 0)
          (frames-with-click x (- lane-bottom (* 0.25 (gui::grid-view-lane-height v)) -1) #'draw)))
      (is (< (abs (- 0.25 (gui:step-velocity (gui:melodic-step p 0)))) 0.05))
      (multiple-value-bind (x y) (note-xy 60 0)
        (with-keys-held (:ctrl) (frames-with-click x y #'draw)))
      (type-text "eb4" #'draw)
      (press-key %imgui:+key-enter+ #'draw)
      (is (equal '((0 63)) (%notes p))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test off-scale-note-selectable                       ; Review Focus 5
  (with-editors-env ()
    (with-melodic-place (p (%melodic '((0 61))) :scale :major :fold t)
      (multiple-value-bind (x y) (note-xy 60 0) (frames-with-click x (+ y 3) #'draw))
      (is (equal '(0) (gui::editor-state-selection
                       (gui::editor-state (gui::grid-view-id gui::*last-grid-view*))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement the editing, and the `text-entry` `:parse` keyword.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`, then `make test SUITE=controls`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors src/gui/controls/core.lisp tests/test-editors.lisp
git commit -m "feat: melodic sequencer editing, transposing and typed notes"
```

---

### Task 15: Envelope editor display

**Files:**
- Create: `src/gui/editors/envelope-editor.lisp`
- Modify: `sc-imgui.asd`, `src/gui/package.lisp`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 2, 3, and 9; `format-control-value` and `parse-control-spec` from the control core.
- Produces:
    - `gui:envelope-editor` (a macro) and `(gui:envelope-editor-value label value &key width (height 6) (min 0) (max 1) unit duration)`.
    - Argument checks:
        - `widget-value-error` unless the value is an `envelope`.
        - `control-spec-error` for `min` ≥ `max`, a bad size, an unknown unit, or `duration` not a positive real.
    - The `envelope-view` struct, stored in the state's `view` and in `*last-envelope-view*`. Slots:
        - `id`, `x`, `y`, `width`.
        - `graph-x`, `graph-y`, `graph-w`, `graph-h`.
        - `span`: the time shown.
        - `min`, `max`, `spec` (a control spec for `unit`).
    - Layout:
        - The label line, then the graph (`height` rem high, inset 0.4 rem so handles at the edges stay inside), then the info line.
        - The width is `width` rem, or the available width when nil.
    - `span`:
        - `duration` if given.
        - Otherwise `max(envelope-duration, 0.001) × 1.1`, or 1.0 s when the duration is 0.
        - Frozen in the state's `fit` while a drag is open.
    - Geometry:
        - `(envelope-point-xy view e i)` → `(values x y)`, and `(envelope-xy->time-level view x y)`.
        - Levels outside min–max are drawn at the edges.
    - `(envelope-hit view e mx my)` → `(:point i)` within 0.5 rem of a handle, `(:segment i)` within 0.4 rem vertically of the curve between points `i` and `i+1`, `(:empty)` elsewhere in the graph, or nil outside it.
    - Drawing:
        - Background `:frame`, with time grid lines in `:grid-step`.
        - The curve is a polyline in `:accent`, 2 px. Each segment is sampled with `curve-level` at `max(2, segment width in px / 2)` points (`:step` and `:hold` exactly).
        - Handles are 0.3 rem circles filled `:accent`, with the hovered handle outlined in `:text`.
        - The release node and loop node get a vertical `:grid-beat` line and an "R" or "L" in `:text-dim` at the top of the graph.
    - The info line, in `:text-dim`:
        - A point: `"<time> s  <level>"`, with the level formatted by `format-control-value`. Levels at `+exp-floor+` show as 0.
        - A segment: `"Curve: <curve>"`, the keyword name or the number with 1 decimal.
        - Empty otherwise.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun draw-env (e &rest args)
  (lambda () (in-window (apply #'gui:envelope-editor-value "Amp" e args))))

(test envelope-editor-draws-every-curve
  (with-editors-env ()
    (let ((e (gui:make-envelope '(0 1 0.5 0.5 0.2 1 0 1 0.3 0)
                                '(0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1)
                                :curves '(:step :lin :exp :sine :welch :sqr :cubed :hold -4)
                                :release-node 7 :loop-node 2)))
      (is (every (lambda (r) (and (eq e (first r)) (null (second r))))
                 (loop repeat 3 collect (with-test-frame ()
                                          (multiple-value-list (funcall (draw-env e :unit :db))))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test zero-duration-envelope-draws                    ; Review Focus 4
  (with-editors-env ()
    (let ((e (gui:make-envelope '(-1 1 0) '(0 0) :curves :exp)))
      (dotimes (i 3) (with-test-frame () (funcall (draw-env e :min -1))))
      (is (= 1.0 (gui::envelope-view-span gui::*last-envelope-view*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test envelope-hit-testing
  (with-editors-env ()
    (let ((e (gui:make-envelope '(0 1 0) '(1 1))))
      (dotimes (i 2) (with-test-frame () (funcall (draw-env e :width 20))))
      (let ((v gui::*last-envelope-view*))
        (multiple-value-bind (x y) (gui::envelope-point-xy v e 1)
          (is (equal '(:point 1) (gui::envelope-hit v e (+ x 2) y))))
        (multiple-value-bind (x1 y1) (gui::envelope-point-xy v e 0)
          (multiple-value-bind (x2 y2) (gui::envelope-point-xy v e 1)
            (is (equal '(:segment 0) (gui::envelope-hit v e (/ (+ x1 x2) 2) (/ (+ y1 y2) 2))))
            (is (equal '(:empty) (gui::envelope-hit v e (/ (+ x1 x2) 2) (+ y2 2))))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test envelope-editor-argument-errors
  (with-editors-env ()
    (signals gui:widget-value-error (with-test-frame () (funcall (draw-env '(0 1)))))
    (dolist (args '((:min 1 :max 1) (:unit :furlongs) (:duration 0) (:height -2)))
      (signals gui:control-spec-error
        (with-test-frame () (funcall (apply #'draw-env (gui:envelope-perc) args)))))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement the display and export the names.** The editor calls `editor-sync` each frame, as the sequencers do.

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/envelope-editor.lisp sc-imgui.asd src/gui/package.lisp tests/test-editors.lisp
git commit -m "feat: gui:envelope-editor display"
```

---

### Task 16: Envelope editor interaction

**Files:**
- Modify: `src/gui/editors/envelope-editor.lisp`, `tests/test-editors.lisp`

**Interfaces:**
- Consumes: Tasks 2, 9, 14 (`text-entry :parse`), and 15.
- Produces:
    - **Drag a point:**
        - Its level follows the mouse, clamped to min–max.
        - For points after the first, the preceding segment's time becomes `max(0, t_mouse − t_previous)`, and later points move with it.
        - Computed from the gesture-start envelope each frame, with `span` frozen.
    - **Double-click:**
        - Empty space: `envelope-insert-point` at the mouse.
        - A point: `envelope-delete-point`. Ignored at 2 points.
        - A segment: `envelope-with-curve` with `:lin`.
    - **Bend a segment** (not `:step` or `:hold`):
        - Drag vertically: curvature += `k·(−dy)/rem-px(0.5)`, where `k` is −1 for a rising segment (y2 ≥ y1) and +1 for a falling one, so dragging up bulges the curve up.
        - The wheel: 0.5 per notch, with the same sign rule.
        - A named curve starts from 0. The result is clamped to [−10, 10].
    - **Right-click a point:** a popup from the pure `(envelope-node-menu e i)`, which returns a list of `(label enabled-p new-envelope)`:
        - `"Set release node"`: enabled unless the loop node is non-nil and ≥ `i`.
        - `"Set loop node"`: enabled unless the release node is non-nil and ≤ `i`.
        - `"Clear release node"`, or `"Clear release node (and loop)"` when a loop node is set: enabled when a release node is set.
        - `"Clear loop node"`: enabled when a loop node is set.
        - Disabled items use `menu-item-bool` with `enabled` false.
    - **Right-click a segment:** a popup listing `:lin :exp :sine :welch :sqr :cubed :step :hold`, with the current one checked.
    - **Cmd-click a point:** opens two fields in the info line, time and level (level only for point 0), with focus on level.
        - Each field uses `text-entry`. Time is parsed as a non-negative number of seconds; level with the unit's parser, then clamped.
        - Enter commits that field as one undo step.
        - A field's `:cancel` is ignored while the other field is active, so clicking between them works.
        - Escape, or a click outside both fields, closes both.
    - **Keys:** Cmd-Z and Cmd-Shift-Z when the editor is focused and no text input is active.

- [ ] **Step 1: Write the failing tests**

```lisp
(defmacro with-env-place ((var envelope &rest args) &body body)
  `(let ((,var ,envelope))
     (flet ((draw () (in-window (gui:envelope-editor "Amp" ,var :width 20 ,@args))))
       (dotimes (i 2) (with-test-frame () (draw)))
       ,@body)))

(defun env-point-xy (e i) (gui::envelope-point-xy gui::*last-envelope-view* e i))

(test drag-point-moves-later-points
  (with-editors-env ()
    (with-env-place (e (gui:make-envelope '(0 1 0) '(1 1)))
      (multiple-value-bind (x y) (env-point-xy e 1)
        (let ((v gui::*last-envelope-view*))
          (frames-with-drag x y (* 0.25 (/ (gui::envelope-view-graph-w v) (gui::envelope-view-span v)))
                            (* 0.5 (gui::envelope-view-graph-h v)) #'draw)))
      (is (< (abs (- 1.25 (first (gui:envelope-times e)))) 0.02))
      (is (< (abs (- 1.0 (second (gui:envelope-times e)))) 1e-6))
      (is (< (abs (- 0.5 (second (gui:envelope-levels e)))) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test add-and-delete-points-by-double-click
  (with-editors-env ()
    (with-env-place (e (gui:make-envelope '(0 1 0) '(1 1)))
      (multiple-value-bind (x1) (env-point-xy e 0)
        (multiple-value-bind (x2 y2) (env-point-xy e 1)
          (frames-with-double-click (/ (+ x1 x2) 2) (+ y2 4) #'draw)))
      (is (= 4 (length (gui:envelope-levels e))))
      (multiple-value-bind (x y) (env-point-xy e 1) (frames-with-double-click x y #'draw))
      (is (= 3 (length (gui:envelope-levels e)))))
    (with-env-place (e (gui:make-envelope '(0 1) '(1)))
      (multiple-value-bind (x y) (env-point-xy e 1) (frames-with-double-click x y #'draw))
      (is (= 2 (length (gui:envelope-levels e)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test bend-with-drag-and-wheel
  (with-editors-env ()
    (with-env-place (e (gui:make-envelope '(0 1) '(1)))
      (multiple-value-bind (x1 y1) (env-point-xy e 0)
        (multiple-value-bind (x2 y2) (env-point-xy e 1)
          (let ((mx (/ (+ x1 x2) 2)) (my (/ (+ y1 y2) 2)))
            (frames-with-drag mx my 0 (- (gui::rem-px 1)) #'draw)
            (is (< (abs (- -2 (first (gui:envelope-curves e)))) 0.01))
            (frames-with-wheel mx (- my (gui::rem-px 0.3)) -2 #'draw)
            (is (< (abs (- -1 (first (gui:envelope-curves e)))) 0.01))))))
    (with-env-place (e (gui:make-envelope '(0 1) '(1) :curves :step))
      (multiple-value-bind (x1 y1) (env-point-xy e 0)
        (multiple-value-bind (x2 y2) (env-point-xy e 1)
          (frames-with-drag (/ (+ x1 x2) 2) y2 0 (- (gui::rem-px 1)) #'draw)))
      (is (eq :step (first (gui:envelope-curves e)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test node-menu-disables-invalid-choices
  (let* ((e (gui:make-envelope '(0 1 0.5 0) '(1 1 1) :release-node 2 :loop-node 1))
         (items (lambda (i) (mapcar (lambda (it) (list (first it) (second it)))
                                    (gui::envelope-node-menu e i)))))
    (is (equal '(("Set release node" nil) ("Set loop node" t)
                 ("Clear release node (and loop)" t) ("Clear loop node" t))
               (funcall items 0)))
    (is (equal '("Set release node" t) (first (funcall items 3))))
    (is (equal '("Set loop node" nil) (second (funcall items 2))))
    (is (null (gui:envelope-loop-node (third (third (gui::envelope-node-menu e 0))))))))

(test typed-time-and-level
  (with-editors-env ()
    (with-env-place (e (gui:make-envelope '(0 1 0) '(1 1)))
      (multiple-value-bind (x y) (env-point-xy e 1)
        (with-keys-held (:ctrl) (frames-with-click x y #'draw)))
      (type-text "0.25" #'draw)                      ; level field has focus
      (press-key %imgui:+key-enter+ #'draw)
      (is (= 0.25 (second (gui:envelope-levels e))))
      (with-keys-held (:ctrl) (press-key %imgui:+key-z+ #'draw))
      (is (= 1 (second (gui:envelope-levels e)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
```

- [ ] **Step 2: Run them to confirm they fail.** `make test SUITE=editors`.

- [ ] **Step 3: Implement the interaction.**

- [ ] **Step 4: Run them to confirm they pass.** `make test SUITE=editors`, then `make test`.

- [ ] **Step 5: Commit**

```bash
git add src/gui/editors/envelope-editor.lisp tests/test-editors.lisp
git commit -m "feat: envelope editor interaction, node menus and typed entry"
```

---

### Task 17: Example and documentation

**Files:**
- Create: `examples/editors.lisp`
- Modify: `tests/test-examples.lisp` (add `"editors.lisp"` to the list), `examples/README.md`, `src/gui/README.md`, `tests/README.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Add `"editors.lisp"` to `examples-run-cleanly`, and run `make test SUITE=examples`.** Expected: FAIL; the file is missing.

- [ ] **Step 2: Write `examples/editors.lisp`.** Follow `examples/controls.lisp`: a header comment with run instructions and what to try, `cl-user` package, and `*example-…*` variables. It contains one `define-gui`:
    - An amp envelope: `(gui:envelope-adsr)` in `gui:envelope-editor`, using the default 0–1 range.
    - A drum kit:
        - `(gui:make-drum-pattern :rows '(:kick :snare :closed-hat :open-hat) :gates t)`, prefilled with a four-on-the-floor kick.
        - Its `:playhead` comes from `*example-step*`, which the GUI advances once every 8 frames with `(incf …)` inside the panel, so the example needs no thread.
    - A bass line: a melodic pattern in `:minor` with root 45, shown with `:scale :minor :root 45 :fold t`.
    - A comment showing the cl-collider use: `(gui:envelope-env *example-env*)` and a `pattern-events` loop.

- [ ] **Step 3: Run `make test SUITE=examples`.** Expected: PASS, with no failed panels and no asserts.

- [ ] **Step 4: Documentation**
    - `src/gui/README.md`:
        - An "Editors" section: a quick reference of every exported editor and data function; the data model (envelopes, timing, drum and melodic patterns, `pattern-events`, scales); each editor's arguments and interaction; a keyboard shortcut table; and recipes for driving a cl-collider routine from a sequencer and building a synth with `envelope-env`. Include the note that edits reach existing synthdefs only when they're redefined.
        - The grid roles in the themes section.
    - `tests/README.md`: the `editors` suite, its two files, and the new harness helpers, in the coverage map.
    - `examples/README.md`: `editors.lisp`.

- [ ] **Step 5: Run `make test`.** Expected: every suite passes.

- [ ] **Step 6: Commit**

```bash
git add examples/editors.lisp examples/README.md tests/test-examples.lisp src/gui/README.md tests/README.md
git commit -m "docs: editors example and documentation"
```

- [ ] **Step 7: Manual check on macOS** (from the spec):
    - Grid colours in both themes.
    - How dragging, bending, and painting feel.
    - All keyboard shortcuts, with Cmd.
    - `(gui:set-font-size 20)` scales every editor cleanly.

    Tune the grid role values in `theme.lisp` if needed, and commit separately.
