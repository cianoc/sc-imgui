(in-package #:sc-imgui.tests)
(in-suite generator)

(defun fixture-path (name)
  (asdf:system-relative-pathname "sc-imgui/tests" (format nil "tests/fixtures/~A" name)))

(defun fixture-model ()
  (load-model (fixture-path "definitions.json")
              (fixture-path "structs_and_enums.json")
              (fixture-path "typedefs_dict.json")))

(defun fixture-typedefs () (getf (fixture-model) :typedefs))

(defun fixture-forms (&rest args)
  "emit-forms on the fixture, muffling the expected opaque-struct warning."
  (handler-bind ((warning #'muffle-warning))
    (values (apply #'emit-forms (fixture-model) :prefix "ig" :package "%IMGUI" args))))

(defun find-defcfun (forms c-name)
  (find-if (lambda (f) (and (eq (first f) 'cffi:defcfun)
                            (equal (first (second f)) c-name)))
           forms))

(defun constant-value (forms symbol-name)
  (let ((f (find-if (lambda (f) (and (eq (first f) 'cl:defconstant)
                                     (string= (symbol-name (second f)) symbol-name)))
                    forms)))
    (third f)))

(defun find-struct (forms symbol-name)
  (find-if (lambda (f) (and (eq (first f) 'cffi:defcstruct)
                            (string= (symbol-name (second f)) symbol-name)))
           forms))

(defun opaque-struct-p (forms symbol-name)
  (let ((f (find-struct forms symbol-name)))
    (and f (null (cddr f)))))

(test names
  (is (string= "slider-float2" (c-name->lisp-name "igSliderFloat2" "ig")))
  (is (string= "get-io" (c-name->lisp-name "igGetIO" "ig")))
  (is (string= "begin-child-str" (c-name->lisp-name "igBeginChild_Str" "ig")))
  (is (string= "plot-line-float-ptr-int"
               (c-name->lisp-name "ImPlot_PlotLine_FloatPtrInt" "ImPlot_")))
  (is (string= "im-vec2" (c-name->lisp-name "ImVec2" "")))
  (is (string= "im-gui-io" (c-name->lisp-name "ImGuiIO" "")))
  (is (string= "im-vector-im-draw-vert" (c-name->lisp-name "ImVector_ImDrawVert" "")))
  (is (string= "window-flags-no-title-bar"
               (c-name->lisp-name "ImGuiWindowFlags_NoTitleBar" "ImGui"))))

(test types
  (let ((td (fixture-typedefs)))
    (is (eq :bool (c-type->cffi "bool" td)))
    (is (eq :string (c-type->cffi "const char*" td)))
    (is (eq :pointer (c-type->cffi "ImDrawList*" td)))
    (is (eq :int (c-type->cffi "ImGuiWindowFlags" td)))
    (is (equal "IM-VEC2" (symbol-name (second (c-type->cffi "ImVec2" td)))))
    (is (equal "IM-VEC4" (symbol-name (second (c-type->cffi "const ImVec4" td)))))
    (is (eq :uint32 (c-type->cffi "ImGuiID" td)))
    (is (eq :size (c-type->cffi "size_t" td)))
    (is (eq :uint64 (c-type->cffi "unsigned long long" td)))
    (is (eq :pointer (c-type->cffi "void(*)(void* ptr,int n)" td)))
    (is (eq :pointer (c-type->cffi "float[2]" td)))
    (is (null (c-type->cffi "va_list" td)))
    (is (null (c-type->cffi "SomeUnknownStruct" td)))))

(test emit-from-fixture
  (let* ((forms (fixture-forms))
         (button (find-defcfun forms "igButton")))
    (is (not (null button)))
    (is (equal "BUTTON" (symbol-name (second (second button)))))
    (is (null (find-defcfun forms "igText")))      ; variadic: skipped
    (is (equal 1 (constant-value forms "+WINDOW-FLAGS-NO-TITLE-BAR+")))
    (is (opaque-struct-p forms "IM-BITFIELD-THING"))
    (is (not (opaque-struct-p forms "IM-VEC2")))))

(test opaque-struct-warns
  (let (warned)
    (handler-bind ((opaque-struct-warning
                     (lambda (w) (push (opaque-struct-name w) warned)
                       (muffle-warning w))))
      (emit-forms (fixture-model) :prefix "ig" :package "%IMGUI"))
    (is (equal '("ImBitfieldThing") warned))))

(test by-value-struct-fields-and-ordering
  (let* ((model (list :functions nil :enums nil
                      :typedefs (make-hash-table :test 'equal)
                      :structs
                      ;; user sorts before ImVec2 but must be emitted after it
                      (list (list :name "AUser"
                                  :fields (list (list :name "Pos" :type "ImVec2")
                                                (list :name "Flag" :type "bool")
                                                (list :name "Buf[4]" :type "float" :size 4)
                                                (list :name "Cb" :type "void(*)(int)")))
                            (list :name "ImVec2"
                                  :fields (list (list :name "x" :type "float")
                                                (list :name "y" :type "float"))))))
         (forms (emit-forms model :package "%IMGUI"))
         (user (find-struct forms "A-USER")))
    (is (< (position "IM-VEC2" forms :key (lambda (f) (symbol-name (second f))) :test #'string=)
           (position "A-USER" forms :key (lambda (f) (symbol-name (second f))) :test #'string=)))
    (is (equal '(:struct "IM-VEC2")
               (let ((ty (second (third user)))) (list (first ty) (symbol-name (second ty))))))
    (is (equal '(:boolean :uchar) (second (fourth user))))
    (is (equal '(:count 4) (cddr (fifth user))))
    (is (eq :pointer (second (sixth user))))))

(test exports-cover-functions-and-constants
  (let* ((forms (fixture-forms))
         (names (mapcar #'symbol-name (forms-exports forms))))
    (is (member "BUTTON" names :test #'string=))
    (is (member "+WINDOW-FLAGS-NO-TITLE-BAR+" names :test #'string=))
    (is (not (member "IM-VEC2" names :test #'string=)))))
