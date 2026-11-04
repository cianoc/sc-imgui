(in-package #:sc-imgui.bindings)

(defun shim-file-name ()
  (cond ((member :darwin *features*) "libsc_imgui_shim.dylib")
        ((member :windows *features*) "sc_imgui_shim.dll")
        (t "libsc_imgui_shim.so")))

(defun default-search-paths ()
  (let ((env (uiop:getenv "SC_IMGUI_LIB"))
        (root (asdf:system-source-directory "sc-imgui")))
    (append (when (and env (plusp (length env)))
              (list (uiop:ensure-directory-pathname env)))
            (list (merge-pathnames "native/build/" root)
                  (merge-pathnames "native/build/Release/" root)))))

(defvar *library-search-paths* (default-search-paths)
  "Directories searched, in order, for the native shim library.")

(define-condition shim-library-not-found (error)
  ((paths :initarg :paths :reader shim-library-not-found-paths))
  (:report (lambda (c stream)
             (format stream "Native shim library ~A not found.  Tried:~{~%  ~A~}~%~
                             Build it with `make native`, or set SC_IMGUI_LIB to its directory."
                     (shim-file-name)
                     (mapcar #'namestring (shim-library-not-found-paths c))))))

(defun load-shim-library ()
  "Load the first existing shim library from *LIBRARY-SEARCH-PATHS*.  Signals
SHIM-LIBRARY-NOT-FOUND, listing every path tried, when there is none."
  (let* ((candidates (mapcar (lambda (dir) (merge-pathnames (shim-file-name) dir))
                             *library-search-paths*))
         (found (find-if #'probe-file candidates)))
    (unless found
      (error 'shim-library-not-found :paths candidates))
    (unless (handler-case (cffi:foreign-library-loaded-p 'shim)
              (cffi::foreign-library-undefined-error () nil))
      (eval `(cffi:define-foreign-library shim (t ,(namestring (truename found)))))
      (cffi:load-foreign-library 'shim))
    found))

(load-shim-library)
