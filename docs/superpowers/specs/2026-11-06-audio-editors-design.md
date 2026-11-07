# Design spec: audio editors (part 3b)

2026-11-06

## Purpose and context

Part 3 of the cl-collider GUI toolkit adds Ableton Live-style audio controls. It is split in two:

- **Part 3a** (`docs/superpowers/specs/2026-11-05-audio-controls-design.md`, done): single-value controls (knob, fader, toggle, trigger, number box, XY pad) on a shared control core.
- **Part 3b (this spec):** editors: an envelope editor, a drum sequencer, and a melodic sequencer.

Like the controls, the editors edit any Lisp place and don't depend on cl-collider or on the parameter store (part 2). They're built on the part 3a control core (`src/gui/controls/core.lisp`) and the themes.

### Requirements

Confirmed:

- **Envelope editor:**
    - Edits free breakpoints with a curve per segment.
    - Supports release and loop nodes.
    - Supports every SuperCollider curve: numeric curvature and all named curves.
    - Its value converts directly to cl-collider's `env` arguments.
    - Convenience constructors mirror cl-collider's `env-triangle`, `env-sine`, `env-perc`, `env-linen`, `env-cutoff`, `env-dadsr`, `env-adsr`, and `env-asr`.
- **Sequencers:**
    - The drum sequencer has rows of steps, each step holding a velocity. The melodic sequencer has steps, each holding note, velocity, gate, and on/off.
    - Both show a playhead and support optional scale snapping (melodic only).
- **Timing:**
    - A pattern has `bars`, `bar-length` (beats per bar), and `step-resolution` (steps per beat).
    - Bar, beat, and step lines are drawn in distinct colours.
    - Bars are numbered from 1.
- **Length:**
    - A pattern can be played shorter than its capacity. Steps past the length are remembered but not played.
    - Length changes in the GUI by dragging the end marker. Capacity and timing change only from code.
- **Editing, modelled on Live:**
    - Select and Draw modes; selection, cut, copy, paste, duplicate, and delete.
    - Dragging moves the selection, and Option/Alt-drag copies it.
    - Undo and redo, per editor.
- **Row names:**
    - Drum rows default to numbers from 0.
    - Melodic rows default to MIDI note names (C4 = 60).
    - Both accept symbols, numbers, and strings as names.

Assumptions:

- The calling convention matches the part 3a controls: a place-taking macro that returns true on change, plus a `-value` function.
- All sizes are in rem, like the controls.
- MIDI is out of scope. Every value can be set from code, which covers it.

### Success criteria

- A drum part, a bass line, and an amp envelope can each be edited from the REPL and read by a cl-collider pattern thread without locks.
- `(gui:envelope-env e)` turns the envelope editor's value into a cl-collider envelope in one call.
- Editing feels like Live in the cases this spec covers.
- The editors follow `gui:set-theme` and `gui:set-font-size` live.
- No changes to the native shim.

## Approach

**Immutable values, written back to the place.** Envelopes and patterns are immutable structures. An edit builds a new value and writes it to the place in one assignment, so a pattern thread reading the place always sees a complete value, never a half-finished edit. Code changes values the same way: through `with-` functions that return a copy.

