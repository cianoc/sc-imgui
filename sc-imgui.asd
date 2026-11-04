;;;; sc-imgui systems. Later tasks add sc-imgui/bindings and fill in sc-imgui.

;;; Primary system: Quicklisp's quickload requires it to exist before it will
;;; load a "sc-imgui/..." subsystem.  Components arrive in later tasks.
(asdf:defsystem "sc-imgui"
  :description "Dear ImGui + ImPlot for Common Lisp (SBCL)."
  :depends-on ("sc-imgui/bindings" "bordeaux-threads" "trivial-main-thread" "alexandria" "uiop")
  :pathname "src/"
  :serial t
  :components ((:module "runtime"
                :serial t
                :components ((:file "package")
                             (:file "registry")
                             (:file "tasks")
                             (:file "report")
                             (:file "frame")
                             (:file "loop")))
               (:module "gui"
                :serial t
                :components ((:file "package")
                             (:file "define-gui")
                             (:file "foreign")
                             (:file "scopes")
                             (:file "layout")
                             (:file "widgets")))))

(asdf:defsystem "sc-imgui/generator"
  :description "Generates CFFI bindings from cimgui/cimplot JSON definitions."
  :depends-on ("com.inuoe.jzon" "cffi")
  :pathname "generator/"
  :serial t
  :components ((:file "package")
               (:file "names")
               (:file "model")
               (:file "types")
               (:file "emit")
               (:file "main")))

;;; Foreign bindings: native shim library plus the generated cimgui/cimplot CFFI.
;;; The shim library is loaded by library.lisp before the generated files compile.
(asdf:defsystem "sc-imgui/bindings"
  :description "CFFI bindings to the native shim, Dear ImGui and ImPlot."
  :depends-on ("cffi" "cffi-libffi" "alexandria" "uiop")
  :pathname "src/bindings/"
  :serial t
  :components ((:file "package")
               (:file "types")
               (:file "library")
               (:file "shim")
               (:file "imgui")
               (:file "implot")))

;;; Test system. Each task appends its test files (and suites in
;;; tests/suites.lisp); run with `make test` or `make test SUITE=<name>`.
(asdf:defsystem "sc-imgui/tests"
  :description "FiveAM tests for sc-imgui."
  :depends-on ("fiveam" "sc-imgui/generator" "sc-imgui/bindings" "sc-imgui")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suites")
               (:file "test-generator")
               (:file "headless")
               (:file "test-bindings")
               (:file "test-registry")
               (:file "test-frame")
               (:file "test-loop")
               (:file "test-scopes")
               (:file "test-widgets")))
