;;; This file contains the ARM specific runtime stuff.
;;;
(in-package "SB!VM")

#-sb-xc-host
(defun machine-type ()
  "Return a string describing the type of the local machine."
  "ARM")

;;;; FIXUP-CODE-OBJECT

(!with-bigvec-or-sap
(defun fixup-code-object (code offset fixup kind &optional flavor)
  (declare (type index offset))
  (declare (ignore flavor))
  (unless (zerop (rem offset n-word-bytes))
    (error "Unaligned instruction?  offset=#x~X." offset))
  (without-gcing
   (let ((sap (code-instructions code)))
     (ecase kind
       (:absolute
        (setf (sap-ref-32 sap offset) fixup)))))))

;;;; "Sigcontext" access functions, cut & pasted from sparc-vm.lisp,
;;;; then modified for ARM.
;;;;
;;;; See also x86-vm for commentary on signed vs unsigned.

#-sb-xc-host (progn
(defun context-float-register (context index format)
  (declare (ignorable context index))
  (warn "stub CONTEXT-FLOAT-REGISTER")
  (coerce 0 format))

(defun %set-context-float-register (context index format new-value)
  (declare (ignore context index))
  (warn "stub %SET-CONTEXT-FLOAT-REGISTER")
  (coerce new-value format))

;;;; INTERNAL-ERROR-ARGS.

;;; Given a (POSIX) signal context, extract the internal error
;;; arguments from the instruction stream.
(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (let* ((pc (context-pc context))
         (error-number (sap-ref-8 pc 5)))
    (declare (type system-area-pointer pc))
    (values error-number
            (sb!kernel::decode-internal-error-args (sap+ pc 6) error-number))))
) ; end PROGN
