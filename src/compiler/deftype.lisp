;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

(defun constant-type-expander (name expansion)
  (declare (optimize safety))
  ;; Dummy implementation of SET-CLOSURE-NAME for the host.
  (flet (#+sb-xc-host (set-closure-name (f name) (declare (ignore name)) f))
    (set-closure-name
     (lambda (whole)
       ;; NB: It does not in general work to set the lambda-list of a closure,
       ;; but all constant-type-expanders have NIL as the lambda-list
       ;; because if they didn't, they wouldn't be constant.
       (declare (sb!c::lambda-list ()))
       (if (cdr whole)
           (error 'sb!kernel::arg-count-error
                  :kind 'deftype :name (car whole) :args (cdr whole)
                  :lambda-list '() :minimum 0 :maximum 0)
           expansion))
     `(type-expander ,name))))

;; Can't have a function called SIMPLE-TYPE-ERROR or TYPE-ERROR...
;; FUNCTION returning NIL is as good as SFUNCTION returning NIL,
;; so we don't care that this can't use (FTYPE (SFUNCTION ...)).
;; But do we really need this? It's not highly useful.
(declaim (ftype (function (t t t &rest t) #+(and sb-xc-host ccl) *
                                          #-(and sb-xc-host ccl) nil) bad-type))
(defun bad-type (datum type control &rest arguments)
  (error 'simple-type-error
         :datum datum
         :expected-type type
         :format-control control
         :format-arguments arguments))

(defmacro sb!xc:deftype (&whole form name lambda-list &body body
                         &environment env)
  "Define a new type, with syntax like DEFMACRO."
  (declare (ignore env))
  (unless (symbolp name)
    (bad-type name 'symbol "Type name is not a symbol:~%  ~S"
              form))
  (multiple-value-bind (expander-form doc source-location-form)
      (multiple-value-bind (forms decls doc) (parse-body body t)
        (acond ((and (not lambda-list) (not decls)
                    (let ((expr `(progn ,@forms)))
                      ;; While CONSTANTP works early, %MACROEXPAND does not,
                      ;; so we can't pass ENV because it'd try to macroexpand.
                      (if (sb!xc:constantp expr) expr)))
                #-sb-xc-host
                (check-deprecated-type (constant-form-value it))
                (values `(constant-type-expander ',name ,it) doc
                        '(sb!c:source-location)))
               (t
                ;; FIXME: it seems non-ANSI-compliant to pretend every lexenv
                ;; is nil. See also lp#309140.
                ;; Source-location and docstring are associated with the lambda
                ;; so we don't store them separately.
                (make-macro-lambda `(type-expander ,name)
                                   lambda-list body 'deftype name
                                   :doc-string-allowed :external
                                   :environment :ignore))))
    ;; Maybe kill docstring, but only under the cross-compiler.
    #!+(and (not sb-doc) (host-feature sb-xc-host)) (setq doc nil)
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (%compiler-deftype ',name ,expander-form ,source-location-form
                            ,@(when doc `(,doc)))))))
