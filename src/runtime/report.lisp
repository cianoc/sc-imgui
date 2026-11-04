(in-package #:gui.runtime)

(defvar *report-stream* *standard-output*
  "Where errors are reported.  Captured at load time; the frame loop rebinds it.")

(defun report-error (source condition &optional backtrace-string)
  (let ((stream *report-stream*))
    (format stream "~&[gui] ~A failed: ~A~%" source condition)
    (when backtrace-string
      (format stream "~A~%" backtrace-string))
    (finish-output stream)))
