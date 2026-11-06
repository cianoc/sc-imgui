(in-package #:sc-imgui.tests)

;;; One suite per area.  Later tasks add test files to sc-imgui/tests and put
;;; `(in-suite <name>)` at the top; the suites below already exist so that
;;; `make test SUITE=<name>` works from the start.

(def-suite all :description "Every sc-imgui test.")

(macrolet ((define-suites (&rest names)
             `(progn ,@(loop for n in names
                             collect `(def-suite ,n :in all)))))
  (define-suites generator bindings registry frame loop scopes widgets plots draw theme controls examples))

(defun run-suites (&optional suite)
  "Run SUITE (a name such as \"generator\"; NIL or \"\" means all).  Returns
true only when every check passed."
  (let* ((name (and suite (plusp (length suite)) (string-upcase suite)))
         (symbol (if name (find-symbol name '#:sc-imgui.tests) 'all)))
    (unless (and symbol (get-test symbol))
      (format *error-output* "~&Unknown suite ~S~%" suite)
      (return-from run-suites nil))
    (let ((results (run symbol)))
      (explain! results)
      (results-status results))))
