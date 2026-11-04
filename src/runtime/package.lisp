(defpackage #:gui.runtime
  (:use #:cl)
  (:export #:gui-entry #:make-gui-entry #:gui-entry-p
           #:gui-entry-name #:gui-entry-function-name
           #:gui-entry-visible #:gui-entry-failure
           #:register-gui #:unregister-gui #:find-gui
           #:set-gui-visible #:mark-gui-failed #:clear-gui-failure
           #:registry-snapshot #:%reset-registry
           #:enqueue-task #:run-queued-tasks
           #:*report-stream* #:report-error
           #:*debug-on-error* #:draw-registered-guis
           #:retry-panel #:disable-panel
           #:*ini-path* #:start #:stop #:running-p))
