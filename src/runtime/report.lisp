(in-package #:gui.runtime)

(defvar *report-stream* *standard-output*
  "Where errors are reported.  Captured at load time; GUI:START setfs it
globally to the *standard-output* of the thread that called it.")

(defun %safe-princ (object)
  (handler-case (princ-to-string object)
    (serious-condition ()
      (handler-case (format nil "<unprintable ~S>" (type-of object))
        (serious-condition () "<unprintable>")))))

(defun report-error (source condition &optional backtrace-string)
  "Report CONDITION for SOURCE to *REPORT-STREAM*.  Never signals: an
unprintable condition or a dead stream falls back to *ERROR-OUTPUT*, then to
silence."
  (let ((text (format nil "~&[gui] ~A failed: ~A~%~@[~A~%~]"
                      (%safe-princ source) (%safe-princ condition)
                      (and backtrace-string (%safe-princ backtrace-string)))))
    (flet ((try (stream)
             (handler-case (progn (write-string text stream)
                                  (finish-output stream)
                                  t)
               (serious-condition () nil))))
      (or (try *report-stream*)
          (try *error-output*)
          nil))))
