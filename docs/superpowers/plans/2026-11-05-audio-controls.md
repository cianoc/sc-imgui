# Audio Controls (Part 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add six Ableton Live-style controls to the `gui` package (knob, fader, toggle, trigger, number box, XY pad), built on a shared control core, themed and rem-sized.

**Architecture:** A pure-Lisp *value specification* layer (mapping, units, parsing) and an ImGui-facing *control core* (item reservation, drag, wheel, double-click, typed entry, per-control state, themed colours) live in `src/gui/controls/`. Each control is a small file that calls the core and draws with the draw-list primitives and `theme-color`. No native changes.

**Tech Stack:** SBCL, CFFI, the generated `%imgui` bindings, FiveAM.

**Spec:** `docs/superpowers/specs/2026-11-05-audio-controls-design.md`. Executors read the spec alongside this plan; it holds the exact behaviour (unit tables, interaction rules, error list) that tasks reference by section.

## Global Constraints

- No changes to `native/`, `src/bindings/`, or the generated files. Every ImGui call uses existing bindings.
- All new public names are exported from `gui` in `src/gui/package.lisp`. Internal helpers stay unexported and are tested with `gui::`.
- Every size is in rem (times ImGui's style `font-size-base`) unless given as `(:px n)`. Use `gui::%pixels` from `theme.lisp` for conversion.
- Controls draw only with colours from the theme, through the core's `control-color` (which applies ImGui's style alpha). No literal colours.
- Cmd-click on macOS and Ctrl-click elsewhere are both read from `io.key-ctrl`: ImGui reports Cmd as Ctrl on macOS. Never read `key-super`.
- Value types are preserved: `double-float` stays `double-float`, integers and choice indexes stay integers, other reals come back `single-float`.
- Drawing a control never writes its place; only user input does.
- Type and specification errors are signalled before any foreign call, naming the control's label.
- Existing widgets (`slider`, `checkbox`, `button`, ...) are unchanged.
- Tests: FiveAM, new suite `controls`, run with `make test SUITE=controls`; every headless test ends with `(is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))`.

## Review Focus

Inputs the spec implies but doesn't spell out, most likely first. Each is pinned by a test in the owning task.

| # | Input or condition | Expected behaviour | Pinned in |
| --- | --- | --- | --- |
| 1 | A `:log` control whose place holds 0 or a negative number, e.g. set from code | Drawn at `min`, no arithmetic error; not written back | Task 2 `log-position-of-nonpositive-value`, Task 6 `knob-draws-nonpositive-log-value` |
| 2 | A drag that overshoots the range, then reverses | The accumulated position is clamped to 0–1, so reversing responds at once | Task 4 `overshoot-then-reverse` |
| 3 | A `:choices` place holding an out-of-range or non-integer index | Out of range: shown clamped, not written back. Non-integer: `widget-value-error` | Task 2 `choices-index-clamped`, Task 4 `choices-non-integer-place` |
| 4 | The place changes from code while its text field is open, then Escape | The place keeps the code's new value; the field never writes a stale value | Task 5 `escape-keeps-code-change` |
| 5 | `gui:set-font-size` runs between frames during a drag | The drag continues without a jump or error, from the accumulated position | Task 4 `font-size-change-mid-drag` |

## File Structure

```
src/gui/controls/
  spec.lisp        value specification: parsing, validation, value<->position
  units.lisp       formatting and parsing per unit
  core.lisp        state table, item reservation, interaction, colours, text entry
  knob.lisp
  fader.lisp
  buttons.lisp     toggle and trigger
  number-box.lisp
  xy-pad.lisp
src/gui/theme.lisp      (modify) :error role
src/gui/package.lisp    (modify) exports
sc-imgui.asd            (modify) controls module after "draw"; test files
tests/headless.lisp     (modify) wheel, double-click, key helpers
tests/suites.lisp       (modify) add `controls`
tests/test-control-spec.lisp   pure-Lisp tests (tasks 2, 3)
tests/test-controls.lisp       headless interaction tests (tasks 4-10)
examples/controls.lisp
```

`sc-imgui.asd`: inside the `gui` module, after `(:file "draw")`, add `(:module "controls" :serial t :components ((:file "spec") (:file "units") (:file "core") (:file "number-box") (:file "knob") (:file "fader") (:file "buttons") (:file "xy-pad")))`. Each task adds its file to this list when it creates it.

---

### Task 1: The `:error` palette role

**Files:**
- Modify: `src/gui/theme.lisp` (`*palette-roles*`, both shipped themes)
- Test: `tests/test-theme.lisp`

**Interfaces:**
- Produces: `(gui:theme-color :error)` returns the current theme's error colour, packed.

- [ ] **Step 1: Write the failing tests in `tests/test-theme.lisp`**

