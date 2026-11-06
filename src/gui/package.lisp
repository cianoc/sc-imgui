(defpackage #:gui
  (:use #:cl)
  (:shadow #:remove)
  (:import-from #:gui.runtime #:*debug-on-error*
                #:*ini-path* #:*fonts* #:*font-size* #:unknown-font
                #:start #:stop #:shutdown #:running-p
                #:main-thread-busy)
  (:export #:define-gui #:show #:hide #:remove #:call-in-gui-thread
           #:*debug-on-error*
           #:start #:stop #:shutdown #:running-p #:*ini-path* #:main-thread-busy
           #:*fonts* #:*font-size* #:with-font #:unknown-font
           #:*theme* #:define-theme #:set-theme #:set-font-size #:theme-color
           #:enum-flags #:with-window #:with-group #:with-child #:with-section
           #:with-id #:with-disabled #:with-style #:with-row #:with-grid
           #:same-line #:new-line #:separator #:spacing #:indent #:unindent
           #:set-next-item-width
           #:widget-value-error
           #:slider #:slider-value #:drag #:drag-value #:checkbox #:checkbox-value
           #:combo #:combo-value #:input-text #:input-text-value #:selectable #:selectable-value
           #:list-box #:list-box-value #:button #:text
           #:with-plot #:plot-lines #:plot-bars #:plot-scatter
           #:color #:window-draw-list #:draw-line #:draw-rect #:draw-circle
           #:draw-arc #:draw-polyline #:draw-text #:invisible-button
           #:item-hovered-p #:item-active-p #:cursor-screen-pos #:mouse-pos
           #:mouse-drag-delta #:content-region-avail #:set-cursor-screen-pos
           #:reset-mouse-drag-delta))
