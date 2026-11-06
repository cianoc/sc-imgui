# Design spec: audio controls (part 3a)

2026-11-05

## Purpose and context

Part 3 of the cl-collider GUI toolkit adds Ableton Live-style audio controls. It is split in two:

- **Part 3a (this spec):** single-value controls: knob, fader, toggle, trigger, number box, and XY pad.
- **Part 3b (a later spec):** editors: the envelope editor and the step sequencer grid.

The controls are built on the foundation (part 1, `docs/superpowers/specs/2026-11-04-imgui-foundation-design.md`) and the themes (`src/gui/theme.lisp`). They don't depend on cl-collider or on the parameter store (part 2): they edit any Lisp place, so part 2 later becomes one more kind of place.

### Requirements

Confirmed:

- Controls look and handle like Live's, and take their colours from the active theme.
- Every value control supports: vertical drag with Shift for fine adjustment, double-click to reset to a default, mouse-wheel nudges, and Cmd/Ctrl-click to type an exact value.
- Values display with units (`:hz`, `:db`, `:ms`, `:percent`, `:semitones`, `:pan`) or a custom formatting function.
- Value mappings: linear and logarithmic; bipolar (drawn from an origin); stepped (integers or a step size); named choices.
- The controls sit beside the existing `gui` widgets with distinct names; `gui:slider`, `gui:checkbox`, and `gui:button` are unchanged.
- Typed text that can't be parsed keeps the entry field open, marked with an error colour, so it can be corrected.

Assumptions:

- Calling convention matches the existing widgets: a place-taking macro that returns true on change, plus a `-value` function.
- All sizes scale with the base font size (rem), like the theme's spacing.

### Success criteria

- A synth panel that looks and handles like a Live device can be built entirely from the REPL with these controls.
- All six controls behave identically wherever their behaviour overlaps, because they share one implementation of interaction and display.
- Controls follow `gui:set-theme` and `gui:set-font-size` live.
- No changes to the native shim.

## Approach

**Lisp controls on a shared control core.** One internal layer, the *control core*, implements everything controls share: value mapping, interaction, formatting, parsing, and the place and `-value` plumbing. Each control is a small Lisp function that reserves its area with an invisible button, hands interaction to the core, and draws itself with the draw-list primitives and `theme-color`.

All needed ImGui functionality is already in the generated bindings: `is-mouse-double-clicked-nil`, `set-item-key-owner-nil` (claiming the mouse wheel), `set-keyboard-focus-here`, `input-text`, `get-item-id`, `set-mouse-cursor`, and the `ImGuiIO` fields `mouse-wheel`, `key-shift`, `key-ctrl`, and `key-super`.

Rejected alternatives:

- **Controls in C++ inside the shim,** using ImGui's internal widget helpers: loses live redefinition, depends on ImGui's unstable internal API, and makes the shim no longer thin.
- **An existing C++ knob library:** covers only knobs, doesn't match Live or the other controls, and adds C++ widget code.

## The control core

Lives in a new directory, `src/gui/controls/`. Controls never handle the mouse or format values themselves.

### Value specification

Every value control (knob, fader, number box, and each axis of the XY pad) takes the same keyword arguments:

