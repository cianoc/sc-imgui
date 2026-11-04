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

;;; On macOS the window must leave the screen once the loop has shut down,
;;; though the main thread then idles and processes no more Cocoa events.
;;; %SHIM:ONSCREEN-WINDOW-COUNT is -1 where it is unavailable (Linux CI).
(defun check-window-count (when expected)
  (let ((count (%shim:onscreen-window-count)))
    (if (minusp count)
        (note "skip on-screen window count ~A (unavailable here)" when)
        (check (funcall expected count) "~D on-screen window(s) ~A" count when))))

(defun check-window-gone-within (seconds when)
  "Poll until no window of ours is on screen, failing after SECONDS."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* seconds internal-time-units-per-second)))))
    (loop for count = (%shim:onscreen-window-count)
          until (or (<= count 0) (> (get-internal-real-time) deadline))
          do (sleep 0.02))
    (check-window-count (format nil "within ~,1F s ~A" seconds when) #'zerop)))

(defun check-window-gone (when)
  (sleep 0.5)
  (check-window-count when #'zerop))

(defvar *ini* (merge-pathnames "sc-imgui-smoke.ini" (uiop:temporary-directory)))

(defun run-checks ()
  (when (probe-file *ini*) (delete-file *ini*))
  (setf gui:*ini-path* *ini*)
  (let ((out (make-string-output-stream)))
    ;; 1. start returns T, then NIL while running.
    (let ((first (let ((*standard-output* out)) (gui:start :title "sc-imgui smoke")))
          (second (let ((*standard-output* out)) (gui:start))))
      (check (eq first t) "first (gui:start) returned ~S" first)
      (check (null second) "second (gui:start) returned ~S" second))
    ;; 2. A panel reaches 300 frames.
    (let ((t0 (get-internal-real-time)))
      (wait-until (lambda () (>= *count-a* 300)))
      (check t "counter panel reached 300 frames in ~,2F s"
             (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
    ;; 3. Redefinition takes effect within 60 frames.
    (let ((f0 *frames*))
      (redefine '(gui:define-gui smoke-counter ()
              (smoke-window "counter B")
              (incf *count-b*)))
      (wait-until (lambda () (or (plusp *count-b*) (> (- *frames* f0) 60))))
      (check (plusp *count-b*) "redefined panel ran within ~D frames"
             (- *frames* f0)))
    (check-window-count "while running" #'plusp)
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
    ;; 5. stop, then start again with the registry intact, then stop.
    (let ((stopped (gui:stop)))
      (check (eq stopped t) "(gui:stop) returned ~S" stopped)
      (wait-until (lambda () (not (gui:running-p))))
      (check t "running-p false after stop")
      (check (probe-file *ini*) "ImGui saved its layout to gui:*ini-path* (~A)" *ini*)
      (check-window-gone "0.5 s after stop"))
    (let ((again (gui:start :title "sc-imgui smoke (restart)")))
      (check (eq again t) "restart (gui:start) returned ~S" again))
    (let ((f0 *frames*))
      (wait-frames 60)
      (check t "restarted loop ran ~D frames" (- *frames* f0)))
    ;; 6. The title-bar close button (AppKit's performClose:, on the main
    ;; thread) ends the loop and the window leaves the screen.
    (let ((sent :pending))
      (gui:call-in-gui-thread (lambda () (setf sent (%shim:test-perform-close))))
      (wait-until (lambda () (not (eq sent :pending))))
      (if (minusp sent)
          (note "skip close-button check (unavailable here)")
          (progn
            (wait-until (lambda () (not (gui:running-p))))
            (check t "running-p false after the close button")
            (check-window-gone-within 1.0 "after the close button"))))
    (unless (gui:running-p)
      (let ((again (gui:start :title "sc-imgui smoke (after close)")))
        (check (eq again t) "start after close (gui:start) returned ~S" again))
      (let ((f0 *frames*))
        (wait-frames 60)
        (check t "loop after close ran ~D frames" (- *frames* f0))))
    (let ((stopped (gui:stop)))
      (check (eq stopped t) "final (gui:stop) returned ~S" stopped)
      (check (not (gui:running-p)) "running-p false after final stop")
      (check-window-gone "0.5 s after final stop"))))

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
