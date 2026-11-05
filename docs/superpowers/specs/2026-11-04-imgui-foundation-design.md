# Design Spec: Immediate-Mode GUI Foundation for cl-collider

Nov 4, 2026 · @Cian

## Purpose and context

This spec covers part 1, the foundation: Common Lisp bindings to Dear ImGui and ImPlot, plus a live frame loop that lets you build GUIs from the REPL. The toolkit is for personal use in cl-collider live coding, not a general-purpose library.

**Confirmed requirements**

- SBCL, driven from Emacs with SLIME or Sly.
- macOS is the primary platform. Linux and Windows should work, since nothing in the design is Mac-specific.
- GUIs can be defined and redefined from the REPL while the window stays open.
- Authoring style is hybrid: a raw immediate-mode layer first, then a declarative `defpanel` layer on top (part 5).
- Controls follow value changes made from code, such as REPL forms and patterns, not only the reverse (part 2). MIDI is handled separately, outside this toolkit; it only needs to update values through code.
- Must-have controls for the first usable version: knobs, sliders, toggles, buttons, XY pads, level meters, scopes and spectra, an envelope editor, and a step sequencer grid (parts 3 and 4).
- Panels are mostly fixed arrangements. Flexbox-style reflowing layout is wanted later, not now.
- Multiple OS windows are wanted later, not in v1.

**Assumptions**

- Controls should look good, but they don't need to be pixel-perfect skeuomorphic.
- Plots show live, updating data, not publication-quality figures.

**Success criteria for the foundation**

- From a SLIME or Sly REPL on macOS, `(gui:start)` opens a window and returns control to the REPL immediately.
- Re-evaluating a `define-gui` form changes the window on the next frame.
- An error in one panel never stops the window or other panels, and the panel recovers once you fix the form and re-evaluate it.
- The foundation has no dependency on cl-collider, so it can be tested without scsynth running.

## Scope and decomposition

The toolkit is five parts, each designed and built in turn. Each part gets its own spec, plan, and implementation. This spec covers part 1 only.

1. **Foundation (this spec):** cimgui and cimplot bindings, a GLFW and OpenGL 3 backend, a main-thread frame loop, live redefinition, and the Lisp API layer.
2. **Parameter store:** named values with ranges and scaling. The GUI, REPL code, and patterns all write to it, and it forwards changes to synths through `ctrl`. The GUI reads it every frame, so controls follow changes automatically. Any external source, such as separately handled MIDI, writes to it through the same code API.
3. **Audio widgets:** knobs, XY pads, an envelope editor, and a step sequencer grid, built from the foundation's draw-list primitives.
4. **Live audio display:** level meters from `SendPeakRMS` or `SendReply` over OSC. Scopes and spectra via polling a server buffer or reading scsynth's shared-memory scope interface. That choice is made in part 4's spec.
5. **`defpanel`:** the declarative layer. It registers panels through the same registry as `define-gui` and can drop into raw draw code.

The first usable version needs parts 1 through 4. Part 5 builds on the API layer and parameter store and needs no changes to the foundation.

## Architecture

The foundation is four layers, and your code talks only to the top one. The API layer and runtime call ImGui through the raw bindings, and only the native shim touches the windowing system and GPU.

&#91;embedded content: foundation layers · 4 layers under your code\]

**Native shim.** A CMake project builds one shared library from pinned git submodules: Dear ImGui on its docking branch, cimgui, ImPlot, cimplot, and GLFW. It uses ImGui's stock GLFW and OpenGL 3 backend files and adds five functions of its own. The same CMake file builds a `.dylib` on macOS, a `.so` on Linux, and a `.dll` on Windows.

**Docking branch.** It's pinned from the start, with viewports disabled in v1. Adding multiple OS windows later then needs only a config flag and two extra calls in the shim's end-frame function.

**Raw bindings.** A small Lisp generator reads cimgui's and cimplot's JSON definition files and writes plain CFFI forms for everything. This avoids c2ffi or claw, and upgrading ImGui means regenerating. Only the API and runtime layers use these packages.

**One OS window in v1.** It can hold any number of ImGui windows, which you can drag around and dock inside it.

## Frame loop and threading

The frame loop runs on SBCL's main thread, and the REPL stays free on its Swank thread.

**Starting and stopping**

