(in-package #:sc-imgui.tests)
(in-suite controls)

;;; Control core interaction, exercised through gui:number-box.

(defmacro with-controls-env (() &body body)
  "A headless context with the :mid-light theme and a base font size of 15,
set before the theme is applied so GUI::REM-PX agrees before and during
frames (a fresh context has base 0 until its first NewFrame)."
  `(with-headless-imgui ()
     (let ((gui:*theme* :mid-light))
       (set-base-font-size 15)
       (gui::apply-theme)
       ,@body)))

(test drag-up-increases
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:number-box "n" v))))
      (is (< (abs (- v 0.5)) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test shift-drag-is-ten-times-finer
  (with-controls-env ()
    (let ((v 0.0))
      (with-keys-held (:shift)
        (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:number-box "n" v)))))
      (is (< (abs (- v 0.05)) 0.005)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test overshoot-then-reverse                          ; Review Focus 2
  (with-controls-env ()
    (let ((v 0.9))
      ;; drag far past max, then back down 1 rem without releasing: value drops at once
      (drag-path (list 0 (- (gui::rem-px 30)) (+ (gui::rem-px 1)))
                 (lambda () (in-window (gui:number-box "n" v))))
      (is (< (abs (- v 0.9)) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test double-click-resets
  (with-controls-env ()
    (let ((v 0.7))
      (click-item (lambda () (in-window (gui:number-box "n" v :default 0.25)))
                  :clicker #'frames-with-double-click)
      (is (= 0.25 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test wheel-nudges
  (with-controls-env ()
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:number-box "n" v)))
                  :clicker (lambda (x y f) (frames-with-wheel x y 2 f)))
      (is (< (abs (- v 0.52)) 1e-4)))
    (let ((v 3))
      (click-item (lambda () (in-window (gui:number-box "n" v :min 0 :max 10)))
                  :clicker (lambda (x y f) (frames-with-wheel x y -1 f)))
      (is (eql 2 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test trackpad-wheel-fractions-step-stepped-controls
  ;; Four 0.3-notch events, one per frame (queued together, ImGui would sum
  ;; them into one frame): no single event reaches a step, the sum does.
  (with-controls-env ()
    (let ((v 3))
      (click-item (lambda () (in-window (gui:number-box "n" v :min 0 :max 10)))
                  :clicker (lambda (x y f) (frames-with-wheel x y '(0.3 0.3 0.3 0.3) f)))
      (is (eql 4 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test drawing-never-writes
  (with-controls-env ()
    (let ((v 7.5) (writes 0))
      (dotimes (i 3)
        (with-test-frame ()
          (in-window (when (nth-value 1 (gui:number-box-value "n" v :min 0 :max 1)) (incf writes)))))
      (is (= 0 writes)) (is (= 7.5 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test choices-non-integer-place                       ; Review Focus 3
  (with-controls-env ()
    (let ((v 1.5))
      (signals gui:widget-value-error
        (with-test-frame () (in-window (gui:number-box "n" v :choices '("a" "b"))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test disabled-ignores-input
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 -50 (lambda () (in-window (gui:with-disabled () (gui:number-box "n" v)))))
      (is (= 0.0 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test font-size-change-mid-drag                       ; Review Focus 5
  ;; drag-path frames: move, press, step 0 (dy 0), step 1 (20 px up, 30 px
  ;; past ImGui's 6 px threshold so all 20 count), step 2 (20 px up), release.
  ;; The base font size changes from 15 to 20 just before step 2, so step 1
  ;; travels 20 px of a 10 rem = 150 px range and step 2 20 px of 200 px:
  ;; v = 20/150 + 20/200.  Recomputing from the total travel at the new size
  ;; would give 40/200 = 0.2 instead (a jump), which this detects.
  (with-controls-env ()
    (let ((v 0.0))
      (drag-path (list 0 -20 -20)
                 (lambda () (in-window (gui:number-box "n" v)))
                 :between (lambda (i) (when (= i 2) (set-base-font-size 20.0))))
      (is (< (abs (- v (+ (/ 20 150) (/ 20 200)))) 0.01) "v = ~A" v))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test state-removed-after-release
  (with-controls-env ()
    (let ((v 0.0))
      (prime-and-drag 0 -20 (lambda () (in-window (gui:number-box "n" v))))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test state-removed-when-control-vanishes-mid-drag
  (with-controls-env ()
    (let ((v 0.0) (w 0.0) (shown t))
      (drag-path (list 0 -20 -20)
                 (lambda () (in-window (when shown (gui:number-box "n" v))))
                 :between (lambda (i) (when (= i 1) (setf shown nil))))
      ;; Stale entries are swept by the first control drawn in a frame with
      ;; the mouse up.  With no control drawn at all no gui code runs, so draw
      ;; one more frame containing a different control before checking.
      (with-test-frame () (in-window (gui:number-box "other" w)))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test signalling-format-function-propagates
  (with-controls-env ()
    (let ((v 0.5))
      (signals error
        (with-test-frame ()
          (in-window (gui:number-box "n" v :format (lambda (x) (declare (ignore x)) (error "boom")))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test wrong-value-types-signal-before-drawing
  (with-controls-env ()
    (let ((v nil))
      (signals gui:widget-value-error
        (with-test-frame () (in-window (gui:number-box "n" v)))))
    (let ((v "0.5"))
      (signals gui:widget-value-error
        (with-test-frame () (in-window (gui:number-box "n" v)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test types-preserved-through-drag
  (with-controls-env ()
    (let ((v 0d0) (i 0))
      (prime-and-drag 0 (- (gui::rem-px 5)) (lambda () (in-window (gui:number-box "d" v))))
      (is (typep v 'double-float))
      (prime-and-drag 0 (- (gui::rem-px 5))
                      (lambda () (in-window (gui:number-box "i" i :min 0 :max 10))))
      (is (eql 5 i)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
