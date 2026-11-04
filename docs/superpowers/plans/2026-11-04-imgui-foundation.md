# Immediate-Mode GUI Foundation Implementation Plan

Nov 4, 2026 · @Cian

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build part 1 of the cl-collider GUI toolkit: Dear ImGui and ImPlot bindings for SBCL with a main-thread frame loop, live `define-gui` redefinition, and a place-based Lisp API.

**Architecture:** A C++ shim library bundles cimgui, cimplot, and ImGui's stock GLFW/OpenGL 3 backend behind a few C functions. A Lisp generator turns cimgui's and cimplot's JSON definitions into CFFI forms. A runtime package owns the registry and frame loop, and the `gui` package is the API you write against.

**Tech Stack:** SBCL, ASDF, Quicklisp; CFFI with cffi-libffi; trivial-main-thread; bordeaux-threads (`bt2`); alexandria; com.inuoe.jzon (generator only); FiveAM; CMake; Dear ImGui (docking branch), cimgui, ImPlot, cimplot, GLFW.

**Spec:** Design Spec: Immediate-Mode GUI Foundation for cl-collider (export as `docs/superpowers/specs/2026-11-04-imgui-foundation-design.md`). Executors read the spec alongside this plan.

**Project name:** repository `sc-imgui`, ASDF system `sc-imgui`. Packages follow the spec: `%imgui`, `%implot`, `%shim`, `gui.runtime`, `gui`.

## Global Constraints

- Lisp implementation: SBCL only. Driven from Emacs with SLIME or Sly.
- Platforms: macOS primary (tested locally); Linux tested in CI; Windows expected to work, not tested in v1. Nothing may be macOS-specific outside the shim's CMake platform branches.
- Dear ImGui: docking branch, pinned to an exact commit as a git submodule. Viewports disabled in v1 (`ImGuiConfigFlags_ViewportsEnable` never set).
- cimgui: the branch whose generated output matches ImGui's docking branch (`docking_inter`), pinned to the commit generated from the pinned ImGui. cimplot and ImPlot pinned to commits compatible with those. Record every pin in `.gitmodules` and in the README with its date.
- One OS window in v1.
- Frame loop on SBCL's main thread via `trivial-main-thread`. `gui:start` returns immediately.
- Continuous redraw, `glfwSwapInterval(1)`.
- Every frame, and every headless test frame, runs inside `(sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact) ...)`.
- ImGui `IM_ASSERT` must never abort the process. The shim overrides it to record the failure (Task 1).
- Struct-by-value foreign calls (`ImVec2`, `ImVec4`) go through cffi-libffi. Load `cffi-libffi` in the bindings system.
- The foundation (`sc-imgui`) must not depend on cl-collider.
- Error reports go to `gui.runtime:*report-stream*`, captured from `*standard-output*` when `start` is called. Never write reports to the main thread's own `*standard-output*`.
- Rendered pixels are never compared in tests.
- Test framework: FiveAM. Test entry point: `make test`, or `make test SUITE=<name>` for one suite.

## Review Focus

These five failure modes aren't spelled out in the spec but are the most likely to bite in daily use. Each has a pinning test in the owning task.

| # | Input or condition | Expected behavior | Pinned in |
| --- | --- | --- | --- |
| 1 | An ImGui misuse fires `IM_ASSERT` in C, e.g. `End` without `Begin` | SBCL keeps running; the failure is recorded and readable from Lisp | Task 1 (C test), Task 3 `assert-does-not-abort` |
| 2 | Draw code errors while the loop runs on the main thread, whose `*standard-output*` is the `*inferior-lisp*` buffer, not the SLIME REPL | The report appears in the REPL, via `*report-stream*` captured at `start` | Task 5 `report-goes-to-captured-stream` |
| 3 | A widget's place holds `nil` or a non-number, typically a `defvar` with no value | A `type-error` naming the widget label, handled as a panel failure, not a crash in foreign code | Task 8 `slider-nil-place-signals-type-error` |
| 4 | `with-id` given a Lisp object such as a cons or struct, which the GC can move | The same object yields the same ImGui ID before and after a full GC | Task 7 `with-id-stable-across-gc` |
| 5 | A plot given a general vector or list, e.g. `(vector 1 2 3)` or `'(1 2 3)` | It plots, coerced to a `single-float` vector; only specialized float vectors avoid the copy | Task 9 `plot-coerces-general-sequences` |

## File Structure

```
sc-imgui/
  sc-imgui.asd            systems: sc-imgui, sc-imgui/bindings,
                            sc-imgui/generator, sc-imgui/tests
  Makefile                  targets: native, bindings, test, smoke
  README.md                 build steps, submodule pins, running from SLIME
  examples/                 runnable demos to load after (gui:start)
    README.md               how to run each example
    hello.lisp, layout.lisp, plots.lisp, custom-knob.lisp, error-recovery.lisp
  native/
    CMakeLists.txt          builds libsc_imgui_shim (.dylib/.so/.dll)
    sc_imgui_config.h     IMGUI_USER_CONFIG: IM_ASSERT override
    shim.h, shim.cpp        window, frame, headless and assert-log functions
    test_assert.c           C test for the assert override
    third_party/            submodules: imgui, cimgui, implot, cimplot, glfw
  generator/
    package.lisp
    model.lisp              JSON -> plist model of functions, structs, enums
    types.lisp              C type string -> CFFI type
    names.lisp              C name -> Lisp symbol name
    emit.lisp               model -> CFFI forms, written to a file
    main.lisp               generate-bindings entry point
  src/bindings/
    package.lisp            %imgui, %implot, %shim
    library.lisp            foreign library search and load
    shim.lisp               hand-written CFFI for shim.h
    imgui.lisp              GENERATED, committed
    implot.lisp             GENERATED, committed
  src/runtime/
    package.lisp            gui.runtime
    registry.lisp           gui-entry struct, register, snapshot
    tasks.lisp              call-in-gui-thread queue
    report.lisp             *report-stream*, report-error
    frame.lisp              draw-registered-guis, failed-panel windows
    loop.lisp               start, stop, running-p, *ini-path*
  src/gui/
    package.lisp            gui (shadows cl:remove)
    define-gui.lisp         define-gui, show, hide, remove
    foreign.lisp            scratch memory, string helpers, ID table
    scopes.lisp             with-window ... with-style
    layout.lisp             with-row, with-grid, layout functions
    widgets.lisp            widgets and their -value variants
    plots.lisp              with-plot, plot-lines, plot-bars, plot-scatter
    draw.lisp               draw-list primitives, interaction helpers
  tests/
    run.lisp                CLI entry used by make test
    package.lisp, suites.lisp
    headless.lisp           with-headless-imgui, with-test-frame, click-at
    fixtures/               small cimgui/cimplot JSON fixtures
    test-generator.lisp ... one file per suite
    smoke.lisp              real-window smoke test
  .github/workflows/ci.yml  Linux: build, test, smoke under Xvfb
```

Each task's **Files** block names its files. Generated files are committed so that loading the system never needs the generator or JSON.

## Task 1: Native shim and build

**Files:**

- Create: `native/CMakeLists.txt`, `native/sc_imgui_config.h`, `native/shim.h`, `native/shim.cpp`, `native/test_assert.c`, `Makefile`, `README.md`, `.gitmodules`
- Submodules: `native/third_party/{imgui,cimgui,implot,cimplot,glfw}`
- Test: `native/test_assert.c` (run by `ctest`)

