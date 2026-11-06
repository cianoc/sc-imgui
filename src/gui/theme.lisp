(in-package #:gui)

;;; Themes: a palette of colour roles mapped onto every ImGui and ImPlot
;;; colour, plus style sizes in rem (multiples of the base font size) or
;;; pixels.  Themes are data, defined with DEFINE-THEME and applied on the GUI
;;; thread between frames.

(defvar *theme* :mid-light
  "Name of the theme applied when the window is created.  Change it with
SET-THEME, which also applies it to a window that exists.")

(defvar *themes* (make-hash-table :test 'eq :synchronized t)
  "Theme name to THEME.")

(defstruct (theme (:constructor %make-theme (palette style colors)))
  palette   ; plist role -> (r g b a); :series -> list of (r g b a)
  style     ; plist size keyword -> (:rem n) / (:px n) / (:pair a b)
  colors)   ; plist COL keyword -> (r g b a)

(defparameter *palette-roles*
  '(:background :panel :title :frame :frame-hover :control :control-hover
    :border :text :text-dim :accent :accent-text :series)
  "Every palette role a theme must define.")

;;; Colours

(defun parse-color (spec &optional (what "colour"))
  "SPEC, a \"#rrggbb\" or \"#rrggbbaa\" string or an (r g b [a]) list of reals
in 0-1, as a list of four single-floats.  An error names SPEC and WHAT."
  (flet ((bad (why) (error "Bad colour ~S for ~A: ~A" spec what why)))
    (typecase spec
      (string
       (unless (and (member (length spec) '(7 9)) (char= #\# (char spec 0)))
         (bad "expected \"#rrggbb\" or \"#rrggbbaa\""))
       (let ((bytes (loop for i from 1 below (length spec) by 2
                          collect (or (ignore-errors (parse-integer spec :start i :end (+ i 2)
                                                                         :radix 16))
                                      (bad "not hexadecimal")))))
         (mapcar (lambda (b) (/ b 255.0)) (if (= 3 (length bytes)) (append bytes '(255)) bytes))))
      (cons
       (unless (and (member (length spec) '(3 4)) (every #'realp spec))
         (bad "expected a list of three or four reals"))
       (unless (every (lambda (x) (<= 0 x 1)) spec)
         (bad "components must be between 0 and 1"))
       (let ((c (mapcar (lambda (x) (float x 1.0)) spec)))
         (if (= 3 (length c)) (append c '(1.0)) c)))
      (t (bad "expected a \"#rrggbb\" string or an (r g b [a]) list")))))

(defun %plist-pairs (plist what)
  (unless (and (listp plist) (evenp (length plist)))
    (error "~A must be a property list, got ~S" what plist))
  (loop for (k v) on plist by #'cddr collect (cons k v)))

(defun %parse-palette-entry (role spec)
  (unless (member role *palette-roles*)
    (error "Unknown palette role ~S.  Roles: ~{~S~^, ~}" role *palette-roles*))
  (if (eq role :series)
      (progn (unless (and (consp spec) (every (lambda (c) (or (stringp c) (consp c))) spec))
               (error "Palette :series must be a list of colours, got ~S" spec))
             (mapcar (lambda (c) (parse-color c "palette role :series")) spec))
      (parse-color spec (format nil "palette role ~S" role))))

(defun %color-index (keyword)
  "ImGui's colour index for the COL keyword KEYWORD, or an error naming it."
  (handler-case (enum-value "COL" keyword)
    (error () (error "Unknown ImGui colour ~S in :colors (no constant %imgui:+col-~(~A~)+)"
                     keyword keyword))))

;;; Sizes

(defun %style-slot (key)
  "The ImGuiStyle slot symbol for KEY and its kind, :float or :pair."
  (let* ((type '(:struct %imgui::im-gui-style))
         (slot (find-symbol (symbol-name key) '#:%imgui)))
    (unless (and slot (member slot (cffi:foreign-slot-names type)))
      (error "Unknown style size ~S (no ImGuiStyle field of that name)" key))
    (let ((slot-type (cffi:foreign-slot-type type slot)))
      (cond ((eq slot-type :float) (values slot :float))
            ((equal slot-type '(:struct %imgui::im-vec2)) (values slot :pair))
            (t (error "Style ~S is not a size (ImGuiStyle field type ~S)" key slot-type))))))

(defun %parse-size (key spec)
  "A number is rem, (:px n) is pixels."
  (cond ((realp spec) (list :rem spec))
        ((and (consp spec) (eq (first spec) :px) (= 2 (length spec)) (realp (second spec)))
         (list :px (second spec)))
        (t (error "Bad size ~S for style ~S: expected a number of rem or (:px n)" spec key))))

(defun %parse-style-entry (key spec)
  (multiple-value-bind (slot kind) (%style-slot key)
    (declare (ignore slot))
    (if (eq kind :float)
        (%parse-size key spec)
        (progn
          (unless (and (consp spec) (= 2 (length spec)) (not (eq (first spec) :px)))
            (error "Bad size ~S for style ~S: expected a pair (x y)" spec key))
          (list :pair (%parse-size key (first spec)) (%parse-size key (second spec)))))))

(defun %pixels (size base)
  (destructuring-bind (unit n) size
    (float (if (eq unit :rem) (* (float n 1.0) base) n) 1.0)))

;;; Defining and finding themes

(defun %merge (base pairs)
  "BASE plist with each (key . value) of PAIRS set, key by key."
  (let ((plist (copy-list base)))
    (loop for (k . v) in pairs do (setf (getf plist k) v))
    plist))

(defun find-theme (name)
  (or (gethash name *themes*)
      (error "Unknown theme ~S.  Known themes: ~{~S~^, ~}" name
             (sort (loop for k being the hash-keys of *themes* collect k) #'string<))))

(defun define-theme (name &key base palette style colors)
  "Define or redefine the theme NAME.  BASE names a theme whose palette, style
and colors are copied first; PALETTE, STYLE and COLORS then override them key
by key.  Colours are \"#rrggbb\", \"#rrggbbaa\" or (r g b [a]) lists of 0-1
reals.  Style sizes are numbers of rem (times the base font size) or (:px n);
pairs are two-element lists.  COLORS overrides individual ImGui colours by COL
keyword.  Everything is checked here.  Redefining the current theme applies it
to a window that exists.  Returns NAME."
  (let* ((parent (and base (find-theme base)))
         (theme (%make-theme
                 (%merge (and parent (theme-palette parent))
                         (loop for (k . v) in (%plist-pairs palette ":palette")
                               collect (cons k (%parse-palette-entry k v))))
                 (%merge (and parent (theme-style parent))
                         (loop for (k . v) in (%plist-pairs style ":style")
                               collect (cons k (%parse-style-entry k v))))
                 (%merge (and parent (theme-colors parent))
                         (loop for (k . v) in (%plist-pairs colors ":colors")
                               do (%color-index k)
                               collect (cons k (parse-color v (format nil "colour ~S" k))))))))
    (let ((missing (remove-if (lambda (r) (getf (theme-palette theme) r)) *palette-roles*)))
      (when missing
        (error "Theme ~S: the palette is missing ~{~S~^, ~} (give them, or a :base)" name missing)))
    (setf (gethash name *themes*) theme)
    (when (eq name *theme*) (%reapply-theme))
    name))

(defun %reapply-theme ()
  (when (gui.runtime:window-open-p)
    (call-in-gui-thread (lambda () (apply-theme)))))

(defun set-theme (name)
  "Make NAME the current theme and apply it, between frames, to a window that
exists (showing or hidden).  Returns NAME."
  (find-theme name)
  (setf *theme* name)
  (%reapply-theme)
  name)

(defun set-font-size (px)
  "Set *FONT-SIZE* to PX and, if a window exists, make PX ImGui's base font
size between frames and reapply the current theme so rem sizes follow.
Returns PX."
  (check-type px (real (0)))
  (setf *font-size* px)
  (when (gui.runtime:window-open-p)
    (call-in-gui-thread
     (lambda ()
       (setf (cffi:foreign-slot-value (%imgui:get-style) '(:struct %imgui::im-gui-style)
                                      '%imgui::font-size-base)
             (float px 1.0))
       (apply-theme))))
  px)

(defun theme-color (role)
  "The current theme's colour for ROLE, packed as COLOR does (for :series, the
first colour).  Plain Lisp: safe from any thread."
  (unless (member role *palette-roles*)
    (error "Unknown palette role ~S.  Roles: ~{~S~^, ~}" role *palette-roles*))
  (let ((c (getf (theme-palette (find-theme *theme*)) role)))
    (apply #'color (if (eq role :series) (first c) c))))

(defun theme-series ()
  "The current theme's :series colours, or NIL if *THEME* names no theme."
  (let ((theme (gethash *theme* *themes*)))
    (and theme (getf (theme-palette theme) :series))))

;;; Palette -> ImGui and ImPlot colours.  A source is a role, (role alpha) for
;;; the role's colour at that alpha, or :none (transparent).

(defparameter *imgui-color-map*
  '((:text :text) (:text-disabled :text-dim)
    (:window-bg :panel) (:child-bg :panel) (:popup-bg :panel)
    (:border :border) (:border-shadow :none)
    (:frame-bg :frame) (:frame-bg-hovered :frame-hover) (:frame-bg-active :frame-hover)
    (:title-bg :title) (:title-bg-active :title) (:title-bg-collapsed :title)
    (:menu-bar-bg :title)
    (:scrollbar-bg :frame) (:scrollbar-grab :control)
    (:scrollbar-grab-hovered :control-hover) (:scrollbar-grab-active :accent)
    (:check-mark :accent) (:checkbox-selected-bg :frame)
    (:slider-grab :accent) (:slider-grab-active :accent)
    (:button :control) (:button-hovered :control-hover) (:button-active :accent)
    (:header :control) (:header-hovered :control-hover) (:header-active :accent)
    (:separator :border) (:separator-hovered (:accent 0.6)) (:separator-active :accent)
    (:resize-grip (:border 0.5)) (:resize-grip-hovered :control-hover)
    (:resize-grip-active :accent)
    (:input-text-cursor :accent)
    (:tab-hovered :control-hover) (:tab :title) (:tab-selected :panel)
    (:tab-selected-overline :accent) (:tab-dimmed :title) (:tab-dimmed-selected :panel)
    (:tab-dimmed-selected-overline :border)
    (:docking-preview (:accent 0.4)) (:docking-empty-bg :background)
    (:plot-lines :text-dim) (:plot-lines-hovered :accent)
    (:plot-histogram :text-dim) (:plot-histogram-hovered :accent)
    (:table-header-bg :title) (:table-border-strong :border) (:table-border-light :border)
    (:table-row-bg :none) (:table-row-bg-alt (:text 0.04))
    (:text-link :accent) (:text-selected-bg (:accent 0.35)) (:tree-lines :border)
    (:drag-drop-target :accent) (:drag-drop-target-bg (:accent 0.2))
    (:unsaved-marker :text)
    (:nav-cursor :accent) (:nav-windowing-highlight (:accent 0.7))
    (:nav-windowing-dim-bg (:background 0.35)) (:modal-window-dim-bg (:background 0.6)))
  "Each ImGui colour (COL keyword) and its palette source.")

(defparameter *implot-color-map*
  '((:frame-bg :panel) (:plot-bg :frame) (:plot-border :border)
    (:legend-bg :panel) (:legend-border :border) (:legend-text :text)
    (:title-text :text) (:inlay-text :text) (:axis-text :text)
    (:axis-grid :border) (:axis-tick :border)
    (:axis-bg :none) (:axis-bg-hovered :frame-hover) (:axis-bg-active :accent)
    (:selection :accent) (:crosshairs :accent))
  "Each ImPlot colour (%implot COL keyword) and its palette source.")

(defun %source-color (palette source)
  (cond ((eq source :none) (list 0.0 0.0 0.0 0.0))
        ((consp source) (destructuring-bind (role alpha) source
                          (destructuring-bind (r g b a) (getf palette role)
                            (list r g b (* a (float alpha 1.0))))))
        (t (getf palette source))))

(defun theme-imgui-colors (theme)
  "Alist of ImGui colour index to (r g b a): the palette mapping, then :colors."
  (let ((palette (theme-palette theme)))
    (append (loop for (key source) in *imgui-color-map*
                  collect (cons (enum-value "COL" key) (%source-color palette source)))
            (loop for (key c) on (theme-colors theme) by #'cddr
                  collect (cons (%color-index key) c)))))

(defun theme-implot-colors (theme)
  (let ((palette (theme-palette theme)))
    (loop for (key source) in *implot-color-map*
          collect (cons (enum-value "COL" key '#:%implot) (%source-color palette source)))))

;;; Applying

(defun %set-vec4 (pointer color)
  (loop for slot in '(%imgui::x %imgui::y %imgui::z %imgui::w)
        for v in color
        do (setf (cffi:foreign-slot-value pointer '(:struct %imgui::im-vec4) slot) v)))

(defun %write-colors (colors-pointer alist)
  "Later entries win, so :colors overrides follow the mapping."
  (loop for (index . color) in alist
        do (%set-vec4 (cffi:mem-aptr colors-pointer '(:struct %imgui::im-vec4) index) color)))

(defun apply-theme (&optional (name *theme*))
  "Write theme NAME's colours and sizes into ImGui's and ImPlot's styles and
set the background.  Rem sizes use ImGui's current base font size.  GUI
thread, between frames."
  (let* ((theme (find-theme name))
         (type '(:struct %imgui::im-gui-style))
         (style (%imgui:get-style))
         (base (let ((b (cffi:foreign-slot-value style type '%imgui::font-size-base)))
                 (if (plusp b) b (float *font-size* 1.0)))))
    (loop for (key size) on (theme-style theme) by #'cddr
          for slot = (%style-slot key)
          do (if (eq (first size) :pair)
                 (let ((p (cffi:foreign-slot-pointer style type slot)))
                   (setf (cffi:foreign-slot-value p '(:struct %imgui::im-vec2) '%imgui::x)
                         (%pixels (second size) base)
                         (cffi:foreign-slot-value p '(:struct %imgui::im-vec2) '%imgui::y)
                         (%pixels (third size) base)))
                 (setf (cffi:foreign-slot-value style type slot) (%pixels size base))))
    (%write-colors (cffi:foreign-slot-pointer style type '%imgui::colors)
                   (theme-imgui-colors theme))
    (%write-colors (cffi:foreign-slot-pointer (%implot:get-style) '(:struct %implot::im-plot-style)
                                              '%implot::colors)
                   (theme-implot-colors theme))
    (destructuring-bind (r g b a) (getf (theme-palette theme) :background)
      (declare (ignore a))
      (%shim:set-clear-color r g b))
    name))

(pushnew 'apply-theme gui.runtime:*after-window-created-hook*)

;;; The shipped themes (Ableton Live-inspired, not copies).

(defparameter *shipped-style*
  '(:frame-padding (0.38 0.15) :item-spacing (0.46 0.63)
    :item-inner-spacing (0.31 0.23) :window-padding (0.46 0.38)
    :cell-padding (0.31 0.08) :indent-spacing 0.92
    :scrollbar-size 0.62 :grab-min-size 0.62
    :window-rounding (:px 2) :child-rounding (:px 2) :frame-rounding (:px 2)
    :popup-rounding (:px 2) :grab-rounding (:px 2) :tab-rounding (:px 2)
    :scrollbar-rounding (:px 2)
    :window-border-size (:px 1) :frame-border-size (:px 0)))

(define-theme :mid-light
  :palette '(:background "#9e9e9e" :panel "#c4c4c4" :title "#b0b0b0" :frame "#a9a9a9"
             :frame-hover "#b5b5b5" :control "#d6d6d6" :control-hover "#e0e0e0"
             :border "#8a8a8a" :text "#141414" :text-dim "#4a4a4a" :accent "#ff9a2e"
             :accent-text "#141414" :series ("#1c5f7a" "#b8450f" "#3f7d20" "#6b3fa0"))
  :style *shipped-style*)

(define-theme :dark
  :palette '(:background "#1e1e1e" :panel "#2f2f2f" :title "#3d3d3d" :frame "#1d1d1d"
             :frame-hover "#262626" :control "#3d3d3d" :control-hover "#484848"
             :border "#191919" :text "#d4d4d4" :text-dim "#8a8a8a" :accent "#e8a23a"
             :accent-text "#1a1a1a" :series ("#5cc0e0" "#e8a23a" "#8fd16a" "#c58af0"))
  :style *shipped-style*)
