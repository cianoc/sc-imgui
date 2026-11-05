;;; The frame loop.  It runs on SBCL's main thread (handed over with
;;; SB-THREAD:INTERRUPT-THREAD), so START returns at once and the REPL stays
;;; free.  That needs the REPL to
;;; evaluate in some other thread: START called on the main thread signals
;;; MAIN-THREAD-BUSY instead of creating the loop.
;;;
;;; Once created, the loop keeps the main thread until SHUTDOWN.  STOP (or the
;;; window's close button) only hides the window: the loop then waits for
;;; events, still running CALL-IN-GUI-THREAD tasks, and START shows the window
;;; again.  Never letting the main thread go idle means the platform's event
;;; loop always runs, so a hidden or closed window really leaves the screen
;;; (on macOS an idle main thread left it there).  STOP, START and SHUTDOWN
;;; only change the requested *STATE* and wake the loop, which does the GLFW
;;; work on the main thread.

(in-package #:gui.runtime)

(defvar *ini-path* #p"sc-imgui.ini"
  "Where ImGui saves window layout, merged with *DEFAULT-PATHNAME-DEFAULTS* at
START.  NIL disables saving.  Changes take effect when the window is next created.")

(defvar *loop-lock* (bt2:make-lock :name "gui loop"))
(defvar *state* nil
  "Requested loop state: NIL (no loop), :SHOWING, :HIDDEN or :SHUTTING-DOWN.
Changed under *LOOP-LOCK*; the loop acts on it and sets it to NIL on exit.")
(defvar *shown* nil "True while the window is on screen.  Written only by the loop.")
(defvar *title* "sc-imgui" "Title to give the window when the loop next shows it.")

(defconstant +hidden-wait+ 0.5d0
  "Longest wait for events while hidden, in seconds.  Requests wake the loop at
once; this only bounds the delay should a wake-up be missed.")

(defun running-p ()
  "True while the window is showing and panels are drawn (or START has asked
for that)."
  (eq *state* :showing))

(defun main-thread-p ()
  (eq sb-thread:*current-thread* (sb-thread:main-thread)))

(defun %run-on-main-thread (function)
  "Run FUNCTION on SBCL's main thread, with interrupts enabled, as soon as that
thread accepts interrupts; return at once.  An interrupt stays pending while
the main thread defers interrupts (a GC, a long foreign call), so FUNCTION is
never lost.  (trivial-main-thread's task queue could lose it: its runner only
looked at the queue when notified, and a notification sent before it waited
was dropped.)  Afterwards the main thread resumes what it was doing."
  (sb-thread:interrupt-thread (sb-thread:main-thread)
                              (lambda () (sb-sys:with-interrupts (funcall function)))))

(defun wake-loop ()
  "Wake the loop if it is waiting for events.  Safe from any thread, and a
no-op without a window."
  (ignore-errors (%shim:wake)))

(define-condition main-thread-busy (error)
  ()
  (:report (lambda (c stream)
             (declare (ignore c))
             (format stream "~@<GUI:START was called on SBCL's main thread.  The frame loop ~
needs the main thread free (macOS only lets it drive windows), but this REPL is ~
evaluating on the main thread, so the loop would freeze it until the window ~
closed.~:@>~%~%~
With SLIME, put~%~%  (setf swank::*main-thread-used* t)~%~%~
~@<in ~~/.swank.lisp and restart SLIME; the REPL then runs in its own thread.  ~
Check with~:@>~%~%  (eq sb-thread:*current-thread* (sb-thread:main-thread))~%~%~
~@<which should be NIL in the REPL.  A script should call GUI:START from another ~
thread and leave the main thread idle, as tests/smoke.lisp does.~:@>")))
  (:documentation "Signalled by START when called on SBCL's main thread, which
the frame loop needs for itself."))

(defun %ini-namestring ()
  (and *ini-path*
       (uiop:native-namestring (merge-pathnames *ini-path* *default-pathname-defaults*))))

(defun %frame-loop (width height title ini)
  "Open the window and run the loop until SHUTDOWN: draw frames while :SHOWING,
wait for events while :HIDDEN."
  (let ((opened nil))
    (unwind-protect
         (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
           (block frames
             (handler-case
             (handler-bind
                 ((error (lambda (c)
                           (report-error :loop c (ignore-errors (%backtrace-string)))
                           (return-from frames nil))))
               ;; A failed open cleans up after itself, so only a window that
               ;; opened is shut down.
               (unless (zerop (%shim:open-window width height title ini))
                 (report-error :loop (%shim:last-error))
                 (return-from frames nil))
               (setf opened t
                     *shown* t)
               (loop
                 (run-queued-tasks)
                 (ecase *state*
                   (:shutting-down (return-from frames nil))
                   (:showing
                    (unless *shown*
                      (%shim:show-window *title*)
                      (setf *shown* t))
                    (if (= 1 (%shim:should-close))
                        ;; The close button: the same as STOP.
                        (bt2:with-lock-held (*loop-lock*)
                          (when (eq *state* :showing) (setf *state* :hidden)))
                        (progn (%shim:begin-frame)
                               (draw-registered-guis)
                               (%shim:end-frame))))
                   (:hidden
                    (when *shown*
                      (%shim:hide-window)
                      (setf *shown* nil))
                    (%shim:wait-events +hidden-wait+)))))
               ;; Stack or heap exhaustion outside a panel: report and shut
               ;; down cleanly rather than leave a frozen window.
               (storage-condition (c) (report-error :loop c)))))
      (when opened
        (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
          (ignore-errors (%shim:shutdown))))
      (bt2:with-lock-held (*loop-lock*)
        (setf *state* nil
              *shown* nil)))))

(defun %wait-while (predicate)
  "Unless on the main thread (where the loop would never get to run), poll
PREDICATE for up to 5 s while it is true."
  (unless (main-thread-p)
    (loop repeat 500
          while (funcall predicate)
          do (sleep 0.01))))

(defun start (&key (width 1280) (height 800) (title "sc-imgui"))
  "Show the GUI window.  Returns T at once, or NIL if it is already showing.

With no loop (the first time, or after SHUTDOWN) this opens a WIDTH x HEIGHT
window and runs the frame loop on SBCL's main thread; that must not be
requested from the main thread itself, which signals MAIN-THREAD-BUSY and
changes nothing.  After STOP it shows the hidden window again, titled TITLE,
and resumes drawing panels.  Errors are reported to the caller's
*STANDARD-OUTPUT*."
  (when (eq *state* :shutting-down)
    (%wait-while (lambda () (eq *state* :shutting-down))))
  (let ((ini (%ini-namestring)) (create nil))
    (bt2:with-lock-held (*loop-lock*)
      (case *state*
        ((:showing :shutting-down) (return-from start nil))
        (:hidden (setf *state* :showing *title* title))
        ((nil)
         (when (main-thread-p)
           (error 'main-thread-busy))
         (setf *state* :showing
               *title* title
               create t)))
      (setf *report-stream* *standard-output*))
    (if create
        (handler-bind ((error (lambda (c)
                                (declare (ignore c))
                                ;; Could not hand the loop to the main thread.
                                (bt2:with-lock-held (*loop-lock*) (setf *state* nil)))))
          (%run-on-main-thread (lambda () (%frame-loop width height title ini))))
        (wake-loop))
    t))

(defun stop (&key (wait t))
  "Hide the window and stop drawing panels, saving the layout to *INI-PATH*.
The loop keeps the main thread, waiting for events and still running
CALL-IN-GUI-THREAD tasks; START shows the window again and SHUTDOWN ends the
loop.  Returns T if the window was showing, else NIL.  With WAIT (and not on
the main thread, where waiting would deadlock) wait up to 5 s for the window
to be hidden."
  (unless (bt2:with-lock-held (*loop-lock*)
            (when (eq *state* :showing) (setf *state* :hidden)))
    (return-from stop nil))
  (wake-loop)
  (when wait
    (%wait-while (lambda () (and *shown* (eq *state* :hidden)))))
  t)

(defun shutdown (&key (wait t))
  "Hide the window, destroy it, end the loop and release the main thread.
Returns T if there was a loop, else NIL.  With WAIT (and not on the main
thread) wait up to 5 s for the loop to finish."
  (unless (bt2:with-lock-held (*loop-lock*)
            (when (member *state* '(:showing :hidden))
              (setf *state* :shutting-down)))
    (return-from shutdown nil))
  (wake-loop)
  (when wait
    (%wait-while (lambda () *state*)))
  t)
