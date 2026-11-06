(in-package #:sc-imgui.tests)
(in-suite controls)

(defun spec (&rest args &key (value 0.5) &allow-other-keys)
  (apply #'gui::parse-control-spec "t" value (alexandria:remove-from-plist args :value)))

(test linear-round-trip
  (let ((s (spec :min 20 :max 220)))
    (is (= 0.5 (gui::value->position s 120.0)))
    (is (= 120.0 (gui::position->value s 0.5 1.0)))))

(test log-round-trip
  (let ((s (spec :min 20 :max 20000 :scale :log)))
    (is (< (abs (- 0.5 (gui::value->position s (sqrt (* 20 20000))))) 1e-5))
    (is (< (abs (- 632.456 (gui::position->value s 0.5 1.0))) 0.01))))

(test log-position-of-nonpositive-value            ; Review Focus 1
  (let ((s (spec :min 20 :max 20000 :scale :log)))
    (is (= 0.0 (gui::value->position s 0)))
    (is (= 0.0 (gui::value->position s -5.0)))))

(test stepped-and-integer-snap
  (is (= 0.5 (gui::position->value (spec :min 0 :max 1 :step 0.25) 0.55 1.0)))
  (let ((s (spec :value 3 :min -12 :max 12)))
    (is (= 1 (gui::control-spec-step s)))
    (is (eql 0 (gui::position->value s 0.51 3)))))

(test types-preserved
  (is (typep (gui::position->value (spec) 0.3 0.5d0) 'double-float))
  (is (typep (gui::position->value (spec) 0.3 1/2) 'single-float))
  (is (integerp (gui::position->value (spec :value 1 :choices '("a" "b" "c")) 0.9 1))))

(test choices-index-clamped                         ; Review Focus 3
  (let ((s (spec :value 1 :choices '("a" "b" "c"))))
    (is (= 2 (gui::control-spec-max s)))
    (is (= 1.0 (gui::value->position s 7)))
    (is (= 2 (gui::clamp-to-spec s 7)))))

(test bipolar-origin-and-default
  (let ((s (spec :min -1 :max 1 :bipolar t)))
    (is (= 0 (gui::control-spec-origin s)))
    (is (= 0 (gui::control-spec-default s))))
  (is (= 15 (gui::control-spec-origin (spec :min 10 :max 20 :bipolar t))))
  (is (= 0.2 (gui::control-spec-origin (spec :bipolar 0.2)))))

(test spec-errors
  (dolist (args '((:min 1 :max 1) (:min 0 :max 10 :scale :log) (:step 0)
                  (:choices ()) (:choices ("a" 2)) (:choices ("a") :min 0)
                  (:default 5) (:unit :furlongs) (:scale :exp)))
    (handler-case (progn (apply #'spec args) (fail "no error for ~S" args))
      (gui:control-spec-error (e) (is (search "\"t\"" (princ-to-string e)))))))

(test unit-formatting
  (flet ((f (unit v &rest args) (gui::format-control-value (apply #'spec :unit unit args) v)))
    (is (string= "440 Hz" (f :hz 440.0 :min 20 :max 20000)))
    (is (string= "999 Hz" (f :hz 999.0 :min 20 :max 20000)))
    (is (string= "1.00 kHz" (f :hz 1000.0 :min 20 :max 20000)))
    (is (string= "2.40 kHz" (f :hz 2400.0 :min 20 :max 20000)))
    (is (string= "-6.0 dB" (f :db -6.0 :min -70 :max 6)))
    (is (string= "-inf dB" (f :db -70.0 :min -70 :max 6)))
    (is (string= "120 ms" (f :ms 120.0 :min 0 :max 5000)))
    (is (string= "1.20 s" (f :ms 1200.0 :min 0 :max 5000)))
    (is (string= "62 %" (f :percent 0.62)))
    (is (string= "+3 st" (f :semitones 3 :value 3 :min -12 :max 12)))
    (is (string= "0 st" (f :semitones 0 :value 0 :min -12 :max 12)))
    (is (string= "C" (f :pan 0.0 :min -1 :max 1)))
    (is (string= "C" (f :pan 0.004 :min -1 :max 1)))
    (is (string= "25R" (f :pan 0.5 :min -1 :max 1)))
    (is (string= "50L" (f :pan -1.0 :min -1 :max 1)))))

(test plain-number-precision
  (flet ((f (v &rest args) (gui::format-control-value (apply #'spec args) v)))
    (is (string= "123" (f 123.4 :min 0 :max 200)))
    (is (string= "12.3" (f 12.34 :min 0 :max 20)))
    (is (string= "0.50" (f 0.5 :min 0 :max 1)))
    (is (string= "7" (f 7 :value 7 :min 0 :max 8)))))

(test choice-and-custom-formatting
  (is (string= "Saw" (gui::format-control-value (spec :value 1 :choices '("Sine" "Saw")) 1)))
  (is (string= "Saw" (gui::format-control-value (spec :value 1 :choices '("Sine" "Saw")) 9)))
  (is (string= "x7" (gui::format-control-value (spec :format (lambda (v) (format nil "x~D" (round v)))) 7.0)))
  (signals error (gui::format-control-value (spec :format (lambda (v) (error "boom ~A" v))) 1.0)))

(test text-parsing
  (flet ((p (unit text &rest args) (gui::parse-control-text (apply #'spec :unit unit args) text)))
    (is (= 2000 (p :hz "2k" :min 20 :max 20000)))
    (is (= 2400 (p :hz "2.4 kHz" :min 20 :max 20000)))
    (is (= -6 (p :db "-6 dB" :min -70 :max 6)))
    (is (= -6 (p :db "-6" :min -70 :max 6)))
    (is (= 1200 (p :ms "1.2s" :min 0 :max 5000)))
    (is (= 0.5 (p :pan "25R" :min -1 :max 1)))
    (is (= -1 (p :pan "50L" :min -1 :max 1)))
    (is (= 0 (p :pan "C" :min -1 :max 1)))
    (is (= 0.62 (p :percent "62%")))
    (is (= 0.62 (p :percent "62 %")))
    (is (= 3 (p :semitones "+3 st" :min -12 :max 12)))
    (is (= -70 (p :db "-inf dB" :min -70 :max 6)))
    (is (equal '(nil nil) (multiple-value-list (p :hz "abc" :min 20 :max 20000))))
    (is (equal '(nil nil) (multiple-value-list (p :hz "" :min 20 :max 20000))))
    (is (equal '(nil nil) (multiple-value-list (p :hz "1e3" :min 20 :max 20000))))
    (is (equal '(nil nil) (multiple-value-list (p :hz "#.(foo)" :min 20 :max 20000))))
    (is (equal '(nil nil) (multiple-value-list (p :hz "2 kHzz" :min 20 :max 20000)))))
  (is (= 1 (gui::parse-control-text (spec :value 0 :choices '("Sine" "Saw")) "saw")))
  (is (equal '(nil nil) (multiple-value-list
                         (gui::parse-control-text (spec :value 0 :choices '("Sine" "Saw")) "tri")))))

(test parse-never-signals-on-huge-numbers
  (let ((s (spec :unit :hz :min 20 :max 20000))
        (huge (format nil "1~A.5" (make-string 60 :initial-element #\0))))
    (is (equal '(nil nil) (multiple-value-list (gui::parse-control-text s huge))))
    (finishes (gui::parse-control-text            ; tiny: may underflow, must not signal
               s (format nil "0.~A1" (make-string 60 :initial-element #\0))))))

(test bare-numbers-follow-display-scale
  (flet ((p (unit text &rest args) (gui::parse-control-text (apply #'spec :unit unit args) text)))
    (is (= 0.62 (p :percent "62")))
    (is (= 0.5 (p :pan "25" :min -1 :max 1)))
    (is (= -0.5 (p :pan "-25" :min -1 :max 1)))
    (is (= 0 (p :pan "0" :min -1 :max 1)))
    (is (= 0.5 (p :pan "25R" :min -1 :max 1)))
    (is (= -1 (p :pan "50L" :min -1 :max 1)))
    (is (= -6 (p :db "-6" :min -70 :max 6)))
    (is (= 440 (p :hz "440" :min 20 :max 20000)))
    (is (= 120 (p :ms "120" :min 0 :max 5000)))
    (is (= 3 (p :semitones "3" :min -12 :max 12)))))

(test format-parse-boundaries
  (flet ((f (unit v &rest args) (gui::format-control-value (apply #'spec :unit unit args) v)))
    (is (string= "1.00 kHz" (f :hz 999.6 :min 20 :max 20000)))
    (is (string= "0.0 dB" (f :db -0.04 :min -70 :max 6))))
  (let ((s (spec :unit :hz :min 20 :max 20000)))
    (is (= 0.5 (gui::parse-control-text s ".5")))
    (is (= 5 (gui::parse-control-text s "5.")))
    (is (= 440 (gui::parse-control-text s "  440 Hz  ")))
    (is (equal '(nil nil) (multiple-value-list (gui::parse-control-text s "-"))))
    (is (equal '(nil nil) (multiple-value-list (gui::parse-control-text s ""))))))
