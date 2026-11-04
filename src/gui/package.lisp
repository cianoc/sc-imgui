(defpackage #:gui
  (:use #:cl)
  (:shadow #:remove)
  (:import-from #:gui.runtime #:*debug-on-error*
                #:*ini-path* #:start #:stop #:running-p
                #:main-thread-busy)
  (:export #:define-gui #:show #:hide #:remove #:call-in-gui-thread
           #:*debug-on-error*
           #:start #:stop #:running-p #:*ini-path* #:main-thread-busy
           #:enum-flags #:with-window #:with-group #:with-child #:with-section
           #:with-id #:with-disabled #:with-style #:with-row #:with-grid
           #:same-line #:new-line #:separator #:spacing #:indent #:unindent
           #:set-next-item-width
           #:widget-value-error
           #:slider #:slider-value #:drag #:drag-value #:checkbox #:checkbox-value
           #:combo #:combo-value #:input-text #:input-text-value #:button #:text))