```lisp
(test shipped-themes-define-error
  (dolist (name '(:mid-light :dark))
    (let ((gui:*theme* name))
      (is (integerp (gui:theme-color :error)))))
  (is (equal (rgba "#b3261e") (getf (gui::theme-palette (gui::find-theme :mid-light)) :error)))
  (is (equal (rgba "#e5534b") (getf (gui::theme-palette (gui::find-theme :dark)) :error))))

(test theme-without-base-needs-error
  (let ((palette (loop for (k v) on (gui::theme-palette (gui::find-theme :dark)) by #'cddr
                       unless (eq k :error) append (list k v))))
    (signals error (gui:define-theme :test-no-error :palette palette))))

(test derived-theme-inherits-error
  (gui:define-theme :test-derived :base :dark :palette '(:accent "#4fb3d9"))
  (is (equal (rgba "#e5534b") (getf (gui::theme-palette (gui::find-theme :test-derived)) :error))))
```

(The `theme-without-base-needs-error` palette is copied from `:dark` as parsed lists; `define-theme` already accepts `(r g b a)` lists.)

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=theme`. Expected: FAIL; `Unknown palette role :ERROR`.

- [ ] **Step 3: Add `:error` to `*palette-roles*`, and `:error "#b3261e"` to `:mid-light` and `:error "#e5534b"` to `:dark`.** It maps to no ImGui colour.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=theme`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/theme.lisp tests/test-theme.lisp
git commit -m "feat: :error palette role in themes"
```

---

### Task 2: Value specification and mapping

**Files:**
- Create: `src/gui/controls/spec.lisp`, `tests/test-control-spec.lisp`
- Modify: `sc-imgui.asd` (controls module with `spec`; test file `test-control-spec` after `test-theme`), `tests/suites.lisp` (add `controls`), `src/gui/package.lisp` (export `control-spec-error`)

**Interfaces:**
- Produces (package `gui`, internal unless noted):
    - `(defstruct control-spec min max scale step choices origin default unit format)`: normalized. For `:choices`, `min` is 0, `max` is `(1- (length choices))`, and `step` is 1.
    - `(parse-control-spec label value &key (min 0) (max 1) (scale :linear) step choices bipolar default unit format)` → `control-spec`. Validates every case in the spec's "Errors" section, signalling `gui:control-spec-error`. An integer `value` with no `step` and no `choices` gets `step` 1. `bipolar t` → origin 0 when `min` ≤ 0 ≤ `max`, else the midpoint; a number is the origin; `nil` → origin `min`. `default` defaults to the origin.
    - `gui:control-spec-error` (exported): `error` subclass, slots `label` and `problem`; report `Control "<label>": <problem>`.
    - `(value->position spec value)` → single-float in [0, 1], clamped. Log scale maps `log(value/min)/log(max/min)`; values ≤ 0 map to 0.
    - `(position->value spec position like)` → the value at `position` (clamped to [0, 1]), snapped to `step` from `min`, then coerced to `like`'s type: integer if `like` is an integer, `double-float` if `like` is, else `single-float`.
    - `(clamp-to-spec spec value)` → value clamped to [`min`, `max`], same type rule.

- [ ] **Step 1: Write the failing tests in `tests/test-control-spec.lisp`** (start with `(in-package #:sc-imgui.tests)` and `(in-suite controls)`)

```lisp
(defun spec (&rest args &key (value 0.5) &allow-other-keys)
  (apply #'gui::parse-control-spec "t" value (alexandria:remove-from-plist args :value)))

(test linear-round-trip
  (let ((s (spec :min 20 :max 220)))
    (is (= 0.5 (gui::value->position s 120.0)))
    (is (= 120.0 (gui::position->value s 0.5 1.0)))))

(test log-round-trip
  (let ((s (spec :min 20 :max 20000 :scale :log)))
    (is (< (abs (- 0.5 (gui::value->position s (sqrt (* 20 20000))))) 1e-5))
    (is (< (abs (- 632.456 (gui::position->value s 0.5 1.0))) 0.01))))

(test log-position-of-nonpositive-value            ; Review Focus 1
  (let ((s (spec :min 20 :max 20000 :scale :log)))
    (is (= 0.0 (gui::value->position s 0)))
    (is (= 0.0 (gui::value->position s -5.0)))))

(test stepped-and-integer-snap
  (is (= 0.5 (gui::position->value (spec :min 0 :max 1 :step 0.25) 0.55 1.0)))
  (let ((s (spec :value 3 :min -12 :max 12)))
    (is (= 1 (gui::control-spec-step s)))
    (is (eql 0 (gui::position->value s 0.51 3)))))

(test types-preserved
  (is (typep (gui::position->value (spec) 0.3 0.5d0) 'double-float))
  (is (typep (gui::position->value (spec) 0.3 1/2) 'single-float))
  (is (integerp (gui::position->value (spec :value 1 :choices '("a" "b" "c")) 0.9 1))))

(test choices-index-clamped                         ; Review Focus 3
  (let ((s (spec :value 1 :choices '("a" "b" "c"))))
    (is (= 2 (gui::control-spec-max s)))
    (is (= 1.0 (gui::value->position s 7)))
    (is (= 2 (gui::clamp-to-spec s 7)))))

(test bipolar-origin-and-default
  (let ((s (spec :min -1 :max 1 :bipolar t)))
    (is (= 0 (gui::control-spec-origin s)))
    (is (= 0 (gui::control-spec-default s))))
  (is (= 15 (gui::control-spec-origin (spec :min 10 :max 20 :bipolar t))))
  (is (= 0.2 (gui::control-spec-origin (spec :bipolar 0.2)))))

(test spec-errors
  (dolist (args '((:min 1 :max 1) (:min 0 :max 10 :scale :log) (:step 0)
                  (:choices ()) (:choices ("a" 2)) (:choices ("a") :min 0)
                  (:default 5) (:unit :furlongs) (:scale :exp)))
    (handler-case (progn (apply #'spec args) (fail "no error for ~S" args))
      (gui:control-spec-error (e) (is (search "\"t\"" (princ-to-string e)))))))
```

Add `(in-package ...)`/`(in-suite ...)` lines; `controls` must be added to `define-suites` in `tests/suites.lisp`.

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui::parse-control-spec` undefined.

- [ ] **Step 3: Implement `spec.lisp`** with the interfaces above. Valid units: `:hz :db :ms :percent :semitones :pan`. `:choices` combined with an explicitly supplied `:min`, `:max`, `:step`, or `:scale` is an error (use `-p` supplied flags).

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/spec.lisp src/gui/package.lisp sc-imgui.asd tests/suites.lisp tests/test-control-spec.lisp
git commit -m "feat: control value specifications and mapping"
```

---

### Task 3: Unit formatting and parsing

**Files:**
- Create: `src/gui/controls/units.lisp`
- Modify: `sc-imgui.asd` (add `units`), `tests/test-control-spec.lisp`

**Interfaces:**
- Consumes: `control-spec` (Task 2).
- Produces (internal):
    - `(format-control-value spec value)` → string: `:format` function if given (called with the value), else the choice name for choices, else the unit formatter, else a plain number with precision from the range (`max - min` ≥ 100 → 0 decimals, ≥ 10 → 1, else 2; integers always 0).
    - `(parse-control-text spec string)` → `(values value ok-p)`. Accepts the unit's own output and these forms: a bare number in the unit's base (`-6` for dB, `440` for Hz); `k`/`kHz` (×1000, Hz); `s` (×1000, ms); `%` (÷100, percent); `L`/`R`/`C` for pan (`25R` → 0.5, `50L` → -1.0, `C` → 0); a choice name (case-insensitive) for choices. Whitespace and unit case are ignored. Returns `(values nil nil)` for anything else. The value is not clamped here.

- [ ] **Step 1: Write the failing tests**

```lisp
(test unit-formatting
  (flet ((f (unit v &rest args) (gui::format-control-value (apply #'spec :unit unit args) v)))
    (is (string= "440 Hz" (f :hz 440.0 :min 20 :max 20000)))
    (is (string= "999 Hz" (f :hz 999.0 :min 20 :max 20000)))
    (is (string= "1.00 kHz" (f :hz 1000.0 :min 20 :max 20000)))
    (is (string= "2.40 kHz" (f :hz 2400.0 :min 20 :max 20000)))
    (is (string= "-6.0 dB" (f :db -6.0 :min -70 :max 6)))
    (is (string= "-inf dB" (f :db -70.0 :min -70 :max 6)))
    (is (string= "120 ms" (f :ms 120.0 :min 0 :max 5000)))
    (is (string= "1.20 s" (f :ms 1200.0 :min 0 :max 5000)))
    (is (string= "62 %" (f :percent 0.62)))
    (is (string= "+3 st" (f :semitones 3 :value 3 :min -12 :max 12)))
    (is (string= "0 st" (f :semitones 0 :value 0 :min -12 :max 12)))
    (is (string= "C" (f :pan 0.0 :min -1 :max 1)))
    (is (string= "25R" (f :pan 0.5 :min -1 :max 1)))
    (is (string= "50L" (f :pan -1.0 :min -1 :max 1)))))

(test choice-and-custom-formatting
  (is (string= "Saw" (gui::format-control-value (spec :value 1 :choices '("Sine" "Saw")) 1)))
  (is (string= "x7" (gui::format-control-value (spec :format (lambda (v) (format nil "x~D" (round v)))) 7.0))))

(test text-parsing
  (flet ((p (unit text &rest args) (gui::parse-control-text (apply #'spec :unit unit args) text)))
    (is (= 2000 (p :hz "2k" :min 20 :max 20000)))
    (is (= 2400 (p :hz "2.4 kHz" :min 20 :max 20000)))
    (is (= -6 (p :db "-6 dB" :min -70 :max 6)))
    (is (= -6 (p :db "-6" :min -70 :max 6)))
    (is (= 1200 (p :ms "1.2s" :min 0 :max 5000)))
    (is (= 0.5 (p :pan "25R" :min -1 :max 1)))
    (is (= 0.62 (p :percent "62%")))
    (is (equal '(nil nil) (multiple-value-list (p :hz "abc" :min 20 :max 20000))))
    (is (equal '(nil nil) (multiple-value-list (p :hz "2 kHzz" :min 20 :max 20000)))))
  (is (= 1 (gui::parse-control-text (spec :value 0 :choices '("Sine" "Saw")) "saw"))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui::format-control-value` undefined.

- [ ] **Step 3: Implement `units.lisp`** with the interfaces above, using the spec's "Display" table for formats. Parse numbers without `read-from-string` (no reader on user text): a small hand-written decimal parser.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/units.lisp sc-imgui.asd tests/test-control-spec.lisp
git commit -m "feat: unit formatting and text parsing for controls"
```

---

### Task 4: Control core and the number box

The core's interaction is proven through its simplest consumer, the number box.

**Files:**
- Create: `src/gui/controls/core.lisp`, `src/gui/controls/number-box.lisp`, `tests/test-controls.lisp`
- Modify: `tests/headless.lisp`, `sc-imgui.asd` (add `core`, `number-box`; test file `test-controls`), `src/gui/package.lisp` (export `number-box`, `number-box-value`)

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces (internal unless noted):
    - `(rem-px n)` → pixels for `n` rem at the current style `font-size-base`; `(:px n)` passes through.
    - `(control-color role &optional (alpha 1.0))` → packed colour of `(theme-color role)` with its alpha multiplied by `alpha` and by ImGui's style `alpha` (so `with-disabled` fades it).
    - `*control-states*`: `equal` hash table from ImGui item ID to a `control-state` struct (`position`, `edit-text`, `edit-error`). Entries are removed when their drag or edit ends, and any entry not touched in a frame where the left mouse button is up is removed at the end of that frame (so a control that vanished mid-drag leaves nothing behind).
    - `(defstruct control-frame x y width height value changed-p hovered-p active-p editing-p)`.
    - `(control-behavior label spec value &key width height (axis :vertical) value-rect)` → `control-frame`. Reserves `width` × `height` pixels at the cursor as one item via `gui:invisible-button`, then applies, in this order: double-click reset (`is-mouse-double-clicked-nil 0` while hovered) to `default`; Ctrl-click (`key-ctrl` at press) starts text entry (Task 5); drag along `axis` (`:vertical` up increases, `:horizontal` right increases, full range = `(rem-px 10)` pixels, ×0.1 with `key-shift`), accumulating the *unclamped-then-clamped* position in the state so overshoot doesn't need undoing; wheel while hovered (claim with `(set-item-key-owner-nil %imgui:+key-mouse-wheel-y+)`, read `mouse-wheel` from IO; 0.01 per notch, 0.001 with Shift, or one step for stepped specs). `value` in the frame is the new value (or the clamped display value when unchanged); `changed-p` only when user input changed it. `value-rect` (x y w h) is where text entry is drawn.
    - `(define-value-control name value-function)`: like `define-place-widget`, for controls taking a spec.
    - `gui:number-box` (macro) / `gui:number-box-value (label value &rest spec &key width)` → `(values new changed-p)`. Draws a `:frame` box (`:frame-hover` when hovered) with the formatted value centered in `:text-dim` (`:text` while active), and the label to the right in `:text-dim`. Height is the frame height; width defaults to fit the formatted `min`, `max`, and longest choice plus padding.
- Produces (harness, `tests/headless.lisp`):
    - `(frames-with-wheel x y notches draw-fn &key shift)`: move, then queue `im-gui-io-add-mouse-wheel-event` 0 `notches`; two frames.
    - `(frames-with-double-click x y draw-fn)`: move, press, release, press, release; one frame each.
    - `(with-keys-held (&rest mods) &body)`: queues `im-gui-io-add-key-event` down for each of `+mod-shift+`, `+mod-ctrl+` before the body and up after.
    - `frames-with-drag` gains `&key shift`.

- [ ] **Step 1: Add the harness helpers, then write the failing tests in `tests/test-controls.lisp`**

```lisp
(defmacro with-controls-env (() &body body)
  `(with-headless-imgui () (let ((gui:*theme* :mid-light)) (gui::apply-theme) ,@body)))

(test drag-up-increases
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:number-box "n" v))))
      (is (< (abs (- v 0.5)) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test shift-drag-is-ten-times-finer
  (with-controls-env ()
    (let ((v 0.0))
      (with-keys-held (:shift)
        (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:number-box "n" v)))))
      (is (< (abs (- v 0.05)) 0.005)))))

(test overshoot-then-reverse                          ; Review Focus 2
  (with-controls-env ()
    (let ((v 0.9))
      ;; drag far past max, then back down 1 rem without releasing: value drops at once
      (drag-path (list 0 (- (gui::rem-px 30)) (+ (gui::rem-px 1)))
                 (lambda () (in-window (gui:number-box "n" v))))
      (is (< (abs (- v 0.9)) 0.02)))))

(test double-click-resets
  (with-controls-env ()
    (let ((v 0.7))
      (click-item (lambda () (in-window (gui:number-box "n" v :default 0.25)))
                  :clicker #'frames-with-double-click)
      (is (= 0.25 v)))))

(test wheel-nudges
  (with-controls-env ()
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:number-box "n" v)))
                  :clicker (lambda (x y f) (frames-with-wheel x y 2 f)))
      (is (< (abs (- v 0.52)) 1e-4)))
    (let ((v 3))
      (click-item (lambda () (in-window (gui:number-box "n" v :min 0 :max 10)))
                  :clicker (lambda (x y f) (frames-with-wheel x y -1 f)))
      (is (eql 2 v)))))

(test drawing-never-writes
  (with-controls-env ()
    (let ((v 7.5) (writes 0))
      (dotimes (i 3)
        (with-test-frame ()
          (in-window (when (nth-value 1 (gui:number-box-value "n" v :min 0 :max 1)) (incf writes)))))
      (is (= 0 writes)) (is (= 7.5 v)))))

(test choices-non-integer-place                       ; Review Focus 3
  (with-controls-env ()
    (let ((v 1.5))
      (signals gui:widget-value-error
        (with-test-frame () (in-window (gui:number-box "n" v :choices '("a" "b"))))))))

(test disabled-ignores-input
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 -50 (lambda () (in-window (gui:with-disabled () (gui:number-box "n" v)))))
      (is (= 0.0 v)))))

(test font-size-change-mid-drag                       ; Review Focus 5
  (with-controls-env ()
    (let ((v 0.0))
      (drag-path (list 0 -20 -20)
                 (lambda () (in-window (gui:number-box "n" v)))
                 :between (lambda (i) (when (= i 1) (set-base-font-size 20.0))))
      (is (< 0.0 v 1.0)))
    (is (= 0 (%shim:assert-count)))))

(test state-removed-after-release
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 -20 (lambda () (in-window (gui:number-box "n" v))))
      (is (= 0 (hash-table-count gui::*control-states*))))))

(test state-removed-when-control-vanishes-mid-drag
  (with-controls-env ()
    (let ((v 0.0) (shown t))
      (drag-path (list 0 -20 -20)
                 (lambda () (in-window (when shown (gui:number-box "n" v))))
                 :between (lambda (i) (when (= i 1) (setf shown nil))))
      (is (= 0 (hash-table-count gui::*control-states*))))))

(test signalling-format-function-propagates
  (with-controls-env ()
    (let ((v 0.5))
      (signals error
        (with-test-frame ()
          (in-window (gui:number-box "n" v :format (lambda (x) (declare (ignore x)) (error "boom")))))))))
```

Further harness helpers these tests use, also in `tests/headless.lisp`: `click-item` gains `&key clicker` (a function of x, y, draw-fn; default `frames-with-click`); `(drag-path dys draw-fn &key between)` presses at the primed item's center, moves by each successive `dy` (relative to the previous position) one frame each, calls `between` with the step index before each frame, then releases; `(set-base-font-size px)` sets the style's `font-size-base`.

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui:number-box` undefined.

- [ ] **Step 3: Implement `core.lisp` and `number-box.lisp`** with the interfaces above. `number-box-value` checks its value with `%check` (`real`, or `integer` for choices) before anything else. Set the mouse cursor to `+mouse-cursor-none+` while dragging, as Live hides it.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/core.lisp src/gui/controls/number-box.lisp src/gui/package.lisp sc-imgui.asd tests/headless.lisp tests/test-controls.lisp
git commit -m "feat: control core and gui:number-box"
```

---

### Task 5: Typed entry

**Files:**
- Modify: `src/gui/controls/core.lisp`, `tests/test-controls.lisp`, `tests/headless.lisp`

**Interfaces:**
- Consumes: `control-behavior`, `parse-control-text`, `format-control-value`, `control-color`.
- Produces: text entry inside `control-behavior`, used by every control that passes `value-rect`:
    - Ctrl-click (press with `key-ctrl`) sets the state's `edit-text` to the formatted value and `editing-p` true. While editing, the core draws `%imgui:input-text` over `value-rect` (with `set-keyboard-focus-here` on the first frame, `+input-text-flags-enter-returns-true+` and `+input-text-flags-auto-select-all+`).
    - Enter: `parse-control-text`; on success, clamp and snap, return it as changed, end editing. On failure, set `edit-error`, keep editing, keep the text. `edit-error` clears when the text changes.
    - While `edit-error`, draw a 1 px rectangle in `(control-color :error)` around `value-rect`.
    - Escape, or the field losing focus without Enter, ends editing with no change.
- Produces (harness): `(press-key key draw-fn)` queues a key down and up for `key` (`+key-enter+`, `+key-escape+`) across two frames.

- [ ] **Step 1: Write the failing tests**

```lisp
(defun ctrl-click (draw)
  (with-keys-held (:ctrl) (click-item draw)))

(test typed-entry-commits
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :scale :log :unit :hz)))))
      (ctrl-click draw)
      (type-text "2k" draw)                 ; replaces the auto-selected text
      (press-key %imgui:+key-enter+ draw)
      (is (= 2000.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))))

(test bad-entry-stays-open-then-corrects
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (type-text "abc" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (= 440.0 v))
      (let ((state (first (alexandria:hash-table-values gui::*control-states*))))
        (is (gui::control-state-edit-error state))
        (is (string= "abc" (gui::control-state-edit-text state))))
      (dotimes (i 3) (press-key %imgui:+key-backspace+ draw))
      (type-text "500" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (= 500.0 v)))))

(test escape-cancels
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (type-text "900" draw)
      (press-key %imgui:+key-escape+ draw)
      (is (= 440.0 v)))))

(test escape-keeps-code-change                        ; Review Focus 4
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (setf v 880.0)                         ; a pattern changes the value meanwhile
      (press-key %imgui:+key-escape+ draw)
      (is (= 880.0 v)))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; the value is unchanged after Enter.

- [ ] **Step 3: Implement typed entry in `core.lisp`** as described, using a foreign buffer per editing control (allocate on start, free on end) sized 64 bytes; it never writes the place except on a successful Enter.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/core.lisp tests/test-controls.lisp tests/headless.lisp
git commit -m "feat: typed entry for controls, with error outline"
```

---

### Task 6: Knob

**Files:**
- Create: `src/gui/controls/knob.lisp`
- Modify: `sc-imgui.asd` (add `knob`), `src/gui/package.lisp` (export `knob`, `knob-value`), `tests/test-controls.lisp`

**Interfaces:**
- Consumes: the core (Task 4), typed entry (Task 5).
- Produces: `gui:knob` (macro), `gui:knob-value (label value &rest spec &key (size 2.5))` → `(values new changed-p)`. Item width = `size` + 0.5 rem; height = one text line + `size` + one text line + item spacing between. Drawing per the spec's "Knob" section: arc from 3π/4 to 9π/4 (270°, open at the bottom), track in `:frame` (`:frame-hover` when hovered), value arc in `:accent` from the origin's angle to the value's, pointer line from 30% to 90% of the radius in `:text`. Label and value centered, clipped to the item width with `%imgui:push-clip-rect`/`pop-clip-rect`. The value line is the `value-rect`.

- [ ] **Step 1: Write the failing tests**

```lisp
(test knob-drags-and-keeps-type
  (with-controls-env ()
    (let ((v 0.0d0))
      (prime-and-drag 0 (- (gui::rem-px 10)) (lambda () (in-window (gui:knob "k" v))))
      (is (typep v 'double-float)) (is (> v 0.99d0)))))

(test knob-draws-nonpositive-log-value                ; Review Focus 1
  (with-controls-env ()
    (let ((v 0))
      (with-test-frame () (in-window (gui:knob "f" v :min 20 :max 20000 :scale :log :unit :hz)))
      (is (eql 0 v)) (is (= 0 (%shim:assert-count))))))

(test knob-row-aligns-at-two-sizes
  (with-controls-env ()
    (dolist (px '(13.0 15.0))
      (set-base-font-size px)
      (let (rects)
        (with-test-frame ()
          (in-window (gui:with-row ()
                       (progn (gui:knob-value "Cutoff frequency" 0.5) (push (last-item-rect) rects))
                       (progn (gui:knob-value "Q" 0.5) (push (last-item-rect) rects)))))
        (destructuring-bind ((ax1 ay1 ax2 ay2) (bx1 by1 bx2 by2)) (reverse rects)
          (is (= ay1 by1))                                      ; common top edge
          (is (= (- ax2 ax1) (- bx2 bx1)))                      ; equal widths despite labels
          (is (< (abs (- (- ax2 ax1) (* 3.0 px))) 1.0))         ; 2.5 + 0.5 rem
          (is (= (- ay2 ay1) (- by2 by1))))))))

(test knob-bipolar-choices-draw-cleanly
  (with-controls-env ()
    (let ((pan 0.0) (wave 1))
      (with-test-frame ()
        (in-window (gui:knob "Pan" pan :min -1 :max 1 :bipolar t :unit :pan)
                   (gui:knob "Wave" wave :choices '("Sine" "Saw" "Square"))))
      (is (= 0 (%shim:assert-count))))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui:knob` undefined.

- [ ] **Step 3: Implement `knob.lisp`** with the interface above.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/knob.lisp src/gui/package.lisp sc-imgui.asd tests/test-controls.lisp
git commit -m "feat: gui:knob"
```

---

### Task 7: Fader

**Files:**
- Create: `src/gui/controls/fader.lisp`
- Modify: `sc-imgui.asd` (add `fader`), `src/gui/package.lisp` (export `fader`, `fader-value`), `tests/test-controls.lisp`

**Interfaces:**
- Produces: `gui:fader` (macro), `gui:fader-value (label value &rest spec &key vertical length thickness)` → `(values new changed-p)`. Horizontal: width `length` rem or `(content-region-avail)` width; height `thickness` rem or `%imgui:get-frame-height`; `axis :horizontal`; label left and value right inside the bar (`value-rect` is the right half). Vertical: width `thickness` rem or frame height ×1.5; bar height `length` rem (default 8); label above, value below; `axis :vertical`. Fill in `:accent` from the origin; track `:frame`/`:frame-hover`.

- [ ] **Step 1: Write the failing tests**

```lisp
(test horizontal-fader-follows-horizontal-drag
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag (gui::rem-px 5) 0 (lambda () (in-window (gui:fader "Vol" v))))
      (is (< (abs (- v 0.5)) 0.02)))
    (let ((v 0.0))
      (prime-and-drag 0 -50 (lambda () (in-window (gui:fader "Vol" v))))
      (is (= 0.0 v)))))

