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

- **`make test`** runs 95 [FiveAM](https://github.com/lispci/fiveam) tests in ten suites. They run **headless**: ImGui runs with no window and no GPU, and each test draws frames itself by calling `NewFrame` and `Render`. They're fast, need no display, and run anywhere, including CI.
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
                           # scopes, widgets, plots, draw, examples
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

Defines the suite `all` and the ten suites inside it, plus `run-suites`, which runs a suite by name and returns true only when every check passed. **A new suite must be added to the list here**, or `make test SUITE=<name>` reports "Unknown suite".

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
| `click-item` | Draws twice so the item has a rectangle, then clicks its center | The two priming frames cover the hidden-first-frame rule. |
| `click-item-at-right-edge` | Clicks 2 pixels inside the right edge of the item's *frame* | An item's rectangle includes its label, so the frame's right edge is calculated from the item width, not the rectangle. |
| `frames-with-drag`, `prime-and-drag` | Press, move by (dx, dy) while held, release | Used for drag interactions, such as the knob in the examples. |
| `type-text` | Queues typed characters and runs two frames | Text input needs a frame to receive the characters and one to apply them. |
| `with-clean-registry` | Empties the panel registry and task queue before and after the body | The registry is global, so without this, panels from one test would leak into the next. |
| `vtx-count` | Number of vertices in a draw list | Reads ImGui's own structs directly (`im-draw-list`, `im-vector-im-draw-vert`) to show that drawing functions added something. |

### `fixtures/`

Hand-written miniature versions of cimgui's three JSON files: `definitions.json`, `structs_and_enums.json`, and `typedefs_dict.json`. They hold only the entries the generator tests need. Examples are `igButton` (a `bool` return plus an `ImVec2` by value), `igText` (variadic, so it must be skipped), and a struct with a bitfield, which must come out opaque. **They aren't copies of real cimgui output** and don't change when cimgui does. See [Maintenance](#maintenance-when-upgrading-submodules).

### The test system in `sc-imgui.asd`

`sc-imgui/tests` lists the test files with `:serial t`, so they load in the order listed. `headless.lisp` must come before any file that uses its helpers. **A new test file must be added to this list**, or it's never loaded.

## Suite by suite

### `test-generator.lisp` (suite `generator`, 10 tests)

Tests the binding generator against the fixtures, without loading ImGui:

- **Naming:** C names to Lisp names, such as `igSliderFloat2` → `slider-float2`, `igGetIO` → `get-io`, and `ImPlot_PlotLine_FloatPtrInt` → `plot-line-float-ptr-int`.
- **Type mapping:** C types to CFFI types, including typedefs resolving through `typedefs_dict.json`, and unknown types returning `nil`.
- **Emitted forms:** variadic functions are skipped, enums become constants, and a struct with an unmappable field becomes opaque and warns.
- **`bool` handling:** every C `bool` argument or return becomes `:uint8` in a `NAME-RAW` function, with a `NAME` wrapper converting to and from `t`/`nil`. This works around how C `bool` behaves through cffi-libffi.
- **`const char*` arguments** accept `nil`, which is passed as NULL.
- **By-value structs:** a struct is emitted after the structs it contains, and ImPlot reuses ImGui's `ImVec2` from `%imgui` rather than defining its own.
- **Exports and prefixes:** the right names are exported, and ImPlot's output contains only ImPlot's structs and enums.

### `test-bindings.lisp` (suite `bindings`, 17 tests)

Tests the loaded native library and the generated bindings, through real calls:

- The library loads, and a missing library signals `shim-library-not-found` listing the paths tried.
- Headless frames run, and **ImGui misuse is recorded instead of aborting** (`assert-does-not-abort`).
- `ImGuiIO` isn't opaque: `display-size` reads back as 800.
- Structs returned by value work, and simulated clicks land (`frames-with-click-clicks-a-button`) or miss (`mouse-over-nothing-does-not-click`).
- The window-related shim functions are harmless when there's no window.
- `nil` and string arguments, and `t`/`nil` booleans, reach C correctly on both CFFI call paths: plain calls, and cffi-libffi calls used when a struct is passed by value.

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

### `test-loop.lisp` (suite `loop`, 10 tests)

`start`, `stop`, and `shutdown` without opening a window. A real window is the smoke test's job.

- `stop` and `shutdown` return `nil` with no loop, and the GUI isn't running by default.
- **State transitions are tested by setting the loop's state by hand:** `stop` hides a showing window, `start` shows a hidden one, and `shutdown` ends a hidden or showing loop.
- `start` called on the main thread signals `main-thread-busy`, with instructions for SLIME.
- A failure to open the window is reported, and doesn't destroy the headless context.
- A panel calling `start` while the loop runs gets `nil`. *Main thread only; skipped otherwise.*
- **Regression:** a handoff to the main thread survives the main thread deferring interrupts for a second. That's the case where the earlier `trivial-main-thread` version lost the request. *Main thread only; skipped otherwise.*

### `test-scopes.lisp` (suite `scopes`, 8 tests)

The scope and layout macros, headless:

- **Errors keep scopes balanced** for every scope macro: an error inside `with-window`, `with-group`, `with-child`, `with-id`, `with-disabled`, `with-style`, or `with-grid` leaves no ImGui assertion.
- `with-row` puts items on one line, and `with-grid` fills columns in order.
- **`with-id` gives the same ID before and after a full garbage collection,** because Lisp objects can move in memory and their addresses are never used as IDs.
- `enum-flags` resolves keywords and rejects unknown ones.
- The macros don't capture a user variable named `open`.
- `with-grid`'s default ID tells apart bodies that differ deep inside, and stays the same for identical bodies.

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

### `test-plots.lisp` (suite `plots`, 6 tests)

- Specialized `single-float` and `double-float` vectors are passed without copying; lists and general vectors are converted to `single-float` vectors.
- Non-numbers, and `xs` and `ys` of different lengths, signal errors naming the plot label.
- Every plot kind draws cleanly, including empty data and mixed float types.
- The plot body runs, and `EndPlot` balances.

### `test-draw.lisp` (suite `draw`, 5 tests)

- `gui:color` packs colors exactly as ImGui does, including out-of-range components, which are clamped.
- Every drawing primitive adds vertices to the draw list.
- `draw-polyline` draws nothing for a single point, and rejects an odd number of coordinates.
- An invisible button reports clicks, and a drag reports its distance while the button is held.

### `test-examples.lisp` (suite `examples`, 2 tests)

Loads each file in `examples/` headlessly and draws three frames:

- `hello`, `layout`, `plots`, and `custom-knob` register panels, none fails, and no ImGui assertion is recorded.
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
| Scope macros stay balanced after errors | `scopes`: `errors-keep-scopes-balanced` |
| Row and grid layout | `scopes`: `with-row-places-items-on-one-line`, `with-grid-fills-columns-in-order` |
| Widgets write back to their places | `widgets` suite |
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
- **Some exported functions have no direct test:** the `drag` macro (only `drag-value` is used), `with-section`, the layout functions (`same-line`, `new-line`, `separator`, `spacing`, `indent`, `unindent`, `set-next-item-width`), and the interaction helpers `item-hovered-p`, `mouse-pos`, `content-region-avail`, `set-cursor-screen-pos`, and `reset-mouse-drag-delta`. Some of these run indirectly when the examples are loaded, but nothing checks what they do. `with-style` and `with-disabled` are tested only for staying balanced, not for their effect.
- **Docking.** Docking is enabled, but no test docks a window.
- **`with-section`'s collapsed state** and other behavior that needs a click on a header.
