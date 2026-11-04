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

(test define-gui-rejects-arguments
  (signals error (macroexpand-1 '(gui:define-gui x (a) nil))))