(test vertical-fader-follows-vertical-drag
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:fader "Vol" v :vertical t))))
      (is (< (abs (- v 0.5)) 0.02)))))

(test fader-fills-width-and-bipolar-draws
  (with-controls-env ()
    (let ((v 0.0))
      (with-test-frame () (in-window (gui:fader "Pan" v :min -1 :max 1 :bipolar t :unit :pan)))
      (let ((r (last-item-rect-of (lambda () (in-window (gui:fader "Pan" v :min -1 :max 1))))))
        (is (> (- (third r) (first r)) (* 0.8 (gui::rem-px 20)))))
      (is (= 0 (%shim:assert-count))))))
```

(`last-item-rect-of` draws once and returns `*item-rect*`; add it to the harness if Task 4 didn't.)

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui:fader` undefined.

- [ ] **Step 3: Implement `fader.lisp`.**

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/fader.lisp src/gui/package.lisp sc-imgui.asd tests/test-controls.lisp
git commit -m "feat: gui:fader, horizontal and vertical"
```

---

### Task 8: Toggle and trigger

**Files:**
- Create: `src/gui/controls/buttons.lisp`
- Modify: `sc-imgui.asd` (add `buttons`), `src/gui/package.lisp` (export `toggle`, `toggle-value`, `trigger`), `tests/test-controls.lisp`

**Interfaces:**
- Produces:
    - `gui:toggle` (macro), `gui:toggle-value (label value &key width)` → `(values new changed-p)`; a click flips the generalized boolean, written back as `t`/`nil`. Lit `:accent` with `:accent-text` when on; `:control`/`:control-hover` with `:text` when off. Width `width` rem or label width plus 1 rem; height frame height. Doesn't use the value specification.
    - `gui:trigger (label &key width)` → `(values pressed-p held-p released-p)`, using `is-item-activated`, `is-item-active`, `is-item-deactivated`. Lit `:accent` while held.

- [ ] **Step 1: Write the failing tests**

```lisp
(test toggle-flips
  (with-controls-env ()
    (let ((on nil))
      (click-item (lambda () (in-window (gui:toggle "Mute" on))))
      (is (eq t on))
      (click-item (lambda () (in-window (gui:toggle "Mute" on))))
      (is (eq nil on)))))

