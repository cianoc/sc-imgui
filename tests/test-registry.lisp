(in-package #:sc-imgui.tests)
(in-suite registry)

(test define-registers
  (with-clean-registry ()
    (gui:define-gui panel-a () nil)
    (is (eq 'panel-a (gui.runtime:gui-entry-function-name (gui.runtime:find-gui 'panel-a))))))

(test redefine-replaces-in-place
  (with-clean-registry ()
    (gui:define-gui panel-a () nil) (gui:define-gui panel-b () nil) (gui:define-gui panel-a () t)
    (is (equal '(panel-a panel-b)
               (mapcar #'gui.runtime:gui-entry-name (gui.runtime:registry-snapshot))))))

(test redefine-clears-failure
  (with-clean-registry ()
    (gui:define-gui panel-a () nil)
    (gui.runtime:mark-gui-failed 'panel-a (make-condition 'simple-error))
    (gui:define-gui panel-a () nil)
    (is (null (gui.runtime:gui-entry-failure (gui.runtime:find-gui 'panel-a))))))

(test hide-show-remove
  (with-clean-registry ()
    (gui:define-gui panel-a () nil)
    (gui:hide 'panel-a) (is (not (gui.runtime:gui-entry-visible (gui.runtime:find-gui 'panel-a))))
    (gui:show 'panel-a) (is (gui.runtime:gui-entry-visible (gui.runtime:find-gui 'panel-a)))
    (gui:remove 'panel-a) (is (null (gui.runtime:find-gui 'panel-a)))))

(test concurrent-registration                ; 8 threads x 100 names
  (with-clean-registry ()
    (mapc #'bt2:join-thread
          (loop for i below 8 collect
            (let ((i i)) (bt2:make-thread
                          (lambda () (dotimes (j 100)
                                       (gui.runtime:register-gui (cons i j) 'ignore)))))))
    (is (= 800 (length (gui.runtime:registry-snapshot))))))

(test task-queue-survives-errors
  (with-clean-registry ()
    (let ((gui.runtime:*report-stream* (make-string-output-stream)) (ran 0))
      (gui:call-in-gui-thread (lambda () (incf ran)))
      (gui:call-in-gui-thread (lambda () (error "boom")))
      (gui:call-in-gui-thread (lambda () (incf ran)))
      (is (= 3 (gui.runtime:run-queued-tasks)))
      (is (= 2 ran))
      (is (search "boom" (get-output-stream-string gui.runtime:*report-stream*)))
      (is (= 0 (gui.runtime:run-queued-tasks))))))

(define-condition unprintable-task-condition (error) ()
  (:report (lambda (c s) (declare (ignore c s)) (error "report exploded"))))

(test unprintable-task-condition-does-not-stop-later-tasks
  (with-clean-registry ()
    (gui.runtime::%reset-tasks)
    (let ((ran 0) (gui.runtime:*report-stream* (make-broadcast-stream)))
      (gui:call-in-gui-thread (lambda () (error 'unprintable-task-condition)))
      (gui:call-in-gui-thread (lambda () (incf ran)))
      (is (= 2 (gui.runtime:run-queued-tasks)))
      (is (= 1 ran)))))

(test define-gui-rejects-arguments
  (signals error (macroexpand-1 '(gui:define-gui x (a) nil))))

(test redefine-marks-refit
  (with-clean-registry ()
    (gui.runtime:register-gui 'panel-a 'panel-a)
    (is (null (gui.runtime:gui-refit-pending 'panel-a)) "first registration needs no refit")
    (gui.runtime:register-gui 'panel-a 'panel-a)
    (let ((first (gui.runtime:gui-refit-pending 'panel-a)))
      (is (not (null first)))
      ;; A redefinition while the old token is in use keeps its own refit.
      (gui.runtime:register-gui 'panel-a 'panel-a)
      (let ((second (gui.runtime:gui-refit-pending 'panel-a)))
        (is (not (eq first second)))
        (gui.runtime:clear-gui-refit 'panel-a first)
        (is (eq second (gui.runtime:gui-refit-pending 'panel-a)))
        (gui.runtime:clear-gui-refit 'panel-a second)
        (is (null (gui.runtime:gui-refit-pending 'panel-a)))))
    (is (null (gui.runtime:gui-refit-pending 'no-such-panel)))))
