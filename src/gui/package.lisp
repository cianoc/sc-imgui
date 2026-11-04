(defpackage #:gui
  (:use #:cl)
  (:shadow #:remove)
  (:import-from #:gui.runtime #:*debug-on-error*)
  (:export #:define-gui #:show #:hide #:remove #:call-in-gui-thread
           #:*debug-on-error*))