- `(gui:start)` returns immediately. The first time, it uses `trivial-main-thread` to run the loop on the main thread, which SLIME and Sly leave free. Calling `start` while the window is showing does nothing and returns `NIL`.
- `(gui:stop)` saves the layout, hides the window and stops drawing panels. The loop keeps running: it waits for events (near-zero CPU) and still runs tasks queued with `call-in-gui-thread`. `start` shows the window again.
- Closing the window behaves the same as `(gui:stop)`.
- `(gui:shutdown)` hides the window, keeps processing events until it has left the screen, then destroys it, ends the loop and releases the main thread. `start` after a shutdown creates a new window and loop.
- So the main thread stays with the GUI from the first `start` until `shutdown`. It is never left idle with a window open, because on macOS the window server only removes a hidden or destroyed window while the main run loop runs. That is why the shim needs no Objective-C code.
- `start`, `stop`, `shutdown` and `call-in-gui-thread` wake a waiting loop with `glfwPostEmptyEvent`.
- On Linux and Windows the same code runs; the main thread isn't strictly required there.

**Each frame**

1. Run tasks queued with `call-in-gui-thread`.
2. Begin the frame: poll input and start a new ImGui frame.
3. Call the draw function of each visible registered GUI.
4. End the frame: render and swap buffers.

The whole frame runs inside `sb-int:with-float-traps-masked`, so GL drivers and Cocoa can't trip SBCL's floating-point traps.

**Pacing.** The loop redraws continuously, synced to the display refresh (`glfwSwapInterval 1`, typically 60 fps). It doesn't wait for input, because scopes and meters change on their own. Only while the window is hidden does the loop wait for events instead of drawing.

**Registry.** The registry is the loop's list of what to draw, keyed by name.

- `define-gui` expands into a function definition plus a registry entry. Redefining replaces the existing entry and never duplicates it.
- The loop looks up each function by name every frame, so a redefinition takes effect on the next frame.
- `gui:hide` and `gui:show` stop and resume drawing a panel without deleting it. `gui:remove` deletes the entry.
- The registry lives in Lisp, so panels survive `stop`, `shutdown` and `start`.
- Registering, hiding, showing, and removing are safe from any thread. The registry is protected by a lock, and the loop iterates over a snapshot.
- Part 5's `defpanel` registers through this same mechanism.

**Crossing threads.** `(gui:call-in-gui-thread thunk)` queues a function to run at step 1 of the next frame. It's for operations that must happen between frames on the main thread, such as loading fonts or changing the global style. Sharing data that other threads write is part 2's concern.

scsynth is a separate process, so a slow or broken draw function makes only the GUI stutter. Audio keeps playing.

## Lisp API layer

Widgets read from and write to any `setf`-able place and return true when the value changed.

```lisp
(slider "Cutoff" *cutoff* :min 20 :max 20000 :scale :log)
(slider "Gain" (gethash :gain *mix*) :min 0 :max 1)
(checkbox "Mute" (slot-value track 'muted))
(when (button "Reset") (setf *cutoff* 1000))
```

**Place-based widgets.** Each widget macro copies the place's value into reused foreign scratch memory, calls ImGui, and writes the result back to the place if it changed. Drawing happens on one thread, so the scratch memory is shared safely.

**Functional variants.** Each widget also has a function form that takes the current value and returns two values: the new value and whether it changed. It writes nothing. Part 2's parameter store uses these.

**Scope macros.** `with-window`, `with-row`, `with-group`, `with-grid`, `with-section`, `with-child`, `with-id`, `with-disabled`, and `with-style` each wrap an ImGui begin/end or push/pop pair in `unwind-protect`. The closing call always runs, even after an error, and ImGui's quirks are handled inside the macro. For example, `End` is called even when a window is collapsed.

**IDs.** ImGui identifies widgets by label within a window. `with-id` pushes an ID scope so loops can repeat labels:

```lisp
(dolist (s *voices*)
  (with-id (s)
    (knob "Cutoff" (cutoff-of s) ...)))
```

**Plots.** ImPlot wrappers accept specialized Lisp vectors of type `(simple-array single-float (*))` or `(simple-array double-float (*))`. The vector is pinned with CFFI's `with-pointer-to-vector-data` and passed by pointer, so data isn't copied each frame.

**Draw-list primitives.** Lines, arcs, circles, rectangles, filled shapes, and text are exposed through ImGui's draw-list API, along with invisible buttons for mouse interaction. Part 3's audio widgets are built from these.

**Strings.** Labels are converted to UTF-8 foreign strings per call. Caching can be added later if profiling shows a need.

**v1 coverage**

| Area | Wrapped in v1 |
| --- | --- |
| Windows and layout | `with-window` and the layout macros in the next section |
| Basic widgets | text, buttons, checkboxes, combo boxes, text input |
| Numeric widgets | sliders and drag fields; float and integer; linear or log scale |
| Plots (ImPlot) | line, bar, and scatter plots |
| Custom drawing | draw-list primitives and invisible buttons |

Everything else is reachable through the raw `%imgui` and `%implot` packages until it's worth wrapping.

## Layout

