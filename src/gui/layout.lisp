(in-package #:gui)

(defun same-line (&optional (offset 0.0) (spacing -1.0))
  (%imgui:same-line (float offset 1.0f0) (float spacing 1.0f0)))
(defun new-line () (%imgui:new-line))
(defun separator () (%imgui:separator))
(defun spacing () (%imgui:spacing))
(defun indent (&optional (width 0.0)) (%imgui:indent (float width 1.0f0)))
(defun unindent (&optional (width 0.0)) (%imgui:unindent (float width 1.0f0)))
(defun set-next-item-width (width) (%imgui:set-next-item-width (float width 1.0f0)))

(defmacro with-row (() &body body)
  "Run BODY forms on one line: (same-line) between consecutive top-level forms."
  `(progn ,@(loop for (form . more) on body
                  collect form
                  when more collect '(same-line))))

(defmacro with-grid ((&key (columns 2) id flags) &body body)
  "A table of COLUMNS columns; each top-level form lands in the next cell."
  (let ((id (or id (format nil "grid-~(~x~)" (sxhash body)))))
    `(when (%imgui:begin-table ,id ,columns ,(%flags-form "TABLE-FLAGS" flags) (vec2 0 0) 0.0f0)
       (unwind-protect
            (progn ,@(loop for form in body
                           collect '(%imgui:table-next-column)
                           collect form))
         (%imgui:end-table)))))
