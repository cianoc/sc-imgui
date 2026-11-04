(in-package #:gui.runtime)

;;; The frame loop.  It runs on SBCL's main thread (via trivial-main-thread),
;;; which SLIME and Sly leave idle, so START returns at once and the REPL stays
;;; free.  START and STOP may be called from any thread.

(defvar *ini-path* #p"sc-imgui.ini"
  "Where ImGui saves window layout, merged with *DEFAULT-PATHNAME-DEFAULTS* at
START.  NIL disables saving.  Changes take effect at the next START.")

(defvar *loop-lock* (bt2:make-lock :name "gui loop"))
(defvar *running* nil "True from START until the loop has shut down.")
(defvar *stop-requested* nil "Set by STOP (and START clears it); the loop polls it.")

(defun running-p ()
  "True while the frame loop is running (or START has queued it)."
  (and *running* t))

(defun %ini-namestring ()
  (and *ini-path*
       (uiop:native-namestring (merge-pathnames *ini-path* *default-pathname-defaults*))))

(defun %frame-loop (width height title ini)
  "Open the window and draw frames until STOP or the window is closed."
  (let ((opened nil))
    (unwind-protect
         (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
           (block frames
             (handler-bind
                 ((error (lambda (c)
                           (report-error :loop c (ignore-errors (%backtrace-string)))
                           (return-from frames nil))))
               ;; A failed open cleans up after itself, so only a window that
               ;; opened is shut down.
               (unless (zerop (%shim:open-window width height title ini))
                 (report-error :loop (%shim:last-error))
                 (return-from frames nil))
               (setf opened t)
               (loop until (or *stop-requested* (= 1 (%shim:should-close)))
                     do (run-queued-tasks)
                        (%shim:begin-frame)
                        (draw-registered-guis)
                        (%shim:end-frame)))))
      (when opened
        (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
          (ignore-errors (%shim:shutdown))))
      (bt2:with-lock-held (*loop-lock*)
        (setf *running* nil)))))

(defun start (&key (width 1280) (height 800) (title "sc-imgui"))
  "Open the window and run the frame loop on the main thread.  Returns T at
once, or NIL if the loop is already running.  Errors are reported to the
caller's *STANDARD-OUTPUT*."
  (let ((ini (%ini-namestring)))
    (bt2:with-lock-held (*loop-lock*)
      (when *running*
        (return-from start nil))
      (setf *running* t
            *stop-requested* nil
            *report-stream* *standard-output*))
    (handler-bind ((error (lambda (c)
                            (declare (ignore c))
                            ;; Could not hand the loop to the main thread.
                            (bt2:with-lock-held (*loop-lock*) (setf *running* nil)))))
      (trivial-main-thread:call-in-main-thread
       (lambda () (%frame-loop width height title ini))
       :blocking nil))
    t))

(defun stop (&key (wait t))
  "Ask the loop to finish its frame, close the window and exit.  Returns T if it
was running, else NIL.  With WAIT (and not on the main thread, where waiting
would deadlock) wait up to 5 s for it to finish."
  (unless (bt2:with-lock-held (*loop-lock*)
            (when *running* (setf *stop-requested* t)))
    (return-from stop nil))
  (when (and wait (not (trivial-main-thread:main-thread-p)))
    (loop repeat 500
          while (running-p)
          do (sleep 0.01)))
  t)
