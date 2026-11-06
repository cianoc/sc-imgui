(in-package #:gui)

;;;; gui:number-box: Live's compact number field.  The formatted value sits
;;;; centered in a small frame box, with the label to its right.

(defun number-box-fit-width (spec like)
  "Box width that fits the formatted min, max and every choice, plus padding."
  (let ((strings (append (list (format-control-value
                                spec (coerce-like (control-spec-min spec) like))
                               (format-control-value
                                spec (coerce-like (control-spec-max spec) like)))
                         (control-spec-choices spec))))
    (+ (reduce #'max strings :key #'text-width)
       (* 2 (%style-x %imgui::frame-padding)))))

(defun number-box-value (label value &rest spec &key width &allow-other-keys)
  "Draw a number box for VALUE under SPEC (the value control keywords) and
return (values new-value changed-p).  WIDTH is the box's width in rem or
(:px n); by default it fits the longest value."
  (%check label value (if (get-properties spec '(:choices)) 'integer 'real))
  (let* ((spec (apply #'parse-control-spec label value
                      (alexandria:remove-from-plist spec :width)))
         (height (%imgui:get-frame-height))
         (box-width (if width (rem-px width) (number-box-fit-width spec value)))
         (label-text (visible-label label))
         (label-width (text-width label-text))
         (gap (if (plusp label-width) (%style-x %imgui::item-inner-spacing) 0.0)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (let* ((frame (control-behavior label spec value
                                      :width (+ box-width gap label-width) :height height
                                      :value-rect (list x y box-width height)))
             (text-y (+ y (/ (- height (%imgui:get-font-size)) 2))))
        ;; While editing, the core's text field (already drawn) is the box.
        (unless (control-frame-editing-p frame)
          (draw-rect x y (+ x box-width) (+ y height)
                     (control-color (if (control-frame-hovered-p frame) :frame-hover :frame))
                     :filled t :rounding (%style-value %imgui::frame-rounding))
          (let* ((text (format-control-value spec (control-frame-value frame)))
                 (slack (- box-width (text-width text)))
                 (text-x (+ x (if (minusp slack)
                                  (min (%style-x %imgui::frame-padding) (/ box-width 2))
                                  (/ slack 2)))))
            (%imgui:push-clip-rect (vec2 x y) (vec2 (+ x box-width) (+ y height)) t)
            (unwind-protect
                 (draw-text text-x text-y
                            (control-color (if (control-frame-active-p frame) :text :text-dim))
                            text)
              (%imgui:pop-clip-rect))))
        (when (plusp label-width)
          (draw-text (+ x box-width gap) text-y (control-color :text-dim) label-text))
        (if (control-frame-changed-p frame)
            (values (control-frame-value frame) t)
            (values value nil))))))

(define-value-control number-box number-box-value)
