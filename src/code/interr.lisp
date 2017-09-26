;;;; functions and macros to define and deal with internal errors
;;;; (i.e. problems that can be signaled from assembler code)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

;;;; internal errors

(macrolet ((def-it ()
             (let ((n (1+ (position-if 'stringp sb!c:+backend-internal-errors+
                                       :key #'car :from-end t))))
               `(progn
                  (declaim ((simple-vector ,n) **internal-error-handlers**))
                  (!defglobal **internal-error-handlers**
                              ,(make-array n :initial-element 0))))))
  (def-it))

(eval-when (:compile-toplevel :execute)
(sb!xc:defmacro deferr (name args &rest body)
  (multiple-value-bind (llks required optional rest) (parse-lambda-list args)
    (declare (ignore llks))
    (aver (not rest))
    (let ((max (+ (length required) (length optional))))
      (unless (<= max 3)
        (error "Update (DEFUN INTERNAL-ERROR) for ~D error arguments" max))))
  `(setf (svref **internal-error-handlers** ,(error-number-or-lose name))
         (named-lambda ,(string name) (,@args)
           (declare (optimize (sb!c::verify-arg-count 0)))
           ,@body)))) ; EVAL-WHEN

;;; Backtrace code may want to know the error that caused
;;; interruption, but there are other means to get code interrupted
;;; and inspecting code around PC for the error number may yield wrong
;;; results.
(defvar *current-internal-error* nil)
(defvar *current-internal-trap-number*)
(defvar *current-internal-error-args*)

#!+undefined-fun-restarts
(defun restart-undefined (name fdefn-or-symbol context)
  (multiple-value-bind (tn-offset pc-offset)
      (if context
          (sb!c::decode-restart-location context)
          (car *current-internal-error-args*))
    (labels ((retry-value (value)
               (or (typecase value
                     (fdefn (fdefn-fun value))
                     (symbol
                      (let ((fdefn (symbol-fdefn value)))
                        (and fdefn
                             (fdefn-fun fdefn))))
                     (function value)
                     (t
                      (try (make-condition 'retry-undefined-function
                                           :name name
                                           :format-control "Bad value when restarting ~s: ~s"
                                           :format-arguments (list name value))
                           t)))
                   (try (make-condition 'retry-undefined-function
                                        :name name
                                        :format-control (if (fdefn-p value)
                                                            "~S is still undefined"
                                                            "Can't replace ~s with ~s because it is undefined")
                                        :format-arguments (list name value))
                        t)))
             (set-value (function retrying)
               (if retrying
                   (retry-value function)
                   (sb!di::sub-set-debug-var-slot
                    nil tn-offset
                    (retry-value function)
                    *current-internal-error-context*)))
             (try (condition &optional retrying)
               (cond (context
                      ;; The #'abc case from SAFE-FDEFN-FUN, CONTEXT
                      ;; specifies the offset from the error location
                      ;; where it can retry checking the FDEFN
                      (prog1
                          (restart-case (error condition)
                            (continue ()
                              :report (lambda (stream)
                                        (format stream "Retry using ~s." name))
                              (set-value fdefn-or-symbol retrying))
                            (use-value (value)
                              :report (lambda (stream)
                                        (format stream "Use specified function."))
                              :interactive read-evaluated-form
                              (set-value value retrying)))
                        (unless retrying
                          (sb!vm::incf-context-pc *current-internal-error-context*
                                                  pc-offset))))
                     (t
                      (restart-case (error condition)
                        (continue ()
                          :report (lambda (stream)
                                    (format stream "Retry calling ~s." name))
                          (set-value fdefn-or-symbol retrying))
                        (use-value (value)
                          :report (lambda (stream)
                                    (format stream "Call specified function."))
                          :interactive read-evaluated-form
                          (set-value value retrying))
                        (return-value (&rest values)
                          :report (lambda (stream)
                                    (format stream "Return specified values."))
                          :interactive mv-read-evaluated-form
                          (set-value (lambda (&rest args)
                                       (declare (ignore args))
                                       (values-list values))
                                     retrying))
                        (return-nothing ()
                          :report (lambda (stream)
                                    (format stream "Return zero values."))
                          (set-value (lambda (&rest args)
                                       (declare (ignore args))
                                       (values))
                                     retrying)))))))
      (try (make-condition 'undefined-function :name name)))))

(deferr undefined-fun-error (fdefn-or-symbol)
  (let ((name (etypecase fdefn-or-symbol
                (symbol fdefn-or-symbol)
                (fdefn (let ((name (fdefn-name fdefn-or-symbol)))
                         ;; fasteval stores weird things in the NAME slot
                         ;; of fdefns of special forms. Have to grab the
                         ;; special form name out of that.
                         (cond #!+(and sb-fasteval immobile-code)
                               ((and (listp name) (functionp (car name)))
                                (cadr (%fun-name (car name))))
                               (t
                                name))))))
        #!+undefined-fun-restarts
        context)
    (cond #!+undefined-fun-restarts
          ((or (= *current-internal-trap-number* sb!vm:cerror-trap)
               (integerp (setf context (sb!di:error-context))))
           (restart-undefined name fdefn-or-symbol context))
          (t
           (error 'undefined-function :name name)))))

#!+(or arm arm64 x86-64)
(deferr undefined-alien-fun-error (address)
  (error 'undefined-alien-function-error
         :name
         (and (integerp address)
              (sap-foreign-symbol (int-sap address)))))

#!-(or arm arm64 x86-64)
(defun undefined-alien-fun-error ()
  (error 'undefined-alien-function-error))

(deferr invalid-arg-count-error (nargs)
  (error 'simple-program-error
         :format-control "invalid number of arguments: ~S"
         :format-arguments (list nargs)))

(deferr local-invalid-arg-count-error (nargs name)
  (error 'simple-program-error
         :format-control "~S called with invalid number of arguments: ~S"
         :format-arguments (list name nargs)))

(deferr bogus-arg-to-values-list-error (list)
  (error 'simple-type-error
         :datum list
         :expected-type 'list
         :format-control
         "~@<attempt to use VALUES-LIST on a dotted list: ~2I~_~S~:>"
         :format-arguments (list list)))

(defun restart-unbound (symbol context)
  (multiple-value-bind (tn-offset pc-offset)
      (sb!c::decode-restart-location context)
    (labels ((retry-value (value)
               (multiple-value-bind (type defined)
                   (info :variable :type symbol)
                 (if (and defined
                          (not (ctypep value type)))
                     (try (make-condition 'retry-unbound-variable
                                          :name symbol
                                          :format-control
                                          "Type mismatch when restarting unbound symbol error:~@
                                           ~s is not of type ~s"
                                          :format-arguments (list value (type-specifier type))))
                     value)))
             (set-value (value &optional set-symbol)
               (sb!di::sub-set-debug-var-slot
                nil tn-offset (retry-value value)
                *current-internal-error-context*)
               (sb!vm::incf-context-pc *current-internal-error-context*
                                       pc-offset)
               (when set-symbol
                 (set symbol value))
               (return-from restart-unbound))
             (retry-evaluation ()
               (if (boundp symbol)
                   (set-value (symbol-value symbol))
                   (try (make-condition 'retry-unbound-variable
                                        :name symbol
                                        :format-control "~s is still unbound"
                                        :format-arguments (list symbol)))))
             (try (condition)
               (cond (t
                      (restart-case (error condition)
                        (continue ()
                          :report (lambda (stream)
                                    (format stream "Retry using ~s." symbol))
                          (retry-evaluation))
                        (use-value (value)
                          :report (lambda (stream)
                                    (format stream "Use specified value."))
                          :interactive read-evaluated-form
                          (set-value value))
                        (store-value (value)
                          :report (lambda (stream)
                                    (format stream "Set specified value and use it."))
                          :interactive read-evaluated-form
                          (set-value value t)))))))
      (try (make-condition 'unbound-variable :name symbol)))))

(deferr unbound-symbol-error (symbol)
  (let* ((context (sb!di:error-context)))
    (if context
        (restart-unbound symbol context)
        (error 'unbound-variable :name symbol))))

(deferr invalid-unwind-error ()
  (error 'simple-control-error
         :format-control
         "attempt to RETURN-FROM a block or GO to a tag that no longer exists"))

(deferr unseen-throw-tag-error (tag)
  (let ((text "attempt to THROW to a tag that does not exist: ~S"))
    #!+sb-fasteval
    (when (listp tag)
      (binding* ((frame (find-interrupted-frame))
                 (name (sb!di:debug-fun-name (sb!di:frame-debug-fun frame)))
                 (down (and (eq name 'sb!c::unwind) ; is this tautological ?
                            (sb!di:frame-down frame)) :exit-if-null))
        (case (sb!di:debug-fun-name (sb!di:frame-debug-fun down))
         ((return-from)
          (setq text "attempt to RETURN-FROM an exited block: ~S"
                     ;; block name was wrapped in a cons
                tag (car tag)))
         ((go)
                     ;; FIXME: can we reverse-engineer the tag name from
                     ;; the object that was thrown, for a better diagnostic?
          (setq text "attempt to GO into an exited tagbody")))))
    (error 'simple-control-error
           :format-control text :format-arguments (list tag))))

(deferr nil-fun-returned-error (function)
  (error 'simple-control-error
         :format-control
         "A function with declared result type NIL returned:~%  ~S"
         :format-arguments (list function)))

(deferr nil-array-accessed-error (array)
  (error 'nil-array-accessed-error
         :datum array :expected-type '(not (array nil))))

(deferr division-by-zero-error (this that)
  (error 'division-by-zero
         :operation '/
         :operands (list this that)))

(deferr object-not-type-error (object type)
  (if (invalid-array-p object)
      (invalid-array-error object)
      (error (if (and (%instancep object)
                      (layout-invalid (%instance-layout object)))
                 'layout-invalid
                 'type-error)
             :datum object
             :expected-type type
             :context (sb!di:error-context))))

(deferr layout-invalid-error (object layout)
  (error 'layout-invalid
         :datum object
         :expected-type (layout-classoid layout)))

(deferr odd-key-args-error ()
  (error 'simple-program-error
         :format-control "odd number of &KEY arguments"))

(deferr unknown-key-arg-error (key-name)
  (let ((context (sb!di:error-context)))
    (if (integerp context)
        (restart-case
            (error 'unknown-keyword-argument :name key-name)
          (continue ()
            :report (lambda (stream)
                      (format stream "Ignore all unknown keywords"))
            (sb!vm::incf-context-pc *current-internal-error-context*
                                    context)))
        (error 'unknown-keyword-argument :name key-name))))

;; TODO: make the arguments (ARRAY INDEX &optional BOUND)
;; and don't need the bound for vectors. Just read it.
(deferr invalid-array-index-error (array bound index)
  (invalid-array-index-error array index bound))

(deferr tls-exhausted-error ()
  ;; There is nothing we can do about it. A number of entries in the
  ;; tls could be reserved and made available for recovery but since
  ;; tls indices are never reused it would be kind of silly and
  ;; without it signalling an error is more than likely to end in a
  ;; recursive error.
  (%primitive print "Thread local storage exhausted.")
  (sb!impl::%halt))

;;;; INTERNAL-ERROR signal handler

;;; This is needed for restarting XEPs, which do not bind anything but
;;; also do not save their own BSP, and we need to discard the
;;; bindings made by the error handling machinery.
#!+unwind-to-frame-and-call-vop
(defvar *interr-current-bsp* nil)

(defun internal-error (context continuable)
  (declare (type system-area-pointer context))
  (declare (ignore continuable))
  (/show0 "entering INTERNAL-ERROR, CONTEXT=..")
  (/hexstr context)
  (let (#!+unwind-to-frame-and-call-vop
        (*interr-current-bsp*
          ;; Needs to be done before anything is bound
          (%primitive sb!c:current-binding-pointer)))
   (infinite-error-protect
    (/show0 "about to bind ALIEN-CONTEXT")
    (let* ((alien-context (sap-alien context (* os-context-t)))
           #!+c-stack-is-control-stack
           (fp-and-pc (make-array 2 :element-type 'word)))
      #!+c-stack-is-control-stack
      (declare (truly-dynamic-extent fp-and-pc))
      #!+c-stack-is-control-stack
      (setf (aref fp-and-pc 0) (sb!vm:context-register alien-context sb!vm::cfp-offset)
            (aref fp-and-pc 1) (sb!sys:sap-int (sb!vm:context-pc alien-context)))
      (let (#!+c-stack-is-control-stack
            (*saved-fp-and-pcs* (cons fp-and-pc *saved-fp-and-pcs*)))
        #!+c-stack-is-control-stack
        (declare (truly-dynamic-extent *saved-fp-and-pcs*))
       (/show0 "about to bind ERROR-NUMBER and ARGUMENTS"))
      (multiple-value-bind (error-number arguments
                            *current-internal-trap-number*)
          (sb!vm:internal-error-args alien-context)
        (with-interrupt-bindings
          (let ((sb!debug:*stack-top-hint* (find-interrupted-frame))
                (*current-internal-error* error-number)
                (*current-internal-error-args* arguments)
                (*current-internal-error-context* alien-context)
                (fp (int-sap (sb!vm:context-register alien-context
                                                     sb!vm::cfp-offset))))
            (if (and (>= error-number (length **internal-error-handlers**))
                     (< error-number (length sb!c:+backend-internal-errors+)))
                (let ((context (sb!di:error-context)))
                  (if (typep context '(cons (eql :struct-read)))
                      ;; This was shoehorned into being a "type error"
                      ;; which isn't the best way to explain it to the user.
                      ;; However, from an API stance, it makes some sense to signal
                      ;; a TYPE-ERROR since there may be existing code that catches
                      ;; unbound slots errors as type-errors. Our tests certainly do,
                      ;; but perhaps only as an artifact of the implementation.
                      (destructuring-bind (struct-name . slot-name) (cdr context)
                        ;; Infer the slot type, but fail safely. The message is enough,
                        ;; and the required type is pretty much irrelevant.
                        (let* ((dd (find-defstruct-description struct-name))
                               (dsd (and dd (find slot-name (dd-slots dd) :key #'dsd-name))))
                          (error 'simple-type-error
                                 :format-control "Accessed uninitialized slot ~S of structure ~S"
                                 :format-arguments (list slot-name struct-name)
                                 :datum (make-unbound-marker)
                                 :expected-type (if dsd (dsd-type dsd) 't))))
                      (error 'type-error
                             :datum (sb!di::sub-access-debug-var-slot
                                     fp (first arguments) alien-context)
                             :expected-type
                             (car (svref sb!c:+backend-internal-errors+
                                         error-number))
                             :context context)))
                (let ((handler
                        (and (typep error-number
                                    '#.`(mod ,(length **internal-error-handlers**)))
                             (svref **internal-error-handlers** error-number))))
                  (cond
                    ((functionp handler)
                     ;; INTERNAL-ERROR-ARGS supplies the right amount of arguments
                     (macrolet ((arg (n)
                                  `(sb!di::sub-access-debug-var-slot
                                    fp (nth ,n arguments) alien-context)))
                       (ecase (length arguments)
                         (0 (funcall handler))
                         (1 (funcall handler (arg 0)))
                         (2 (funcall handler (arg 0) (arg 1)))
                         (3 (funcall handler (arg 0) (arg 1) (arg 2))))))
                    ((eql handler 0) ; if (DEFERR x) was inadvertently omitted
                     (error 'simple-error
                            :format-control
                            "unknown internal error, ~D, args=~S"
                            :format-arguments
                            (list error-number
                                  (mapcar (lambda (sc-offset)
                                            (sb!di::sub-access-debug-var-slot
                                             fp sc-offset alien-context))
                                          arguments))))
                    (t                  ; wtf?
                     (error 'simple-error
                            :format-control "internal error ~D: ~A; args=~S"
                            :format-arguments
                            (list error-number
                                  handler
                                  (mapcar (lambda (sc-offset)
                                            (sb!di::sub-access-debug-var-slot
                                             fp sc-offset alien-context))
                                          arguments))))))))))))))

(defun control-stack-exhausted-error ()
  (let ((sb!debug:*stack-top-hint* nil))
    (infinite-error-protect
     (format *error-output*
             "Control stack guard page temporarily disabled: proceed with caution~%")
     (error 'control-stack-exhausted))))

(defun binding-stack-exhausted-error ()
  (let ((sb!debug:*stack-top-hint* nil))
    (infinite-error-protect
     (format *error-output*
             "Binding stack guard page temporarily disabled: proceed with caution~%")
     (error 'binding-stack-exhausted))))

(defun alien-stack-exhausted-error ()
  (let ((sb!debug:*stack-top-hint* nil))
    (infinite-error-protect
     (format *error-output*
             "Alien stack guard page temporarily disabled: proceed with caution~%")
     (error 'alien-stack-exhausted))))

;;; KLUDGE: we keep a single HEAP-EXHAUSTED-ERROR object around, so
;;; that we don't need to allocate it when running out of
;;; memory. Similarly we pass the amounts in special variables as
;;; there may be multiple threads running into trouble at the same
;;; time. The condition is created by GC-REINIT.
(define-load-time-global *heap-exhausted-error-condition*
  (make-condition 'heap-exhausted-error))
(defvar *heap-exhausted-error-available-bytes*)
(defvar *heap-exhausted-error-requested-bytes*)

(defun heap-exhausted-error (available requested)
  ;; Double word aligned bytes, can be passed as fixnums to avoid
  ;; allocating bignums on the C side.
  (declare (fixnum available requested))
  (infinite-error-protect
   (let ((*heap-exhausted-error-available-bytes*
           (ash available sb!vm:n-fixnum-tag-bits))
         (*heap-exhausted-error-requested-bytes*
           (ash requested sb!vm:n-fixnum-tag-bits)))
     (error *heap-exhausted-error-condition*))))

(defun undefined-alien-variable-error ()
  (declare (optimize allow-non-returning-tail-call))
  (error 'undefined-alien-variable-error))

#!-win32
(define-alien-variable current-memory-fault-address unsigned)

#!-win32
(defun memory-fault-error ()
  (let ((sb!debug:*stack-top-hint* (find-interrupted-frame)))
    (error 'memory-fault-error
           :address current-memory-fault-address)))

;;; This is SIGTRAP / EXCEPTION_BREAKPOINT that runtime could not deal
;;; with. Prior to Windows we just had a Lisp side handler for
;;; SIGTRAP, but now we need to deal with this portably.
(defun unhandled-trap-error (context-sap)
  (declare (type system-area-pointer context-sap))
  (infinite-error-protect
   (let ((context (sap-alien context-sap (* os-context-t))))
     (error 'breakpoint-error
            :context context
            :address (sap-int (sb!vm:context-pc context))))))