| Argument | Meaning |
| --- | --- |
| `:min`, `:max` | Range. Defaults 0 and 1. |
| `:scale` | `:linear` (default) or `:log`. `:log` requires `min` > 0. |
| `:step` | Snap to multiples of this. An integer value with no `:step` snaps to 1, so integer places stay integers. |
| `:choices` | A list of strings. The value is an index, and the control steps through the choices. Replaces `:min`, `:max`, and `:step`. |
| `:bipolar` | Draw the arc or fill from an origin rather than from `min`. `t` uses 0 if the range includes it, otherwise the midpoint; a number sets the origin. |
| `:default` | Value for double-click reset. Defaults to the origin when bipolar, otherwise `min`. |
| `:unit` | A built-in formatter; see [Display](#display). |
| `:format` | A function of the value returning a string. Overrides `:unit`. |

Internally the core converts between the value and a *position* from 0 to 1, applying the scale. Steps and choices are applied when converting a position back to a value.

### Interaction

Identical for every value control, except where a control says otherwise:

- **Drag vertically,** up to increase. A full sweep of the range takes 10 rem of travel; Shift makes it 10 times finer. During a drag the core accumulates the unsnapped position, so stepped and choice controls don't stick between steps.
- **Double-click** resets to `:default`.
- **Mouse wheel,** while hovered, moves 1% of the range per notch, or one step for stepped controls and choices. Shift makes it 0.1%. The control claims the wheel, so the window doesn't scroll under it.
- **Cmd-click** on macOS (Ctrl-click on Linux and Windows) opens a text field in place of the value:
    - Enter parses the text with the control's unit. `2k`, `2.4 kHz`, `-6`, `-6 dB`, and `25R` all work. The result is clamped and snapped, and the field closes.
    - If the text can't be parsed, Enter leaves the field open with the text unchanged, outlined in the theme's `:error` colour, and the value unchanged. The outline clears when the text is edited.
    - Escape or clicking elsewhere cancels, leaving the value unchanged.

### Display

`:unit` selects a formatter, which is also used to parse typed text:

| Unit | Values | Display |
| --- | --- | --- |
| `:hz` | frequency in Hz | `440 Hz`, `2.40 kHz` (kHz from 1000) |
| `:db` | level in dB | `-6.0 dB`; `-inf dB` at or below -70 |
| `:ms` | time in ms | `120 ms`, `1.20 s` (s from 1000) |
| `:percent` | 0 to 1 | `62 %` |
| `:semitones` | semitones | `+3 st`, `-12 st`, `0 st` |
| `:pan` | -1 to 1 | `50L`, `C`, `25R` (Live's 50L–50R scale) |

With neither `:unit` nor `:format`, numbers show with a precision suited to the range. Choice controls show the selected choice's name.

### Calling convention

Each value control is a macro taking a place, written with the existing `define-place-widget` pattern:

```lisp
(gui:knob "Cutoff" *cutoff* :min 20 :max 20000 :scale :log :unit :hz)
```

It writes the new value back to the place and returns true when the value changed. A `-value` function (`knob-value`, `fader-value`, `number-box-value`) takes the current value and returns `(values new-value changed-p)`, writing nothing. `changed-p` is true on every frame the value changes during a drag, so code such as `ctrl` can follow it continuously.

### Per-control state

State that lasts across frames, such as a drag in progress (the accumulated position) or an open text field (its text and error flag), lives in a Lisp table keyed by ImGui's item ID. An entry is removed when its drag or edit ends. If a control disappears mid-interaction, because its panel failed or was hidden, its entry is removed when the mouse button is released. Nothing persists between uses.

## The controls

All use the value specification above unless stated, and draw only with `theme-color`, so they follow the active theme.

### Knob

`(gui:knob label place &rest spec &key (size 2.5))`

- The label above in `:text-dim`, a 270° arc open at the bottom, and the formatted value below.
- The track arc in `:frame`; the value arc in `:accent`, from `min`, or from the origin when bipolar; a short pointer line at the current position.
- `size` is the arc's diameter in rem.

### Fader

`(gui:fader label place &rest spec &key vertical length thickness)`

- **Horizontal** (the default), like Live's bar slider: a flat bar in `:frame`, filled in `:accent` up to the value, with the label left-aligned and the value right-aligned inside the bar. It fills the available width unless `length` is given in rem.
- **Vertical** (`:vertical t`), mixer style: filled from the bottom, with the label above and the value below.
- `thickness` defaults to ImGui's frame height (the font size plus twice the vertical frame padding), so a horizontal fader is as tall as other controls on its row; a vertical fader's `length` defaults to 8 rem.
- Bipolar fill grows out from the origin.
- **Exception to the core:** a fader drags along its own axis, so a horizontal fader follows horizontal drags. All other core interaction applies.

### Toggle

`(gui:toggle label place &key width)`

- A rectangular button showing the label: lit in `:accent` with `:accent-text` when on, `:control` with `:text` when off. A click flips the boolean in `place`.
- No value specification, wheel, or typed entry.
- `toggle-value` returns `(values new-value changed-p)`.

### Trigger

`(gui:trigger label &key width)`

- A momentary button; no place.
- Returns three values: true on the frame it's pressed, true while it's held, true on the frame it's released.
- Lit in `:accent` while held.

### Number box

`(gui:number-box label place &rest spec &key width)`

- Live's compact number field: the formatted value in a small `:frame` box, with the label beside it.
- All core interaction, including typed entry.
- Its width defaults to fit the longest value it can display; `width` sets it in rem.

### XY pad

`(gui:xy-pad label x-place y-place &key x y (size 8))`

- `x` and `y` are each a value specification as a list, for example `:x '(:min 20 :max 20000 :scale :log :unit :hz)`.
- A square in `:frame`, with faint grid lines in `:border`, crosshair lines through the current point, and the point in `:accent`. The label above, both values below.
- **Different interaction:** pressing anywhere moves the point there, and dragging follows the mouse directly. Shift-drag switches to relative, fine movement. Double-click resets both axes. No wheel or typed entry.
- The macro writes whichever places changed and returns true if either did. `xy-pad-value` returns `(values x y changed-p)`.

### Choices

`:choices` works on knobs, faders, and number boxes:

```lisp
(gui:knob "Wave" *wave* :choices '("Sine" "Saw" "Square" "Noise"))
```

## Layout and sizing

- **All sizes are in rem**, multiples of the base font size: knob diameters, fader lengths and thickness, box widths, and the XY pad's size. They scale with `gui:set-font-size`. A size given as `(:px n)` is fixed.
- **One control, one ImGui item.** Each control reserves a single rectangle covering everything it draws, including its label and value text, so `with-row`, `with-grid`, and `with-group` treat it as one unit, and a row of controls shares a top edge.
- **Widths are a fixed number of rem, independent of the label and value text.** A knob's width is its diameter plus 0.5 rem. Text wider than the control is clipped at its edge, so rows stay aligned as values change. Number boxes and toggles likewise keep their width when their text changes.
- **Feedback states,** from the theme:
    - Hovered: the track changes from `:frame` to `:frame-hover`.
    - Active (being dragged or edited): the value text is drawn in `:text` at full strength.
    - Disabled (inside `gui:with-disabled`): input is ignored, and every colour the control draws is multiplied by ImGui's current style alpha, so it fades exactly as stock widgets do.
- **IDs** follow the usual rules: the label is the ID, `##` hides a suffix, and `with-id` separates repeated controls.

Example:

```lisp
(gui:with-window ("Saw")
  (gui:with-row ()
    (gui:knob "Cutoff" *cutoff* :min 20 :max 20000 :scale :log :unit :hz)
    (gui:knob "Res" *res* :unit :percent)
    (gui:knob "Pan" *pan* :min -1 :max 1 :bipolar t :unit :pan))
  (gui:fader "Volume" *vol* :min -70 :max 6 :default 0 :unit :db)
  (gui:with-row ()
    (gui:toggle "Mute" *mute*)
    (when (gui:trigger "Hit") (play-note))))
```

## Theme change: the `:error` role

The theme palette gains an `:error` role, used to outline an invalid text entry, and available to other code through `(gui:theme-color :error)`.

| Theme | `:error` |
| --- | --- |
| `:mid-light` | `#b3261e` |
| `:dark` | `#e5534b` |

Values are checked for contrast against each theme's `:frame` and may be tuned at the manual check. Themes inherit it through `:base`; a theme defined without `:base` must supply it, like every other role. ImGui's stock widgets don't use it.

## Errors

- **Wrong value type** (for example a `nil` place, or a string where a number belongs) signals `gui:widget-value-error` naming the label, before any foreign call.
- **Invalid specifications** signal an error naming the label and the problem: `min` not below `max`; `:log` with `min` ≤ 0; a non-positive `:step`; empty or non-string `:choices`, or `:choices` combined with `:min`, `:max`, `:step`, or `:scale`; a `:default` outside the range; an unknown `:unit`; a malformed `:x` or `:y`.
- **A value outside the range** (for example set from code) is displayed clamped but not written back unless the user changes the control. Drawing a control never changes its value.
- **Types are preserved:** a `double-float` stays a `double-float`; integers and choice indexes stay integers.
- **A `:format` function that signals** fails the panel, like any other error in panel code.

Inside a panel, all of these fail the panel through the existing runtime error handling.

## Testing

**New `controls` suite, pure Lisp (no ImGui):**

- Mapping round trips for linear, log, stepped, choices, and bipolar origins.
- Formatting at boundaries: `999 Hz` and `1.00 kHz`, `-inf dB`, `C` for pan, `0 st`.
- Parsing typed text: `2k`, `2.4 kHz`, `-6 dB`, `25R`; rejecting garbage.
- Every specification error.

**Same suite, headless interaction** through the test harness, for each control:

- A drag up increases the value by the expected amount; Shift makes it 10 times finer.
- Double-click resets to the default; wheel notches move 1% or one step, and 0.1% with Shift.
- Cmd/Ctrl-click, typing, and Enter set the value; garbage and Enter leave the field open and the value unchanged; correcting it and Enter commits; Escape cancels.
- A horizontal fader follows a horizontal drag; the XY pad jumps to a click and moves finely with Shift.
- A toggle flips; a trigger reports pressed, held, and released on the right frames.
- Inside `with-disabled`, input is ignored.
- Places are written only on change; out-of-range values aren't rewritten.
- A row of knobs shares a top edge and equal widths at font sizes 13 and 15.
- No ImGui assertions in any case.

The harness gains helpers for mouse-wheel events and modifier keys, using the bound `im-gui-io-add-mouse-wheel-event` and `im-gui-io-add-key-event`.

**`theme` suite:** both shipped themes define `:error`; a theme without `:base` and without `:error` is rejected.

**Examples:** a new `examples/controls.lisp`, a Live-style synth device using all six controls, loaded headlessly by the `examples` suite.

**Manual check on macOS:** drag speed and Shift feel right; both themes look good; controls scale cleanly with `set-font-size`; typed entry works with the error outline.

## Documentation

- `src/gui/README.md`: a "Controls" section (quick reference, reference for each control and the value specification, units, interaction, the device recipe), the `:error` role in the themes section, and the custom widget walkthrough pointing to `gui:knob`.
- `tests/README.md`: the `controls` suite and the coverage map.

## Out of scope

| Item | Where it goes |
| --- | --- |
| Envelope editor, step sequencer grid | Part 3b |
| Binding controls to synth parameters by name | Part 2 (parameter store) |
| Meters and scopes | Part 4 |
| Declarative panels | Part 5 |
| Tooltips, hover help text | Later, if wanted |
| MIDI learn | Outside this toolkit |
