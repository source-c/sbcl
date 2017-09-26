;;;; X86-64-specific runtime stuff

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")
(defun machine-type ()
  "Return a string describing the type of the local machine."
  "X86-64")

;;;; :CODE-OBJECT fixups

;;; This gets called by LOAD to resolve newly positioned objects
;;; with things (like code instructions) that have to refer to them.
(defun fixup-code-object (code offset fixup kind &optional flavor)
  (declare (type index offset) (ignorable flavor))
  (without-gcing
      (let* ((sap (code-instructions code))
             (fixup (+ (if (eq kind :absolute64)
                           (signed-sap-ref-64 sap offset)
                           (signed-sap-ref-32 sap offset))
                       fixup)))
      (ecase kind
        (:absolute64
         ;; Word at sap + offset contains a value to be replaced by
         ;; adding that value to fixup.
         (setf (sap-ref-64 sap offset) fixup))
        (:absolute
         ;; Word at sap + offset contains a value to be replaced by
         ;; adding that value to fixup.
         (setf (sap-ref-32 sap offset) fixup))
        (:relative
         ;; Fixup is the actual address wanted.
         ;; Replace word with value to add to that loc to get there.
         ;; In the #!-immobile-code case, there's nothing to assert.
         ;; Relative fixups pretty much can't happen.
         #!+immobile-code
         (unless (immobile-space-obj-p code)
           (error "Can't compute fixup relative to movable object ~S" code))
         (setf (signed-sap-ref-32 sap offset)
               (etypecase fixup
                 (integer
                  ;; JMP/CALL are relative to the next instruction,
                  ;; so add 4 bytes for the size of the displacement itself.
                  (- fixup
                     (the (unsigned-byte 64) (+ (sap-int sap) offset 4))))))))))
  ;; An absolute fixup is stored in the code header's %FIXUPS slot if it
  ;; references an immobile-space (but not static-space) object.
  ;; This needn't be inside WITHOUT-GCING, because code fixups will point
  ;; only to objects that don't move except during save-lisp-and-die.
  ;; So there is no race with GC here.
  ;; Note that:
  ;;  (1) Call fixups occur in both :RELATIVE and :ABSOLUTE kinds.
  ;;      We can ignore the :RELATIVE kind.
  ;;  (2) :STATIC-CALL fixups point to immobile space, not static space.
  #!+immobile-space
  (when (and (eq kind :absolute)
             (member flavor '(:named-call :layout :immobile-object ; -> fixedobj subspace
                              :assembly-routine :static-call))) ; -> varyobj subspace
    (let ((fixups (%code-fixups code)))
      ;; Sanctifying the code component will compact these into a bignum.
      (setf (%code-fixups code) (cons offset (if (eql fixups 0) nil fixups)))))
  nil)

#!+immobile-space
(defun sanctify-for-execution (code)
  (let ((fixups (%code-fixups code)))
    (when (listp fixups)
      (setf (%code-fixups code) (sb!c::pack-code-fixup-locs fixups))))
  nil)

#!+(or darwin linux win32)
(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* unsigned) (context (* os-context-t)) (index int))

;;; This is like CONTEXT-REGISTER, but returns the value of a float
;;; register. FORMAT is the type of float to return.

(defun context-float-register (context index format)
  (declare (ignorable context index))
  #!-(or darwin linux win32)
  (progn
    (warn "stub CONTEXT-FLOAT-REGISTER")
    (coerce 0 format))
  #!+(or darwin linux win32)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (sap-ref-single sap 0))
      (double-float
       (sap-ref-double sap 0))
      (complex-single-float
       (complex (sap-ref-single sap 0)
                (sap-ref-single sap 4)))
      (complex-double-float
       (complex (sap-ref-double sap 0)
                (sap-ref-double sap 8))))))

