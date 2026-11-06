(in-package #:gui)

;;;; Display strings and typed-text parsing for value controls.  Pure Lisp.
;;;; User text never reaches the Lisp reader: numbers are parsed by hand into
;;;; exact rationals, unit multipliers are applied exactly, and only then is
;;;; the result coerced (integers stay integers, others become single-floats).

(defun fixed-string (x decimals)
  "X rounded to DECIMALS places as a string, without float printing."
  (let* ((r (rational x))
         (scale (expt 10 decimals))
         (n (round (* (abs r) scale))))
    (multiple-value-bind (whole frac) (floor n scale)
      (format nil "~:[~;-~]~D~:[~;.~V,'0D~]"
              (and (minusp r) (plusp n)) whole (plusp decimals) decimals frac))))

(defun format-with-prefix (value decimals suffix)
  (format nil "~A ~A" (fixed-string value decimals) suffix))

(defun format-unit-value (unit value)
  (ecase unit
    (:hz (if (>= value 999.5)
             (format-with-prefix (/ (rational value) 1000) 2 "kHz")
             (format-with-prefix value 0 "Hz")))
    (:ms (if (>= value 999.5)
             (format-with-prefix (/ (rational value) 1000) 2 "s")
             (format-with-prefix value 0 "ms")))
    (:db (if (<= value -70)
             "-inf dB"
             (format-with-prefix value 1 "dB")))
    (:percent (format-with-prefix (* (rational value) 100) 0 "%"))
    (:semitones (let ((n (round value)))
                  (format nil "~:[~;+~]~D st" (plusp n) n)))
    (:pan (let ((n (round (* (rational value) 50))))
            (cond ((zerop n) "C")
                  ((plusp n) (format nil "~DR" n))
                  (t (format nil "~DL" (- n))))))))

(defun format-plain-value (spec value)
  (let ((range (- (control-spec-max spec) (control-spec-min spec))))
    (fixed-string value (cond ((integerp value) 0)
                              ((>= range 100) 0)
                              ((>= range 10) 1)
                              (t 2)))))

(defun format-control-value (spec value)
  "The display string for VALUE under SPEC.  A :format function wins and its
errors propagate."
  (let ((fn (control-spec-format spec))
        (choices (control-spec-choices spec))
        (unit (control-spec-unit spec)))
    (cond (fn (funcall fn value))
          (choices (nth (max 0 (min (1- (length choices)) (round value))) choices))
          (unit (format-unit-value unit value))
          (t (format-plain-value spec value)))))

;;; Parsing

(defun parse-decimal (string)
  "Parse [+-]digits[.digits] at the start of STRING.  Returns the exact rational
and the index after it, or NIL if there is no number."
  (let ((i 0) (n (length string)) (sign 1) (int 0) (digits 0) (frac 0) (scale 1))
    (when (and (< i n) (member (char string i) '(#\+ #\-)))
      (when (char= (char string i) #\-) (setf sign -1))
      (incf i))
    (loop while (and (< i n) (digit-char-p (char string i)))
          do (setf int (+ (* int 10) (digit-char-p (char string i))))
             (incf digits) (incf i))
    (when (and (< i n) (char= (char string i) #\.))
      (incf i)
      (loop while (and (< i n) (digit-char-p (char string i)))
            do (setf frac (+ (* frac 10) (digit-char-p (char string i)))
                     scale (* scale 10))
               (incf digits) (incf i)))
    (when (plusp digits)
      (values (* sign (+ int (/ frac scale))) i))))

(defun unit-multiplier (unit suffix)
  "The exact factor for SUFFIX (lower-case, trimmed) under UNIT, or NIL."
  (flet ((in (&rest names) (member suffix names :test #'string=)))
    (cond ((and (string= suffix "") (not (member unit '(:percent :pan)))) 1)
          (t (ecase unit
               ((nil) nil)
               (:hz (cond ((in "hz") 1) ((in "k" "khz") 1000)))
               (:db (and (in "db") 1))
               (:ms (cond ((in "ms") 1) ((in "s") 1000)))
               (:percent (and (in "" "%") 1/100))
               (:semitones (and (in "st") 1))
               (:pan (cond ((in "") 1/50) ((in "l") -1/50) ((in "r") 1/50))))))))

(defun coerce-parsed (rational)
  "RATIONAL as an integer or single-float, or NIL if it is out of float range."
  (if (integerp rational)
      rational
      (handler-case (float rational 1f0)
        (arithmetic-error () nil))))

(defun parse-control-text (spec string)
  "Parse typed STRING under SPEC.  Returns (values value t), or (values nil nil).
The value is not clamped."
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) string))
        (choices (control-spec-choices spec))
        (unit (control-spec-unit spec)))
    (flet ((fail () (return-from parse-control-text (values nil nil))))
      (when (zerop (length text)) (fail))
      (when choices
        (let ((index (position text choices :test #'string-equal)))
          (if index (return-from parse-control-text (values index t)) (fail))))
      (let ((lower (string-downcase text)))
        (when (and (eq unit :pan) (string= lower "c"))
          (return-from parse-control-text (values 0 t)))
        (when (and (eq unit :db) (member lower '("-inf" "-inf db") :test #'string=))
          (return-from parse-control-text (values (control-spec-min spec) t)))
        (multiple-value-bind (number end) (parse-decimal lower)
          (unless number (fail))
          (let ((factor (unit-multiplier
                         unit (string-trim " " (subseq lower end)))))
            (unless factor (fail))
            (let ((value (coerce-parsed (* number factor))))
              (if value (values value t) (fail)))))))))
