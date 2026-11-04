;;;; Hand-written bindings for native/shim.h.
(cl:in-package #:%shim)

(cffi:defcfun ("shim_open_window" open-window) :int
  (width :int) (height :int) (title :string) (ini-path :string))
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
(cffi:defcfun ("shim_onscreen_window_count" onscreen-window-count) :int)
