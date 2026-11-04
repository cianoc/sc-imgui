;;;; sc-imgui systems. Later tasks add sc-imgui/bindings and fill in sc-imgui.

;;; Primary system: Quicklisp's quickload requires it to exist before it will
;;; load a "sc-imgui/..." subsystem.  Components arrive in later tasks.
(asdf:defsystem "sc-imgui"
  :description "Dear ImGui + ImPlot for Common Lisp (SBCL).")

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
               (:file "library")
               (:file "shim")
               (:file "imgui")
               (:file "implot")))

;;; Test system. Each task appends its test files (and suites in
;;; tests/suites.lisp); run with `make test` or `make test SUITE=<name>`.
(asdf:defsystem "sc-imgui/tests"
  :description "FiveAM tests for sc-imgui."
  :depends-on ("fiveam" "sc-imgui/generator" "sc-imgui/bindings")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suites")
               (:file "test-generator")
               (:file "headless")
               (:file "test-bindings")))
