(in-package #:sc-imgui.tests)
(in-suite theme)

;;; Themes: palettes, rem/px sizes and ImGui/ImPlot colours.  Headless: the
;;; theme is applied directly, or by running the queued task.

(defun rgba (spec) (gui::parse-color spec))

(defun imgui-color (keyword)
  "ImGui style colour KEYWORD (a COL name) as (r g b a)."
  (vec4-list (cffi:mem-aptr (cffi:foreign-slot-pointer (%imgui:get-style) '(:struct %imgui::im-gui-style)
                                                       '%imgui::colors)
                            '(:struct %imgui::im-vec4) (gui:enum-flags "COL" keyword))))

(defun implot-color (keyword)
  (vec4-list (cffi:mem-aptr (cffi:foreign-slot-pointer (%implot:get-style) '(:struct %implot::im-plot-style)
                                                       '%implot::colors)
                            '(:struct %imgui::im-vec4) (gui:enum-flags "COL" keyword '#:%implot))))

(defun vec4-list (pointer)
  (loop for slot in '(%imgui::x %imgui::y %imgui::z %imgui::w)
        collect (cffi:foreign-slot-value pointer '(:struct %imgui::im-vec4) slot)))

(defun style-value (slot)
  "ImGui style SLOT (a keyword): a float, or (x y) for a pair."
  (let* ((name (find-symbol (symbol-name slot) '#:%imgui))
         (type '(:struct %imgui::im-gui-style)))
    (if (eq :float (cffi:foreign-slot-type type name))
        (cffi:foreign-slot-value (%imgui:get-style) type name)
        (let ((p (cffi:foreign-slot-pointer (%imgui:get-style) type name)))
          (list (cffi:foreign-slot-value p '(:struct %imgui::im-vec2) '%imgui::x)
                (cffi:foreign-slot-value p '(:struct %imgui::im-vec2) '%imgui::y))))))

(defun set-font-size-base (px)
  (setf (cffi:foreign-slot-value (%imgui:get-style) '(:struct %imgui::im-gui-style)
                                 '%imgui::font-size-base)
        (float px 1.0f0)))

(defun queued-task-count () (length gui.runtime::*tasks*))

(defmacro with-test-themes ((&rest names) &body body)
  "Run BODY, then forget the themes NAMES and restore *THEME*."
  `(let ((gui:*theme* gui:*theme*))
     (unwind-protect (progn ,@body)
       (dolist (n ',names) (remhash n gui::*themes*)))))

(defun draw-themed-frame ()
  "A frame using widgets and a plot, so a theme is exercised."
  (with-test-frame ()
    (gui:with-window ("w")
      (gui:text "themed")
      (%imgui:button "b" (vec2 0 0))
      (gui:with-plot ("p" :height 100)
        (gui:plot-lines "l" '(1 2 3))))))

(test shipped-themes-write-their-palettes
  (dolist (case '((:mid-light "#c4c4c4" "#a9a9a9" "#d6d6d6" "#ff9a2e" "#141414" "#8a8a8a")
                  (:dark      "#2f2f2f" "#1d1d1d" "#3d3d3d" "#e8a23a" "#d4d4d4" "#191919")))
    (destructuring-bind (name panel frame control accent text border) case
      (with-headless-imgui ()
        (gui::apply-theme name)
        (is (equal (rgba panel) (imgui-color :window-bg)) "~S window bg" name)
        (is (equal (rgba panel) (imgui-color :popup-bg)))
        (is (equal (rgba frame) (imgui-color :frame-bg)))
        (is (equal (rgba control) (imgui-color :button)))
        (is (equal (rgba accent) (imgui-color :slider-grab)) "~S slider grab" name)
        (is (equal (rgba accent) (imgui-color :check-mark)))
        (is (equal (rgba accent) (imgui-color :button-active)))
        (is (equal (rgba text) (imgui-color :text)))
        (is (equal (rgba border) (imgui-color :border)))
        (is (equal (rgba frame) (implot-color :plot-bg)) "~S plot bg" name)
        (is (equal (rgba panel) (implot-color :frame-bg)))
        (is (equal (rgba text) (implot-color :axis-text)))
        (is (equal (rgba border) (implot-color :axis-grid)))
        (is (equal (rgba accent) (implot-color :selection)))
        (dotimes (i 2) (draw-themed-frame))
        (is (= 0 (%shim:assert-count)) "asserts with ~S: ~A" name (%shim:last-assert))))))

(test every-colour-is-set-by-the-mapping
  (with-headless-imgui ()
    (let ((sentinel (list 0.123f0 0.456f0 0.789f0 0.5f0)))
      (flet ((fill-colors (style type count)
               (let ((colors (cffi:foreign-slot-pointer style type
                                                        (find-symbol "COLORS" (symbol-package (second type))))))
                 (dotimes (i count)
                   (loop for slot in '(%imgui::x %imgui::y %imgui::z %imgui::w)
                         for v in sentinel
                         do (setf (cffi:foreign-slot-value (cffi:mem-aptr colors '(:struct %imgui::im-vec4) i)
                                                           '(:struct %imgui::im-vec4) slot)
                                  v))))))
        (fill-colors (%imgui:get-style) '(:struct %imgui::im-gui-style) %imgui:+col-count+)
        (fill-colors (%implot:get-style) '(:struct %implot::im-plot-style) %implot:+col-count+)
        (gui::apply-theme :mid-light)
        (let ((unset (loop for i below %imgui:+col-count+
                           when (equal sentinel (vec4-list (cffi:mem-aptr
                                                            (cffi:foreign-slot-pointer
                                                             (%imgui:get-style) '(:struct %imgui::im-gui-style)
                                                             '%imgui::colors)
                                                            '(:struct %imgui::im-vec4) i)))
                             collect (%imgui:get-style-color-name i)))
              (unset-plot (loop for i below %implot:+col-count+
                                when (equal sentinel (vec4-list (cffi:mem-aptr
                                                                 (cffi:foreign-slot-pointer
                                                                  (%implot:get-style) '(:struct %implot::im-plot-style)
                                                                  '%implot::colors)
                                                                 '(:struct %imgui::im-vec4) i)))
                                  collect i)))
          (is (null unset) "ImGui colours not set: ~S" unset)
          (is (null unset-plot) "ImPlot colours not set: ~S" unset-plot))))))

(test rem-sizes-scale-with-the-font-size-and-px-sizes-do-not
  (dolist (px '(13 15))
    (with-headless-imgui ()
      (set-font-size-base px)
      (gui::apply-theme :mid-light)
      (flet ((in-rem (n) (* (float n 1.0f0) (float px 1.0f0))))
        (is (equal (list (in-rem 0.38) (in-rem 0.15)) (style-value :frame-padding)) "frame padding at ~D" px)
        (is (equal (list (in-rem 0.46) (in-rem 0.63)) (style-value :item-spacing)))
        (is (= (in-rem 0.92) (style-value :indent-spacing)))
        (is (= (in-rem 0.62) (style-value :scrollbar-size)))
        (is (= 2.0 (style-value :frame-rounding)) "(:px 2) at ~D" px)
        (is (= 1.0 (style-value :window-border-size)))
        (is (= 0.0 (style-value :frame-border-size)))))))

(test base-inheritance-and-partial-overrides
  (with-test-themes (:test-child :test-grandchild)
    (gui:define-theme :test-child :base :dark
                      :palette '(:accent "#00ff00")
                      :style '(:frame-rounding (:px 5) :item-spacing (1 (:px 3))))
    (gui:define-theme :test-grandchild :base :test-child :palette '(:panel (0.5 0.5 0.5)))
    (with-headless-imgui ()
      (set-font-size-base 10)
      (gui::apply-theme :test-grandchild)
      (is (equal (rgba "#00ff00") (imgui-color :slider-grab)) "accent from the parent")
      (is (equal (rgba '(0.5 0.5 0.5)) (imgui-color :window-bg)) "own panel")
      (is (equal (rgba "#1d1d1d") (imgui-color :frame-bg)) "frame from :dark")
      (is (= 5.0 (style-value :frame-rounding)))
      (is (equal '(10.0 3.0) (style-value :item-spacing)) "mixed rem and px pair")
      (is (equal (list (* 0.38f0 10) (* 0.15f0 10)) (style-value :frame-padding)) "from :dark"))
    (is (equal (rgba "#e8a23a") (getf (gui::theme-palette (gui::find-theme :dark)) :accent))
        ":dark is not changed by its children")))

(test colors-overrides-win
  (with-test-themes (:test-overrides)
    (gui:define-theme :test-overrides :base :mid-light
                      :colors '(:button "#ff0000" :plot-lines (0 0 1 0.5)))
    (with-headless-imgui ()
      (gui::apply-theme :test-overrides)
      (is (equal (rgba "#ff0000") (imgui-color :button)))
      (is (equal (rgba '(0 0 1 0.5)) (imgui-color :plot-lines)))
      (is (equal (rgba "#e0e0e0") (imgui-color :button-hovered)) "others still from the palette"))))

(test colour-parsing
  (is (equal (list 1.0 (/ 128 255.0) 0.0 1.0) (gui::parse-color "#ff8000")))
  (is (equal (list 1.0 (/ 128 255.0) 0.0 (/ 64 255.0)) (gui::parse-color "#FF800040")))
  (is (equal '(0.1 0.2 0.3 1.0) (gui::parse-color '(0.1 0.2 0.3))))
  (is (equal '(0.0 1.0 0.5 0.25) (gui::parse-color '(0 1 1/2 0.25))))
  (dolist (bad '("#ff80" "ff8000" "#gg0000" (1 2 3) (0.1 0.2) (0.1 0.2 0.3 0.4 0.5) :red nil))
    (signals error (gui::parse-color bad))))

(defun define-theme-error (&rest args)
  "The message of the error DEFINE-THEME signals for ARGS, or NIL."
  (handler-case (progn (apply #'gui:define-theme :test-bad args) nil)
    (error (e) (princ-to-string e))))

(test define-theme-rejects-bad-data-naming-it
  (with-test-themes (:test-bad)
    (dolist (case '(((:base :dark :palette (:accent "#ff80")) "#ff80" ":ACCENT")
                    ((:base :dark :palette (:panel (2 0 0))) "(2 0 0)" ":PANEL")
                    ((:base :dark :palette (:nope "#000000")) ":NOPE")
                    ((:base :dark :palette (:series ("#000000" "oops"))) "oops")
                    ((:base :dark :colors (:no-such-colour "#000000")) ":NO-SUCH-COLOUR")
                    ((:base :dark :colors (:button "#xyz")) "#xyz")
                    ((:base :dark :style (:no-such-size 1)) ":NO-SUCH-SIZE")
                    ((:base :dark :style (:frame-padding 1)) ":FRAME-PADDING")
                    ((:base :dark :style (:frame-rounding (:pixels 2))) ":FRAME-ROUNDING")
                    ((:base :no-such-theme) ":NO-SUCH-THEME")
                    ((:palette (:accent "#ff0000")) ":PANEL")))
      (destructuring-bind (args &rest needles) case
        (let ((message (apply #'define-theme-error args)))
          (is (stringp message) "~S should be rejected" args)
          (dolist (n needles)
            (is (and message (search n message)) "~S: ~S not in ~S" args n message)))))
    (is (null (gethash :test-bad gui::*themes*)) "a rejected theme is not defined")))

(test theme-color-matches-gui-color
  (let ((gui:*theme* :mid-light))
    (is (= (gui:color 1.0 (/ #x9a 255.0) (/ #x2e 255.0)) (gui:theme-color :accent)))
    (is (= (gui:color (/ #x1c 255.0) (/ #x5f 255.0) (/ #x7a 255.0)) (gui:theme-color :series)))
    (signals error (gui:theme-color :no-such-role)))
  (let ((gui:*theme* :dark))
    (is (= (apply #'gui:color (rgba "#2f2f2f")) (gui:theme-color :panel)))))

(test set-theme-unknown-name-lists-known-themes
  (let ((gui:*theme* :mid-light)
        (message (handler-case (progn (gui:set-theme :no-such-theme) nil)
                   (error (e) (princ-to-string e)))))
    (is (stringp message))
    (dolist (s '(":NO-SUCH-THEME" ":MID-LIGHT" ":DARK"))
      (is (and message (search s message)) "~A in ~S" s message))
    (is (eq :mid-light gui:*theme*))))

(test without-a-window-set-theme-and-set-font-size-only-set-variables
  (with-clean-registry ()
    (let ((gui:*theme* :mid-light) (gui:*font-size* 15))
      (is (eq :dark (gui:set-theme :dark)))
      (is (eq :dark gui:*theme*))
      (is (= 13 (gui:set-font-size 13)))
      (is (= 13 gui:*font-size*))
      (is (= 0 (queued-task-count))))))

(test with-a-window-each-change-queues-one-task-that-applies-it
  (dolist (state '(:showing :hidden))
    (with-clean-registry ()
      (let ((gui:*theme* :mid-light) (gui:*font-size* 15))
        (with-headless-imgui ()
          (set-font-size-base 15)
          (gui::apply-theme :mid-light)
          (with-loop-state (state)
            (gui:set-theme :dark)
            (is (= 1 (queued-task-count)) "set-theme queues one task when ~S" state)
            (is (equal (rgba "#c4c4c4") (imgui-color :window-bg)) "not applied before the task runs")
            (gui.runtime:run-queued-tasks)
            (is (equal (rgba "#2f2f2f") (imgui-color :window-bg)))
            (gui:set-font-size 13)
            (is (= 1 (queued-task-count)) "set-font-size queues one task when ~S" state)
            (gui.runtime:run-queued-tasks)
            (is (= 13.0 (style-value :font-size-base)))
            (is (equal (list (* 0.38f0 13) (* 0.15f0 13)) (style-value :frame-padding)))
            (is (equal (rgba "#2f2f2f") (imgui-color :window-bg)) "still :dark")
            (dotimes (i 2) (draw-themed-frame))
            (is (= 0 (%shim:assert-count)))))))))

(test redefining-the-current-theme-reapplies-it
  (with-clean-registry ()
    (with-test-themes (:test-live)
      (gui:define-theme :test-live :base :mid-light)
      (setf gui:*theme* :test-live)
      (with-headless-imgui ()
        (gui::apply-theme)
        (with-loop-state (:showing)
          (is (eq :test-live (gui:define-theme :test-live :base :mid-light
                                               :palette '(:panel "#123456"))))
          (is (= 1 (queued-task-count)))
          (gui.runtime:run-queued-tasks)
          (is (equal (rgba "#123456") (imgui-color :window-bg))))))))

(test shipped-themes-define-error
  (dolist (name '(:mid-light :dark))
    (let ((gui:*theme* name))
      (is (integerp (gui:theme-color :error)))))
  (is (equal (rgba "#b3261e") (getf (gui::theme-palette (gui::find-theme :mid-light)) :error)))
  (is (equal (rgba "#e5534b") (getf (gui::theme-palette (gui::find-theme :dark)) :error))))

(test theme-without-base-needs-error
  (with-test-themes (:test-no-error)
    (let ((palette (loop for (k v) on (gui::theme-palette (gui::find-theme :dark)) by #'cddr
                         unless (eq k :error) append (list k v))))
      (signals error (gui:define-theme :test-no-error :palette palette)))))

(test derived-theme-inherits-error
  (with-test-themes (:test-derived)
    (gui:define-theme :test-derived :base :dark :palette '(:accent "#4fb3d9"))
    (is (equal (rgba "#e5534b") (getf (gui::theme-palette (gui::find-theme :test-derived)) :error)))))
