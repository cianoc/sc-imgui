;;;; layout.lisp -- with-row, with-grid, with-section, a scrolling with-child
;;;; of selectable rows, and a list-box.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)
;;;;       (load (asdf:system-relative-pathname :sc-imgui "examples/layout.lisp"))

(in-package #:cl-user)

(defvar *example-mix* (list 0.8 0.5 0.3))
(defvar *example-adsr* (vector 0.01 0.2 0.7 0.5)) ; attack decay sustain release
(defvar *example-row* nil)                         ; selected row in the scrolling list
(defvar *example-wave* 0)                          ; index into the list-box items

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
      ;; selectable toggles a place; for single selection use selectable-value
      ;; and store the clicked row.  with-id gives each row its own ID.
      (gui:with-child ("list" :height 100 :border t)
        (dotimes (i 40)
          (gui:with-id (i)
            (when (nth-value 1 (gui:selectable-value (format nil "item ~D" i)
                                                     (eql i *example-row*)))
              (setf *example-row* i)))))
      (gui:text "Selected: ~:[none~;item ~:*~D~]" *example-row*))
    ;; list-box: the place holds the index of the chosen string.
    (gui:with-section ("List box" :default-open t)
      (gui:list-box "wave" *example-wave* '("sine" "saw" "square" "triangle" "noise")
                    :height 90))))
