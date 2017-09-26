;;;; "warm initialization": initialization which comes after cold init

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "COMMON-LISP-USER")

;;;; general warm init compilation policy

(proclaim '(optimize (compilation-speed 1)
                     (debug #+sb-show 2 #-sb-show 1)
                     (inhibit-warnings 2)
                     (safety 2)
                     (space 1)
                     (speed 2)))

;;; Assert that genesis preserved shadowing symbols.
(let ((p sb-assem::*backend-instruction-set-package*))
  (unless (eq p (find-package "SB-VM"))
    (dolist (expect '("SEGMENT" "MAKE-SEGMENT"))
      (assert (find expect (package-shadowing-symbols p) :test 'string=)))))


;;;; compiling and loading more of the system

(load "src/cold/muffler.lisp")

;;; FIXME: CMU CL's pclcom.lisp had extra optional stuff wrapped around
;;; COMPILE-PCL, at least some of which we should probably have too:
;;;
;;; (with-compilation-unit
;;;     (:optimize '(optimize (debug #+(and (not high-security) small) .5
;;;                               #-(or high-security small) 2
;;;                               #+high-security 3)
;;;                        (speed 2) (safety #+(and (not high-security) small) 0
;;;                                          #-(or high-security small) 2
;;;                                          #+high-security 3)
;;;                        (inhibit-warnings 2))
;;;      :optimize-interface '(optimize-interface #+(and (not high-security) small)
;;; (safety 1)
;;;                                            #+high-security (safety 3))
;;;      :context-declarations
;;;      '((:external (declare (optimize-interface (safety #-high-security 2 #+high-
;;; security 3)
;;;                                             (debug #-high-security 1 #+high-s
;;; ecurity 3))))
;;;     ((:or :macro (:match "$EARLY-") (:match "$BOOT-"))
;;;     (declare (optimize (speed 0))))))
;;;
;;; FIXME: This has mutated into a hack which crudely duplicates
;;; functionality from the existing mechanism to load files from
;;; build-order.lisp-expr, without being quite parallel. (E.g. object
;;; files end up alongside the source files instead of ending up in
;;; parallel directory trees.) Maybe we could merge the filenames here
;;; into build-order.lisp-expr with some new flag (perhaps :WARM) to
;;; indicate that the files should be handled not in cold load but
;;; afterwards.
(let ((early-srcs
              '("SRC;CODE;WARM-ERROR"
                "SRC;CODE;ROOM" ; for MAP-ALLOCATED-OBJECTS
                ;; We re-nickname SB-SEQUENCE as SEQUENCE now.
                ;; It could be done in genesis, but not earlier,
                ;; since the host has a package of that name.
                "SRC;CODE;DEFPACKAGE"))

      (interpreter-srcs
              #+sb-fasteval
              '("SRC;INTERPRETER;MACROS"
                "SRC;INTERPRETER;CHECKFUNS"
                "SRC;INTERPRETER;ENV"
                "SRC;INTERPRETER;SEXPR"
                "SRC;INTERPRETER;SPECIAL-FORMS"
                "SRC;INTERPRETER;EVAL"
                "SRC;INTERPRETER;DEBUG"))
       (pcl-srcs
              '(;; CLOS, derived from the PCL reference implementation
                ;;
                ;; This PCL build order is based on a particular
                ;; (arbitrary) linearization of the declared build
                ;; order dependencies from the old PCL defsys.lisp
                ;; dependency database.
                #+nil "src/pcl/walk" ; #+NIL = moved to build-order.lisp-expr
                #+nil "SRC;PCL;EARLY-LOW"
                "SRC;PCL;MACROS"
                "SRC;PCL;COMPILER-SUPPORT"
                #+nil "SRC;PCL;LOW"
                #+nil "SRC;PCL;SLOT-NAME" ; moved to build-order.lisp-expr
                "SRC;PCL;DEFCLASS"
                "SRC;PCL;DEFS"
                "SRC;PCL;FNGEN"
                "SRC;PCL;WRAPPER"
                "SRC;PCL;CACHE"
                "SRC;PCL;DLISP"
                "SRC;PCL;BOOT"
                "SRC;PCL;VECTOR"
                "SRC;PCL;SLOTS-BOOT"
                "SRC;PCL;COMBIN"
                "SRC;PCL;DFUN"
                "SRC;PCL;CTOR"
                "SRC;PCL;BRAID"
                "SRC;PCL;DLISP3"
                "SRC;PCL;GENERIC-FUNCTIONS"
                "SRC;PCL;SLOTS"
                "SRC;PCL;INIT"
                "SRC;PCL;STD-CLASS"
                "SRC;PCL;CPL"
                "SRC;PCL;FSC"
                "SRC;PCL;METHODS"
                "SRC;PCL;FIXUP"
                "SRC;PCL;DEFCOMBIN"
                "SRC;PCL;CTYPES"
                "SRC;PCL;ENV"
                "SRC;PCL;DOCUMENTATION"
                "SRC;PCL;PRINT-OBJECT"
                "SRC;PCL;PRECOM1"
                "SRC;PCL;PRECOM2"))
      (other-srcs
              '("SRC;CODE;SETF-FUNS"
                "SRC;CODE;STUBS"
                ;; miscellaneous functionality which depends on CLOS
                "SRC;CODE;LATE-CONDITION"

                ;; CLOS-level support for the Gray OO streams
                ;; extension (which is also supported by various
                ;; lower-level hooks elsewhere in the code)
                "SRC;PCL;GRAY-STREAMS-CLASS"
                "SRC;PCL;GRAY-STREAMS"

                ;; CLOS-level support for User-extensible sequences.
                "SRC;PCL;SEQUENCE"

                ;; other functionality not needed for cold init, moved
                ;; to warm init to reduce peak memory requirement in
                ;; cold init
                "SRC;CODE;DESCRIBE"

                "SRC;CODE;DESCRIBE-POLICY"
                "SRC;CODE;INSPECT"
                "SRC;CODE;PROFILE"
                "SRC;CODE;NTRACE"
                "SRC;CODE;STEP"
                "SRC;CODE;WARM-LIB"
                #+win32 "SRC;CODE;WARM-MSWIN"
                "SRC;CODE;RUN-PROGRAM"
                #+sb-traceroot "SRC;CODE;TRACEROOT"

                #+immobile-code "SRC;CODE;IMMOBILE-SPACE"
                "SRC;CODE;REPACK-XREF"
                "SRC;CODE;SAVE"))
      (sb-c::*handled-conditions* sb-c::*handled-conditions*))
 (declare (special *compile-files-p*))
 (proclaim '(sb-ext:muffle-conditions
             (or (satisfies unable-to-optimize-note-p)
                 (satisfies optional+key-style-warning-p))))
 (flet
    ((do-srcs (list)
       (dolist (stem list)
         (let ((fullname (concatenate 'string "SYS:" stem ".LISP")))
           (sb-int:/show "about to compile" fullname)
           (flet ((report-recompile-restart (stream)
                    (format stream "Recompile file ~S" fullname))
                  (report-continue-restart (stream)
                    (format stream
                            "Continue, using possibly bogus file ~S"
                            (compile-file-pathname fullname))))
             (tagbody
              retry-compile-file
                (multiple-value-bind (output-truename warnings-p failure-p)
                    (ecase (if (boundp '*compile-files-p*) *compile-files-p* t)
                     ((t)   (compile-file fullname))
                     ((nil) (compile-file-pathname fullname)))
                  (declare (ignore warnings-p))
                  (sb-int:/show "done compiling" fullname)
                  (cond ((not output-truename)
                         (error "COMPILE-FILE of ~S failed." fullname))
                        (failure-p
                         (unwind-protect
                              (restart-case
                                  (error "FAILURE-P was set when creating ~S."
                                         output-truename)
                                (recompile ()
                                  :report report-recompile-restart
                                  (go retry-compile-file))
                                (continue ()
                                  :report report-continue-restart
                                  (setf failure-p nil)))
                           ;; Don't leave failed object files lying around.
                           (when (and failure-p (probe-file output-truename))
                                 (delete-file output-truename)
                                 (format t "~&deleted ~S~%" output-truename))))
                        ;; Otherwise: success, just fall through.
                        (t nil))
                  (unless (handler-bind
                              ((sb-kernel:redefinition-with-defgeneric
                                #'muffle-warning))
                            (load output-truename))
                    (error "LOAD of ~S failed." output-truename))
                  (sb-int:/show "done loading" output-truename))))))))

  (let ((*print-length* 10)
        (*print-level* 5)
        (*print-circle* t)
        (*compile-print* nil))
    (do-srcs early-srcs)
    (with-compilation-unit () (do-srcs interpreter-srcs))
    (with-compilation-unit () (do-srcs pcl-srcs))
    (do-srcs other-srcs))))
