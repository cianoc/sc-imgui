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
