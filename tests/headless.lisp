(in-package #:sc-imgui.tests)

;;; Shared helpers for tests that run ImGui without a window.

(defmacro with-headless-imgui ((&key (width 800) (height 600)) &body body)
  `(progn
     (%shim:clear-asserts)
     (unless (zerop (%shim:headless-create ,width ,height))
       (error "headless-create failed: ~A" (%shim:last-error)))
     (unwind-protect
          (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
            ,@body)
       (%shim:headless-destroy))))

(defmacro with-test-frame (() &body body)
  "NewFrame, BODY, Render (even when BODY unwinds), with float traps masked."
  `(sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
     (%imgui:new-frame)
     (unwind-protect (progn ,@body)
       (%imgui:render))))

(defun vec2 (x y)
  "Plist form of a by-value ImVec2 argument."
  (list '%imgui::x (float x 1.0f0) '%imgui::y (float y 1.0f0)))

(defun vec4 (x y z w)
  "Plist form of a by-value ImVec4 argument."
  (list '%imgui::x (float x 1.0f0) '%imgui::y (float y 1.0f0)
        '%imgui::z (float z 1.0f0) '%imgui::w (float w 1.0f0)))

(defun last-item-center ()
  "Center of the last item, as (values x y)."
  (let ((min (%imgui:get-item-rect-min))
        (max (%imgui:get-item-rect-max)))
    (values (/ (+ (getf min '%imgui::x) (getf max '%imgui::x)) 2)
            (/ (+ (getf min '%imgui::y) (getf max '%imgui::y)) 2))))

(defun frames-with-click (x y draw-fn &key (warmup 0))
  "Click at (X, Y): run four frames (move, press, release, idle), calling
DRAW-FN once in each, and return the list of its values.  Input goes through
ImGui's IO event queue, queued before each frame so that frame consumes it.
WARMUP extra event-free frames run first (their values are dropped); use it
when DRAW-FN's windows first appear in this call, since a new window is hidden
for its first frame and cannot be hovered until the next."
  (let ((io (%imgui:get-io-nil)))
    (dotimes (i warmup)
      (with-test-frame () (funcall draw-fn)))
    (loop for event in (list (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                         io (float x 1.0f0) (float y 1.0f0)))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 t))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 nil))
                             nil)
          collect (progn (when event (funcall event))
                         (with-test-frame () (funcall draw-fn))))))

(defmacro with-clean-registry (() &body body)
  "Run BODY against an empty panel registry and task queue, resetting both
before and after."
  `(progn
     (gui.runtime:%reset-registry)
     (unwind-protect (progn ,@body)
       (gui.runtime:%reset-registry))))

(defmacro in-window (&body body)
  "Run BODY inside a window named \"w\", recording the last item's rect in
*ITEM-RECT* before the window closes.  Returns BODY's values."
  `(gui:with-window ("w")
     (multiple-value-prog1 (progn ,@body)
       (setf *item-rect* (last-item-rect)
             *item-width* (%imgui:calc-item-width)))))

(defvar *item-rect* nil "Rect recorded by IN-WINDOW, as (min-x min-y max-x max-y).")
(defvar *item-width* nil
  "Item width in effect at the end of the window body, recorded by IN-WINDOW.")

(defun last-item-rect ()
  "Rect of the last item, as (min-x min-y max-x max-y)."
  (let ((min (%imgui:get-item-rect-min))
        (max (%imgui:get-item-rect-max)))
    (list (getf min '%imgui::x) (getf min '%imgui::y)
          (getf max '%imgui::x) (getf max '%imgui::y))))

(defun click-item (draw-fn &key (x-fn (lambda (r) (/ (+ (first r) (third r)) 2)))
                                (clicker #'frames-with-click))
  "Prime DRAW-FN (which must use IN-WINDOW) so its item has a rect, then click
the item at X-FN of the rect.  CLICKER, a function of x, y and DRAW-FN, does
the clicking (FRAMES-WITH-DOUBLE-CLICK, or a closure over FRAMES-WITH-WHEEL).
Returns its value: by default the list of DRAW-FN's values per frame."
  (setf *item-rect* nil)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn)))
  (let ((r *item-rect*))
    (funcall clicker (funcall x-fn r) (/ (+ (second r) (fourth r)) 2) draw-fn)))

(defun click-item-at-right-edge (draw-fn)
  "Click the item's frame 2 pixels in from its right edge.  The item rect also
covers the label, so the frame's edge is min-x plus the item width."
  (click-item draw-fn :x-fn (lambda (r) (- (+ (first r) *item-width*) 2))))

(defun type-text (string draw-fn)
  "Queue STRING as typed characters and run two frames of DRAW-FN."
  (%imgui:im-gui-io-add-input-characters-utf8 (%imgui:get-io-nil) string)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn))))

