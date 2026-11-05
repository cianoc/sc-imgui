(in-package #:sc-imgui.tests)
(in-suite draw)

(test color-matches-imgui
  (is (= (%imgui:color-convert-float4-to-u32 (vec4 1 0.5 0 1)) (gui:color 1 0.5 0 1)))
  (is (= (%imgui:color-convert-float4-to-u32 (vec4 0.2 0.7 1.4 -1)) (gui:color 0.2 0.7 1.4 -1))))

(test primitives-add-vertices
  (with-headless-imgui ()
    (%shim:clear-asserts)
    ;; A new window is hidden for its first frame and clips text; warm it up.
    (with-test-frame () (in-window))
    (with-test-frame ()
      (in-window
        (let ((c (gui:color 1 1 1)))
          (dolist (f (list (lambda () (gui:draw-line 10 10 50 50 c))
                           (lambda () (gui:draw-rect 10 10 50 50 c :filled t))
                           (lambda () (gui:draw-circle 30 30 10 c))
                           (lambda () (gui:draw-arc 30 30 10 0 pi c))
                           (lambda () (gui:draw-polyline '(0 0 10 10 20 0) c))
                           (lambda () (multiple-value-bind (x y) (gui:cursor-screen-pos)
                                       (gui:draw-text x y c "hi")))))
            (let ((before (vtx-count (gui:window-draw-list))))
              (funcall f)
              (is (> (vtx-count (gui:window-draw-list)) before)))))))
    (is (= 0 (%shim:assert-count)))))

(test polyline-edge-cases
  (with-headless-imgui ()
    (with-test-frame ()
      (in-window
        (let ((before (vtx-count (gui:window-draw-list))))
          (gui:draw-polyline '(5 5) (gui:color 1 1 1))
          (is (= before (vtx-count (gui:window-draw-list)))))
        (signals error (gui:draw-polyline '(0 0 10) (gui:color 1 1 1)))))))

(test invisible-button-clicks
  (with-headless-imgui ()
    (is (= 1 (count t (click-item (lambda () (in-window (gui:invisible-button "k" 40 40)))))))))

(test drag-reports-delta-while-active
  (with-headless-imgui ()
    (let (seen)
      (prime-and-drag 30 0
        (lambda () (in-window (gui:invisible-button "k" 40 40)
                     (when (gui:item-active-p) (push (gui:mouse-drag-delta) seen)))))
      (is (some (lambda (dx) (>= dx 29.0)) seen)))))
