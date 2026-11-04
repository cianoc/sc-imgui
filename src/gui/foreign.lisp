(in-package #:gui)

;;; Enum keyword resolution and stable object IDs for the scope macros.

(defun enum-value (prefix keyword)
  "Value of %imgui:+PREFIX-KEYWORD+, or an error naming both."
  (let* ((name (format nil "+~A-~A+" prefix (symbol-name keyword)))
         (symbol (find-symbol name '#:%imgui)))
    (if (and symbol (boundp symbol))
        (symbol-value symbol)
        (error "Unknown ~A keyword ~S (no constant %IMGUI:~A)" prefix keyword name))))

(defun enum-flags (prefix designator)
  "Resolve DESIGNATOR (an integer, a keyword, or a list of keywords) to an
integer, looking keywords up as %imgui:+PREFIX-KEYWORD+ constants."
  (etypecase designator
    (integer designator)
    (null 0)
    (keyword (enum-value prefix designator))
    (list (let ((flags 0))
            (dolist (k designator flags)
              (setf flags (logior flags (enum-flags prefix k))))))))

(defun %constant-designator-p (form)
  (or (integerp form) (keywordp form) (null form)
      (and (consp form) (eq (car form) 'quote)
           (let ((x (second form))) (or (keywordp x) (and (listp x) (every #'keywordp x)))))))

(defun %flags-form (prefix form)
  "Form computing the flags for FORM; constant designators resolve at macroexpansion."
  (cond ((not (%constant-designator-p form)) `(enum-flags ,prefix ,form))
        ((and (consp form) (eq (car form) 'quote)) (enum-flags prefix (second form)))
        (t (enum-flags prefix form))))

(defun vec2 (x y)
  (list '%imgui::x (float x 1.0f0) '%imgui::y (float y 1.0f0)))

(defvar *object-ids* (make-hash-table :test 'eql :weakness :key :synchronized t))
(defvar *next-object-id* (ash 1 30))

(defun stable-object-id (object)
  "A small integer for OBJECT that stays the same for as long as it is alive."
  (sb-ext:with-locked-hash-table (*object-ids*)
    (or (gethash object *object-ids*)
        (setf (gethash object *object-ids*) (incf *next-object-id*)))))

(defun push-object-id (object)
  "PushID for OBJECT: 32-bit integers and strings directly, anything else via
a stable weak-table integer (never an address)."
  (typecase object
    ((signed-byte 32) (%imgui:push-id-int object))
    (string (%imgui:push-id-str object))
    (t (%imgui:push-id-int (stable-object-id object)))))
