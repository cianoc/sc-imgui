(in-package #:gui.runtime)

;;; Per-frame panel drawing with error isolation.

(defvar *debug-on-error* nil
  "When true, panel errors reach the debugger (with RETRY-PANEL and
DISABLE-PANEL restarts) instead of being caught and shown in a failed window.")

(defvar *refit-windows* nil
  "True while a panel that was just redefined is called: GUI:WITH-WINDOW then
refits each of its windows to its contents.")

(defvar *retry-button-centers* (make-hash-table :test 'equal)
  "Entry name -> (x y) center of its failed window's Retry button.  For tests.")

(defun %backtrace-string ()
  (with-output-to-string (s) (sb-debug:print-backtrace :count 30 :stream s)))

(defun %call-panel (entry)
  "Call ENTRY's function; return normally whether or not it failed.  Returns
true only when the panel function returned normally."
  (let ((name (gui-entry-name entry)))
    (cffi:with-foreign-object (state '(:struct %imgui::im-gui-error-recovery-state))
      (%imgui:error-recovery-store-state state)
      (unwind-protect
           (if *debug-on-error*
               (let ((seen nil))
                 (restart-case
                     ;; Enter the debugger here, inside the RESTART-CASE, so
                     ;; that no outer handler (the frame loop's, which would
                     ;; close the window, or trivial-main-thread's runner, which
                     ;; would drop the condition) ever sees the error.
                     (handler-bind ((error (lambda (c)
                                             (setf seen c)
                                             (invoke-debugger c))))
                       (funcall (fdefinition (gui-entry-function-name entry)))
                       t)
                   (retry-panel () :report "Leave the panel enabled; retry next frame." nil)
                   (disable-panel ()
                     :report "Mark the panel failed and show its failed window."
                     (mark-gui-failed name seen)
                     nil)))
               (block panel
                 (handler-bind
                     ((error (lambda (c)
                               (let ((bt (ignore-errors (%backtrace-string))))
                                 (mark-gui-failed name c)
                                 (report-error name c bt))
                               (return-from panel nil))))
                   (funcall (fdefinition (gui-entry-function-name entry)))
                   t)))
        ;; Pop anything the panel left open so later panels are not nested in it.
        (%imgui:error-recovery-try-to-recover-state state)))))

(defun %truncate-text (string limit)
  (if (> (length string) limit) (subseq string 0 limit) string))

(defun %draw-failed-window (entry)
  (let* ((name (gui-entry-name entry))
         (text (%truncate-text
                (handler-case (princ-to-string (gui-entry-failure entry))
                  (error () "<unprintable condition>"))
                500)))
    (let ((open (%imgui:begin (format nil "~A (failed)##failed-~A" name name)
                              (cffi:null-pointer) 0)))
      (unwind-protect
           (when open
             (%imgui:text-unformatted text (cffi:null-pointer))
             (when (%imgui:button "Retry" '(%imgui::x 0.0f0 %imgui::y 0.0f0))
               (clear-gui-failure name))
             (let ((min (%imgui:get-item-rect-min))
                   (max (%imgui:get-item-rect-max)))
               (setf (gethash name *retry-button-centers*)
                     (list (/ (+ (getf min '%imgui::x) (getf max '%imgui::x)) 2)
                           (/ (+ (getf min '%imgui::y) (getf max '%imgui::y)) 2)))))
        (%imgui:end)))))

(defun draw-registered-guis ()
  "Draw every visible panel, isolating errors; failed panels get a window."
  (dolist (entry (registry-snapshot))
    (when (gui-entry-visible entry)
      (if (gui-entry-failure entry)
          (%draw-failed-window entry)
          (let* ((name (gui-entry-name entry))
                 (refit (gui-refit-pending name)))
            ;; A redefined panel's windows refit once: the mark is cleared only
            ;; after a call that returned normally.
            (when (and (let ((*refit-windows* (and refit t)))
                         (%call-panel entry))
                       refit)
              (clear-gui-refit name refit)))))))
