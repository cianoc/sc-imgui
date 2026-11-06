(defpackage #:gui.runtime
  (:use #:cl)
  (:export #:gui-entry #:make-gui-entry #:gui-entry-p
           #:gui-entry-name #:gui-entry-function-name
           #:gui-entry-visible #:gui-entry-failure
           #:register-gui #:unregister-gui #:find-gui
           #:set-gui-visible #:mark-gui-failed #:clear-gui-failure
           #:gui-entry-refit #:gui-refit-pending #:clear-gui-refit #:*refit-windows*
           #:registry-snapshot #:%reset-registry
           #:enqueue-task #:run-queued-tasks
           #:*report-stream* #:report-error
           #:*debug-on-error* #:draw-registered-guis
           #:retry-panel #:disable-panel
           #:*ini-path* #:*fonts* #:*font-size* #:font-index
           #:unknown-font #:unknown-font-name #:unknown-font-loaded
           #:start #:stop #:shutdown #:running-p #:wake-loop
           #:main-thread-busy))
