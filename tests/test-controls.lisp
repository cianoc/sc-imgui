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

(test shift-wheel-is-ten-times-finer
  (with-controls-env ()
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:number-box "n" v)))
                  :clicker (lambda (x y f) (frames-with-wheel x y 2 f :shift t)))
      (is (< (abs (- v 0.502)) 1e-5) "v = ~A" v))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test shift-horizontal-wheel-fallback
  ;; macOS turns Shift+wheel into a horizontal wheel: with Shift held and only
  ;; io.MouseWheelH moving, the control still takes 0.1% per notch.  Without
  ;; Shift the horizontal wheel is ignored.
  (with-controls-env ()
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:number-box "n" v)))
                  :clicker (lambda (x y f) (frames-with-wheel x y 2 f :shift t :horizontal t)))
      (is (< (abs (- v 0.502)) 1e-5) "v = ~A" v))
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:number-box "n" v)))
                  :clicker (lambda (x y f) (frames-with-wheel x y 2 f :horizontal t)))
      (is (= 0.5 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test number-box-default-width-fits-interior-values
  ;; The ends of -70..6 dB format as "-inf dB" and "6.0 dB", narrower than
  ;; interior values like "-12.5 dB"; 10..1000 ms ends as "10 ms" and
  ;; "1.00 s", narrower than "999 ms".  The label is hidden, so the item is
  ;; the box.
  (with-controls-env ()
    (let ((db -12.5) (ms 999.0) pad db-text ms-text db-rect)
      (with-test-frame ()
        (in-window (setf pad (* 2 (gui::%style-x %imgui::frame-padding))
                         db-text (gui::text-width "-12.5 dB")
                         ms-text (gui::text-width "999 ms"))
                   (gui:number-box "##db" db :min -70 :max 6 :unit :db)
                   (setf db-rect (last-item-rect))
                   (gui:number-box "##ms" ms :min 10 :max 1000 :unit :ms)))
      (is (>= (- (third db-rect) (first db-rect)) (+ pad db-text)) "~S" db-rect)
      (is (>= (- (third *item-rect*) (first *item-rect*)) (+ pad ms-text)) "~S" *item-rect*))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test number-box-frame-stays-hovered-while-dragging
  ;; drag-path frames: move, press, step 0 (dy 0), step 1 (8 rem up, off the
  ;; box: active but not hovered), release.
  (with-controls-env ()
    (let* ((v 0.0)
           (frames (drag-path (list 0 (- (gui::rem-px 8)))
                              (lambda () (in-window (control-colors (gui:number-box "##n" v))))))
           (dragging (nth 3 frames)))
      (is (member (gui::control-color :frame-hover) dragging))
      (is (not (member (gui::control-color :frame) dragging))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test control-states-cleared-by-save-hook
  ;; A saved image must not keep foreign buffers: the hook empties the table
  ;; without freeing (the pointers are stale after a restart).
  (is (member 'gui::%reset-control-states sb-ext:*save-hooks*))
  (let ((gui::*control-states* (make-hash-table :test 'equal))
        (gui::*control-states-swept* 5)
        (buffer (cffi:foreign-alloc :uint8 :count 64)))
    (unwind-protect
         (let ((state (gui::make-control-state :edit-buffer buffer :edit-text "x")))
           (setf (gethash 1 gui::*control-states*) state)
           (funcall 'gui::%reset-control-states)
           (is (= 0 (hash-table-count gui::*control-states*)))
           (is (null gui::*control-states-swept*))
           (is (eq buffer (gui::control-state-edit-buffer state))))
      (cffi:foreign-free buffer))))

(test controls-reject-unknown-keys-and-bad-sizes
  ;; Each signals CONTROL-SPEC-ERROR naming the label, not SBCL's unknown
  ;; &KEY error or a bare size error.
  (with-controls-env ()
    (dolist (call (list (lambda () (gui:knob-value "Lbl" 0.5 :length 3))
                        (lambda () (gui:knob-value "Lbl" 0.5 :thickness 3))
                        (lambda () (gui:fader-value "Lbl" 0.5 :size 3))
                        (lambda () (gui:number-box-value "Lbl" 0.5 :size 3))
                        (lambda () (gui:knob-value "Lbl" 0.5 :format "%.2f"))
                        (lambda () (gui:knob-value "Lbl" 0.5 :size 0))
                        (lambda () (gui:knob-value "Lbl" 0.5 :size "big"))
                        (lambda () (gui:fader-value "Lbl" 0.5 :length -1))
                        (lambda () (gui:fader-value "Lbl" 0.5 :thickness '(:px)))
                        (lambda () (gui:fader-value "Lbl" 0.5 :vertical t :thickness '(:px -2)))
                        (lambda () (gui:number-box-value "Lbl" 0.5 :width '(:em 3)))
                        (lambda () (gui:xy-pad-value "Lbl" 0.5 0.5 :size 0))
                        (lambda () (gui:toggle-value "Lbl" t :width -2))
                        (lambda () (gui:trigger "Lbl" :width "x"))))
      (handler-case (progn (with-test-frame () (in-window (funcall call)))
                           (fail "no control-spec-error from ~S" call))
        (gui:control-spec-error (e)
          (is (equal "Lbl" (gui::control-spec-error-label e)))
          (is (search "\"Lbl\"" (princ-to-string e))))
        (error (e) (fail "~S signalled ~A: ~A" call (type-of e) e))))
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

(test knob-drags-and-keeps-type
  (with-controls-env ()
    (let ((v 0.0d0))
      (prime-and-drag 0 (- (gui::rem-px 10)) (lambda () (in-window (gui:knob "k" v))))
      (is (typep v 'double-float)) (is (> v 0.99d0)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test knob-draws-nonpositive-log-value
  (with-controls-env ()
    (let ((v 0))
      (with-test-frame () (in-window (gui:knob "f" v :min 20 :max 20000 :scale :log :unit :hz)))
      (is (eql 0 v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test knob-row-aligns-at-two-sizes
  (with-controls-env ()
    (dolist (px '(13.0 15.0))
      (set-base-font-size px)
      (let (rects)
        (with-test-frame ()
          (in-window (gui:with-row ()
                       (progn (gui:knob-value "Cutoff frequency" 0.5) (push (last-item-rect) rects))
                       (progn (gui:knob-value "Q" 0.5) (push (last-item-rect) rects)))))
        (destructuring-bind ((ax1 ay1 ax2 ay2) (bx1 by1 bx2 by2)) (reverse rects)
          (is (= ay1 by1))
          (is (= (- ax2 ax1) (- bx2 bx1)))
          (is (< (abs (- (- ax2 ax1) (* 3.0 px))) 1.0))
          (is (= (- ay2 ay1) (- by2 by1))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test knob-bipolar-choices-draw-cleanly
  (with-controls-env ()
    (let ((pan 0.0) (wave 1))
      (with-test-frame ()
        (in-window (gui:knob "Pan" pan :min -1 :max 1 :bipolar t :unit :pan)
                   (gui:knob "Wave" wave :choices '("Sine" "Saw" "Square"))))
      (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert)))))

(test knob-wrong-type-signals
  (with-controls-env ()
    (let ((v "x"))
      (with-test-frame ()
        (signals gui:widget-value-error (in-window (gui:knob "k" v)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

;;; Fader

(defvar *fader-bar* nil "Bar rect (x y w h) of the fader last drawn by FADER-DRAWER.")

(defun fader-drawer (place-get place-set &rest args)
  "A draw function for a fader (in a fixed 600x400 window) over a place
accessed by PLACE-GET/PLACE-SET, recording its bar rect in *FADER-BAR*."
  (lambda ()
    (%imgui:set-next-window-size (gui::vec2 600 400) %imgui:+cond-always+)
    (in-window
      (multiple-value-bind (new changed) (apply #'gui:fader-value "Vol" (funcall place-get) args)
        (when changed (funcall place-set new))))
    (destructuring-bind (x y x2 y2) *item-rect*
      (declare (ignore y2))
      (let ((vertical (getf args :vertical)))
        (setf *fader-bar*
              (gui::fader-bar-rect vertical x y (- x2 x)
                                   (if vertical (gui::rem-px 8) (- x2 x))
                                   (%imgui:get-frame-height) (%imgui:get-font-size)
                                   (gui::item-spacing-y)))))))

(defun fader-point (fraction vertical)
  "Screen point at FRACTION (0 = min, 1 = max) along *FADER-BAR*'s axis."
  (destructuring-bind (x y w h) *fader-bar*
    (if vertical
        (values (+ x (/ w 2)) (+ y (* (- 1 fraction) h)))
        (values (+ x (* fraction w)) (+ y (/ h 2))))))

(defmacro with-fader ((v draw initial &rest args) &body body)
  `(let* ((,v ,initial)
          (,draw (fader-drawer (lambda () ,v) (lambda (n) (setf ,v n)) ,@args)))
     (dotimes (i 2) (with-test-frame () (funcall ,draw)))
     ,@body))

(test fader-click-jumps-to-the-point-after-the-double-click-time
  ;; Clicking a point on a fader's bar makes that point the value -- but only
  ;; once the double-click time has passed, so a double-click can still reset.
  (with-controls-env ()
    (dolist (vertical '(nil t))
      (dolist (fraction '(0.25 0.9))
        (with-fader (v draw 0.0 :vertical vertical)
          (multiple-value-bind (x y) (fader-point fraction vertical)
            (frames-with-click x y draw))
          (is (= 0.0 v) "~:[horizontal~;vertical~] click: no jump before the double-click time"
              vertical)
          (idle-frames (double-click-frames) draw)
          (is (< (abs (- v fraction)) 0.02) "~:[horizontal~;vertical~] click at ~A gives ~A"
              vertical fraction v)
          (is (= 0 (hash-table-count gui::*control-states*))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-drag-tracks-the-mouse
  ;; After the press jumps to the point, dragging keeps the fill edge under
  ;; the cursor: 1:1 with the bar's length.
  (with-controls-env ()
    (dolist (vertical '(nil t))
      (with-fader (v draw 0.0 :vertical vertical)
        (multiple-value-bind (x y) (fader-point 0.5 vertical)
          (let ((quarter (/ (if vertical (fourth *fader-bar*) (third *fader-bar*)) 4)))
            (if vertical
                (frames-with-drag x y 0 (- quarter) draw)
                (frames-with-drag x y quarter 0 draw))))
        (is (< (abs (- v 0.75)) 0.02) "~:[horizontal~;vertical~]: press at 0.5, drag a quarter: ~A"
            vertical v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-shift-press-does-not-jump
  ;; Shift keeps fine, relative movement: the press doesn't jump, and a drag
  ;; of half the bar moves a twentieth of the range.
  (with-controls-env ()
    (dolist (vertical '(nil t))
      (with-fader (v draw 0.0 :vertical vertical)
        (multiple-value-bind (x y) (fader-point 0.5 vertical)
          (let ((half (/ (if vertical (fourth *fader-bar*) (third *fader-bar*)) 2)))
            (with-keys-held (:shift)
              (if vertical
                  (frames-with-drag x y 0 (- half) draw)
                  (frames-with-drag x y half 0 draw)))))
        (is (< (abs (- v 0.05)) 0.01) "~:[horizontal~;vertical~] Shift: ~A" vertical v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-drags-only-along-its-axis
  ;; A drag across the axis moves nothing, so the press counts as a click: it
  ;; jumps to the pressed point after the double-click time, and no further.
  (with-controls-env ()
    (dolist (vertical '(nil t))
      (with-fader (v draw 0.0 :vertical vertical)
        (multiple-value-bind (x y) (fader-point 0.5 vertical)
          (if vertical
              (frames-with-drag x y 50 0 draw)
              (frames-with-drag x y 0 -50 draw)))
        (idle-frames (double-click-frames) draw)
        (is (< (abs (- v 0.5)) 0.02) "~:[horizontal~;vertical~] across-axis drag: ~A" vertical v)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-double-click-resets-instead-of-jumping
  (with-controls-env ()
    (dolist (vertical '(nil t))
      (with-fader (v draw 0.8 :vertical vertical :default 0.2)
        (multiple-value-bind (x y) (fader-point 0.6 vertical)
          (frames-with-double-click x y draw))
        (idle-frames (double-click-frames) draw)
        (is (< (abs (- v 0.2)) 1e-6) "~:[horizontal~;vertical~] double-click: ~A" vertical v)
        (is (= 0 (hash-table-count gui::*control-states*)))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-fills-width-and-bipolar-draws
  (with-controls-env ()
    (let ((v 0.0) rect avail frame-height)
      (flet ((draw ()
               (%imgui:set-next-window-size (gui::vec2 600 400) %imgui:+cond-always+)
               (gui:with-window ("w")
                 (setf avail (gui:content-region-avail)
                       frame-height (%imgui:get-frame-height))
                 (gui:fader "Pan" v :min -1 :max 1 :bipolar t :unit :pan)
                 (setf rect (last-item-rect)))))
        (dotimes (i 2) (with-test-frame () (draw))))
      (is (>= (- (third rect) (first rect)) (* 0.8 600.0)) "~S" rect)
      (is (= (- (third rect) (first rect)) avail) "~S ~S" rect avail)
      (is (= (- (fourth rect) (second rect)) frame-height) "~S" rect))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-sizes-follow-thickness-and-length
  (with-controls-env ()
    (with-test-frame ()
      (in-window (gui:fader-value "h" 0.5 :length 10 :thickness 2)))
    (destructuring-bind (x1 y1 x2 y2) *item-rect*
      (is (= (- x2 x1) (gui::rem-px 10)))
      (is (= (- y2 y1) (gui::rem-px 2))))
    (let (fh)
      (with-test-frame ()
        (in-window (setf fh (%imgui:get-frame-height))
                   (gui:fader-value "v" 0.5 :vertical t)))
      (destructuring-bind (x1 y1 x2 y2) *item-rect*
        ;; The item is 3.5 rem wide; the bar inside it is FH wide.
        (is (< (abs (- (- x2 x1) (gui::rem-px 3.5))) 0.01))
        (is (< fh (gui::rem-px 3.5)))
        (is (> (- y2 y1) (gui::rem-px 8)))))
    ;; A thickness wider than 3.5 rem widens the item to match.
    (with-test-frame ()
      (in-window (gui:fader-value "v" 0.5 :vertical t :thickness 5)))
    (destructuring-bind (x1 y1 x2 y2) *item-rect*
      (declare (ignore y1 y2))
      (is (< (abs (- (- x2 x1) (gui::rem-px 5))) 0.01)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test vertical-fader-fits-its-value
  ;; Measured in the bundled font (the default bitmap font is wider).
  (with-controls-env ()
    (with-loaded-fonts ()
      (dolist (px '(13.0 15.0 20.0))
        (set-base-font-size px)
        (let (text)
          (dotimes (i 2)
            (with-test-frame ()
              (in-window (setf text (gui::text-width "-12.0 dB"))
                         (gui:fader-value "Vol" -12.0 :vertical t :min -70 :max 6 :unit :db))))
          (is (>= (- (third *item-rect*) (first *item-rect*)) text)
              "~S: ~S ~S" px *item-rect* text))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-bar-rect-geometry
  ;; (fader-bar-rect vertical x y item-width len thickness line spacing)
  ;; Horizontal: the bar is the item.
  (is (equal '(10 20 200 18) (gui::fader-bar-rect nil 10 20 200 200 18 15 4)))
  ;; Vertical: the bar is THICKNESS wide, centred in the item, below the
  ;; label line and its spacing.
  (is (equal '(26 39 20 120) (gui::fader-bar-rect t 10 20 52 120 20 15 4))))

(test fader-value-text-dims-when-inactive
  ;; Hidden labels, so the only text drawn is the value.
  (with-controls-env ()
    (let (h vt)
      ;; A new window's first frame clips all text (and sizes the window to
      ;; fit), so record the second.
      (dotimes (i 2)
        (with-test-frame ()
          (in-window (setf h (control-colors (gui:fader-value "##h" 0.5 :length 10))
                           vt (control-colors (gui:fader-value "##v" 0.5 :vertical t))))))
      (dolist (colors (list h vt))
        (is (member (gui::control-color :text-dim) colors))
        (is (not (member (gui::control-color :text) colors)))))
    ;; prime-and-drag frames: move, press, move (active), release.
    (let* ((v 0.5)
           (frames (prime-and-drag 20 0 (lambda ()
                                          (in-window (control-colors
                                                      (gui:fader "##h" v :length 10)))))))
      (is (member (gui::control-color :text) (nth 2 frames))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-wrong-type-signals
  (with-controls-env ()
    (signals gui:widget-value-error (gui:fader-value "v" nil))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test fader-fill-rect-geometry
  ;; Bar at (10, 20), 100 wide, 40 tall.
  (flet ((rect (v lo hi) (gui::fader-fill-rect v lo hi 10 20 100 40)))
    ;; Horizontal unipolar: origin 0 to 0.25.
    (is (equal '(10 20 35.0 60) (rect nil 0 0.25)))
    ;; Horizontal bipolar, value below the origin (0.5): 0.2..0.5.
    (is (equal '(30.0 20 60.0 60) (rect nil 0.2 0.5)))
    ;; Horizontal bipolar, value above the origin: 0.5..0.8.
    (is (equal '(60.0 20 90.0 60) (rect nil 0.5 0.8)))
    ;; Vertical: filled from the bottom (y 60) upward.
    (is (equal '(10 40.0 110 60) (rect t 0 0.5)))
    (is (equal '(10 36.0 110 48.0) (rect t 0.3 0.6)))))

;;; Toggle and trigger

(test toggle-flips
  (with-controls-env ()
    (let ((on nil))
      (click-item (lambda () (in-window (gui:toggle "Mute" on))))
      (is (eq t on))
      (click-item (lambda () (in-window (gui:toggle "Mute" on))))
      (is (eq nil on)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test toggle-accepts-generalized-boolean
  (with-controls-env ()
    (let ((on :yes))
      (click-item (lambda () (in-window (gui:toggle "Mute" on))))
      (is (eq nil on)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test toggle-disabled-ignores-click
  (with-controls-env ()
    (let ((on nil))
      (click-item (lambda () (in-window (gui:with-disabled () (gui:toggle "Mute" on)))))
      (is (eq nil on)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test toggle-sizes
  (with-controls-env ()
    (with-test-frame ()
      (in-window (gui:toggle-value "Mute" nil :width 6)))
    (destructuring-bind (x1 y1 x2 y2) *item-rect*
      (is (< (abs (- (- x2 x1) (gui::rem-px 6))) 0.01))
      (is (= (- y2 y1) (%imgui:get-frame-height))))
    (with-test-frame ()
      (in-window (gui:toggle-value "Mute##x" nil)))
    (is (< (abs (- (- (third *item-rect*) (first *item-rect*))
                   (+ (gui::text-width "Mute") (gui::rem-px 1))))
           0.01))
    (with-test-frame ()
      (in-window (gui:toggle-value "Mute" nil :width '(:px 50))))
    (is (< (abs (- (- (third *item-rect*) (first *item-rect*)) 50.0)) 0.01))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test trigger-reports-press-hold-release
  (with-controls-env ()
    (let ((frames (click-item (lambda () (in-window (multiple-value-list (gui:trigger "Hit")))))))
      (is (equal '((nil nil nil) (t t nil) (nil nil t) (nil nil nil)) frames)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test trigger-disabled-reports-nothing
  (with-controls-env ()
    (let ((frames (click-item
                   (lambda () (in-window (gui:with-disabled ()
                                           (multiple-value-list (gui:trigger "Hit"))))))))
      (is (every (lambda (f) (equal f '(nil nil nil))) frames)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

;;; gui:xy-pad

(test xy-click-jumps-and-shift-drags-finely
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      ;; click the pad's center: both go to 0.5
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y))))
      (is (< (abs (- x 0.5)) 0.02)) (is (< (abs (- y 0.5)) 0.02))
      ;; Idle past ImGui's 0.3 s double-click time (frames are 1/60 s), so
      ;; the next press is not a double-click (which would reset both).
      (dotimes (i 30) (with-test-frame () (in-window (gui:xy-pad "xy" x y))))
      (let ((x0 x))
        (with-keys-held (:shift)
          (prime-and-drag (gui::rem-px 4) 0 (lambda () (in-window (gui:xy-pad "xy" x y)))))
        (is (< (abs (- (- x x0) 0.05)) 0.01))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-axes-have-own-specs
  (with-controls-env ()
    (let ((f 440.0) (q 0.5))
      (with-test-frame ()
        (in-window (gui:xy-pad "Filter" f q :x '(:min 20 :max 20000 :scale :log :unit :hz)
                                            :y '(:unit :percent))))
      (is (= 440.0 f)) (is (= 0 (%shim:assert-count))))))

(test xy-double-click-resets-both
  (with-controls-env ()
    (let ((x 0.9) (y 0.9))
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y :x '(:default 0.1) :y '(:default 0.2))))
                  :clicker #'frames-with-double-click)
      (is (= 0.1 x)) (is (= 0.2 y)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-click-y-up-increases
  ;; A click a quarter of the pad above its center raises y by 0.25; x is
  ;; unchanged at the center.
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y)))
                  :clicker (lambda (cx cy f) (frames-with-click cx (- cy (gui::rem-px 2)) f)))
      (is (< (abs (- x 0.5)) 0.02)) (is (< (abs (- y 0.75)) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-absolute-drag-follows-mouse
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      ;; from the center, 2 rem right and 2 rem down: (0.75, 0.25)
      (prime-and-drag (gui::rem-px 2) (gui::rem-px 2) (lambda () (in-window (gui:xy-pad "xy" x y))))
      (is (< (abs (- x 0.75)) 0.02)) (is (< (abs (- y 0.25)) 0.02))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-shift-press-does-not-jump
  (with-controls-env ()
    (let ((x 0.2) (y 0.3) (writes 0))
      (with-keys-held (:shift)
        (click-item (lambda () (in-window (when (gui:xy-pad "xy" x y) (incf writes))))))
      (is (= 0.2 x)) (is (= 0.3 y)) (is (= 0 writes)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-keeps-types
  (with-controls-env ()
    (let ((x 0.0d0) (y 0))
      (click-item (lambda () (in-window (gui:xy-pad "xy" x y :y '(:max 10)))))
      (is (typep x 'double-float)) (is (< (abs (- x 0.5d0)) 0.02d0))
      (is (eql 5 y)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-out-of-range-not-written
  (with-controls-env ()
    ;; Drawing alone never writes or reports a change.
    (let ((x 5.0) (y -3.0) (writes 0))
      (dotimes (i 3)
        (with-test-frame ()
          (in-window (multiple-value-bind (nx ny changed) (gui:xy-pad-value "xy" x y)
                       (is (eql 5.0 nx)) (is (eql -3.0 ny))
                       (when changed (incf writes))))))
      (is (= 0 writes))
      ;; A Shift-drag straight up moves only y: x is neither clamped nor written.
      (with-keys-held (:shift)
        (prime-and-drag 0 (- (gui::rem-px 4)) (lambda () (in-window (gui:xy-pad "xy" x y)))))
      (is (eql 5.0 x)) (is (< (abs (- y 0.05)) 0.01)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-macro-evaluates-subforms-once
  (with-controls-env ()
    (let ((v (vector 0.0 0.0)) (n 0))
      (with-test-frame ()
        (in-window (gui:xy-pad "xy" (aref v (progn (incf n) 0)) (aref v (progn (incf n) 1)))))
      (is (= 2 n))
      (click-item (lambda () (in-window (gui:xy-pad "xy" (aref v (progn (incf n) 0))
                                                         (aref v (progn (incf n) 1))))))
      (is (< (abs (- (aref v 0) 0.5)) 0.02)) (is (< (abs (- (aref v 1) 0.5)) 0.02)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-disabled-ignores-input
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      (click-item (lambda () (in-window (gui:with-disabled () (gui:xy-pad "xy" x y)))))
      (prime-and-drag 20 -20 (lambda () (in-window (gui:with-disabled () (gui:xy-pad "xy" x y)))))
      (click-item (lambda () (in-window (gui:with-disabled () (gui:xy-pad "xy" x y))))
                  :clicker #'frames-with-double-click)
      (is (= 0.0 x)) (is (= 0.0 y)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-size-and-one-item
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      (with-test-frame () (in-window (gui:xy-pad "xy" x y)))
      (is (< (abs (- (- (third *item-rect*) (first *item-rect*)) (gui::rem-px 8))) 0.01))
      (with-test-frame () (in-window (gui:xy-pad "xy" x y :size '(:px 50))))
      (is (< (abs (- (- (third *item-rect*) (first *item-rect*)) 50.0)) 0.01))
      ;; label line, spacing, square, spacing, value line
      (is (< (abs (- (- (fourth *item-rect*) (second *item-rect*))
                     (+ 50.0 (* 2 (+ (gui::rem-px 1) (gui::item-spacing-y))))))
             0.01)))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-malformed-specs-signal
  (with-controls-env ()
    (let ((x 0.0) (y 0.0))
      (dolist (args '((:x (:min)) (:x (:min 1 :max 1)) (:y (:min 1 :max 1))
                      (:x 5) (:y (:min 0 . 1)) (:x (:bogus 1))))
        (let ((args args))
          (signals gui:control-spec-error
            (with-test-frame () (in-window (apply #'gui:xy-pad-value "xy" x y args))))))
      (handler-case (with-test-frame () (in-window (gui:xy-pad "Pad" x y :x '(:min))))
        (gui:control-spec-error (e) (is (equal "Pad" (gui::control-spec-error-label e))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test xy-wrong-value-types-signal
  (with-controls-env ()
    (dolist (pair '((nil 0.0) (0.0 "a") ("a" nil)))
      (let ((x (first pair)) (y (second pair)))
        (handler-case
            (progn (with-test-frame () (in-window (gui:xy-pad "Pad" x y)))
                   (fail "no error for ~S" pair))
          (gui:widget-value-error (e) (is (equal "Pad" (gui::widget-value-error-label e)))))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

;;; Click-to-edit on the number box: a click (press and release without a
;;; drag) opens the text field once ImGui's double-click time has passed, so a
;;; double-click still resets.  Headless frames are 1/60 s apart.

(defun idle-frames (n draw)
  (dotimes (i n) (with-test-frame () (funcall draw))))

(defun double-click-frames ()
  "Frames that cover ImGui's double-click time, plus a margin."
  (+ 2 (ceiling (* 60 (cffi:foreign-slot-value (%imgui:get-io-nil) '(:struct %imgui::im-gui-io)
                                               '%imgui::mouse-double-click-time)))))

(defun open-field-p ()
  (some #'gui::control-state-edit-text (alexandria:hash-table-values gui::*control-states*)))

(test number-box-click-opens-text-field
  (with-controls-env ()
    (let* ((v 0)
           (draw (lambda () (in-window (gui:number-box "Transpose" v :min -24 :max 24 :unit :semitones)))))
      (click-item draw)
      (is (not (open-field-p)) "not before the double-click time has passed")
      (idle-frames (double-click-frames) draw)
      (is (open-field-p) "a click opens the field")
      (type-text "7" draw)
      (press-key %imgui:+key-enter+ draw)
      (is (eql 7 v))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test number-box-double-click-resets-without-opening
  (with-controls-env ()
    (let* ((v 5)
           (draw (lambda () (in-window (gui:number-box "Transpose" v :min -24 :max 24 :default 0)))))
      (click-item draw :clicker #'frames-with-double-click)
      (idle-frames (double-click-frames) draw)
      (is (eql 0 v))
      (is (not (open-field-p)))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test number-box-drag-does-not-open
  (with-controls-env ()
    (let* ((v 0.0)
           (draw (lambda () (in-window (gui:number-box "n" v)))))
      (prime-and-drag 0 (- (gui::rem-px 2)) draw)
      (idle-frames (double-click-frames) draw)
      (is (> v 0.1))
      (is (not (open-field-p)))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))

(test knob-click-does-not-open
  (with-controls-env ()
    (let ((v 0.5))
      (click-item (lambda () (in-window (gui:knob "k" v))))
      (idle-frames (double-click-frames) (lambda () (in-window (gui:knob "k" v))))
      (is (not (open-field-p)))
      (is (= 0 (hash-table-count gui::*control-states*))))
    (is (= 0 (%shim:assert-count)) "~A" (%shim:last-assert))))
