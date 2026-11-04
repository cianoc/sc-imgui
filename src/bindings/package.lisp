;;;; Packages for the foreign bindings.  %imgui and %implot use nothing and
;;;; export nothing here: the generated files export their own symbols.

(defpackage #:sc-imgui.bindings
  (:use #:cl)
  (:export #:optional-string
           #:*library-search-paths*
           #:load-shim-library
           #:shim-library-not-found
           #:shim-library-not-found-paths))

(defpackage #:%shim
  (:use)
  (:export #:open-window #:should-close #:begin-frame #:end-frame #:shutdown
           #:last-error #:headless-create #:headless-destroy
           #:assert-count #:last-assert #:clear-asserts
           #:onscreen-window-count #:test-perform-close))

(defpackage #:%imgui (:use))

(defpackage #:%implot (:use))
