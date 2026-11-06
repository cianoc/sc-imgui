(in-package #:gui)

;;;; gui:xy-pad: two values on one square, each with its own value
;;;; specification.  The label above, "<x> / <y>" below, the point in the
;;;; accent colour with crosshair lines through it.  Pressing moves the point
;;;; to the mouse and dragging follows it (y up = increasing); with Shift the
;;;; drag is relative and 10 times finer; double-click resets both axes.  No
;;;; wheel or typed entry.  Uses the core's state table (so the stale sweep
;;;; covers it) but not CONTROL-BEHAVIOR's drag.

(defparameter *xy-spec-keys*
  '(:min :max :scale :step :choices :bipolar :default :unit :format)
  "The keywords allowed in an :x or :y specification.")

(defstruct (xy-state (:include control-state))
  (px 0.0)   ; x position in [0, 1] of the point being dragged
  (py 0.0)   ; y position in [0, 1]
  frozen)    ; true after a double-click reset: no absolute following until release

(defun check-xy-spec-shape (label axis plist)
  "Signal CONTROL-SPEC-ERROR naming LABEL unless PLIST, the AXIS (:x or :y)
specification, is a proper plist of known value control keywords."
  (flet ((fail (string &rest args)
           (error 'control-spec-error
                  :label label
                  :problem (format nil "malformed ~S ~S: ~?" axis plist string args))))
    (unless (and (alexandria:proper-list-p plist) (evenp (length plist)))
      (fail "expected a property list"))
    (loop for key in plist by #'cddr
          unless (member key *xy-spec-keys*)
            do (fail "unknown keyword ~S" key))))

