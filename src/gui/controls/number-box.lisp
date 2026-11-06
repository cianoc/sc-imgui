(in-package #:gui)

;;;; gui:number-box: Live's compact number field.  The formatted value sits
;;;; centered in a small frame box, with the label to its right.

(defparameter *number-box-samples* 20
  "Intervals across the range sampled when fitting a number box's width.")

(defun number-box-candidates (spec like)
  "Strings a number box under SPEC may display, for LIKE's type: every choice,
or the formatted min, max, unit boundaries and evenly spaced positions."
  (or (control-spec-choices spec)
      (let* ((min (control-spec-min spec))
             (max (control-spec-max spec))
             (boundaries (remove-if-not (lambda (v) (< min v max))
                                        (case (control-spec-unit spec)
                                          ((:hz :ms) '(999 1999/2))
                                          (:db '(-699/10 -99/10 -1/10)))))
             (values (append (list min max)
                             (mapcar (lambda (v) (coerce-like v like)) boundaries)
                             (loop for i from 0 to *number-box-samples*
                                   collect (position->value spec (/ i *number-box-samples*)
                                                            like)))))
        (mapcar (lambda (v) (format-control-value spec (coerce-like v like))) values))))

(defun widest-digit (string digit)
  "STRING with every decimal digit replaced by DIGIT."
  (map 'string (lambda (c) (if (digit-char-p c) digit c)) string))

(defvar *number-box-widths* (make-hash-table :test 'equal)
  "Fitted text width by (font, size, spec fields, LIKE's type).  Cleared when
it grows past 256 entries (closures for :format make keys churn).")

(defun number-box-text-width (spec like)
  "Width of the widest text a number box under SPEC may display.  Numbers are
measured with each digit replaced by the font's widest digit, so a value
sampled between two others with the same shape is covered."
  (let ((key (list (cffi:pointer-address (%imgui:get-font)) (%imgui:get-font-size)
                   (control-spec-min spec) (control-spec-max spec) (control-spec-scale spec)
                   (control-spec-step spec) (control-spec-choices spec)
                   (control-spec-unit spec) (control-spec-format spec)
                   (type-of (coerce-like 0 like)))))
    (or (gethash key *number-box-widths*)
        (let* ((strings (number-box-candidates spec like))
               (digit (if (control-spec-choices spec)
                          nil
                          (loop with best = #\0 with best-width = 0
                                for c across "0123456789"
                                for w = (text-width (string c))
                                when (> w best-width) do (setf best c best-width w)
                                finally (return best))))
               (width (loop for s in strings
                            maximize (text-width (if digit (widest-digit s digit) s)))))
          (when (> (hash-table-count *number-box-widths*) 256)
            (clrhash *number-box-widths*))
          (setf (gethash key *number-box-widths*) width)))))

(defun number-box-fit-width (spec like)
  "Box width that fits the widest value SPEC may display, plus padding."
  (+ (number-box-text-width spec like)
     (* 2 (%style-x %imgui::frame-padding))))

(defun number-box-value (label value &rest spec &key width &allow-other-keys)
  "Draw a number box for VALUE under SPEC (the value control keywords) and
return (values new-value changed-p).  WIDTH is the box's width in rem or
(:px n); by default it fits the longest value."
  (check-control-keys label spec :width)
  (check-control-sizes label :width width)
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
                                      :value-rect (list x y box-width height)
                                      :click-edits t))
             (text-y (+ y (/ (- height (%imgui:get-font-size)) 2))))
        ;; While editing, the core's text field (already drawn) is the box.
        (unless (control-frame-editing-p frame)
          (draw-rect x y (+ x box-width) (+ y height)
                     (control-color (if (or (control-frame-hovered-p frame)
                                             (control-frame-active-p frame))
                                         :frame-hover :frame))
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
          (draw-text (+ x box-width gap) text-y (control-color :text) label-text))
        (if (control-frame-changed-p frame)
            (values (control-frame-value frame) t)
            (values value nil))))))

(define-value-control number-box number-box-value)