(test trigger-reports-press-hold-release
  (with-controls-env ()
    (let ((frames (click-item (lambda () (in-window (multiple-value-list (gui:trigger "Hit")))))))
      ;; click-item frames: move, press, release, idle (after two priming frames)
      (is (equal '((nil nil nil) (t t nil) (nil nil t) (nil nil nil)) frames)))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui:toggle` undefined.

- [ ] **Step 3: Implement `buttons.lisp`.**

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/buttons.lisp src/gui/package.lisp sc-imgui.asd tests/test-controls.lisp
git commit -m "feat: gui:toggle and gui:trigger"
```

---

### Task 9: XY pad

**Files:**
- Create: `src/gui/controls/xy-pad.lisp`
- Modify: `sc-imgui.asd` (add `xy-pad`), `src/gui/package.lisp` (export `xy-pad`, `xy-pad-value`), `tests/test-controls.lisp`

**Interfaces:**
- Produces:
    - `gui:xy-pad (label x-place y-place &key x y (size 8))`: macro; `x` and `y` are evaluated spec plists. Writes whichever place changed; returns true if either did. Uses `get-setf-expansion` for both places, evaluating subforms once.
    - `gui:xy-pad-value (label x-value y-value &key x y (size 8))` → `(values new-x new-y changed-p)`.
    - Behaviour per the spec's "XY pad" section: press moves the point to the mouse (position from the pad's rect, y up = increasing); dragging follows absolutely; with Shift the drag is relative at 0.1×; double-click resets both. Uses the core's state table and `control-color`, not `control-behavior`'s drag (different interaction), but the same double-click and disabled handling.

- [ ] **Step 1: Write the failing tests**

```lisp
(test xy-click-jumps-and-shift-drags-finely
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      ;; click the pad's center: both go to 0.5
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y))))
      (is (< (abs (- x 0.5)) 0.02)) (is (< (abs (- y 0.5)) 0.02))
      (let ((x0 x))
        (with-keys-held (:shift)
          (prime-and-drag (gui::rem-px 4) 0 (lambda () (in-window (gui:xy-pad "xy" x y)))))
        (is (< (abs (- (- x x0) 0.05)) 0.01))))))