**Interfaces:**

- Consumes: nothing.
- Produces: shared library `libsc_imgui_shim` exporting every cimgui and cimplot symbol plus this C API from `shim.h`, all `extern "C"`:

```c
int         shim_open_window(int width, int height, const char *title, const char *ini_path); /* 0 = ok; ini_path NULL = no ini file; string is copied */
int         shim_should_close(void);          /* 1 when the user closed the window */
void        shim_begin_frame(void);           /* glfwPollEvents + backend NewFrame + igNewFrame */
void        shim_end_frame(void);             /* igRender + GL draw + glfwSwapBuffers */
void        shim_shutdown(void);              /* destroys backends, ImPlot and ImGui contexts, window */
const char *shim_last_error(void);            /* message for the last nonzero return, or "" */
int         shim_headless_create(int width, int height); /* contexts, DisplaySize, DeltaTime 1/60, font atlas built; 0 = ok */
void        shim_headless_destroy(void);
int         shim_assert_count(void);
const char *shim_last_assert(void);           /* "expr @ file:line" */
void        shim_clear_asserts(void);
```

- [ ] **Step 1: Add the submodules, pinned**

Add ImGui (docking branch), cimgui (`docking_inter`), ImPlot, cimplot, and GLFW under `native/third_party/`. Check out compatible commits and record each SHA and date in `README.md`.

- [ ] **Step 2: Write the failing C test `native/test_assert.c`**

