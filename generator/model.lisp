(in-package #:sc-imgui.generator)

(defun read-json (path)
  (with-open-file (s path :external-format :utf-8)
    (com.inuoe.jzon:parse s)))

(defun hash-keys-sorted (table)
  (sort (loop for k being the hash-keys of table collect k) #'string<))

(defun load-functions (definitions)
  (let (functions)
    (dolist (key (hash-keys-sorted definitions))
      (loop for f across (gethash key definitions)
            do (let* ((arg-ts (coerce (gethash "argsT" f) 'list))
                      (variadic (or (gethash "isvararg" f)
                                    (find "..." arg-ts
                                          :key (lambda (a) (gethash "type" a))
                                          :test #'string=)))
                      (args (loop for a in arg-ts
                                  unless (string= (gethash "type" a) "...")
                                    collect (list (gethash "name" a)
                                                  (gethash "type" a))))
                      (ret (or (gethash "ret" f)
                               ;; cimgui omits `ret` on constructors (they
                               ;; return a pointer) and some destructors.
                               (if (gethash "constructor" f) "void*" "void"))))
                 (push (list :c-name (gethash "ov_cimguiname" f)
                             :ret ret
                             :args args
                             :variadic-p (and variadic t)
                             :templated-p (and (gethash "templated" f) t))
                       functions))))
    (nreverse functions)))

(defun load-structs (structs-table)
  (loop for name in (hash-keys-sorted structs-table)
        collect (list :name name
                      :fields (loop for f across (gethash name structs-table)
                                    collect (list :name (gethash "name" f)
                                                  :type (gethash "type" f)
                                                  :size (gethash "size" f)
                                                  :bitfield-p (and (gethash "bitfield" f) t))))))

(defun load-enums (enums-table)
  (loop for name in (hash-keys-sorted enums-table)
        collect (list :name name
                      :values (loop for e across (gethash name enums-table)
                                    collect (cons (gethash "name" e)
                                                  (gethash "calc_value" e))))))

(defparameter *instantiated-templates* '("ImVector" "ImSmallStack_" "ImSpan")
  "Templates whose instantiations cimgui emits as plain C structs and that the
generator reproduces.  The others (ImPool, ImBitArray, ...) stay opaque.")

(defun split-string (string char)
  (loop with start = 0
        for pos = (position char string :start start)
        collect (string-trim " " (subseq string start pos))
        while pos
        do (setf start (1+ pos))))

(defun template-instance-name (template args)
  "cimgui's name for TEMPLATE<ARGS...>: ImVector<ImDrawList*> is
ImVector_ImDrawListPtr, ImSmallStack_<ImDrawFlags,3> is
ImSmallStack__ImDrawFlags__3."
  (let ((joined (format nil "~{~A~^__~}" args)))
    (format nil "~A_~A" template
            (substitute #\_ #\Space
                        (with-output-to-string (out)
                          (loop for c across joined
                                do (if (char= c #\*)
                                       (write-string "Ptr" out)
                                       (write-char c out))))))))

(defun template-parameters (typenames)
  "Parse \"typename T, int Capacity, typename SZ_T = ImU16\" into
((name . default-or-nil) ...)."
  (loop for decl in (split-string typenames #\,)
        for eq = (position #\= decl)
        for head = (string-trim " " (subseq decl 0 eq))
        collect (cons (subseq head (1+ (or (position #\Space head :from-end t) -1)))
                      (and eq (string-trim " " (subseq decl (1+ eq)))))))

(defun substitute-template-params (string bindings)
  "Replace each identifier in STRING that BINDINGS (alist name . text) names."
  (with-output-to-string (out)
    (let ((i 0) (n (length string)))
      (loop while (< i n)
            do (if (or (alpha-char-p (char string i)) (char= (char string i) #\_))
                   (let* ((end (or (position-if-not
                                    (lambda (c) (or (alphanumericp c) (char= c #\_)))
                                    string :start i)
                                   n))
                          (word (subseq string i end))
                          (binding (assoc word bindings :test #'string=)))
                     (write-string (if binding (cdr binding) word) out)
                     (setf i end))
                   (progn (write-char (char string i) out) (incf i)))))))

(defun load-template-instances (se template)
  "Struct plists for each instantiation of TEMPLATE that cimgui lists in
templates_done, built from its templated_structs definition."
  (let ((templated (gethash "templated_structs" se))
        (done (gethash "templates_done" se))
        (typenames (gethash "typenames" se)))
    (when (and (hash-table-p templated) (hash-table-p done) (hash-table-p typenames)
               (gethash template templated) (gethash template done))
      (let ((params (template-parameters (gethash template typenames))))
        (loop for key in (hash-keys-sorted (gethash template done))
              for args = (split-string key #\,)
              for bindings = (loop for (name . default) in params
                                   for i from 0
                                   collect (cons name (or (nth i args) default)))
              collect (list :name (template-instance-name template args)
                            :fields (loop for f across (gethash template templated)
                                          collect (template-field f bindings))))))))

(defun template-field (f bindings)
  (let* ((name (gethash "name" f))
         (bracket (position #\[ name))
         (size (or (gethash "size" f)
                   (and bracket
                        (parse-integer (substitute-template-params
                                        (subseq name (1+ bracket) (position #\] name))
                                        bindings)
                                       :junk-allowed t)))))
    (list :name name
          :type (substitute-template-params (gethash "type" f) bindings)
          :size size
          :bitfield-p nil)))

(defun merge-enum-typedefs (typedefs se)
  "Every enum E_ is an `int` typedef E, unless typedefs says otherwise; the
`enumtypes` table gives the exact underlying type of the rest."
  (let ((enums (gethash "enums" se))
        (enumtypes (gethash "enumtypes" se)))
    (when (hash-table-p enums)
      (loop for name being the hash-keys of enums
            for plain = (string-right-trim "_" name)
            unless (nth-value 1 (gethash plain typedefs))
              do (setf (gethash plain typedefs) "int")))
    (when (hash-table-p enumtypes)
      (loop for name being the hash-keys of enumtypes using (hash-value type)
            do (setf (gethash name typedefs) type)))
    typedefs))

(defun load-model (definitions-path structs-and-enums-path typedefs-path)
  "Read cimgui-style JSON into a plist (:functions :structs :enums :typedefs)."
  (let ((definitions (read-json definitions-path))
        (se (read-json structs-and-enums-path))
        (typedefs (read-json typedefs-path)))
    (list :functions (load-functions definitions)
          :structs (append (load-structs (gethash "structs" se))
                           (loop for template in *instantiated-templates*
                                 append (load-template-instances se template)))
          :enums (load-enums (gethash "enums" se))
          :typedefs (merge-enum-typedefs typedefs se))))
