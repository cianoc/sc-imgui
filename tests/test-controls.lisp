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

;;; Typed entry (Ctrl/Cmd-click)

(defun ctrl-click (draw)
  "Ctrl/Cmd-click DRAW's item, then run one frame that consumes the Ctrl
key-up.  (A key pressed in the same frame as the modifier's release is not
seen by the text field: Escape there would be lost.)"
  (with-keys-held (:ctrl) (click-item draw))
  (with-test-frame () (funcall draw)))

(defun assert-field-open ()
  "Check that exactly one control has its text field open."
  (let ((states (alexandria:hash-table-values gui::*control-states*)))
    (is (= 1 (length states)))
    (is (and states (gui::control-state-edit-text (first states))))))

(test typed-entry-commits
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :scale :log :unit :hz)))))
      (ctrl-click draw)
      (type-text "2k" draw)                 ; replaces the auto-selected text
      (press-key %imgui:+key-enter+ draw)
      (is (= 2000.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test typed-entry-clamps-and-snaps
  (with-controls-env ()
    (let* ((v 3)
           (draw (lambda () (in-window (gui:number-box "n" v :min 0 :max 10)))))
      (ctrl-click draw)
      (type-text "99" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (eql 10 v))
      (ctrl-click draw)
      (type-text "6.4" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (eql 6 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test bad-entry-stays-open-then-corrects
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (type-text "abc" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (= 440.0 v))
      (let ((state (first (alexandria:hash-table-values gui::*control-states*))))
        (is (gui::control-state-edit-error state))
        (is (string= "abc" (gui::control-state-edit-text state)))
        (press-key %imgui:+key-backspace+ draw)
        (is (string= "ab" (gui::control-state-edit-text state)))
        (is (not (gui::control-state-edit-error state))))
      (dotimes (i 2) (press-key %imgui:+key-backspace+ draw))
      (type-text "500" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (= 500.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test escape-cancels
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (type-text "900" draw)
      (assert-field-open)
      (press-key %imgui:+key-escape+ draw)
      (is (= 440.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test escape-keeps-code-change                        ; Review Focus 4
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (assert-field-open)
      (setf v 880.0)                         ; a pattern changes the value meanwhile
      (press-key %imgui:+key-escape+ draw)
      (is (= 880.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test enter-on-unedited-text-keeps-code-change       ; Review Focus 4, R10
  (with-controls-env ()
    (let* ((v 440.0)
           (draw (lambda () (in-window (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))))
      (ctrl-click draw)
      (assert-field-open)
      (setf v 880.0)                         ; code changes the value meanwhile
      (press-key %imgui:+key-enter+ draw)    ; Enter on the opening text "440 Hz"
      (is (= 880.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test clicking-elsewhere-cancels
  (with-controls-env ()
    (let* ((v 440.0) (w 0.5)
           (draw-v (lambda () (gui:number-box "f" v :min 20 :max 20000 :unit :hz)))
           (draw (lambda () (in-window (funcall draw-v)))))
      (ctrl-click draw)
      (type-text "900" draw)
      (assert-field-open)
      ;; Click a second control drawn below the first.
      (click-item (lambda () (in-window (funcall draw-v) (gui:number-box "other" w))))
      (is (= 440.0 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test ctrl-double-click-does-not-reset-in-core
  ;; Through CONTROL-BEHAVIOR with no value-rect, so no text field opens and
  ;; takes the mouse: the second click lands on the control's own item,
  ;; where ImGui reports the double-click.  Only the Ctrl guard stops a reset.
  (with-controls-env ()
    (let* ((spec (gui::parse-control-spec "n" 0.7 :default 0.25))
           (changed 0)
           (draw (lambda ()
                   (in-window
                     (let ((frame (gui::control-behavior "n" spec 0.7 :width 60 :height 20)))
                       (when (gui::control-frame-changed-p frame) (incf changed)))))))
      (with-keys-held (:ctrl)
        (click-item draw :clicker #'frames-with-double-click))
      (is (= 0 changed))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert)))
  ;; Without Ctrl the same double-click does reset, so the check above can
  ;; see one.  (A fresh context: more clicks in quick succession would count
  ;; as a triple-click.)
  (with-controls-env ()
    (let* ((spec (gui::parse-control-spec "n" 0.7 :default 0.25))
           (changed 0))
      (click-item (lambda ()
                    (in-window
                      (when (gui::control-frame-changed-p
                             (gui::control-behavior "n" spec 0.7 :width 60 :height 20))
                        (incf changed))))
                  :clicker #'frames-with-double-click)
      (is (plusp changed)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test ctrl-double-click-does-not-reset
  (with-controls-env ()
    (let* ((v 0.7)
           (draw (lambda () (in-window (gui:number-box "n" v :default 0.25)))))
      ;; Double-click the label, outside the value-rect: the field opened by
      ;; the first click covers only the box, so the second click reaches
      ;; the control's own item and ImGui reports a double-click on it.
      (with-keys-held (:ctrl)
        (click-item draw :x-fn (lambda (r) (- (third r) 2))
                         :clicker #'frames-with-double-click))
      (is (= 0.7 v))
      (let ((state (first (alexandria:hash-table-values gui::*control-states*))))
        (is (and state (gui::control-state-edit-text state)))
        (is (and state (null (gui::control-state-position state)))))
      (press-key %imgui:+key-escape+ draw)
      (is (= 0.7 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
