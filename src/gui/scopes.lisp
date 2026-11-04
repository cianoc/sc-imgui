(in-package #:gui)

(defmacro with-window ((title &key flags) &body body)
  "Begin/End; BODY runs only when Begin returns true.  End always runs."
  `(progn
     (let ((open (%imgui:begin ,title (cffi:null-pointer) ,(%flags-form "WINDOW-FLAGS" flags))))
       (unwind-protect (when open ,@body)
         (%imgui:end)))))

(defmacro with-group (() &body body)
  `(progn (%imgui:begin-group)
          (unwind-protect (progn ,@body) (%imgui:end-group))))

(defmacro with-child ((id &key (width 0) (height 0) border) &body body)
  `(let ((open (%imgui:begin-child-str
                ,id (vec2 ,width ,height)
                (if ,border %imgui:+child-flags-borders+ %imgui:+child-flags-none+) 0)))
     (unwind-protect (when open ,@body) (%imgui:end-child))))

(defmacro with-section ((label &key default-open) &body body)
  `(when (%imgui:collapsing-header-tree-node-flags
          ,label (if ,default-open %imgui:+tree-node-flags-default-open+ 0))
     ,@body))

(defmacro with-id ((object) &body body)
  `(progn (push-object-id ,object)
          (unwind-protect (progn ,@body) (%imgui:pop-id))))

(defmacro with-disabled ((&optional (disabled t)) &body body)
  `(progn (%imgui:begin-disabled (and ,disabled t))
          (unwind-protect (progn ,@body) (%imgui:end-disabled))))

(defmacro with-style ((&rest specs) &body body)
  "Each spec: (:color name r g b [a]), (:var name value) or (:var name x y)."
  (let ((colors (gensym "COLORS")) (vars (gensym "VARS")))
    `(let ((,colors 0) (,vars 0))
       (unwind-protect
            (progn
              ,@(loop for spec in specs
                      collect
                      (destructuring-bind (kind name &rest args) spec
                        (ecase kind
                          (:color
                           (destructuring-bind (r g b &optional (a 1.0)) args
                             `(progn (%imgui:push-style-color-vec4
                                      ,(%flags-form "COL" name)
                                      (list '%imgui::x (float ,r 1.0f0) '%imgui::y (float ,g 1.0f0)
                                            '%imgui::z (float ,b 1.0f0) '%imgui::w (float ,a 1.0f0)))
                                     (incf ,colors))))
                          (:var
                           (destructuring-bind (x &optional (y nil y-p)) args
                             `(progn ,(if y-p
                                          `(%imgui:push-style-var-vec2 ,(%flags-form "STYLE-VAR" name)
                                                                       (vec2 ,x ,y))
                                          `(%imgui:push-style-var-float ,(%flags-form "STYLE-VAR" name)
                                                                        (float ,x 1.0f0)))
                                     (incf ,vars)))))))
              ,@body)
         (when (plusp ,vars) (%imgui:pop-style-var ,vars))
         (when (plusp ,colors) (%imgui:pop-style-color ,colors))))))
