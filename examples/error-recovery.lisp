;;;; error-recovery.lisp -- a failing panel does not take the others down.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)  (load "examples/error-recovery.lisp")
;;;;
;;;; 1. Two windows appear: "Healthy", which keeps running, and
;;;;    "example-broken (failed)".  The broken panel (example-broken) signals
;;;;    an error while *example-break* is T; the error is reported to the REPL,
;;;;    the panel is switched off, and its failed window shows the message and
;;;;    a Retry button.
;;;; 2. Fix it, either way:
;;;;      (setf *example-break* nil)   then press Retry in the failed window;
;;;;    or edit the panel below and re-evaluate it (C-c C-c), which clears the
;;;;    failure by itself.  Either way the "Broken" window then appears.

(in-package #:cl-user)

(defvar *example-break* t)
(defvar *example-ticks* 0)

(gui:define-gui example-healthy ()
  (gui:with-window ("Healthy")
    (gui:text "Still running: ~D frames" (incf *example-ticks*))))

(gui:define-gui example-broken ()
  (when *example-break*
    (error "example-broken: *example-break* is true"))
  (gui:with-window ("Broken")
    (gui:text "Recovered.")))
