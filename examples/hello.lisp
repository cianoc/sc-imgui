;;;; hello.lisp -- the smallest useful panel: text, a button, a slider, a checkbox.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)  (load "examples/hello.lisp")
;;;; Then edit the panel below and re-evaluate it (C-c C-c): the window updates.

(in-package #:cl-user)

(defvar *example-clicks* 0)
(defvar *example-gain* 0.5)
(defvar *example-enabled* t)

(gui:define-gui example-hello ()
  (gui:with-window ("Hello")
    (gui:text "Hello from Lisp.")
    (when (gui:button "Click me")
      (incf *example-clicks*))
    (gui:same-line)
    (gui:text "clicked ~D times" *example-clicks*)
    ;; Place-based widgets read and write the variable directly.
    (gui:slider "gain" *example-gain* :min 0 :max 1)
    (gui:checkbox "enabled" *example-enabled*)
    (gui:text "gain = ~,2F, enabled = ~A" *example-gain* *example-enabled*)))
