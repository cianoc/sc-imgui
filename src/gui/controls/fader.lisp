(in-package #:gui)

;;;; gui:fader: a bar slider filled in the accent colour from the value's
;;;; origin.  Horizontal (the default): label left and value right inside the
;;;; bar, filling the available width.  Vertical: label above, value below.
;;;; A fader drags along its own axis.

(defun fader-value (label value &rest spec &key vertical ((:length len)) thickness
                    &allow-other-keys)
  "Draw a fader for VALUE under SPEC (the value control keywords) and return
(values new-value changed-p).  LEN (the :length key) and THICKNESS are in rem
or (:px n); THICKNESS defaults to the frame height, LEN to the available width
(horizontal) or 8 rem (vertical)."
  (%check label value (if (get-properties spec '(:choices)) 'integer 'real))
  (let* ((spec (apply #'parse-control-spec label value
                      (alexandria:remove-from-plist spec :vertical :length :thickness)))
         (frame-height (%imgui:get-frame-height))
         (thickness (if thickness (rem-px thickness) frame-height))
         (len (if len
                  (rem-px len)
                  (if vertical (rem-px 8) (max 1.0 (nth-value 0 (content-region-avail))))))
         (line (%imgui:get-font-size))
         (label-text (visible-label label)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (let* ((spacing-y (cffi:foreign-slot-value
                         (cffi:foreign-slot-pointer (%imgui:get-style)
                                                    '(:struct %imgui::im-gui-style)
                                                    '%imgui::item-spacing)
                         '(:struct %imgui::im-vec2) '%imgui::y))
             (width (if vertical thickness len))
             (height (if vertical
                         (+ line spacing-y len spacing-y frame-height)
                         thickness))
             (bar-y (if vertical (+ y line spacing-y) y))
             (bar-w width)
             (bar-h (if vertical len thickness))
             (value-rect (if vertical
                             (list x (+ bar-y bar-h spacing-y) width frame-height)
                             (list (+ x (/ width 2)) (+ y (/ (- thickness frame-height) 2))
                                   (/ width 2) frame-height)))
             (frame (control-behavior label spec value
                                      :width width :height height
                                      :axis (if vertical :vertical :horizontal)
                                      :value-rect value-rect))
             (position (value->position spec (control-frame-value frame)))
             (origin (value->position spec (control-spec-origin spec)))
             (lo (min position origin))
             (hi (max position origin))
             (text-y (+ y (/ (- thickness line) 2))))
        (draw-rect x bar-y (+ x bar-w) (+ bar-y bar-h)
                   (control-color (if (or (control-frame-hovered-p frame)
                                          (control-frame-active-p frame))
                                      :frame-hover :frame))
                   :filled t)
        (when (> hi lo)
          (if vertical
              (draw-rect x (- (+ bar-y bar-h) (* hi bar-h)) (+ x bar-w) (- (+ bar-y bar-h) (* lo bar-h))
                         (control-color :accent) :filled t)
              (draw-rect (+ x (* lo bar-w)) bar-y (+ x (* hi bar-w)) (+ bar-y bar-h)
                         (control-color :accent) :filled t)))
        (if vertical
            (progn
              (when (plusp (length label-text))
                (draw-clipped-centered-text x y width (control-color :text-dim) label-text))
              (unless (control-frame-editing-p frame)
                (draw-clipped-centered-text
                 x (+ (second value-rect) (/ (- frame-height line) 2)) width
                 (control-color (if (control-frame-active-p frame) :text :text-dim))
                 (format-control-value spec (control-frame-value frame)))))
            (let ((pad (rem-px 0.4))
                  (half (/ width 2)))
              (%imgui:push-clip-rect (vec2 x bar-y) (vec2 (+ x bar-w) (+ bar-y bar-h)) t)
              (unwind-protect
                   (progn
                     (when (plusp (length label-text))
                       (draw-text (+ x pad) text-y (control-color :text) label-text))
                     (unless (control-frame-editing-p frame)
                       (let ((text (format-control-value spec (control-frame-value frame))))
                         (draw-text (max (+ x half) (- (+ x width) pad (text-width text))) text-y
                                    (control-color :text) text))))
                (%imgui:pop-clip-rect))))
        (if (control-frame-changed-p frame)
            (values (control-frame-value frame) t)
            (values value nil))))))

(define-value-control fader fader-value)
