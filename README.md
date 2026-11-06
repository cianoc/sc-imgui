# sc-imgui

Common Lisp binding to Dear ImGui and ImPlot, intended for cl-collider. Currently this only works on SBCL. 

Mostly vibe coded using Claude as an experiment.

## Native shim

`make native` builds `native/build/libsc_imgui_shim.{dylib,so}` (ImGui, ImPlot,
cimgui, cimplot, GLFW and the shim in one shared library) and runs the C tests.

```
git submodule update --init native/third_party/{imgui,cimgui,implot,cimplot,glfw}
make native
```

Do not initialise the nested submodules inside `cimgui/` or `cimplot/`: only the
top-level `native/third_party/imgui` and `native/third_party/implot` are compiled
(`cimgui.cpp` and `cimplot.cpp` find them through an include directory).

### Pinned submodules

| Submodule | Commit | Commit date | Notes |
|-----------|--------|-------------|-------|
| imgui | `d88f238d1d363ef387382b2e29ad12cf96f826ac` | 2026-10-15 | docking branch; the ImGui commit cimgui `5d7cc7e` was generated from |
| cimgui | `5d7cc7e12de9a868bbecc00ce2ed74e58d266f1c` | 2026-10-16 | `docking_inter`, "pull imgui docking 1.93 and generate" |
| implot | `72de27832d1e6299bcc930ce01073d899d420392` | 2026-10-25 | the ImPlot commit cimplot `c809ff2` points at |
| cimplot | `c809ff29c84813fe1cdc8a0c069145ef2285f22a` | 2026-10-26 | "pull v1.1 and generate" |
| glfw | `7b6aead9fb88b3623e3b3725ebb42670cbe4c579` | 2024-02-23 | tag 3.4 |

cimgui's `docking_inter` HEAD (`2a6a93f`, 2026-10-18) is not used: its generated
output was produced from non-docking ImGui (no `ImGuiConfigFlags_DockingEnable`,
no dock API), as its own commit message half-admits. `5d7cc7e` is the newest
commit whose output contains the docking API.

## Running from SLIME or Sly

```lisp
(ql:quickload :sc-imgui)
(gui:start)                     ; opens the window, returns T at once

(gui:define-gui hello ()
  (gui:with-window ("Hello")
    (gui:text "Hello from Lisp")
    (when (gui:button "Click")
      (print :clicked gui.runtime:*report-stream*))))
```

Re-evaluate a `define-gui` form (C-c C-c) and the window picks up the new
definition on the next frame. Each window the panel opens with `gui:with-window`
then refits its size to its new contents once, so added widgets are not cut
off. After that you can resize it by hand as usual, and the size is saved as
usual. Windows of other panels, and windows opened with a bare `%imgui:begin`
as above, keep their size. `(gui:stop)` hides the window, as does the
window's close button; `(gui:start)` shows it again with the same panels.
`(gui:shutdown)` destroys the window and ends the loop.

The frame loop runs on SBCL's main thread (macOS requires it for Cocoa), handed
over by interrupting it (`sb-thread:interrupt-thread`), so `start` returns immediately and the REPL
stays free. That only works when the REPL evaluates in some *other* thread.
`start` called on the main thread signals `gui:main-thread-busy` and changes
nothing, because running the loop there would freeze the REPL until the window
closed.

### SLIME: give the REPL its own thread

Recent SLIME runs the REPL (and `C-x C-e`) on SBCL's main thread. Add this to
`~/.swank.lisp` and restart SLIME (`M-x slime-restart-inferior-lisp`):

```lisp
(setf swank::*main-thread-used* t)
```

Swank then gives the REPL its own thread and leaves the main thread idle for
the frame loop. To check, evaluate this in the REPL; it should return `NIL`:

```lisp
(eq sb-thread:*current-thread* (sb-thread:main-thread))
```

A plain `sbcl` terminal REPL also evaluates on the main thread. Scripts should
call `start` from another thread and leave the main thread idle, as
`tests/smoke.lisp` does.

Once started, the loop keeps the main thread until `(gui:shutdown)`. While
the window is hidden the loop waits for events (near-zero CPU) and still runs
`call-in-gui-thread` tasks. Never leaving the main thread idle is what lets a
hidden or destroyed window actually leave the screen on macOS.

- `(gui:start &key width height title)` shows the window: it creates the window
  and loop the first time (and after `shutdown`), or shows the hidden window
  again. Returns `NIL` if already showing. `width` and `height` apply only when
  the window is created; `title` applies each time it is shown. Creating the
  loop from the main thread signals `gui:main-thread-busy`.