(test xy-axes-have-own-specs
  (with-controls-env ()
    (let ((f 440.0) (q 0.5))
      (with-test-frame ()
        (in-window (gui:xy-pad "Filter" f q :x '(:min 20 :max 20000 :scale :log :unit :hz)
                                            :y '(:unit :percent))))
      (is (= 440.0 f)) (is (= 0 (%shim:assert-count))))))

(test xy-double-click-resets-both
  (with-controls-env ()
    (let ((x 0.9) (y 0.9))
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y :x '(:default 0.1) :y '(:default 0.2))))
                  :clicker #'frames-with-double-click)
      (is (= 0.1 x)) (is (= 0.2 y)))))
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `make test SUITE=controls`. Expected: FAIL; `gui:xy-pad` undefined.

- [ ] **Step 3: Implement `xy-pad.lisp`.** Draw a `:frame` square, three grid lines per axis in `(control-color :border)`, crosshair lines in `(control-color :text-dim 0.6)`, a 0.25 rem point in `:accent`; label above, `"<x> / <y>"` below.

- [ ] **Step 4: Run them to confirm they pass**

Run: `make test SUITE=controls`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/controls/xy-pad.lisp src/gui/package.lisp sc-imgui.asd tests/test-controls.lisp
git commit -m "feat: gui:xy-pad"
```

---

### Task 10: Example and documentation

**Files:**
- Create: `examples/controls.lisp`
- Modify: `tests/test-examples.lisp`, `examples/README.md`, `src/gui/README.md`, `tests/README.md`

**Interfaces:**
- Consumes: all six controls.

- [ ] **Step 1: Add `"controls.lisp"` to the list in `examples-run-cleanly`** in `tests/test-examples.lisp`, then run `make test SUITE=examples`. Expected: FAIL; the file doesn't exist.

- [ ] **Step 2: Write `examples/controls.lisp`**: a Live-style synth device in one window, using every control: a row of knobs (log cutoff in Hz, resonance in percent, bipolar pan, a choices waveform knob), a horizontal volume fader in dB, a vertical fader, a toggle and a trigger, a number box in semitones, and an XY pad over cutoff and resonance. No cl-collider: values print with `gui:text`. Same header and conventions as the other examples (`cl-user`, `example-` prefixes, no `gui:start`).

- [ ] **Step 3: Run it to confirm it passes**

Run: `make test SUITE=examples`. Expected: all checks pass.

- [ ] **Step 4: Update the docs**
- `src/gui/README.md`: a "Controls" section after Widgets: the value specification table, the units table, the interaction list (including Cmd/Ctrl-click and the error outline), each control's signature and description, choices, layout and sizing rules, `control-spec-error`; quick-reference rows; a recipe from the spec's layout example; the `:error` role in the themes section; in "Building a custom widget", note that `gui:knob` now exists and the walkthrough shows how controls are built.
- `tests/README.md`: the `controls` suite, its files, the new harness helpers, and coverage-map rows.
- `examples/README.md`: the new example.

- [ ] **Step 5: Run the full suite and the smoke test**

Run: `make test`, then `make smoke`. Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add examples tests src/gui/README.md
git commit -m "docs: controls example and documentation"
```

- [ ] **Step 7: Manual check on macOS (ask the user)**

In SLIME: `(gui:start)`, load `examples/controls.lisp`. Check: drag speed and Shift feel right; Cmd-click typing works, including the error outline on bad input; double-click and wheel work; both themes look right (`(gui:set-theme :dark)`); controls scale cleanly with `(gui:set-font-size 13)` and `20`; the cursor hides while dragging.
