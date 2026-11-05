;;;; custom-knob.lisp -- a custom widget built from draw-list primitives.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)  (load "examples/custom-knob.lisp")
;;;; Drag a knob up or down.  This previews how widgets are built in part 3.

(in-package #:cl-user)

(defvar *example-knobs* (vector 0.2 0.5 0.8))

(defun example-knob (label value min max &key (size 48))
  "Draw a knob and return VALUE, changed by dragging vertically."
  (multiple-value-bind (x y) (gui:cursor-screen-pos) ; top-left, before the button
    (gui:invisible-button label size size)           ; non-zero size: 0 means "fit"
    (let* ((active (gui:item-active-p))
           (r (/ size 2.0)))
      (when active
        (multiple-value-bind (dx dy) (gui:mouse-drag-delta)
          (declare (ignore dx))
          ;; 200 px of drag sweeps the whole range; reset so it never drifts.
          (setf value (max min (min max (- value (* dy (/ (- max min) 200.0))))))
          (gui:reset-mouse-drag-delta)))
      (let* ((cx (+ x r))
             (cy (+ y r))
             (start (* pi 0.75))
             (end (+ start (* (/ (- value min) (- max min)) pi 1.5))))
        (gui:draw-circle cx cy (- r 2) (gui:color 0.2 0.2 0.25) :filled t)
        (gui:draw-arc cx cy (- r 3) start (+ start (* pi 1.5)) (gui:color 0.4 0.4 0.4)
                      :thickness 3)
        (gui:draw-arc cx cy (- r 3) start end
                      (if active (gui:color 1 0.7 0.2) (gui:color 0.3 0.7 1))
                      :thickness 3)
        (gui:draw-line cx cy (+ cx (* (- r 6) (cos end))) (+ cy (* (- r 6) (sin end)))
                       (gui:color 1 1 1) :thickness 2)))
    (gui:text "~A ~,2F" label value)
    value))

(gui:define-gui example-knobs ()
  (gui:with-window ("Knobs")
    (dotimes (i 3)
      (gui:with-group ()
        (setf (aref *example-knobs* i)
              (example-knob (format nil "knob ~D" i) (aref *example-knobs* i) 0.0 1.0)))
      (when (< i 2) (gui:same-line)))))
