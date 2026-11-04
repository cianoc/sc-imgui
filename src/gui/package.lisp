(defpackage #:gui
  (:use #:cl)
  (:shadow #:remove)
  (:export #:define-gui #:show #:hide #:remove #:call-in-gui-thread))
