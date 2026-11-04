(in-package #:gui.runtime)

;;; Panel registry: an ordered list plus an EQUAL hash table, both guarded by
;;; one lock.  Safe from any thread.

(defstruct gui-entry
  name function-name (visible t) (failure nil)
  ;; NIL, or a fresh token set when the panel is redefined: its windows refit
  ;; to their contents on its next successful call (see DRAW-REGISTERED-GUIS).
  (refit nil))

(defvar *registry-lock* (bt2:make-lock :name "gui registry"))
(defvar *entries* '() "Entries in registration order.")
(defvar *entry-table* (make-hash-table :test 'equal))

(defmacro with-registry-lock (&body body)
  `(bt2:with-lock-held (*registry-lock*) ,@body))

(defun register-gui (name function-name)
  "Register NAME, or update it in place (keeping position and visibility,
clearing any failure and marking its windows for a refit).  Returns the entry."
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (if entry
          (setf (gui-entry-function-name entry) function-name
                (gui-entry-failure entry) nil
                (gui-entry-refit entry) (list name))
          (let ((new (make-gui-entry :name name :function-name function-name)))
            (setf (gethash name *entry-table*) new
                  *entries* (nconc *entries* (list new))
                  entry new)))
      entry)))

(defun unregister-gui (name)
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (when entry
        (remhash name *entry-table*)
        (setf *entries* (delete entry *entries* :test #'eq))
        t))))

(defun find-gui (name)
  (with-registry-lock (values (gethash name *entry-table*))))

(defun set-gui-visible (name visible)
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (when entry (setf (gui-entry-visible entry) (and visible t))))))

(defun mark-gui-failed (name condition)
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (when entry (setf (gui-entry-failure entry) condition)))))

(defun clear-gui-failure (name)
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (when entry (setf (gui-entry-failure entry) nil)))))

(defun gui-refit-pending (name)
  "The refit token of NAME's entry, or NIL when no refit is pending."
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (and entry (gui-entry-refit entry)))))

(defun clear-gui-refit (name token)
  "Clear NAME's pending refit if it is still TOKEN (a later redefinition keeps
its own refit pending)."
  (with-registry-lock
    (let ((entry (gethash name *entry-table*)))
      (when (and entry (eq (gui-entry-refit entry) token))
        (setf (gui-entry-refit entry) nil)))))

(defun registry-snapshot ()
  "A fresh list of the entries, in registration order."
  (with-registry-lock (copy-list *entries*)))

(defun %reset-registry ()
  "Tests only: empty the registry and the task queue."
  (with-registry-lock
    (setf *entries* '())
    (clrhash *entry-table*))
  (%reset-tasks)
  nil)
