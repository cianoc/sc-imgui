(in-package #:gui)

;;; ImPlot plots over Lisp float vectors.  Specialized vectors are pinned and
;;; handed to ImPlot without copying; other sequences are copied to single-float.

(defmacro with-plot ((title &key (width -1) (height 0) flags) &body body)
  "BeginPlot/EndPlot.  Unlike ImGui's End, EndPlot is only valid when BeginPlot
returned true, so BODY and EndPlot both run only then."
  (let ((open (gensym "OPEN")))
    `(let ((,open (%implot:begin-plot ,title (vec2 ,width ,height)
                                      ,(%flags-form "FLAGS" flags '#:%implot))))
       (when ,open
         (unwind-protect (progn ,@body) (%implot:end-plot))))))

(deftype %plot-single () '(simple-array single-float (*)))
(deftype %plot-double () '(simple-array double-float (*)))

(defun plot-data (sequence &optional (label "plot"))
  "SEQUENCE itself when it is a simple single- or double-float vector, else a
new single-float vector of its elements.  Non-reals signal an error naming LABEL."
  (typecase sequence
    ((or %plot-single %plot-double) sequence)
    (t (unless (typep sequence 'sequence)
         (error "Plot ~S: data must be a sequence of reals, got ~S" label sequence))
       (let* ((n (length sequence))
              (out (make-array n :element-type 'single-float))
              (i 0))
         (map nil (lambda (x)
                    (unless (realp x)
                      (error "Plot ~S: data contains the non-real ~S" label x))
                    (setf (aref out i) (coerce x 'single-float))
                    (incf i))
              sequence)
         out))))

(defun plot-spec (stride &optional (marker %implot:+marker-none+))
  "An ImPlotSpec (as a by-value plist) with ImPlot's defaults, STRIDE bytes and MARKER."
  (flet ((auto () (list '%imgui::x 0.0f0 '%imgui::y 0.0f0 '%imgui::z 0.0f0 '%imgui::w -1.0f0))
         (nullp () (cffi:null-pointer)))
    (list '%implot::line-color (auto) '%implot::line-colors (nullp)
          '%implot::line-weight 1.0f0
          '%implot::fill-color (auto) '%implot::fill-colors (nullp)
          '%implot::fill-alpha 1.0f0
          '%implot::marker marker '%implot::marker-size 4.0f0
          '%implot::marker-sizes (nullp)
          '%implot::marker-line-color (auto) '%implot::marker-line-colors (nullp)
          '%implot::marker-fill-color (auto) '%implot::marker-fill-colors (nullp)
          '%implot::size 4.0f0 '%implot::offset 0 '%implot::stride stride
          '%implot::flags 0)))

(defun plot-pair (label xs ys)
  "Validated (values XS YS) vectors of one element type; error naming LABEL if
the lengths differ.  Mixed element types both become single-float."
  (let ((xs (plot-data xs label)) (ys (plot-data ys label)))
    (unless (= (length xs) (length ys))
      (error "Plot ~S: xs has ~D elements but ys has ~D" label (length xs) (length ys)))
    (unless (equal (array-element-type xs) (array-element-type ys))
      (flet ((single (v) (if (typep v '%plot-single) v (plot-data (coerce v 'list) label))))
        (setf xs (single xs) ys (single ys))))
    (values xs ys)))

(defun plot-lines (label ys &key xs)
  "Line plot of YS (against XS, or against 0, 1, 2... when XS is nil)."
  (if xs
      (multiple-value-bind (xs ys) (plot-pair label xs ys)
        (unless (zerop (length ys))
          (etypecase ys
            (%plot-single
             (cffi:with-pointer-to-vector-data (px xs)
               (cffi:with-pointer-to-vector-data (py ys)
                 (%implot:plot-line-float-ptr-float-ptr
                  label px py (length ys) (plot-spec 4)))))
            (%plot-double
             (cffi:with-pointer-to-vector-data (px xs)
               (cffi:with-pointer-to-vector-data (py ys)
                 (%implot:plot-line-double-ptrdouble-ptr
                  label px py (length ys) (plot-spec 8))))))))
      (let ((ys (plot-data ys label)))
        (unless (zerop (length ys))
          (etypecase ys
            (%plot-single
             (cffi:with-pointer-to-vector-data (py ys)
               (%implot:plot-line-float-ptr-int
                label py (length ys) 1d0 0d0 (plot-spec 4))))
            (%plot-double
             (cffi:with-pointer-to-vector-data (py ys)
               (%implot:plot-line-double-ptr-int
                label py (length ys) 1d0 0d0 (plot-spec 8)))))))))

(defun plot-bars (label ys &key (bar-size 0.67))
  "Bar plot of YS at x = 0, 1, 2..."
  (let ((ys (plot-data ys label))
        (bar-size (float bar-size 1d0)))
    (unless (zerop (length ys))
      (etypecase ys
        (%plot-single
         (cffi:with-pointer-to-vector-data (py ys)
           (%implot:plot-bars-float-ptr-int
            label py (length ys) bar-size 0d0 (plot-spec 4))))
        (%plot-double
         (cffi:with-pointer-to-vector-data (py ys)
           (%implot:plot-bars-double-ptr-int
            label py (length ys) bar-size 0d0 (plot-spec 8))))))))

(defun plot-scatter (label xs ys)
  "Scatter plot of the points (XS[i], YS[i]), drawn with circle markers."
  (multiple-value-bind (xs ys) (plot-pair label xs ys)
    (unless (zerop (length ys))
      (etypecase ys
        (%plot-single
         (cffi:with-pointer-to-vector-data (px xs)
           (cffi:with-pointer-to-vector-data (py ys)
             (%implot:plot-scatter-float-ptr-float-ptr
              label px py (length ys) (plot-spec 4 %implot:+marker-circle+)))))
        (%plot-double
         (cffi:with-pointer-to-vector-data (px xs)
           (cffi:with-pointer-to-vector-data (py ys)
             (%implot:plot-scatter-double-ptrdouble-ptr
              label px py (length ys) (plot-spec 8 %implot:+marker-circle+)))))))))
