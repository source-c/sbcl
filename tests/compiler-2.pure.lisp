;;;; various compiler tests without side effects

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

;;;; This file of tests was added because the tests in 'compiler.pure.lisp'
;;;; are a total hodgepodge- there is often no hugely compelling reason for
;;;; their being tests of the compiler per se, such as whether
;;;; INPUT-ERROR-IN-COMPILED-FILE is a subclass of SERIOUS-CONDITION;
;;;; in addition to which it is near impossible to wade through the
;;;; ton of nameless, slow, and noisy tests.

;;;; This file strives to do better on all fronts:
;;;; the tests should be fast, named, and not noisy.

(cl:in-package :cl-user)

(load "compiler-test-util.lisp")

(with-test (:name :ldb-recognize-local-macros)
  ;; Should not call %LDB
  (assert (not (ctu:find-named-callees
                (compile nil
                         '(lambda (x)
                           (declare (optimize speed))
                           (macrolet ((b () '(byte 2 2)))
                             (ldb (b) (the fixnum x)))))))))

;; lp#1458190
(with-test (:name :dbp-eval-order)
  (sb-int:collect ((calls))
    (flet ((f (new old)
             (dpb (progn (calls 'eval-new) new)
                  (progn (calls 'eval-byte) (byte 10 10))
                  (progn (calls 'eval-old) old))))
      (f 20 0)
      (assert (equal (calls)
                     '(eval-new eval-byte eval-old))))))

;; Best practice treats TRULY-THE as a special operator, not a macro,
;; in a context such as (DPB X (TRULY-THE SB-KERNEL:BYTE-SPECIFIER ...) Y).
;; DPB used to expand its second argument using MACROEXPAND and lose
;; the nuance of TRULY-THE. Strictly speaking, byte-specifier is not a
;; type specifier that users are supposed to know about, so portable code
;; should not care, but this might affect internal code.
(with-test (:name :dpb-inner-macro)
  (flet ((source-xform (sexpr)
           (funcall (sb-int:info :function :source-transform (car sexpr))
                    sexpr (sb-kernel:make-null-lexenv))))
    (assert (equal-mod-gensyms
             (source-xform
              '(dpb (new) (truly-the sb-kernel:byte-specifier bspec) (old)))
             '(let ((new (new))
                    (byte (truly-the sb-kernel:byte-specifier bspec)))
               (sb-kernel:%dpb new (byte-size byte) (byte-position byte)
                               (old)))))))

(with-test (:name :inline-satisfies-predicate)
  ;; If we remove the indirections in these functions,
  ;; this test should visibly break so that we can write a new test
  ;; that asserts that inlining F works in (THE (SATISFIES F) obj).
  (assert (equal (sb-ext:typexpand 'sb-impl::function-name)
                 '(satisfies sb-int:legal-fun-name-p)))
  (let ((f (compile nil '(lambda (x) (the sb-impl::function-name x)))))
    (assert (equal (list (symbol-function 'sb-int:valid-function-name-p))
                   (ctu:find-named-callees f))))
  (let ((f (compile nil '(lambda (x)
                           (declare (notinline sb-int:legal-fun-name-p))
                           (the sb-impl::function-name x)))))
    (assert (equal (list (symbol-function 'sb-int:legal-fun-name-p))
                   (ctu:find-named-callees f)))))

(with-test (:name :make-array-untestable-type-no-warning)
  (assert-no-signal
   (compile nil `(lambda () (make-array '(2 2)
                                        :element-type `(satisfies foofa))))))

(with-test (:name :make-array-nil-no-warning)
  (assert-no-signal
   (compile nil '(lambda () (make-array '(2 2) :element-type nil)))))

(with-test (:name :nth-value-huge-n-works)
  (flet ((return-a-ton-of-values ()
           (values-list (loop for i below 5000 collect i))))
    (assert (= (nth-value 1 (return-a-ton-of-values)) 1))
    (assert (= (nth-value 4000 (return-a-ton-of-values)) 4000))))

(defstruct (a-test-structure-foo
            (:constructor make-a-foo-1)
            (:constructor make-a-foo-2 (b &optional a)))
  (a 0 :type symbol)
  (b nil :type integer))

(with-test (:name :improperly-initialized-slot-warns)
  (with-open-stream (*error-output* (make-broadcast-stream))
    (multiple-value-bind (f warn err)
        (compile nil '(lambda () (make-a-foo-1 :a 'what)))
      ;; should warn because B's default is NIL, not an integer.
      (assert (and f warn err)))
    (multiple-value-bind (f warn err)
        (compile nil '(lambda () (make-a-foo-2 3)))
      ;; should warn because A's default is 0
      (assert (and f warn err)))))

(with-test (:name :inline-structure-ctor-no-declaim)
  (let ((f (compile nil
                    '(lambda ()
                       (make-a-foo-1 :a 'wat :b 3)))))
    (assert (ctu:find-named-callees f)))
  (let ((f (compile nil
                    '(lambda ()
                       (declare (inline make-a-foo-1))
                       (make-a-foo-1 :a 'wat :b 3)))))
    (assert (not (ctu:find-named-callees f)))))

(with-test (:name :internal-name-p :skipped-on :sb-xref-for-internals)
  (assert (sb-c::internal-name-p 'sb-int:neq)))

(with-test (:name :coerce-callable-to-fun-note)
  (macrolet ((try (form what)
               `(assert
                 (search ,(format nil "~A is not known to be" what)
                         (with-output-to-string (*error-output*)
                           (compile nil '(lambda (x)
                                           (declare (optimize speed))
                                           (funcall ,form))))))))

    (try (eval `(work-with ,x)) "callable expression")
    (try x "X")
    ;; For this I'd accept either Z or X in the message.
    (try (progn (let ((z x)) (identity z))) "X")))

(with-test (:name :princ-to-string-unflushable)
  ;; Ordinary we'll flush it
  (let ((f (compile nil '(lambda (x) (princ-to-string x) x))))
    (assert (not (ctu:find-named-callees f :name 'princ-to-string))))
  ;; But in high safety it should be called for effect
  (let ((f (compile nil '(lambda (x)
                           (declare (optimize safety)) (princ-to-string x) x))))
    (assert (ctu:find-named-callees f :name 'princ-to-string))))

(with-test (:name :space-bounds-no-consing
                  :skipped-on :interpreter)
  ;; Asking for the size of a heap space should not cost anything!
  (ctu:assert-no-consing (sb-vm::%space-bounds :static))
  (ctu:assert-no-consing (sb-vm::space-bytes :static)))

(with-test (:name :map-allocated-objects-no-consing
                  :skipped-on :interpreter
                  :fails-on :ppc)
  (let ((n 0))
    (sb-int:dx-flet ((f (obj type size)
                       (declare (ignore obj type size))
                       (incf n)))
      (ctu:assert-no-consing
       (sb-vm::map-allocated-objects #'f :dynamic)
       5))))

(with-test (:name :pack-varints-as-bignum)
  (dotimes (i 500) ; do some random testing this many times
    (let* ((random-numbers (loop repeat (+ (random 20) 3)
                                 collect (1+ (random 4000))))
           (test-list (sort (delete-duplicates random-numbers) #'<))
           (packed-int (sb-c::pack-code-fixup-locs test-list))
           (result (make-array 1 :element-type 'sb-ext:word)))
      ;; The packer intrinsically self-checks the packing
      ;; so we don't need to assert anything about that.
      (sb-sys:with-pinned-objects (packed-int result)
        ;; Now exercise the C unpacker.
        ;; This hack of allocating 4 longs is terrible, but whatever.
        (let ((unpacker (make-alien long 4))
              (prev-loc 0))
          (alien-funcall (extern-alien "varint_unpacker_init"
                                       (function void (* long) unsigned))
                         unpacker
                         (sb-kernel:get-lisp-obj-address packed-int))
          (sb-int:collect ((unpacked))
            (loop
             (let ((status
                    (alien-funcall
                     (extern-alien "varint_unpack"
                                   (function int (* long) system-area-pointer))
                     unpacker (sb-sys:vector-sap result))))
               (let ((val (aref result 0)))
                 ;; status of 0 is EOF, val = 0 means a decoded value was 0,
                 ;; which can't happen, so it's effectively EOF.
                 (when (or (eql status 0) (eql val 0)) (return))
                 (let ((loc (+ prev-loc val)))
                   (unpacked loc)
                   (setq prev-loc loc)))))
            (assert (equal (unpacked) test-list))))))))

(with-test (:name :symbol-value-quoted-constant)
  (let ((f (compile nil '(lambda () (symbol-value 'char-code-limit)))))
    (assert (not (ctu:find-code-constants f :type 'symbol))))
  (let ((f (compile nil '(lambda () (symbol-global-value 'char-code-limit)))))
    (assert (not (ctu:find-code-constants f :type 'symbol)))))

(with-test (:name :set-symbol-value-of-defglobal)
  (let ((s 'sb-c::*recognized-declarations*))
    (assert (eq (sb-int:info :variable :kind s) :global)) ; verify precondition
    (let ((f (compile nil `(lambda () (setf (symbol-value ',s) nil)))))
      ;; Should not have a call to SET-SYMBOL-GLOBAL-VALUE>
      (assert (not (ctu:find-code-constants f :type 'sb-kernel:fdefn))))))

(with-test (:name :layout-constants
                  :skipped-on '(not (and :x86-64 :immobile-space)))
  (let ((addr-of-pathname-layout
         (write-to-string
          (sb-kernel:get-lisp-obj-address (sb-kernel:find-layout 'pathname))
          :base 16 :radix t))
        (count 0))
    ;; The constant should appear in two CMP instructions
    (dolist (line (split-string
                   (with-output-to-string (s)
                     (let ((sb-disassem:*disassem-location-column-width* 0))
                       (disassemble 'pathnamep :stream s)))
                   #\newline))
      (when (and (search "CMP" line) (search addr-of-pathname-layout line))
        (incf count)))
    (assert (= count 2))))

(with-test (:name :set-symbol-value-imm :skipped-on '(not :x86-64))
  (let (success)
    (dolist (line (split-string
                   (with-output-to-string (s)
                     (let ((sb-disassem:*disassem-location-column-width* 0))
                       (disassemble '(lambda () (setq *print-base* 8)) :stream s)))
                   #\newline))
      (when (and #+sb-thread (search "MOV QWORD PTR [R" line)
                 #-sb-thread (search "MOV QWORD PTR [" line)
                 (search (format nil ", ~D" (ash 8 sb-vm:n-fixnum-tag-bits)) line))
        (setq success t)))
    (assert success)))

(with-test (:name :linkage-table-bogosity :skipped-on '(not :sb-dynamic-core))
  (let ((strings (map 'list (lambda (x) (if (consp x) (car x) x))
                      #+sb-dynamic-core sb-vm::+required-foreign-symbols+
                      #-sb-dynamic-core '())))
    (assert (= (length (remove-duplicates strings :test 'string=))
               (length strings)))))

(with-test (:name :no-style-warning-for-inline-cl-fun)
  (assert (not (nth-value
                1 (compile nil '(lambda (x)
                                 (declare (optimize (speed 3)) (inline length)
                                          (muffle-conditions compiler-note))
                                 (length x)))))))