(defun %set-context-float-register (context index format value)
  (declare (ignorable context index format))
  #!-(or linux win32)
  (progn
    (warn "stub %SET-CONTEXT-FLOAT-REGISTER")
    value)
  #!+(or linux win32)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (setf (sap-ref-single sap 0) value))
      (double-float
       (setf (sap-ref-double sap 0) value))
      (complex-single-float
       (locally
           (declare (type (complex single-float) value))
         (setf (sap-ref-single sap 0) (realpart value)
               (sap-ref-single sap 4) (imagpart value))))
      (complex-double-float
       (locally
           (declare (type (complex double-float) value))
         (setf (sap-ref-double sap 0) (realpart value)
               (sap-ref-double sap 8) (imagpart value)))))))

;;; Given a signal context, return the floating point modes word in
;;; the same format as returned by FLOATING-POINT-MODES.
#!-linux
(defun context-floating-point-modes (context)
  (declare (ignore context)) ; stub!
  (warn "stub CONTEXT-FLOATING-POINT-MODES")
  0)
#!+linux
(define-alien-routine ("os_context_fp_control" context-floating-point-modes)
    (unsigned 32)
  (context (* os-context-t)))

(define-alien-routine
    ("arch_get_fp_modes" floating-point-modes) (unsigned 32))

(define-alien-routine
    ("arch_set_fp_modes" %floating-point-modes-setter) void (fp (unsigned 32)))

(defun (setf floating-point-modes) (val) (%floating-point-modes-setter val))


;;;; INTERNAL-ERROR-ARGS