```c
/* asserts must be recorded, never abort */
int main(void) {
  if (shim_headless_create(800, 600) != 0) return 1;
  igNewFrame();
  igEnd();                         /* End without Begin: misuse */
  igRender();
  if (shim_assert_count() < 1) return 2;
  if (shim_last_assert()[0] == '\0') return 3;
  shim_clear_asserts();
  if (shim_assert_count() != 0) return 4;
  shim_headless_destroy();
  return 0;
}
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `make native` Expected: build fails; `shim.h` not found.

- [ ] **Step 4: Implement the build and shim**

* `sc_imgui_config.h` declares `extern "C" void sc_imgui_assert_failed(const char *expr, const char *file, int line);` and defines `IM_ASSERT(e)` as `do { if (!(e)) sc_imgui_assert_failed(#e, __FILE__, __LINE__); } while (0)`.
* `CMakeLists.txt` builds one shared library from the ImGui, ImPlot, cimgui, and cimplot sources, `imgui_impl_glfw.cpp`, `imgui_impl_opengl3.cpp`, and `shim.cpp`. Every target gets the compile definition `IMGUI_USER_CONFIG="sc_imgui_config.h"` and, for cimgui, `IMGUI_IMPL_API=extern "C"`. GLFW comes from `add_subdirectory` with its examples, tests, and docs off. Add `test_assert` as a `ctest` test.
* `shim.cpp` keeps the assert count and last message in statics. Contexts set `io.ConfigErrorRecovery = true` and `io.ConfigFlags |= ImGuiConfigFlags_DockingEnable`, so windows can dock inside the one OS window. `ImGuiConfigFlags_ViewportsEnable` stays off.
* OpenGL context: macOS uses 3.2 core, forward-compatible, GLSL `#version 150`. Other platforms use 3.0, GLSL `#version 130`. `shim_open_window` calls `glfwSwapInterval(1)`.
* `Makefile` target `native` runs `cmake -S native -B native/build -DCMAKE_BUILD_TYPE=Release`, then `cmake --build native/build`, then `ctest --test-dir native/build --output-on-failure`.

- [ ] **Step 5: Run it to confirm it passes**

Run: `make native` Expected: build succeeds; `100% tests passed, 0 tests failed out of 1`.

- [ ] **Step 6: Commit**

```bash
git add .gitmodules native Makefile README.md
git commit -m "feat: native shim with recorded ImGui asserts"
```

## Task 2: Binding generator and test runner

**Files:**

- Create: `sc-imgui.asd` (systems `sc-imgui/generator` and `sc-imgui/tests` only for now), `generator/{package,model,types,names,emit,main}.lisp`, `tests/{run,package,suites}.lisp`, `tests/test-generator.lisp`, `tests/fixtures/{definitions,structs_and_enums,typedefs_dict}.json`
- Modify: `Makefile` (targets `bindings`, `test`)

**Interfaces:**

- Consumes: the JSON files in `native/third_party/cimgui/generator/output/` and `native/third_party/cimplot/generator/output/`.
- Produces (package `sc-imgui.generator`):
  - `(load-model definitions-path structs-and-enums-path typedefs-path)` returns a plist `(:functions list :structs list :enums list :typedefs hash-table)`. Each function is a plist `(:c-name string :ret string :args ((name type) ...) :variadic-p boolean)`, taken from cimgui's `ov_cimguiname`, `ret`, `argsT`, and `...` arguments.
  - `(c-name->lisp-name c-name prefix)` returns a lowercase string.
  - `(c-type->cffi type-string typedefs)` returns a CFFI type, or `nil` when unmappable.
  - `(emit-forms model &key prefix package)` returns a list of `defcstruct`, `defcfun`, and `defconstant` forms.
  - `(generate-bindings &key (cimgui-dir ...) (cimplot-dir ...) (output-dir #p"src/bindings/"))` writes `imgui.lisp` into package `%imgui` and `implot.lisp` into package `%implot`.
- Produces (test runner): `make test` runs every suite; `make test SUITE=generator` runs one. It exits 0 only when all checks pass.

**Mapping rules (pinned by tests):**

| C | CFFI |
| --- | --- |
| `bool`, `int`, `unsigned int`, `float`, `double`, `void` | `:bool`, `:int`, `:uint`, `:float`, `:double`, `:void` |
| `const char*` | `:string` |
| any other pointer `T*` | `:pointer` |
| `ImVec2`, `ImVec4` by value | `(:struct im-vec2)`, `(:struct im-vec4)` |
| `ImU32`, `ImGuiID` | `:uint32` |
| `size_t` | `:size` |
| a typedef in `typedefs_dict` | its resolved target, e.g. `ImGuiWindowFlags` resolves to `int` |
| fixed array `T[n]` as a struct field | `T` with `:count n` |

Naming: strip the prefix (`ig` for functions, `ImPlot_` for ImPlot functions, `ImGui` or `ImPlot` for enum names), then split CamelCase. Each uppercase letter after a lowercase letter or digit starts a word. In a run of capitals followed by a lowercase letter, the last capital starts a new word. `_` becomes `-`, and the result is lowercased. Enum constants are wrapped in `+...+`. Variadic functions and any with a `va_list` argument are skipped. A struct with any unmappable field is emitted opaque (`(defcstruct name)` with no slots), with a `warn` naming it. Enum values come from `calc_value`.

- [ ] **Step 1: Write the failing tests in `tests/test-generator.lisp`**

```lisp
(test names
  (is (string= "slider-float2" (c-name->lisp-name "igSliderFloat2" "ig")))
  (is (string= "get-io" (c-name->lisp-name "igGetIO" "ig")))
  (is (string= "begin-child-str" (c-name->lisp-name "igBeginChild_Str" "ig")))
  (is (string= "plot-line-float-ptr-int"
               (c-name->lisp-name "ImPlot_PlotLine_FloatPtrInt" "ImPlot_")))
  (is (string= "im-vec2" (c-name->lisp-name "ImVec2" ""))))

(test types
  (let ((td (fixture-typedefs)))
    (is (eq :bool (c-type->cffi "bool" td)))
    (is (eq :string (c-type->cffi "const char*" td)))
    (is (eq :pointer (c-type->cffi "ImDrawList*" td)))
    (is (eq :int (c-type->cffi "ImGuiWindowFlags" td)))
    (is (equal "IM-VEC2" (symbol-name (second (c-type->cffi "ImVec2" td)))))
    (is (null (c-type->cffi "SomeUnknownStruct" td)))))

(test emit-from-fixture
  (let ((forms (emit-forms (fixture-model) :prefix "ig" :package "%IMGUI")))
    (is (find-defcfun forms "igButton"))          ; label :string, size (:struct im-vec2), returns :bool
    (is (null (find-defcfun forms "igText")))      ; variadic: skipped
    (is (equal 1 (constant-value forms "+WINDOW-FLAGS-NO-TITLE-BAR+")))
    (is (opaque-struct-p forms "IM-BITFIELD-THING"))))
```

The fixtures hold exactly the entries these tests name: `igButton`, `igText` (variadic), `ImGuiWindowFlags_NoTitleBar` with `calc_value` 1, `ImVec2`, and `ImBitfieldThing`, which has an `unsigned int x:1` field. `find-defcfun`, `constant-value`, `opaque-struct-p`, `fixture-model`, and `fixture-typedefs` are small helpers in the same file.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=generator`. Expected: FAIL; `c-name->lisp-name` is undefined.

- [ ] **Step 3: Implement the generator files and `generate-bindings`**

Use `com.inuoe.jzon:parse` for JSON. `emit.lisp` writes forms with `*print-case* :downcase` and `*package*` bound to the target package. Each file starts with the header `;;; GENERATED by generator/main.lisp; do not edit.`, followed by the cimgui or cimplot commit SHA. For ImPlot, only emit functions with the `ImPlot_` prefix and structs and enums whose names start with `ImPlot`.

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=generator`. Expected: all checks pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add sc-imgui.asd generator tests Makefile
git commit -m "feat: CFFI binding generator for cimgui JSON"
```

## Task 3: Load the bindings, headless harness

**Files:**

- Create: `src/bindings/{package,library,shim}.lisp`, `tests/headless.lisp`, `tests/test-bindings.lisp`
- Generate and commit: `src/bindings/imgui.lisp`, `src/bindings/implot.lisp` (via `make bindings`)
- Modify: `sc-imgui.asd` (add `sc-imgui/bindings`, depending on `cffi`, `cffi-libffi`, `alexandria`)

**Interfaces:**

- Consumes: Task 1's library and `shim.h`; Task 2's `generate-bindings`.
- Produces:
  - Package `%shim`: `open-window` (width height title ini-path) returns `:int`; `should-close` returns `:int`; `begin-frame`, `end-frame`, `shutdown`; `last-error` returns `:string`; `headless-create` (width height) returns `:int`; `headless-destroy`; `assert-count` returns `:int`; `last-assert` returns `:string`; `clear-asserts`. `ini-path` is `:string`, and `nil` passes NULL.
  - Packages `%imgui` and `%implot` with the generated forms. cimgui functions that return `ImVec2` take an out-pointer as their first argument (`pOut`). Callers allocate it.
  - `sc-imgui.bindings:*library-search-paths*`: the directory in env `SC_IMGUI_LIB` if set, then `native/build/` and `native/build/Release/` relative to the system source directory.
  - `(sc-imgui.bindings:load-shim-library)` loads the first match. If none, it signals `sc-imgui.bindings:shim-library-not-found`, whose slot `paths` and report list every path tried. It's called at system load.
  - Test harness (`tests/headless.lisp`): `(with-headless-imgui (&key (width 800) (height 600)) &body)` wraps `headless-create` and `headless-destroy` in `unwind-protect`. `(with-test-frame () &body)` wraps the body in `igNewFrame`/`igRender` with float traps masked. `(frames-with-click x y draw-fn)` runs four frames (move, press, release, idle), calls `draw-fn` once per frame, and returns the list of its values. `(last-item-center)` returns `(values x y)` from `igGetItemRectMin`/`Max`.

* [ ] **Step 1: Generate the bindings**

Run: `make bindings`. Expected: `src/bindings/imgui.lisp` and `implot.lisp` exist and start with the GENERATED header. Any `warn` output lists only structs this plan doesn't use.

- [ ] **Step 2: Write the failing tests in `tests/test-bindings.lisp`**

```lisp
(test library-loads
  (is (cffi:foreign-library-loaded-p 'sc-imgui.bindings::shim)))

(test missing-library-lists-paths
  (let ((sc-imgui.bindings:*library-search-paths* (list #p"/nonexistent/")))
    (signals sc-imgui.bindings:shim-library-not-found
      (sc-imgui.bindings:load-shim-library))
    (handler-case (sc-imgui.bindings:load-shim-library)
      (error (e) (is (search "/nonexistent/" (princ-to-string e)))))))

(test headless-frame-runs
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))

(test assert-does-not-abort             ; Review Focus 1
  (with-headless-imgui ()
    (with-test-frame () (%imgui:end))   ; End without Begin
    (is (>= (%shim:assert-count) 1))
    (%shim:clear-asserts)))

(test io-struct-is-not-opaque
  (with-headless-imgui (:width 800)
    (let ((size (cffi:foreign-slot-pointer (%imgui:get-io) '(:struct %imgui::im-gui-io)
                                           '%imgui::display-size)))
      (is (= 800.0 (cffi:foreign-slot-value size '(:struct %imgui::im-vec2) '%imgui::x))))))
```

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `make test SUITE=bindings`. Expected: FAIL; package `%SHIM` does not exist.

- [ ] **Step 4: Implement `package.lisp`, `library.lisp`, `shim.lisp`, and `tests/headless.lisp`**

Use `cffi:define-foreign-library` with the platform file name: `libsc_imgui_shim.dylib` on Darwin, `.so` on Linux, `sc_imgui_shim.dll` on Windows. Load it by trying each search path explicitly so the condition can list them.

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `make test SUITE=bindings`. Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add sc-imgui.asd src/bindings tests
git commit -m "feat: load shim and generated bindings; headless test harness"
```

## Task 4: Registry, task queue, `define-gui`

**Files:**

- Create: `src/runtime/{package,registry,tasks,report}.lisp`, `src/gui/{package,define-gui}.lisp`, `tests/test-registry.lisp`
- Modify: `sc-imgui.asd` (main system `sc-imgui`, depending on `sc-imgui/bindings`, `bordeaux-threads`, `trivial-main-thread`, `alexandria`)

**Interfaces:**

- Consumes: nothing from ImGui yet.
- Produces (package `gui.runtime`):
  - `(defstruct gui-entry name function-name (visible t) (failure nil))`, where `failure` is a condition or `nil`.
  - `(register-gui name function-name)` returns the entry. If `name` exists, it updates `function-name`, clears `failure`, and keeps the entry's position and `visible`.
  - `(unregister-gui name)` returns true if the name existed. `(find-gui name)` returns the entry or `nil`.
  - `(set-gui-visible name visible)`, `(mark-gui-failed name condition)`, `(clear-gui-failure name)`.
  - `(registry-snapshot)` returns a fresh list of entries in registration order.
  - All registry functions take one `bt2` lock and are safe from any thread. `(%reset-registry)` is for tests only.
  - `(enqueue-task thunk)`; `(run-queued-tasks)` returns the number of tasks run. A task that signals an error is reported with source `:task`, and the rest still run.
  - `*report-stream*` defaults to `*standard-output*` at load time; Task 6 rebinds it. `(report-error source condition &optional backtrace-string)` writes `[gui] <source> failed: <condition>`, then the backtrace if given.
- Produces (package `gui`, which shadows `cl:remove`):
  - `(define-gui name () &body body)` expands into `(progn (defun name () ,@body) (gui.runtime:register-gui 'name 'name) 'name)`. A non-empty lambda list signals an error at macroexpansion.
  - `(show name)`, `(hide name)`, `(remove name)`, and `(call-in-gui-thread thunk)`, which is `enqueue-task`.

* [ ] **Step 1: Write the failing tests in `tests/test-registry.lisp`**

Each test runs inside `(with-clean-registry () ...)`, which calls `%reset-registry` before and after.

```lisp
(test define-registers
  (gui:define-gui panel-a () nil)
  (is (eq 'panel-a (gui.runtime:gui-entry-function-name (gui.runtime:find-gui 'panel-a)))))

(test redefine-replaces-in-place
  (gui:define-gui panel-a () nil) (gui:define-gui panel-b () nil) (gui:define-gui panel-a () t)
  (is (equal '(panel-a panel-b)
             (mapcar #'gui.runtime:gui-entry-name (gui.runtime:registry-snapshot)))))

(test redefine-clears-failure
  (gui:define-gui panel-a () nil)
  (gui.runtime:mark-gui-failed 'panel-a (make-condition 'simple-error))
  (gui:define-gui panel-a () nil)
  (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'panel-a)))))

(test hide-show-remove
  (gui:define-gui panel-a () nil)
  (gui:hide 'panel-a) (is (not (gui.runtime:gui-entry-visible (gui.runtime:find-gui 'panel-a))))
  (gui:show 'panel-a) (is (gui.runtime:gui-entry-visible (gui.runtime:find-gui 'panel-a)))
  (gui:remove 'panel-a) (is (null (gui.runtime:find-gui 'panel-a))))

(test concurrent-registration                ; 8 threads x 100 names
  (mapc #'bt2:join-thread
        (loop for i below 8 collect
          (let ((i i)) (bt2:make-thread
                        (lambda () (dotimes (j 100)
                                     (gui.runtime:register-gui (cons i j) 'ignore)))))))
  (is (= 800 (length (gui.runtime:registry-snapshot)))))

(test task-queue-survives-errors
  (let ((gui.runtime:*report-stream* (make-string-output-stream)) (ran 0))
    (gui:call-in-gui-thread (lambda () (incf ran)))
    (gui:call-in-gui-thread (lambda () (error "boom")))
    (gui:call-in-gui-thread (lambda () (incf ran)))
    (is (= 3 (gui.runtime:run-queued-tasks)))
    (is (= 2 ran))
    (is (search "boom" (get-output-stream-string gui.runtime:*report-stream*)))
    (is (= 0 (gui.runtime:run-queued-tasks)))))

(test define-gui-rejects-arguments
  (signals error (macroexpand-1 '(gui:define-gui x (a) nil))))
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=registry`. Expected: FAIL; package `GUI` does not exist.

- [ ] **Step 3: Implement the runtime and gui files listed above**

Store the registry as a list plus an `equal` hash table keyed by name, both guarded by the lock. Names can be any `equal`-comparable object; the concurrency test uses conses. The task queue is a list under its own lock, swapped out in one step when running.

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=registry`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add sc-imgui.asd src/runtime src/gui tests
git commit -m "feat: panel registry, task queue, define-gui"
```

## Task 5: Per-frame panel drawing and error recovery

**Files:**

- Create: `src/runtime/frame.lisp`, `tests/test-frame.lisp`
- Modify: `src/gui/package.lisp` (re-export `gui.runtime:*debug-on-error*` as `gui:*debug-on-error*`)

**Interfaces:**

- Consumes: Task 4's registry and `report-error`; Task 3's `%imgui` and headless harness.
- Produces (package `gui.runtime`):
  - `*debug-on-error*`, default `nil`.
  - `(draw-registered-guis)`, called between ImGui's new-frame and render.
    - It takes a `registry-snapshot`. Each visible entry with no failure has its function looked up by name with `fdefinition` and called.
    - When `*debug-on-error*` is `nil`, an error inside a panel is caught with `handler-bind`. The handler captures a backtrace string (`sb-debug:print-backtrace`, `:count 30`), calls `mark-gui-failed` and `report-error` with the entry name as source, and unwinds out of that panel only.
    - When `*debug-on-error*` is true, no handler is installed. The panel call runs inside `restart-case` with restarts `retry-panel` (leave the entry healthy) and `disable-panel` (call `mark-gui-failed`).
    - Each failed entry gets a window titled `"<name> (failed)##failed-<name>"`. It shows the condition text (at most 500 characters) and a `Retry` button that calls `clear-gui-failure`. Each frame, the Retry button's center is stored as a list (x y) in `*retry-button-centers*`, a hash table keyed by entry name, for tests.

* [ ] **Step 1: Write the failing tests in `tests/test-frame.lisp`**

All tests run inside `with-clean-registry` and `with-headless-imgui`. `(frame)` is a local helper for `(with-test-frame () (gui.runtime:draw-registered-guis))`.

```lisp
(test healthy-panel-is-called
  (let ((n 0)) (gui:define-gui p () (incf n)) (frame) (is (= 1 n))))

(test hidden-panel-is-skipped
  (let ((n 0)) (gui:define-gui p () (incf n)) (gui:hide 'p) (frame) (is (= 0 n))))

(test failing-panel-is-isolated
  (let ((n 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
    (gui:define-gui bad () (error "boom"))
    (gui:define-gui good () (incf n))
    (frame) (frame)
    (is (typep (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)) 'simple-error))
    (is (= 2 n))))

(test unbalanced-panel-does-not-break-next-frame
  (let ((n 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
    (gui:define-gui bad () (%imgui:begin "x" (cffi:null-pointer) 0) (error "boom"))
    (gui:define-gui good () (incf n))
    (frame) (frame)
    (is (= 2 n))
    (%shim:clear-asserts)))

(test report-goes-to-captured-stream        ; Review Focus 2
  (let ((gui.runtime:*report-stream* (make-string-output-stream)))
    (gui:define-gui bad () (error "boom-123"))
    (frame)
    (let ((out (get-output-stream-string gui.runtime:*report-stream*)))
      (is (search "BAD" out)) (is (search "boom-123" out)))))

(test retry-button-clears-failure
  (let ((gui.runtime:*report-stream* (make-broadcast-stream)) (fail t))
    (gui:define-gui flaky () (when fail (error "once")))
    (frame) (frame)                          ; fails, then draws its failed window
    (setf fail nil)
    (destructuring-bind (x y) (gethash 'flaky gui.runtime::*retry-button-centers*)
      (frames-with-click x y #'gui.runtime:draw-registered-guis))
    (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'flaky))))))

(test debug-on-error-offers-restarts
  (let ((gui:*debug-on-error* t))
    (gui:define-gui bad () (error "boom"))
    (handler-bind ((error (lambda (c) (declare (ignore c))
                            (invoke-restart 'gui.runtime:disable-panel))))
      (frame))
    (is (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)))))
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=frame`. Expected: FAIL; `draw-registered-guis` is undefined.

- [ ] **Step 3: Implement `src/runtime/frame.lisp`**

Draw the failed-panel window with raw `%imgui` calls, with `end` inside `unwind-protect`. When `*debug-on-error*` is true, the condition stored by `disable-panel` is the one the restart was invoked under. Capture it with a `handler-bind` that only records the condition and declines (returns normally), so the debugger still runs.

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=frame`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/frame.lisp src/gui/package.lisp tests/test-frame.lisp
git commit -m "feat: per-panel error isolation, failed-panel window, retry"
```

## Task 6: Frame loop, start/stop, smoke test, CI

**Files:**

- Create: `src/runtime/loop.lisp`, `tests/test-loop.lisp`, `tests/smoke.lisp`, `.github/workflows/ci.yml`
- Modify: `src/gui/package.lisp` (export `start`, `stop`, `running-p`, `*ini-path*`), `Makefile` (target `smoke`), `README.md` (running from SLIME or Sly)

**Interfaces:**

- Consumes: `%shim` window functions (Task 3); `run-queued-tasks`, `*report-stream*`, and `report-error` (Task 4); `draw-registered-guis` (Task 5).
- Produces (package `gui.runtime`, re-exported from `gui`):
  - `*ini-path*`, default `#p"sc-imgui.ini"`. It's merged with `*default-pathname-defaults*` at `start`, and `nil` disables saving. The shim copies the string, so no foreign memory is kept alive in Lisp. Changes take effect at the next `start`.
  - `(start &key (width 1280) (height 800) (title "sc-imgui"))` returns `t` when it starts the loop and `nil` if already running. Before returning, it sets `*report-stream*` to the caller's `*standard-output*`. It then calls `trivial-main-thread:call-in-main-thread` with the loop function, non-blocking.
  - The loop function runs inside the masked-float-traps form. It calls `open-window`; a nonzero result is reported with source `:loop` and `(%shim:last-error)`, and the loop exits. Otherwise each frame does `run-queued-tasks`, `begin-frame`, `draw-registered-guis`, `end-frame`, until the stop flag is set or `should-close` returns 1. An error outside panels is reported with source `:loop`. `shutdown` and clearing the running flag happen in `unwind-protect`.
  - `(stop &key (wait t))` sets the stop flag and returns `t` if the loop was running, else `nil`. With `wait`, it polls `running-p` every 10 ms for up to 5 s.
  - `(running-p)`.

* [ ] **Step 1: Write the failing unit tests in `tests/test-loop.lisp`**

```lisp
(test stop-when-not-running
  (is (null (gui:stop))))

(test not-running-by-default
  (is (not (gui:running-p))))
```

- [ ] **Step 2: Write the smoke test `tests/smoke.lisp`**

It runs its checks in a worker thread and keeps the main thread free for `trivial-main-thread`, as its README describes for scripts. It exits with status 0 only if every check holds, and fails after 30 s. Checks, in order:

1. With `*standard-output*` bound to a string stream, `(gui:start)` returns `t`, and a second `(gui:start)` returns `nil`.
2. A `define-gui` panel that increments a counter reaches 300 frames.
3. Redefining that panel to increment a second counter makes the second counter advance within 60 frames.
4. A panel that signals `"smoke-boom"` doesn't stop the counter, and the string stream from check 1 contains `smoke-boom`.
5. `(gui:stop)` returns `t` and `running-p` becomes false. Then `(gui:start)` again runs 60 more frames, and `(gui:stop)` ends it.

- [ ] **Step 3: Run both to confirm they fail**

Run: `make test SUITE=loop` and `make smoke`. Expected: FAIL; `gui:stop` is undefined.

- [ ] **Step 4: Implement `src/runtime/loop.lisp`, the `smoke` target, and CI**

The `smoke` target runs `sbcl --non-interactive --load tests/smoke.lisp`. In `ci.yml` (ubuntu-latest):

1. Install SBCL, Quicklisp, `cmake`, `xvfb`, and GLFW's X11 and GL development packages (`libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev`).
2. Check out with submodules.
3. Run `make native`, then `make test`, then `xvfb-run -s "-screen 0 1280x1024x24" make smoke`.

- [ ] **Step 5: Run them to confirm they pass**

Run: `make test SUITE=loop`, then `make smoke` locally on macOS. Expected: both exit 0; a window appears briefly during the smoke test.

- [ ] **Step 6: Manual check from SLIME or Sly on macOS**

In the SLIME REPL: `(ql:quickload :sc-imgui)`, then `(gui:start)`, then evaluate a `define-gui` that opens a window with a button. Expected: `start` returns `t` at once, the REPL stays responsive, and re-evaluating the form with C-c C-c changes the window. Record the result in the commit message.

- [ ] **Step 7: Commit**

```bash
git add src/runtime/loop.lisp src/gui/package.lisp tests Makefile README.md .github
git commit -m "feat: main-thread frame loop with start/stop; smoke test and CI"
```

## Task 7: Scope and layout macros

**Files:**

- Create: `src/gui/foreign.lisp` (ID table and enum helpers; Task 8 adds to it), `src/gui/scopes.lisp`, `src/gui/layout.lisp`, `tests/test-scopes.lisp`
- Modify: `src/gui/package.lisp` (exports)

**Interfaces:**

- Consumes: `%imgui` (Task 3), headless harness (Task 3).
- Produces (package `gui`):
  - `(enum-flags prefix designator)` returns an integer. `designator` is an integer (returned as is), a keyword, or a list of keywords. `:no-title-bar` with prefix `"WINDOW-FLAGS"` resolves to `%imgui:+window-flags-no-title-bar+`. An unknown keyword signals an error naming the keyword and prefix.
  - `(object-id object)`, internal. An integer that fits in 32 bits is pushed with `PushID_Int`, and a string with `PushID_Str`. Any other object gets a stable integer from a weak-key `eq` hash table, assigned on first use and pushed with `PushID_Int`. Addresses are never used.
  - `(with-window (title &key flags) &body)`: body runs only if `Begin` returns true. `End` always runs.
  - `(with-group () &body)`, `(with-child (id &key (width 0) (height 0) border) &body)` (`EndChild` always runs), `(with-section (label &key default-open) &body)` (body runs if `CollapsingHeader` returns true; nothing to pop), `(with-id (object) &body)`, `(with-disabled (&optional (disabled t)) &body)`.
  - `(with-style (&rest specs) &body)`. Each spec is `(:color name r g b &optional (a 1.0))`, `(:var name value)`, or `(:var name x y)`. Names resolve through `enum-flags` with prefixes `"COL"` and `"STYLE-VAR"`. Pops `PopStyleColor` and `PopStyleVar` by count.
  - `(with-row () &body)` inserts `(same-line)` between consecutive top-level body forms.
  - `(with-grid (&key (columns 2) id flags) &body)` calls `BeginTable`. The default `id` is `"grid-"` followed by the hex `sxhash` of the body forms, computed at macroexpansion, so it's stable across redefinitions with unchanged bodies. If `BeginTable` returns true, `TableNextColumn` runs before each top-level form and `EndTable` runs afterwards. `EndTable` runs only when `BeginTable` returned true.
  - Functions: `same-line`, `new-line`, `separator`, `spacing`, `(indent &optional (width 0.0))`, `(unindent &optional (width 0.0))`, `(set-next-item-width width)`.
  - Every closing call (`End`, `EndGroup`, `EndChild`, `PopID`, `EndDisabled`, the pops, `EndTable`) runs in `unwind-protect`.

* [ ] **Step 1: Write the failing tests in `tests/test-scopes.lisp`**

Tests run inside `with-headless-imgui`. `(item-min-y)` and `(item-min-x)` are local helpers over `igGetItemRectMin`.

```lisp
(test window-body-runs
  (let (ran) (with-test-frame () (gui:with-window ("w") (setf ran t))) (is-true ran)))

(test errors-keep-scopes-balanced
  (dolist (f (list (lambda () (gui:with-window ("w") (error "x")))
                   (lambda () (gui:with-window ("w") (gui:with-group () (error "x"))))
                   (lambda () (gui:with-window ("w") (gui:with-child ("c") (error "x"))))
                   (lambda () (gui:with-window ("w") (gui:with-id (42) (error "x"))))
                   (lambda () (gui:with-window ("w") (gui:with-disabled () (error "x"))))
                   (lambda () (gui:with-window ("w")
                                (gui:with-style ((:color :button 1 0 0) (:var :frame-rounding 4.0))
                                  (error "x"))))
                   (lambda () (gui:with-window ("w") (gui:with-grid (:columns 2) (error "x"))))))
    (with-test-frame () (handler-case (funcall f) (error () nil)))
    (is (= 0 (%shim:assert-count)))))

(test with-row-places-items-on-one-line
  (let (ys xs)
    (with-test-frame ()
      (gui:with-window ("w")
        (gui:with-row ()
          (progn (%imgui:button "a" (vec2 0 0)) (push (item-min-y) ys) (push (item-min-x) xs))
          (progn (%imgui:button "b" (vec2 0 0)) (push (item-min-y) ys) (push (item-min-x) xs)))))
    (is (= (first ys) (second ys)))
    (is (> (first xs) (second xs)))))

(test with-grid-fills-columns-in-order
  (let (ys)
    (with-test-frame ()
      (gui:with-window ("w")
        (gui:with-grid (:columns 2)
          (progn (%imgui:button "a" (vec2 0 0)) (push (item-min-y) ys))
          (progn (%imgui:button "b" (vec2 0 0)) (push (item-min-y) ys))
          (progn (%imgui:button "c" (vec2 0 0)) (push (item-min-y) ys)))))
    (destructuring-bind (c b a) ys
      (is (= a b)) (is (> c a)))))

(test with-id-stable-across-gc               ; Review Focus 4
  (let ((obj (list 1 2)) id1 id2 id3)
    (with-test-frame () (gui:with-id (obj) (setf id1 (%imgui:get-id-str "k"))))
    (sb-ext:gc :full t)
    (with-test-frame () (gui:with-id (obj) (setf id2 (%imgui:get-id-str "k")))
                        (gui:with-id ((list 1 2)) (setf id3 (%imgui:get-id-str "k"))))
    (is (= id1 id2))
    (is (/= id1 id3))))

(test enum-flags-resolves-keywords
  (is (= (logior %imgui:+window-flags-no-title-bar+ %imgui:+window-flags-no-resize+)
         (gui:enum-flags "WINDOW-FLAGS" '(:no-title-bar :no-resize))))
  (signals error (gui:enum-flags "WINDOW-FLAGS" :no-such-flag)))
```

`vec2` is a test helper that passes an `ImVec2` by value, as a plist `(%imgui::x x %imgui::y y)` per cffi-libffi.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=scopes`. Expected: FAIL; `gui:with-window` is undefined.

- [ ] **Step 3: Implement `foreign.lisp`, `scopes.lisp`, and `layout.lisp`**
- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=scopes`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui tests/test-scopes.lisp
git commit -m "feat: balanced scope macros, layout macros, stable IDs"
```

## Task 8: Widgets

**Files:**

- Create: `src/gui/widgets.lisp`, `tests/test-widgets.lisp`
- Modify: `src/gui/foreign.lisp` (scratch memory), `src/gui/package.lisp` (exports), `tests/headless.lisp` (add `last-item-rect` and `type-text`)

**Interfaces:**

- Consumes: `enum-flags` and `with-window` (Task 7), harness (Task 3).
- Produces (package `gui`). Each place-taking macro evaluates its place's subforms once (`get-setf-expansion`), writes back only when changed, and returns true when changed. Each has a `-value` function taking the current value instead of a place and returning `(values new-value changed-p)`.

| Macro / function | Arguments | Notes |
| --- | --- | --- |
| `slider` / `slider-value` | `label place &key (min 0) (max 1) (scale :linear) format` | Integer value uses `SliderInt`; other reals use `SliderFloat`. `:scale :log` adds `+slider-flags-logarithmic+`. Written back as the original float type (`single-float` or `double-float`); rationals come back as `single-float`. Default format `"%.3f"` or `"%d"`. |
| `drag` / `drag-value` | `label place &key (speed 0.01) (min 0) (max 0) format` | `DragFloat` or `DragInt`, same type rules. `min` = `max` means unclamped. |
| `checkbox` / `checkbox-value` | `label place` | Writes `t` or `nil`. |
| `combo` / `combo-value` | `label place items` | The place holds an index into the list of strings `items`. Uses `BeginCombo`, `Selectable`, `EndCombo`. An out-of-range index previews `""`. |
| `input-text` / `input-text-value` | `label place &key (max-length 256)` | The place holds a string, using a foreign buffer of `max-length` + 1 bytes for the call. |
| `button` | `label &key (width 0) (height 0)` | A function; returns true on click. |
| `text` | `control-string &rest args` | `(apply #'format nil ...)`, then `TextUnformatted`. |

- A value of the wrong type (`nil`, a string for `slider`, and so on) signals `gui:widget-value-error`, a subclass of `type-error` whose report names the widget label. It's signalled before any foreign call.
- `foreign.lisp` gains one 64-byte scratch buffer for `float`, `int`, and `bool` out-values. It's reused on every call, which is safe because drawing is single-threaded.

* [ ] **Step 1: Write the failing tests in `tests/test-widgets.lisp`**

Tests run inside `with-headless-imgui`. `in-window` wraps a body in `(gui:with-window ("w") ...)`. A priming frame records `(last-item-rect)`, returned as `(min-x min-y max-x max-y)`, so clicks know where to land.

```lisp
(test button-reports-one-click
  (let ((results (click-item (lambda () (in-window (gui:button "go"))))))
    (is (= 1 (count t results)))))

(test checkbox-toggles-place
  (let ((flag nil))
    (click-item (lambda () (in-window (gui:checkbox "on" flag))))
    (is (eq t flag))))

(test slider-float-writes-place-and-keeps-type
  (let ((v 0.0d0))
    (click-item-at-right-edge (lambda () (in-window (gui:slider "v" v :min 0 :max 1))))
    (is (typep v 'double-float)) (is (> v 0.9d0))))

(test slider-int-writes-integer
  (let ((v 0))
    (click-item-at-right-edge (lambda () (in-window (gui:slider "n" v :min 0 :max 10))))
    (is (integerp v)) (is (>= v 9))))

(test slider-log-scale-draws-cleanly
  (let ((v 440.0))
    (with-test-frame () (in-window (gui:slider "f" v :min 20 :max 20000 :scale :log)))
    (is (= 440.0 v)) (is (= 0 (%shim:assert-count)))))

(test value-variants-return-unchanged-without-input
  (with-test-frame ()
    (in-window
      (is (equal '(0.5 nil) (multiple-value-list (gui:slider-value "a" 0.5))))
      (is (equal '("hi" nil) (multiple-value-list (gui:input-text-value "b" "hi"))))
      (is (equal '(1 nil) (multiple-value-list (gui:combo-value "c" 1 '("x" "y"))))))))

(test input-text-writes-typed-text
  (let ((s ""))
    (click-item (lambda () (in-window (gui:input-text "name" s))))
    (type-text "hi" (lambda () (in-window (gui:input-text "name" s))))
    (is (string= "hi" s))))

(test slider-nil-place-signals-type-error   ; Review Focus 3
  (let ((v nil))
    (handler-case (with-test-frame () (in-window (gui:slider "Cutoff" v)))
      (type-error (e) (is (search "Cutoff" (princ-to-string e))))
      (:no-error (&rest r) (declare (ignore r)) (fail "no error signalled")))
    (is (= 0 (%shim:assert-count)))))
```

`click-item` runs a priming frame, then `frames-with-click` at the rect's center, and returns the draw function's values. `click-item-at-right-edge` clicks at `max-x - 2`. `type-text` queues `AddInputCharactersUTF8` and runs two frames. `with-test-frame` must call `igRender` in `unwind-protect`, so an error mid-frame still ends the frame.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=widgets`. Expected: FAIL; `gui:button` is undefined.

- [ ] **Step 3: Implement `widgets.lisp` and the scratch buffer**
- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=widgets`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui tests
git commit -m "feat: place-based widgets with functional variants"
```

## Task 9: Plots

**Files:**

- Create: `src/gui/plots.lisp`, `tests/test-plots.lisp`
- Modify: `src/gui/package.lisp` (exports)

**Interfaces:**

- Consumes: `%implot` (Task 3; the ImPlot context is created by `shim_open_window` and `shim_headless_create`), `with-window` and `enum-flags` (Task 7).
- Produces (package `gui`):
  - `(with-plot (title &key (width -1) (height 0) flags) &body)`. Body and `EndPlot` run only when `BeginPlot` returns true, unlike ImGui's `End`. `EndPlot` runs in `unwind-protect`.
  - `(plot-data sequence)`, internal. It returns its argument unchanged (`eq`) when it's a `(simple-array single-float (*))` or `(simple-array double-float (*))`. Any other sequence of reals is copied into a new `single-float` vector.
  - `(plot-lines label ys &key xs)`, `(plot-bars label ys &key (bar-size 0.67))`, `(plot-scatter label xs ys)`.
    - Data goes through `plot-data` and is pinned with `cffi:with-pointer-to-vector-data`. The call uses the `FloatPtr` or `doublePtr` overload matching the element type, with stride 4 or 8 passed explicitly.
    - When `xs` and `ys` differ in element type, both become `single-float`. Different lengths signal an error naming the label.
    - Empty data makes no foreign call.

* [ ] **Step 1: Write the failing tests in `tests/test-plots.lisp`**

Tests run inside `with-headless-imgui`. `in-plot` wraps a body in `(gui:with-window ("w") (gui:with-plot ("p") ...))`.

```lisp
(test specialized-vectors-are-not-copied
  (let ((s (make-array 4096 :element-type 'single-float :initial-element 0.0))
        (d (make-array 8 :element-type 'double-float :initial-element 0d0)))
    (is (eq s (gui::plot-data s)))
    (is (eq d (gui::plot-data d)))))

(test plot-coerces-general-sequences          ; Review Focus 5
  (is (equalp #(1.0 2.0 3.0) (gui::plot-data '(1 2 3))))
  (is (typep (gui::plot-data (vector 1 2 3)) '(simple-array single-float (*))))
  (with-test-frame () (in-plot (gui:plot-lines "l" '(1 2 3))))
  (is (= 0 (%shim:assert-count))))

(test all-plot-kinds-draw-cleanly
  (let ((ys (make-array 4096 :element-type 'single-float :initial-element 0.5))
        (xs (make-array 4096 :element-type 'double-float :initial-element 1d0)))
    (with-test-frame ()
      (in-plot (gui:plot-lines "l" ys)
               (gui:plot-lines "lx" ys :xs xs)
               (gui:plot-bars "b" ys)
               (gui:plot-scatter "s" xs ys)
               (gui:plot-lines "empty" #())))
    (is (= 0 (%shim:assert-count)))))

(test mismatched-lengths-signal-error
  (handler-case (with-test-frame () (in-plot (gui:plot-scatter "pts" '(1 2) '(1 2 3))))
    (error (e) (is (search "pts" (princ-to-string e))))
    (:no-error (&rest r) (declare (ignore r)) (fail "no error signalled")))
  (is (= 0 (%shim:assert-count))))
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=plots`. Expected: FAIL; `gui::plot-data` is undefined.

- [ ] **Step 3: Implement `plots.lisp`**
- [ ] **Step 4: Run the tests to confirm they pass**

Run: `make test SUITE=plots`. Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add src/gui/plots.lisp src/gui/package.lisp tests/test-plots.lisp
git commit -m "feat: ImPlot line, bar and scatter plots from Lisp vectors"
```

## Task 10: Draw-list primitives and interaction helpers

**Files:**

- Create: `src/gui/draw.lisp`, `tests/test-draw.lisp`
- Modify: `src/gui/package.lisp` (exports), `tests/headless.lisp` (add `frames-with-drag`)

**Interfaces:**

- Consumes: `%imgui` (Task 3), `with-window` (Task 7), `click-item` and the other test helpers (Task 8).
- Produces (package `gui`). Coordinates are screen-space floats, and every draw function takes `&key (draw-list (window-draw-list))`:
  - `(color r g b &optional (a 1.0))` returns a packed `ImU32`, computed in Lisp from components clamped to 0–1. It must equal `igColorConvertFloat4ToU32`.
  - `(window-draw-list)` returns a pointer.
  - `(draw-line x1 y1 x2 y2 color &key (thickness 1.0))`
  - `(draw-rect x1 y1 x2 y2 color &key filled (rounding 0.0) (thickness 1.0))`
  - `(draw-circle cx cy radius color &key filled (segments 0) (thickness 1.0))`
  - `(draw-arc cx cy radius a-min a-max color &key (thickness 1.0) (segments 0))`, using `PathArcTo` and `PathStroke`. Angles are in radians.
  - `(draw-polyline points color &key closed (thickness 1.0))`. `points` is a flat list or vector `x0 y0 x1 y1 ...`, copied into a foreign `ImVec2` array. Fewer than two points draws nothing; an odd count signals an error.
  - `(draw-text x y color string)`
  - `(invisible-button id width height)` returns true on click.
  - `(item-hovered-p)` and `(item-active-p)`.
  - `(cursor-screen-pos)`, `(mouse-pos)`, `(mouse-drag-delta &optional (button 0))`, and `(content-region-avail)` each return `(values x y)`. `(set-cursor-screen-pos x y)` and `(reset-mouse-drag-delta &optional (button 0))` return nothing.
- Produces (harness): `(frames-with-drag x y dx dy draw-fn)` runs move, press, move by (dx, dy) while held, then release, calling `draw-fn` each frame and returning its values.

* [ ] **Step 1: Write the failing tests in `tests/test-draw.lisp`**

```lisp
(test color-matches-imgui
  (is (= (%imgui:color-convert-float4-to-u32 (vec4 1 0.5 0 1)) (gui:color 1 0.5 0 1))))

(test primitives-add-vertices
  (with-headless-imgui ()
    (with-test-frame ()
      (in-window
        (let ((c (gui:color 1 1 1)))
          (dolist (f (list (lambda () (gui:draw-line 10 10 50 50 c))
                           (lambda () (gui:draw-rect 10 10 50 50 c :filled t))
                           (lambda () (gui:draw-circle 30 30 10 c))
                           (lambda () (gui:draw-arc 30 30 10 0 pi c))
                           (lambda () (gui:draw-polyline '(0 0 10 10 20 0) c))
                           (lambda () (gui:draw-text 10 10 c "hi"))))
            (let ((before (vtx-count (gui:window-draw-list))))
              (funcall f)
              (is (> (vtx-count (gui:window-draw-list)) before)))))))
    (is (= 0 (%shim:assert-count)))))

(test polyline-edge-cases
  (with-headless-imgui ()
    (with-test-frame ()
      (in-window
        (let ((before (vtx-count (gui:window-draw-list))))
          (gui:draw-polyline '(5 5) (gui:color 1 1 1))
          (is (= before (vtx-count (gui:window-draw-list)))))
        (signals error (gui:draw-polyline '(0 0 10) (gui:color 1 1 1)))))))

(test invisible-button-clicks
  (with-headless-imgui ()
    (is (= 1 (count t (click-item (lambda () (in-window (gui:invisible-button "k" 40 40)))))))))

(test drag-reports-delta-while-active
  (with-headless-imgui ()
    (let (seen)
      (prime-and-drag 30 0
        (lambda () (in-window (gui:invisible-button "k" 40 40)
                     (when (gui:item-active-p) (push (gui:mouse-drag-delta) seen)))))
      (is (some (lambda (dx) (>= dx 29.0)) seen)))))
```

`vtx-count` reads `VtxBuffer.Size` from the draw list via the generated `im-draw-list` and `im-vector-im-draw-vert` structs, which must not be opaque. `vec4` passes an `ImVec4` by value. `prime-and-drag` runs a priming frame, then `frames-with-drag` from the item's center.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `make test SUITE=draw`. Expected: FAIL; `gui:color` is undefined.

- [ ] **Step 3: Implement `draw.lisp` and `frames-with-drag`**
- [ ] **Step 4: Run the full suite**

Run: `make test`. Expected: every suite passes (generator, bindings, registry, frame, loop, scopes, widgets, plots, draw), exit code 0. Then run `make smoke`; expected exit code 0.

- [ ] **Step 5: Commit**

```bash
git add src/gui/draw.lisp src/gui/package.lisp tests
git commit -m "feat: draw-list primitives and interaction helpers"
```

## Task 11: Examples

**Files:**

- Create: `examples/README.md`, `examples/hello.lisp`, `examples/layout.lisp`, `examples/plots.lisp`, `examples/custom-knob.lisp`, `examples/error-recovery.lisp`, `tests/test-examples.lisp`
- Modify: `README.md` (link to `examples/README.md`)

**Interfaces:**

- Consumes: the whole `gui` API from Tasks 4 through 10.
- Produces: example files you load from the REPL after `(gui:start)`. Each file is in `cl-user`, uses `gui:` prefixes, and defines only `defvar`/`defparameter` state and `define-gui` panels whose names start with `example-`. No file calls `gui:start`. Examples don't use cl-collider; cl-collider examples arrive with part 2.

| File | Shows |
| --- | --- |
| `hello.lisp` | A window with `text`, a click-counting `button`, a `slider` on a float, and a `checkbox` |
| `layout.lisp` | `with-row` of sliders, a four-column `with-grid` ADSR block, a `with-section`, and a scrolling `with-child` list |
| `plots.lisp` | A live sine `plot-lines` advancing each frame from `get-internal-real-time`, plus `plot-bars` and `plot-scatter` |
| `custom-knob.lisp` | A function `(example-knob label value min max)` returning the new value, built from `invisible-button`, `item-active-p`, `mouse-drag-delta`, `draw-circle`, and `draw-arc`; a panel using three knobs. It previews how part 3 builds widgets. |
| `error-recovery.lisp` | `*example-break*`, default `t`, and a panel that signals an error while it's true, beside a healthy panel. Comments walk through seeing the failed window, then fixing it with Retry or by re-evaluating. |

`examples/README.md` gives, per file, the three REPL steps: `(ql:quickload :sc-imgui)`, `(gui:start)`, then `(load "examples/<file>.lisp")`.

- [ ] **Step 1: Write the failing test in `tests/test-examples.lisp`**

Each example is loaded headlessly and run for three frames. It must register panels, none may fail (except the deliberate one), and ImGui must record no asserts.

```lisp
(defun run-example (file)
  (with-clean-registry ()
    (with-headless-imgui ()
      (let ((gui.runtime:*report-stream* (make-broadcast-stream)))
        (load (asdf:system-relative-pathname :sc-imgui (format nil "examples/~A" file)))
        (dotimes (i 3) (with-test-frame () (gui.runtime:draw-registered-guis)))
        (values (mapcar (lambda (e) (cons (gui.runtime:gui-entry-name e)
                                          (gui.runtime:gui-entry-failure e)))
                        (gui.runtime:registry-snapshot))
                (%shim:assert-count))))))

(test examples-run-cleanly
  (dolist (file '("hello.lisp" "layout.lisp" "plots.lisp" "custom-knob.lisp"))
    (multiple-value-bind (entries asserts) (run-example file)
      (is (plusp (length entries)) "~A registers no panels" file)
      (is (every (lambda (e) (null (cdr e))) entries) "~A has a failed panel" file)
      (is (= 0 asserts) "~A recorded ImGui asserts" file))))

(test error-recovery-example-fails-only-the-broken-panel
  (multiple-value-bind (entries asserts) (run-example "error-recovery.lisp")
    (is (= 1 (count-if #'cdr entries)))
    (is (= 0 asserts))))
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `make test SUITE=examples`. Expected: FAIL; `examples/hello.lisp` does not exist.

- [ ] **Step 3: Write the five example files and `examples/README.md`**

Keep each file short enough to read in one screen, with a header comment saying what it shows and how to run it.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `make test SUITE=examples`. Expected: all checks pass.

- [ ] **Step 5: Try them live**

In SLIME or Sly on macOS, load each example after `(gui:start)`. Expected: each panel appears; dragging a knob in `custom-knob.lisp` changes its value; setting `*example-break*` to `nil` and pressing Retry restores the broken panel.

- [ ] **Step 6: Commit**

```bash
git add examples tests/test-examples.lisp README.md
git commit -m "docs: runnable examples with headless tests"
```
