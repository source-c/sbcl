;;;; machine-independent disassembler

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!DISASSEM")

;;; types and defaults

(defconstant label-column-width 7)

(deftype text-width () '(integer 0 1000))
(deftype alignment () '(integer 0 64))
(deftype offset () 'fixnum)
(deftype address () 'word)
(deftype disassem-length () '(and unsigned-byte fixnum))
(deftype column () '(integer 0 1000))

(defconstant max-filtered-value-index 32)
(deftype filtered-value-index ()
  `(integer 0 (,max-filtered-value-index)))
(deftype filtered-value-vector ()
  `(simple-array t (,max-filtered-value-index)))

;;;; disassembly parameters

;; With a few tweaks, you can use a running SBCL as a cross-assembler
;; and disassembler for other supported backends,
;; if that backend has been converted to use a distinct ASM package.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter sb!assem::*backend-instruction-set-package*
    (find-package #.(sb-cold::backend-asm-package-name))))

(defvar *disassem-inst-space* nil)

;;; minimum alignment of instructions, in bytes
(defvar *disassem-inst-alignment-bytes* sb!vm:n-word-bytes)
(declaim (type alignment *disassem-inst-alignment-bytes*))

;; How many columns of output to allow for the address preceding each line.
;; If NIL, use the minimum possible width for the disassembly range.
;; If 0, do not print addresses.
(defvar *disassem-location-column-width* nil)
(declaim (type (or null text-width) *disassem-location-column-width*))

;;; the width of the column in which instruction-names are printed. A
;;; value of zero gives the effect of not aligning the arguments at
;;; all.
(defvar *disassem-opcode-column-width* 0)
(declaim (type text-width *disassem-opcode-column-width*))

;;; the width of the column in which instruction-bytes are printed. A
;;; value of zero disables the printing of instruction bytes.
(defvar *disassem-inst-column-width* 16
  "The width of instruction bytes.")
(declaim (type text-width *disassem-inst-column-width*))

(defvar *disassem-note-column* (+ 45 *disassem-inst-column-width*)
  "The column in which end-of-line comments for notes are started.")

;;;; A DCHUNK contains the bits we look at to decode an
;;;; instruction.
;;;; I tried to keep this abstract so that if using integers > the machine
;;;; word size conses too much, it can be changed to use bit-vectors or
;;;; something.
;;;;
;;;; KLUDGE: It's not clear that using bit-vectors would be any more efficient.
;;;; Perhaps the abstraction could go away. -- WHN 19991124

#!-sb-fluid
(declaim (inline dchunk-or dchunk-and dchunk-clear dchunk-not
                 dchunk-make-mask dchunk-make-field
                 dchunk-extract
                 dchunk=
                 dchunk-count-bits))

;;; For variable-length instruction sets, such as x86, it is better to
;;; define the dchunk size to be the smallest number of bits necessary
;;; and sufficient to decode any instruction format, if that quantity
;;; of bits is small enough to avoid bignum consing.
;;; Ideally this constant would go in the 'insts' file for the architecture,
;;; but there's really no easy way to do that at present.
(defconstant dchunk-bits
  #!+x86-64 56
  #!-x86-64 sb!vm:n-word-bits)

(deftype dchunk ()
  `(unsigned-byte ,dchunk-bits))
(deftype dchunk-index ()
  `(integer 0 ,dchunk-bits))

(defconstant dchunk-zero 0)
(defconstant dchunk-one (ldb (byte dchunk-bits 0) -1))

(defun dchunk-extract (chunk byte-spec)
  (declare (type dchunk chunk))
  (the dchunk (ldb byte-spec (the dchunk chunk))))

(defmacro dchunk-copy (x)
  `(the dchunk ,x))

(defun dchunk-or (to from)
  (declare (type dchunk to from))
  (the dchunk (logior to from)))
(defun dchunk-and (to from)
  (declare (type dchunk to from))
  (the dchunk (logand to from)))
(defun dchunk-clear (to from)
  (declare (type dchunk to from))
  (the dchunk (logandc2 to from)))
(defun dchunk-not (from)
  (declare (type dchunk from))
  (the dchunk (logand dchunk-one (lognot from))))

(defmacro dchunk-andf (to from)
  `(setf ,to (dchunk-and ,to ,from)))
(defmacro dchunk-orf (to from)
  `(setf ,to (dchunk-or ,to ,from)))
(defmacro dchunk-clearf (to from)
  `(setf ,to (dchunk-clear ,to ,from)))

(defun dchunk-make-mask (pos)
  (the dchunk (mask-field pos -1)))
(defun dchunk-make-field (pos value)
  (the dchunk (dpb value pos 0)))

(defmacro make-dchunk (value)
  `(the dchunk ,value))

(defun dchunk-corrected-extract (from pos unit-bits byte-order)
  (declare (type dchunk from))
  (if (eq byte-order :big-endian)
      (ldb (byte (byte-size pos)
                 (+ (byte-position pos) (- dchunk-bits unit-bits)))
           (the dchunk from))
      (ldb pos (the dchunk from))))

(defmacro dchunk-insertf (place pos value)
  `(setf ,place (the dchunk (dpb ,value ,pos (the dchunk,place)))))

(defun dchunk= (x y)
  (declare (type dchunk x y))
  (= x y))
(defmacro dchunk-zerop (x)
  `(dchunk= ,x dchunk-zero))

(defun dchunk-strict-superset-p (sup sub)
  (and (zerop (logandc2 sub sup))
       (not (zerop (logandc2 sup sub)))))

(defun dchunk-count-bits (x)
  (declare (type dchunk x))
  (logcount x))

(defstruct (instruction (:conc-name inst-)
                        (:constructor
                         make-instruction (name format-name print-name
                                           length mask id printer labeller
                                           prefilters control))
                        (:copier nil))
  (name nil :type (or symbol string) :read-only t)
  (format-name nil :type (or symbol string) :read-only t)

  (mask dchunk-zero :type dchunk :read-only t)   ; bits in the inst that are constant
  (id dchunk-zero :type dchunk :read-only t)     ; value of those constant bits

  (length 0 :type disassem-length :read-only t)  ; in bytes

  (print-name nil :type symbol :read-only t)

  ;; disassembly "functions"
  (prefilters nil :type list :read-only t)
  (labeller nil :type (or list vector) :read-only t)
  (printer nil :type (or null function) :read-only t)
  (control nil :type (or null function) :read-only t)

  ;; instructions that are the same as this instruction but with more
  ;; constraints
  (specializers nil :type list))
(defmethod print-object ((inst instruction) stream)
  (print-unreadable-object (inst stream :type t :identity t)
    (format stream "~A(~A)" (inst-name inst) (inst-format-name inst))))

;;;; an instruction space holds all known machine instructions in a
;;;; form that can be easily searched

(defstruct (inst-space (:conc-name ispace-)
                       (:copier nil))
  (valid-mask dchunk-zero :type dchunk) ; applies to *children*
  (choices nil :type list))
(defmethod print-object ((ispace inst-space) stream)
  (print-unreadable-object (ispace stream :type t :identity t)))

;;; now that we've defined the structure, we can declaim the type of
;;; the variable:
(declaim (type (or null inst-space) *disassem-inst-space*))

(defstruct (inst-space-choice (:conc-name ischoice-)
                              (:copier nil))
  (common-id dchunk-zero :type dchunk)  ; applies to *parent's* mask
  (subspace (missing-arg) :type (or inst-space instruction)))

(defstruct (arg (:constructor %make-arg (name))
                (:copier nil)
                (:predicate nil))
  (name nil :type symbol)
  (fields nil :type list)

  (value nil :type (or list integer))
  (sign-extend-p nil :type boolean)

  ;; functions to use
  (printer nil :type (or null function vector))
  (prefilter nil :type (or null function))
  (use-label nil :type (or boolean function)))

(defstruct (instruction-format (:conc-name format-)
                               (:constructor make-inst-format
                                             (name length default-printer args))
                               (:copier nil))
  (name nil)
  (args nil :type list)

  (length 0 :type disassem-length)               ; in bytes

  (default-printer nil :type list))

;;; A FUNSTATE holds the state of any arguments used in a disassembly
;;; function. It is a 2-level alist. The outer list maps each ARG to
;;; a list of styles in which that arg can be rendered.
;;; Each rendering is named by a keyword (the key to the inner alist),
;;; and is represented as a list of temp vars and values for them.
(defun make-funstate (args) (mapcar #'list args))

(defun arg-position (arg funstate)
  ;;; The THE form is to assert that ARG is found.
  (the filtered-value-index (position arg funstate :key #'car)))

(defun arg-or-lose (name funstate)
  (or (car (assoc name funstate :key #'arg-name :test #'eq))
      (pd-error "unknown argument ~S" name)))

;;; machinery to provide more meaningful error messages during compilation
(defvar *current-instruction-flavor*)
(defun pd-error (fmt &rest args)
  (if (boundp '*current-instruction-flavor*)
      (error "~{A printer ~D~}: ~?" *current-instruction-flavor* fmt args)
      (apply #'error fmt args)))

(defun format-or-lose (name)
  (or (get name 'inst-format)
      (pd-error "unknown instruction format ~S" name)))

;;; Return a modified copy of ARG that has property values changed
;;; depending on whether it is being used at compile-time or load-time.
;;; This is to avoid evaluating #'FOO references at compile-time
;;; while allowing compile-time manipulation of byte specifiers.
(defun massage-arg (spec when)
  (ecase when
    (:compile
     ;; At compile-time we get a restricted view of the DEFINE-ARG-TYPE args,
     ;; just enough to macroexpand :READER definitions. :TYPE and ::SIGN-EXTEND
     ;; are as specified, but :PREFILTER, :LABELLER, and :PRINTER are not
     ;; compile-time evaluated.
     (loop for (indicator val) on (cdr spec) by #'cddr
           nconc (case indicator
                   (:sign-extend ; Only a literal T or NIL is allowed
                    (list indicator (the boolean val)))
                   (:prefilter
                    ;; #'ERROR is a placeholder for any compile-time non-nil
                    ;; value. If nil, it must be literally nil, not 'NIL.
                    (list indicator (if val #'error nil)))
                   ((:field :fields :type)
                    (list indicator val)))))
    (:eval
     (loop for (indicator raw-val) on (cdr spec) by #'cddr
           ;; Use NAMED-LAMBDAs to enhance debuggability,
           for val = (if (typep raw-val '(cons (eql lambda)))
                         `(named-lambda ,(format nil "~A.~A" (car spec) indicator)
                                        ,@(cdr raw-val))
                         raw-val)
           nconc (case indicator
                   (:reader nil) ; drop it
                   (:prefilter ; Enforce compile-time-determined not-nullness.
                    (list indicator (if val `(the (not null) ,val) nil)))
                   (t (list indicator val)))))))

(defmacro define-instruction-format ((format-name length-in-bits
                                      &key default-printer include)
                                     &rest arg-specs)
  #+sb-xc-host (declare (ignore default-printer))
  "DEFINE-INSTRUCTION-FORMAT (Name Length {Format-Key Value}*) Arg-Def*
  Define an instruction format NAME for the disassembler's use. LENGTH is
  the length of the format in bits.
  Possible FORMAT-KEYs:

  :INCLUDE other-format-name
      Inherit all arguments and properties of the given format. Any
      arguments defined in the current format definition will either modify
      the copy of an existing argument (keeping in the same order with
      respect to when prefilters are called), if it has the same name as
      one, or be added to the end.
  :DEFAULT-PRINTER printer-list
      Use the given PRINTER-LIST as a format to print any instructions of
      this format when they don't specify something else.

  Each ARG-DEF defines one argument in the format, and is of the form
    (Arg-Name {Arg-Key Value}*)

  Possible ARG-KEYs (the values are evaluated unless otherwise specified):

  :FIELDS byte-spec-list
      The argument takes values from these fields in the instruction. If
      the list is of length one, then the corresponding value is supplied by
      itself; otherwise it is a list of the values. The list may be NIL.
  :FIELD byte-spec
      The same as :FIELDS (list byte-spec).

  :VALUE value
      If the argument only has one field, this is the value it should have,
      otherwise it's a list of the values of the individual fields. This can
      be overridden in an instruction-definition or a format definition
      including this one by specifying another, or NIL to indicate that it's
      variable.

  :SIGN-EXTEND boolean
      If non-NIL, the raw value of this argument is sign-extended,
      immediately after being extracted from the instruction (before any
      prefilters are run, for instance). If the argument has multiple
      fields, they are all sign-extended.

  :TYPE arg-type-name
      Inherit any properties of the given argument type.

  :PREFILTER function
      A function which is called (along with all other prefilters, in the
      order that their arguments appear in the instruction-format) before
      any printing is done, to filter the raw value. Any uses of READ-SUFFIX
      must be done inside a prefilter.

  :PRINTER function-string-or-vector
      A function, string, or vector which is used to print this argument.

  :USE-LABEL
      If non-NIL, the value of this argument is used as an address, and if
      that address occurs inside the disassembled code, it is replaced by a
      label. If this is a function, it is called to filter the value."
  `(progn
     (eval-when (:compile-toplevel)
       (%def-inst-format
        ',format-name ',include ,length-in-bits nil
        ,@(mapcar (lambda (arg) `(list ',(car arg) ,@(massage-arg arg :compile)))
                  arg-specs)))
     ,@(mapcan
        (lambda (arg-spec)
          (awhen (getf (cdr arg-spec) :reader)
            `((defun ,it (dchunk dstate)
                (declare (ignorable dchunk dstate))
                (flet ((local-filtered-value (offset)
                         (declare (type filtered-value-index offset))
                         (aref (dstate-filtered-values dstate) offset))
                       (local-extract (bytespec)
                         (dchunk-extract dchunk bytespec)))
                  (declare (ignorable #'local-filtered-value #'local-extract)
                           (inline local-filtered-value local-extract))
                  ;; Delay ARG-FORM-VALUE call until after compile-time-too
                  ;; processing of !%DEF-INSTRUCTION-FORMAT has happened.
                  (macrolet
                      ((reader ()
                         (let* ((format-args
                                 (format-args (format-or-lose ',format-name)))
                                (arg (find ',(car arg-spec) format-args
                                           :key #'arg-name))
                                (funstate (make-funstate format-args))
                                (*!temp-var-counter* 0)
                                (expr (arg-value-form arg funstate :numeric)))
                           `(let* ,(make-arg-temp-bindings funstate) ,expr))))
                    (reader)))))))
        arg-specs)
     #-sb-xc-host ; Host doesn't need the real definition.
     (%def-inst-format
      ',format-name ',include ,length-in-bits ,default-printer
      ,@(mapcar (lambda (arg) `(list ',(car arg) ,@(massage-arg arg :eval)))
                arg-specs))))

(defun %def-inst-format (name inherit length printer &rest arg-specs)
  (let ((args (if inherit (copy-list (format-args (format-or-lose inherit)))))
        (seen))
    (dolist (arg-spec arg-specs)
      (let* ((arg-name (car arg-spec))
             (properties (cdr arg-spec))
             (cell (member arg-name args :key #'arg-name)))
        (aver (not (memq arg-name seen)))
        (push arg-name seen)
        (cond ((not cell)
               (setq args (nconc args (list (apply #'modify-arg (%make-arg arg-name)
                                                   length properties)))))
              (properties
               (rplaca cell (apply #'modify-arg (copy-structure (car cell))
                                   length properties))))))
    (setf (get name 'inst-format)
          (make-inst-format name (bits-to-bytes length) printer args))))

(defun modify-arg (arg format-length
                   &key   (value nil value-p)
                          (type nil type-p)
                          (prefilter nil prefilter-p)
                          (printer nil printer-p)
                          (sign-extend nil sign-extend-p)
                          (use-label nil use-label-p)
                          (field nil field-p)
                          (fields nil fields-p))
  (when field-p
    (if fields-p
        (error ":FIELD and :FIELDS are mutually exclusive")
        (setf fields (list field) fields-p t)))
  (when type-p
    (let ((type-arg (or (get type 'arg-type)
                        (pd-error "unknown argument type: ~S" type))))
      (setf (arg-printer arg) (arg-printer type-arg))
      (setf (arg-prefilter arg) (arg-prefilter type-arg))
      (setf (arg-sign-extend-p arg) (arg-sign-extend-p type-arg))
      (setf (arg-use-label arg) (arg-use-label type-arg))))
  (when value-p
    (setf (arg-value arg) value))
  (when prefilter-p
    (setf (arg-prefilter arg) prefilter))
  (when sign-extend-p
    (setf (arg-sign-extend-p arg) sign-extend))
  (when printer-p
    (setf (arg-printer arg) printer))
  (when use-label-p
    (setf (arg-use-label arg) use-label))
  (when fields-p
    (setf (arg-fields arg)
          (mapcar (lambda (bytespec)
                    (when (> (+ (byte-position bytespec) (byte-size bytespec))
                             format-length)
                      (error "~@<in arg ~S: ~3I~:_~
                                   The field ~S doesn't fit in an ~
                                   instruction-format ~W bits wide.~:>"
                             (arg-name arg) bytespec format-length))
                    (correct-dchunk-bytespec-for-endianness
                     bytespec format-length sb!c:*backend-byte-order*))
                  fields)))
  arg)

(defun arg-value-form (arg funstate
                       &optional
                       (rendering :final)
                       (allow-multiple-p (neq rendering :numeric)))
  (let ((forms (gen-arg-forms arg rendering funstate)))
    (when (and (not allow-multiple-p)
               (listp forms)
               (/= (length forms) 1))
      (pd-error "~S must not have multiple values." arg))
    (maybe-listify forms)))

(defun correct-dchunk-bytespec-for-endianness (bs unit-bits byte-order)
  (if (eq byte-order :big-endian)
      (byte (byte-size bs) (+ (byte-position bs) (- dchunk-bits unit-bits)))
      bs))

(defun make-arg-temp-bindings (funstate)
  (let ((bindings nil))
    ;; Prefilters have to be called in the correct order, so reverse FUNSTATE
    ;; because we're using PUSH in the inner loop.
    (dolist (arg-cell (reverse funstate) bindings)
      ;; These sublists are "backwards", so PUSH ends up being correct.
      (dolist (rendering (cdr arg-cell))
        (let* ((binding (cdr rendering))
               (vars (car binding))
               (vals (cdr binding)))
          (if (listp vars)
              (mapc (lambda (var val) (push `(,var ,val) bindings)) vars vals)
              (push `(,vars ,vals) bindings)))))))

;;; Return the form(s) that should be evaluated to render ARG in the chosen
;;; RENDERING style, which is one of :RAW, :SIGN-EXTENDED,
;;; :FILTERED, :NUMERIC, and :FINAL. Each rendering depends on the preceding
;;; one, so asking for :FINAL will implicitly compute all renderings.
(defvar *!temp-var-counter*)
(defun gen-arg-forms (arg rendering funstate)
  (labels ((tempvars (n)
             (if (plusp n)
                 (cons (package-symbolicate
                        (load-time-value (find-package "SB!DISASSEM"))
                        ".T" (write-to-string (incf *!temp-var-counter*)))
                       (tempvars (1- n))))))
    (let* ((arg-cell (assq arg funstate))
           (rendering-temps (cdr (assq rendering (cdr arg-cell))))
           (vars (car rendering-temps))
           (forms (cdr rendering-temps)))
      (unless forms
        (multiple-value-bind (new-forms single-value-p)
            (%gen-arg-forms arg rendering funstate)
          (setq forms new-forms
                vars (cond ((or single-value-p (atom forms))
                            (if (symbolp forms) vars (car (tempvars 1))))
                           ((every #'symbolp forms)
                            ;; just use the same as the forms
                            nil)
                           (t
                            (tempvars (length forms)))))
          (push (list* rendering vars forms) (cdr arg-cell))))
      (or vars forms))))

(defun maybe-listify (forms)
  (cond ((atom forms)
         forms)
        ((/= (length forms) 1)
         `(list ,@forms))
        (t
         (car forms))))

;;; DEFINE-ARG-TYPE Name {Key Value}*
;;;
;;; Define a disassembler argument type NAME (which can then be referenced in
;;; another argument definition using the :TYPE argument). &KEY args are:
;;;
;;;  :SIGN-EXTEND boolean
;;;     If non-NIL, the raw value of this argument is sign-extended.
;;;
;;;  :TYPE arg-type-name
;;;     Inherit any properties of given arg-type.
;;;
;;; :PREFILTER function
;;;     A function which is called (along with all other prefilters,
;;;     in the order that their arguments appear in the instruction-
;;;     format) before any printing is done, to filter the raw value.
;;;     Any uses of READ-SUFFIX must be done inside a prefilter.
;;;
;;; :PRINTER function-string-or-vector
;;;     A function, string, or vector which is used to print an argument of
;;;     this type.
;;;
;;; :USE-LABEL
;;;     If non-NIL, the value of an argument of this type is used as
;;;     an address, and if that address occurs inside the disassembled
;;;     code, it is replaced by a label. If this is a function, it is
;;;     called to filter the value.
(defmacro define-arg-type (name &rest args
                           &key ((:type inherit))
                                sign-extend prefilter printer use-label)
  (declare (ignore sign-extend prefilter printer use-label))
  ;; FIXME: this should be an *unevaluated* macro arg (named :INHERIT)
  (aver (typep inherit '(or null (cons (eql quote) (cons symbol null)))))
  (let ((pair (cons name (loop for (ind val) on args by #'cddr
                               unless (eq ind :type)
                               nconc (list ind val)))))
    `(progn
       (eval-when (:compile-toplevel)
         (%def-arg-type ',name ,inherit ,@(massage-arg pair :compile)))
       #-sb-xc-host ; Host doesn't need the real definition.
       (%def-arg-type ',name ,inherit ,@(massage-arg pair :eval)))))

(defun %def-arg-type (name inherit &rest properties)
  (setf (get name 'arg-type)
        (apply 'modify-arg (%make-arg name) nil
               (nconc (when inherit (list :type inherit)) properties))))

(defun %gen-arg-forms (arg rendering funstate)
  (declare (type arg arg) (type list funstate))
  (ecase rendering
    (:raw ; just extract the bits
     (mapcar (lambda (bytespec)
               `(the (unsigned-byte ,(byte-size bytespec))
                     (local-extract ',bytespec)))
             (arg-fields arg)))
    (:sign-extended ; sign-extend, or not
     (let ((raw-forms (gen-arg-forms arg :raw funstate)))
       (if (and (arg-sign-extend-p arg) (listp raw-forms))
           (mapcar (lambda (form field)
                     `(the (signed-byte ,(byte-size field))
                           (sign-extend ,form ,(byte-size field))))
                   raw-forms
                   (arg-fields arg))
           raw-forms)))
    (:filtered ; extract from the prefiltered value vector
     (let ((pf (arg-prefilter arg)))
       (if pf
           (values `(local-filtered-value ,(arg-position arg funstate)) t)
           (gen-arg-forms arg :sign-extended funstate))))
    (:numeric ; pass the filtered value to the label adjuster, or not
     (let ((filtered-forms (gen-arg-forms arg :filtered funstate))
           (use-label (arg-use-label arg)))
       ;; use-label = T means that the prefiltered value is already an address,
       ;; otherwise non-nil means a function to call, and NIL means not a label.
       ;; So only the middle case needs to call ADJUST-LABEL.
       (if (and use-label (neq use-label t))
           `((adjust-label ,(maybe-listify filtered-forms) ,use-label))
           filtered-forms)))
    (:final ; if arg is not a label, return numeric value, otherwise a string
     (let ((numeric-forms (gen-arg-forms arg :numeric funstate)))
       (if (arg-use-label arg)
           `((lookup-label ,(maybe-listify numeric-forms)))
           numeric-forms)))))

(defun find-printer-fun (printer-source args cache *current-instruction-flavor*)
  (let* ((source (preprocess-printer printer-source args))
         (funstate (make-funstate args))
         (forms (let ((*!temp-var-counter* 0))
                  (compile-printer-list source funstate)))
         (bindings (make-arg-temp-bindings funstate))
         (guts `(let* ,bindings ,@forms))
         (sub-table (assq :printer cache)))
    (or (cdr (assoc guts (cdr sub-table) :test #'equal))
        (let ((template
     '(lambda (chunk inst stream dstate
               &aux (chunk (truly-the dchunk chunk))
                    (inst (truly-the instruction inst))
                    (stream (truly-the stream stream))
                    (dstate (truly-the disassem-state dstate)))
       (macrolet ((local-format-arg (arg fmt)
                    `(funcall (formatter ,fmt) stream ,arg)))
         (flet ((local-tab-to-arg-column ()
                  (tab (dstate-argument-column dstate) stream))
                (local-print-name ()
                  (princ (inst-print-name inst) stream))
                (local-write-char (ch)
                  (write-char ch stream))
                (local-princ (thing)
                  (princ thing stream))
                (local-princ16 (thing)
                  (princ16 thing stream))
                (local-call-arg-printer (arg printer)
                  (funcall printer arg stream dstate))
                (local-call-global-printer (fun)
                  (funcall fun chunk inst stream dstate))
                (local-filtered-value (offset)
                  (declare (type filtered-value-index offset))
                  (aref (dstate-filtered-values dstate) offset))
                (local-extract (bytespec)
                  (dchunk-extract chunk bytespec))
                (lookup-label (lab)
                  (or (gethash lab (dstate-label-hash dstate))
                      lab))
                (adjust-label (val adjust-fun)
                  (funcall adjust-fun val dstate)))
           (declare (ignorable #'local-tab-to-arg-column
                               #'local-print-name
                               #'local-princ #'local-princ16
                               #'local-write-char
                               #'local-call-arg-printer
                               #'local-call-global-printer
                               #'local-extract
                               #'local-filtered-value
                               #'lookup-label #'adjust-label)
                    (inline local-tab-to-arg-column
                            local-princ local-princ16
                            local-call-arg-printer local-call-global-printer
                            local-filtered-value local-extract
                            lookup-label adjust-label))
           :body)))))
          (cdar (push (cons guts (compile nil (subst guts :body template)))
                      (cdr sub-table)))))))

(defun preprocess-test (subj form args)
  (multiple-value-bind (subj test)
      (if (and (consp form) (symbolp (car form)) (not (keywordp (car form))))
          (values (car form) (cdr form))
          (values subj form))
    (let ((key (if (consp test) (car test) test))
          (body (if (consp test) (cdr test) nil)))
      (case key
        (:constant
         (if (null body)
             ;; If no supplied constant values, just any constant is ok,
             ;; just see whether there's some constant value in the arg.
             (not
              (null
               (arg-value
                (or (find subj args :key #'arg-name)
                    (pd-error "unknown argument ~S" subj)))))
             ;; Otherwise, defer to run-time.
             form))
        ((:or :and :not)
         (recons
          form
          subj
          (recons
           test
           key
           (sharing-mapcar
            (lambda (sub-test)
              (preprocess-test subj sub-test args))
            body))))
        (t form)))))

(defun preprocess-conditionals (printer args)
  (if (atom printer)
      printer
      (case (car printer)
        (:unless
         (preprocess-conditionals
          `(:cond ((:not ,(nth 1 printer)) ,@(nthcdr 2 printer)))
          args))
        (:when
         (preprocess-conditionals `(:cond (,(cdr printer))) args))
        (:if
         (preprocess-conditionals
          `(:cond (,(nth 1 printer) ,(nth 2 printer))
                  (t ,(nth 3 printer)))
          args))
        (:cond
         (recons
          printer
          :cond
          (sharing-mapcar
           (lambda (clause)
             (let ((filtered-body
                    (sharing-mapcar
                     (lambda (sub-printer)
                       (preprocess-conditionals sub-printer args))
                     (cdr clause))))
               (recons
                clause
                (preprocess-test (find-first-field-name filtered-body)
                                 (car clause)
                                 args)
                filtered-body)))
           (cdr printer))))
        (quote printer)
        (t
         (sharing-mapcar
          (lambda (sub-printer)
            (preprocess-conditionals sub-printer args))
          printer)))))

;;; Return a version of the disassembly-template PRINTER with
;;; compile-time tests (e.g. :constant without a value), and any
;;; :CHOOSE operators resolved properly for the args ARGS.
;;;
;;; (:CHOOSE Sub*) simply returns the first Sub in which every field
;;; reference refers to a valid arg.
(defun preprocess-printer (printer args)
  (preprocess-conditionals (preprocess-chooses printer args) args))

;;; Return the first non-keyword symbol in a depth-first search of TREE.
(defun find-first-field-name (tree)
  (cond ((null tree)
         nil)
        ((and (symbolp tree) (not (keywordp tree)))
         tree)
        ((atom tree)
         nil)
        ((eq (car tree) 'quote)
         nil)
        (t
         (or (find-first-field-name (car tree))
             (find-first-field-name (cdr tree))))))

(defun preprocess-chooses (printer args)
  (cond ((atom printer)
         printer)
        ((eq (car printer) :choose)
         (pick-printer-choice (cdr printer) args))
        (t
         (sharing-mapcar (lambda (sub) (preprocess-chooses sub args))
                         printer))))

;;;; some simple functions that help avoid consing when we're just
;;;; recursively filtering things that usually don't change

(defun recons (old-cons car cdr)
  "If CAR is eq to the car of OLD-CONS and CDR is eq to the CDR, return
  OLD-CONS, otherwise return (cons CAR CDR)."
  (if (and (eq car (car old-cons)) (eq cdr (cdr old-cons)))
      old-cons
      (cons car cdr)))

(defun sharing-mapcar (fun list)
  (declare (type function fun))
  "A simple (one list arg) mapcar that avoids consing up a new list
  as long as the results of calling FUN on the elements of LIST are
  eq to the original."
  (and list
       (recons list
                     (funcall fun (car list))
                     (sharing-mapcar fun (cdr list)))))

(defun all-arg-refs-relevant-p (printer args)
  (cond ((or (null printer) (keywordp printer) (eq printer t))
         t)
        ((symbolp printer)
         (find printer args :key #'arg-name))
        ((listp printer)
         (every (lambda (x) (all-arg-refs-relevant-p x args))
                printer))
        (t t)))

(defun pick-printer-choice (choices args)
  (dolist (choice choices
           (pd-error "no suitable choice found in ~S" choices))
    (when (all-arg-refs-relevant-p choice args)
      (return choice))))

(defun compile-printer-list (sources funstate)
  (when sources
    (cons (compile-printer-body (car sources) funstate)
          (compile-printer-list (cdr sources) funstate))))

(defun compile-printer-body (source funstate)
  (cond ((null source)
         nil)
        ((eq source :name)
         `(local-print-name))
        ((eq source :tab)
         `(local-tab-to-arg-column))
        ((keywordp source)
         (pd-error "unknown printer element: ~S" source))
        ((symbolp source)
         (compile-print source funstate))
        ((atom source)
         `(local-princ ',source))
        ((eq (car source) :using)
         (unless (or (stringp (cadr source))
                     (and (listp (cadr source))
                          (eq (caadr source) 'function)))
           (pd-error "The first arg to :USING must be a string or #'function."))
         ;; For (:using #'F) to be stuffed in properly, the printer as expressed
         ;; in its DSL would have to compile-time expand into a thing that
         ;; reconstructs it such that #'F forms don't appear inside quoted list
         ;; structure. Lacking the ability to do that, we treat #'F as a bit of
         ;; syntax to be evaluated manually.
         (compile-print (caddr source) funstate
                        (let ((f (cadr source)))
                          (if (typep f '(cons (eql function) (cons symbol null)))
                              (symbol-function (second f))
                              f))))
        ((eq (car source) :plus-integer)
         ;; prints the given field proceed with a + or a -
         (let ((form
                (arg-value-form (arg-or-lose (cadr source) funstate)
                                funstate
                                :numeric)))
           `(progn
              (when (>= ,form 0)
                (local-write-char #\+))
              (local-princ ,form))))
        ((eq (car source) 'quote)
         `(local-princ ,source))
        ((eq (car source) 'function)
         `(local-call-global-printer ,source))
        ((eq (car source) :cond)
         `(cond ,@(mapcar (lambda (clause)
                            `(,(compile-test (find-first-field-name
                                              (cdr clause))
                                             (car clause)
                                             funstate)
                              ,@(compile-printer-list (cdr clause)
                                                      funstate)))
                          (cdr source))))
        ;; :IF, :UNLESS, and :WHEN are replaced by :COND during preprocessing
        (t
         `(progn ,@(compile-printer-list source funstate)))))

(defun compile-print (arg-name funstate &optional printer)
  (let* ((arg (arg-or-lose arg-name funstate))
         (printer (or printer (arg-printer arg))))
    (etypecase printer
      (string
       `(local-format-arg ,(arg-value-form arg funstate) ,printer))
      (vector
       `(local-princ (aref ,printer ,(arg-value-form arg funstate :numeric))))
      ((or function (cons (eql function)))
       `(local-call-arg-printer ,(arg-value-form arg funstate) ,printer))
      (boolean
       `(,(if (arg-use-label arg) 'local-princ16 'local-princ)
         ,(arg-value-form arg funstate))))))

(defun compare-fields-form (val-form-1 val-form-2)
  (flet ((listify-fields (fields)
           (cond ((symbolp fields) fields)
                 ((every #'constantp fields) `',fields)
                 (t `(list ,@fields)))))
    (cond ((or (symbolp val-form-1) (symbolp val-form-2))
           `(equal ,(listify-fields val-form-1)
                   ,(listify-fields val-form-2)))
          (t
           `(and ,@(mapcar (lambda (v1 v2) `(= ,v1 ,v2))
                           val-form-1 val-form-2))))))

(defun compile-test (subj test funstate)
  (when (and (consp test) (symbolp (car test)) (not (keywordp (car test))))
    (setf subj (car test)
          test (cdr test)))
  (let ((key (if (consp test) (car test) test))
        (body (if (consp test) (cdr test) nil)))
    (cond ((null key)
           nil)
          ((eq key t)
           t)
          ((eq key :constant)
           (let* ((arg (arg-or-lose subj funstate))
                  (fields (arg-fields arg))
                  (consts body))
             (when (not (= (length fields) (length consts)))
               (pd-error "The number of constants doesn't match number of ~
                          fields in: (~S :constant~{ ~S~})"
                         subj body))
             (compare-fields-form (gen-arg-forms arg :numeric funstate)
                                  consts)))
          ((eq key :positive)
           `(> ,(arg-value-form (arg-or-lose subj funstate) funstate :numeric)
               0))
          ((eq key :negative)
           `(< ,(arg-value-form (arg-or-lose subj funstate) funstate :numeric)
               0))
          ((eq key :same-as)
           (let ((arg1 (arg-or-lose subj funstate))
                 (arg2 (arg-or-lose (car body) funstate)))
             (unless (and (= (length (arg-fields arg1))
                             (length (arg-fields arg2)))
                          (every (lambda (bs1 bs2)
                                   (= (byte-size bs1) (byte-size bs2)))
                                 (arg-fields arg1)
                                 (arg-fields arg2)))
               (pd-error "can't compare differently sized fields: ~
                          (~S :same-as ~S)" subj (car body)))
             (compare-fields-form (gen-arg-forms arg1 :numeric funstate)
                                  (gen-arg-forms arg2 :numeric funstate))))
          ((eq key :or)
           `(or ,@(mapcar (lambda (sub) (compile-test subj sub funstate))
                          body)))
          ((eq key :and)
           `(and ,@(mapcar (lambda (sub) (compile-test subj sub funstate))
                           body)))
          ((eq key :not)
           `(not ,(compile-test subj (car body) funstate)))
          ((and (consp key) (null body))
           (compile-test subj key funstate))
          (t
           (pd-error "bogus test-form: ~S" test)))))

(defun compute-mask-id (args)
  (let ((mask dchunk-zero)
        (id dchunk-zero))
    (dolist (arg args (values mask id))
      (let ((av (arg-value arg)))
        (when av
          (do ((fields (arg-fields arg) (cdr fields))
               (values (if (atom av) (list av) av) (cdr values)))
              ((null fields))
            (let ((field-mask (dchunk-make-mask (car fields))))
              (when (/= (dchunk-and mask field-mask) dchunk-zero)
                (pd-error "The field ~S in arg ~S overlaps some other field."
                          (car fields)
                          (arg-name arg)))
              (dchunk-insertf id (car fields) (car values))
              (dchunk-orf mask field-mask))))))))

#!-sb-fluid (declaim (inline bytes-to-bits))
(declaim (maybe-inline sign-extend aligned-p align tab tab0))

(defun bytes-to-bits (bytes)
  (declare (type disassem-length bytes))
  (* bytes sb!vm:n-byte-bits))

(defun bits-to-bytes (bits)
  (declare (type disassem-length bits))
  (multiple-value-bind (bytes rbits)
      (truncate bits sb!vm:n-byte-bits)
    (when (not (zerop rbits))
      (error "~W bits is not a byte-multiple." bits))
    bytes))

(defun sign-extend (int size)
  (declare (type integer int)
           (type (integer 0 128) size))
  (if (logbitp (1- size) int)
      (dpb int (byte size 0) -1)
      int))

;;; Is ADDRESS aligned on a SIZE byte boundary?
(defun aligned-p (address size)
  (declare (type address address)
           (type alignment size))
  (zerop (logand (1- size) address)))

;;; Return ADDRESS aligned *upward* to a SIZE byte boundary.
(defun align (address size)
  (declare (type address address)
           (type alignment size))
  (logandc1 (1- size) (+ (1- size) address)))

(defun tab (column stream)
  (funcall (formatter "~V,1t") stream column)
  nil)
(defun tab0 (column stream)
  (funcall (formatter "~V,0t") stream column)
  nil)

(defun princ16 (value stream)
  (write value :stream stream :radix t :base 16 :escape nil))

(defstruct (storage-info (:copier nil))
  (groups nil :type list)               ; alist of (name . location-group)
  (debug-vars #() :type vector))

(defstruct (segment (:conc-name seg-)
                    (:constructor %make-segment)
                    (:copier nil))
  (sap-maker (missing-arg)
             :type (function () #-sb-xc-host system-area-pointer))
  ;; Length in bytes of the range of memory covered by this segment.
  (length 0 :type disassem-length)
  (virtual-location 0 :type address)
  (storage-info nil :type (or null storage-info))
  ;; KLUDGE: CODE-COMPONENT is not a type the host understands
  #-sb-xc-host (code nil :type (or null code-component))
  (unboxed-data-range nil :type (or null (cons fixnum fixnum)))
  (hooks nil :type list))

;;; All state during disassembly. We store some seemingly redundant
;;; information so that we can allow garbage collect during disassembly and
;;; not get tripped up by a code block being moved...
(defstruct (disassem-state (:conc-name dstate-)
                           (:constructor %make-dstate)
                           (:copier nil))
  ;; offset of current pos in segment
  (cur-offs 0 :type offset)
  ;; offset of next position
  (next-offs 0 :type offset)
  ;; a sap pointing to our segment
  (segment-sap nil :type (or null #-sb-xc-host system-area-pointer))
  ;; the current segment
  (segment nil :type (or null segment))
  ;; to avoid buffer overrun at segment end, we might need to copy bytes
  ;; here first because sap-ref-dchunk reads a fixed length.
  (scratch-buf (make-array 8 :element-type '(unsigned-byte 8)))
  ;; what to align to in most cases
  (alignment sb!vm:n-word-bytes :type alignment)
  (byte-order :little-endian
              :type (member :big-endian :little-endian))
  ;; for user code to hang stuff off of
  (properties nil :type list)
  ;; for user code to hang stuff off of, cleared each time after a
  ;; non-prefix instruction is processed
  (inst-properties nil :type (or fixnum list))
  (filtered-values (make-array max-filtered-value-index)
                   :type filtered-value-vector)
  ;; to avoid consing decoded values, a prefilter can keep a chain
  ;; of objects in these slots. The objects returned here
  ;; are reusable for the next instruction.
  (filtered-arg-pool-in-use)
  (filtered-arg-pool-free)
  ;; used for prettifying printing
  (addr-print-len nil :type (or null (integer 0 20)))
  (argument-column 0 :type column)
  ;; to make output look nicer
  (output-state :beginning
                :type (member :beginning
                              :block-boundary
                              nil))

  ;; alist of (address . label-number)
  (labels nil :type list)
  ;; same as LABELS slot data, but in a different form
  (label-hash (make-hash-table) :type hash-table)
  ;; list of function
  (fun-hooks nil :type list)

  ;; alist of (address . label-number), popped as it's used
  (cur-labels nil :type list)
  ;; OFFS-HOOKs, popped as they're used
  (cur-offs-hooks nil :type list)

  ;; for the current location
  (notes nil :type list)

  ;; currently active source variables
  (current-valid-locations nil :type (or null (vector bit))))
(declaim (freeze-type disassem-state))
(defmethod print-object ((dstate disassem-state) stream)
  (print-unreadable-object (dstate stream :type t)
    (format stream
            "+~W~@[ in ~S~]"
            (dstate-cur-offs dstate)
            (dstate-segment dstate))))

;;; Return the absolute address of the current instruction in DSTATE.
(defun dstate-cur-addr (dstate)
  (the address (+ (seg-virtual-location (dstate-segment dstate))
                  (dstate-cur-offs dstate))))

;;; Return the absolute address of the next instruction in DSTATE.
(defun dstate-next-addr (dstate)
  (the address (+ (seg-virtual-location (dstate-segment dstate))
                  (dstate-next-offs dstate))))

;;; Get the value of the property called NAME in DSTATE. Also SETF'able.
;;;
;;; KLUDGE: The associated run-time machinery for this is in
;;; target-disassem.lisp (much later). This is here just to make sure
;;; it's defined before it's used. -- WHN ca. 19990701
(defmacro dstate-get-prop (dstate name)
  `(getf (dstate-properties ,dstate) ,name))

;;; Put PROPERTY into the set of instruction properties in DSTATE.
;;; PROPERTY can be a fixnum or symbol, but any given backend
;;; must exclusively use one or the other property representation.
(defun dstate-put-inst-prop (dstate property)
  (if (fixnump property)
      (setf (dstate-inst-properties dstate)
            (logior (or (dstate-inst-properties dstate) 0) property))
      (push property (dstate-inst-properties dstate))))

;;; Return non-NIL if PROPERTY is in the set of instruction properties in
;;; DSTATE. As with -PUT-INST-PROP, we can have a bitmask or a plist.
(defun dstate-get-inst-prop (dstate property)
  (if (fixnump property)
      (logtest (or (dstate-inst-properties dstate) 0) property)
      (memq property (dstate-inst-properties dstate))))

(declaim (ftype function read-suffix))
(defun read-signed-suffix (length dstate)
  (declare (type (member 8 16 32 64) length)
           (type disassem-state dstate)
           (optimize (speed 3) (safety 0)))
  (sign-extend (read-suffix length dstate) length))
