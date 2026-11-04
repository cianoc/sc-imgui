(defpackage #:sc-imgui.generator
  (:use #:cl)
  (:export #:load-model
           #:c-name->lisp-name
           #:c-type->cffi
           #:emit-forms
           #:forms-exports
           #:generate-bindings
           #:opaque-struct-warning
           #:opaque-struct-name
           #:opaque-struct-reason))
