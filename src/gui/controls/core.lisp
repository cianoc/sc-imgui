(in-package #:gui)

;;;; The control core: sizing in rem, theme colours that fade when disabled,
;;;; per-control state across frames, and the shared mouse interaction of
;;;; every value control (double-click reset, drag, wheel, Ctrl/Cmd-click).
;;;; GUI thread only.

;;; Style and IO access

(defmacro %style-value (slot)
  `(cffi:foreign-slot-value (%imgui:get-style) '(:struct %imgui::im-gui-style) ',slot))

(defmacro %style-x (slot)
  "The x of the ImVec2 style field SLOT."
  `(cffi:foreign-slot-value
    (cffi:foreign-slot-pointer (%imgui:get-style) '(:struct %imgui::im-gui-style) ',slot)
    '(:struct %imgui::im-vec2) '%imgui::x))

(defmacro %io-value (slot)
  `(cffi:foreign-slot-value (%imgui:get-io-nil) '(:struct %imgui::im-gui-io) ',slot))

(defun base-font-size ()
  "ImGui's style FontSizeBase, or *FONT-SIZE* while it is still 0 (a context
before its first frame)."
  (let ((base (%style-value %imgui::font-size-base)))
    (if (plusp base) base (float *font-size* 1.0))))

(defun rem-px (n)
  "Pixels for N rem at the current base font size; (:px n) is N pixels."
  (cond ((realp n) (* (float n 1.0) (base-font-size)))
        ((and (consp n) (eq (first n) :px) (= 2 (length n)) (realp (second n)))
         (float (second n) 1.0))
        (t (error "Bad size ~S: expected a number of rem or (:px n)" n))))

(defun text-width (string)
  "Width in pixels of STRING in the current font, hiding any ## suffix."
  (getf (%imgui:calc-text-size string nil t -1.0) '%imgui::x))

(defun visible-label (label)
  "LABEL without its ## suffix."
  (subseq label 0 (search "##" label)))

(defun control-color (role &optional (alpha 1.0))
  "The theme's colour for ROLE, packed, with its alpha multiplied by ALPHA and
by ImGui's style alpha (so it fades inside WITH-DISABLED as stock widgets do)."
  (let* ((packed (theme-color role))
         (a (* (/ (ldb (byte 8 24) packed) 255.0) alpha (%style-value %imgui::alpha))))
    (dpb (truncate (+ (* (max 0.0 (min 1.0 a)) 255.0) 0.5)) (byte 8 24) packed)))

;;; Per-control state

(defstruct control-state
  position     ; accumulated drag position in [0, 1], or NIL when not dragging
  edit-text    ; text of an open text field, or NIL
  edit-error   ; true when the field's text failed to parse
  (frame -1))  ; ImGui frame count when the control last drew

(defvar *control-states* (make-hash-table :test 'equal)
  "ImGui item ID to CONTROL-STATE, for controls mid-drag or mid-edit.")

(defvar *control-states-swept* nil
  "ImGui frame count of the last sweep of *CONTROL-STATES*.")

(defun sweep-control-states ()
  "Once per ImGui frame, with the left button up, drop every state not touched
in the previous frame or this one: its control vanished mid-interaction."
  (let ((frame (%imgui:get-frame-count)))
    (unless (eql frame *control-states-swept*)
      (setf *control-states-swept* frame)
      (unless (%imgui:is-mouse-down-nil 0)
        (loop for id being the hash-keys of *control-states* using (hash-value state)
              unless (<= (1- frame) (control-state-frame state) frame)
                do (remhash id *control-states*))))))

(defun ensure-control-state (id)
  (or (gethash id *control-states*)
      (setf (gethash id *control-states*)
            (make-control-state :frame (%imgui:get-frame-count)))))

(defun start-text-entry (id spec value)
  "Ctrl/Cmd-click on control ID showing VALUE under SPEC.  Typed entry is not
implemented yet, so the click does nothing; it never starts a drag."
  (declare (ignore id spec value))
  nil)

;;; Interaction

(defstruct control-frame
  x y width height value changed-p hovered-p active-p editing-p)

(defun finite-p (x)
  (and (= x x) (< (abs x) most-positive-single-float)))

(defun drag-delta (axis)
  "Mouse travel along AXIS since the last call, positive meaning increase (up
or right); 0 until the drag passes ImGui's threshold."
  (multiple-value-bind (dx dy) (mouse-drag-delta 0)
    (if (and (zerop dx) (zerop dy))
        0
        (progn
          ;; Reset only past the threshold: ImGui measures it from the click
          ;; position, which a reset moves.
          (reset-mouse-drag-delta 0)
          (ecase axis
            (:vertical (- dy))
            (:horizontal dx))))))

(defvar *wheel-residue* (cons nil 0)
  "(item-id . notches): wheel travel not yet turned into a step by the stepped
control last hovered.  Trackpads send fractions of a notch.")

(defun wheel-steps (id notches)
  "Whole steps for NOTCHES of wheel on stepped control ID, carrying the
fraction over to its next wheel event."
  (unless (eql (car *wheel-residue*) id)
    (setf *wheel-residue* (cons id 0)))
  (let ((total (+ (cdr *wheel-residue*) notches)))
    (multiple-value-bind (steps residue) (truncate total)
      (setf (cdr *wheel-residue*) residue)
      steps)))

(defun wheel-value (id spec value notches shift like)
  "VALUE moved by NOTCHES of the wheel on control ID: one step per whole notch
(fractions accumulate) for stepped specs, otherwise 1% (0.1% with SHIFT) of
the range."
  (let ((step (control-spec-step spec)))
    (if step
        (clamp-to-spec spec (snap-to-step spec (+ value (* (wheel-steps id notches) step)))
                       like)
        (position->value spec
                         (+ (value->position spec value) (* notches (if shift 0.001 0.01)))
                         like))))

(defun control-behavior (label spec value &key width height (axis :vertical) value-rect)
  "Reserve WIDTH x HEIGHT pixels at the cursor as one item named LABEL and
apply the shared interaction to VALUE under SPEC: double-click reset,
Ctrl/Cmd-click text entry (drawn in VALUE-RECT, (x y w h)), drag along AXIS,
then the wheel.  Returns a CONTROL-FRAME whose value is the new value, or VALUE
clamped for display when unchanged; CHANGED-P is true only when input changed
it.  Never writes anything."
  (declare (ignore value-rect))
  (sweep-control-states)
  (multiple-value-bind (x y) (cursor-screen-pos)
    (invisible-button label (max 1.0 width) (max 1.0 height))
    (let* ((id (%imgui:get-item-id))
           (frame-count (%imgui:get-frame-count))
           (hovered (item-hovered-p))
           (active (item-active-p))
           (shift (%io-value %imgui::key-shift))
           (state (gethash id *control-states*))
           (new (clamp-to-spec spec value))
           (input nil))
      (when state (setf (control-state-frame state) frame-count))
      ;; Double-click resets to the default.
      (when (and hovered (%imgui:is-mouse-double-clicked-nil 0))
        (setf new (clamp-to-spec spec (control-spec-default spec) value)
              input t))
      ;; A press starts text entry (Ctrl/Cmd held) or a drag.
      (when (%imgui:is-item-activated)
        (if (%io-value %imgui::key-ctrl)
            (start-text-entry id spec new)
            (setf state (ensure-control-state id)
                  (control-state-position state) (value->position spec new))))
      ;; Drag: accumulate the clamped, unsnapped position.
      (cond ((and active state (control-state-position state))
             (%imgui:set-mouse-cursor %imgui:+mouse-cursor-none+)
             (let ((delta (drag-delta axis))
                   (range (rem-px 10)))
               (when (and (/= 0 delta) (finite-p delta) (plusp range) (finite-p range))
                 (let ((position (max 0.0 (min 1.0 (+ (control-state-position state)
                                                      (/ (* delta (if shift 0.1 1.0))
                                                         range))))))
                   (setf (control-state-position state) position
                         new (position->value spec position value)
                         input t)))))
            ((and state (control-state-position state))
             ;; The drag ended.
             (setf (control-state-position state) nil)
             (unless (control-state-edit-text state)
               (remhash id *control-states*))))
      ;; Wheel while hovered; claim it so the window doesn't scroll.
      (when hovered
        (unless (eql (car *wheel-residue*) id)
          (setf *wheel-residue* (cons id 0)))
        (%imgui:set-item-key-owner-nil %imgui:+key-mouse-wheel-y+)
        (%imgui:set-item-key-owner-nil %imgui:+key-mouse-wheel-x+)
        (let ((notches (%io-value %imgui::mouse-wheel)))
          ;; Shift+wheel arrives as horizontal on macOS.
          (when (and shift (zerop notches))
            (setf notches (%io-value %imgui::mouse-wheel-h)))
          (when (and (/= 0 notches) (finite-p notches))
            (setf new (wheel-value id spec new notches shift value)
                  input t))))
      (make-control-frame
       :x x :y y :width width :height height
       :value new
       :changed-p (and input (/= new value))
       :hovered-p hovered :active-p active
       :editing-p (and state (control-state-edit-text state) t)))))

;;; Defining controls

(defmacro define-value-control (name value-function)
  "Define NAME as a macro (NAME label place &rest spec) calling VALUE-FUNCTION
with LABEL, PLACE's value and SPEC, writing a changed value back to PLACE and
returning true when it changed."
  `(define-place-widget ,name ,value-function))
