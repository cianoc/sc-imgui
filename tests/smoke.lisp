;;;; Real-window smoke test: sbcl --non-interactive --load tests/smoke.lisp
;;;; (`make smoke`).  Opens a GLFW/OpenGL window.  Exit status is 0 only when
;;;; every check passed; 1 on a failed check or after 30 s; 2 if loading failed.
;;;;
;;;; The frame loop must run on SBCL's main thread, which trivial-main-thread
;;;; takes over by interrupting it with its task runner the first time it is
;;;; asked to run something there.  So the checks run in a worker thread and the
;;;; main thread just idles (interruptibly) in SLEEP, as it would at an idle
;;;; REPL.  The worker ends the process with SB-EXT:EXIT :ABORT T.

(require :asdf)

(defvar *repo-root*
  (make-pathname :name nil :type nil :version nil
                 :defaults (merge-pathnames "../" (or *load-truename* *default-pathname-defaults*))))

(unless (find-package '#:ql)
  (let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file setup) (load setup))))

(pushnew *repo-root* asdf:*central-registry* :test #'equal)

(handler-bind ((error (lambda (e)
                        (format *error-output* "~&smoke: failed to load sc-imgui: ~A~%" e)
                        (finish-output *error-output*)
                        (sb-ext:exit :code 2 :abort t))))
  (if (find-package '#:ql)
      (funcall (intern "QUICKLOAD" '#:ql) :sc-imgui :silent t)
      (asdf:load-system :sc-imgui)))

(defpackage #:sc-imgui.smoke
  (:use #:cl))
(in-package #:sc-imgui.smoke)

(defconstant +timeout+ 30 "Seconds before the whole smoke test fails.")

;;; Written only by panels on the main thread; read by the worker.
(defvar *frames* 0 "Frames seen by the SMOKE-FRAMES panel.")
(defvar *count-a* 0)
(defvar *count-b* 0)

(defun finish (code control &rest args)
  (format *error-output* "~&smoke: ~?~%" control args)
  (finish-output *error-output*)
  (finish-output *standard-output*)
  (sb-ext:exit :code code :abort t))

(defun note (control &rest args)
  (format t "~&smoke: ~?~%" control args)
  (finish-output))

(defun check (ok control &rest args)
  (if ok
      (apply #'note (concatenate 'string "ok   " control) args)
      (apply #'finish 1 (concatenate 'string "FAIL " control) args)))

(defun wait-until (predicate)
  "Poll PREDICATE every 10 ms until it is true (the global watchdog bounds it)."
  (loop until (funcall predicate) do (sleep 0.01))
  t)

(defun wait-frames (n)
  (let ((target (+ *frames* n)))
    (wait-until (lambda () (>= *frames* target)))))

(defun smoke-window (label)
  (when (%imgui:begin "smoke" (cffi:null-pointer) 0)
    (%imgui:text-unformatted label (cffi:null-pointer)))
  (%imgui:end))

(gui:define-gui smoke-frames ()
  (incf *frames*))

(gui:define-gui smoke-counter ()
  (smoke-window "counter A")
  (incf *count-a*))

(defun redefine (form)
  (handler-bind ((warning #'muffle-warning)) (eval form)))

;;; GLFW's window attributes may only be read on the main thread, so ask the
;;; loop (which runs tasks whether the window is showing or hidden).
(defun window-visible ()
  "1 visible, 0 hidden, -1 no window, read on the GUI thread."
  (let ((result :pending))
    (gui:call-in-gui-thread (lambda () (setf result (%shim:window-visible))))
    (wait-until (lambda () (not (eq result :pending))))
    result))

(defun cpu-seconds-over (seconds)
  "Process CPU time used while sleeping SECONDS."
  (let ((t0 (get-internal-run-time)))
    (sleep seconds)
    (/ (- (get-internal-run-time) t0) internal-time-units-per-second)))

(defun check-hidden (when)
  (check (not (gui:running-p)) "running-p false ~A" when)
  (check (eql 0 (window-visible)) "window hidden ~A (tasks still run)" when)
  (let ((f0 *frames*))
    (sleep 0.3)
    (check (= f0 *frames*) "no frames drawn while hidden ~A" when)))

(defun check-showing-again (title)
  (let ((again (gui:start :title title)))
    (check (eq again t) "(gui:start :title ~S) returned ~S" title again))
  (check (gui:running-p) "running-p true after start")
  (let ((f0 *frames*))
    (wait-frames 60)
    (check t "panels drawn again (~D frames)" (- *frames* f0)))
  (check (eql 1 (window-visible)) "window visible again"))

(defvar *ini* (merge-pathnames "sc-imgui-smoke.ini" (uiop:temporary-directory)))

(defun run-checks ()
  (when (probe-file *ini*) (delete-file *ini*))
  (setf gui:*ini-path* *ini*)
  (let ((out (make-string-output-stream)))
    ;; 1. start returns T, then NIL while showing.
    (let ((first (let ((*standard-output* out)) (gui:start :title "sc-imgui smoke")))
          (second (let ((*standard-output* out)) (gui:start))))
      (check (eq first t) "first (gui:start) returned ~S" first)
      (check (null second) "second (gui:start) returned ~S" second))
    ;; 2. A panel reaches 300 frames.
    (let ((t0 (get-internal-real-time)))
      (wait-until (lambda () (>= *count-a* 300)))
      (check t "counter panel reached 300 frames in ~,2F s"
             (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
    (check (eql 1 (window-visible)) "window visible while running")
    ;; 3. Redefinition takes effect within 60 frames.
    (let ((f0 *frames*))
      (redefine '(gui:define-gui smoke-counter ()
              (smoke-window "counter B")
              (incf *count-b*)))
      (wait-until (lambda () (or (plusp *count-b*) (> (- *frames* f0) 60))))
      (check (plusp *count-b*) "redefined panel ran within ~D frames"
             (- *frames* f0)))
    ;; 4. A failing panel neither stops the loop nor goes unreported.
    (redefine '(gui:define-gui smoke-boom () (error "smoke-boom")))
    (wait-until (lambda () (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'smoke-boom))))
    (let ((b0 *count-b*))
      (wait-frames 30)
      (check (>= (- *count-b* b0) 30) "counter kept running after smoke-boom (+~D)"
             (- *count-b* b0)))
    (let ((report (get-output-stream-string out)))
      (check (search "smoke-boom" report) "smoke-boom reported to start's *standard-output*"))
    (gui:remove 'smoke-boom)
    ;; 5. stop hides the window; the loop idles but still runs tasks.
    (let ((stopped (gui:stop)))
      (check (eq stopped t) "(gui:stop) returned ~S" stopped)
      (check (null (gui:stop)) "second (gui:stop) returned NIL")
      (check (probe-file *ini*) "ImGui saved its layout to gui:*ini-path* (~A)" *ini*)
      (check-hidden "after stop")
      (let ((cpu (cpu-seconds-over 1.0)))
        (check (< cpu 0.2) "~,3F s CPU over 1 s while hidden" cpu)))
    ;; 6. start shows the same window again.
    (check-showing-again "sc-imgui smoke (shown again)")
    ;; 7. The close button (GLFW's should-close flag) behaves like stop.
    (check (zerop (%shim:test-request-close)) "close requested")
    (wait-until (lambda () (not (gui:running-p))))
    (check-hidden "after the close button")
    (check-showing-again "sc-imgui smoke (after close)")
    ;; 8. shutdown ends the loop and releases the main thread.
    (let ((done (gui:shutdown)))
      (check (eq done t) "(gui:shutdown) returned ~S" done)
      (check (null gui.runtime::*state*) "loop ended after shutdown")
      (check (= -1 (%shim:window-visible)) "window destroyed after shutdown")
      (check (null (gui:shutdown)) "second (gui:shutdown) returned NIL")
      (check (null (gui:stop)) "(gui:stop) after shutdown returned NIL")
      (check (eq :free (trivial-main-thread:call-in-main-thread (lambda () :free) :blocking t))
             "main thread runs other work after shutdown"))
    ;; 9. start after shutdown creates a new window and loop.
    (check-showing-again "sc-imgui smoke (new loop)")
    (check (eq t (gui:stop)) "stop before final shutdown")
    (check (eq t (gui:shutdown)) "shutdown from hidden")
    (check (null gui.runtime::*state*) "loop ended after final shutdown")))

(bt2:make-thread (lambda ()
                   (sleep +timeout+)
                   (finish 1 "FAIL timed out after ~D s (frames ~D, A ~D, B ~D)"
                           +timeout+ *frames* *count-a* *count-b*))
                 :name "smoke watchdog")

(bt2:make-thread (lambda ()
                   (handler-case (run-checks)
                     (error (e) (finish 1 "FAIL error in checks: ~A" e)))
                   (finish 0 "all checks passed"))
                 :name "smoke checks")

;;; Leave the main thread idle and interruptible for trivial-main-thread.
(loop (sleep 1))
