;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!IMPL")

;;; entries in STATIC-SYMBOLS table, references to which can be compiled
;;; as though they're special variables
;;;
;;; FIXME: These should be listed once and only once, instead of
;;; listed here and then listed separately (and by now, 2001-06-06,
;;; slightly differently) elsewhere. (Maybe this is resolved?)
(declaim (special *posix-argv*
                  *core-string*
                  *stdin*
                  *stdout*
                  *stderr*
                  *tty*
                  sb!vm:*current-catch-block*
                  sb!vm::*current-unwind-protect-block*
                  sb!vm::*alien-stack-pointer*
                  sb!vm:*control-stack-start*
                  sb!vm:*control-stack-end*
                  sb!vm:*binding-stack-start*
                  #!+(or hpux) sb!vm::*c-lra*
                  *allow-with-interrupts*
                  sb!unix::*unblock-deferrables-on-enabling-interrupts-p*
                  *interrupts-enabled*
                  *interrupt-pending*
                  #!+sb-thruption *thruption-pending*
                  #!+sb-safepoint *gc-safe*
                  #!+sb-safepoint *in-safepoint*
                  *free-interrupt-context-index*
                  sb!vm::*allocation-pointer*
                  sb!vm::*binding-stack-pointer*
                  sb!pcl::*cache-miss-values-stack*
                  sb!pcl::*dfun-miss-gfs-on-stack*))
(defvar sb!vm:*alloc-signal*) ; initialized by create_thread_struct()
;;; This is a slot of 'struct thread' if multithreaded,
;;; and the symbol-global-value should never be used.
;;; (And in any case it is not really a special var)
#!+(and (or x86 x86-64) (not sb-thread))
(!defvar *pseudo-atomic-bits* 0)