v1 uses ImGui's own cursor-based layout, wrapped in nesting macros. That suits fixed panels, which is the expected use.

**Between windows.** You arrange ImGui windows by dragging and resizing them inside the OS window. With the docking branch, you can also dock them into tabs and splits. ImGui saves the arrangement to an `.ini` file. `gui:*ini-path*` sets where that file lives, so each project can keep its own layout.

**Inside a window**

| Macro | Wraps | Use |
| --- | --- | --- |
| `with-row` | `SameLine` between children | widgets side by side |
| `with-group` | `BeginGroup` / `EndGroup` | treat several widgets as one block, e.g. a column inside a row |
| `with-grid` | `BeginTable` / `EndTable` | a grid with fixed or stretching columns |
| `with-section` | `CollapsingHeader` | a foldable section |
| `with-child` | `BeginChild` / `EndChild` | a scrolling or bordered sub-area |

Item width, indent, spacing, and separators are wrapped as plain functions.

```lisp
(define-gui saw-panel ()
  (with-window ("Saw")
    (with-row ()
      (slider "Cutoff" *cutoff* :min 20 :max 20000 :scale :log)
      (slider "Res" *res* :min 0 :max 1))
    (with-section ("Envelope")
      (with-grid (:columns 4)
        (slider "A" *a*) (slider "D" *d*)
        (slider "S" *s*) (slider "R" *r*)))))
```

**Known limitations.** Widgets don't wrap onto a new line when a window narrows. Leftover space isn't distributed except by table columns. Centering and right-aligning require computing positions from the available width.

**Future work.** A flexbox-style layout macro can be added beside these later. Clay is a candidate to compute the rectangles, with ImGui still drawing and handling input inside them. The v1 macros don't need to change to allow this.

## Error handling

An error in one panel disables only that panel, and re-evaluating its `define-gui` brings it back.

**When a panel's draw function signals an error**

1. The scope macros' `unwind-protect` closes any open ImGui scopes, keeping ImGui's stack balanced. ImGui's built-in error recovery is a backstop if anything is still unbalanced at the end of the frame.
2. The panel's registry entry is marked failed, storing the condition. Failed panels are skipped. Other panels keep drawing.
3. In its place, a small window titled with the panel name shows the error message and a **Retry** button. Retry clears the failed mark.
4. The error and a backtrace are printed to the REPL's output stream.
5. Re-evaluating the panel's `define-gui` clears the failed mark automatically.

**Debugger option.** By default the SLIME or Sly debugger is not entered, because it would run on the main thread and freeze the window. When `gui:*debug-on-error*` is true, the error enters the debugger with two extra restarts: `retry-panel` and `disable-panel`.

**Other failures**

| Failure | Behavior |
| --- | --- |
| A task queued with `call-in-gui-thread` signals an error | reported to the REPL output; the loop continues |
| The window can't be created, or the loop itself fails | the loop shuts down cleanly, reports the cause, and `start` can be called again |
| The native library can't be found | loading the system signals an error listing the paths searched |

## Testing

Most tests run headless, so they need no window or display and run in CI.

| Level | What it checks | Where it runs |
| --- | --- | --- |
| Binding generator | Given small cimgui JSON fixtures, the generator emits the expected CFFI forms | anywhere |
| Headless ImGui | Widgets write back to their places, using simulated mouse input. Scope macros stay balanced when the body signals an error. Registry define, redefine, show, hide, and remove. Failed-panel marking and recovery. | anywhere, including CI; ImGui runs with a context and display size but no backend |
| Backend smoke test | Open a window, run several hundred frames, hide it, show it again, close it, shut it down, start a new one | locally on macOS; on Linux CI under a virtual display (Xvfb) |

**Platforms.** macOS is primary and tested locally. Linux is tested in CI. Windows is expected to work but isn't tested in v1.

**Not tested.** Rendered pixels aren't compared. That's high effort for little value in a personal tool.

## Out of scope and future work

These are deliberately left out of the foundation. Each one has a home later.

| Item | Where it goes |
| --- | --- |
| Knobs, XY pads, envelope editor, step sequencer grid | part 3 |
| Parameter store and sync with synths | part 2 |
| Level meters, scopes, spectra, getting audio data from scsynth | part 4 |
| `defpanel` declarative layer | part 5 |
| MIDI input | outside this toolkit; it updates values through code like any other caller |
| Multiple OS windows (ImGui viewports) | later: set the viewports flag and add the platform-window calls to the shim's end-frame function; no Lisp API change |
| Flexbox-style layout macro | later; Clay is a candidate as a layout calculator |
| Metal backend on macOS | only if OpenGL becomes a problem; changes the shim only |
| Label string caching | only if profiling shows a need |
| Windows testing | later |
