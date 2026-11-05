(in-package #:sc-imgui.generator)

(defun c-name->lisp-name (c-name prefix)
  "Strip PREFIX from C-NAME, split CamelCase into words joined by `-`, and
lowercase.  `_` becomes `-`.  An uppercase letter starts a new word after a
lowercase letter or digit, or when it ends a run of capitals that is followed
by a lowercase letter."
  (let* ((start (if (and prefix
                         (plusp (length prefix))
                         (>= (length c-name) (length prefix))
                         (string= prefix c-name :end2 (length prefix)))
                    (length prefix)
                    0))
         (name (subseq c-name start))
         (n (length name)))
    (with-output-to-string (out)
      (dotimes (i n)
        (let ((c (char name i)))
          (cond ((char= c #\_) (write-char #\- out))
                (t
                 (when (and (upper-case-p c) (plusp i))
                   (let ((prev (char name (1- i)))
                         (next (and (< (1+ i) n) (char name (1+ i)))))
                     (when (or (lower-case-p prev)
                               (digit-char-p prev)
                               (and (upper-case-p prev) next (lower-case-p next)))
                       (write-char #\- out))))
                 (write-char (char-downcase c) out))))))))

(defparameter *lisp-name-overrides* '()
  "Alist of (C-NAME . LISP-NAME) that replaces the naming rule for those C names.
LISP-NAME has the form C-NAME->LISP-NAME returns: no prefix, no `+...+' for a
constant, no `-raw' for a bool function (the generator adds those).  Applies to
functions, enum constants and structs.  Use it to resolve a
`binding-name-collision' deliberately: keep the established name and rename
the other C name, with a test in tests/test-generator.lisp.")

(defvar *used-overrides* nil
  "When a hash table, BINDING-LISP-NAME records in it each C name whose
override it applies.  GENERATE-BINDINGS binds it to find unused overrides.")

(defun binding-lisp-name (c-name prefix)
  "The Lisp name for C-NAME: its override, or C-NAME->LISP-NAME with PREFIX."
  (let ((override (assoc c-name *lisp-name-overrides* :test #'string=)))
    (cond (override
           (when *used-overrides* (setf (gethash c-name *used-overrides*) t))
           (cdr override))
          (t (c-name->lisp-name c-name prefix)))))
