(in-package #:gui)

;;;; gui:toggle and gui:trigger: rectangular buttons with a label, built on
;;;; one invisible button.  No value specification, wheel or typed entry.

(defun button-width (label width)
  "Pixels: WIDTH rem (or (:px n)), else the label's width plus 1 rem."
  (check-control-sizes label :width width)
  (max 1.0 (if width
               (rem-px width)
               (+ (text-width label) (rem-px 1)))))

(defconstant +bevel-light+ 0.45 "How far a button's light edge is lightened toward white.")
(defconstant +bevel-dark+ -0.35 "How far a button's dark edge is darkened toward black.")

(defun draw-button-face (x y width height lit hovered pressed label)
  "Draw a button's rectangle and its label, centred and clipped.  The edges
are bevelled: light along the top and left with dark along the bottom and
right, so it looks raised -- or swapped when PRESSED, with the label nudged
down and right, so it looks indented."
  (let* ((text (visible-label label))
         (face (cond (lit :accent) (hovered :control-hover) (t :control)))
         (rounding (rem-px 0.15))
         (edge (max 1.0 (float (round (rem-px 0.08)) 1.0)))
         (light (control-shade face +bevel-light+))
         (dark (control-shade face +bevel-dark+))
         (top-left (if pressed dark light))
         (bottom-right (if pressed light dark))
         (half (/ edge 2))
         (x2 (+ x width)) (y2 (+ y height))
         (nudge (if pressed 1.0 0.0)))
    (draw-rect x y x2 y2 (control-color face) :filled t :rounding rounding)
    (draw-line (+ x rounding) (+ y half) (- x2 rounding) (+ y half) top-left :thickness edge)
    (draw-line (+ x half) (+ y rounding) (+ x half) (- y2 rounding) top-left :thickness edge)
    (draw-line (+ x rounding) (- y2 half) (- x2 rounding) (- y2 half) bottom-right :thickness edge)
    (draw-line (- x2 half) (+ y rounding) (- x2 half) (- y2 rounding) bottom-right :thickness edge)
    (when (plusp (length text))
      (draw-clipped-centered-text (+ x nudge) (+ y nudge (/ (- height (%imgui:get-font-size)) 2))
                                  width (control-color (if lit :accent-text :text)) text))))

(defun toggle-value (label value &key width)
  "Draw a toggle for the generalized boolean VALUE and return
(values new-value changed-p); a click flips it, written as T or NIL."
  (let ((width (button-width label width))
        (height (%imgui:get-frame-height)))
    (multiple-value-bind (x y) (cursor-screen-pos)
      (let* ((clicked (invisible-button label width height))
             (new (if clicked (not value) (and value t))))
        ;; Pressed (indented) while on, or while the mouse is down on it.
        (draw-button-face x y width height new (item-hovered-p) (or new (item-active-p)) label)
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
        (draw-button-face x y width height held (item-hovered-p) held label)
        (values pressed held released)))))
