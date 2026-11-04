(in-package #:gui)

;;; Place-based widgets.  Each macro takes a setf place, reads it, calls the
;;; functional -VALUE variant and writes back only on change; it returns true
;;; on change.  The -VALUE functions return (values new-value changed-p).

(define-condition widget-value-error (type-error)
  ((label :initarg :label :reader widget-value-error-label))
  (:report (lambda (c s)
             (format s "Widget ~S: value ~S is not of type ~S."
                     (widget-value-error-label c) (type-error-datum c)
                     (type-error-expected-type c)))))

(defun %check (label value type)
  (unless (typep value type)
    (error 'widget-value-error :label label :datum value :expected-type type)))

(defun %float-type (value)
  (if (typep value 'double-float) 'double-float 'single-float))

(defun %out-float (value) (coerce value 'single-float))

(defun expand-place-widget (function label place args env)
  "Form calling FUNCTION with LABEL, PLACE's current value and ARGS, writing a
changed value back to PLACE and returning the changed-p."
  (multiple-value-bind (vars vals stores setter getter) (get-setf-expansion place env)
    (let ((new (gensym "NEW")) (changed (gensym "CHANGED")))
      `(let* (,@(mapcar #'list vars vals))
         (multiple-value-bind (,new ,changed) (,function ,label ,getter ,@args)
           (when ,changed
             (let ((,(first stores) ,new)) ,setter))
           ,changed)))))

(defmacro define-place-widget (name value-name)
  `(defmacro ,name (label place &rest args &environment env)
     (expand-place-widget ',value-name label place args env)))

(defun slider-value (label value &key (min 0) (max 1) (scale :linear) format)
  (%check label value 'real)
  (%check label min 'real)
  (%check label max 'real)
  (let ((flags (ecase scale
                 (:linear 0)
                 (:log %imgui:+slider-flags-logarithmic+)))
        (buf (scratch)))
    (if (integerp value)
        (progn
          (setf (cffi:mem-ref buf :int) value)
          (let ((changed (%imgui:slider-int label buf (round min) (round max)
                                            (or format "%d") flags)))
            (values (if changed (cffi:mem-ref buf :int) value) changed)))
        (progn
          (setf (cffi:mem-ref buf :float) (%out-float value))
          (let ((changed (%imgui:slider-float label buf (%out-float min) (%out-float max)
                                              (or format "%.3f") flags)))
            (values (if changed
                        (coerce (cffi:mem-ref buf :float) (%float-type value))
                        value)
                    changed))))))

(defun drag-value (label value &key (speed 0.01) (min 0) (max 0) format)
  (%check label value 'real)
  (%check label speed 'real)
  (%check label min 'real)
  (%check label max 'real)
  (let ((buf (scratch)))
    (if (integerp value)
        (progn
          (setf (cffi:mem-ref buf :int) value)
          (let ((changed (%imgui:drag-int label buf (%out-float speed) (round min) (round max)
                                          (or format "%d") 0)))
            (values (if changed (cffi:mem-ref buf :int) value) changed)))
        (progn
          (setf (cffi:mem-ref buf :float) (%out-float value))
          (let ((changed (%imgui:drag-float label buf (%out-float speed)
                                            (%out-float min) (%out-float max)
                                            (or format "%.3f") 0)))
            (values (if changed
                        (coerce (cffi:mem-ref buf :float) (%float-type value))
                        value)
                    changed))))))

(defun checkbox-value (label value)
  (let ((buf (scratch)))
    (setf (cffi:mem-ref buf :uint8) (if value 1 0))
    (let ((changed (%imgui:checkbox label buf)))
      (values (if changed (/= 0 (cffi:mem-ref buf :uint8)) (and value t)) changed))))

(defun combo-value (label index items)
  (%check label index 'integer)
  (%check label items 'list)
  (dolist (item items) (%check label item 'string))
  (let ((new index) (changed nil)
        (preview (if (and (>= index 0) (< index (length items))) (nth index items) "")))
    (when (%imgui:begin-combo label preview 0)
      (unwind-protect
           (loop for item in items
                 for i from 0
                 do (with-id (i)
                      (when (%imgui:selectable-bool item (= i index) 0 (vec2 0 0))
                        (setf new i changed t))))
        (%imgui:end-combo)))
    (values new changed)))

(defun %utf8-truncated (string max-bytes)
  "UTF-8 octets of STRING, cut at a character boundary to at most MAX-BYTES."
  (let* ((octets (sb-ext:string-to-octets string :external-format :utf-8))
         (cut (min max-bytes (length octets))))
    (loop while (and (> cut 0) (< cut (length octets))
                     (= (logand (aref octets cut) #xC0) #x80))
          do (decf cut))
    (subseq octets 0 cut)))

(defun input-text-value (label value &key (max-length 256))
  (%check label value 'string)
  (%check label max-length '(integer 0))
  (let ((octets (%utf8-truncated value max-length))
        (buf (cffi:foreign-alloc :uint8 :count (1+ max-length) :initial-element 0)))
    (unwind-protect
         (progn
           (dotimes (i (length octets)) (setf (cffi:mem-ref buf :uint8 i) (aref octets i)))
           (let ((changed (%imgui:input-text label buf (1+ max-length) 0
                                             (cffi:null-pointer) (cffi:null-pointer))))
             (if changed
                 (let* ((n (or (loop for i below (1+ max-length)
                                     when (zerop (cffi:mem-ref buf :uint8 i)) return i)
                               max-length))
                        (bytes (make-array n :element-type '(unsigned-byte 8))))
                   (dotimes (i n) (setf (aref bytes i) (cffi:mem-ref buf :uint8 i)))
                   (values (sb-ext:octets-to-string
                            bytes :external-format '(:utf-8 :replacement #\?))
                           t))
                 (values value nil))))
      (cffi:foreign-free buf))))

(define-place-widget slider slider-value)
(define-place-widget drag drag-value)
(define-place-widget checkbox checkbox-value)
(define-place-widget combo combo-value)
(define-place-widget input-text input-text-value)

(defun button (label &key (width 0) (height 0))
  (%imgui:button label (vec2 width height)))

(defun text (control-string &rest args)
  (%imgui:text-unformatted
   (if args (apply #'format nil control-string args) control-string)
   nil))
