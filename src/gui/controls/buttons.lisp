(in-package #:gui)

;;;; gui:toggle and gui:trigger: rectangular buttons with a label, built on
;;;; one invisible button.  No value specification, wheel or typed entry.

(defun button-width (label width)
  "Pixels: WIDTH rem (or (:px n)), else the label's width plus 1 rem."
  (check-control-sizes label :width width)
  (max 1.0 (if width
               (rem-px width)
               (+ (text-width label) (rem-px 1)))))

(defun draw-button-face (x y width height lit hovered label)
  "Draw a button's rectangle and its label, centred and clipped."
  (let ((text (visible-label label)))
    (draw-rect x y (+ x width) (+ y height)
               (control-color (cond (lit :accent) (hovered :control-hover) (t :control)))
               :filled t :rounding (rem-px 0.15))
    (when (plusp (length text))
      (draw-clipped-centered-text x (+ y (/ (- height (%imgui:get-font-size)) 2)) width
                                  (control-color (if lit :accent-text :text)) text))))

(defun toggle-value (label value &key width)
  "Draw a toggle for the generalized boolean VALUE and return
(values new-value changed-p); a click flips it, written as T or NIL."
  (let ((width (button-width label width))
        (height (%imgui:get-frame-height)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (let* ((clicked (invisible-button label width height))
             (new (if clicked (not value) (and value t))))
        (draw-button-face x y width height new (item-hovered-p) label)
        (if clicked (values new t) (values value nil))))))

(define-place-widget toggle toggle-value)

(defun trigger (label &key width)
  "Draw a momentary button.  Returns (values pressed-p held-p released-p)."
  (let ((width (button-width label width))
        (height (%imgui:get-frame-height)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (invisible-button label width height)
      (let ((pressed (%imgui:is-item-activated))
            (held (%imgui:is-item-active))
            (released (%imgui:is-item-deactivated)))
        (draw-button-face x y width height held (item-hovered-p) label)
        (values pressed held released)))))
