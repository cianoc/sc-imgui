# src/gui/: the `gui` package

Contents:

1. [Overview](#overview)
2. [Quick reference](#quick-reference)
3. [Core ideas](#core-ideas)
4. [Package reference](#package-reference)
5. [Themes](#themes)
6. [File by file](#file-by-file)
7. [Building a custom widget](#building-a-custom-widget)
8. [Recipes](#recipes)
9. [Extending the API](#extending-the-api)
10. [Not yet wrapped](#not-yet-wrapped)
11. [Gotchas](#gotchas)
12. [Tests and examples](#tests-and-examples)

## Overview

`gui` is the API you write against. It's built on `gui.runtime` (the frame loop and panel registry, in `src/runtime/`) and the raw bindings `%imgui` and `%implot` (in `src/bindings/`). It re-exports the runtime's user-facing functions, so `gui:` is the only package you need. See `src/README.md` for how the directories fit together.

A complete session:

```lisp
(ql:quickload :sc-imgui)
(gui:start)

(defvar *cutoff* 1000.0)
(defvar *mute* nil)

(gui:define-gui saw-panel ()
  (gui:with-window ("Saw")
    (gui:slider "Cutoff" *cutoff* :min 20 :max 20000 :scale :log)
    (gui:checkbox "Mute" *mute*)
    (when (gui:button "Reset")
      (setf *cutoff* 1000.0))))
```

Re-evaluating the `define-gui` form changes the window on the next frame. `(gui:stop)` hides the window, `(gui:start)` shows it again, and `(gui:shutdown)` ends the GUI and releases SBCL's main thread.

## Quick reference

| Area | Export | Kind | One line |
| --- | --- | --- | --- |
| [Panels](#panels-and-lifecycle) | `define-gui` | macro | Define and register a panel |
| | `show`, `hide`, `remove` | functions | Show, hide, or unregister a panel |
| | `call-in-gui-thread` | function | Run a function on the GUI thread between frames |
| | `start`, `stop`, `shutdown`, `running-p` | functions | Show, hide, or end the GUI; is it showing? |
| | `*ini-path*`, `*debug-on-error*` | variables | Layout file; debugger instead of failed window |
| | `*fonts*`, `*font-size*` | variables | Fonts to load and the base size, read when the window is created |
| | `main-thread-busy` | condition | `start` called on the main thread |
| | `unknown-font` | condition | `with-font` got a name that isn't loaded |
| [Themes](#themes) | `define-theme`, `set-theme`, `set-font-size` | functions | Define a theme; switch it live; change the base font size live |
| | `theme-color` | function | The current theme's colour for a palette role, for custom widgets |
| | `*theme*` | variable | Name of the theme applied when the window is created |
| [Scopes](#scopes) | `with-window`, `with-group`, `with-child`, `with-section`, `with-id`, `with-disabled`, `with-style`, `with-font` | macros | Balanced ImGui begin/end and push/pop |
| [Layout](#layout) | `with-row`, `with-grid` | macros | Items on one line; items in a table |
| | `same-line`, `new-line`, `separator`, `spacing`, `indent`, `unindent`, `set-next-item-width` | functions | Fine layout control |
| [Widgets](#widgets) | `slider`, `drag`, `checkbox`, `combo`, `input-text`, `selectable`, `list-box` | macros | Edit a place; true when changed |
| | `slider-value`, `drag-value`, ... `list-box-value` | functions | Same, returning `(values new changed-p)` |
| | `button`, `text` | functions | Clickable button; formatted text |
| [Controls](#controls) | `knob`, `fader`, `number-box` | macros | Audio controls with units, scales and typed entry; true when changed |
| | `knob-value`, `fader-value`, `number-box-value` | functions | Same, returning `(values new changed-p)` |
| | `toggle`, `toggle-value` | macro, function | A lit on/off button on a boolean place |
| | `trigger` | function | Momentary button; returns pressed, held, released |
| | `xy-pad`, `xy-pad-value` | macro, function | Two values on one square pad |
| | `control-spec-error` | condition | A control got an invalid specification |
| | `widget-value-error` | condition | A widget got a value of the wrong type |
| [Plots](#plots) | `with-plot` | macro | An ImPlot plot area; items take the theme's series colours |
| | `plot-lines`, `plot-bars`, `plot-scatter` | functions | Plot Lisp sequences |
| [Drawing](#drawing) | `color` | function | Pack RGBA into ImGui's color format |
| | `window-draw-list`, `draw-line`, `draw-rect`, `draw-circle`, `draw-arc`, `draw-polyline`, `draw-text` | functions | Draw shapes and text |
| [Interaction](#interaction) | `invisible-button`, `item-hovered-p`, `item-active-p` | functions | Reserve space; query the mouse over it |
| | `cursor-screen-pos`, `set-cursor-screen-pos`, `mouse-pos`, `mouse-drag-delta`, `reset-mouse-drag-delta`, `content-region-avail` | functions | Positions and drag distances |
| [Flags](#flags) | `enum-flags` | function | Keywords to an ImGui flags integer |

## Core ideas

### Immediate mode

A panel is a function the runtime calls **every frame**, about 60 times a second. Nothing on screen persists by itself: a widget exists in a frame only because your code called it in that frame. State lives in your own variables. Conditionals and loops work naturally:

```lisp
(gui:define-gui voices ()
  (gui:with-window ("Voices")
    (dolist (v *voices*)
      (gui:with-id (v)
        (gui:slider "Amp" (voice-amp v))))
    (when (null *voices*)
      (gui:text "No voices running"))))
```

### Place-based widgets

The widget macros take a `setf`-able place: a variable, `(gethash k table)`, `(aref v i)`, `(slot-value obj 'x)`, an accessor. Each one reads the place, draws the widget, writes the new value back **only when the user changed it**, and returns true when it did. That return value is the hook for side effects:

```lisp
(when (gui:slider "Cutoff" *cutoff* :min 20 :max 20000 :scale :log)
  (ctrl *saw* :cutoff *cutoff*))
```

Each macro has a function variant ending in `-value` that takes the current value instead of a place and returns `(values new-value changed-p)`, writing nothing. Use it when the value doesn't live in a place, or when you want to decide what happens to the new value.

### Scopes always close

ImGui works in begin/end and push/pop pairs. Every `with-` macro closes what it opened in `unwind-protect`, so an error in your code still leaves ImGui balanced. The runtime then marks only that panel as failed. Raw `%imgui` calls get none of this protection.

### Labels and IDs

ImGui identifies a widget by its label, within the current window and ID scope. Two widgets with the same label in the same scope behave as one. Ways to keep them apart:

- `with-id` pushes an ID scope. Give it any Lisp object: a synth, a struct, an index, a string.
- ImGui's label conventions: everything after `##` is part of the ID but not displayed (`"Gain##left"` and `"Gain##right"` both show "Gain"), and `###` makes only the text after it the ID, so the visible part can change (`"Level 0.5###level"`).

`with-id` never uses an object's memory address, which changes when the garbage collector moves it. Objects get a stable number from a weak table instead.

### Flags as keywords

Where an ImGui function takes flags, the macros accept keywords: `(gui:with-window ("Meter" :flags '(:no-resize :no-collapse)) ...)`. Keywords are looked up as constants (`:no-resize` → `%imgui:+window-flags-no-resize+`), and several are combined with `logior`. A literal keyword or quoted list is resolved **when the macro expands**, so a misspelled flag is an error at compile time. A computed value is resolved at run time. An integer is used as is.

## Package reference

Arguments in `&key` lists show their defaults. "Place" means a `setf`-able form.

### Panels and lifecycle

**`(define-gui name () &body body)`** — macro. Defines `name` as a global function of no arguments, registers it as a panel, and returns `name`. Re-evaluating it replaces the panel in place, clears any failure mark, and refits the panel's windows to their contents once. A non-empty lambda list is an error.

**`(show name)`**, **`(hide name)`** — Make a panel visible or hidden. A hidden panel stays registered and defined. Both return `name`, even if no such panel exists.

**`(remove name)`** — Unregisters a panel. Returns true if it existed. The function stays defined. (Shadows `cl:remove`; see [Gotchas](#gotchas).)

**`(call-in-gui-thread thunk)`** — Queues `thunk` to run on the GUI thread **between frames**, and wakes the loop. For work that must happen on the main thread but outside drawing, such as changing ImGui's global style through `%imgui`. Not for drawing widgets; see [Gotchas](#gotchas). An error in a task is reported and the loop continues.

**`(start &key (width 1280) (height 800) (title "sc-imgui"))`** — Shows the GUI window, creating it and starting the loop on SBCL's main thread the first time (or after `shutdown`). Returns `t`, or `nil` if already showing. `width` and `height` apply only when the window is created. Signals `main-thread-busy` if called on the main thread itself.

**`(stop &key (wait t))`** — Saves the layout, hides the window, and stops drawing panels. The loop keeps running. Returns `t`, or `nil` if not showing.

**`(shutdown &key (wait t))`** — Destroys the window, ends the loop, and gives the main thread back. Returns `t`, or `nil` if there was no loop. Panels stay registered.

**`(running-p)`** — True while the window is showing and panels are drawn.

**`*ini-path*`** — Where ImGui saves window positions and sizes. Default `#p"sc-imgui.ini"`, merged with `*default-pathname-defaults*` at `start`. `nil` disables saving. Takes effect when the window is next created.

**`*debug-on-error*`** — Default `nil`. When true, a panel error enters the debugger, with restarts `retry-panel` and `disable-panel`, instead of being shown in a failed window. Useful for hard bugs, but the window freezes while the debugger is open.

**`*fonts*`** — Plist of font name (any keyword) to font file, as a native namestring or a pathname. Default `(:regular <assets/fonts/Inter-Regular.ttf> :semibold <assets/fonts/Inter-SemiBold.ttf>)`: the bundled Inter (see the top-level `README.md`). `:regular` is the default font for all text. Without it (or with a `nil` path), ImGui's built-in scalable font is the default. Takes effect when the window is next created, so after changing it call `(gui:shutdown)` and `(gui:start)`. `stop` and `start` don't reload fonts. A font file that fails to load is reported at the REPL, and that name uses the regular font.

**`*font-size*`** — The base font size in pixels, default 15. Same timing as `*fonts*`.

**`unknown-font`** — Error signalled by `with-font` for a name that isn't loaded. The message names it and lists the loaded names. Inside a panel it fails the panel like any other error. Readers: `unknown-font-name`, `unknown-font-loaded` (from `gui.runtime`).

**`main-thread-busy`** — Condition signalled by `start` on the main thread. Its report explains the SLIME setting needed (`swank::*main-thread-used*`).

### Themes

See [Themes](#themes) for the palette roles, sizes and recipes.

**`(define-theme name &key base palette style colors)`** — Defines or redefines the theme `name` and returns `name`. It is a function, so its arguments are evaluated: quote the data. `base` names a theme whose palette, style and colors are copied first; `palette`, `style` and `colors` then override them key by key. A theme without `base` must give every palette role. Everything is checked here, and an error names the bad colour, role, colour name or size. Redefining the current theme applies it to a window that exists.

**`(set-theme name)`** — Sets `*theme*` to `name` and, if a window exists (showing or hidden), applies it between frames. An unknown name is an error that lists the known themes. Returns `name`. With no window it only sets `*theme*`, which is used when the window is created.

**`(set-font-size px)`** — Sets `*font-size*` to `px` and, if a window exists, sets ImGui's base font size to `px` between frames and reapplies the theme, so rem sizes follow. Returns `px`. With no window it only sets `*font-size*`, which is used when the window is created.

**`(theme-color role)`** — The current theme's colour for the palette `role`, packed as `color` does, for `draw-line`, `draw-circle` and the like. For `:series` it is the first series colour. Plain Lisp, safe from any thread. An unknown role is an error.

**`*theme*`** — Name of the theme applied when the window is created. Default `:mid-light`. Change it with `set-theme`, which also applies it to a window that exists.

### Scopes

**`(with-window (title &key flags) &body body)`** — An ImGui window. `body` runs only when the window is visible (not collapsed or clipped). `End` always runs. Flags use the `WINDOW-FLAGS` prefix, such as `:no-title-bar`, `:no-resize`, `:no-move`, `:always-auto-resize`. On the first frame after its panel is redefined, the window refits to its contents.

**`(with-group () &body body)`** — Treats the body's widgets as one item, so the group can sit in a row beside other items, for example a column of widgets inside a `with-row`.

**`(with-child (id &key (width 0) (height 0) border) &body body)`** — A scrolling sub-area. A size of 0 fills the available space on that axis. `border` draws a frame. `body` runs only when the child is visible.

**`(with-section (label &key default-open) &body body)`** — A collapsing header. `body` runs only while it's expanded. `default-open` starts it expanded the first time.

**`(with-id (object) &body body)`** — Pushes an ID scope for `object`. Integers that fit in 32 bits and strings are used directly; any other object gets a stable number.

**`(with-disabled (&optional (disabled t)) &body body)`** — Greys out the body's widgets and ignores input to them while `disabled` is true. `disabled` is evaluated each frame.

**`(with-font (name &key size) &body body)`** — Text in the body uses the font loaded under `name`, a key of `*fonts*`, at `size` pixels if given, otherwise at the current size. `name` and `size` are evaluated. Nests, and pops afterwards, even after an error. A name that wasn't loaded signals `unknown-font`. With no fonts loaded at all (headless tests), the font is left unchanged, size included.

**`(with-style (&rest specs) &body body)`** — Temporarily changes style colors and variables for the body. Each spec is one of:

- `(:color name r g b [a])`: a style color, with `name` from the `COL` prefix (`:button`, `:button-hovered`, `:text`, `:frame-bg`, ...) and components from 0 to 1.
- `(:var name value)`: a single-number style variable from the `STYLE-VAR` prefix (`:frame-rounding`, `:alpha`, ...).
- `(:var name x y)`: a two-number style variable (`:frame-padding`, `:item-spacing`, ...).

Everything pushed is popped afterwards, even after an error.

### Layout

ImGui places each widget below the previous one. These change that.

**`(with-row () &body body)`** — Puts each top-level form of the body on the same line, by inserting `same-line` between them. To put a multi-widget column in a row, wrap it in `with-group`.

**`(with-grid (&key (columns 2) id flags) &body body)`** — A table. Each top-level form of the body goes in the next cell, filling rows left to right. `columns` is evaluated. Flags use the `TABLE-FLAGS` prefix, such as `:borders` or `:sizing-stretch-same`. The default `id` is computed from the body's text, so it stays the same across redefinitions; give an explicit `:id` when two grids with identical bodies are in the same window. The body runs only when the table is visible.

**`(same-line &optional (offset 0.0) (spacing -1.0))`** — Puts the next item on the same line as the previous one. `offset` is from the window's left edge; a negative `spacing` uses the style's default.

**`(new-line)`**, **`(separator)`**, **`(spacing)`** — End the current line; draw a horizontal line; add vertical space.

**`(indent &optional (width 0.0))`**, **`(unindent &optional (width 0.0))`** — Indent following items; 0 uses the style's default indent. Pair them yourself.

**`(set-next-item-width width)`** — Width of the next widget in pixels. Negative values are measured from the right edge (`-1` fills the remaining width).

### Widgets

Each place-taking macro has the form `(widget label place &rest args)`, where `args` are the keyword arguments of its `-value` function. It returns true when the value changed.

**`slider`**, **`(slider-value label value &key (min 0) (max 1) (scale :linear) format)`** — A slider. An integer value gives an integer slider (`min` and `max` rounded); any other real gives a float slider and keeps its type (`double-float` stays `double-float`; rationals come back as `single-float`). `:scale :log` gives a logarithmic slider, for frequencies. `format` is a C printf format with one numeric conversion; the default is `"%d"` or `"%.3f"`.

**`drag`**, **`(drag-value label value &key (speed 0.01) (min 0) (max 0) format)`** — A number field changed by dragging horizontally, `speed` units per pixel. `min` equal to `max` means unclamped. Types as for `slider`.

**`checkbox`**, **`(checkbox-value label value)`** — A checkbox. Any non-`nil` value counts as checked; the new value is `t` or `nil`.

**`combo`**, **`(combo-value label index items)`** — A drop-down list. `items` is a list of strings, and the place holds the selected item's index. An out-of-range index shows an empty preview.

**`input-text`**, **`(input-text-value label value &key (max-length 256))`** — A text field. The place holds a string. `max-length` is in UTF-8 bytes; longer text is cut at a character boundary.

**`selectable`**, **`(selectable-value label selected &key (width 0) (height 0))`** — A row that highlights when `selected`. A click toggles the value.

**`list-box`**, **`(list-box-value label index items &key (width 0) (height 0))`** — A scrolling list of string `items`. The place holds the selected index, or `nil` for none. A height of 0 shows about seven rows.

**`(button label &key (width 0) (height 0))`** — A button. Returns true on the frame it's clicked. A size of 0 fits the label.

**`(text control-string &rest args)`** — Displays text. With `args`, formats with Lisp's `format`; without, displays `control-string` literally, so `~` is safe in plain text.

**`widget-value-error`** — A subclass of `type-error`, signalled before any foreign call when a widget gets a value or argument of the wrong type, such as a `nil` slider value. Its report names the widget's label; `widget-value-error-label` reads it. Inside a panel, the runtime treats it like any panel error.

### Controls

Audio controls that look and handle like Ableton Live's: a knob, a fader, a toggle, a trigger, a number box and an XY pad. They take their colours from the theme, size themselves in rem, and follow `set-theme` and `set-font-size` live. They edit any place, like the widgets above, and don't depend on cl-collider. The code is in `src/gui/controls/`. `examples/controls.lisp` is a synth device that uses all six.

The value controls (`knob`, `fader`, `number-box`, and each axis of `xy-pad`) share one implementation of mapping, interaction, display and typed entry, so they behave the same wherever they overlap. Each is a place macro with a `-value` function, like the widgets: the macro writes the new value back and returns true when it changed, and the function returns `(values new-value changed-p)` and writes nothing. `changed-p` is true on every frame the value changes during a drag, so code can follow it continuously.

```lisp
(gui:knob "Cutoff" *cutoff* :min 20 :max 20000 :scale :log :unit :hz)
```

#### Value specification

Every value control takes these keyword arguments:

| Argument | Meaning |
| --- | --- |
| `:min`, `:max` | Range. Defaults 0 and 1. |
| `:scale` | `:linear` (default) or `:log`. `:log` needs `min` above 0. |
| `:step` | Snap to multiples of this. An integer value with no `:step` snaps to 1, so integer places stay integers. |
| `:choices` | A list of strings. The value is an index, and the control steps through the choices. Replaces `:min`, `:max`, `:step` and `:scale`. |
| `:bipolar` | Draw the arc or fill from an origin instead of from `min`. `t` uses 0 if the range includes it, otherwise the midpoint; a number sets the origin. |
| `:default` | Value for double-click reset. Defaults to the origin when bipolar, otherwise `min`. |
| `:unit` | A built-in formatter, which also parses typed text. See below. |
| `:format` | A function of the value that returns a string. Overrides `:unit`. |

#### Units

| Unit | Values | Display | Bare typed number |
| --- | --- | --- | --- |
| `:hz` | Frequency in Hz | `440 Hz`, `2.40 kHz` (kHz from 1000) | Hz |
| `:db` | Level in dB | `-6.0 dB`; `-inf dB` at or below -70 | dB |
| `:ms` | Time in ms | `120 ms`, `1.20 s` (s from 1000) | ms |
| `:percent` | 0 to 1 | `62 %` | Percent: `62` is 62 % |
| `:semitones` | Semitones | `+3 st`, `-12 st`, `0 st` | Semitones |
| `:pan` | -1 to 1 | `50L`, `C`, `25R` (Live's 50L to 50R scale) | On the display scale: `25` is 25R, `-25` is 25L |

With neither `:unit` nor `:format`, numbers show with a precision that suits the range, and a choice control shows the selected choice's name.

#### Interaction

The same for every value control, except where a control says otherwise:

- **Drag vertically,** up to increase. A full sweep of the range takes 10 rem of travel. Shift makes it 10 times finer. The control accumulates the unsnapped position during a drag, so stepped and choice controls don't stick between steps. The cursor is hidden while dragging.
- **Double-click** resets to `:default`.
- **Mouse wheel,** while hovered, moves 1% of the range per notch, or one step for stepped controls and choices. Shift makes it 0.1% (on macOS, where Shift turns the wheel horizontal, the horizontal wheel is read instead). Trackpad fractions add up, and a stepped or choice control steps once per whole notch. The control claims the wheel, so the window doesn't scroll under it. An integer place with no `:step` steps by 1, so the wheel moves it 1 per notch whatever the range: an integer 20 to 20000 Hz knob moves 1 Hz per notch. This is a known limitation; use a float place, or give a `:step`, for a wide range.
- **Cmd-click** on macOS (Ctrl-click on Linux and Windows) opens a text field in place of the value:
    - Enter parses the text with the control's unit. `2k`, `2.4 kHz`, `1.2 s`, `-6`, `-6 dB` and `25R` all work. The result is clamped and snapped, and the field closes.
    - If the text can't be parsed, the field stays open with the text unchanged, outlined in the theme's `:error` colour, and the value is unchanged. The outline clears when you edit the text.
    - Escape or clicking elsewhere cancels and leaves the value unchanged.
    - Enter on text you haven't edited closes the field without writing, so a value that code changed in the meantime is kept.

#### Controls

**`knob`**, **`(knob-value label value &rest spec &key (size 2.5))`** — A 270° arc open at the bottom, with the label above in `:text` and the formatted value below. The track is `:frame`, the value arc is `:accent` (from `min`, or from the origin when bipolar), and a short pointer marks the position. `size` is the arc's diameter in rem. The knob is its diameter plus 0.5 rem wide.

**`fader`**, **`(fader-value label value &rest spec &key vertical length thickness)`** — Horizontal by default, like Live's bar slider: a flat bar in `:frame`, filled in `:accent` up to the value, with the label left-aligned and the value right-aligned inside it. It fills the available width unless `length` (in rem) is given. With `:vertical t` it is a mixer fader, filled from the bottom, with the label above and the value below. `thickness` is the bar's width across its axis and defaults to the frame height in both orientations, so a horizontal fader is as tall as other controls on its row. A vertical fader's item is 3.5 rem wide (or `thickness`, if wider), with the bar centred in it, so the label and value have room; its `length` defaults to 8 rem. A bipolar fill grows out from the origin. Clicking a point on the bar makes that point the value once the double-click time (0.3 s) has passed, so a double-click still resets to the default without a jump first. Pressing and dragging jumps at once to the point under the cursor and then tracks the mouse 1:1 along the fader's own axis (a full sweep is the bar's length), so the fill edge stays under the cursor. Shift doesn't jump: Shift-drag moves 10 times finer from the current value. Everything else is as above.

**`toggle`**, **`(toggle-value label value &key width)`** — A rectangular button showing the label: lit in `:accent` when on, `:control` when off. A click flips the boolean in the place, which holds `t` or `nil`. It has no value specification, wheel or typed entry. `width` is in rem; the default fits the label plus 1 rem.

**`(trigger label &key width)`** — A momentary button with no place. Returns three values: true on the frame it's pressed, true while it's held, and true on the frame it's released. It is lit in `:accent` while held.

**`number-box`**, **`(number-box-value label value &rest spec &key width)`** — Live's compact number field: the formatted value in a `:frame` box, with the label beside it. All the interaction above applies, including typed entry. A plain click (press and release without dragging) also opens the text field, once the double-click time (0.3 s) has passed, so a double-click still resets; dragging works as on the other controls. The box is wide enough for the longest value it can show; `width` sets it in rem.

**`xy-pad`**, **`(xy-pad-value label x-value y-value &key x y (size 8))`** — A square pad that edits two values. The macro is `(xy-pad label x-place y-place &key x y size)`. `x` and `y` are each a value specification as a list, such as `:x '(:min 20 :max 20000 :scale :log :unit :hz)`. The pad is `:frame` with faint grid lines, crosshair lines through the point, and the point in `:accent`; the label is above and both values below. `size` is the side in rem. It handles input differently:

- Pressing anywhere moves the point there, and dragging follows the mouse.
- Shift-drag is relative and fine: 0.1 times the pad's size. If you release Shift mid-drag, the drag goes back to absolute and the point snaps to the mouse.
- Double-click resets both axes.
- There is no wheel or typed entry.

The macro writes whichever places changed and returns true if either did. `xy-pad-value` returns `(values new-x new-y changed-p)`. An axis you didn't change comes back as given, not clamped.

**Choices.** `:choices` works on knobs, faders and number boxes. The place holds the selected index:

```lisp
(gui:knob "Wave" *wave* :choices '("Sine" "Saw" "Square" "Noise"))
```

#### Layout and sizing

- **All sizes are in rem,** multiples of the base font size: knob diameters, fader lengths and thickness, box and button widths, and the XY pad's size. They scale with `set-font-size`. A size given as `(:px n)` is fixed.
- **One control, one ImGui item.** Each control reserves one rectangle that covers everything it draws, label and value text included, so `with-row`, `with-grid` and `with-group` treat it as a unit, and a row of controls shares a top edge.
- **Widths don't change as the value changes.** Text wider than its control is clipped at the edge, so rows stay aligned as values change.
- **Feedback follows the theme.** A hovered control's track changes from `:frame` to `:frame-hover`. While you drag or edit, the value text is drawn in full-strength `:text`. Inside `with-disabled`, input is ignored and every colour fades with ImGui's style alpha, like the stock widgets.
- **IDs** follow the usual rules: the label is the ID, `##` hides a suffix, and `with-id` separates repeated controls.

#### Errors

- **A value of the wrong type**, such as a `nil` place or a string where a number belongs, signals `widget-value-error` naming the label, before any foreign call.
- **An invalid specification** signals **`control-spec-error`**, a subclass of `error` whose report names the label and the problem. `control-spec-error-label` and `control-spec-error-problem` read the two parts. The problems include, for example: `min` not below `max`; `:log` with `min` of 0 or less; a non-positive `:step`; empty or non-string `:choices`, or `:choices` with `:min`, `:max`, `:step` or `:scale`; a `:default` outside the range; an unknown `:unit`; a `:format` that isn't a function (such as a printf string like `"%.2f"`); a keyword the control doesn't take (such as `:length` on a knob); a size that isn't a positive number of rem or `(:px n)`; a malformed `:x` or `:y`. These are signalled before any foreign call.
- **A value outside the range**, for example set from code, is displayed clamped but not written back unless the user changes the control. Drawing a control never changes its value.
- **Types are preserved.** A `double-float` stays a `double-float`; integers and choice indexes stay integers.
- **A `:format` function that signals** fails the panel, like any other error in panel code.

Inside a panel, all of these fail the panel through the usual error handling.

### Plots

**`(with-plot (title &key (width -1) (height 0) flags) &body body)`** — An ImPlot plot area. A width of -1 fills the available width; a height of 0 uses ImPlot's default. Flags use `%implot`'s `FLAGS` prefix, such as `:no-title` or `:no-legend`. The body, which calls the plot functions, runs only when the plot is visible.

Each plot item takes its line, fill and marker colour from the current theme's `:series`, in order, cycling. The count restarts at the first colour for each `with-plot`. Outside a `with-plot`, ImPlot picks the colour.

**`(plot-lines label ys &key xs)`** — A line through `ys`, against `xs` or against 0, 1, 2, ... when `xs` is `nil`.

**`(plot-bars label ys &key (bar-size 0.67))`** — Bars at x = 0, 1, 2, ..., each `bar-size` wide.

**`(plot-scatter label xs ys)`** — Circle markers at each `(xs[i], ys[i])`.

Data may be any sequence of reals. A `(simple-array single-float (*))` or `(simple-array double-float (*))` is passed to ImPlot directly, with no copy; anything else is copied into a new `single-float` vector every frame. `xs` and `ys` must be the same length; if their element types differ, both are copied as `single-float`. Empty data draws nothing. A wrong length or a non-real element signals an error naming the label.

### Drawing

For custom widgets. Coordinates are in **screen space**, in pixels from the top-left of the OS window; use `cursor-screen-pos` to find where the next item would go. Every draw function takes `&key (draw-list (window-draw-list))` and returns no values.

**`(color r g b &optional (a 1.0))`** — Packs components from 0 to 1 (clamped) into ImGui's 32-bit color format.

**`(window-draw-list)`** — The current window's draw list.

**`(draw-line x1 y1 x2 y2 color &key (thickness 1.0))`**

**`(draw-rect x1 y1 x2 y2 color &key filled (rounding 0.0) (thickness 1.0))`** — From corner `(x1, y1)` to corner `(x2, y2)`.

**`(draw-circle cx cy radius color &key filled (segments 0) (thickness 1.0))`** — 0 segments lets ImGui choose.

**`(draw-arc cx cy radius a-min a-max color &key (thickness 1.0) (segments 0))`** — Angles in radians, measured clockwise from the positive x axis (screen y points down).

**`(draw-polyline points color &key closed (thickness 1.0))`** — `points` is a flat list or vector `x0 y0 x1 y1 ...`. Fewer than two points draws nothing; an odd number of coordinates is an error.

**`(draw-text x y color string)`**

### Interaction

**`(invisible-button id width height)`** — Reserves a `width` × `height` area as an item that responds to the mouse, without drawing anything. Returns true on click. Then `item-hovered-p` and `item-active-p` describe it. `width` and `height` must be greater than 0.

**`(item-hovered-p)`**, **`(item-active-p)`** — Whether the mouse is over the last item, and whether it's being held (pressed or dragged).

**`(cursor-screen-pos)`**, **`(set-cursor-screen-pos x y)`** — Where the next item will be placed, as `(values x y)` in screen space; move it.

**`(mouse-pos)`** — The mouse position, `(values x y)`.

**`(mouse-drag-delta &optional (button 0))`**, **`(reset-mouse-drag-delta &optional (button 0))`** — Distance dragged since the button was pressed (or since the last reset), `(values dx dy)`; reset it. Button 0 is left, 1 right, 2 middle.

**`(content-region-avail)`** — Space left in the current window or child, `(values width height)`.

### Flags

**`(enum-flags prefix designator &optional (package '#:%imgui))`** — Converts `designator` to an integer. An integer is returned as is, `nil` is 0, a keyword is looked up as the constant `+PREFIX-KEYWORD+` in `package`, and a list of keywords is combined with `logior`. An unknown keyword signals an error naming the constant it looked for.

```lisp
(gui:enum-flags "WINDOW-FLAGS" '(:no-title-bar :no-resize))   ; window flags
(gui:enum-flags "IM-DRAW-FLAGS" :round-top)                   ; drawing flags keep "IM-"
(gui:enum-flags "FLAGS" :no-legend '#:%implot)                ; ImPlot plot flags
```

Most ImGui prefixes lose their `ImGui` part (`WINDOW-FLAGS`, `TABLE-FLAGS`, `COL`, `STYLE-VAR`), but a few enums keep `IM-` (`IM-DRAW-FLAGS`, `IM-FONT-FLAGS`, ...). See "Enum constant prefixes aren't uniform" in `generator/README.md`.

## Themes

A theme replaces ImGui's default look. The two shipped themes are inspired by Ableton Live: flat, compact, low-contrast, with an orange accent. `:mid-light` is the default; `:dark` is the other. Themes are data, defined in `theme.lisp`. A theme has a palette, a style, and optional colour overrides, and it is applied when the window is created and again whenever you call `set-theme`.

### Palette

The palette gives each role a colour. A colour is `"#rrggbb"`, `"#rrggbbaa"`, or a list `(r g b [a])` of reals from 0 to 1.

| Role | Used for |
| --- | --- |
| `:background` | The colour behind all windows (the GL clear colour) |
| `:panel` | Window, child and popup backgrounds |
| `:title` | Title bars, menu bars, table headers, inactive tabs |
| `:frame` | Backgrounds of sliders, checkboxes, text fields and plots |
| `:frame-hover` | The same, hovered |
| `:control` | Buttons, headers, scrollbar grabs |
| `:control-hover` | The same, hovered |
| `:border` | Borders, separators, plot grid |
| `:text` | Text |
| `:text-dim` | Disabled text; a control's value text while it isn't being used |
| `:accent` | Check marks, slider grabs, pressed controls, selections |
| `:accent-text` | Text drawn on the accent. For custom controls; the ImGui mapping doesn't use it |
| `:series` | A list of colours for plot lines, bars and markers |
| `:error` | Outline of an invalid typed entry in a control; not used by ImGui's stock widgets. `#b3261e` in `:mid-light`, `#e5534b` in `:dark` |

The palette maps onto all of ImGui's colours (`*imgui-color-map*` in `theme.lisp`) and all of ImPlot's (`*implot-color-map*`). Some mappings use a role at part opacity, such as the accent at 35% for text selection.

### Sizes

`:style` sets ImGui style sizes by `ImGuiStyle` field name (`:frame-padding`, `:item-spacing`, `:frame-rounding`, ...). A number is in **rem**: it is multiplied by ImGui's current base font size when the theme is applied. `(:px n)` is a fixed number of pixels. A size that ImGui keeps as a pair (`:frame-padding`) is a two-element list, each element a number or `(:px n)`.

This works like CSS rem. One font-size setting controls the density of the whole UI: padding, spacing, scrollbars and indents all follow `set-font-size`. Rounding and border sizes in the shipped themes are fixed pixels.

### Colour overrides

`:colors` overrides individual ImGui colours by `COL` name, the same names `with-style` takes (`:button`, `:frame-bg`, ...). Overrides apply after the palette mapping. An unknown name is an error at `define-theme`.

### Defining a theme

Give `:base` to start from another theme and override only what differs:

```lisp
(gui:define-theme :my-dark
  :base :dark
  :palette '(:accent "#4fb3ff")
  :style '(:frame-rounding (:px 6))
  :colors '(:button-hovered "#555555"))
```

Without `:base`, the palette must have every role. Defining a name that exists replaces it. Defining the current theme reapplies it at once.

### Limits

ImGui's stock slider draws a grab handle on a track, not a bar filled up to the value. Filled sliders, arc knobs and lit toggles are the [controls](#controls): `fader`, `knob` and `toggle`. They take their colours from `theme-color`, so they follow the theme.

## File by file

The `sc-imgui` system loads these in this order (`sc-imgui.asd`); each may use the ones before it.

| File | Contents |
| --- | --- |
| `package.lisp` | The `gui` package: its exports, the re-exports from `gui.runtime`, and the shadowing of `cl:remove`. |
| `define-gui.lisp` | `define-gui`, `show`, `hide`, `remove`, `call-in-gui-thread`: thin wrappers over the runtime registry and task queue. |
| `foreign.lisp` | Shared helpers: `enum-flags` and the compile-time flag resolution used by the macros; `vec2` (internal), which builds the plist form of a by-value `ImVec2`; stable object IDs for `with-id`, from a weak, synchronized hash table; and the 64-byte scratch buffer that widgets use for out-values, allocated on first use and reallocated after an image is saved. |
| `scopes.lisp` | `with-window`, `with-group`, `with-child`, `with-section`, `with-id`, `with-font`, `with-disabled`, `with-style`. |
| `layout.lisp` | The layout functions, `with-row`, and `with-grid`. |
| `widgets.lisp` | `widget-value-error`; the `-value` functions; `define-place-widget`, which generates each place macro from its `-value` function using `get-setf-expansion`; `button` and `text`. |
| `theme.lisp` | Themes: the palette-to-ImGui and ImPlot colour maps, `define-theme`, `set-theme`, `set-font-size`, `theme-color`, `apply-theme` (internal; writes the styles and the clear colour, and runs from `gui.runtime:*after-window-created-hook*`), and the two shipped themes. |
| `plots.lisp` | `with-plot` and the plot functions. `plot-data` decides whether to copy; `plot-pair` matches `xs` and `ys`; `plot-spec` builds ImPlot's `ImPlotSpec` argument with the theme's next series colour (`next-series-color`) and ImPlot's other defaults; vectors are pinned with `cffi:with-pointer-to-vector-data` during each call. |
| `draw.lisp` | `color`, the draw functions, and the interaction helpers. |
| `controls/` | The audio controls, loaded after `draw.lisp`: `spec.lisp` (value specifications, `control-spec-error`, mapping between value and position), `units.lisp` (formatting and parsing for each unit), `core.lisp` (the shared interaction, per-control state, typed entry, rem sizes), then `number-box.lisp`, `knob.lisp`, `fader.lisp`, `buttons.lisp` (toggle and trigger) and `xy-pad.lisp`. |

## Building a custom widget

`examples/custom-knob.lisp` builds a knob from the pieces above. `gui:knob` now exists (see [Controls](#controls)), and this walkthrough shows how the controls are built: each reserves an invisible button, reads interaction, and draws with the primitives and `theme-color`. The real controls add one shared layer for mapping, display and typed entry (`src/gui/controls/`).

Here is the knob, with the five steps marked:

```lisp
(defun example-knob (label value min max &key (size 48))
  (multiple-value-bind (x y) (gui:cursor-screen-pos)   ; 1. where the widget starts
    (gui:invisible-button label size size)             ; 2. reserve space, get mouse input
    (let ((active (gui:item-active-p))
          (r (/ size 2.0)))
      (when active                                     ; 3. update the value from the drag
        (multiple-value-bind (dx dy) (gui:mouse-drag-delta)
          (declare (ignore dx))
          (setf value (max min (min max (- value (* dy (/ (- max min) 200.0))))))
          (gui:reset-mouse-drag-delta)))
      (let* ((cx (+ x r)) (cy (+ y r))                 ; 4. draw it from the current value
             (start (* pi 0.75))
             (end (+ start (* (/ (- value min) (- max min)) pi 1.5))))
        (gui:draw-circle cx cy (- r 2) (gui:theme-color (if active :control-hover :control))
                         :filled t)
        (gui:draw-arc cx cy (- r 3) start end (gui:theme-color :accent) :thickness 3)))
    (gui:text "~A ~,2F" label value)
    value))                                            ; 5. return the new value
```

The steps:

1. **Record the position** with `cursor-screen-pos` before adding any item.
2. **Reserve the area** with `invisible-button`. It makes the area an item, so the layout moves past it, and gives it mouse input. Its label is its ID, so repeated widgets need distinct labels or `with-id`.
3. **Read the interaction** with `item-active-p` and `mouse-drag-delta`. Resetting the drag delta after each use makes it a per-frame change, so the value never drifts.
4. **Draw** with the primitives, in screen coordinates relative to the recorded position. Colours come from `theme-color`, so the knob follows `set-theme`. (The full example also draws the track and the pointer.)
5. **Return the new value.** This makes it a `-value`-style function. To give it a place form too, see [Extending the API](#extending-the-api).

The knob draws on top of the area it reserved. Wrapping each knob in `with-group` lets several sit in a row with their labels.

## Recipes

### One set of controls per synth

```lisp
(gui:define-gui mixer ()
  (gui:with-window ("Mixer")
    (dolist (s *synths*)
      (gui:with-id (s)                                 ; same labels, separate widgets
        (gui:with-row ()
          (gui:text "~A" (synth-name s))
          (when (gui:slider "Amp" (synth-amp s) :min 0.0 :max 1.0)
            (ctrl s :amp (synth-amp s))))))))
```

### A synth device

A row of knobs, a volume fader, and a toggle and trigger, in one window. `examples/controls.lisp` is a fuller version with a vertical fader, a number box and an XY pad.

```lisp
(gui:define-gui saw-device ()
  (gui:with-window ("Saw")
    (gui:with-row ()
      (gui:knob "Cutoff" *cutoff* :min 20 :max 20000 :scale :log :unit :hz)
      (gui:knob "Res" *res* :unit :percent)
      (gui:knob "Pan" *pan* :min -1 :max 1 :bipolar t :unit :pan))
    (gui:fader "Volume" *vol* :min -70 :max 6 :default 0 :unit :db)
    (gui:with-row ()
      (gui:toggle "Mute" *mute*)
      (when (gui:trigger "Hit") (play-note)))))
```

### A live scope with no copying

Keep one specialized vector and update it in place. It's passed to ImPlot by pointer each frame.

```lisp
(defvar *scope* (make-array 512 :element-type 'single-float :initial-element 0.0))

(gui:define-gui scope ()
  (let ((phase (/ (get-internal-real-time) internal-time-units-per-second 1.0)))
    (dotimes (i (length *scope*))                      ; stand-in for real audio data
      (setf (aref *scope* i) (sin (+ phase (* i 0.05))))))
  (gui:with-window ("Scope")
    (gui:with-plot ("##scope" :height 200 :flags '(:no-legend))
      (gui:plot-lines "signal" *scope*))))
```

### A styled button

```lisp
(gui:with-style ((:color :button 0.7 0.15 0.15)
                 (:color :button-hovered 0.85 0.2 0.2)
                 (:var :frame-rounding 6.0))
  (when (gui:button "PANIC" :width 120 :height 40)
    (stop-all-synths)))
```

### Fonts: a heading, a big readout, and a bold weight

Inter Regular and SemiBold are loaded by default, so `:semibold` works at once. `with-font` takes a size for a one-off big number:

```lisp
(gui:define-gui levels ()
  (gui:with-window ("Levels")
    (gui:with-font (:semibold)
      (gui:text "Output"))
    (gui:with-font (:regular :size 28)
      (gui:text "~,1F dB" *level-db*))
    (gui:text "Peak hold")))
```

For another weight, download `Inter-Bold.ttf` from the same Inter release (`Inter-4.1.zip`, in `extras/ttf/`), add it to `*fonts*`, then recreate the window:

```lisp
(setf (getf gui:*fonts* :bold) "/path/to/Inter-Bold.ttf")
(gui:shutdown)
(gui:start)

(gui:define-gui title ()
  (gui:with-window ("Title")
    (gui:with-font (:bold :size 22)
      (gui:text "Bold"))))
```

The panels stay registered through `shutdown`, so they come back on the new window.

### Switching theme

```lisp
(gui:set-theme :dark)        ; applies between frames
(gui:set-theme :mid-light)
```

With no window yet, `set-theme` only sets `gui:*theme*`, used when the window is created.

### Live-like density

Sizes are in rem, so one call changes the density of the whole UI:

```lisp
(gui:set-font-size 13)       ; smaller text, tighter padding and spacing
(gui:set-font-size 15)       ; the default
```

### A custom accent

```lisp
(gui:define-theme :my-dark :base :dark :palette '(:accent "#4fb3ff"))
(gui:set-theme :my-dark)
```

### Colours for a custom widget

Use `theme-color` instead of fixed colours, so the widget follows the theme:

```lisp
(gui:draw-circle cx cy r (gui:theme-color :control) :filled t)
(gui:draw-arc cx cy r a0 a1 (gui:theme-color :accent) :thickness 3)
```

### A fixed window

Window size isn't wrapped yet, so set it with `%imgui` before the window. `gui::vec2` is internal.

```lisp
(gui:define-gui meter ()
  (%imgui:set-next-window-size (gui::vec2 220 300) %imgui:+cond-first-use-ever+)
  (gui:with-window ("Meter" :flags '(:no-resize :no-collapse))
    (gui:text "Level")))
```

## Extending the API

Add new wrappers here rather than calling `%imgui` throughout your own code, so the protections apply everywhere.

**A new place widget.** Write a `-value` function that checks its arguments with `%check` before any foreign call, passes out-values through `(scratch)`, and returns `(values new changed-p)`, returning the original value unchanged when nothing changed. Then generate the macro:

```lisp
(defun meter-value (label value &key (min 0.0) (max 1.0))
  (%check label value 'real)
  ...)
(define-place-widget meter meter-value)
```

**A new scope macro.** Wrap the begin call and the body in `unwind-protect` with the end call. Check ImGui's rule for each pair:

- Some end calls must always run (`End`, `EndChild`, `EndGroup`, the pops). Call them unconditionally.
- Others are valid only when the begin returned true (`EndTable`, `EndCombo`, `EndListBox`, `EndPlot`, `EndTabBar`, `EndMenu`, `EndTooltip`). Put the whole `unwind-protect` inside `(when open ...)`.

Use gensyms for any variable the expansion binds; a test checks that the macros don't capture a user variable named `open`. Resolve flags with `%flags-form` so literal keywords are checked at compile time.

**Then:** export the new names in `package.lisp`, add the file to `sc-imgui.asd` if it's a new file, and add tests to the matching suite (`widgets`, `scopes`, `plots`, `draw`, or `controls` for the audio controls). Test widgets through simulated input with `click-item`, and scope macros with the error-balance pattern in `tests/test-scopes.lisp`. See `tests/README.md`.

## Not yet wrapped

These common ImGui features exist in `%imgui` but have no `gui` wrapper yet. Calling them from a panel works, but you must balance their begin/end pairs yourself, and an error between them isn't protected.

| Feature | `%imgui` functions | Notes |
| --- | --- | --- |
| Tabs | `begin-tab-bar`, `begin-tab-item`, `end-tab-item`, `end-tab-bar` | End only when the begin returned true |
| Menus | `begin-menu-bar`, `begin-main-menu-bar`, `begin-menu`, `menu-item-bool`, and their ends | The window needs the `:menu-bar` flag for `begin-menu-bar` |
| Tooltips | `begin-tooltip`, `end-tooltip` | `set-tooltip` isn't bound (it's variadic); use `begin-tooltip` and `gui:text` |
| Popups and modals | `open-popup-str`, `begin-popup`, `begin-popup-modal`, `end-popup` | |
| Colour pickers | `color-edit3`, `color-edit4`, `color-picker4` | Take a pointer to 3 or 4 floats |
| Vertical sliders | `v-slider-float`, `v-slider-int` | `gui:fader` with `:vertical t` is the audio version |
| Multi-value sliders | `slider-float2`, `slider-float3`, ... | Take a pointer to an array |
| Radio buttons | `radio-button-bool` | |
| Numeric inputs | `input-float`, `input-int` | Typed entry with +/- buttons |
| Trees | `tree-node-str`, `tree-pop` | |
| Progress bars | `progress-bar` | |
| Window size and position | `set-next-window-size`, `set-next-window-pos` | Call before `with-window` |
| Docking | `dock-space-over-viewport`, `set-next-window-dock-id` | Docking is enabled; windows can already be docked by dragging |
| Images | `image` | Needs a texture, which nothing creates yet |
| Keyboard | `is-key-pressed-bool`, `is-key-down-nil` | Key constants use the `KEY` prefix |
| The demo | `show-demo-window` | Shows every ImGui feature, with a pointer or `(cffi:null-pointer)` |

A tab bar from raw calls, for example:

```lisp
(when (%imgui:begin-tab-bar "tabs" 0)
  (unwind-protect
       (progn
         (when (%imgui:begin-tab-item "Synth" (cffi:null-pointer) 0)
           (unwind-protect (gui:text "synth controls") (%imgui:end-tab-item)))
         (when (%imgui:begin-tab-item "FX" (cffi:null-pointer) 0)
           (unwind-protect (gui:text "fx controls") (%imgui:end-tab-item))))
    (%imgui:end-tab-bar)))
```

Anything you use often belongs in `gui` as a proper wrapper.

## Gotchas

### Draw only from panels

Every widget, layout, plot, drawing, and interaction function calls into ImGui, and must run inside a frame on the GUI thread, which means inside a panel body. Calling one from the REPL thread, or from a `call-in-gui-thread` task, is ImGui misuse. Tasks run **between** frames, before `NewFrame`, so even on the right thread there's no frame to draw into. Use tasks only for between-frame work, such as style changes.

### Some bodies don't run every frame

`with-window` skips its body while the window is collapsed or clipped, `with-section` while collapsed, `with-child` and `with-grid` when not visible, and `with-plot` when the plot isn't visible. Don't put work there that must happen every frame, like updating a scope buffer or sending values to synths. Do it before the scope.

### Not every widget checks its value

`slider`, `drag`, `combo`, `input-text`, and `list-box` check their values and signal `widget-value-error` for a wrong type, such as a `nil` from a `defvar` with no value. `checkbox` and `selectable` accept anything, treating it as true or false, and write back `t` or `nil`.

### `format` strings go to C

The `:format` argument of `slider` and `drag` is a C printf format passed straight to ImGui, not a Lisp `format` string. Use exactly one numeric conversion matching the widget (`%d` for integers, `%f`, `%.2f`, or `%g` for floats), and write `%%` for a literal percent sign. Any other conversion, such as `%s`, is undefined behavior in C and can crash.

### `text` and `~`

`text` uses Lisp's `format` only when given arguments. `(gui:text "100%~")` displays literally, but `(gui:text "~A ~" x)` is a `format` error. To show a value next to a literal `~`, escape it as `~~`.

### Panel names are global functions

`define-gui` defines a global function with the panel's name in the current package. Don't reuse the name of a function you need, and don't call the panel function directly: it draws, so it must only run inside a frame.

### `show`, `hide`, and `remove` don't complain

`show` and `hide` return the name whether or not the panel exists, so a typo silently does nothing. `remove` returns `nil` for an unknown name. Check with `(gui.runtime:find-gui 'name)` when unsure.

### `gui:remove` shadows `cl:remove`

The `gui` package shadows `cl:remove`. If your package `:use`s `gui`, `remove` refers to `gui:remove`, and using `cl:remove` requires writing `cl:remove` or shadowing it yourself. Using `gui:` prefixes, as the examples do, avoids this.

### Repeated labels collide

Two widgets with the same label in the same window and ID scope share an ID: clicking one affects both, or ImGui records an assertion. Loops over objects need `with-id`, and repeated grids need distinct `:id`s. Custom widgets built with `invisible-button` need unique button IDs.

### `invisible-button` needs a real size

A width or height of 0 is an ImGui error for `invisible-button`, unlike `button`, where 0 means "fit the label".

### Plot data is copied unless it's specialized

Lists and general vectors are copied into a new vector every frame. For large or fast-changing data, keep a `(simple-array single-float (*))` or `double-float` vector and update it in place. Mixed element types between `xs` and `ys` also cause a copy.

### `input-text` limits bytes, not characters

`max-length` counts UTF-8 bytes. Text with accented or non-Latin characters fits fewer characters than `max-length` suggests.

### A redefined panel's windows refit once

After `define-gui` is re-evaluated, its windows resize to fit their contents on the next frame, discarding a manual resize. That's deliberate, so new widgets aren't hidden. A size set afterwards sticks.

### Fonts load only when the window is created

`*fonts*` and `*font-size*` are read once, when `start` creates a new window. `stop` and `start` only hide and show it, so changes don't show. Call `(gui:shutdown)` then `(gui:start)`. Until then, `with-font` with a name you just added fails the panel with `unknown-font`: an unknown name is an error, not a silent fallback.

### Raw calls aren't protected

`%imgui` and `%implot` calls bypass everything here: no type checks, no balanced scopes, `bool` and string details left to you. An unbalanced raw begin/end usually shows up as a recorded ImGui assertion rather than a Lisp error; check `(%shim:assert-count)` and `(%shim:last-assert)` if a panel misbehaves.

## Tests and examples

| Suite | Covers |
| --- | --- |
| `scopes` | Every scope macro, including `with-font`, stays balanced after an error; `with-font` sizes, nesting, the unknown-name error, and no fonts loaded; `with-row` and `with-grid` placement; `with-id` stability across garbage collection; `enum-flags`; no variable capture |
| `widgets` | Every widget writing back through simulated input; number types preserved; `-value` variants; UTF-8 truncation; `widget-value-error`; places evaluated once |
| `plots` | No copying for specialized vectors; coercion; length and type errors; every plot kind; series colours cycle per item and restart per plot |
| `draw` | `color` matches ImGui; every primitive adds vertices; polyline edge cases; invisible-button clicks and drags |
| `theme` | Colour and size parsing and errors; `define-theme` with and without `:base`; the palette mapping reaching every ImGui and ImPlot colour; rem and pixel sizes; `set-theme`, `set-font-size` and `theme-color`; the shipped themes |
| `controls` | Value specifications, units and parsing; every control's interaction (drag, Shift, wheel, double-click, typed entry), layout and no ImGui assertions |
| `examples` | Every file in `examples/` loads and draws without failures or assertions |

Not directly tested (see "Known gaps" in `tests/README.md`): the `drag` macro, `with-section`, the layout functions, `item-hovered-p`, `mouse-pos`, `content-region-avail`, `set-cursor-screen-pos`, `reset-mouse-drag-delta`, and the visible effect of `with-style`, `with-disabled`, and `with-font`. Some run indirectly through the examples.

The examples, each loaded after `(gui:start)` with `(load (asdf:system-relative-pathname :sc-imgui "examples/<file>.lisp"))`:

- `hello.lisp`: text, a button, a slider, a checkbox.
- `layout.lisp`: rows, a grid, a section, a scrolling child.
- `plots.lisp`: a live line plot, bars, and a scatter plot.
- `custom-knob.lisp`: the knob from [Building a custom widget](#building-a-custom-widget), coloured with `theme-color`.
- `controls.lisp`: a synth device with knobs, faders, a toggle, a trigger, a number box and an XY pad.
- `error-recovery.lisp`: a deliberately failing panel and how to recover it.