(defun vtx-count (draw-list)
  "Number of vertices in DRAW-LIST's VtxBuffer."
  (cffi:foreign-slot-value
   (cffi:foreign-slot-pointer draw-list '(:struct %imgui::im-draw-list) '%imgui::vtx-buffer)
   '(:struct %imgui::im-vector-im-draw-vert) '%imgui::size))

(defun vtx-colors (draw-list &optional (start 0))
  "The packed colours of DRAW-LIST's vertices from index START to the end."
  (let* ((vector (cffi:foreign-slot-pointer draw-list '(:struct %imgui::im-draw-list)
                                            '%imgui::vtx-buffer))
         (size (cffi:foreign-slot-value vector '(:struct %imgui::im-vector-im-draw-vert)
                                        '%imgui::size))
         (data (cffi:foreign-slot-value vector '(:struct %imgui::im-vector-im-draw-vert)
                                        '%imgui::data))
         (stride (cffi:foreign-type-size '(:struct %imgui::im-draw-vert))))
    (loop for i from start below size
          collect (cffi:foreign-slot-value (cffi:inc-pointer data (* i stride))
                                           '(:struct %imgui::im-draw-vert) '%imgui::col))))

(defun vtx-points (draw-list &optional (start 0))
  "(x y colour) of DRAW-LIST's vertices from index START to the end."
  (let* ((vector (cffi:foreign-slot-pointer draw-list '(:struct %imgui::im-draw-list)
                                            '%imgui::vtx-buffer))
         (size (cffi:foreign-slot-value vector '(:struct %imgui::im-vector-im-draw-vert)
                                        '%imgui::size))
         (data (cffi:foreign-slot-value vector '(:struct %imgui::im-vector-im-draw-vert)
                                        '%imgui::data))
         (stride (cffi:foreign-type-size '(:struct %imgui::im-draw-vert))))
    (loop for i from start below size
          for v = (cffi:inc-pointer data (* i stride))
          for pos = (cffi:foreign-slot-pointer v '(:struct %imgui::im-draw-vert) '%imgui::pos)
          collect (list (cffi:foreign-slot-value pos '(:struct %imgui::im-vec2) '%imgui::x)
                        (cffi:foreign-slot-value pos '(:struct %imgui::im-vec2) '%imgui::y)
                        (cffi:foreign-slot-value v '(:struct %imgui::im-draw-vert) '%imgui::col)))))

(defmacro control-colors (&body body)
  "Run BODY (drawing inside a window) and return the packed colours of the
vertices it added to the window's draw list."
  (let ((dl (gensym "DL")) (start (gensym "START")))
    `(let* ((,dl (gui:window-draw-list))
            (,start (vtx-count ,dl)))
       ,@body
       (vtx-colors ,dl ,start))))

(defun %modifier-key (modifier)
  "The key to queue for MODIFIER.  :CTRL is whatever ImGui reports as
io.KeyCtrl: with io.ConfigMacOSXBehaviors (the macOS default) AddKeyEvent
swaps Ctrl and Super, so Cmd (Super) arrives as Ctrl."
  (ecase modifier
    (:shift %imgui:+mod-shift+)
    (:ctrl (if (cffi:foreign-slot-value (%imgui:get-io-nil) '(:struct %imgui::im-gui-io)
                                        '%imgui::config-mac-osx-behaviors)
               %imgui:+mod-super+
               %imgui:+mod-ctrl+))))

(defmacro with-keys-held ((&rest modifiers) &body body)
  "Queue key-down events for MODIFIERS (:shift, :ctrl) before BODY and key-up
events after it (even when BODY unwinds).  The events are consumed by the
next frame each precedes."
  (let ((mods (gensym "MODS")))
    `(let ((,mods (mapcar #'%modifier-key ',modifiers)))
       (dolist (key ,mods) (%imgui:im-gui-io-add-key-event (%imgui:get-io-nil) key t))
       (unwind-protect (progn ,@body)
         (dolist (key ,mods) (%imgui:im-gui-io-add-key-event (%imgui:get-io-nil) key nil))))))

(defun frames-with-drag (x y dx dy draw-fn &key shift)
  "Move to (X, Y), press, move by (DX, DY) while held, then release, calling
DRAW-FN once per frame; returns the list of its values (one per frame).
SHIFT holds Shift throughout."
  (if shift
      (with-keys-held (:shift) (frames-with-drag x y dx dy draw-fn))
      (let ((io (%imgui:get-io-nil)))
        (loop for event in (list (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                             io (float x 1.0f0) (float y 1.0f0)))
                                 (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 t))
                                 (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                             io (float (+ x dx) 1.0f0) (float (+ y dy) 1.0f0)))
                                 (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 nil)))
              collect (progn (funcall event)
                             (with-test-frame () (funcall draw-fn)))))))

(defun frames-with-wheel (x y notches draw-fn &key shift horizontal)
  "Move to (X, Y) (one frame), then queue a vertical wheel of NOTCHES and run
two more frames (the first sees it in io.MouseWheel).  NOTCHES may also be a
list, one wheel event per frame (as a trackpad sends), followed by one idle
frame.  SHIFT holds Shift.  HORIZONTAL queues the notches on the horizontal
wheel instead (io.MouseWheelH), as macOS sends Shift+wheel.  Returns the list
of DRAW-FN's values per frame."
  (if shift
      (with-keys-held (:shift) (frames-with-wheel x y notches draw-fn :horizontal horizontal))
      (let ((io (%imgui:get-io-nil)))
        (loop for event in (append
                            (list (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                              io (float x 1.0f0) (float y 1.0f0))))
                            (mapcar (lambda (n)
                                      (lambda () (if horizontal
                                                     (%imgui:im-gui-io-add-mouse-wheel-event
                                                      io (float n 1.0f0) 0.0f0)
                                                     (%imgui:im-gui-io-add-mouse-wheel-event
                                                      io 0.0f0 (float n 1.0f0)))))
                                    (if (listp notches) notches (list notches)))
                            (list nil))
              collect (progn (when event (funcall event))
                             (with-test-frame () (funcall draw-fn)))))))

(defun frames-with-double-click (x y draw-fn)
  "Move to (X, Y), press, release, press, release: one frame each.  Returns
the list of DRAW-FN's values per frame."
  (let ((io (%imgui:get-io-nil)))
    (loop for event in (list (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                         io (float x 1.0f0) (float y 1.0f0)))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 t))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 nil))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 t))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 nil)))
          collect (progn (funcall event)
                         (with-test-frame () (funcall draw-fn))))))

(defun drag-path (dys draw-fn &key between)
  "Prime DRAW-FN (which must use IN-WINDOW), move to its item's center (one
frame) and press (one frame); then for each DY in DYS call BETWEEN (if given)
with the step index, move vertically by DY from the previous position, and run
a frame; then release (one frame).  Returns DRAW-FN's values per frame."
  (setf *item-rect* nil)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn)))
  (let* ((io (%imgui:get-io-nil))
         (r *item-rect*)
         (x (/ (+ (first r) (third r)) 2))
         (y (/ (+ (second r) (fourth r)) 2)))
    (flet ((frame () (with-test-frame () (funcall draw-fn)))
           (move () (%imgui:im-gui-io-add-mouse-pos-event io (float x 1.0f0) (float y 1.0f0))))
      (append
       (progn (move) (list (frame)))
       (progn (%imgui:im-gui-io-add-mouse-button-event io 0 t) (list (frame)))
       (loop for dy in dys
             for i from 0
             collect (progn (when between (funcall between i))
                            (incf y dy)
                            (move)
                            (frame)))
       (progn (%imgui:im-gui-io-add-mouse-button-event io 0 nil) (list (frame)))))))

(defun set-base-font-size (px)
  "Set ImGui's style FontSizeBase to PX (as GUI:SET-FONT-SIZE does on the GUI
thread), without reapplying the theme."
  (setf (cffi:foreign-slot-value (%imgui:get-style) '(:struct %imgui::im-gui-style)
                                 '%imgui::font-size-base)
        (float px 1.0)))

(defun prime-and-drag (dx dy draw-fn)
  "Prime DRAW-FN (which must use IN-WINDOW) so its item has a rect, then drag
from the item's center by (DX, DY).  Returns DRAW-FN's values per frame."
  (setf *item-rect* nil)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn)))
  (let ((r *item-rect*))
    (frames-with-drag (/ (+ (first r) (third r)) 2) (/ (+ (second r) (fourth r)) 2)
                      dx dy draw-fn)))

