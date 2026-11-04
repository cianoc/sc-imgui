(in-package #:sc-imgui.tests)

;;; Frame loop start/stop.  Opening a real window is covered by tests/smoke.lisp
;;; (`make smoke`); these tests never open one.

(in-suite loop)

(test stop-when-not-running
  (is (null (gui:stop))))

(test not-running-by-default
  (is (not (gui:running-p))))

;;; START from SBCL's main thread would run the loop inside the caller (a
;;; SLIME REPL using the main thread, or a plain terminal REPL) and freeze it, so
;;; it refuses.  `make test` runs on the main thread; elsewhere hand the call to
;;; the main thread through trivial-main-thread so the real check still runs.
(defun %start-on-main-thread ()
  "Call (GUI:START) on the main thread.  Returns the condition it signalled (or
NIL) and the output it wrote."
  (let ((out (make-string-output-stream)))
    (flet ((call ()
             (handler-case (progn (let ((*standard-output* out)) (gui:start)) nil)
               (gui:main-thread-busy (c) c))))
      (values (if (trivial-main-thread:main-thread-p)
                  (call)
                  (trivial-main-thread:call-in-main-thread #'call :blocking t))
              (get-output-stream-string out)))))

(test start-on-main-thread-signals
  (let ((saved gui.runtime:*report-stream*)
        (marker (make-string-output-stream)))
    (unwind-protect
         (progn
           (setf gui.runtime:*report-stream* marker)
           (multiple-value-bind (c output) (%start-on-main-thread)
             (is (typep c 'gui:main-thread-busy))
             (is (not (gui:running-p)))
             (is (eq marker gui.runtime:*report-stream*) "*report-stream* was changed")
             (is (string= "" output))
             (let ((report (and c (princ-to-string c))))
               (is (search "*main-thread-used*" report))
               (is (search "~/.swank.lisp" report))
               (is (search "main thread" report)))))
      (setf gui.runtime:*report-stream* saved))))

(test frame-loop-reports-open-failure
  ;; With a headless context open, the shim refuses to open a window.  Run the
  ;; loop body directly (START would refuse on the main thread, and elsewhere
  ;; the loop would run later, after the headless context is gone).
  (let ((saved gui.runtime:*report-stream*)
        (out (make-string-output-stream)))
    (unwind-protect
         (with-headless-imgui ()
           (setf gui.runtime:*report-stream* out
                 gui.runtime::*running* t)
           (gui.runtime::%frame-loop 100 100 "x" "unused.ini")
           (is (not (gui:running-p)))
           ;; The failed open must not tear down the headless context.
           (is (not (cffi:null-pointer-p (%imgui:get-current-context))))
           (let ((report (get-output-stream-string out)))
             (is (search "LOOP failed" report))
             (is (search "already open" report))))
      (setf gui.runtime::*running* nil
            gui.runtime:*report-stream* saved))))

(test start-from-panel-while-running-returns-nil
  ;; A panel calling START while the loop runs (so on the main thread) does
  ;; nothing: it returns NIL and signals nothing.  Headless stand-in for the
  ;; running loop: *RUNNING* set and the registered panels drawn in a frame.
  (when (trivial-main-thread:main-thread-p)
    (let ((result :not-called) (signalled nil)
          (out (make-string-output-stream)))
      (unwind-protect
           (with-frame-env
             (let ((gui.runtime:*report-stream* out))
               (setf gui.runtime::*running* t)
               (gui:define-gui starter ()
                 (setf result (handler-case (gui:start)
                                (condition (c) (setf signalled c) :signalled))))
               (frame)
               (is (null result))
               (is (null signalled))
               (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'starter))))
               (is (string= "" (get-output-stream-string out)))))
        (setf gui.runtime::*running* nil))))
  (unless (trivial-main-thread:main-thread-p)
    (skip "not on the main thread")))
