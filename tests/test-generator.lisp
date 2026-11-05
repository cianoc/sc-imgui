(in-package #:sc-imgui.tests)
(in-suite generator)

(defun ensure-package (name) (or (find-package name) (make-package name :use nil)))

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
    ;; cimgui's layout-identical by-value `_c` structs map to the real struct
    (is (equal "IM-VEC2" (symbol-name (second (c-type->cffi "ImVec2_c" td)))))
    (is (equal "IM-VEC4" (symbol-name (second (c-type->cffi "ImVec4_c" td)))))
    (is (null (c-type->cffi "Unknown_c" td)))
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
    (is (equal "BUTTON-RAW" (symbol-name (second (second button)))))
    (is (find-defun forms "BUTTON"))
    (is (null (find-defcfun forms "igText")))      ; variadic: skipped
    (is (equal 1 (constant-value forms "+WINDOW-FLAGS-NO-TITLE-BAR+")))
    (is (opaque-struct-p forms "IM-BITFIELD-THING"))
    (is (not (opaque-struct-p forms "IM-VEC2")))))

(defun find-defun (forms name)
  (find-if (lambda (f) (and (eq (first f) 'cl:defun)
                            (string= (symbol-name (second f)) name)))
           forms))

(test bool-returns-use-uint8-and-wrapper
  ;; Rule: every C `bool` return is a :uint8 defcfun (NAME-RAW) plus a wrapper
  ;; NAME returning T/NIL; same with and without by-value struct args.
  (let ((forms (fixture-forms)))
    (dolist (case '(("igButton" "BUTTON") ("igIsWindowFocused" "IS-WINDOW-FOCUSED")))
      (destructuring-bind (c-name name) case
        (let ((raw (find-defcfun forms c-name))
              (wrapper (find-defun forms name)))
          (is (not (null raw)))
          (is (eq :uint8 (third raw)))
          (is (equal (concatenate 'string name "-RAW") (symbol-name (second (second raw)))))
          (is (not (null wrapper)))
          (is (eq (second (second raw)) (first (third (fourth wrapper))))
              "wrapper calls the raw function"))))
    ;; igButton still takes the by-value struct
    (is (equal "IM-VEC2" (symbol-name (second (second (fifth (find-defcfun forms "igButton")))))))))

;; `const char*` arguments use sc-imgui.bindings:optional-string (NIL passes
;; NULL); `const char*` returns stay CFFI :string.
(test const-char-arguments-accept-nil
  (let ((button (find-defcfun (fixture-forms) "igButton")))
    (is (equal "LABEL" (symbol-name (first (fourth button)))))
    (is (eq 'sc-imgui.bindings:optional-string (second (fourth button)))))
  (let ((forms (sc-imgui.generator::emit-function
                (list :c-name "igGetVersion" :ret "const char*" :args nil)
                "ig" (ensure-package "%IMGUI") nil (make-hash-table :test 'equal))))
    (is (eq :string (third (first forms))))))

;; Bool-argument rule: C `bool` arguments are :uint8 in a NAME-RAW defcfun and
;; NAME is a wrapper passing T/NIL as 1/0, with or without by-value structs.
(defun emit-one (c-name ret args)
  (sc-imgui.generator::emit-function
   (list :c-name c-name :ret ret :args args)
   "ig" (ensure-package "%IMGUI") nil (make-hash-table :test 'equal)))

(test bool-arguments-use-uint8-and-wrapper
  ;; no by-value struct: void igSetNextItemOpen(bool is_open, ImGuiCond cond)
  (destructuring-bind (raw wrapper)
      (emit-one "igSetNextItemOpen" "void" '(("is_open" "bool") ("cond" "int")))
    (is (equal "SET-NEXT-ITEM-OPEN-RAW" (symbol-name (second (second raw)))))
    (is (eq :void (third raw)))
    (is (eq :uint8 (second (fourth raw))))
    (is (eq 'cl:defun (first wrapper)))
    (is (equal "SET-NEXT-ITEM-OPEN" (symbol-name (second wrapper))))
    (is (equal '("IS-OPEN" "COND") (mapcar #'symbol-name (third wrapper))))
    ;; void return: the wrapper returns the raw call's value unchanged
    (destructuring-bind (call-head a b) (fourth wrapper)
      (is (eq (second (second raw)) call-head))
      (is (equal '(cl:if t 1 0) (subst t (first (third wrapper)) a)))
      (is (eq (second (third wrapper)) b))))
  ;; by-value struct and bool return:
  ;; bool igSelectable_Bool(const char* label, bool selected, flags, ImVec2 size)
  (destructuring-bind (raw wrapper)
      (emit-one "igSelectable_Bool" "bool"
                '(("label" "const char*") ("selected" "bool") ("flags" "int")
                  ("size" "const ImVec2")))
    (is (eq :uint8 (third raw)))
    (is (eq :uint8 (second (fifth raw))))
    (is (equal "IM-VEC2" (symbol-name (second (second (seventh raw))))))
    (let ((body (fourth wrapper)))
      (is (eq 'cl:/= (first body)))
      (is (eq (second (second raw)) (first (third body))))
      (is (equal '(cl:if t 1 0) (subst t (second (third wrapper)) (third (third body)))))))
  ;; no bool anywhere: a plain defcfun, no wrapper
  (let ((forms (emit-one "igSetNextItemWidth" "void" '(("item_width" "float")))))
    (is (= 1 (length forms)))
    (is (eq 'cffi:defcfun (first (first forms))))))

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
    (is (member "IS-WINDOW-FOCUSED" names :test #'string=))
    (is (not (member "BUTTON-RAW" names :test #'string=)))
    (is (not (member "IM-VEC2" names :test #'string=)))))

(test name-prefixes-filter-structs-and-enums
  (let* ((model (list :functions nil :typedefs (make-hash-table :test 'equal)
                      :structs (list (list :name "ImPlotThing"
                                           :fields (list (list :name "p" :type "ImVec2")))
                                     (list :name "ImGuiOther"
                                           :fields (list (list :name "a" :type "int"))))
                      :enums (list (list :name "ImPlotFlags_" :values '(("ImPlotFlags_None" . 0)))
                                   (list :name "ImGuiFlags_" :values '(("ImGuiFlags_None" . 0))))))
         (forms (handler-bind ((warning #'muffle-warning))
                  (emit-forms model :package "%IMPLOT" :prefix "ImPlot_" :enum-prefix "ImPlot"
                                    :name-prefixes '("ImPlot")
                                    :external-structs
                                    (list (cons "ImVec2" (intern "IM-VEC2" (ensure-package "%IMGUI"))))))))
    (is (find-struct forms "IM-PLOT-THING"))
    (is (null (find-struct forms "IM-GUI-OTHER")))
    (is (equal 0 (constant-value forms "+FLAGS-NONE+")))
    (is (= 1 (count-if (lambda (f) (eq (first f) 'cl:defconstant)) forms)))
    ;; ImVec2 comes from %imgui, not redefined
    (is (equal "%IMGUI" (package-name (symbol-package
                                       (second (second (third (find-struct forms "IM-PLOT-THING"))))))))))

;;; Binding-name collisions: two C names mapping to one Lisp symbol are an
;;; error, never a silent skip or a silent first-wins.

(defun model-of (&key functions structs enums)
  (list :functions functions :structs structs :enums enums
        :typedefs (make-hash-table :test 'equal)))

(defun c-function (c-name &optional (ret "void"))
  (list :c-name c-name :ret ret :args nil))

(defun collisions-in (model &rest args)
  "The (kind lisp-name c-names) of each collision EMIT-FORMS signals for MODEL,
or :NONE when it returns normally."
  (handler-case
      (handler-bind ((opaque-struct-warning #'muffle-warning))
        (apply #'emit-forms model :package "%IMGUI" args)
        :none)
    (binding-name-collision (c)
      (loop for x in (binding-name-collisions c)
            collect (list (collision-kind x)
                          (symbol-name (collision-lisp-name x))
                          (collision-c-names x))))))

(test functions-with-the-same-lisp-name-collide
  (is (equal '((:function "FOO-IO" ("igFooIO" "igFoo_IO")))
             (collisions-in (model-of :functions (list (c-function "igFooIO")
                                                       (c-function "igFoo_IO")))))))

(test function-named-like-a-raw-wrapper-collides
  (is (equal '((:function "FOO-RAW" ("igFoo" "igFooRaw")))
             (collisions-in (model-of :functions (list (c-function "igFoo" "bool")
                                                       (c-function "igFooRaw")))))))

(test enum-constants-with-the-same-lisp-name-collide
  (dolist (values '((1 2) (1 1)))           ; differing, then equal values
    (is (equal '((:constant "+FLAGS-NO-TITLE+" ("ImGuiFlags_NoTitle" "ImGuiFlags_No_Title")))
               (collisions-in
                (model-of :enums (list (list :name "ImGuiFlags_"
                                             :values (list (cons "ImGuiFlags_NoTitle" (first values))
                                                           (cons "ImGuiFlags_No_Title" (second values)))))))))))

(test structs-with-the-same-lisp-name-collide
  (is (equal '((:struct "IM-FOO-IO" ("ImFooIO" "ImFoo_IO")))
             (collisions-in
              (model-of :structs (list (list :name "ImFooIO"
                                             :fields (list (list :name "a" :type "int")))
                                       (list :name "ImFoo_IO"
                                             :fields (list (list :name "b" :type "int")))))))))

(test every-collision-is-listed
  (let ((found (collisions-in
                (model-of :functions (list (c-function "igFooIO") (c-function "igFoo_IO")
                                           (c-function "igBar" "bool") (c-function "igBarRaw"))
                          :enums (list (list :name "ImGuiFlags_"
                                             :values '(("ImGuiFlags_NoTitle" . 1) ("ImGuiFlags_No_Title" . 2))))
                          :structs (list (list :name "ImFooIO" :fields nil)
                                         (list :name "ImFoo_IO" :fields nil))))))
    (is (equal '((:struct "IM-FOO-IO") (:constant "+FLAGS-NO-TITLE+")
                 (:function "FOO-IO") (:function "BAR-RAW"))
               (mapcar (lambda (c) (subseq c 0 2)) found)))
    ;; the report names every symbol and every C name
    (let ((report (handler-case
                      (handler-bind ((opaque-struct-warning #'muffle-warning))
                        (emit-forms (model-of :functions (list (c-function "igFooIO")
                                                               (c-function "igFoo_IO")
                                                               (c-function "igBar" "bool")
                                                               (c-function "igBarRaw")))
                                    :package "%IMGUI"))
                    (binding-name-collision (c) (princ-to-string c)))))
      (dolist (s '("FOO-IO" "igFooIO" "igFoo_IO" "BAR-RAW" "igBar" "igBarRaw"))
        (is (search s report) "report mentions ~A" s)))))

(test no-duplicate-lisp-name-skip-reason
  (let ((skipped (handler-case
                     (nth-value 1 (emit-forms (model-of :functions (list (c-function "igFooIO")
                                                                         (c-function "igFoo_IO")))
                                              :package "%IMGUI"))
                   (binding-name-collision () :signalled))))
    (is (eq :signalled skipped))))

(test fixture-output-unchanged
  ;; tests/fixtures/expected-imgui.lisp is the output from before collisions
  ;; became errors; a fixture without collisions must produce it exactly.
  (let ((path (uiop:tmpize-pathname (merge-pathnames "sc-imgui-fixture.lisp"
                                                     (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (sc-imgui.generator::write-bindings-file path (fixture-forms) "%IMGUI"
                                                    "fixture" "fixture")
           (is (string= (uiop:read-file-string (fixture-path "expected-imgui.lisp"))
                        (uiop:read-file-string path))))
      (uiop:delete-file-if-exists path))))

;;; generate-bindings writes nothing unless both libraries emit cleanly.

(defun write-library-json (dir &key (definitions "{}") (enums "{}"))
  (let ((out (merge-pathnames "generator/output/" dir)))
    (ensure-directories-exist out)
    (flet ((put (name text)
             (with-open-file (s (merge-pathnames name out) :direction :output
                                                           :if-exists :supersede)
               (write-string text s))))
      (put "definitions.json" definitions)
      (put "structs_and_enums.json" (format nil "{\"enums\": ~A, \"structs\": {}}" enums))
      (put "typedefs_dict.json" "{}"))))

(test collision-in-cimplot-writes-no-files
  (let ((root (merge-pathnames (format nil "sc-imgui-gen-~36R/" (random (expt 36 8)
                                                                      (make-random-state t)))
                               (uiop:temporary-directory))))
    (unwind-protect
         (let ((cimgui (merge-pathnames "cimgui/" root))
               (cimplot (merge-pathnames "cimplot/" root))
               (out (merge-pathnames "out/" root)))
           (write-library-json cimgui)
           (write-library-json cimplot :enums "{\"ImPlotFlags_\": [
              {\"name\": \"ImPlotFlags_NoTitle\", \"calc_value\": 1},
              {\"name\": \"ImPlotFlags_No_Title\", \"calc_value\": 1}]}")
           (is (eq :signalled
                   (handler-case (let ((*standard-output* (make-broadcast-stream)))
                                   (generate-bindings :cimgui-dir cimgui :cimplot-dir cimplot
                                                      :output-dir out))
                     (binding-name-collision () :signalled))))
           (is (null (probe-file (merge-pathnames "imgui.lisp" out))))
           (is (null (probe-file (merge-pathnames "implot.lisp" out))))
           ;; without the collision both files are written
           (write-library-json cimplot)
           (let ((*standard-output* (make-broadcast-stream)))
             (generate-bindings :cimgui-dir cimgui :cimplot-dir cimplot :output-dir out))
           (is (probe-file (merge-pathnames "imgui.lisp" out)))
           (is (probe-file (merge-pathnames "implot.lisp" out))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

;;; *lisp-name-overrides* resolves a collision by renaming one C name.

(defun emitted-names (forms)
  "Symbol names of every form, mapped from the form's C name when it has one."
  (loop for f in forms
        collect (symbol-name (if (eq (first f) 'cffi:defcfun) (second (second f)) (second f)))))

(test override-resolves-a-function-collision
  (let* ((*lisp-name-overrides* '(("igFoo_IO" . "foo-io-2")))
         (forms (emit-forms (model-of :functions (list (c-function "igFooIO")
                                                       (c-function "igFoo_IO")))
                            :package "%IMGUI")))
    (is (equal "FOO-IO" (symbol-name (second (second (find-defcfun forms "igFooIO"))))))
    (is (equal "FOO-IO-2" (symbol-name (second (second (find-defcfun forms "igFoo_IO"))))))))

(test override-of-a-bool-function-renames-its-wrapper-and-raw
  (let* ((*lisp-name-overrides* '(("igFoo" . "foo-checked")))
         (forms (emit-forms (model-of :functions (list (c-function "igFoo" "bool")
                                                       (c-function "igFooRaw")))
                            :package "%IMGUI")))
    (is (equal '("FOO-CHECKED-RAW" "FOO-CHECKED" "FOO-RAW") (emitted-names forms)))))

(test override-resolves-a-constant-collision
  (let* ((*lisp-name-overrides* '(("ImGuiFlags_No_Title" . "flags-no-title-legacy")))
         (forms (emit-forms (model-of :enums (list (list :name "ImGuiFlags_"
                                                         :values '(("ImGuiFlags_NoTitle" . 1)
                                                                   ("ImGuiFlags_No_Title" . 2)))))
                            :package "%IMGUI")))
    (is (equal 1 (constant-value forms "+FLAGS-NO-TITLE+")))
    (is (equal 2 (constant-value forms "+FLAGS-NO-TITLE-LEGACY+")))))

(test override-renames-a-struct-everywhere-it-is-used
  (let* ((*lisp-name-overrides* '(("ImFoo_IO" . "im-foo-io-2")))
         (forms (emit-forms (model-of :structs (list (list :name "ImFooIO"
                                                           :fields '((:name "a" :type "int")))
                                                     (list :name "ImFoo_IO"
                                                           :fields '((:name "b" :type "int")))
                                                     (list :name "ImHolder"
                                                           :fields '((:name "x" :type "ImFoo_IO"))))
                                      :functions (list (list :c-name "igTake" :ret "void"
                                                             :args '(("v" "ImFoo_IO")))))
                            :package "%IMGUI")))
    (is (find-struct forms "IM-FOO-IO"))
    (is (find-struct forms "IM-FOO-IO-2"))
    (flet ((struct-name (type) (symbol-name (second type))))
      (is (equal "IM-FOO-IO-2" (struct-name (second (third (find-struct forms "IM-HOLDER"))))))
      (is (equal "IM-FOO-IO-2" (struct-name (second (fourth (find-defcfun forms "igTake")))))))))

(test overrides-are-empty-by-default
  (is (null *lisp-name-overrides*)))

;;; generate-bindings warns about overrides that match nothing in either library.

(defun unused-override-warnings (overrides)
  "C names of the UNUSED-NAME-OVERRIDE warnings generate-bindings signals with
OVERRIDES, run on temporary cimgui JSON (igFoo) and cimplot JSON (one enum)."
  (let ((root (merge-pathnames (format nil "sc-imgui-gen-~36R/" (random (expt 36 8)
                                                                      (make-random-state t)))
                               (uiop:temporary-directory)))
        (warned '()))
    (unwind-protect
         (let ((cimgui (merge-pathnames "cimgui/" root))
               (cimplot (merge-pathnames "cimplot/" root)))
           (write-library-json cimgui :definitions "{\"igFoo\": [
              {\"argsT\": [], \"ov_cimguiname\": \"igFoo\", \"ret\": \"void\"}]}")
           (write-library-json cimplot :enums "{\"ImPlotFlags_\": [
              {\"name\": \"ImPlotFlags_NoTitle\", \"calc_value\": 1}]}")
           (handler-bind ((unused-name-override
                            (lambda (w) (push (unused-override-c-name w) warned)
                              (muffle-warning w))))
             (let ((*lisp-name-overrides* overrides)
                   (*standard-output* (make-broadcast-stream)))
               (generate-bindings :cimgui-dir cimgui :cimplot-dir cimplot
                                  :output-dir (merge-pathnames "out/" root)))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))
    (nreverse warned)))

(test unused-overrides-warn
  (is (equal '("igGone" "ImPlotFlags_Gone")
             (unused-override-warnings '(("igFoo" . "foo-2")
                                         ("igGone" . "gone")
                                         ("ImPlotFlags_NoTitle" . "flags-untitled")
                                         ("ImPlotFlags_Gone" . "flags-gone"))))))

(test used-overrides-do-not-warn
  (is (null (unused-override-warnings '(("igFoo" . "foo-2")
                                        ("ImPlotFlags_NoTitle" . "flags-untitled"))))))
