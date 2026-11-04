;;;; Foreign types shared by the hand-written and generated bindings.
(in-package #:sc-imgui.bindings)

;;; CFFI's :string rejects NIL, but many ImGui `const char*` arguments are
;;; optional (text_end, format, overlay, ...) and take NULL.  The generator
;;; uses this type for every `const char*` argument; returns stay :string.
;;;
;;; It subclasses CFFI's own string type (internal, but stable) rather than
;;; starting from scratch: calls with by-value struct arguments go through
;;; cffi-libffi, which translates arguments with an expansion CFFI defines
;;; for its string type only (an internal generic).  Inheriting it keeps
;;; strings translated and freed the same way on both call paths.

(cffi:define-foreign-type optional-string-type (cffi::foreign-string-type)
  ()
  (:simple-parser optional-string)
  (:documentation "A `const char*` argument: like CFFI :string (a Lisp string
is copied to a foreign string and freed after the call; a foreign pointer
passes through), and NIL passes NULL."))

(defmethod cffi:translate-to-foreign ((value null) (type optional-string-type))
  (values (cffi:null-pointer) nil))
