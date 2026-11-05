;;;; layout.lisp -- with-row, with-grid, with-section and a scrolling with-child.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)  (load "examples/layout.lisp")

(in-package #:cl-user)

(defvar *example-mix* (list 0.8 0.5 0.3))
(defvar *example-adsr* (vector 0.01 0.2 0.7 0.5)) ; attack decay sustain release

(gui:define-gui example-layout ()
  (gui:with-window ("Layout")
    ;; with-row puts its forms on one line.
    (gui:with-row ()
      (gui:set-next-item-width 80)
      (gui:slider "a" (first *example-mix*))
      (gui:set-next-item-width 80)
      (gui:slider "b" (second *example-mix*))
      (gui:set-next-item-width 80)
      (gui:slider "c" (third *example-mix*)))
    ;; with-grid: each form fills the next cell, left to right, top to bottom.
    (gui:with-section ("ADSR" :default-open t)
      (gui:with-grid (:columns 4 :id "adsr")
        (gui:slider "A" (aref *example-adsr* 0) :min 0 :max 2)
        (gui:slider "D" (aref *example-adsr* 1) :min 0 :max 2)
        (gui:slider "S" (aref *example-adsr* 2) :min 0 :max 1)
        (gui:slider "R" (aref *example-adsr* 3) :min 0 :max 4)))
    (gui:with-section ("Scrolling list" :default-open t)
      (gui:with-child ("list" :height 100 :border t)
        (dotimes (i 40)
          (gui:text "item ~D" i))))))
