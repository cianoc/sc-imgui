(in-package #:sc-imgui.tests)

;;; Frame loop start/stop.  Opening a real window is covered by tests/smoke.lisp
;;; (`make smoke`); these tests never open one.

(in-suite loop)

(test stop-when-not-running
  (is (null (gui:stop))))

(test not-running-by-default
  (is (not (gui:running-p))))

(test shutdown-without-a-loop
  (is (null (gui:shutdown))))

;;; State transitions without a real loop: set the loop's state by hand.  START
;;; and STOP on an existing loop only change the requested state and wake it.
(defmacro with-loop-state ((state) &body body)
  `(unwind-protect
        (progn (setf gui.runtime::*state* ,state
                     gui.runtime::*shown* (eq ,state :showing))
               ,@body)
     (setf gui.runtime::*state* nil
           gui.runtime::*shown* nil)))

(test stop-hides-a-showing-window
  (with-loop-state (:showing)
    (is (gui:running-p))
    (is (eq t (gui:stop :wait nil)))
    (is (eq :hidden gui.runtime::*state*))
    (is (not (gui:running-p)))
    (is (null (gui:stop :wait nil)) "stop when hidden")))

(test start-shows-a-hidden-window-even-on-the-main-thread
  ;; Showing again needs no new loop, so the main-thread check does not apply.
  (with-loop-state (:hidden)
    (is (eq t (gui:start :title "again")))
    (is (eq :showing gui.runtime::*state*))
    (is (string= "again" gui.runtime::*title*))
    (is (gui:running-p))
    (is (null (gui:start)) "start when showing")))

(test shutdown-ends-a-hidden-or-showing-loop
  (dolist (state '(:hidden :showing))
    (with-loop-state (state)
      (is (eq t (gui:shutdown :wait nil)))
      (is (eq :shutting-down gui.runtime::*state*))
      (is (not (gui:running-p)))
      (is (null (gui:shutdown :wait nil)) "shutdown while shutting down")
      (is (null (gui:stop :wait nil)) "stop while shutting down"))))

;;; START from SBCL's main thread would run the loop inside the caller (a
;;; SLIME REPL using the main thread, or a plain terminal REPL) and freeze it, so
;;; it refuses.  `make test` runs on the main thread; elsewhere hand the call to
;;; the main thread so the real check still runs.
(defun %start-on-main-thread ()
  "Call (GUI:START) on the main thread.  Returns the condition it signalled (or
NIL) and the output it wrote."
  (let ((out (make-string-output-stream)))
    (flet ((call ()
             (handler-case (progn (let ((*standard-output* out)) (gui:start)) nil)
               (gui:main-thread-busy (c) c))))
      (values (if (gui.runtime::main-thread-p)
                  (call)
                  (let ((result :pending))
                    (gui.runtime::%run-on-main-thread (lambda () (setf result (call))))
                    (loop while (eq result :pending) do (sleep 0.01))
                    result))
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
                 gui.runtime::*state* :showing)
           (gui.runtime::%frame-loop 100 100 "x" "unused.ini")
           (is (not (gui:running-p)))
           ;; The failed open must not tear down the headless context.
           (is (not (cffi:null-pointer-p (%imgui:get-current-context))))
           (let ((report (get-output-stream-string out)))
             (is (search "LOOP failed" report))
             (is (search "already open" report))))
      (setf gui.runtime::*state* nil
            gui.runtime:*report-stream* saved))))

(test start-from-panel-while-running-returns-nil
  ;; A panel calling START while the loop runs (so on the main thread) does
  ;; nothing: it returns NIL and signals nothing.  Headless stand-in for the
  ;; running loop: *STATE* :SHOWING and the registered panels drawn in a frame.
  (when (gui.runtime::main-thread-p)
    (let ((result :not-called) (signalled nil)
          (out (make-string-output-stream)))
      (unwind-protect
           (with-frame-env
             (let ((gui.runtime:*report-stream* out))
               (setf gui.runtime::*state* :showing)
               (gui:define-gui starter ()
                 (setf result (handler-case (gui:start)
                                (condition (c) (setf signalled c) :signalled))))
               (frame)
               (is (null result))
               (is (null signalled))
               (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'starter))))
               (is (string= "" (get-output-stream-string out)))))
        (setf gui.runtime::*state* nil))))
  (unless (gui.runtime::main-thread-p)
    (skip "not on the main thread")))

;;; Regression: handing work to the main thread must survive a main thread
;;; that is slow to accept interrupts (a GC, a long foreign call).
;;; trivial-main-thread's queue lost such a task for good, so START returned T
;;; and no frame was ever drawn (seen once in CI).  Needs the test run itself
;;; to be on the main thread, as `make test` is.
(test main-thread-handoff-survives-deferred-interrupts
  (if (gui.runtime::main-thread-p)
      (let ((ran nil))
        (bt2:make-thread (lambda ()
                           (sleep 0.1)
                           (gui.runtime::%run-on-main-thread
                            (lambda () (setf ran (if (gui.runtime::main-thread-p)
                                                     :main
                                                     :other))))))
        ;; Defer interrupts for longer than trivial-main-thread's 0.5 s handshake.
        (sb-sys:without-interrupts
          (let ((end (+ (get-internal-real-time) internal-time-units-per-second)))
            (loop while (< (get-internal-real-time) end))))
        (loop repeat 300 until ran do (sleep 0.01))
        (is (eq :main ran)))
      (skip "not on the main thread")))
