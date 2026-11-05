(in-package #:gui)

(defmacro define-gui (name lambda-list &body body)
  "Define panel function NAME and register it (replacing in place on redefinition)."
  (when lambda-list
    (error "define-gui ~S: panels take no arguments, got lambda list ~S" name lambda-list))
  `(progn (defun ,name () ,@body)
          (gui.runtime:register-gui ',name ',name)
          ',name))

(defun show (name) (gui.runtime:set-gui-visible name t) name)
(defun hide (name) (gui.runtime:set-gui-visible name nil) name)
(defun remove (name) (gui.runtime:unregister-gui name))
(defun call-in-gui-thread (thunk)
  (prog1 (gui.runtime:enqueue-task thunk)
    (gui.runtime:wake-loop)))
