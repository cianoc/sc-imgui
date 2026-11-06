;;;; controls.lisp -- a Live-style synth device built from the audio controls.
;;;;
;;;; Run:  (ql:quickload :sc-imgui)  (gui:start)
;;;;       (load (asdf:system-relative-pathname :sc-imgui "examples/controls.lisp"))
;;;; Drag a knob or fader up or down (Shift for fine); double-click resets it;
;;;; Cmd-click (Ctrl-click off macOS) types a value, e.g. 2k or -6; a plain
;;;; click on the Transpose number box does too.
;;;; Drag in the XY pad to move cutoff and resonance together.
;;;; Try (gui:set-theme :dark) and (gui:set-font-size 20).

(in-package #:cl-user)

(defvar *example-cutoff* 1000.0)
(defvar *example-res* 0.3)
(defvar *example-pan* 0.0)
(defvar *example-wave* 1)
(defvar *example-volume* -6.0)
(defvar *example-send* 0.5)
(defvar *example-mute* nil)
(defvar *example-hits* 0)
(defvar *example-held* nil)
(defvar *example-transpose* 0)

(defparameter *example-waves* '("Sine" "Saw" "Square" "Noise"))
(defparameter *example-cutoff-spec* '(:min 20 :max 20000 :scale :log :unit :hz))
(defparameter *example-res-spec* '(:unit :percent))

(gui:define-gui example-controls ()
  (gui:with-window ("Synth device")
    (gui:with-row ()
      (gui:knob "Cutoff" *example-cutoff* :min 20 :max 20000 :scale :log :unit :hz)
      (gui:knob "Res" *example-res* :unit :percent)
      (gui:knob "Pan" *example-pan* :min -1 :max 1 :bipolar t :unit :pan)
      (gui:knob "Wave" *example-wave* :choices *example-waves*))
    (gui:fader "Volume" *example-volume* :min -70 :max 6 :default 0 :unit :db)
    (gui:with-row ()
      (gui:fader "Send" *example-send* :vertical t :length 6 :unit :percent)
      (gui:with-group ()
        (gui:with-row ()
          (gui:toggle "Mute" *example-mute*)
          (multiple-value-bind (pressed held) (gui:trigger "Hit")
            (when pressed (incf *example-hits*))
            (setf *example-held* held)))
        (gui:number-box "Transpose" *example-transpose*
                        :min -24 :max 24 :unit :semitones)
        (gui:text "Hits: ~D~:[~; (held)~]" *example-hits* *example-held*))
      (gui:xy-pad "Cutoff / Res" *example-cutoff* *example-res*
                  :x *example-cutoff-spec* :y *example-res-spec*))
    (gui:text "~A  cutoff ~,0F Hz  res ~,2F  pan ~,2F  volume ~,1F dB~:[~; (muted)~]"
              (nth *example-wave* *example-waves*) *example-cutoff* *example-res*
              *example-pan* *example-volume* *example-mute*)))
