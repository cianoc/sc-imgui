(in-package #:sc-imgui.generator)

(define-condition opaque-struct-warning (warning)
  ((name :initarg :name :reader opaque-struct-name)
   (reason :initarg :reason :reader opaque-struct-reason))
  (:report (lambda (c stream)
             (format stream "Emitting ~A as an opaque struct: ~A"
                     (opaque-struct-name c) (opaque-struct-reason c)))))

(defun ensure-package (designator)
  (or (find-package designator)
      (make-package designator :use nil)))

(defun field-lisp-name (c-name)
  "Slot name for the C field C-NAME, without any `[n]` array suffix."
  (c-name->lisp-name (subseq c-name 0 (position #\[ c-name)) ""))

(defun storage-type (cffi-type)
  "CFFI `:bool` is int-sized; C `bool` is one byte.  Use a one-byte boolean for
struct slots (layout) and for return values (no garbage upper bits)."
  (subst '(:boolean :uchar) :bool cffi-type))

(defun struct-type-p (cffi-type)
  (and (consp cffi-type) (eq (first cffi-type) :struct)))

(defun build-structs (structs typedefs package external-structs)
  "Resolve every struct to complete or opaque.  Returns (values lookup forms)
where LOOKUP maps a struct name to its symbol when complete, and FORMS are the
defcstruct forms, a struct used by value always after the structs it contains."
  (let ((defs (make-hash-table :test 'equal))
        (state (make-hash-table :test 'equal))
        (forms '())
        (opaque '()))
    (dolist (s structs) (setf (gethash (getf s :name) defs) s))
    (labels ((external (name)
               (cdr (assoc name external-structs :test #'string=)))
             (lookup (name)
               (cond ((gethash name defs)
                      (resolve name)
                      (and (eq (gethash name state) :complete)
                           (struct-type-symbol name)))
                     (t (external name))))
             (resolve (name)
               (unless (gethash name state)
                 (setf (gethash name state) :busy)
                 (multiple-value-bind (slots reason)
                     (struct-slots (gethash name defs))
                   (let ((symbol (struct-type-symbol name)))
                     (cond (reason
                            (setf (gethash name state) :opaque)
                            (push (cons name reason) opaque)
                            (push `(cffi:defcstruct ,symbol) forms))
                           (t
                            (setf (gethash name state) :complete)
                            (push `(cffi:defcstruct ,symbol ,@slots) forms)))))))
             (struct-slots (def)
               (let ((slots '()) (seen '()))
                 (dolist (f (getf def :fields))
                   (let* ((cname (getf f :name))
                          (array-p (find #\[ cname))
                          (type (and (not (getf f :bitfield-p))
                                     (not (and array-p (null (getf f :size))))
                                     (c-type->cffi (getf f :type) typedefs
                                                   :structs #'lookup)))
                          (slot (field-lisp-name cname)))
                     (cond ((getf f :bitfield-p)
                            (return-from struct-slots
                              (values nil (format nil "bitfield member ~A" cname))))
                           ((null type)
                            (return-from struct-slots
                              (values nil (format nil "unmappable type ~S for ~A"
                                                  (getf f :type) cname))))
                           ((member slot seen :test #'string=)
                            (return-from struct-slots
                              (values nil (format nil "duplicate slot name ~A" slot)))))
                     (push slot seen)
                     (push `(,(intern (string-upcase slot) package)
                             ,(storage-type type)
                             ,@(when array-p `(:count ,(getf f :size))))
                           slots)))
                 (values (nreverse slots) nil))))
      (dolist (s structs) (resolve (getf s :name)))
      (values #'lookup (nreverse forms) (nreverse opaque)
              (loop for s in structs
                    for name = (getf s :name)
                    when (eq (gethash name state) :complete)
                      collect (cons name (struct-type-symbol name)))))))

(defun emit-function (f prefix package lookup typedefs)
  "Return a defcfun form for F, or (values nil reason) when it is skipped."
  (when (getf f :variadic-p)
    (return-from emit-function (values nil "variadic")))
  (when (getf f :templated-p)
    (return-from emit-function (values nil "templated")))
  (let ((ret (c-type->cffi (getf f :ret) typedefs :structs lookup))
        (args (loop for (name type) in (getf f :args)
                    collect (list name type
                                  (c-type->cffi type typedefs :structs lookup)))))
    (cond ((null ret)
           (values nil (format nil "unmappable return type ~S" (getf f :ret))))
          ((find nil args :key #'third)
           (values nil (format nil "unmappable argument type ~S"
                               (second (find nil args :key #'third)))))
          (t
           (let ((c-name (getf f :c-name))
                 (names (loop for (name nil nil) in args
                              for i from 0
                              collect (let ((n (c-name->lisp-name name "")))
                                        (if (zerop (length n))
                                            (format nil "arg~D" i)
                                            n)))))
             (if (/= (length names) (length (remove-duplicates names :test #'string=)))
                 (values nil "duplicate argument names")
                 `(cffi:defcfun (,c-name
                                 ,(intern (string-upcase (c-name->lisp-name c-name prefix))
                                          package))
                      ,(if (find-if #'struct-type-p args :key #'third)
                           ;; cffi-libffi (used for by-value structs) cannot
                           ;; translate a (:boolean :uchar) result.
                           ret
                           (storage-type ret))
                    ,@(loop for (nil nil type) in args
                            for n in names
                            collect `(,(intern (string-upcase n) package) ,type)))))))))

(defun starts-with-p (prefix string)
  (and (>= (length string) (length prefix))
       (string= prefix string :end2 (length prefix))))

(defun emit-forms (model &key (prefix "ig") (package "%IMGUI") (enum-prefix "ImGui")
                              strict-prefix external-structs)
  "Turn MODEL into defcstruct, defconstant and defcfun forms (in that order).
PREFIX is stripped from function names; with STRICT-PREFIX only functions that
start with it are emitted.  ENUM-PREFIX is stripped from enum constant names.
EXTERNAL-STRUCTS is an alist of (c-name . symbol) for by-value structs defined
in another package.  Opaque structs are reported with
`opaque-struct-warning'.  The second value lists (c-name reason) for each
skipped function, and the third an alist (c-name . symbol) of the structs emitted with
slots (usable as another package's EXTERNAL-STRUCTS)."
  (let* ((pkg (ensure-package package))
         (*package* pkg)
         (typedefs (getf model :typedefs))
         (struct-forms '()) (constant-forms '()) (function-forms '())
         (skipped '()) complete
         lookup)
    (multiple-value-bind (lk forms opaque complete-structs)
        (build-structs (getf model :structs) typedefs pkg external-structs)
      (setf lookup lk struct-forms forms complete complete-structs)
      (loop for (name . reason) in opaque
            do (warn 'opaque-struct-warning :name name :reason reason)))
    ;; constants
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (enum (getf model :enums))
        (loop for (name . value) in (getf enum :values)
              do (let ((sym (intern (string-upcase
                                     (format nil "+~A+" (c-name->lisp-name name enum-prefix)))
                                    pkg)))
                   (cond ((not (integerp value)))
                         ((nth-value 1 (gethash sym seen))
                          (unless (eql value (gethash sym seen))
                            (warn "Constant ~A defined with differing values; keeping first" sym)))
                         (t (setf (gethash sym seen) value)
                            (push `(cl:defconstant ,sym ,value) constant-forms)))))))
    ;; functions
    (let ((seen (make-hash-table :test 'eq)))
      (dolist (f (getf model :functions))
        (unless (and strict-prefix (not (starts-with-p prefix (getf f :c-name))))
          (multiple-value-bind (form reason) (emit-function f prefix pkg lookup typedefs)
            (cond ((null form) (push (list (getf f :c-name) reason) skipped))
                  ((gethash (second (second form)) seen)
                   (push (list (getf f :c-name) "duplicate lisp name") skipped))
                  (t (setf (gethash (second (second form)) seen) t)
                     (push form function-forms)))))))
    (values (append struct-forms (nreverse constant-forms) (nreverse function-forms))
            (nreverse skipped)
            complete)))

(defun forms-exports (forms)
  "Symbols naming the defcfun and defconstant forms in FORMS."
  (loop for form in forms
        for head = (first form)
        when (eq head 'cffi:defcfun) collect (second (second form))
        when (eq head 'cl:defconstant) collect (second form)))
