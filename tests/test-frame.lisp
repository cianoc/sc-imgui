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
      (handler-bind ((error (lambda (c) (declare (ignore c))
                              (invoke-restart 'gui.runtime:disable-panel))))
        (frame))
      (is (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'bad))))))
