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
