;;;; Test entry point: sbcl --non-interactive --load tests/run.lisp
;;;; Environment: SUITE=<name> runs one suite, otherwise all.
;;;; Exit status is 0 only when everything loaded and every check passed.

(require :asdf)

(defvar *repo-root*
  (make-pathname :name nil :type nil :version nil
                 :defaults (merge-pathnames "../" (or *load-truename* *default-pathname-defaults*))))

(unless (find-package '#:ql)
  (let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file setup) (load setup))))

(pushnew *repo-root* asdf:*central-registry* :test #'equal)

(defun fail (control &rest args)
  (format *error-output* "~&~?~%" control args)
  (finish-output *error-output*)
  (sb-ext:exit :code 2 :abort t))

(handler-bind ((error (lambda (e)
                        (sb-debug:print-backtrace :count 25 :stream *error-output*)
                        (fail "Failed to load sc-imgui/tests: ~A" e))))
  (if (find-package '#:ql)
      (funcall (intern "QUICKLOAD" '#:ql) :sc-imgui/tests :silent t)
      (asdf:load-system :sc-imgui/tests)))

(let ((ok (handler-case
              (funcall (intern "RUN-SUITES" '#:sc-imgui.tests)
                       (sb-posix:getenv "SUITE"))
            (error (e) (fail "Test run failed: ~A" e)))))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1) :abort t))
