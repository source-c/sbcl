;;;; target-only code that knows how to load compiled code directly
;;;; into core
;;;;
;;;; FIXME: The filename here is confusing because "core" here means
;;;; "main memory", while elsewhere in the system it connotes a
;;;; ".core" file dumping the contents of main memory.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!C")

(declaim (ftype (sfunction (#!+immobile-code boolean fixnum fixnum)
                           code-component) allocate-code-object))
(defun allocate-code-object (#!+immobile-code immobile-p boxed unboxed)
  #!+gencgc
  (without-gcing
   (if (or #!+immobile-code immobile-p)
       #!+immobile-code (sb!vm::allocate-immobile-code boxed unboxed)
       #!-immobile-code nil
       (%make-lisp-obj
        (alien-funcall (extern-alien "alloc_code_object"
                                     (function unsigned unsigned unsigned))
                       boxed unboxed))))
  #!-gencgc
  (%primitive allocate-code-object boxed unboxed))

;; OFFSET is in bytes from the start of the code component's raw bytes
(defun new-simple-fun (code fun-index offset nfuns)
  (declare (type (unsigned-byte 27) fun-index)
           (type index offset)
           (type (unsigned-byte 14) nfuns))
  (unless (zerop (logand offset sb!vm:lowtag-mask))
    (bug "unaligned function object, offset = #X~X" offset))
  (let ((header-data (get-header-data code)))
    (if (> fun-index 0)
        (let* ((n-header-words (logand header-data sb!vm:short-header-max-words))
               (index (+ (- sb!vm:other-pointer-lowtag)
                         (ash n-header-words sb!vm:word-shift)
                         (ash (1- fun-index) 2))))
          (aver (eql (sap-ref-32 (int-sap (get-lisp-obj-address code)) index) 0))
          (setf (sap-ref-32 (int-sap (get-lisp-obj-address code)) index) offset))
        ;; Special case for the first simple-fun:
        ;; The value range of 'offset' and 'nfuns' is the same
        ;; regardless of word size.
        ;; It's as if it's a positive 32-bit fixnum (29 significant bits).
        ;; 16 bits is enough for the offset because it only needs to
        ;; skip over the unboxed constants.
        #!-64-bit
        (let ((newval (logior (ash (the (mod #x8000) offset) 14) nfuns)))
          (aver (eql (sb!vm::%code-n-entries code) 0))
          (setf (sb!vm::%code-n-entries code) newval))
        #!+64-bit
        (let ((newval (logior (ash (the (mod #x8000) offset) 16) nfuns)))
          (aver (eql (ldb (byte 32 24) header-data) 0))
          (set-header-data code (dpb newval (byte 32 24) header-data)))))
  (let ((fun (%primitive sb!c:compute-fun code offset)))
    (setf (%simple-fun-self fun) fun)
    fun))

;;; Make a function entry, filling in slots from the ENTRY-INFO.
(defun make-fun-entry (fun-index entry-info code-obj object nfuns)
  (declare (type entry-info entry-info) (type core-object object))
  (let ((res (new-simple-fun code-obj fun-index
                             (label-position (entry-info-offset entry-info))
                             nfuns)))
    (setf (%simple-fun-name res) (entry-info-name entry-info))
    (setf (%simple-fun-arglist res) (entry-info-arguments entry-info))
    (setf (%simple-fun-type res) (entry-info-type entry-info))
    (setf (%simple-fun-info res) (entry-info-info entry-info))
    (note-fun entry-info res object)))

;;; Dump a component to core. We pass in the assembler fixups, code
;;; vector and node info.
(defun make-core-component (component segment length fixup-notes object)
  (declare (type component component)
           (type segment segment)
           (type index length)
           (list fixup-notes)
           (type core-object object))
  (let ((debug-info (debug-info-for-component component)))
    ;; FIXME: use WITHOUT-GCING only for stuff that needs it.
    ;; Most likely this could be WITH-PINNED-OBJECTS.
    ;; See also the remark in LOAD-CODE about the order of installing
    ;; simple-funs and setting the 'nfuns' value.
    (without-gcing
      (let* ((2comp (component-info component))
             (constants (ir2-component-constants 2comp))
             (box-num (- (length constants) sb!vm:code-constants-offset))
             (code-obj (allocate-code-object
                        #!+immobile-code (eq *compile-to-memory-space* :immobile)
                        box-num length)))
        (declare (type index box-num length))

         (copy-byte-vector-to-system-area
          (the (simple-array assembly-unit 1) (segment-contents-as-vector segment))
          (code-instructions code-obj))

        (do-core-fixups code-obj fixup-notes)

        (let* ((entries (ir2-component-entries 2comp))
               (nfuns (length entries))
               (fun-index nfuns))
          (dolist (entry entries)
            (make-fun-entry (decf fun-index) entry code-obj object nfuns)))

        #!-(or x86 x86-64)
        (sb!vm:sanctify-for-execution code-obj)

        (push debug-info (core-object-debug-info object))
        (setf (%code-debug-info code-obj) debug-info)

        (do ((index sb!vm:code-constants-offset (1+ index)))
            ((>= index (length constants)))
          (let ((const (aref constants index)))
            (etypecase const
              (null)
              (constant
               (setf (code-header-ref code-obj index)
                     (constant-value const)))
              (list
               (ecase (car const)
                 (:entry
                  (reference-core-fun code-obj index (cdr const) object))
                 (:fdefinition
                  (setf (code-header-ref code-obj index)
                        (find-or-create-fdefn (cdr const))))
                 (:known-fun
                  (setf (code-header-ref code-obj index)
                        (%coerce-name-to-fun (cdr const))))))))))))
  (values))
