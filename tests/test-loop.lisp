(in-package #:sc-imgui.tests)

;;; Frame loop start/stop.  Opening a real window is covered by tests/smoke.lisp
;;; (`make smoke`); these tests never open one.

(in-suite loop)

(test stop-when-not-running
  (is (null (gui:stop))))

(test not-running-by-default
  (is (not (gui:running-p))))

(test start-reports-open-failure
  ;; With a headless context open, the shim refuses to open a window.  On the
  ;; main thread (as under `make test`) START runs the loop synchronously, so
  ;; the failure is visible on return.  Elsewhere the loop would run later on
  ;; the main thread, after the headless context is gone, so skip.
  (if (not (trivial-main-thread:main-thread-p))
      (skip "not on the main thread")
      (let ((saved gui.runtime:*report-stream*)
            (out (make-string-output-stream)))
        (unwind-protect
             (with-headless-imgui ()
               (is (eq t (let ((*standard-output* out)) (gui:start))))
               (is (not (gui:running-p)))
               ;; The failed start must not tear down the headless context.
               (is (not (cffi:null-pointer-p (%imgui:get-current-context))))
               (let ((report (get-output-stream-string out)))
                 (is (search "LOOP failed" report))
                 (is (search "already open" report))))
          (setf gui.runtime:*report-stream* saved)))))
