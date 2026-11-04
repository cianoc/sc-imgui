(in-package #:gui.runtime)

;;; Task queue: a list (newest first) under its own lock, swapped out whole
;;; when run.

(defvar *task-lock* (bt2:make-lock :name "gui tasks"))
(defvar *tasks* '())

(defun enqueue-task (thunk)
  (bt2:with-lock-held (*task-lock*) (push thunk *tasks*))
  thunk)

(defun %reset-tasks ()
  (bt2:with-lock-held (*task-lock*) (setf *tasks* '())))

(defun run-queued-tasks ()
  "Run queued tasks in order.  Errors are reported and do not stop the rest.
Returns the number of tasks run."
  (let ((tasks (bt2:with-lock-held (*task-lock*)
                 (prog1 (nreverse *tasks*) (setf *tasks* '())))))
    (dolist (task tasks)
      (handler-case (funcall task)
        (error (e) (report-error :task e))))
    (length tasks)))