- `(gui:stop &key (wait t))` saves the layout to `*ini-path*`, hides the window
  and stops drawing panels; the loop keeps running. The window's close button
  does the same. Returns `T` if the window was showing; with `wait` it waits up
  to 5 s for the window to hide (never when called from the main thread, e.g.
  from a panel).
- `(gui:shutdown &key (wait t))` hides and destroys the window, ends the loop
  and releases the main thread. Returns `T` if there was a loop; with `wait` it
  waits up to 5 s for the loop to end.
- `(gui:running-p)` is true while the window is showing and panels are drawn.
- `gui:*ini-path*` (default `"sc-imgui.ini"`, merged with
  `*default-pathname-defaults*` at `start`; `NIL` disables) is where ImGui saves
  window layout.
- Errors are reported to the `*standard-output*` of the thread that called
  `start` (the REPL), never to the main thread's own output.
- `gui:*fonts*` (a plist of font name to file) and `gui:*font-size*` (default
  15) choose the fonts, loaded when the window is created: change them, then
  `(gui:shutdown)` and `(gui:start)`. `stop` and `start` do not reload fonts.
- `gui:*theme*` (default `:mid-light`; the other shipped theme is `:dark`) is the
  look applied when the window is created. `(gui:set-theme :dark)` switches it
  live, and `(gui:set-font-size 13)` changes the density live.

## Fonts

The default font is Inter 4.1 (released 2024-11-16,
<https://github.com/rsms/inter/releases/tag/v4.1>, asset `Inter-4.1.zip`). The
files `Inter-Regular.ttf` and `Inter-SemiBold.ttf` are the static TTFs from
`extras/ttf/` in that release, kept in `assets/fonts/`. Inter is licensed under
the SIL Open Font License 1.1, and the licence text is in `assets/fonts/OFL.txt`.
It must stay with the font files.

`gui:*fonts*` defaults to `(:regular Inter-Regular :semibold Inter-SemiBold)`.
`:regular` is the default font for all text; use another with
`(gui:with-font (:semibold) ...)` or `(gui:with-font (:regular :size 28) ...)`.
Without a `:regular` font, ImGui's built-in font is used.

## API summary

Each item is demonstrated in [examples/](examples/README.md).

- `gui:define-gui`: define or redefine a panel; `gui:show`, `gui:hide`, `gui:remove` control it by name.
- `gui:call-in-gui-thread`: queue a function to run on the GUI thread before the next frame.
- `gui:*debug-on-error*`: when true, panel errors enter the debugger with `retry-panel` and `disable-panel` restarts instead of showing a failed window.
- `gui:*fonts*`, `gui:*font-size*`: the fonts loaded at window creation (bundled Inter by default).
- Scope and layout macros: `with-window`, `with-child`, `with-row`, `with-grid`, `with-section` (see `examples/layout.lisp`); `with-font` picks a loaded font and size for its body.
- Widgets: `text`, `button`, `checkbox`, `slider`, `input-text`, `combo`, `selectable`, `list-box`, ... each on a place, with functional `-value` variants (e.g. `slider-value`, `checkbox-value`) that take and return values.
- Plots: `plot-lines`, `plot-bars`, `plot-scatter` from Lisp vectors (`examples/plots.lisp`).
- Draw primitives and interaction helpers: `draw-circle`, `draw-arc`, `invisible-button`, `mouse-drag-delta` (`examples/custom-knob.lisp`).

Notes:

- Docked windows do not refit after a panel is redefined.
- A window that is not opened on the frame right after a redefinition misses that one-time refit.

## Linux

Build packages (as in `.github/workflows/ci.yml`):

```
sudo apt-get install -y --no-install-recommends \
  sbcl build-essential cmake pkg-config curl ca-certificates \
  xvfb xauth libgl1-mesa-dri libgl1-mesa-dev \
  libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
  libwayland-dev libxkbcommon-dev libffi-dev
```

On Linux the shim requests an OpenGL 3.0 context, and ImGui's OpenGL3 backend
enables large meshes (more than 64k vertices per draw list) only when the
driver reports GL 3.2 or later. That is fine on Mesa, but very large plots may
hit the 16-bit index limit on older drivers.

## Examples

See [examples/README.md](examples/README.md) for runnable examples.

## Tests

```
make test              # all FiveAM suites (headless, no window)
make test SUITE=loop   # one suite
make smoke             # opens a real window for a few seconds
```

On Linux without a display, run the smoke test under Xvfb:
`xvfb-run -s "-screen 0 1280x1024x24" make smoke`.
