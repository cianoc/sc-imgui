(in-package #:sc-imgui.tests)
(in-suite scopes)

(defun item-min-x () (getf (%imgui:get-item-rect-min) '%imgui::x))
(defun item-min-y () (getf (%imgui:get-item-rect-min) '%imgui::y))

(test window-body-runs
  (with-headless-imgui ()
    (let (ran) (with-test-frame () (gui:with-window ("w") (setf ran t))) (is-true ran))))

(test errors-keep-scopes-balanced
  (with-headless-imgui ()
    (dolist (f (list (lambda () (gui:with-window ("w") (error "x")))
                     (lambda () (gui:with-window ("w") (gui:with-group () (error "x"))))
                     (lambda () (gui:with-window ("w") (gui:with-child ("c") (error "x"))))
                     (lambda () (gui:with-window ("w") (gui:with-id (42) (error "x"))))
                     (lambda () (gui:with-window ("w") (gui:with-disabled () (error "x"))))
                     (lambda () (gui:with-window ("w")
                                  (gui:with-style ((:color :button 1 0 0) (:var :frame-rounding 4.0))
                                    (error "x"))))
                     (lambda () (gui:with-window ("w") (gui:with-grid (:columns 2) (error "x"))))))
      (%shim:clear-asserts)
      (with-test-frame () (handler-case (funcall f) (error () nil)))
      (is (= 0 (%shim:assert-count))))))

(test with-row-places-items-on-one-line
  (with-headless-imgui ()
    (let (ys xs)
      (with-test-frame ()
        (gui:with-window ("w")
          (gui:with-row ()
            (progn (%imgui:button "a" (vec2 0 0)) (push (item-min-y) ys) (push (item-min-x) xs))
            (progn (%imgui:button "b" (vec2 0 0)) (push (item-min-y) ys) (push (item-min-x) xs)))))
      (is (= (first ys) (second ys)))
      (is (> (first xs) (second xs))))))

(test with-grid-fills-columns-in-order
  (with-headless-imgui ()
    (let (ys)
      (with-test-frame ()
        (gui:with-window ("w")
          (gui:with-grid (:columns 2)
            (progn (%imgui:button "a" (vec2 0 0)) (push (item-min-y) ys))
            (progn (%imgui:button "b" (vec2 0 0)) (push (item-min-y) ys))
            (progn (%imgui:button "c" (vec2 0 0)) (push (item-min-y) ys)))))
      (destructuring-bind (c b a) ys
        (is (= a b)) (is (> c a))))))

(test with-id-stable-across-gc
  (with-headless-imgui ()
    (let ((obj (list 1 2)) id1 id2 id3)
      (with-test-frame () (gui:with-id (obj) (setf id1 (%imgui:get-id-str "k"))))
      (sb-ext:gc :full t)
      (with-test-frame () (gui:with-id (obj) (setf id2 (%imgui:get-id-str "k")))
                          (gui:with-id ((list 1 2)) (setf id3 (%imgui:get-id-str "k"))))
      (is (= id1 id2))
      (is (/= id1 id3)))))

(test enum-flags-resolves-keywords
  (is (= (logior %imgui:+window-flags-no-title-bar+ %imgui:+window-flags-no-resize+)
         (gui:enum-flags "WINDOW-FLAGS" '(:no-title-bar :no-resize))))
  (signals error (gui:enum-flags "WINDOW-FLAGS" :no-such-flag)))

(test scope-macros-do-not-capture-open
  (with-headless-imgui ()
    (let ((open :users) seen)
      (with-test-frame ()
        (gui:with-window ("w")
          (push open seen)
          (gui:with-child ("c") (push open seen))))
      (is (equal '(:users :users) seen)))))

(defun default-grid-id (body)
  (let ((form (macroexpand-1 `(gui:with-grid () ,@body))))
    (second (second form))))

(test with-grid-default-id-distinguishes-deep-bodies
  (let ((a '((text "A") (text "B") (text "C") (text "D")))
        (z '((text "A") (text "B") (text "C") (text "Z"))))
    (is (stringp (default-grid-id a)))
    (is (string/= (default-grid-id a) (default-grid-id z)))
    (is (string= (default-grid-id a) (default-grid-id (copy-tree a))))))
