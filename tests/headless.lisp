(in-package #:sc-imgui.tests)

;;; Shared helpers for tests that run ImGui without a window.

(defmacro with-headless-imgui ((&key (width 800) (height 600)) &body body)
  `(progn
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
