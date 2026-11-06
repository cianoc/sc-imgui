;;;; Hand-written bindings for native/shim.h.
(cl:in-package #:%shim)

(cffi:defcfun ("shim_open_window" open-window) :int
  (width :int) (height :int)
  (title sc-imgui.bindings:optional-string)
  (ini-path sc-imgui.bindings:optional-string)) ; NIL = no ini file
(cffi:defcfun ("shim_should_close" should-close) :int)
(cffi:defcfun ("shim_begin_frame" begin-frame) :void)
(cffi:defcfun ("shim_end_frame" end-frame) :void)
(cffi:defcfun ("shim_shutdown" shutdown) :void)
(cffi:defcfun ("shim_last_error" last-error) :string)
(cffi:defcfun ("shim_headless_create" headless-create) :int
  (width :int) (height :int))
(cffi:defcfun ("shim_headless_destroy" headless-destroy) :void)
(cffi:defcfun ("shim_assert_count" assert-count) :int)
(cffi:defcfun ("shim_last_assert" last-assert) :string)
(cffi:defcfun ("shim_clear_asserts" clear-asserts) :void)
(cffi:defcfun ("shim_show_window" show-window) :void
  (title sc-imgui.bindings:optional-string))     ; main thread; NIL = keep the title
(cffi:defcfun ("shim_hide_window" hide-window) :void) ; main thread; saves the ini file
(cffi:defcfun ("shim_wait_events" wait-events) :int (timeout :double)) ; main thread
(cffi:defcfun ("shim_wake" wake) :void)                        ; any thread
(cffi:defcfun ("shim_window_visible" window-visible) :int)     ; main thread
(cffi:defcfun ("shim_test_request_close" test-request-close) :int) ; tests only
(cffi:defcfun ("shim_add_font" add-font) :int   ; main thread; index, or -1
  (path sc-imgui.bindings:optional-string) (size :float))
(cffi:defcfun ("shim_push_font" push-font) :void ; main thread; balance with %imgui:pop-font
  (index :int) (size :float))
(cffi:defcfun ("shim_set_clear_color" set-clear-color) :void ; main thread
  (r :float) (g :float) (b :float))
