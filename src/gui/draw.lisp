(in-package #:gui)

;;; Draw-list primitives and interaction helpers.  Coordinates are screen-space
;;; reals; every draw function takes :draw-list (default: the window's).

(defun %f (x) (coerce x 'single-float))

(defun color (r g b &optional (a 1.0))
  "Packed ImU32 (ABGR byte order) from components clamped to 0-1, rounded the
way ImGui's IM_F32_TO_INT8_SAT does."
  (flet ((byte-of (v)
           (let ((v (max 0.0f0 (min 1.0f0 (%f v)))))
             (truncate (+ (* v 255.0f0) 0.5f0)))))
    (logior (byte-of r) (ash (byte-of g) 8) (ash (byte-of b) 16) (ash (byte-of a) 24))))

(defun window-draw-list ()
  (%imgui:get-window-draw-list))

(defun draw-line (x1 y1 x2 y2 color &key (thickness 1.0) (draw-list (window-draw-list)))
  (%imgui:im-draw-list-add-line draw-list (vec2 x1 y1) (vec2 x2 y2) color (%f thickness) 0)
  (values))

(defun draw-rect (x1 y1 x2 y2 color &key filled (rounding 0.0) (thickness 1.0)
                                      (draw-list (window-draw-list)))
  (if filled
      (%imgui:im-draw-list-add-rect-filled draw-list (vec2 x1 y1) (vec2 x2 y2) color
                                           (%f rounding) 0)
      (%imgui:im-draw-list-add-rect draw-list (vec2 x1 y1) (vec2 x2 y2) color
                                    (%f rounding) (%f thickness) 0))
  (values))

(defun draw-circle (cx cy radius color &key filled (segments 0) (thickness 1.0)
                                         (draw-list (window-draw-list)))
  (if filled
      (%imgui:im-draw-list-add-circle-filled draw-list (vec2 cx cy) (%f radius) color segments)
      (%imgui:im-draw-list-add-circle draw-list (vec2 cx cy) (%f radius) color segments
                                      (%f thickness) 0))
  (values))

(defun draw-arc (cx cy radius a-min a-max color &key (thickness 1.0) (segments 0)
                                                  (draw-list (window-draw-list)))
  "Stroke an arc from A-MIN to A-MAX radians."
  (%imgui:im-draw-list-path-arc-to draw-list (vec2 cx cy) (%f radius) (%f a-min) (%f a-max)
                                   segments)
  (%imgui:im-draw-list-path-stroke draw-list color (%f thickness) 0)
  (values))

(defun draw-polyline (points color &key closed (thickness 1.0) (draw-list (window-draw-list)))
  "POINTS is a flat list or vector x0 y0 x1 y1 ...  Fewer than two points draws
nothing; an odd count is an error."
  (let ((n (length points)))
    (when (oddp n)
      (error "draw-polyline: ~D coordinates is odd; points are x y pairs" n))
    (when (>= n 4)
      (let ((count (floor n 2))
            (array (cffi:foreign-alloc :float :count n)))
        (unwind-protect
             (progn
               (let ((i 0))
                 (map nil (lambda (v)
                            (setf (cffi:mem-aref array :float i) (%f v))
                            (incf i))
                      points))
               (%imgui:im-draw-list-add-polyline
                draw-list array count color (%f thickness)
                (if closed %imgui:+im-draw-flags-closed+ 0)))
          (cffi:foreign-free array)))))
  (values))

(defun draw-text (x y color string &key (draw-list (window-draw-list)))
  (%imgui:im-draw-list-add-text-vec2 draw-list (vec2 x y) color string nil)
  (values))

(defun invisible-button (id width height)
  "True on click."
  (%imgui:invisible-button id (vec2 width height) 0))

(defun item-hovered-p () (%imgui:is-item-hovered 0))
(defun item-active-p () (%imgui:is-item-active))

(defmacro %vec2-values (form)
  `(let ((v ,form)) (values (getf v '%imgui::x) (getf v '%imgui::y))))

(defun cursor-screen-pos () (%vec2-values (%imgui:get-cursor-screen-pos)))
(defun mouse-pos () (%vec2-values (%imgui:get-mouse-pos)))
(defun mouse-drag-delta (&optional (button 0))
  (%vec2-values (%imgui:get-mouse-drag-delta button -1.0f0)))
(defun content-region-avail () (%vec2-values (%imgui:get-content-region-avail)))

(defun set-cursor-screen-pos (x y)
  (%imgui:set-cursor-screen-pos (vec2 x y))
  (values))

(defun reset-mouse-drag-delta (&optional (button 0))
  (%imgui:reset-mouse-drag-delta button)
  (values))
