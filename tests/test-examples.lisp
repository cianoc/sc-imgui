(in-package #:sc-imgui.tests)
(in-suite examples)

(defun run-example (file)
  (with-clean-registry ()
    (with-headless-imgui ()
      (let ((gui.runtime:*report-stream* (make-broadcast-stream)))
        (load (asdf:system-relative-pathname :sc-imgui (format nil "examples/~A" file)))
        (dotimes (i 3) (with-test-frame () (gui.runtime:draw-registered-guis)))
        (values (mapcar (lambda (e) (cons (gui.runtime:gui-entry-name e)
                                          (gui.runtime:gui-entry-failure e)))
                        (gui.runtime:registry-snapshot))
                (%shim:assert-count))))))

(test examples-run-cleanly
  (dolist (file '("hello.lisp" "layout.lisp" "plots.lisp" "custom-knob.lisp"))
    (multiple-value-bind (entries asserts) (run-example file)
      (is (plusp (length entries)) "~A registers no panels" file)
      (is (every (lambda (e) (null (cdr e))) entries) "~A has a failed panel" file)
      (is (= 0 asserts) "~A recorded ImGui asserts" file))))

(test error-recovery-example-fails-only-the-broken-panel
  (multiple-value-bind (entries asserts) (run-example "error-recovery.lisp")
    (is (= 1 (count-if #'cdr entries)))
    (is (= 0 asserts))))
