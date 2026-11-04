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
