(in-package #:sc-imgui.tests)
(in-suite widgets)

(test button-reports-one-click
  (with-headless-imgui ()
    (let ((results (click-item (lambda () (in-window (gui:button "go"))))))
      (is (= 1 (count t results))))))

(test checkbox-toggles-place
  (with-headless-imgui ()
    (let ((flag nil))
      (click-item (lambda () (in-window (gui:checkbox "on" flag))))
      (is (eq t flag)))))

(test slider-float-writes-place-and-keeps-type
  (with-headless-imgui ()
    (let ((v 0.0d0))
      (click-item-at-right-edge (lambda () (in-window (gui:slider "v" v :min 0 :max 1))))
      (is (typep v 'double-float)) (is (> v 0.9d0)))))

(test slider-int-writes-integer
  (with-headless-imgui ()
    (let ((v 0))
      (click-item-at-right-edge (lambda () (in-window (gui:slider "n" v :min 0 :max 10))))
      (is (integerp v)) (is (>= v 9)))))

(test slider-log-scale-draws-cleanly
  (with-headless-imgui ()
    (let ((v 440.0))
      (%shim:clear-asserts)
      (with-test-frame () (in-window (gui:slider "f" v :min 20 :max 20000 :scale :log)))
      (is (= 440.0 v)) (is (= 0 (%shim:assert-count))))))

(test value-variants-return-unchanged-without-input
  (with-headless-imgui ()
    (with-test-frame ()
      (in-window
        (is (equal '(0.5 nil) (multiple-value-list (gui:slider-value "a" 0.5))))
        (is (equal '("hi" nil) (multiple-value-list (gui:input-text-value "b" "hi"))))
        (is (equal '(1 nil) (multiple-value-list (gui:combo-value "c" 1 '("x" "y")))))
        (is (equal '(t nil) (multiple-value-list (gui:checkbox-value "d" t))))
        (is (equal '(3 nil) (multiple-value-list (gui:drag-value "e" 3))))))))

(test input-text-writes-typed-text
  (with-headless-imgui ()
    (let ((s ""))
      (click-item (lambda () (in-window (gui:input-text "name" s))))
      (type-text "hi" (lambda () (in-window (gui:input-text "name" s))))
      (is (string= "hi" s)))))

(test input-text-truncates-at-character-boundary
  (with-headless-imgui ()
    ;; Three 2-byte characters into a 5-byte limit: two fit.
    (is (equalp #(#xC3 #xA9 #xC3 #xA9)
                (gui::%utf8-truncated (coerce '(#\LATIN_SMALL_LETTER_E_WITH_ACUTE
                                                #\LATIN_SMALL_LETTER_E_WITH_ACUTE
                                                #\LATIN_SMALL_LETTER_E_WITH_ACUTE) 'string)
                                      5)))
    (is (= 2 (length (gui::%utf8-truncated "abcdef" 2))))))

(test combo-selects-item-and-previews-empty-when-out-of-range
  (with-headless-imgui ()
    (let ((i 5) (items '("x" "y" "x")))
      (%shim:clear-asserts)
      (with-test-frame () (in-window (gui:combo "c" i items)))
      (is (= 5 i))
      (click-item (lambda () (in-window (gui:combo "c" i items))))
      (is (= 0 (%shim:assert-count))))))

(test place-subforms-evaluated-once
  (with-headless-imgui ()
    (let ((n 0) (vec (vector nil)))
      (click-item (lambda () (in-window (gui:checkbox "on" (aref vec (progn (incf n) 0))))))
      (is (= 6 n))
      (is (eq t (aref vec 0))))))

(test text-uses-format-only-with-args
  (with-headless-imgui ()
    (%shim:clear-asserts)
    (with-test-frame ()
      (in-window (gui:text "100~% plain ~a") (gui:text "n=~D" 3)))
    (is (= 0 (%shim:assert-count)))))

(test slider-nil-place-signals-type-error
  (with-headless-imgui ()
    (let ((v nil))
      (%shim:clear-asserts)
      (handler-case (with-test-frame () (in-window (gui:slider "Cutoff" v)))
        (gui:widget-value-error (e) (is (search "Cutoff" (princ-to-string e))))
        (:no-error (&rest r) (declare (ignore r)) (fail "no error signalled")))
      (is (typep (make-condition 'gui:widget-value-error :label "x" :datum 1 :expected-type 'string)
                 'type-error))
      (is (= 0 (%shim:assert-count))))))

(test selectable-toggles-place
  (with-headless-imgui ()
    (let ((on nil))
      (let ((results (click-item (lambda () (in-window (gui:selectable "row" on))))))
        (is (= 1 (count t results))))
      (is (eq t on))
      (click-item (lambda () (in-window (gui:selectable "row" on))))
      (is (eq nil on)))))

(test list-box-selects-clicked-item
  (with-headless-imgui ()
    ;; The default list box is about 7.25 lines tall, so its centre is item 3.
    (let ((i nil) (items '("a" "b" "c" "d" "e" "f" "g")))
      (%shim:clear-asserts)
      (click-item (lambda () (in-window (gui:list-box "l" i items))))
      (is (eql 3 i))
      (is (= 0 (%shim:assert-count))))))

(test list-box-tolerates-no-selection-and-duplicates
  (with-headless-imgui ()
    (%shim:clear-asserts)
    (with-test-frame ()
      (in-window
        (is (equal '(nil nil) (multiple-value-list (gui:list-box-value "l" nil '("x" "x")))))
        (is (equal '(9 nil) (multiple-value-list (gui:list-box-value "m" 9 '("x" "y")))))
        (is (equal '(t nil) (multiple-value-list (gui:selectable-value "s" t))))))
    (is (= 0 (%shim:assert-count)))))
