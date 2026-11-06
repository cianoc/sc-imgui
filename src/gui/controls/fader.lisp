(in-package #:gui)

;;;; gui:fader: a bar slider filled in the accent colour from the value's
;;;; origin.  Horizontal (the default): label left and value right inside the
;;;; bar, filling the available width.  Vertical: label above, value below.
;;;; A fader drags along its own axis.

(defun fader-fill-rect (vertical lo hi x y w h)
  "Fill rectangle (x1 y1 x2 y2) of a fader whose bar is the rect at X Y of W x H,
spanning positions LO..HI in [0, 1] (LO <= HI): left to right when horizontal,
from the bottom up when VERTICAL."
  (if vertical
      (list x (- (+ y h) (* hi h)) (+ x w) (- (+ y h) (* lo h)))
      (list (+ x (* lo w)) y (+ x (* hi w)) (+ y h))))

(defun fader-bar-rect (vertical x y item-width len thickness line spacing)
  "The bar (x y w h) of a fader item at X Y, ITEM-WIDTH wide: the item itself
when horizontal (LEN by THICKNESS); when VERTICAL, THICKNESS wide and LEN tall,
centred in the item below the label LINE and SPACING."
  (if vertical
      (list (+ x (/ (- item-width thickness) 2)) (+ y line spacing) thickness len)
      (list x y len thickness)))

(defun fader-press-position (vertical bar mx my)
  "The position (0 at min, 1 at max) of the screen point MX MY along BAR
(x y w h): left to right when horizontal, bottom to top when VERTICAL."
  (destructuring-bind (x y w h) bar
    (if vertical
        (and (plusp h) (- 1 (/ (- my y) h)))
        (and (plusp w) (/ (- mx x) w)))))

(defun fader-value (label value &rest spec &key vertical ((:length len)) thickness
                    &allow-other-keys)
  "Draw a fader for VALUE under SPEC (the value control keywords) and return
(values new-value changed-p).  LEN (the :length key) and THICKNESS, the bar's
width across its axis, are in rem or (:px n); THICKNESS defaults to the frame
height, LEN to the available width (horizontal) or 8 rem (vertical).  A
vertical fader's item is 3.5 rem wide (or THICKNESS, if wider), with the bar
centred in it."
  (check-control-keys label spec :vertical :length :thickness)
  (check-control-sizes label :length len :thickness thickness)
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
      (let* ((spacing-y (item-spacing-y))
             (width (if vertical (max thickness (rem-px 3.5)) len))
             (height (if vertical
                         (+ line spacing-y len spacing-y frame-height)
                         thickness))
             (value-rect (if vertical
                             (list x (+ y line spacing-y len spacing-y) width frame-height)
                             (list (+ x (/ width 2)) (+ y (/ (- thickness frame-height) 2))
                                   (/ width 2) frame-height)))
             (bar (fader-bar-rect vertical x y width len thickness line spacing-y))
             (frame (control-behavior label spec value
                                      :width width :height height
                                      :axis (if vertical :vertical :horizontal)
                                      ;; A fader tracks the mouse 1:1 along its bar,
                                      ;; and a press jumps to the pressed point.
                                      :travel len
                                      :press-position (lambda (mx my)
                                                        (fader-press-position vertical bar mx my))
                                      :value-rect value-rect))
             (position (value->position spec (control-frame-value frame)))
             (origin (value->position spec (control-spec-origin spec)))
             (lo (min position origin))
             (hi (max position origin))
             (text-y (+ y (/ (- thickness line) 2)))
             (value-color (control-color (if (control-frame-active-p frame) :text :text-dim))))
        (destructuring-bind (bar-x bar-y bar-w bar-h) bar
          (draw-rect bar-x bar-y (+ bar-x bar-w) (+ bar-y bar-h)
                     (control-color (if (or (control-frame-hovered-p frame)
                                            (control-frame-active-p frame))
                                        :frame-hover :frame))
                     :filled t)
          (when (> hi lo)
            (destructuring-bind (x1 y1 x2 y2)
                (fader-fill-rect vertical lo hi bar-x bar-y bar-w bar-h)
              (draw-rect x1 y1 x2 y2 (control-color :accent) :filled t)))
          (if vertical
              (progn
                (when (plusp (length label-text))
                  (draw-clipped-centered-text x y width (control-color :text-dim) label-text))
                (unless (control-frame-editing-p frame)
                  (draw-clipped-centered-text
                   x (+ (second value-rect) (/ (- frame-height line) 2)) width value-color
                   (format-control-value spec (control-frame-value frame)))))
              (let ((pad (rem-px 0.4))
                    (half (/ width 2)))
                (%imgui:push-clip-rect (vec2 bar-x bar-y) (vec2 (+ bar-x bar-w) (+ bar-y bar-h)) t)
                (unwind-protect
                     (progn
                       (when (plusp (length label-text))
                         (draw-text (+ x pad) text-y (control-color :text) label-text))
                       (unless (control-frame-editing-p frame)
                         (let ((text (format-control-value spec (control-frame-value frame))))
                           (draw-text (max (+ x half) (- (+ x width) pad (text-width text))) text-y
                                      value-color text))))
                  (%imgui:pop-clip-rect)))))
        (if (control-frame-changed-p frame)
            (values (control-frame-value frame) t)
            (values value nil))))))

(define-value-control fader fader-value)