(defun bundled-font (file)
  "Native path of FILE in assets/fonts/."
  (uiop:native-namestring
   (asdf:system-relative-pathname :sc-imgui (format nil "assets/fonts/~A" file))))

(defun draw-some-text ()
  "One frame drawing a window with text, so the current font is used."
  (with-test-frame ()
    (gui:with-window ("w") (%imgui:text-unformatted "Inter 0123 Ag" (cffi:null-pointer)))))

(defmacro with-loaded-fonts ((&optional (fonts 'gui:*fonts*)) &body body)
  "Load FONTS (a *FONTS* plist, by default the bundled Inter fonts) into the
current headless context as the loop does at window creation, and run BODY
with that font table.  Without this, no fonts are loaded."
  `(let ((gui:*fonts* ,fonts)
         (gui.runtime::*font-table* nil))
     (gui.runtime::load-fonts)
     ,@body))

(defun current-font ()
  "The current font and size, as (address size)."
  (list (cffi:pointer-address (%imgui:get-font)) (%imgui:get-font-size)))

(defun press-key (key draw-fn)
  "Queue a key-down for KEY (an %IMGUI:+KEY-...+ constant), run a frame of
DRAW-FN, then queue its key-up and run another."
  (let ((io (%imgui:get-io-nil)))
    (%imgui:im-gui-io-add-key-event io key t)
    (with-test-frame () (funcall draw-fn))
    (%imgui:im-gui-io-add-key-event io key nil)
    (with-test-frame () (funcall draw-fn))))
