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

;; Y of ImGui's ItemSpacing.
(defun item-spacing-y ()
  (cffi:foreign-slot-value
   (cffi:foreign-slot-pointer (%imgui:get-style) '(:struct %imgui::im-gui-style)
                              '%imgui::item-spacing)
   '(:struct %imgui::im-vec2) '%imgui::y))

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

(defun control-shade (role amount)
  "The theme's colour for ROLE, lightened toward white by AMOUNT (0 to 1) or,
when AMOUNT is negative, darkened toward black, packed and faded like
CONTROL-COLOR.  Derived from the theme, so it follows SET-THEME."
  (let* ((packed (control-color role))
         (target (if (plusp amount) 255 0))
         (k (min 1.0 (abs amount))))
    (flet ((channel (pos)
             (let ((c (ldb (byte 8 pos) packed)))
               (truncate (+ c (* k (- target c)) 0.5)))))
      (logior (channel 0) (ash (channel 8) 8) (ash (channel 16) 16)
              (ash (ldb (byte 8 24) packed) 24)))))

;;; Per-control state

(defstruct control-state
  position     ; accumulated drag position in [0, 1], or NIL when not dragging
  edit-text    ; text of an open text field, or NIL
  edit-opening ; the text the field opened with
  edit-error   ; true when the field's text failed to parse
  edit-buffer  ; foreign buffer of +EDIT-BUFFER-SIZE+ bytes behind the field
  edit-phase   ; :focus (asking for keyboard focus), :refocus (asked, after a
               ; failed Enter) or :active (field focused)
  moved        ; true once the current drag has moved the value
  double-click ; true when the current press was the second of a double-click
  click-at     ; ImGui time of a click whose action waits out the double-click
               ; time (open the text field, or jump), or NIL
  jump         ; position a press or pending click jumps to, or NIL
  (frame -1))  ; ImGui frame count when the control last drew

(defconstant +edit-buffer-size+ 64)

(defvar *control-states* (make-hash-table :test 'equal)
  "ImGui item ID to CONTROL-STATE, for controls mid-drag or mid-edit.")

(defvar *control-states-swept* nil
  "ImGui frame count of the last sweep of *CONTROL-STATES*.")

;;; Text field buffers are meaningless in a saved image: forget them (without
;;; freeing) so the sweep never frees a stale pointer after a restart.
(defun %reset-control-states ()
  (setf *control-states* (make-hash-table :test 'equal)
        *control-states-swept* nil))
(pushnew '%reset-control-states sb-ext:*save-hooks*)

(defun sweep-control-states ()
  "Once per ImGui frame, with the left button up, drop every state not touched
in the previous frame or this one: its control vanished mid-interaction."
  (let ((frame (%imgui:get-frame-count)))
    (unless (eql frame *control-states-swept*)
      (setf *control-states-swept* frame)
      (unless (%imgui:is-mouse-down-nil 0)
        (loop for id being the hash-keys of *control-states* using (hash-value state)
              unless (<= (1- frame) (control-state-frame state) frame)
                do (remove-control-state id))))))

(defun remove-control-state (id)
  "Drop ID's state, freeing its text field's buffer."
  (let ((state (gethash id *control-states*)))
    (when state
      (end-text-entry state)
      (remhash id *control-states*))))

(defun ensure-control-state (id)
  (or (gethash id *control-states*)
      (setf (gethash id *control-states*)
            (make-control-state :frame (%imgui:get-frame-count)))))

;;; Typed entry

(defun set-edit-buffer (state text)
  "Copy TEXT into STATE's buffer as UTF-8, dropping whole characters from the
end until it fits with its NUL."
  (let ((text (loop with octets = 0
                    for char across text
                    for code = (char-code char)
                    do (incf octets (cond ((< code #x80) 1) ((< code #x800) 2)
                                          ((< code #x10000) 3) (t 4)))
                    while (< octets +edit-buffer-size+)
                    count t into chars
                    finally (return (subseq text 0 chars)))))
    (cffi:lisp-string-to-foreign text (control-state-edit-buffer state) +edit-buffer-size+
                                 :encoding :utf-8)))

(defun start-text-entry (state text)
  "Open a text field on STATE showing TEXT."
  (unless (control-state-edit-buffer state)
    (setf (control-state-edit-buffer state) (cffi:foreign-alloc :uint8 :count +edit-buffer-size+)))
  (set-edit-buffer state text)
  (setf (control-state-edit-text state) (cffi:foreign-string-to-lisp
                                         (control-state-edit-buffer state) :encoding :utf-8)
        (control-state-edit-opening state) (control-state-edit-text state)
        (control-state-edit-error state) nil
        (control-state-edit-phase state) :focus))

(defun end-text-entry (state)
  "Close STATE's text field, if any, and free its buffer."
  (let ((buffer (control-state-edit-buffer state)))
    (when buffer
      (cffi:foreign-free buffer)))
  (setf (control-state-edit-buffer state) nil
        (control-state-edit-text state) nil
        (control-state-edit-opening state) nil
        (control-state-edit-error state) nil
        (control-state-edit-phase state) nil))

(defun text-entry (id state spec like value-rect)
  "Draw STATE's open text field over VALUE-RECT, (x y w h), for control ID and
handle its keys.  Returns :COMMIT and the parsed value (clamped and snapped
under SPEC, as LIKE's type) on a successful Enter, :CANCEL when the field
lost focus without one (Escape or a click elsewhere) or on Enter with the
text it opened with (which may be stale if code changed the value since),
else NIL."
  (destructuring-bind (x y w h) value-rect
    (set-cursor-screen-pos x y)
    (when (eq (control-state-edit-phase state) :focus)
      (%imgui:set-keyboard-focus-here 0))
    (%imgui:set-next-item-width (max 1.0 w))
    (let* ((buffer (control-state-edit-buffer state))
           (entered (%imgui:input-text (format nil "##edit~D" id) buffer +edit-buffer-size+
                                       ;; Select all on opening, but not on
                                       ;; refocusing after a failed Enter.
                                       (logior %imgui:+input-text-flags-enter-returns-true+
                                               (if (eq (control-state-edit-phase state) :refocus)
                                                   0
                                                   %imgui:+input-text-flags-auto-select-all+))
                                       (cffi:null-pointer) (cffi:null-pointer)))
           (active (%imgui:is-item-active))
           (text (cffi:foreign-string-to-lisp buffer :encoding :utf-8)))
      ;; Editing the text clears the error.
      (unless (string= text (control-state-edit-text state))
        (setf (control-state-edit-text state) text
              (control-state-edit-error state) nil))
      (cond ((and entered (string= text (control-state-edit-opening state)))
             (return-from text-entry :cancel))
            (entered
             (multiple-value-bind (parsed ok) (parse-control-text spec text)
               (when ok
                 (return-from text-entry
                   (values :commit (clamp-to-spec spec (snap-to-step spec parsed) like))))
               ;; Enter deactivated the field: keep it open, refocusing it
               ;; (-1 targets the field just drawn) so it is active again
               ;; next frame.
               (%imgui:set-keyboard-focus-here -1)
               (setf (control-state-edit-error state) t
                     (control-state-edit-phase state) :refocus)))
            (active
             (setf (control-state-edit-phase state) :active))
            ((eq (control-state-edit-phase state) :active)
             (return-from text-entry :cancel)))
      (when (control-state-edit-error state)
        (draw-rect x y (+ x w) (+ y h) (control-color :error)))
      nil)))

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

(defun %press-point (press-position mx my)
  "PRESS-POSITION's position for the screen point MX MY, clamped to [0, 1], or
NIL when it gives none."
  (let ((p (funcall press-position mx my)))
    (and p (finite-p p) (max 0.0 (min 1.0 (float p 1.0))))))

(defun control-behavior (label spec value
                         &key width height (axis :vertical) value-rect travel click-edits
                           press-position)
  "Reserve WIDTH x HEIGHT pixels at the cursor as one item named LABEL and
apply the shared interaction to VALUE under SPEC: double-click reset,
Ctrl/Cmd-click text entry (drawn over VALUE-RECT, (x y w h); without one,
Ctrl/Cmd-click does nothing), drag along AXIS (a full sweep takes TRAVEL
pixels, default 10 rem), then the wheel.  With CLICK-EDITS, a plain click
(press and release without moving the value) also opens the text field, once
ImGui's double-click time has passed without a second click.  With
PRESS-POSITION, a function of the mouse's screen x and y returning a position
in [0, 1] (or NIL), a press without Shift marks the pressed point: a drag
starts by jumping there, and a plain click jumps there once the double-click
time has passed (a double-click resets instead).  Returns a
CONTROL-FRAME whose value is the new value, or VALUE clamped for display when
unchanged; CHANGED-P is true only when input changed it.  Never writes
anything."
  (sweep-control-states)
  (multiple-value-bind (x y) (cursor-screen-pos)
    (let* ((id (%imgui:get-id-str label))
           (state (gethash id *control-states*))
           (editing (and state (control-state-edit-text state)))
           (new (clamp-to-spec spec value))
           (input nil))
      (when editing
        ;; The text field is submitted inside a group with the control's own
        ;; item, so the layout sees one item of the control's size.  It comes
        ;; first so it takes the mouse over the value.
        (%imgui:begin-group))
      (unwind-protect
           (progn
             (when editing
               (multiple-value-bind (outcome parsed)
                   (if value-rect (text-entry id state spec value value-rect) :cancel)
                 (when outcome
                   (end-text-entry state)
                   (unless (control-state-position state)
                     (remhash id *control-states*)
                     (setf state nil)))
                 (when (eq outcome :commit)
                   (setf new parsed input t)))
               (set-cursor-screen-pos x y))
             (invisible-button label (max 1.0 width) (max 1.0 height))
             (let ((frame-count (%imgui:get-frame-count))
                   (hovered (item-hovered-p))
                   (active (item-active-p))
                   (shift (%io-value %imgui::key-shift))
                   (ctrl (%io-value %imgui::key-ctrl)))
               (when state (setf (control-state-frame state) frame-count))
               ;; Double-click resets to the default; with Ctrl/Cmd held it
               ;; only opens the text field.
               (let ((double-click (and hovered (not ctrl)
                                        (%imgui:is-mouse-double-clicked-nil 0))))
                 (when double-click
                   (setf new (clamp-to-spec spec (control-spec-default spec) value)
                         input t))
                 ;; A pending click acts once the double-click time has
                 ;; passed -- jumping to its point, or opening the text field
                 ;; -- and a second click cancels it.
                 (when (and state (control-state-click-at state))
                   (cond (double-click
                          (setf (control-state-click-at state) nil
                                (control-state-jump state) nil))
                         ((> (- (%imgui:get-time) (control-state-click-at state))
                             (%io-value %imgui::mouse-double-click-time))
                          (let ((jump (control-state-jump state)))
                            (setf (control-state-click-at state) nil
                                  (control-state-jump state) nil)
                            (cond (jump
                                   (setf new (position->value spec jump value)
                                         input t))
                                  (value-rect
                                   (start-text-entry state (format-control-value spec new))))))))
                 (when (and double-click state)
                   (setf (control-state-double-click state) t)))
               ;; A press starts a drag, or with Ctrl/Cmd held opens the text
               ;; field (never a drag).
               (when (%imgui:is-item-activated)
                 (cond ((not ctrl)
                        (setf state (ensure-control-state id)
                              (control-state-position state) (value->position spec new)
                              (control-state-moved state) nil)
                        (if (%imgui:is-mouse-double-clicked-nil 0)
                            (setf (control-state-double-click state) t
                                  (control-state-click-at state) nil
                                  (control-state-jump state) nil)
                            ;; Mark the pressed point (not with Shift, which
                            ;; keeps fine relative movement); nothing jumps yet.
                            (setf (control-state-click-at state) nil
                                  (control-state-jump state)
                                  (and press-position (not shift)
                                       (multiple-value-call #'%press-point press-position
                                         (mouse-pos))))))
                       (value-rect
                        (setf state (ensure-control-state id))
                        (start-text-entry state (format-control-value spec new)))))
               ;; Drag: accumulate the clamped, unsnapped position.
               (cond ((and active state (control-state-position state))
                      (%imgui:set-mouse-cursor %imgui:+mouse-cursor-none+)
                      (let ((delta (drag-delta axis))
                            (range (or travel (rem-px 10))))
                        (when (and (/= 0 delta) (finite-p delta) (plusp range) (finite-p range))
                          (let ((position
                                  (if (control-state-jump state)
                                      ;; A moving press can't be a double-click:
                                      ;; jump to the point under the cursor now.
                                      (or (multiple-value-call #'%press-point press-position
                                            (mouse-pos))
                                          (control-state-jump state))
                                      (max 0.0 (min 1.0 (+ (control-state-position state)
                                                           (/ (* delta (if shift 0.1 1.0))
                                                              range)))))))
                            (setf (control-state-jump state) nil)
                            (setf (control-state-position state) position
                                  (control-state-moved state) t
                                  new (position->value spec position value)
                                  input t)))))
                     ((and state (control-state-position state))
                      ;; The drag ended.  A press that moved nothing and wasn't
                      ;; a double-click is a click: with CLICK-EDITS it opens
                      ;; the text field after the double-click time.
                      (setf (control-state-position state) nil)
                      (if (and (not (control-state-moved state))
                               (not (control-state-double-click state))
                               (or (control-state-jump state) (and click-edits value-rect)))
                          (setf (control-state-click-at state) (%imgui:get-time))
                          (progn (setf (control-state-jump state) nil)
                                 (unless (control-state-edit-text state)
                                   (remove-control-state id))))
                      (setf (control-state-double-click state) nil)))
               ;; A finished click that opened nothing leaves no state.
               (when (and state (not active) (not (control-state-position state))
                          (not (control-state-edit-text state))
                          (not (control-state-click-at state))
                          (gethash id *control-states*))
                 (remove-control-state id)
                 (setf state nil))
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
                :editing-p (and state (control-state-edit-text state) t))))
        (when editing (%imgui:end-group))))))

;;; Defining controls

(defmacro define-value-control (name value-function)
  "Define NAME as a macro (NAME label place &rest spec) calling VALUE-FUNCTION
with LABEL, PLACE's value and SPEC, writing a changed value back to PLACE and
returning true when it changed."
  `(define-place-widget ,name ,value-function))
