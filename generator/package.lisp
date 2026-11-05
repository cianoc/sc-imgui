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
           #:opaque-struct-reason
           #:*lisp-name-overrides*
           #:unused-name-override
           #:unused-override-c-name
           #:binding-name-collision
           #:binding-name-collisions
           #:collision-kind
           #:collision-lisp-name
           #:collision-c-names))
