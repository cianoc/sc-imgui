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

(defun click-item (draw-fn &key (x-fn (lambda (r) (/ (+ (first r) (third r)) 2))))
  "Prime DRAW-FN (which must use IN-WINDOW) so its item has a rect, then click
the item at X-FN of the rect.  Returns the list of DRAW-FN's values per frame."
  (setf *item-rect* nil)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn)))
  (let ((r *item-rect*))
    (frames-with-click (funcall x-fn r) (/ (+ (second r) (fourth r)) 2) draw-fn)))

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

(defun frames-with-drag (x y dx dy draw-fn)
  "Move to (X, Y), press, move by (DX, DY) while held, then release, calling
DRAW-FN once per frame; returns the list of its values (one per frame)."
  (let ((io (%imgui:get-io-nil)))
    (loop for event in (list (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                         io (float x 1.0f0) (float y 1.0f0)))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 t))
                             (lambda () (%imgui:im-gui-io-add-mouse-pos-event
                                         io (float (+ x dx) 1.0f0) (float (+ y dy) 1.0f0)))
                             (lambda () (%imgui:im-gui-io-add-mouse-button-event io 0 nil)))
          collect (progn (funcall event)
                         (with-test-frame () (funcall draw-fn))))))

(defun prime-and-drag (dx dy draw-fn)
  "Prime DRAW-FN (which must use IN-WINDOW) so its item has a rect, then drag
from the item's center by (DX, DY).  Returns DRAW-FN's values per frame."
  (setf *item-rect* nil)
  (dotimes (i 2) (with-test-frame () (funcall draw-fn)))
  (let ((r *item-rect*))
    (frames-with-drag (/ (+ (first r) (third r)) 2) (/ (+ (second r) (fourth r)) 2)
                      dx dy draw-fn)))
