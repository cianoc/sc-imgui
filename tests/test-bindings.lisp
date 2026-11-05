(in-package #:sc-imgui.tests)
(in-suite bindings)

(test library-loads
  (is (cffi:foreign-library-loaded-p 'sc-imgui.bindings::shim)))

(test missing-library-lists-paths
  (let ((sc-imgui.bindings:*library-search-paths* (list #p"/nonexistent/")))
    (signals sc-imgui.bindings:shim-library-not-found
      (sc-imgui.bindings:load-shim-library))
    (handler-case (sc-imgui.bindings:load-shim-library)
      (error (e) (is (search "/nonexistent/" (princ-to-string e)))))))

(test headless-frame-runs
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))

(test assert-does-not-abort
  (with-headless-imgui ()
    (with-test-frame () (%imgui:end))   ; End without Begin
    (is (>= (%shim:assert-count) 1))
    (%shim:clear-asserts)))

(test io-struct-is-not-opaque
  (with-headless-imgui (:width 800)
    (let ((size (cffi:foreign-slot-pointer (%imgui:get-io-nil) '(:struct %imgui::im-gui-io)
                                           '%imgui::display-size)))
      (is (= 800.0 (cffi:foreign-slot-value size '(:struct %imgui::im-vec2) '%imgui::x))))))

(test frame-ends-when-body-errors
  (with-headless-imgui ()
    (signals error (with-test-frame () (error "boom")))
    ;; The frame was closed, so a fresh one can start.
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:end))))

(test vec2-struct-return-by-value
  (with-headless-imgui ()
    (let (size)
      (with-test-frame ()
        (%imgui:set-next-window-pos (vec2 10 20) 0 (vec2 0 0))
        (%imgui:begin "t" (cffi:null-pointer) 0)
        (%imgui:button "B" (vec2 50 30))
        (setf size (multiple-value-list (last-item-center)))
        (%imgui:end))
      (is (every #'realp size)))))

(test frames-with-click-clicks-a-button
  (with-headless-imgui ()
    (let (cx cy)
      (flet ((draw ()
               (%imgui:set-next-window-pos (vec2 10 20) 0 (vec2 0 0))
               (%imgui:begin "t" (cffi:null-pointer) 0)
               (prog1 (%imgui:button "B" (vec2 80 40))
                 (multiple-value-setq (cx cy) (last-item-center))
                 (%imgui:end))))
        (with-test-frame () (draw))
        (with-test-frame () (draw))
        (is (equal '(nil nil t nil) (frames-with-click cx cy #'draw)))
        (is (= 0 (%shim:assert-count)))))))

(test mouse-over-nothing-does-not-click
  (with-headless-imgui ()
    (flet ((draw ()
             (%imgui:set-next-window-pos (vec2 10 20) 0 (vec2 0 0))
             (%imgui:begin "t" (cffi:null-pointer) 0)
             (prog1 (%imgui:button "B" (vec2 80 40))
               (%imgui:end))))
      (is (equal '(nil nil nil nil) (frames-with-click 700 500 #'draw :warmup 2))))))

(test window-visible-without-a-window
  ;; -1 when there is no window.
  (is (= -1 (%shim:window-visible))))

(test test-request-close-without-a-window
  ;; The close-button hook has nothing to close in a test run.
  (is (= -1 (%shim:test-request-close))))

(test wake-and-wait-without-a-window-are-harmless
  ;; Neither touches GLFW (or reports an error) before a window exists.
  (%shim:wake)
  (is (= -1 (%shim:wait-events 0.01d0)))
  (is (string= "" (%shim:last-error))))

;;; `const char*` arguments accept NIL (passed as NULL) as well as strings.

(test nil-string-argument
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:text-unformatted "hi" nil)
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))

(test string-arguments-with-struct-by-value
  ;; Calls that take an ImVec2 by value go through cffi-libffi; the string
  ;; argument type must translate there too, for NIL and for strings.
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:progress-bar 0.5 (vec2 100 10) nil)
      (%imgui:progress-bar 0.5 (vec2 100 10) "half")
      ;; The string reached C intact: the button's ID hashes "abc".
      (%imgui:invisible-button "abc" (vec2 20 20) 0)
      (is (= (%imgui:get-id-str "abc") (%imgui:get-item-id)))
      (is (/= (%imgui:get-id-str "abc") (%imgui:get-id-str "abd")))
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))

(test shim-accepts-nil-ini-path
  ;; With a headless context open the shim refuses a window; reaching that
  ;; refusal shows the NIL ini-path was passed (as NULL) without error.
  (with-headless-imgui ()
    (is (/= 0 (%shim:open-window 10 10 "x" nil)))
    (is (search "already open" (%shim:last-error)))))

;;; C `bool` arguments work on both call paths, including the cffi-libffi one
;;; used by calls with by-value structs.

(test bool-arguments-with-struct-by-value
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:selectable-bool "a" t 0 (vec2 0 0))
      (%imgui:selectable-bool "b" nil 0 (vec2 0 0))
      ;; The bool reaches C: hide_text_after_double_hash drops "##cd".
      (let ((hidden (%imgui:calc-text-size "ab##cd" nil t -1.0))
            (shown (%imgui:calc-text-size "ab##cd" nil nil -1.0))
            (ab (%imgui:calc-text-size "ab" nil nil -1.0)))
        (is (= (getf ab '%imgui::x) (getf hidden '%imgui::x)))
        (is (< (getf hidden '%imgui::x) (getf shown '%imgui::x))))
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))

(test bool-argument-plain-call
  ;; No by-value struct: the plain CFFI path.
  (with-headless-imgui ()
    (with-test-frame ()
      (%imgui:begin "t" (cffi:null-pointer) 0)
      (%imgui:set-next-item-open t 0)
      (is (%imgui:tree-node-str "open"))
      (%imgui:tree-pop)
      (%imgui:set-next-item-open nil 0)
      (is (not (%imgui:tree-node-str "closed")))
      (%imgui:end))
    (is (= 0 (%shim:assert-count)))))
