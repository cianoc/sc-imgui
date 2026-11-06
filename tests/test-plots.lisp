(in-package #:sc-imgui.tests)
(in-suite plots)

(defmacro in-plot (&body body)
  "Run BODY inside window \"w\" and plot \"p\".  Local to this suite."
  `(gui:with-window ("w") (gui:with-plot ("p") ,@body)))

(test specialized-vectors-are-not-copied
  (let ((s (make-array 4096 :element-type 'single-float :initial-element 0.0))
        (d (make-array 8 :element-type 'double-float :initial-element 0d0)))
    (is (eq s (gui::plot-data s)))
    (is (eq d (gui::plot-data d)))))

(test plot-coerces-general-sequences
  (is (equalp #(1.0 2.0 3.0) (gui::plot-data '(1 2 3))))
  (is (typep (gui::plot-data (vector 1 2 3)) '(simple-array single-float (*))))
  (with-headless-imgui ()
    (%shim:clear-asserts)
    (dotimes (i 2) (with-test-frame () (in-plot (gui:plot-lines "l" '(1 2 3)))))
    (is (= 0 (%shim:assert-count)))))

(test non-reals-signal-error-naming-label
  (handler-case (gui::plot-data '(1 :x) "bad")
    (error (e) (is (search "bad" (princ-to-string e))))
    (:no-error (&rest r) (declare (ignore r)) (fail "no error signalled"))))

(test all-plot-kinds-draw-cleanly
  (with-headless-imgui ()
    (let ((ys (make-array 4096 :element-type 'single-float :initial-element 0.5))
          (xs (make-array 4096 :element-type 'double-float :initial-element 1d0)))
      (%shim:clear-asserts)
      (dotimes (i 2)
        (with-test-frame ()
          (in-plot (gui:plot-lines "l" ys)
                   (gui:plot-lines "lx" ys :xs xs)
                   (gui:plot-bars "b" ys)
                   (gui:plot-scatter "s" xs ys)
                   (gui:plot-lines "empty" #()))))
      (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert)))))

(test plot-body-runs-and-end-plot-balances
  (with-headless-imgui ()
    (let ((ran nil))
      (%shim:clear-asserts)
      (dotimes (i 2)
        (with-test-frame () (in-plot (setf ran t))))
      (is (eq t ran))
      (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert)))))

(test mismatched-lengths-signal-error
  (with-headless-imgui ()
    (%shim:clear-asserts)
    (handler-case (with-test-frame () (in-plot (gui:plot-scatter "pts" '(1 2) '(1 2 3))))
      (error (e) (is (search "pts" (princ-to-string e))))
      (:no-error (&rest r) (declare (ignore r)) (fail "no error signalled")))
    (is (= 0 (%shim:assert-count)))))

(test series-colours-cycle-per-item-and-restart-per-plot
  (let ((gui:*theme* :mid-light) first-plot second-plot)
    (flet ((item-color () (let ((c (%implot:get-last-item-color)))
                            (gui:color (getf c '%imgui::x) (getf c '%imgui::y)
                                       (getf c '%imgui::z) (getf c '%imgui::w)))))
      (with-headless-imgui ()
        ;; Two frames: a new window is hidden and auto-sized in its first, so a
        ;; second plot would be clipped.  Keep the colours of the last frame.
        (dotimes (frame 2)
         (setf first-plot nil second-plot nil)
         (with-test-frame ()
          (%imgui:set-next-window-size (vec2 400 500) 0)
          (gui:with-window ("w")
            (gui:with-plot ("one" :height 100)
              (dotimes (i 5)
                (gui:plot-lines (format nil "l~D" i) '(1 2 3))
                (push (item-color) first-plot)))
            (gui:with-plot ("two" :height 100)
              (gui:plot-bars "b" '(1 2 3))
              (push (item-color) second-plot)
              (gui:plot-scatter "s" '(1 2) '(3 4))
              (push (item-color) second-plot)))))
        (is (= 0 (%shim:assert-count)))))
    (let ((series (mapcar (lambda (c) (apply #'gui:color c))
                          (getf (gui::theme-palette (gui::find-theme :mid-light)) :series))))
      (is (= 4 (length series)))
      (is (equal (append series (list (first series))) (reverse first-plot)) "cycles through :series")
      (is (equal (subseq series 0 2) (reverse second-plot)) "restarts for each with-plot: ~S vs ~S" (reverse second-plot) (subseq series 0 2)))))
