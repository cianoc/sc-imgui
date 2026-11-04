(defpackage #:gui
  (:use #:cl)
  (:shadow #:remove)
  (:import-from #:gui.runtime #:*debug-on-error*
                #:*ini-path* #:start #:stop #:running-p)
  (:export #:define-gui #:show #:hide #:remove #:call-in-gui-thread
           #:*debug-on-error*
           #:start #:stop #:running-p #:*ini-path*))
