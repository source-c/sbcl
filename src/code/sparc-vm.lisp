;;;; SPARC-specific runtime stuff

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.
(in-package "SB!VM")

;;; See x86-vm.lisp for a description of this.
#-sb-xc-host
(defun machine-type ()
  "Returns a string describing the type of the local machine."
  "SPARC")

(!with-bigvec-or-sap
(defun fixup-code-object (code offset fixup kind &optional flavor)
  (declare (type index offset))
  (declare (ignore flavor))
  (unless (zerop (rem offset n-word-bytes))
    (error "Unaligned instruction?  offset=#x~X." offset))
  (without-gcing
   (let ((sap (code-instructions code)))
     (ecase kind
       (:call
        (error "Can't deal with CALL fixups, yet."))
       (:sethi
        (setf (ldb (byte 22 0) (sap-ref-32 sap offset))
              (ldb (byte 22 10) fixup)))
       (:add
        (setf (ldb (byte 10 0) (sap-ref-32 sap offset))
              (ldb (byte 10 0) fixup)))
       (:absolute
        (setf (sap-ref-32 sap offset)
              fixup)))))))


;;;; "Sigcontext" access functions, cut & pasted from alpha-vm.lisp.
;;;;
;;;; See also x86-vm for commentary on signed vs unsigned.

#-sb-xc-host (progn
;;; This is like CONTEXT-REGISTER, but returns the value of a float
;;; register. FORMAT is the type of float to return.

;;; FIXME: Whether COERCE actually knows how to make a float out of a
;;; long is another question. This stuff still needs testing.
#+nil
(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* long)
  (context (* os-context-t))
  (index int))
#+nil
(defun context-float-register (context index format)
  (declare (type (alien (* os-context-t)) context))
  (coerce (deref (context-float-register-addr context index)) format))
#+nil
(defun %set-context-float-register (context index format new)
  (declare (type (alien (* os-context-t)) context))
  (setf (deref (context-float-register-addr context index))
        (coerce new format)))

;;; Given a signal context, return the floating point modes word in
;;; the same format as returned by FLOATING-POINT-MODES.

;;; Under SunOS, we have a straightforward implementation in C:
#!+sunos
(define-alien-routine ("os_context_fp_control" context-floating-point-modes)
    (unsigned 32)
  (context (* os-context-t)))

;;; Under Linux, we have to contend with utterly broken signal handling.
#!+linux
(defun context-floating-point-modes (context)
  (declare (ignore context))
  (warn "stub CONTEXT-FLOATING-POINT-MODES")
  0)

;;;; INTERNAL-ERROR-ARGS.

;;; Given a (POSIX) signal context, extract the internal error
;;; arguments from the instruction stream.  This is e.g.
;;; 4       23      254     240     2       0       0       0
;;; |       ~~~~~~~~~~~~~~~~~~~~~~~~~
;;; length         data              (everything is an octet)
;;;  (pc)
(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (/show0 "entering INTERNAL-ERROR-ARGS")
  (let* ((pc (context-pc context))
         (error-number (sap-ref-8 pc 4)))
    (declare (type system-area-pointer pc))
    (values error-number
            (sb!kernel::decode-internal-error-args (sap+ pc 5) error-number))))
) ; end PROGN
