(in-package #:gui)

;;;; gui:knob: a 270-degree arc open at the bottom, the label above and the
;;;; formatted value below.  Its width is the diameter plus 0.5 rem whatever
;;;; the text, which is clipped at the item's edge.

(defconstant +knob-start-angle+ (* 0.75d0 pi)
  "ImGui angle (clockwise from +x) of the minimum, at the bottom left.")
(defconstant +knob-sweep+ (* 1.5d0 pi))

(defun knob-angle (position)
  (+ +knob-start-angle+ (* +knob-sweep+ position)))

(defun draw-clipped-centered-text (x y width color text)
  "Draw TEXT centered in the WIDTH pixels from X (left-aligned when wider),
clipped to them."
  (let ((slack (- width (text-width text))))
    (%imgui:push-clip-rect (vec2 x (- y 1.0)) (vec2 (+ x width) (+ y (%imgui:get-frame-height)))
                           t)
    (unwind-protect (draw-text (+ x (max 0.0 (/ slack 2))) y color text)
      (%imgui:pop-clip-rect))))

(defun knob-value (label value &rest spec &key (size 2.5) &allow-other-keys)
  "Draw a knob for VALUE under SPEC (the value control keywords) and return
(values new-value changed-p).  SIZE is the arc's diameter in rem or (:px n)."
  (%check label value (if (get-properties spec '(:choices)) 'integer 'real))
  (let* ((spec (apply #'parse-control-spec label value
                      (alexandria:remove-from-plist spec :size)))
         (diameter (rem-px size))
         (width (+ diameter (rem-px 0.5)))
         (line (%imgui:get-font-size))
         (value-height (%imgui:get-frame-height))
         (spacing (item-spacing-y))
         (height (+ line spacing diameter spacing value-height)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (let* ((value-y (+ y line spacing diameter spacing))
             (frame (control-behavior label spec value
                                      :width width :height height
                                      :value-rect (list x value-y width value-height)))
             (cx (+ x (/ width 2)))
             (cy (+ y line spacing (/ diameter 2)))
             (thickness (max 2.0 (* 0.12 diameter)))
             (radius (max 1.0 (- (/ diameter 2) (/ thickness 2))))
             (position (value->position spec (control-frame-value frame)))
             (origin (value->position spec (control-spec-origin spec)))
             (angle (knob-angle position))
             (origin-angle (knob-angle origin))
             (label-text (visible-label label)))
        (when (plusp (length label-text))
          (draw-clipped-centered-text x y width (control-color :text-dim) label-text))
        (draw-arc cx cy radius +knob-start-angle+ (+ +knob-start-angle+ +knob-sweep+)
                  (control-color (if (or (control-frame-hovered-p frame)
                                         (control-frame-active-p frame))
                                     :frame-hover :frame))
                  :thickness thickness :segments 32)
        (when (> (abs (- angle origin-angle)) 1d-4)
          (draw-arc cx cy radius (min angle origin-angle) (max angle origin-angle)
                    (control-color :accent) :thickness thickness :segments 32))
        (draw-line (+ cx (* 0.3 radius (cos angle))) (+ cy (* 0.3 radius (sin angle)))
                   (+ cx (* 0.9 radius (cos angle))) (+ cy (* 0.9 radius (sin angle)))
                   (control-color :text) :thickness (max 1.5 (* 0.5 thickness)))
        ;; While editing, the core's text field (already drawn) is the value.
        (unless (control-frame-editing-p frame)
          (draw-clipped-centered-text
           x (+ value-y (/ (- value-height line) 2)) width
           (control-color (if (control-frame-active-p frame) :text :text-dim))
           (format-control-value spec (control-frame-value frame))))
        (if (control-frame-changed-p frame)
            (values (control-frame-value frame) t)
            (values value nil))))))

(define-value-control knob knob-value)
