(in-package #:gui)

;;;; Value specification and the value <-> position mapping shared by every
;;;; value control.  Pure Lisp: nothing here touches ImGui.

(define-condition control-spec-error (error)
  ((label :initarg :label :reader control-spec-error-label)
   (problem :initarg :problem :reader control-spec-error-problem))
  (:report (lambda (c s)
             (format s "Control ~S: ~A"
                     (control-spec-error-label c) (control-spec-error-problem c)))))

(defparameter *control-units* '(:hz :db :ms :percent :semitones :pan))

(defparameter *value-control-keys*
  '(:min :max :scale :step :choices :bipolar :default :unit :format)
  "The value specification keywords every value control accepts.")

(defun check-control-keys (label plist &rest extra-keys)
  "Signal CONTROL-SPEC-ERROR naming LABEL unless PLIST is a property list of
value specification keywords and EXTRA-KEYS (the control's own)."
  (unless (and (alexandria:proper-list-p plist) (evenp (length plist)))
    (error 'control-spec-error :label label
                               :problem (format nil "malformed arguments ~S: expected a property list"
                                                plist)))
  (loop for key in plist by #'cddr
        unless (or (member key *value-control-keys*) (member key extra-keys))
          do (error 'control-spec-error
                    :label label
                    :problem (format nil "unknown keyword ~S (expected one of ~{~S~^ ~})"
                                     key (append *value-control-keys* extra-keys)))))

(defun size-p (size)
  "True when SIZE is a positive real (rem) or (:px n) with N a positive real."
  (or (and (realp size) (plusp size))
      (and (alexandria:proper-list-p size) (= 2 (length size)) (eq :px (first size))
           (realp (second size)) (plusp (second size)))))

(defun check-control-sizes (label &rest keys-and-sizes)
  "Signal CONTROL-SPEC-ERROR naming LABEL unless each non-NIL size in
KEYS-AND-SIZES, a plist of size keyword and value, is valid for REM-PX."
  (loop for (key size) on keys-and-sizes by #'cddr
        unless (or (null size) (size-p size))
          do (error 'control-spec-error
                    :label label
                    :problem (format nil "~S must be a positive number of rem or (:px n), got ~S"
                                     key size))))

(defstruct control-spec
  min max scale step choices origin default unit format)

(defun parse-control-spec (label value &key (min 0 min-p) (max 1 max-p)
                                         (scale :linear scale-p)
                                         (step nil step-p)
                                         (choices nil choices-p)
                                         bipolar (default nil default-p)
                                         unit format)
  "Validate the keyword arguments of a value control and return a normalized
CONTROL-SPEC.  Signals CONTROL-SPEC-ERROR, naming LABEL, for an invalid one."
  (flet ((fail (string &rest args)
           (error 'control-spec-error :label label
                                      :problem (apply #'format nil string args))))
    (unless (member scale '(:linear :log))
      (fail "unknown :scale ~S (expected :linear or :log)" scale))
    (when (and unit (not (member unit *control-units*)))
      (fail "unknown :unit ~S (expected one of ~{~S~^ ~})" unit *control-units*))
    (unless (or (null format) (functionp format) (and (symbolp format) (fboundp format)))
      (fail ":format must be a function of the value returning a string, got ~S" format))
    (cond
      (choices-p
       (unless (and choices (listp choices) (every #'stringp choices))
         (fail ":choices must be a non-empty list of strings, got ~S" choices))
       (when (or min-p max-p step-p scale-p)
         (fail ":choices cannot be combined with :min, :max, :step or :scale"))
       (setf min 0
             max (1- (length choices))
             step 1))
      (t
       (unless (and (realp min) (realp max))
         (fail ":min and :max must be real numbers, got ~S and ~S" min max))
       (unless (< min max)
         (fail ":min ~S must be below :max ~S" min max))
       (when (and (eq scale :log) (<= min 0))
         (fail ":log scale needs :min above 0, got ~S" min))
       (when step-p
         (unless (and (realp step) (plusp step))
           (fail ":step must be a positive number, got ~S" step)))
       (when (and (null step) (integerp value))
         (setf step 1))))
    (when (and (numberp bipolar) (not (<= min bipolar max)))
      (fail ":bipolar origin ~S is outside ~S to ~S" bipolar min max))
    (let ((origin (cond ((null bipolar) min)
                        ((numberp bipolar) bipolar)
                        ((<= min 0 max) 0)
                        (t (/ (+ min max) 2)))))
      (when default-p
        (unless (and (realp default) (<= min default max))
          (fail ":default ~S is outside ~S to ~S" default min max)))
      (make-control-spec :min min :max max :scale scale :step step
                         :choices choices :origin origin
                         :default (if default-p default origin)
                         :unit unit :format format))))

(defun value->position (spec value)
  "Position of VALUE in SPEC, a single-float in [0, 1]."
  (let* ((min (control-spec-min spec))
         (max (control-spec-max spec))
         (value (max min (min max value)))
         (position
           (if (eq (control-spec-scale spec) :log)
               (if (<= value 0)
                   0
                   (/ (log (/ (float value 1d0) min)) (log (/ (float max 1d0) min))))
               (/ (- value min) (- max min)))))
    (float (max 0 (min 1 position)) 1f0)))

(defun coerce-like (value like)
  "VALUE as a number of LIKE's type: integer, double-float, else single-float."
  (typecase like
    (integer (round value))
    (double-float (float value 1d0))
    (t (float value 1f0))))

(defun snap-to-step (spec value)
  (let ((step (control-spec-step spec))
        (min (control-spec-min spec)))
    (if step
        (+ min (* step (round (- value min) step)))
        value)))

(defun clamp-to-spec (spec value &optional (like value))
  "VALUE clamped to SPEC's range, as a number of LIKE's type."
  (coerce-like (max (control-spec-min spec) (min (control-spec-max spec) value))
               like))

(defun position->value (spec position like)
  "The value at POSITION (clamped to [0, 1]), snapped to SPEC's step, as a
number of LIKE's type."
  (let* ((min (control-spec-min spec))
         (max (control-spec-max spec))
         (p (max 0 (min 1 (rational position))))
         (value (if (eq (control-spec-scale spec) :log)
                    (* min (exp (* (float p 1d0) (log (/ (float max 1d0) min)))))
                    (+ min (* p (- max min))))))
    (clamp-to-spec spec (snap-to-step spec value) like)))
