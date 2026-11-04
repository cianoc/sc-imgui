(in-package #:sc-imgui.generator)

(defun c-name->lisp-name (c-name prefix)
  "Strip PREFIX from C-NAME, split CamelCase into words joined by `-`, and
lowercase.  `_` becomes `-`.  An uppercase letter starts a new word after a
lowercase letter or digit, or when it ends a run of capitals that is followed
by a lowercase letter."
  (let* ((start (if (and prefix
                         (plusp (length prefix))
                         (>= (length c-name) (length prefix))
                         (string= prefix c-name :end2 (length prefix)))
                    (length prefix)
                    0))
         (name (subseq c-name start))
         (n (length name)))
    (with-output-to-string (out)
      (dotimes (i n)
        (let ((c (char name i)))
          (cond ((char= c #\_) (write-char #\- out))
                (t
                 (when (and (upper-case-p c) (plusp i))
                   (let ((prev (char name (1- i)))
                         (next (and (< (1+ i) n) (char name (1+ i)))))
                     (when (or (lower-case-p prev)
                               (digit-char-p prev)
                               (and (upper-case-p prev) next (lower-case-p next)))
                       (write-char #\- out))))
                 (write-char (char-downcase c) out))))))))