(defun parse-xy-axis-spec (label axis plist value)
  "PLIST parsed as the AXIS specification for VALUE; its errors name the axis."
  (handler-case (apply #'parse-control-spec label value plist)
    (control-spec-error (e)
      (error 'control-spec-error
             :label label
             :problem (format nil "~S: ~A" axis (control-spec-error-problem e))))))

(defun clamp01 (p)
  (max 0.0 (min 1.0 p)))

(defun xy-pad-value (label x-value y-value &key x y (size 8))
  "Draw an XY pad for X-VALUE under the specification plist X and Y-VALUE
under Y, and return (values new-x new-y changed-p).  An axis the user did not
change comes back as given (not clamped).  SIZE is the square's side in rem
or (:px n)."
  (check-xy-spec-shape label :x x)
  (check-xy-spec-shape label :y y)
  (%check label x-value (if (getf x :choices) 'integer 'real))
  (%check label y-value (if (getf y :choices) 'integer 'real))
  (let* ((x-spec (parse-xy-axis-spec label :x x x-value))
         (y-spec (parse-xy-axis-spec label :y y y-value))
         (side (rem-px size))
         (line (%imgui:get-font-size))
         (spacing (item-spacing-y))
         (height (+ line spacing side spacing line)))
    (sweep-control-states)
    (multiple-value-bind (x0 y0) (cursor-screen-pos)
      (let* ((id (%imgui:get-id-str label))
             (state (let ((s (gethash id *control-states*))) (and (xy-state-p s) s)))
             (sq-y (+ y0 line spacing))
             (new-x x-value)
             (new-y y-value))
        (invisible-button label (max 1.0 side) (max 1.0 height))
        (let ((hovered (item-hovered-p))
              (active (item-active-p))
              (shift (%io-value %imgui::key-shift))
              (ctrl (%io-value %imgui::key-ctrl)))
          (when state (setf (control-state-frame state) (%imgui:get-frame-count)))
          (flet ((move-to (px py)
                   ;; Recompute an axis only when its position moved, so an
                   ;; untouched axis keeps its exact value.
                   (unless (= px (xy-state-px state))
                     (setf (xy-state-px state) px
                           new-x (position->value x-spec px x-value)))
                   (unless (= py (xy-state-py state))
                     (setf (xy-state-py state) py
                           new-y (position->value y-spec py y-value)))))
            ;; A press starts tracking from the current point.
            (when (%imgui:is-item-activated)
              (setf state (make-xy-state
                           :frame (%imgui:get-frame-count)
                           :px (value->position x-spec x-value)
                           :py (value->position y-spec y-value))
                    (gethash id *control-states*) state))
            ;; Double-click resets both axes; with Ctrl/Cmd held it does nothing.
            (when (and hovered (not ctrl) (%imgui:is-mouse-double-clicked-nil 0))
              (setf new-x (clamp-to-spec x-spec (control-spec-default x-spec) x-value)
                    new-y (clamp-to-spec y-spec (control-spec-default y-spec) y-value))
              (when state
                (setf (xy-state-px state) (value->position x-spec new-x)
                      (xy-state-py state) (value->position y-spec new-y)
                      (xy-state-frozen state) t)))
            (cond ((and active state)
                   (%imgui:set-mouse-cursor %imgui:+mouse-cursor-none+)
                   (multiple-value-bind (dx dy) (mouse-drag-delta 0)
                     ;; Consume travel every frame, so a Shift pressed mid-drag
                     ;; only sees travel from then on.  Nonzero only past
                     ;; ImGui's threshold, measured from the click position.
                     (unless (and (zerop dx) (zerop dy))
                       (reset-mouse-drag-delta 0))
                     (cond (shift
                            (when (and (finite-p dx) (finite-p dy) (finite-p side) (plusp side))
                              (move-to (clamp01 (+ (xy-state-px state) (/ (* 0.1 dx) side)))
                                       (clamp01 (- (xy-state-py state) (/ (* 0.1 dy) side))))))
                           ((not (xy-state-frozen state))
                            (multiple-value-bind (mx my) (mouse-pos)
                              (when (and (finite-p mx) (finite-p my)
                                         (finite-p side) (plusp side))
                                (move-to (clamp01 (/ (- mx x0) side))
                                         (clamp01 (- 1 (/ (- my sq-y) side))))))))))
                  (state (remove-control-state id))))
          (draw-xy-pad label x-spec y-spec (clamp-to-spec x-spec new-x) (clamp-to-spec y-spec new-y)
                       x0 y0 side height sq-y (or hovered active) active))
        (values new-x new-y (or (/= new-x x-value) (/= new-y y-value)))))))

(defun draw-xy-pad (label x-spec y-spec x-value y-value x0 y0 side height sq-y hot active)
  "Draw the pad whose item is at X0 Y0, SIDE wide and HEIGHT high, its square
at SQ-Y, showing the in-range X-VALUE and Y-VALUE."
  (let* ((x1 (+ x0 side))
         (y1 (+ sq-y side))
         (px (+ x0 (* side (value->position x-spec x-value))))
         (py (- y1 (* side (value->position y-spec y-value))))
         (line (%imgui:get-font-size))
         (label-text (visible-label label)))
    (when (plusp (length label-text))
      (draw-clipped-centered-text x0 y0 side (control-color :text-dim) label-text))
    (draw-rect x0 sq-y x1 y1 (control-color (if hot :frame-hover :frame)) :filled t)
    (loop for i from 1 to 3
          for f = (* side (/ i 4))
          do (draw-line (+ x0 f) sq-y (+ x0 f) y1 (control-color :border))
             (draw-line x0 (+ sq-y f) x1 (+ sq-y f) (control-color :border)))
    (draw-line px sq-y px y1 (control-color :text-dim 0.6))
    (draw-line x0 py x1 py (control-color :text-dim 0.6))
    ;; Clip the point to the item's rect, which it would overhang at an edge.
    (%imgui:push-clip-rect (vec2 x0 y0) (vec2 x1 (+ y0 height)) t)
    (unwind-protect (draw-circle px py (rem-px 0.25) (control-color :accent) :filled t)
      (%imgui:pop-clip-rect))
    (draw-clipped-centered-text
     x0 (+ y1 (item-spacing-y)) side
     (control-color (if active :text :text-dim))
     (format nil "~A / ~A" (format-control-value x-spec x-value)
             (format-control-value y-spec y-value)))
    (values)))

(defmacro xy-pad (label x-place y-place &rest args &environment env)
  "Draw an XY pad for X-PLACE and Y-PLACE (see XY-PAD-VALUE for ARGS: the
evaluated spec plists :x and :y, and :size).  Writes each place the user
changed and returns true if either changed."
  (multiple-value-bind (xvars xvals xstores xsetter xgetter) (get-setf-expansion x-place env)
    (multiple-value-bind (yvars yvals ystores ysetter ygetter) (get-setf-expansion y-place env)
      (let ((old-x (gensym "OLD-X")) (old-y (gensym "OLD-Y"))
            (new-x (gensym "NEW-X")) (new-y (gensym "NEW-Y"))
            (changed (gensym "CHANGED")))
        `(let* (,@(mapcar #'list xvars xvals)
                ,@(mapcar #'list yvars yvals)
                (,old-x ,xgetter)
                (,old-y ,ygetter))
           (multiple-value-bind (,new-x ,new-y ,changed)
               (xy-pad-value ,label ,old-x ,old-y ,@args)
             (when ,changed
               (unless (eql ,new-x ,old-x)
                 (let ((,(first xstores) ,new-x)) ,xsetter))
               (unless (eql ,new-y ,old-y)
                 (let ((,(first ystores) ,new-y)) ,ysetter)))
             ,changed))))))
