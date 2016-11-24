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
        (alien-funcall (extern-alien "alloc_code_object" (function unsigned unsigned unsigned))
                       boxed unboxed))))
  #!-gencgc
  (%primitive allocate-code-object boxed unboxed))

;;; Make a function entry, filling in slots from the ENTRY-INFO.
(defun make-fun-entry (entry-info code-obj object)
  (declare (type entry-info entry-info) (type core-object object))
  (let ((offset (label-position (entry-info-offset entry-info))))
    (declare (type index offset))
    (unless (zerop (logand offset sb!vm:lowtag-mask))
      (error "Unaligned function object, offset = #X~X." offset))
    (let ((res (%primitive compute-fun code-obj offset)))
      (setf (%simple-fun-self res) res)
      (setf (%simple-fun-next res) (%code-entry-points code-obj))
      (setf (%code-entry-points code-obj) res)
      (setf (%simple-fun-name res) (entry-info-name entry-info))
      (setf (%simple-fun-arglist res) (entry-info-arguments entry-info))
      (setf (%simple-fun-type res) (entry-info-type entry-info))
      (setf (%simple-fun-info res) (entry-info-info entry-info))

      (note-fun entry-info res object))))

;;; Dump a component to core. We pass in the assembler fixups, code
;;; vector and node info.
(defun make-core-component (component segment length fixup-notes object)
  (declare (type component component)
           (type sb!assem:segment segment)
           (type index length)
           (list fixup-notes)
           (type core-object object))
  (let ((debug-info (debug-info-for-component component)))
    ;; FIXME: use WITHOUT-GCING only for stuff that needs it.
    (without-gcing
      (let* ((2comp (component-info component))
             (constants (ir2-component-constants 2comp))
             (box-num (- (length constants) sb!vm:code-constants-offset))
             (code-obj (allocate-code-object
                        #!+immobile-code (eq *compile-to-memory-space* :immobile)
                        box-num length))
             (fill-ptr (code-instructions code-obj)))
        (declare (type index box-num length))

        (let ((v (sb!assem:segment-contents-as-vector segment)))
          (declare (type (simple-array sb!assem:assembly-unit 1) v))
          (copy-byte-vector-to-system-area v fill-ptr)
          (setf fill-ptr (sap+ fill-ptr (length v))))

        (do-core-fixups code-obj fixup-notes)

        (dolist (entry (ir2-component-entries 2comp))
          (make-fun-entry entry code-obj object))

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
