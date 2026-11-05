(in-package #:sc-imgui.tests)
(in-suite frame)

(defmacro with-frame-env (&body body)
  `(with-clean-registry ()
     (with-headless-imgui ()
       (flet ((frame () (with-test-frame () (gui.runtime:draw-registered-guis))))
         (declare (ignorable #'frame))
         ,@body))))

(test healthy-panel-is-called
  (with-frame-env
    (let ((n 0)) (gui:define-gui p () (incf n)) (frame) (is (= 1 n)))))

(test hidden-panel-is-skipped
  (with-frame-env
    (let ((n 0)) (gui:define-gui p () (incf n)) (gui:hide 'p) (frame) (is (= 0 n)))))

(test failing-panel-is-isolated
  (with-frame-env
    (let ((n 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
      (gui:define-gui bad () (error "boom"))
      (gui:define-gui good () (incf n))
      (frame) (frame)
      (is (typep (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)) 'simple-error))
      (is (= 2 n)))))

(test unbalanced-panel-does-not-break-next-frame
  (with-frame-env
    (let ((n 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
      (gui:define-gui bad () (%imgui:begin "x" (cffi:null-pointer) 0) (error "boom"))
      (gui:define-gui good () (incf n))
      (frame) (frame)
      (is (= 2 n))
      (%shim:clear-asserts))))

(test report-goes-to-captured-stream
  (with-frame-env
    (let ((gui.runtime:*report-stream* (make-string-output-stream)))
      (gui:define-gui bad () (error "boom-123"))
      (frame)
      (let ((out (get-output-stream-string gui.runtime:*report-stream*)))
        (is (search "BAD" out)) (is (search "boom-123" out))))))

(test retry-button-clears-failure
  (with-frame-env
    (let ((gui.runtime:*report-stream* (make-broadcast-stream)) (fail t))
      (gui:define-gui flaky () (when fail (error "once")))
      (frame) (frame)
      (setf fail nil)
      (destructuring-bind (x y) (gethash 'flaky gui.runtime::*retry-button-centers*)
        (frames-with-click x y #'gui.runtime:draw-registered-guis))
      (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'flaky)))))))

(test debug-on-error-offers-restarts
  (with-frame-env
    (let ((gui:*debug-on-error* t))
      (gui:define-gui bad () (error "boom"))
      ;; The panel error goes straight to the debugger; stand in for it.
      (let ((sb-ext:*invoke-debugger-hook*
              (lambda (c hook) (declare (ignore c hook))
                (invoke-restart 'gui.runtime:disable-panel))))
        (frame))
      (is (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad))))))

(defun debugger-hook-invoking (restart log)
  "An *INVOKE-DEBUGGER-HOOK* that records the restarts on offer in LOG (a cons
cell) and then invokes RESTART."
  (lambda (c hook)
    (declare (ignore hook))
    (setf (car log) (mapcar #'restart-name (compute-restarts c)))
    (invoke-restart restart)))

(defun frame-under-loop-handler (frame)
  "Call FRAME inside a handler like the frame loop's outer one, which would
report and close the window.  Returns true if that handler ran."
  (block outer
    (handler-bind ((error (lambda (c) (declare (ignore c))
                            (return-from outer t))))
      (funcall frame)
      nil)))

(test debug-on-error-bypasses-outer-handlers
  ;; Under the real loop an outer ERROR handler sits above the panels.  With
  ;; *DEBUG-ON-ERROR* the debugger must be reached (both restarts offered)
  ;; before that handler, which must never run.
  (dolist (restart '(gui.runtime:retry-panel gui.runtime:disable-panel))
    (with-frame-env
      (let ((gui:*debug-on-error* t)
            (log (list nil)))
        (gui:define-gui bad () (error "boom"))
        (let ((sb-ext:*invoke-debugger-hook* (debugger-hook-invoking restart log)))
          (is (not (frame-under-loop-handler #'frame))))
        (is (member 'gui.runtime:retry-panel (car log)))
        (is (member 'gui.runtime:disable-panel (car log)))
        (if (eq restart 'gui.runtime:disable-panel)
            (is (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)))
            (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)))))))))

;;; Redefining a panel refits its GUI:WITH-WINDOW windows to their contents.

(defvar *window-sizes* (make-hash-table :test 'equal)
  "Window title -> (width height), recorded inside the window each frame.")
(defvar *refit-widgets* 1 "Buttons drawn in the REFIT-A window.")
(defvar *refit-manual-size* nil "When set, REFIT-A sets this size once (Always).")

(defun record-window-size (title)
  (let ((size (%imgui:get-window-size)))
    (setf (gethash title *window-sizes*)
          (list (getf size '%imgui::x) (getf size '%imgui::y)))))

(defun window-size (title) (gethash title *window-sizes*))

(defun redefine-panel (form)
  "Evaluate a DEFINE-GUI FORM at run time, as re-evaluating it at the REPL does."
  (handler-bind ((warning #'muffle-warning)) (eval form)))

(defparameter *refit-a-form*
  '(gui:define-gui refit-a ()
    (gui:with-window ("refit-a")
      (dotimes (i *refit-widgets*)
        (%imgui:button (format nil "button number ~D" i) (vec2 0 0)))
      (when *refit-manual-size*
        (%imgui:set-window-size-vec2 (vec2 (first *refit-manual-size*)
                                           (second *refit-manual-size*))
                                     %imgui:+cond-always+)
        (setf *refit-manual-size* nil))
      (record-window-size "refit-a"))))

(defparameter *refit-b-form*
  '(gui:define-gui refit-b ()
    (gui:with-window ("refit-b")
      (%imgui:button "b" (vec2 0 0))
      (record-window-size "refit-b"))))

(defun run-frames (n) (dotimes (i n) (with-test-frame () (gui.runtime:draw-registered-guis))))

(test redefinition-refits-windows
  (with-frame-env
    (clrhash *window-sizes*)
    (let ((*refit-widgets* 1) (*refit-manual-size* nil))
      (redefine-panel *refit-a-form*)
      (redefine-panel *refit-b-form*)
      (run-frames 5)
      (let ((a0 (window-size "refit-a")) (b0 (window-size "refit-b")))
        (is (consp a0)) (is (consp b0))
        ;; More content alone does not resize an existing window ...
        (setf *refit-widgets* 8)
        (run-frames 3)
        (is (equal a0 (window-size "refit-a")))
        ;; ... but redefining its panel refits it once.
        (redefine-panel *refit-a-form*)
        (run-frames 3)
        (let ((a1 (window-size "refit-a")))
          (is (> (second a1) (second a0)) "height ~S should exceed ~S" a1 a0)
          (is (equal b0 (window-size "refit-b")) "unchanged panel's window moved: ~S -> ~S"
              b0 (window-size "refit-b"))
          (run-frames 5)
          (is (equal a1 (window-size "refit-a"))))
        ;; After the refit a manual size sticks.
        (setf *refit-manual-size* (list 300.0 150.0))
        (run-frames 5)
        (is (equal '(300.0 150.0) (window-size "refit-a")))
        (is (equal b0 (window-size "refit-b")))))))

(test fixed-failed-panel-refits
  (with-frame-env
    (clrhash *window-sizes*)
    (let ((*refit-widgets* 1) (*refit-manual-size* nil)
          (gui.runtime:*report-stream* (make-broadcast-stream)))
      (redefine-panel *refit-a-form*)
      (run-frames 3)
      (let ((a0 (window-size "refit-a")))
        (redefine-panel '(gui:define-gui refit-a () (error "broken")))
        (run-frames 2)
        (is (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'refit-a)))
        (setf *refit-widgets* 8)
        (redefine-panel *refit-a-form*)
        (run-frames 3)
        (is (> (second (window-size "refit-a")) (second a0)))))))

;;; Reporting must never signal, and non-error serious conditions are isolated.

(define-condition unprintable-condition (error) ()
  (:report (lambda (c s) (declare (ignore c s)) (error "report exploded"))))

(test unprintable-condition-fails-only-its-panel
  (with-frame-env
    (let ((n 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
      (gui:define-gui bad () (error 'unprintable-condition))
      (gui:define-gui good () (incf n))
      (finishes (frame))
      (is (= 1 n))
      (is (not (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad)))))
      (frame)
      (is (= 2 n)))))

(test dead-report-stream-does-not-break-frame
  (with-frame-env
    (let ((n 0)
          (gui.runtime:*report-stream* (make-string-output-stream))
          (*error-output* (make-string-output-stream)))
      (close gui.runtime:*report-stream*)
      (gui:define-gui bad () (error "boom"))
      (gui:define-gui good () (incf n))
      (finishes (frame))
      (is (= 1 n))
      ;; The report falls back to *error-output*.
      (is (search "boom" (get-output-stream-string *error-output*))))))

(defun %recurse (n) (+ 1 (%recurse (1+ n))))

(test runaway-recursion-is-isolated
  (with-frame-env
    (let ((n 0) (gui.runtime:*report-stream* (make-string-output-stream)))
      (gui:define-gui deep () (%recurse 0))
      (gui:define-gui good () (incf n))
      (frame)
      (is (= 1 n))
      (is (typep (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'deep))
                 'storage-condition))
      ;; The guard page is re-protected after unwinding: overflow again.
      (gui.runtime:clear-gui-failure 'deep)
      (frame)
      (is (= 2 n))
      (is (typep (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'deep))
                 'storage-condition))
      (is (search "DEEP" (get-output-stream-string gui.runtime:*report-stream*))))))