**Editors built like the controls.** Each editor reserves one rectangle with an invisible button, reads the mouse and keyboard itself (using the control core's helpers for drag deltas, the wheel, modifiers, and typed entry), and draws with the draw-list primitives and `theme-color`. Per-editor state (mode, selection, undo history, a drag in progress) lives in a table keyed by ImGui item ID, like `*control-states*`. Unlike control state, it is kept for the session, so undo history survives a panel being hidden (see [Undo](#undo)).

Rejected alternatives:

- **Mutable patterns edited in place:** this would need locking between the GUI thread and pattern threads.
- **ImPlot drag points for the envelope:** they can't draw SuperCollider's curve shapes or bend segments, and they don't look like Live.

## Data model

### Envelopes

```lisp
(gui:make-envelope levels times &key (curves :lin) release-node loop-node)
```

- `levels` holds n numbers; `times` holds n−1 non-negative segment durations.
- `curves` is one curve for every segment, or a list of n−1.
    - A curve is a number (curvature) or one of `:step :lin :exp :sine :welch :sqr :cubed :hold`.
    - The aliases `:linear :exponential :sin :wel :cub` are accepted and normalized.
- `release-node` and `loop-node` are level indexes or `nil`. When both are given, the loop node must come before the release node.
- `:exp` segments can't reach 0. A level of 0 adjacent to an `:exp` segment is stored as 0.00001 and shown as 0, matching cl-collider's `env-cutoff`.

Readers:

- `envelope-levels`, `envelope-times`, `envelope-curves` (always a list), `envelope-release-node`, `envelope-loop-node`, and `envelope-duration`.
- **`(gui:envelope-env e)`** returns the cl-collider envelope: the result of `(sc:env levels times curves release-node loop-node)`. This is the usual way to use an envelope:

    ```lisp
    (env-gen.kr (gui:envelope-env *amp-env*) :gate gate :act :free)
    ```

    - **No load-time dependency on cl-collider:** sc-imgui still doesn't depend on cl-collider. `envelope-env` looks up `sc:env` when it is called. If cl-collider isn't loaded, it signals an error saying so.
    - **Fixed at definition:** inside a synthdef, the envelope is the one the editor held when the synthdef was defined. To pick up edits, redefine the synthdef, or pass levels and times as controls.
- `(gui:envelope-env-args e)` returns the same arguments as a list, `(levels times curves release-node loop-node)`, for code that wants to change them first. "No node" is −99, as cl-collider expects.

The convenience constructors mirror cl-collider's arguments and defaults. They take numbers only, not UGens:

| Constructor | Arguments (defaults) | Release node |
| --- | --- | --- |
| `envelope-triangle` | `dur 1.0, level 1.0` | none |
| `envelope-sine` | `dur 1.0, level 1.0` | none |
| `envelope-perc` | `attack 0.01, release 1.0, level 1.0, curve -4.0` | none |
| `envelope-linen` | `attack 0.01, sus-time 1.0, release 1.0, level 1.0, curve :lin` | none |
| `envelope-cutoff` | `release 0.1, level 1.0, curve :lin` | 0 |
| `envelope-dadsr` | `delay 0.1, attack 0.01, decay 0.3, sustain 0.5, release 1.0, peak 1.0, curve -4.0, bias 0.0` | 3 |
| `envelope-adsr` | `attack 0.01, decay 0.3, sustain 0.5, release 1.0, peak 1.0, curve -4.0, bias 0.0` | 2 |
| `envelope-asr` | `attack 0.01, sustain 1.0, release 1.0, curve -4.0` | 1 |

Copy functions return a new envelope: `envelope-with-level`, `envelope-with-time`, `envelope-with-curve`, `envelope-with-release-node`, `envelope-with-loop-node`.

### Pattern timing (both sequencers)

Every pattern has:

| Setting | Meaning | Default |
| --- | --- | --- |
| `bars` | Number of bars | 1 |
| `bar-length` | Beats per bar | 4 |
| `step-resolution` | Steps per beat | 4 |
| `length` | Steps played, 1 to capacity | capacity |

Capacity is `bars × bar-length × step-resolution`. For example, 2 bars of 5 beats at 4 steps per beat gives a capacity of 40, with 20 steps per bar.

Readers:

- `pattern-bars`, `pattern-bar-length`, `pattern-step-resolution`, `pattern-steps-per-bar`, `pattern-max-steps` (capacity), and `pattern-length`.
- `(gui:pattern-step-position p step)` returns `(values bar beat step-in-beat)`, all counted from 1, for display and for code.

Copy functions:

- `pattern-with-length` changes only the length. Steps past it are kept, just not played.
- `pattern-with-bars`, `pattern-with-bar-length`, and `pattern-with-step-resolution` remap every step by musical position. Each old step moves to the nearest new step, and a tie goes to the earlier one. If two steps land on the same new step, the earlier one wins.
- The length is rescaled the same way and clamped to the new capacity.
- Gates (melodic, and drum patterns with gates) are rescaled to keep their musical duration. For example, a gate of 1 step at 4 steps per beat becomes 2 steps at 8 steps per beat.
- Shrinking the capacity is the only way to discard steps.

### Drum patterns

```lisp
(gui:make-drum-pattern &key (rows 8) (bars 1) (bar-length 4) (step-resolution 4) length gates)
```

- Each cell holds a velocity from 0 to 1, where 0 means off.
- `rows` is either a count (rows are named `0 … n−1`) or a list of names. Names are symbols, numbers, or strings, and must be unique under `equal`.
- Row 0 is the top row.
- **Gates (optional):**
    - `:gates t` gives every cell a gate as well as a velocity. It is set when the pattern is created and can't be changed afterwards. The default is `nil`, so cells have no gate.
    - Gates work as in melodic patterns: a length as a fraction of a step, where a gate above 1 ties into the following steps of the same row.

Functions:

- `(gui:drum-step p row step)` returns the velocity. `row` is always an index.
- `(gui:drum-gate p row step)` returns the gate, or `nil` for a pattern without gates. `(gui:drum-pattern-gates-p p)` says whether a pattern has gates.
- `(gui:drum-row-index p name)` returns the index of a row name, or signals an error.
- `drum-pattern-rows` returns the row count, and `drum-row-names` the list of names.
- `(gui:drum-pattern-with-step p row step velocity &key gate)` returns a copy with one cell changed. `gate` defaults to 0.5. It is an error to give `gate` for a pattern without gates.

### Melodic patterns

```lisp
(gui:make-melodic-pattern &key (bars 1) (bar-length 4) (step-resolution 4) length)
```

Each step is either `nil` (empty) or a step made with `(gui:make-step note &key (velocity 0.8) (gate 0.5) (on t))`:

| Field | Meaning |
| --- | --- |
| `note` | MIDI note number, an integer |
| `velocity` | 0 to 1 |
| `gate` | Length as a fraction of a step, above 0. Above 1, the note ties into the following steps. |
| `on` | `nil` mutes the step but keeps it |

Readers: `step-note`, `step-velocity`, `step-gate`, and `step-on-p`. `(gui:melodic-step p i)` returns the step or `nil`. `(gui:melodic-pattern-with-step p i step)` returns a copy.

### Reading a whole step (both sequencers)

```lisp
(gui:pattern-events p step &key include-muted)
```

`pattern-events` returns everything set at one step as a list of property lists, one per sounding note or hit, so the code that plays a pattern doesn't need to know which kind it has:

| Pattern | Each event | Example at one step |
| --- | --- | --- |
| Drum | `:row` (index), `:name` (row name), `:velocity`, plus `:gate` if the pattern has gates | `((:row 0 :name :kick :velocity 1.0) (:row 2 :name :hat :velocity 0.6))` |
| Melodic | `:note`, `:velocity`, `:gate` | `((:note 60 :velocity 0.8 :gate 0.5))` |

- **Order:** drum events come in row order, top row first. A melodic step gives at most one event.
- **Empty steps:** a step with nothing set returns `nil`.
- **Muted steps:** muted melodic steps are left out. `:include-muted t` includes them, with `:on nil` added to the event. Drum cells have no mute, so a drum cell is either set (velocity above 0) or not.
- **Step numbers:** `step` is taken modulo the pattern's length, as the playhead is, so a pattern thread can pass its raw step counter. Steps past the length are never returned this way; read them with `drum-step` or `melodic-step`.
- **Fresh lists:** the result is freshly made each call, so the caller can keep or change it. The pattern isn't affected.

Example, playing a drum pattern from a cl-collider routine:

```lisp
(dolist (e (gui:pattern-events *kit* *drum-step*))
  (synth (getf e :name) :amp (getf e :velocity)))
```

### Scales

A scale is one of `:major :minor :dorian :mixolydian :pentatonic :minor-pentatonic :blues :chromatic`, or a list of semitone offsets from the root (for example `'(0 3 7 10)`). The root is a MIDI note; only its pitch class matters. `(gui:scale-note-p note scale root)` is exported for code.

## Envelope editor

```lisp
(gui:envelope-editor label place &key width (height 6) (min 0) (max 1) unit duration)
```

- **Width and height:** `width` defaults to the available width; `height` is in rem.
- **Range:** `min` and `max` set the level range. `unit` formats levels as in part 3a (`:db`, `:percent`, and so on).
- **Time axis:** `duration` fixes the visible time span. Without it, the view fits the envelope, and the fit is frozen during a drag so points don't move away from the mouse.

**Display:**

- Each segment is drawn with SuperCollider's actual shape for its curve.
- Breakpoints are drawn as handles. The release node is marked R and the loop node L.
- An info line under the graph shows the hovered or dragged point's time and level, or the hovered segment's curve.

**Interaction:**

- **Drag a point** to change its level and its time. Changing a point's time shifts every later point with it. The first point is always at time 0, so it drags vertically only.
- **Double-click empty space** to add a point there. **Double-click a point** to delete it, down to a minimum of 2 points.
- **Cmd-click a point** (Ctrl-click on Linux and Windows) to open time and level fields. They use part 3a's typed-entry behaviour, including the error outline.
- **Bend a segment:**
    - Drag it vertically, or use the mouse wheel over it, to change its curvature from −10 to 10. A named curve becomes numeric once bent.
    - `:step` and `:hold` segments can't be bent.
    - Double-click a segment to reset it to `:lin`.
- **Right-click a point:** set it as the release node, set it as the loop node, or clear either.
    - Choices that would put the loop node at or after the release node are disabled.
    - Clearing the release node also clears the loop node; the menu item reads "Clear release node (and loop)".
- **Right-click a segment:** choose a named curve.
- **Undo and redo** work as described in [Undo](#undo). Envelopes have no selection or clipboard.

## Sequencer grid (shared by both sequencers)

### Header

The header shows the editor's label, a pencil toggle for Draw mode, and the timing as `2 bars · 5 beats · 4 steps`.

### Ruler and grid lines

- The ruler shows bar numbers from 1. Beats are labelled `bar.beat` (`1`, `1.2`, `1.3`, `1.4`, `2`, …), with labels dropped when they wouldn't fit.
- Alternate beats are shaded slightly, as in Live.
- Lines use three new theme roles:

| Role | `:mid-light` | `:dark` |
| --- | --- | --- |
| `:grid-bar` | `#4a4a4a` | `#6a6a6a` |
| `:grid-beat` | `#7f7f7f` | `#3d3d3d` |
| `:grid-step` | `#9a9a9a` | `#2a2a2a` |

Themes inherit these roles through `:base`; a theme without `:base` must supply them. The values may be tuned at the manual check.

### Length and playhead

- **End marker:** an end marker in the ruler shows the length. Dragging it snaps to steps, or to beats with Shift. Steps past the length are dimmed but stay editable.
- **Playhead:** `:playhead` is a step number or `nil`. It is drawn as a column highlight at `playhead mod length`, so a pattern thread can pass its raw step counter.

### Rows shown and scrolling

- **The total is set where the rows are defined:**
    - Drum: by the pattern's `:rows`, because rows are part of what the data means. A pattern thread asks for row 3 or `:snare`.
    - Melodic: by `:low` to `:high` on the editor, because the pattern stores note numbers and any range can show them.
- **`:visible-rows` on both editors sets how many rows are shown.** The grid is `visible-rows × cell` tall.
    - If there are more rows than that, the grid scrolls with the mouse wheel and has a scrollbar.
    - If there are fewer, the grid shrinks to fit.
    - Neither editor takes a height in rem.
- **With `:fold`,** `:visible-rows` counts rows on screen, so 12 visible rows show 12 scale notes.
- **The wheel scrolls rows** unless the mouse is over a selected melodic note, where it transposes instead (see [Melodic sequencer](#melodic-sequencer)).
- **Melodic scroll position:** it starts centred on the notes in the pattern, or on `:root` if the pattern is empty. It is kept per editor.

### Bars shown and horizontal scrolling

- **`:max-display-width`** on both sequencers is the most bars the grid takes up on screen. The default, `nil`, shows every bar.
- **When the pattern has more bars than that,** the cell area is `max-display-width` bars wide and a horizontal scrollbar appears under it.
    - The ruler, the cells, and the melodic velocity lane scroll together. The row labels stay put.
    - When the pattern has that many bars or fewer, the grid is just as wide as the pattern.
- **Scrolling:**
    - Drag the scrollbar, or use a horizontal wheel or trackpad swipe. Shift+wheel also scrolls horizontally, except over a selected melodic note, where it transposes by an octave (from whichever wheel axis the event arrives on).
    - The position is in steps, kept per editor, and clamped when the pattern changes.
- **Nothing follows automatically.** The view doesn't follow the playhead, and dragging a selection past the visible edge doesn't scroll it. The end marker, notes, and the playhead aren't drawn when they're scrolled out of view.
- **The insert marker, pastes, and moves** work in pattern steps, so they're unaffected by scrolling.

### Row labels

Labels are drawn in a column to the left of the grid:

- Strings are shown as written.
- Numbers are printed.
- Symbols are shown as their lowercase name, so `:kick` shows as `kick`.

## Drum sequencer

```lisp
(gui:drum-grid label place &key (cell 1.25) visible-rows max-display-width playhead
                              (default-velocity 1.0) (default-gate 0.5))
```

- **Cells:** `cell` is the cell size in rem. Velocity is shown as the fill's opacity.
- **Gates:** in a pattern with gates, a set cell is drawn as a block as wide as its gate, as melodic notes are. A gate above 1 runs across the following cells of its row. `default-gate` is used for new cells; it is ignored for patterns without gates.
- **Rows:** the pattern's `:rows` sets the total. `:visible-rows` defaults to all of them; see [Rows shown and scrolling](#rows-shown-and-scrolling).
- **Row menu:** right-clicking a row label offers "Clear row" and "Fill every N steps" (2, 3, 4, 8, or every beat).
- **Draw mode:**
    - Click an empty cell to set it to `default-velocity`; click a set cell to clear it. Dragging paints, carrying on whichever action the first click did.
    - Alt-drag a cell vertically to change its velocity.
    - In a pattern with gates, drag a cell's right edge to change its gate, snapping to steps unless Shift is held.

## Melodic sequencer

```lisp
(gui:melodic-sequencer label place
  &key (cell 1.25) (visible-rows 12) max-display-width playhead
       (low 48) (high 84) scale (root 60) fold
       row-names
       (default-velocity 0.8) (default-gate 0.5))
```

**Note lane:**

- The note lane is a row per pitch from `low` to `high`; that range is the total. `:visible-rows` (default 12, one octave) sets how many are shown; see [Rows shown and scrolling](#rows-shown-and-scrolling).
- **Keyboard and shading:** a keyboard strip with black-key shading runs beside the rows.
- **Scale:** with `:scale`, rows in the scale are highlighted. With `:fold t`, only rows in the scale are shown.
- **Notes:**
    - A step's note is a block as wide as its gate, so a gate above 1 runs across the following steps.
    - **Overlapping gates** (both sequencers): a gate that runs into the next set step is drawn cut off at that step. The stored gate isn't changed; what a long gate means for playback is up to the code that plays the pattern.
    - Muted steps are drawn as outlines.
    - Notes outside `low` to `high` show as arrows at the top or bottom edge.

**Row names:**

- `:row-names` is a list or vector. The first entry names `low`, the next `low + 1`, and so on, counting semitones whether or not `:fold` hides rows.
- A `nil` entry, or a row beyond the end of the list, shows the MIDI note name (C4 = 60).
- `:row-names` is an argument to the editor, not part of the pattern, so one pattern can be shown with different labels.
- Because names count from `low`, changing `low` moves them.
- When `:row-names` is given:
    - The keyboard strip and black-key shading are off, and rows use plain alternating shading.
    - `:scale` and `:fold` still work.
- Hovering shows a named row as `name · (60)`, and an unnamed row as `C4 (60)`.

**Velocity lane:** a lane 2 rem tall under the note lane shows each step's velocity as a bar. Dragging in it sets velocity in either mode.

**Draw mode:**

- Click an empty step at a pitch to add a note with the default velocity and gate. Click a note to remove it.
- Drag a note's right edge to change its gate, snapping to steps unless Shift is held.
- Alt-drag a note vertically to change its velocity.

**Both modes:**

- The mouse wheel over a selected note transposes the selection by a semitone, or an octave with Shift. With a scale and `:fold`, it moves by scale degree instead. Anywhere else in the note lane, the wheel scrolls rows.
- Cmd-click a note to type a note name (`C#3`, `eb4`) or a number.

## Selection, clipboard, and moving

Applies to both sequencers. "Cmd" means Cmd on macOS and Ctrl elsewhere.

**Modes:**

- Each editor has its own mode. Select mode is the default.
- The B key, or the pencil toggle in the header, switches between Select and Draw modes.
- Keys go to the editor that was last clicked.

**Selecting:**

- In Select mode, click to select a cell or note and to set the insert marker. Shift-click adds to or removes from the selection.
- Drag on empty space to draw a marquee.
- Cmd-A selects everything; Escape clears the selection.
- A drum selection is any set of cells. A melodic selection is a set of steps.

**Clipboard:**

- Cmd-C copies, Cmd-X cuts, and Cmd-V pastes at the insert marker. Delete or Backspace clears the selection.
- Cmd-D duplicates the selection directly after itself.
- Pasting merges with what's already there:
    - In the drum grid, cells keep their rows and only move in time, and empty cells in the clipboard don't clear anything.
    - Drum cells carry their gates. Cells pasted from a pattern without gates into one with gates get `default-gate`. Cells pasted into a pattern without gates lose their gates.
    - In the melodic sequencer, pasted steps replace the steps they land on.
- There is one clipboard for drum patterns and one for melodic patterns. Both are internal to Lisp.
- **Running past the end:** when a paste or duplicate runs past the last step of the capacity, the steps that fit are pasted and the rest are skipped. Undo restores the pattern if that wasn't wanted.
    - The selection afterwards is what was actually pasted.
    - Length doesn't matter here: steps past the length but inside the capacity are pasted like any others.

**Moving:**

- Drag the selection to move it in time, snapping to steps, or to beats with Shift.
- In the melodic sequencer, dragging vertically also changes pitch.
- Option/Alt-drag moves a copy and leaves the original.
- Arrow keys nudge the selection by a step. In the melodic sequencer, Up and Down change pitch by a semitone, or an octave with Shift.
- **Stopping at the edges:** a move never loses steps. The whole selection stops when one of its steps reaches an edge, and the selection keeps its shape.
    - **In time,** the edges are step 0 and the last step of the capacity, not the length.
    - **In pitch** (melodic sequencer), the edges are MIDI notes 0 and 127, not the visible range.
    - This applies to dragging, Alt-drag copying, arrow-key nudges, and wheel transposes.
    - A nudge that can't move the whole selection does nothing. An octave nudge doesn't fall back to a smaller step.
- Double-click toggles a cell or note in either mode.

## Undo

- Cmd-Z undoes and Cmd-Shift-Z redoes, per editor, for up to 100 steps. This covers all three editors.
- One gesture is one undo step: a whole drag, paste, or nudge.
- **Changes from code:** each frame, the editor compares the place with the value it last wrote. If they differ, the change is recorded as an undo step and the redo list is cleared.
- **Lifetime:** history is keyed by the editor's ID and kept for the session, so hiding and showing a panel doesn't lose it. `(gui:clear-editor-history)` drops all of it.

## Calling convention

Each editor is a macro taking a place, as in part 3a. It writes the new value and returns true on change. The matching `-value` functions (`envelope-editor-value`, `drum-grid-value`, `melodic-sequencer-value`) take the value and return `(values new-value changed-p)`. Inside a panel, a pattern thread reads the same variable:

```lisp
(gui:with-window ("Drums")
  (gui:drum-grid "Kit" *kit* :playhead *drum-step*))
```

## Errors

- **Invalid values** signal an error naming the problem. The checks are:
    - Envelopes: mismatched list lengths, a negative time, an unknown curve, nodes out of range, or the loop node not before the release node.
    - Drum patterns: duplicate row names, a velocity outside 0 to 1, a gate that isn't above 0, or a gate given for a pattern without gates.
    - Timing: a non-positive `bars`, `bar-length`, or `step-resolution`, or a length outside 1 to capacity.
    - Melodic steps: a non-integer note, a velocity outside 0 to 1, or a gate that isn't above 0.
    - Scales: an unknown scale name.
- **Wrong type** (a place holding the wrong kind of value) signals `gui:widget-value-error` naming the label, before any foreign call.
- **Invalid editor arguments** signal an error naming the label: `low` not below `high`, `min` not below `max`, or a `:visible-rows` or `:max-display-width` that isn't a positive integer.
- **Drawing never changes a value.** Values outside the visible range are shown at the edges.

Inside a panel, these fail the panel through the existing runtime error handling.

## Testing

**`editors` suite, pure Lisp:**

- Envelope construction and validation:
    - Alias normalization.
    - The 0.00001 substitution for `:exp`.
    - Every convenience constructor matches cl-collider's output for its defaults, checked against values copied from `EnvGen.lisp`, without loading cl-collider.
    - `envelope-env-args` gives −99 for missing nodes.
    - `envelope-env` calls `sc:env` with those arguments. The test uses a stub `sc` package, so cl-collider isn't needed. Without the stub, it signals the "cl-collider isn't loaded" error.
- Curve shapes: sample points for every curve type match SuperCollider's formulas.
- Timing:
    - Capacity and `pattern-step-position`.
    - Remapping by musical position, including ties, collisions, and the length rescale.
    - Shrinking discards only the steps past the new capacity.
    - Gates keep their musical duration when the step resolution changes.
- `pattern-events`: drum and melodic events, row order, gates present only on gated drum patterns, muted steps left out unless asked for, the step taken modulo the length, and `nil` for an empty step.
- Row names: `drum-row-index`; the label rules for strings, numbers, and symbols; and melodic names counted from `low`, unaffected by `:fold`.
- Clipboard merge rules for each kind; pastes and duplicates that run past capacity paste only what fits.
- Moves stop at the edges in time (0 and capacity) and pitch (0 and 127), keeping the selection whole.
- Undo: gesture grouping, the 100-step limit, and code changes recorded with redo cleared.

**Same suite, headless interaction** through the harness:

- Horizontal scrolling: `:max-display-width` limits the width to that many bars and shows a scrollbar only when the pattern is longer; horizontal wheel and Shift+wheel scroll; hit testing follows the scroll.
- Scrolling: `:visible-rows` sizes the grid; the wheel scrolls rows, and transposes only over a selected note; `:fold` counts rows on screen.
- Envelope editor:
    - Drag a point; add and delete points.
    - Bend a segment with a drag and with the wheel.
    - The node menus disable invalid choices.
    - Cmd-click typed entry.
- Drum grid: toggle cells, paint, and change velocity with Alt-drag. With gates: drag a gate edge, and paste between patterns with and without gates.
- Melodic sequencer:
    - Add and remove notes.
    - Drag a gate edge.
    - Transpose with the wheel and the arrow keys.
- Both sequencers:
    - Marquee selection, then copy, paste, cut, duplicate, and delete.
    - Moving a selection, and Alt-drag copying it.
    - Dragging the end marker.
    - Undo and redo.
- No ImGui assertions in any case.

**`theme` suite:** both shipped themes define the three grid roles.

**Examples:** a new `examples/editors.lisp`, loaded headlessly by the `examples` suite. It contains:

- An amp envelope.
- A named drum kit with a playhead driven by a timer.
- A bass line in a scale.

**Manual check on macOS:**

- Grid colours in both themes.
- How dragging and bending feel.
- Keyboard shortcuts.
- Scaling with `set-font-size`.

## Documentation

- `src/gui/README.md`: an "Editors" section covering the data model, each editor, keyboard shortcuts, and recipes for driving a cl-collider pattern from a sequencer and an envelope editor. The grid roles also go in the themes section.
- `tests/README.md`: the `editors` suite and the coverage map.

## Out of scope

| Item | Where it goes |
| --- | --- |
| Polyphonic (chord) steps | Later, if wanted |
| Per-step probability, micro-timing, and swing | Later, if wanted |
| A shared clipboard with the system | Later, if wanted |
| Binding editors to synth parameters by name | Part 2 (parameter store) |
| Meters and scopes | Part 4 |
| Declarative panels | Part 5 |
| MIDI input and output | Outside this toolkit |