;;; Given a (POSIX) signal context, extract the internal error
;;; arguments from the instruction stream.
(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (/show0 "entering INTERNAL-ERROR-ARGS, CONTEXT=..")
  (/hexstr context)
  (let* ((pc (context-pc context))
         (trap-number (sap-ref-8 pc 0)))
    (declare (type system-area-pointer pc))
    (/show0 "got PC")
    ;; using INT3 the pc is .. INT3 <here> code length bytes...
    (if (= trap-number invalid-arg-count-trap)
        (values #.(error-number-or-lose 'invalid-arg-count-error)
                '(#.arg-count-sc))
        (let ((error-number (sap-ref-8 pc 1)))
          (values error-number
                  (sb!kernel::decode-internal-error-args (sap+ pc 2) error-number)
                  trap-number)))))


;;; the current alien stack pointer; saved/restored for non-local exits
(defvar *alien-stack-pointer*)

#!+immobile-code
(progn
(defun fun-immobilize (fun)
  (let ((code (allocate-code-object t 0 16)))
    (setf (%code-debug-info code) fun)
    (let ((sap (code-instructions code))
          (ea (+ (logandc2 (get-lisp-obj-address code) lowtag-mask)
                 (ash code-debug-info-slot word-shift))))
      ;; For a funcallable-instance, the instruction sequence is:
      ;;    MOV RAX, [RIP-n] ; load the function
      ;;    MOV RAX, [RAX+5] ; load the funcallable-instance-fun
      ;;    JMP [RAX-3]
      ;; Otherwise just instructions 1 and 3 will do.
      ;; We could use the #xA1 opcode to save a byte, but that would
      ;; be another headache do deal with when relocating this code.
      ;; There's precedent for this style of hand-assembly,
      ;; in arch_write_linkage_table_jmp() and arch_do_displaced_inst().
      (setf (sap-ref-32 sap 0) #x058B48 ; REX MOV [RIP-n]
            (signed-sap-ref-32 sap 3) (- ea (+ (sap-int sap) 7))) ; disp
      (let ((i (if (/= (fun-subtype fun) funcallable-instance-widetag)
                   7
                   (let ((disp8 (- (ash funcallable-instance-function-slot
                                        word-shift)
                                   fun-pointer-lowtag))) ; = 5
                     (setf (sap-ref-32 sap 7) (logior (ash disp8 24) #x408B48))
                     11))))
        (setf (sap-ref-32 sap i) #xFD60FF))) ; JMP [RAX-3]
    code))

;;; Return T if FUN can't be called without loading RAX with its descriptor.
;;; This is true of any funcallable instance which is not a GF, and closures.
(defun fun-requires-simplifying-trampoline-p (fun)
  (cond ((not (immobile-space-obj-p fun)) t) ; always
        ((funcallable-instance-p fun)
         ;; A funcallable-instance with no raw slots has no machine
         ;; code within it, and thus requires an external trampoline.
         (eql (layout-bitmap (%funcallable-instance-layout fun))
              sb!kernel::+layout-all-tagged+))
        (t
         (closurep fun))))

(defun %set-fin-trampoline (fin)
  (let ((sap (int-sap (- (get-lisp-obj-address fin) fun-pointer-lowtag)))
        (insts-offs (ash (1+ funcallable-instance-info-offset) word-shift)))
    (setf (sap-ref-word sap insts-offs) #xFFFFFFE9058B48 ; MOV RAX,[RIP-23]
          (sap-ref-32 sap (+ insts-offs 7)) #x00FD60FF)) ; JMP [RAX-3]
  fin)

(defun %set-fdefn-fun (fdefn fun)
  (declare (type fdefn fdefn) (type function fun)
           (values function))
  (unless (eql (sb!vm::fdefn-has-static-callers fdefn) 0)
    (sb!vm::remove-static-links fdefn))
  (let ((trampoline (when (fun-requires-simplifying-trampoline-p fun)
                      (fun-immobilize fun)))) ; a newly made CODE object
    (with-pinned-objects (fdefn trampoline fun)
      (binding* (((fun-entry-addr nop-byte)
                  ;; The NOP-BYTE is an arbitrary value used to indicate the
                  ;; kind of callee in the FDEFN-RAW-ADDR slot.
                  ;; Though it should never be executed, it is a valid encoding.
                  (if trampoline
                      (values (sap-int (code-instructions trampoline)) #x90)
                      (values (sap-ref-word (int-sap (get-lisp-obj-address fun))
                                            (- (ash simple-fun-self-slot word-shift)
                                               fun-pointer-lowtag))
                              (if (simple-fun-p fun) 0 #x48))))
                 (fdefn-addr (- (get-lisp-obj-address fdefn) ; base of the object
                                other-pointer-lowtag))
                 (fdefn-entry-addr (+ fdefn-addr ; address that callers jump to
                                      (ash fdefn-raw-addr-slot word-shift)))
                 (displacement (the (signed-byte 32)
                                 (- fun-entry-addr (+ fdefn-entry-addr 5)))))
        (setf (sap-ref-word (int-sap fdefn-entry-addr) 0)
              (logior #xE9
                      ;; Allow negative displacement
                      (ash (ldb (byte 32 0) displacement) 8) ; JMP opcode
                      (ash nop-byte 40))
              (sap-ref-lispobj (int-sap fdefn-addr) (ash fdefn-fun-slot word-shift))
              fun)))))
) ; end PROGN

;;; Find an immobile FDEFN or FUNCTION given an interior pointer to it.
#!+immobile-space
(defun find-called-object (address)
  ;; The ADDRESS [sic] is actually any immediate operand to MOV,
  ;; which in general decodes as a *signed* integer. So ignore negative values.
  (let ((obj (if (typep address 'sb!ext:word)
                 (alien-funcall (extern-alien "search_all_gc_spaces"
                                              (function unsigned unsigned))
                                address)
                 0)))
      (unless (eql obj 0)
        (case (sap-ref-8 (int-sap obj) 0)
         (#.fdefn-widetag
          (make-lisp-obj (logior obj other-pointer-lowtag)))
         (#.funcallable-instance-widetag
          (make-lisp-obj (logior obj fun-pointer-lowtag)))
         (#.code-header-widetag
          (let ((code (make-lisp-obj (logior obj other-pointer-lowtag))))
            (dotimes (i (code-n-entries code))
              (let ((f (%code-entry-point code i)))
                (if (= (+ (get-lisp-obj-address f)
                          (ash simple-fun-code-offset word-shift)
                          (- fun-pointer-lowtag))
                       address)
                    (return f))))))))))

;;; Compute the PC that FDEFN will jump to when called.
#!+immobile-code
(defun fdefn-call-target (fdefn)
  (let ((pc (+ (get-lisp-obj-address fdefn)
               (- other-pointer-lowtag)
               (ash fdefn-raw-addr-slot word-shift))))
    (+ pc 5 (signed-sap-ref-32 (int-sap pc) 1)))) ; 5 = length of JMP
