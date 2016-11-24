;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

(in-package :cl-user)

(defvar *format-mode*)

(defun format* (format-control &rest arguments)
  (ecase *format-mode*
    (:interpret
     (eval `(format nil ,format-control ,@arguments)))
    (:compile
     (let ((names (sb-int:make-gensym-list (length arguments))))
       (funcall (checked-compile
                 `(lambda ,names (format nil ,format-control ,@names)))
                arguments)))))

(defmacro with-compiled-and-interpreted-format (() &body body)
  `(flet ((run-body (mode)
            (let ((*format-mode* mode))
              (handler-case
                  (progn ,@body)
                (error (condition)
                  (error "~@<Error in ~A FORMAT: ~A~@:>"
                         mode condition))))))
     (run-body :interpret)
     (run-body :compile)))

(defun format-error-format-control-string-p (condition)
  (and (typep condition 'sb-format:format-error)
       (sb-format::format-error-control-string condition)))

(deftype format-error-with-control-string ()
  `(and sb-format:format-error
        (satisfies format-error-format-control-string-p)))

(with-test (:name (:[-directive :non-integer-argument))
  (with-compiled-and-interpreted-format ()
    (assert-error (format* "~[~]" 1d0) format-error-with-control-string)))

(with-test (:name (:P-directive :no-previous-argument))
  (with-compiled-and-interpreted-format ()
    (assert-error (format* "~@<~:P~@:>" '()) format-error-with-control-string)))

(with-test (:name (:*-directive :out-of-bounds))
  (with-compiled-and-interpreted-format ()
    (assert-error (format* "~2@*" '()) format-error-with-control-string)
    (assert-error (format* "~1:*" '()) format-error-with-control-string)))
