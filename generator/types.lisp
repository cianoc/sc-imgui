(in-package #:sc-imgui.generator)

(defparameter *scalar-types*
  '(("bool" . :bool) ("int" . :int) ("signed int" . :int) ("signed" . :int)
    ("unsigned int" . :uint) ("unsigned" . :uint)
    ("float" . :float) ("double" . :double) ("void" . :void)
    ("char" . :char) ("signed char" . :int8) ("unsigned char" . :uint8)
    ("short" . :short) ("signed short" . :short) ("unsigned short" . :ushort)
    ("long" . :long) ("unsigned long" . :ulong)
    ("long long" . :int64) ("unsigned long long" . :uint64)
    ("signed long long" . :int64) ("time_t" . :int64)
    ("size_t" . :size)
    ;; Pinned before typedef lookup.
    ("ImU32" . :uint32) ("ImGuiID" . :uint32))
  "C scalar type name to CFFI type.")

(defparameter *builtin-structs* '("ImVec2" "ImVec4")
  "Structs always mappable by value, even when the model does not define them.")

(defun normalize-c-type (type)
  "Trim TYPE, drop a trailing `;`, a leading `const`/`struct`, and tidy spaces."
  (let ((s (string-trim '(#\Space #\Tab #\;) type)))
    (loop for prefix in '("const " "struct ")
          do (loop while (and (> (length s) (length prefix))
                              (string= prefix s :end2 (length prefix)))
                   do (setf s (string-left-trim " " (subseq s (length prefix))))))
    (string-right-trim " " s)))

(defun lookup-struct (structs name)
  (etypecase structs
    (null nil)
    (function (funcall structs name))
    (hash-table (values (gethash name structs)))))

(defun struct-type-symbol (name)
  (intern (string-upcase (c-name->lisp-name name "")) *package*))

(defun c-type->cffi (type typedefs &key structs (depth 0))
  "Map the C type string TYPE to a CFFI type, or NIL when unmappable.
STRUCTS maps a struct name to its Lisp symbol (a function or hash table, NIL
for not-defined); mapped structs become (:struct symbol).  ImVec2 and ImVec4
are always known."
  (when (or (null type) (> depth 8))
    (return-from c-type->cffi nil))
  (let* ((raw (string-trim '(#\Space #\Tab #\;) type))
         (s (normalize-c-type raw)))
    (cond
      ((zerop (length s)) nil)
      ((search "(*)" s) :pointer)
      ((find #\( s) nil)
      ((string= s "va_list") nil)
      ((string= (remove #\Space raw) "constchar*") :string)
      ((or (find #\* s) (find #\[ s)) :pointer)
      (t
       (let ((scalar (cdr (assoc s *scalar-types* :test #'string=))))
         (cond
           (scalar scalar)
           ((lookup-struct structs s)
            (list :struct (lookup-struct structs s)))
           ((member s *builtin-structs* :test #'string=)
            (list :struct (struct-type-symbol s)))
           ;; cimgui returns/passes small structs as layout-identical `Foo_c`
           ;; (ImVec2_c, ImRect_c, ...); map them to the real struct Foo.
           ((and (> (length s) 2)
                 (string= "_c" s :start2 (- (length s) 2))
                 (let ((base (subseq s 0 (- (length s) 2))))
                   (or (and (lookup-struct structs base)
                            (list :struct (lookup-struct structs base)))
                       (and (member base *builtin-structs* :test #'string=)
                            (list :struct (struct-type-symbol base)))))))
           (t
            (let ((target (and typedefs (gethash s typedefs))))
              (when (and target
                         (not (string= (normalize-c-type target) s)))
                (c-type->cffi target typedefs :structs structs
                                              :depth (1+ depth)))))))))))
