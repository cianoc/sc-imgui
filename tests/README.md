# tests/: the test suites

Contents:

1. [Overview](#overview)
2. [Running the tests](#running-the-tests)
3. [Infrastructure files](#infrastructure-files)
4. [Suite by suite](#suite-by-suite)
5. [The smoke test](#the-smoke-test)
6. [Maintenance when upgrading submodules](#maintenance-when-upgrading-submodules)
7. [Gotchas](#gotchas)
8. [Adding a test](#adding-a-test)
9. [Troubleshooting failing tests](#troubleshooting-failing-tests)
10. [Coverage map](#coverage-map)
11. [Known gaps](#known-gaps)

## Overview

There are two kinds of tests:

- **`make test`** runs 229 [FiveAM](https://github.com/lispci/fiveam) tests in twelve suites. They run **headless**: ImGui runs with no window and no GPU, and each test draws frames itself by calling `NewFrame` and `Render`. They're fast, need no display, and run anywhere, including CI.
- **`make smoke`** opens a **real window** and drives the real frame loop on SBCL's main thread: starting, live redefinition, error recovery, hiding, showing, closing, and shutting down. It needs a display. On Linux CI it runs under Xvfb, a virtual display.

A third test lives outside this folder: `native/test_assert.c`, run by `make native`, checks that ImGui misuse is recorded rather than aborting the process. See `native/README.md`.

CI (`.github/workflows/ci.yml`, Ubuntu) runs `make native`, then `make test`, then `xvfb-run -s "-screen 0 1280x1024x24" make smoke`.

Neither kind compares rendered pixels. That's a deliberate choice for a personal tool; see [Known gaps](#known-gaps).

## Running the tests

Build the native library first. The tests load it, and `make test` doesn't build it for you:

```sh
make native
```

Then:

```sh
make test                  # every suite
make test SUITE=widgets    # one suite: generator, bindings, registry, frame, loop,
                           # scopes, widgets, plots, draw, theme, controls, examples
make smoke                 # real window; needs a display
```

`make test` exits with status 0 only when the test system loaded and every check passed. It exits with 1 when a check failed, and with 2 when loading failed. `make smoke` uses the same codes, and also exits with 1 after 30 seconds if anything hangs.

**From the REPL.** You can run suites in a running Lisp, for example from SLIME:

```lisp
(asdf:load-system :sc-imgui/tests)
(sc-imgui.tests:run-suites "widgets")   ; or (sc-imgui.tests:run-suites) for all
```

Two `loop` tests need the run to be on SBCL's main thread, as `make test` is. From the SLIME REPL, which runs on another thread, they're **skipped**, not failed. Don't start the GUI with `gui:start` in the same Lisp while the tests run: both use the same ImGui state, and only one window or headless context can exist at a time.

**The smoke test can't run from the REPL.** It ends the Lisp process when it finishes. Always run it with `make smoke`.

## Infrastructure files

### `run.lisp`

The entry point for `make test`. It loads Quicklisp if it's installed, adds the repository to ASDF's search path, loads `sc-imgui/tests`, runs the suite named by the `SUITE` environment variable (all suites if unset), and exits with the status codes above. If loading fails, it prints a backtrace first.

### `package.lisp`

Defines `sc-imgui.tests`, which uses FiveAM and the generator package, so generator tests can call its functions unqualified. Everything else is referred to with package prefixes: `gui:`, `gui.runtime:`, `%imgui:`, `%shim:`.

### `suites.lisp`

Defines the suite `all` and the twelve suites inside it, plus `run-suites`, which runs a suite by name and returns true only when every check passed. **A new suite must be added to the list here**, or `make test SUITE=<name>` reports "Unknown suite".

### `headless.lisp`

Shared helpers for tests that run ImGui without a window. Most tests are built from these.

| Helper | What it does | Why it's shaped this way |
| --- | --- | --- |
| `with-headless-imgui` | Clears the assertion record, creates a headless ImGui context (default 800×600), runs the body with float traps masked, and destroys the context afterwards, even after an error | Each test starts with a fresh context and a zero assertion count. Only one context can exist at a time. |
| `with-test-frame` | Runs `NewFrame`, the body, then `Render`, even if the body signals an error | A frame left open would break every later frame in the test. |
| `vec2`, `vec4` | Build the plist form CFFI uses for an `ImVec2` or `ImVec4` passed by value | Functions taking these structs by value go through cffi-libffi, which expects plists. |
| `last-item-center`, `last-item-rect` | The center or rectangle of the last drawn item | Used to aim simulated clicks. |
| `frames-with-click` | Simulates a click at (x, y) over four frames (move, press, release, idle), calling the draw function once per frame and returning its values | ImGui reads input from an event queue, so each event must be queued *before* the frame that should see it. A button reports a click on the release frame. `:warmup` runs extra frames first, because a newly created window is hidden on its first frame and can't be hovered until the next. |
| `in-window` | Runs the body inside a window named `"w"`, and records the last item's rectangle and the current item width | Saves boilerplate, and gives `click-item` something to aim at. |
| `click-item` | Draws twice so the item has a rectangle, then clicks its center (`:x-fn` picks another point, `:clicker` another click function) | The two priming frames cover the hidden-first-frame rule. |
| `click-item-at-right-edge` | Clicks 2 pixels inside the right edge of the item's *frame* | An item's rectangle includes its label, so the frame's right edge is calculated from the item width, not the rectangle. |
| `frames-with-drag`, `prime-and-drag` | Press, move by (dx, dy) while held, release; `:shift t` holds Shift throughout | Used for drag interactions, such as the knob in the examples and the controls. |
| `drag-path` | Prime a drawing function, press on its item, then move by each dy of a list, one frame per step, with an optional `:between` function called before each | Lets a test watch a value frame by frame, such as overshoot then reverse. |
| `frames-with-wheel` | Move to (x, y), then send mouse-wheel notches (a number, or a list with one event per frame as a trackpad sends); `:shift t` holds Shift; `:horizontal t` sends the notches on the horizontal wheel, as macOS sends Shift+wheel | Uses `im-gui-io-add-mouse-wheel-event`. The first frame after the event sees it in `io.MouseWheel`. |
| `frames-with-double-click` | Press and release twice at (x, y), one frame each | Double-click needs two presses within ImGui's double-click time. |
| `vtx-colors`, `control-colors` | The packed colours of a draw list's vertices from an index; `control-colors` returns those its body added to the window's draw list | Lets a test check which theme colours a control drew, such as `:text-dim` for an idle value. Record the second frame of a new window: the first clips all text. |
| `with-keys-held` | Queues key-down events for `:shift` or `:ctrl` before the body and key-up events after it, even if the body unwinds | Uses `im-gui-io-add-key-event`. `:ctrl` is what ImGui reports as `io.KeyCtrl`, which is Cmd on macOS, so one test works on every platform. |
| `press-key` | Queues a key-down for a key, runs a frame, queues the key-up and runs another | For Enter and Escape in typed entry. |
| `set-base-font-size` | Sets ImGui's base font size in its style, without reapplying the theme | Tests of controls at font sizes 13 and 15, and a size change mid-drag. |
| `type-text` | Queues typed characters and runs two frames | Text input needs a frame to receive the characters and one to apply them. |
| `with-clean-registry` | Empties the panel registry and task queue before and after the body | The registry is global, so without this, panels from one test would leak into the next. |
| `bundled-font` | The native path of a file in `assets/fonts/` | The shim takes native namestrings, and the tests shouldn't depend on the working directory. |
| `draw-some-text` | One frame drawing a window with text | Fonts build lazily, so a font has to be used in a frame before a bad one can show up as an assertion. |
| `with-loaded-fonts` | Calls `load-fonts` on the current headless context with a `*fonts*` plist (the bundled Inter by default), and runs the body with that font table | Headless contexts have no window, so nothing else loads fonts. Without it, `with-font` finds no fonts and changes nothing. |
| `current-font` | The current font and size, as `(address size)` | Lets a test see which font a scope selected, and that it was restored. |
| `vtx-count` | Number of vertices in a draw list | Reads ImGui's own structs directly (`im-draw-list`, `im-vector-im-draw-vert`) to show that drawing functions added something. |

### `fixtures/`

Hand-written miniature versions of cimgui's three JSON files: `definitions.json`, `structs_and_enums.json`, and `typedefs_dict.json`. They hold only the entries the generator tests need. Examples are `igButton` (a `bool` return plus an `ImVec2` by value), `igText` (variadic, so it must be skipped), and a struct with a bitfield, which must come out opaque. **They aren't copies of real cimgui output** and don't change when cimgui does. See [Maintenance](#maintenance-when-upgrading-submodules).

`expected-imgui.lisp` is the bindings file the generator wrote from those fixtures before name collisions became errors. `fixture-output-unchanged` checks that the same fixtures still produce it byte for byte. If you change the generator's output on purpose, regenerate it and review the diff.

### The test system in `sc-imgui.asd`

`sc-imgui/tests` lists the test files with `:serial t`, so they load in the order listed. `headless.lisp` must come before any file that uses its helpers. **A new test file must be added to this list**, or it's never loaded.

## Suite by suite

### `test-generator.lisp` (suite `generator`, 25 tests)

Tests the binding generator against the fixtures, without loading ImGui:

- **Naming:** C names to Lisp names, such as `igSliderFloat2` → `slider-float2`, `igGetIO` → `get-io`, and `ImPlot_PlotLine_FloatPtrInt` → `plot-line-float-ptr-int`.
- **Type mapping:** C types to CFFI types, including typedefs resolving through `typedefs_dict.json`, and unknown types returning `nil`.
- **Emitted forms:** variadic functions are skipped, enums become constants, and a struct with an unmappable field becomes opaque and warns.
- **`bool` handling:** every C `bool` argument or return becomes `:uint8` in a `NAME-RAW` function, with a `NAME` wrapper converting to and from `t`/`nil`. This works around how C `bool` behaves through cffi-libffi.
- **`const char*` arguments** accept `nil`, which is passed as NULL.
- **By-value structs:** a struct is emitted after the structs it contains, and ImPlot reuses ImGui's `ImVec2` from `%imgui` rather than defining its own.
- **Exports and prefixes:** the right names are exported, and ImPlot's output contains only ImPlot's structs and enums.
- **Name collisions:** two C functions, enum constants or structs that map to one Lisp symbol signal `binding-name-collision`. A function named like another's `NAME-RAW` counts too. One error lists every collision. An entry in `*lisp-name-overrides*` resolves each kind of collision: a bool function's wrapper and `NAME-RAW` are renamed together, and a renamed struct is used under its new name in fields and arguments. Inputs are built inline, not from the fixtures.
- **Unused overrides:** `generate-bindings` warns with `unused-name-override` for an override that matches nothing in either library, and doesn't warn for overrides that are used.
- **All or nothing:** `generate-bindings` run on temporary JSON writes neither file when cimplot has a collision.

### `test-bindings.lisp` (suite `bindings`, 22 tests)

Tests the loaded native library and the generated bindings, through real calls:

- The library loads, and a missing library signals `shim-library-not-found` listing the paths tried.
- Headless frames run, and **ImGui misuse is recorded instead of aborting** (`assert-does-not-abort`).
- `ImGuiIO` isn't opaque: `display-size` reads back as 800.
- Structs returned by value work, and simulated clicks land (`frames-with-click-clicks-a-button`) or miss (`mouse-over-nothing-does-not-click`).
- The window-related shim functions are harmless when there's no window. `set-clear-color` is harmless with no window and on a headless context.
- `nil` and string arguments, and `t`/`nil` booleans, reach C correctly on both CFFI call paths: plain calls, and cffi-libffi calls used when a struct is passed by value.
- **Fonts:** `add-font` returns consecutive indexes, a bad path returns -1 with the path in `last-error` and uses up no index, and a missing file, a NIL path, or a file that isn't a font as the first font all leave a working built-in default at index 0 with no ImGui assertion. `push-font` with a real, `-1`, or missing index is balanced by `pop-font`.

### `test-registry.lisp` (suite `registry`, 9 tests)

The panel registry and task queue, without ImGui:

- `define-gui` registers a panel; redefinition replaces it in place and clears a failure; `hide`, `show`, and `remove` work; a lambda list with arguments is rejected.
- Registration from 8 threads at once loses nothing.
- `call-in-gui-thread` tasks keep running after one signals an error, even an error whose message itself can't be printed.
- Redefinition marks the panel's windows for a one-time refit, using tokens that survive overlapping redefinitions.

### `test-frame.lisp` (suite `frame`, 13 tests)

Drawing registered panels and recovering from their errors, headless:

- Healthy panels are drawn; hidden panels are skipped.
- **A failing panel is isolated:** other panels keep drawing, including when the failing panel left an ImGui window open.
- The error report goes to the stream captured by `start` (`report-goes-to-captured-stream`).
- The failed panel's Retry button clears the failure.
- With `*debug-on-error*`, the debugger is reached with the `retry-panel` and `disable-panel` restarts, before any outer handler can catch the error.
- Redefining a panel refits its windows to their contents once; afterwards, a manual size sticks.
- Reporting never signals: an unprintable condition, or a closed report stream (which falls back to `*error-output*`), doesn't break the frame.
- Runaway recursion fails only its own panel, and works again the second time, which shows the stack guard is restored.

### `test-loop.lisp` (suite `loop`, 17 tests)

`start`, `stop`, and `shutdown` without opening a window. A real window is the smoke test's job.

- `stop` and `shutdown` return `nil` with no loop, and the GUI isn't running by default.
- **State transitions are tested by setting the loop's state by hand:** `stop` hides a showing window, `start` shows a hidden one, and `shutdown` ends a hidden or showing loop.
- `start` called on the main thread signals `main-thread-busy`, with instructions for SLIME.
- A failure to open the window is reported, and doesn't destroy the headless context.
- A panel calling `start` while the loop runs gets `nil`. *Main thread only; skipped otherwise.*
- **Fonts** are loaded on a headless context with `with-loaded-fonts`, standing in for the loop's call to `load-fonts`. The defaults are the two bundled Inter files and a base size of 15. `:regular` loads first as index 0 whatever its place in the plist, and the rest follow in order. A font that fails is reported with source `:font`, naming the font and path, and its name maps to the regular font. A bad or missing `:regular` falls back to the built-in font. Having no `:regular` isn't an error. `*font-size*` sets the base size. Unusable settings (a size that isn't a number, an odd-length plist, a path that isn't a string) are each reported once with source `:font`, and `load-fonts` never signals, so the GUI keeps drawing.
- **The after-window-created hook:** `window-created`, the function the loop calls once the window opens, runs on a headless context. The fonts are loaded before the hook functions run, a hook function that signals is reported with source `:theme`, and the functions after it still run.
- **Regression:** a handoff to the main thread survives the main thread deferring interrupts for a second. That's the case where the earlier `trivial-main-thread` version lost the request. *Main thread only; skipped otherwise.*

### `test-scopes.lisp` (suite `scopes`, 13 tests)

The scope and layout macros, headless:

- **Errors keep scopes balanced** for every scope macro: an error inside `with-window`, `with-group`, `with-child`, `with-id`, `with-disabled`, `with-style`, or `with-grid` leaves no ImGui assertion.
- `with-row` puts items on one line, and `with-grid` fills columns in order.
- **`with-id` gives the same ID before and after a full garbage collection,** because Lisp objects can move in memory and their addresses are never used as IDs.
- `enum-flags` resolves keywords and rejects unknown ones.
- The macros don't capture a user variable named `open`.
- `with-grid`'s default ID tells apart bodies that differ deep inside, and stays the same for identical bodies.
- **`with-font`** stays balanced after an error, with and without fonts loaded, and restores the font and size. `:size` applies inside and restores, nested uses work, and no `:size` keeps the current size. An unknown name signals `unknown-font`, with the message listing the loaded fonts. With no fonts loaded, it changes nothing. `errors-keep-scopes-balanced` also covers `with-font`, without fonts loaded.

### `test-widgets.lisp` (suite `widgets`, 15 tests)

The widgets, through simulated mouse and keyboard input:

- A button reports exactly one click. A checkbox, selectable, combo, list box, slider, and text input all write the new value back to their place.
- Sliders keep the original number type (`double-float` stays `double-float`, integers stay integers), and the log scale draws cleanly.
- The `-value` variants return the value unchanged when there's no input.
- Text input truncates at a UTF-8 character boundary, never inside a character.
- A place's subforms are evaluated once per call.
- `text` only uses `format` when given arguments, so a `~` in plain text is safe.
- **A `nil` place signals `widget-value-error`, naming the label,** before any foreign call.
- A list box tolerates no selection and duplicate items.

### `test-plots.lisp` (suite `plots`, 7 tests)

- Specialized `single-float` and `double-float` vectors are passed without copying; lists and general vectors are converted to `single-float` vectors.
- Non-numbers, and `xs` and `ys` of different lengths, signal errors naming the plot label.
- Every plot kind draws cleanly, including empty data and mixed float types.
- The plot body runs, and `EndPlot` balances.
- **Series colours:** each item in a `with-plot` takes the next `:series` colour of the theme, cycling past the last one, and the count restarts at the first colour in the next `with-plot`.

### `test-draw.lisp` (suite `draw`, 5 tests)

- `gui:color` packs colors exactly as ImGui does, including out-of-range components, which are clamped.
- Every drawing primitive adds vertices to the draw list.
- `draw-polyline` draws nothing for a single point, and rejects an odd number of coordinates.
- An invisible button reports clicks, and a drag reports its distance while the button is held.

### `test-theme.lisp` (suite `theme`, 15 tests)

Themes, on a headless context. The tests apply a theme directly with `gui::apply-theme`, or queue it and run the task with `run-queued-tasks`, and read ImGui's and ImPlot's styles back through `%imgui:get-style` and `%implot:get-style`. Helpers local to the file read colours and sizes from those styles. `with-test-themes` forgets the themes a test defines.

- Both shipped themes write their palette into the ImGui and ImPlot colours they map to, and the mapping sets every ImGui and ImPlot colour.
- Rem sizes scale with the base font size, and `(:px n)` sizes don't.
- `:base` copies a theme and overrides it key by key, and a `:colors` override wins over the palette mapping.
- Colour parsing accepts the hex and list forms, and `define-theme` rejects bad data with an error that names the colour, role, colour name or size.
- `theme-color` matches `gui:color`, and `set-theme` with an unknown name lists the known themes.
- With no window, `set-theme` and `set-font-size` only set their variables and queue nothing. With a window, showing or hidden, each queues one task that applies the change, and the result draws with no ImGui assertions.
- Redefining the current theme reapplies it.
- Both shipped themes define `:error`, a theme without `:base` and without `:error` is rejected, and a derived theme inherits it.

### `test-control-spec.lisp` (suite `controls`, 16 tests)

The pure-Lisp part of the controls: no ImGui. The file's local `spec` helper builds a normalized specification from keywords.

- Mapping between value and position round-trips for linear, log, stepped and bipolar specs, and choices clamp their index. A non-positive value on a log scale maps to position 0 instead of signalling.
- Integer places snap to 1, and a `double-float` stays a `double-float`.
- Bipolar origins and defaults: `t` picks 0 or the midpoint; a number sets the origin.
- Every specification error names the label and the problem, including a `:format` that isn't a function (a printf string, a number, an unbound symbol).
- Unit formatting at the boundaries (`999 Hz` and `1.00 kHz`, `-inf dB`, `C` for pan, `0 st`), plain-number precision, choice names and custom `:format` functions.
- Parsing typed text (`2k`, `2.4 kHz`, `-6 dB`, `25R`), bare numbers following the display scale for `:percent` and `:pan`, rejecting garbage, and never signalling on huge numbers.

### `test-controls.lisp` (suite `controls`, 70 tests)

The controls on a headless context, through the harness helpers above. `with-controls-env` sets up a headless context with the `:mid-light` theme and a base font size of 15; each test checks that no ImGui assertion was recorded. Comments mark the tests that guard a specific review risk.

- **The core, through `number-box`:** a drag up raises the value by the expected amount, Shift is ten times finer, and overshooting then reversing doesn't stick. Double-click resets; wheel notches move 1% or one step, 0.1% with Shift (also when only the horizontal wheel moves, as on macOS), and trackpad fractions add up to a step. The number box's default width fits interior values wider than its ends, and its frame stays `:frame-hover` while dragged off it. The control-state table is emptied, without freeing, by a save hook. Drawing never writes. Disabled controls ignore input. Per-control state is removed after release and when the control vanishes mid-drag. A font-size change mid-drag is safe. A signalling `:format` propagates, wrong value types signal before drawing, and types are preserved. Unknown keywords and bad sizes on every control signal `control-spec-error` naming the label.
- **Typed entry:** Ctrl-click (Cmd on macOS) opens the field; Enter commits, clamped and snapped; garbage and Enter keeps it open with the error flag and the value unchanged, and correcting it commits; Escape and clicking elsewhere cancel; a value changed by code survives Escape and an unedited Enter; Ctrl-double-click doesn't reset. A plain click on a number box opens the field once the double-click time has passed; a double-click still resets without opening it; a drag doesn't open it; a click on a knob doesn't.
- **Knob:** drags and keeps its type, draws a non-positive log value, aligns in a row at two font sizes, draws bipolar and choice knobs, and signals on the wrong type.
- **Fader:** in both orientations a click jumps to the clicked point only after the double-click time, a press-and-drag jumps at once and then tracks the mouse 1:1 along the bar, a drag across the axis changes nothing, a Shift-press doesn't jump (Shift-drag is ten times finer), and a double-click resets instead of jumping; fill, bipolar fill and width; thickness and length defaults, including the vertical fader's 3.5 rem item, wide enough for `-12.0 dB` at three font sizes; the bar and fill rectangles' geometry; the value drawn in `:text-dim`, or `:text` while dragged.
- **Toggle and trigger:** a toggle flips and accepts any boolean; a trigger reports pressed, held and released on the right frames; both ignore input when disabled; widths.
- **XY pad:** a click jumps to the point and Shift-drag moves finely; each axis has its own specification; double-click resets both; y up increases; an absolute drag follows the mouse; pressing Shift doesn't jump; types are kept; out-of-range values aren't written; the macro evaluates its subforms once; size and a single item; malformed specifications and wrong value types signal.

### `test-examples.lisp` (suite `examples`, 2 tests)

Loads each file in `examples/` headlessly and draws three frames:

- `hello`, `layout`, `plots`, `custom-knob`, and `controls` register panels, none fails, and no ImGui assertion is recorded.
- `error-recovery` fails exactly its one deliberately broken panel.

This keeps the examples working as the code changes.

## The smoke test

`smoke.lisp` opens a real window and checks, in order:

1. `(gui:start)` returns `t`, and a second call returns `nil`. The first call is made while the main thread is deferring interrupts, to exercise the handoff.
2. A panel draws 300 frames.
3. Redefining a panel takes effect within 60 frames.
4. A panel that signals an error doesn't stop other panels, and the error report reaches the stream captured by `start`.
5. `stop` hides the window while the loop keeps running, saves the layout to `*ini-path*`, and `start` shows the same window again.
6. A simulated close-button press hides the window, and `start` brings it back. `shutdown` ends the loop, `start` afterwards opens a fresh window that draws frames, and a final `shutdown` ends cleanly.

It also checks themes. The default theme (`:mid-light`) must be applied at the first start and in the new loop after `shutdown`, read from ImGui's window background colour on the GUI thread. `(gui:set-theme :dark)` must apply between frames, `(gui:set-font-size 13)` must set the base size and move the frame padding to 0.38 rem (0.38 × 13 px), and switching back to `:mid-light` and 15 px must restore both. No theme errors may be reported, and nothing may be reported by the switches.

It also checks fonts. The `smoke-fonts` panel draws text with `with-font` (`:semibold`, and `:regular` at 28 px). At the first start and again in the new loop after `shutdown`, the font table must be `((:regular . 0) (:semibold . 1))` and the panel must see sizes 15, 15, and 28. No font errors may be reported, the font table must be `nil` after `shutdown`, and there must be no ImGui assertions (read on the GUI thread) after the new loop's fonts.

How it runs:

- **The checks run in a worker thread,** and the main thread idles in `sleep`, as it would at an idle SLIME REPL. That leaves the main thread free to accept the loop.
- **A watchdog thread** ends the run with status 1 after 30 seconds, printing the frame counters, so a hang can't stall CI.
- The layout file is written to the system temporary directory (`sc-imgui-smoke.ini`) and deleted at the start of each run.

## Maintenance when upgrading submodules

Read this alongside "Upgrading the third-party libraries" in `native/README.md`.

### Generated names the tests call directly

Most tests go through the `gui` layer, but some call the generated bindings directly. Those break first when cimgui renames something.

**Overload-suffixed names** are the most fragile. cimgui adds a suffix when ImGui has several functions with the same name, and the suffix can change when ImGui adds or removes an overload. For example, `igGetIO` became `igGetIO_Nil` when ImGui added a second version.

| Name | Used in |
| --- | --- |
| `%imgui:get-io-nil` | `headless.lisp` (all input simulation), `test-bindings.lisp` |
| `%imgui:selectable-bool` | `test-bindings.lisp` |
| `%imgui:tree-node-str` | `test-bindings.lisp` |
| `%imgui:get-id-str` | `test-bindings.lisp`, `test-scopes.lisp` |
| `%imgui:set-window-size-vec2` | `test-frame.lisp` |

**Other generated functions used directly:** `new-frame`, `render`, `begin`, `end`, `button`, `invisible-button`, `progress-bar`, `text-unformatted`, `calc-text-size`, `calc-item-width`, `get-item-rect-min`, `get-item-rect-max`, `get-item-id`, `get-window-size`, `get-current-context`, `set-next-window-pos`, `set-next-item-open`, `tree-pop`, `color-convert-float4-to-u32`, and the input-event functions `im-gui-io-add-mouse-pos-event`, `im-gui-io-add-mouse-button-event`, and `im-gui-io-add-input-characters-utf8`.

**Struct slots read directly:** `im-gui-io` → `display-size`; `im-draw-list` → `vtx-buffer`; `im-vector-im-draw-vert` → `size`; and `im-vec2`'s `x`/`y` and `im-vec4`'s `x`/`y`/`z`/`w`. If any of these structs becomes opaque, or a field is renamed, `io-struct-is-not-opaque` and the draw tests fail.

The `gui` layer itself also depends on generated names. A failure that appears across many suites at once usually means a name changed in `src/gui/`, not in the tests.

After `make bindings`, find each renamed function in the diff of `src/bindings/imgui.lisp` and update both `src/gui/` and the tests:

```sh
git diff src/bindings/imgui.lisp | grep '^-(cffi:defcfun'    # removed or renamed functions
grep -rn 'get-io-nil\|selectable-bool\|tree-node-str\|get-id-str\|set-window-size-vec2' src tests examples
```

### The fixtures don't track real cimgui output

The generator tests only ever see the hand-written fixtures. If cimgui changes its JSON format, for example by renaming `ov_cimguiname`, `argsT`, or `calc_value`, the generator suite still passes, and the problem only shows up when `make bindings` runs on the real files. So after an upgrade, read the `make bindings` output and diff, not just the test results. If the real format changes, update the generator, then update the fixtures to the new format so the generator tests test it.

### Which suites go with which upgrade

| Upgrade | Suites most affected | Also check |
| --- | --- | --- |
| ImGui with cimgui | Nearly all: `bindings`, `scopes`, `widgets`, `draw`, `frame`, `examples` | Headless backend flags in `shim_headless_create`; the geometry-dependent tests below |
| ImPlot with cimplot | `plots`, `examples` | The `FloatPtr` and `doublePtr` overload names used in `src/gui/plots.lisp` |
| GLFW | `loop`, and above all `make smoke` | The manual `shutdown` check on macOS |

**Tests that depend on ImGui's default geometry.** A few tests assume ImGui's default sizes and layout behavior. A new ImGui version could change these without anything being wrong:

- `list-box-selects-clicked-item` assumes the default list box is about 7.25 lines tall, so clicking its center selects item 3.
- `redefinition-refits-windows` and `fixed-failed-panel-refits` assume how ImGui auto-sizes windows.
- `click-item-at-right-edge`, used by the slider tests, assumes the item width marks the frame's right edge.

If one of these fails after an upgrade, check whether ImGui changed a default before suspecting the code.

### Triage order

When many tests fail after an upgrade, fix them in this order, because each layer depends on the ones before it:

1. `generator`: the generator itself
2. `bindings`: the library loads and basic calls work
3. `scopes`, `widgets`, `plots`, `draw`: the `gui` layer
4. `frame`, `examples`: panels and recovery built on that layer
5. `loop`: start, stop, and shutdown
6. `make smoke`: the real window, and finally the manual check in SLIME

## Gotchas

### Some tests need the main thread

`make test` runs the tests on SBCL's main thread. Two `loop` tests rely on that and are skipped elsewhere, such as from the SLIME REPL. `start-on-main-thread-signals` checks `start`'s refusal on the main thread; when the run isn't on the main thread, it hands that call to the main thread first, so it still tests the real behavior.

### Float traps must be masked around frames

SBCL traps floating-point errors by default, and ImGui's C++ code routinely produces values like infinity and NaN. `with-headless-imgui` and `with-test-frame` mask the traps. Any new helper that calls into ImGui must do the same, or tests fail with `floating-point-invalid-operation` or similar errors from deep inside ImGui.

### Only one ImGui context at a time

The shim refuses to create a headless context while a window or another headless context exists. Don't nest `with-headless-imgui`, and don't run tests in a Lisp where `gui:start` has opened a window. `frame-loop-reports-open-failure` relies on this refusal.

### The registry is global, and test panels are real functions

`define-gui` registers a panel in the one global registry, and also defines a global function with the panel's name in `sc-imgui.tests`. Wrap every test that defines panels in `with-clean-registry` (`with-frame-env` does this in `test-frame.lisp`). Several tests reuse names like `bad`, `good`, and `p`. That's safe because each test redefines them before use, but a test must never rely on a panel function left over from another test.

### Restore what you rebind

Tests that change `gui.runtime:*report-stream*` or the loop's internal state (`*state*`, `*shown*`) must restore it in `unwind-protect`, or bind it with `let`. Otherwise later tests, or a later `gui:start` in the same Lisp, see the wrong value.

### Check for ImGui assertions

A failed ImGui assertion doesn't signal a Lisp error. It's only recorded. A test can pass while ImGui quietly complains. Headless tests should end with `(is (= 0 (%shim:assert-count)))`, and can include `(%shim:last-assert)` in the failure message. `with-headless-imgui` resets the count at the start, so the check only sees the current test's assertions.

### A rebuilt native library isn't reloaded

CFFI keeps the library it loaded first. After `make native`, restart the Lisp before running tests from the REPL. `make test` starts a fresh SBCL each time, so it's unaffected.

### New files and suites must be registered

A new test file needs `(in-package #:sc-imgui.tests)` and `(in-suite <name>)` at the top, and an entry in the `sc-imgui/tests` component list in `sc-imgui.asd`, after `headless`. A new suite also needs adding to the list in `suites.lisp`.

## Adding a test

The usual pattern for a widget or drawing test:

```lisp
(test my-widget-writes-place
  (with-headless-imgui ()
    (let ((value nil))
      ;; Prime, then click the item; returns the draw function's value per frame.
      (click-item (lambda () (in-window (gui:checkbox "label" value))))
      (is (eq t value))
      ;; ImGui recorded no misuse.
      (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert)))))
```

For panels, use `with-frame-env` from `test-frame.lisp` (or `with-clean-registry` plus `with-headless-imgui`), define panels with `gui:define-gui`, and call the local `(frame)` to draw one frame.

To add a suite:

1. Add its name to `define-suites` in `suites.lisp`.
2. Create `tests/test-<name>.lisp` starting with `(in-package #:sc-imgui.tests)` and `(in-suite <name>)`.
3. Add `(:file "test-<name>")` to `sc-imgui/tests` in `sc-imgui.asd`, after `headless`.
4. Run `make test SUITE=<name>`.

## Troubleshooting failing tests

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `Unknown suite "x"` | The suite name isn't in `suites.lisp` | Check the spelling, or add the suite. |
| Loading fails with `Native shim library ... not found` | The native library isn't built | Run `make native`. |
| `headless-create failed: a window or headless context is already open` | A nested `with-headless-imgui`, or a window open in the same Lisp | Remove the nesting, or run the tests in a fresh Lisp (`make test`). |
| A simulated click doesn't register | The window was created in the same call, and new windows can't be hovered on their first frame | Use `click-item` (which primes for two frames), or pass `:warmup` to `frames-with-click`. |
| A slider click lands in the wrong place | The item's rectangle includes its label | Use `click-item-at-right-edge`, which uses the item width. |
| A test fails with a nonzero `assert-count` | ImGui misuse in the test or the code under test | Print `(%shim:last-assert)` for the failing expression and location. |
| `floating-point-invalid-operation` from inside ImGui | A call into ImGui without masked float traps | Wrap it in `with-test-frame` or `sb-int:with-float-traps-masked`. |
| Two `loop` tests are skipped | The run isn't on the main thread, for example from the SLIME REPL | Expected. Run `make test` to include them. |
| The smoke test fails with `timed out after 30 s` | Something hung: often the loop never started, or the window never appeared | The message prints the frame counters. Zero frames means the loop never ran. |
| Many suites fail at once after an upgrade | A generated name the `gui` layer uses was renamed | See [Maintenance](#maintenance-when-upgrading-submodules), and follow the triage order. |
| Changes to `shim.cpp` don't affect REPL test runs | The old library is still loaded | Restart the Lisp, or use `make test`. |

## Coverage map

Which tests protect each key behavior. Check these before changing the related code.

| Behavior | Tests |
| --- | --- |
| ImGui misuse is recorded, not fatal | `bindings`: `assert-does-not-abort`; `native/test_assert.c` |
| The library is found, or the error lists the paths tried | `bindings`: `library-loads`, `missing-library-lists-paths` |
| Registry: define, redefine, show, hide, remove | `registry`: `define-registers`, `redefine-replaces-in-place`, `hide-show-remove` |
| `call-in-gui-thread` survives task errors | `registry`: `task-queue-survives-errors`, `unprintable-task-condition-does-not-stop-later-tasks` |
| A failing panel is isolated | `frame`: `failing-panel-is-isolated`, `unbalanced-panel-does-not-break-next-frame`, `runaway-recursion-is-isolated` |
| Errors are reported to the stream captured by `start` | `frame`: `report-goes-to-captured-stream`; smoke check 4 |
| Retry and redefinition clear a failure | `frame`: `retry-button-clears-failure`; `registry`: `redefine-clears-failure` |
| `*debug-on-error*` and its restarts | `frame`: `debug-on-error-offers-restarts`, `debug-on-error-bypasses-outer-handlers` |
| Live redefinition | smoke check 3; `frame`: `redefinition-refits-windows` |
| `start`, `stop`, `shutdown`, and the close button | `loop` suite; smoke checks 1, 5, and 6 |
| `start` refuses to run on the main thread | `loop`: `start-on-main-thread-signals` |
| Main-thread handoff is never lost | `loop`: `main-thread-handoff-survives-deferred-interrupts`; smoke check 1 |
| The layout is saved to `*ini-path*` | smoke check 5 |
| Scope macros stay balanced after errors | `scopes`: `errors-keep-scopes-balanced`, `with-font-keeps-scopes-balanced-on-error` |
| The bundled fonts are the defaults, and load in order | `loop`: `default-fonts-are-the-bundled-inter-files`, `fonts-load-in-order-and-are-usable-by-name`, `font-size-sets-the-base-size`; smoke fonts checks |
| A bad font is reported and falls back | `loop`: `bad-font-is-reported-and-falls-back-to-regular`, `bad-or-missing-regular-uses-the-built-in-font`, `bad-font-settings-are-reported-not-signalled`; `bindings`: `add-font-bad-path-fails-and-names-it`, `failed-or-nil-first-font-gives-a-working-default` |
| `with-font` selects a font and size, and restores | `scopes`: `with-font-size-applies-inside-and-restores`, `with-font-nests`, `with-font-unknown-name-lists-loaded-fonts`, `with-font-without-loaded-fonts-changes-nothing` |
| The after-window-created hook runs after the fonts and survives errors | `loop`: `after-window-created-hook-runs-after-fonts-and-survives-errors` |
| The theme is applied at window creation and switched live | `theme`: `with-a-window-each-change-queues-one-task-that-applies-it`; smoke theme checks |
| Shipped palettes reach every ImGui and ImPlot colour | `theme`: `shipped-themes-write-their-palettes`, `every-colour-is-set-by-the-mapping` |
| Rem and pixel sizes follow the font size | `theme`: `rem-sizes-scale-with-the-font-size-and-px-sizes-do-not`; smoke theme checks |
| `define-theme` validates and inherits | `theme`: `base-inheritance-and-partial-overrides`, `colors-overrides-win`, `colour-parsing`, `define-theme-rejects-bad-data-naming-it` |
| `set-theme`, `set-font-size`, `theme-color` | `theme`: `set-theme-unknown-name-lists-known-themes`, `without-a-window-set-theme-and-set-font-size-only-set-variables`, `redefining-the-current-theme-reapplies-it`, `theme-color-matches-gui-color` |
| Plot items take the theme's series colours | `plots`: `series-colours-cycle-per-item-and-restart-per-plot` |
| The shim's clear colour is harmless without a window | `bindings`: `set-clear-color-is-harmless-without-a-window` |
| The shim's font indexes and push/pop | `bindings`: `add-font-returns-indexes`, `push-font-balances-pop-font` |
| Row and grid layout | `scopes`: `with-row-places-items-on-one-line`, `with-grid-fills-columns-in-order` |
| Widgets write back to their places | `widgets` suite |
| Controls map, format and parse values | `controls`: `linear-round-trip`, `log-round-trip`, `unit-formatting`, `text-parsing`, `bare-numbers-follow-display-scale`, `spec-errors` |
| Controls share one interaction | `controls`: `drag-up-increases`, `shift-drag-is-ten-times-finer`, `double-click-resets`, `wheel-nudges`, `trackpad-wheel-fractions-step-stepped-controls` |
| Typed entry and the error outline | `controls`: `typed-entry-commits`, `bad-entry-stays-open-then-corrects`, `escape-cancels`, `enter-on-unedited-text-keeps-code-change` |
| Control state never leaks | `controls`: `state-removed-after-release`, `state-removed-when-control-vanishes-mid-drag` |
| Controls ignore input when disabled | `controls`: `disabled-ignores-input`, `toggle-disabled-ignores-click`, `xy-disabled-ignores-input` |
| Controls line up and scale with the font | `controls`: `knob-row-aligns-at-two-sizes`, `fader-sizes-follow-thickness-and-length`, `toggle-sizes`, `xy-size-and-one-item` |
| Themes define the `:error` role | `theme`: `shipped-themes-define-error`, `theme-without-base-needs-error` |
| Plots take Lisp vectors without copying | `plots`: `specialized-vectors-are-not-copied` |
| Drawing primitives and interaction | `draw` suite |
| The examples keep working | `examples` suite |

The five risks singled out in the original implementation plan ("Review Focus"):

| Risk | Test |
| --- | --- |
| 1. ImGui misuse aborts SBCL | `bindings`: `assert-does-not-abort` |
| 2. Error reports go to the wrong stream (the `*inferior-lisp*` buffer instead of the REPL) | `frame`: `report-goes-to-captured-stream`; smoke check 4 |
| 3. A widget given `nil` crashes in foreign code | `widgets`: `slider-nil-place-signals-type-error` |
| 4. `with-id` IDs change when the garbage collector moves an object | `scopes`: `with-id-stable-across-gc` |
| 5. A plot given a list or general vector fails | `plots`: `plot-coerces-general-sequences` |

## Known gaps

What isn't tested, and why:

- **Rendered pixels.** No test checks what's actually drawn on screen. That's a deliberate choice: comparing images is high effort for a personal tool. The draw tests check only that vertices were added.
- **Windows.** The code should work there, but neither CI nor the tests run on Windows.
- **Live reporting of ImGui assertions.** The frame loop doesn't report recorded assertions during a live session (see `native/README.md`), so there's nothing to test yet. If that's added, it should get a `frame` test.
- **Some exported functions have no direct test:** the `drag` macro (only `drag-value` is used), `with-section`, the layout functions (`same-line`, `new-line`, `separator`, `spacing`, `indent`, `unindent`, `set-next-item-width`), and the interaction helpers `item-hovered-p`, `mouse-pos`, `content-region-avail`, `set-cursor-screen-pos`, and `reset-mouse-drag-delta`. Some of these run indirectly when the examples are loaded, but nothing checks what they do. `with-style` and `with-disabled` are tested only for staying balanced, not for their effect. `with-font` is tested for the font and size it selects, but not for how the glyphs look.
- **Docking.** Docking is enabled, but no test docks a window.
- **`with-section`'s collapsed state** and other behavior that needs a click on a header.
