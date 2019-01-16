;;;; Compile the fundamental system sources (not CLOS, and possibly
;;;; not some other warm-load-only stuff like DESCRIBE) to produce
;;;; object files.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-COLD")

(let ((*features* (cons :sb-xc *features*)))
  (load "src/cold/muffler.lisp"))

;; Avoid forward-reference to an as-yet unknown type.
;; NB: This is not how you would write this function, if you required
;; such a thing. It should be (TYPEP X 'CODE-DELETION-NOTE).
;; Do as I say, not as I do.
(defun code-deletion-note-p (x)
  (eq (type-of x) 'sb-ext:code-deletion-note))
(setq sb-c::*handled-conditions*
      `((,(sb-kernel:specifier-type
           '(or (satisfies unable-to-optimize-note-p)
                (satisfies code-deletion-note-p)))
         . muffle-warning)))

(defun proclaim-target-optimization ()
  (sb-c::init-xc-policy #+cons-profiling '((sb-c::instrument-consing 2)))
  (let ((debug (if (position :sb-show sb-xc:*features*) 2 1)))
    (sb-xc:proclaim
     `(optimize
       (compilation-speed 1) (debug ,debug)
       ;; CLISP's pretty-printer is fragile and tends to cause stack
       ;; corruption or fail internal assertions, as of 2003-04-20; we
       ;; therefore turn off as many notes as possible.
       (sb-ext:inhibit-warnings #-clisp 2 #+clisp 3)
       ;; SAFETY = SPEED (and < 3) should provide reasonable safety,
       ;; but might skip some unreasonably expensive stuff
       (safety 2) (space 1) (speed 2)
       ;; sbcl-internal optimization declarations:
       ;;
       ;; never insert stepper conditions
       (sb-c:insert-step-conditions 0)
       ;; save FP and PC for alien calls -- or not
       (sb-c:alien-funcall-saves-fp-and-pc #!+x86 3 #!-x86 0)))))

;;; A note about CLISP compatibility:
;;; CLISP uses *READTABLE* when loading '.fas' files, and so we shouldn't put
;;; too much of our junk in the readtable. I'm not sure of the full extent
;;; to which it uses our macros, but it definitely was using our #\" reader.
;;; As such, it would signal warnings about strings that it wrote by its own
;;; choice, where we specifically avoided using non-standard char literals.
;;; This would happen when building + loading the cross-compiler, and CLISP
;;; compiled a format call such as this one from 'src/compiler/codegen':
;;;   (FORMAT *COMPILER-TRACE-OUTPUT* "~|~%assembly code for ~S~2%" ...))
;;; which placed into its '.fas' a quoted string containing a byte for the
;;; the literal #\Page character (and literal #\Newline, which is fine).
;;; We should not print a warning for that. We should, however, warn
;;; if we see those characters in strings as read directly from source.
;;;
;;; In case there is doubt as to the veracity of this observation, a simple
;;; experiment proves that the warnings were not exactly our fault:
;;; Given file "foo.lisp" containing (DEFUN F (S) (FORMAT S "x~|y"))
;;; Then:
;;; * (set-macro-character #\"
;;;    (let ((f (get-macro-character #\")))
;;;     (lambda (strm ch &aux (string (funcall f strm ch)))
;;;       (format t "Read ~S from ~S~%" string strm)
;;;       string)))
;;; * (load "foo.fas") shows:
;;;   ;; Loading file foo.fas ...
;;;   Read "x^Ly" from #<INPUT BUFFERED FILE-STREAM CHARACTER #P"/tmp/foo.fas" @11>
;;;
(defun in-target-cross-compilation-mode (fun)
  "Call FUN with everything set up appropriately for cross-compiling
   a target file."
  (let (;; In order to increase microefficiency of the target Lisp,
        ;; enable old CMU CL defined-function-types-never-change
        ;; optimizations. (ANSI says users aren't supposed to
        ;; redefine our functions anyway; and developers can
        ;; fend for themselves.)
        #!-sb-fluid
        (sb-ext:*derive-function-types* t)
        ;; Let the target know that we're the cross-compiler.
        (*features* (cons :sb-xc *features*))
        ;; We need to tweak the readtable..
        (*readtable* (copy-readtable)))
    ;; ..in order to make backquotes expand into target code
    ;; instead of host code.
    (set-macro-character #\` #'sb-impl::backquote-charmacro)
    (set-macro-character #\, #'sb-impl::comma-charmacro)

    ;; Warn about presence of #\Tab or #\Page in our quoted strings.
    ;; This is done here and not more broadly, per the comment above.
    (set-macro-character #\" (make-quote-reader (get-macro-character #\" nil)))

    (set-dispatch-macro-character #\# #\+ #'she-reader)
    (set-dispatch-macro-character #\# #\- #'she-reader)
    ;; Control optimization policy.
    (proclaim-target-optimization)
    (progn
      (funcall fun))))

(setf *target-compile-file* #'sb-xc:compile-file)
(setf *target-assemble-file* #'sb-c:assemble-file)
(setf *in-target-compilation-mode-fn* #'in-target-cross-compilation-mode)

;; ... and since the cross-compiler hasn't seen a DEFMACRO for QUASIQUOTE,
;; make it think it has, otherwise it fails more-or-less immediately.
(setf (sb-xc:macro-function 'sb-int:quasiquote)
      (lambda (form env)
        (the sb-kernel:lexenv-designator env)
        (sb-impl::expand-quasiquote (second form) t)))

(setq sb-c::*track-full-called-fnames* :minimal) ; Change this as desired

;;; Keep these in order by package, then symbol.
(dolist (sym
         (append
          ;; CL, EXT, KERNEL
          '(allocate-instance
            compute-applicable-methods
            slot-makunbound
            make-load-form-saving-slots
            sb-vm::remove-static-links)
          ;; CLOS implementation
          '(sb-mop:class-finalized-p
            sb-mop:class-prototype
            sb-mop:class-slots
            sb-mop:eql-specializer-object
            sb-mop:finalize-inheritance
            sb-mop:generic-function-name
            (setf sb-mop:generic-function-name)
            sb-mop:slot-definition-allocation
            sb-mop:slot-definition-name
            sb-pcl::%force-cache-flushes
            sb-pcl::check-wrapper-validity
            sb-pcl::class-has-a-forward-referenced-superclass-p
            sb-pcl::class-wrapper
            sb-pcl::compute-gf-ftype
            sb-pcl::definition-source
            sb-pcl::ensure-accessor
            sb-pcl:ensure-class-finalized)
          ;; CLOS-based packages
          '(sb-gray:stream-clear-input
            sb-gray:stream-clear-output
            sb-gray:stream-file-position
            sb-gray:stream-finish-output
            sb-gray:stream-force-output
            sb-gray:stream-fresh-line
            sb-gray:stream-line-column
            sb-gray:stream-line-length
            sb-gray:stream-listen
            sb-gray:stream-peek-char
            sb-gray:stream-read-byte
            sb-gray:stream-read-char
            sb-gray:stream-read-char-no-hang
            sb-gray:stream-read-line
            sb-gray:stream-read-sequence
            sb-gray:stream-terpri
            sb-gray:stream-unread-char
            sb-gray:stream-write-byte
            sb-gray:stream-write-char
            sb-gray:stream-write-sequence
            sb-gray:stream-write-string
            sb-sequence:concatenate
            sb-sequence:copy-seq
            sb-sequence:count
            sb-sequence:count-if
            sb-sequence:count-if-not
            sb-sequence:delete
            sb-sequence:delete-duplicates
            sb-sequence:delete-if
            sb-sequence:delete-if-not
            (setf sb-sequence:elt)
            sb-sequence:elt
            sb-sequence:emptyp
            sb-sequence:fill
            sb-sequence:find
            sb-sequence:find-if
            sb-sequence:find-if-not
            (setf sb-sequence:iterator-element)
            sb-sequence:iterator-endp
            sb-sequence:iterator-step
            sb-sequence:length
            sb-sequence:make-sequence-iterator
            sb-sequence:make-sequence-like
            sb-sequence:map
            sb-sequence:merge
            sb-sequence:mismatch
            sb-sequence:nreverse
            sb-sequence:nsubstitute
            sb-sequence:nsubstitute-if
            sb-sequence:nsubstitute-if-not
            sb-sequence:position
            sb-sequence:position-if
            sb-sequence:position-if-not
            sb-sequence:reduce
            sb-sequence:remove
            sb-sequence:remove-duplicates
            sb-sequence:remove-if
            sb-sequence:remove-if-not
            sb-sequence:replace
            sb-sequence:reverse
            sb-sequence:search
            sb-sequence:sort
            sb-sequence:stable-sort
            sb-sequence:subseq
            sb-sequence:substitute
            sb-sequence:substitute-if
            sb-sequence:substitute-if-not)
          ;; Fast interpreter
          #!+sb-fasteval
          '(sb-interpreter:%fun-type
            sb-interpreter:env-policy
            sb-interpreter:eval-in-environment
            sb-interpreter:find-lexical-fun
            sb-interpreter:find-lexical-var
            sb-interpreter::flush-everything
            sb-interpreter::fun-lexically-notinline-p
            sb-interpreter:lexenv-from-env
            sb-interpreter::lexically-unlocked-symbol-p
            sb-interpreter:list-locals
            sb-interpreter:prepare-for-compile
            sb-interpreter::reconstruct-syntactic-closure-env)
          ;; Other
          '(sb-debug::find-interrupted-name-and-frame
            sb-impl::encapsulate-generic-function
            sb-impl::encapsulated-generic-function-p
            sb-impl::get-processes-status-changes-sigchld
            sb-impl::step-form
            sb-impl::step-values
            sb-impl::stringify-package-designator
            sb-impl::stringify-string-designator
            sb-impl::stringify-string-designators
            sb-impl::unencapsulate-generic-function)))
  (setf (gethash sym sb-c::*undefined-fun-whitelist*) t))

#+#.(cl:if (cl:find-package "HOST-SB-POSIX") '(and) '(or))
(defun parallel-make-host-2 (max-jobs)
  (let ((subprocess-count 0)
        (subprocess-list nil))
    (flet ((wait ()
             (multiple-value-bind (pid status) (host-sb-posix:wait)
               (format t "~&; Subprocess ~D exit status ~D~%"  pid status)
               (setq subprocess-list (delete pid subprocess-list)))
             (decf subprocess-count)))
      (do-stems-and-flags (stem flags)
        (unless (position :not-target flags)
          (when (>= subprocess-count max-jobs)
            (wait))
          (let ((pid (host-sb-posix:fork)))
            (when (zerop pid)
              (target-compile-stem stem flags)
              ;; FIXME: convey exit code based on COMPILE result.
              (sb-cold::exit-process 0))
            (push pid subprocess-list))
          (incf subprocess-count)
          ;; Cause the compile-time effects from this file
          ;; to appear in subsequently forked children.
          (let ((*compile-for-effect-only* t))
            (target-compile-stem stem flags))))
      (loop (if (plusp subprocess-count) (wait) (return)))
      (values))))

;;; Actually compile
(let ((sb-xc:*compile-print* nil))
  (if (make-host-2-parallelism)
      (parallel-make-host-2 (make-host-2-parallelism))
      (let ((total
             (count-if (lambda (x) (not (find :not-target (cdr x))))
                       (get-stems-and-flags)))
            (n 0)
            (sb-xc:*compile-verbose* nil))
        (do-stems-and-flags (stem flags)
          (unless (position :not-target flags)
            (format t "~&[~D/~D] ~A" (incf n) total (stem-remap-target stem))
            (target-compile-stem stem flags)
            (terpri))))))
