# sc-imgui

Common Lisp (SBCL) binding to Dear ImGui and ImPlot.

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
  (when (%imgui:begin "Hello" (cffi:null-pointer) 0)
    (when (%imgui:button "Click" '(%imgui::x 0.0 %imgui::y 0.0))
      (print :clicked gui.runtime:*report-stream*)))
  (%imgui:end))
```

Re-evaluate a `define-gui` form (C-c C-c) and the window picks up the new
definition on the next frame. Each window the panel opens with `gui:with-window`
then refits its size to its new contents once, so added widgets are not cut
off. After that you can resize it by hand as usual, and the size is saved as
usual. Windows of other panels, and windows opened with a bare `%imgui:begin`
as above, keep their size. `(gui:stop)` closes the window, as does the
window's close button; `(gui:start)` opens it again with the same panels.

The frame loop runs on SBCL's main thread (macOS requires it for Cocoa), handed
over with `trivial-main-thread`, so `start` returns immediately and the REPL
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

- `(gui:start &key width height title)` returns `NIL` if already running;
  signals `gui:main-thread-busy` on the main thread.
- `(gui:stop &key (wait t))` returns `T` if the loop was running; with `wait` it
  waits up to 5 s for the window to close (never when called from the main
  thread, e.g. from a panel).
- `(gui:running-p)`.
- `gui:*ini-path*` (default `"sc-imgui.ini"`, merged with
  `*default-pathname-defaults*` at `start`; `NIL` disables) is where ImGui saves
  window layout.
- Errors are reported to the `*standard-output*` of the thread that called
  `start` (the REPL), never to the main thread's own output.

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
