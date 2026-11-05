;;;; plots.lisp -- ImPlot from Lisp vectors: a live sine, bars and a scatter.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)  (load "examples/plots.lisp")
;;;; Simple single-float vectors go to ImPlot without copying; lists are copied.

(in-package #:cl-user)

(defparameter *example-xs*
  (let ((v (make-array 200 :element-type 'single-float)))
    (dotimes (i 200 v) (setf (aref v i) (float i 1.0f0)))))
(defparameter *example-sine* (make-array 200 :element-type 'single-float))
(defparameter *example-bars* (coerce '(3.0 5.0 2.0 7.0 4.0) '(simple-array single-float (*))))
(defparameter *example-scatter-x* (coerce '(1.0 2.0 3.5 4.0 6.0) '(simple-array single-float (*))))
(defparameter *example-scatter-y* (coerce '(2.0 4.0 3.0 6.5 5.0) '(simple-array single-float (*))))

(gui:define-gui example-plots ()
  (let ((phase (* 2.0 (/ (get-internal-real-time)
                         (float internal-time-units-per-second 1.0)))))
    ;; Refill the same vector each frame: no consing, and the plot scrolls.
    (dotimes (i (length *example-sine*))
      (setf (aref *example-sine* i) (sin (+ phase (* i 0.1f0))))))
  (gui:with-window ("Plots")
    (gui:with-plot ("sine" :height 200)
      (gui:plot-lines "sin" *example-sine* :xs *example-xs*))
    (gui:with-plot ("bars and scatter" :height 200)
      (gui:plot-bars "bars" *example-bars*)
      (gui:plot-scatter "points" *example-scatter-x* *example-scatter-y*))))
