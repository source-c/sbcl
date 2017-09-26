;;;; Lisp-side allocation (used currently only for direct allocation
;;;; to static and immobile spaces).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

#!-sb-fluid (declaim (inline store-word))
(defun store-word (word base &optional (offset 0) (lowtag 0))
  (declare (type (unsigned-byte #.n-word-bits) word base offset)
           (type (unsigned-byte #.n-lowtag-bits) lowtag))
  (setf (sap-ref-word (int-sap base) (- (ash offset word-shift) lowtag)) word))

(defun allocate-static-vector (widetag length words)
  (declare (type (unsigned-byte #.n-widetag-bits) widetag)
           (type (unsigned-byte #.n-word-bits) words)
           (type index length))
  ;; WITHOUT-GCING implies WITHOUT-INTERRUPTS
  (or
   (without-gcing
     (let* ((pointer (sap-int *static-space-free-pointer*))
            (vector (logior pointer other-pointer-lowtag))
            (nbytes (pad-data-block (+ words vector-data-offset)))
            (new-pointer (+ pointer nbytes)))
       (when (> static-space-end new-pointer)
         (store-word widetag
                     vector 0 other-pointer-lowtag)
         (store-word (fixnumize length)
                     vector vector-length-slot other-pointer-lowtag)
         (store-word 0 new-pointer)
         (setf *static-space-free-pointer* (int-sap new-pointer))
         (%make-lisp-obj vector))))
   (error 'simple-storage-condition
          :format-control "Not enough memory left in static space to ~
                           allocate vector.")))

#!+immobile-space
(progn

(defglobal *immobile-space-mutex* (sb!thread:make-mutex :name "Immobile space"))

(eval-when (:compile-toplevel)
  (assert (eql code-code-size-slot 1))
  (assert (eql code-debug-info-slot 2)))

(define-alien-variable "varyobj_holes" long)
(define-alien-variable "varyobj_page_touched_bits" (* (unsigned 32)))
(define-alien-variable "varyobj_page_scan_start_offset" (* (unsigned 16)))
(define-alien-variable "varyobj_page_header_gens" (* (unsigned 8)))
(define-alien-routine "find_preceding_object" long (where long))

;;; Lazily created freelist, used only when unallocate is called:
;;; A cons whose car is a sorted list of hole sizes available
;;; and whose cdr is a hashtable.
;;; The keys in the hashtable are hole sizes, values are lists of holes.
;;; A better structure would be just a sorted array of sizes
;;; with each entry pointing to the holes which are threaded through
;;; some bytes in the storage itself rather than through cons cells.
(!defglobal *immobile-freelist* nil)

;;; Return the zero-based index within the varyobj subspace of immobile space.
(defun varyobj-page-index (address)
  (declare (type (and fixnum unsigned-byte) address))
  (values (floor (- address (+ immobile-space-start immobile-fixedobj-subspace-size))
                 immobile-card-bytes)))

(defun varyobj-page-address (index)
  (+ immobile-space-start immobile-fixedobj-subspace-size
     (* index immobile-card-bytes)))

;;; Convert a zero-based varyobj page index into a scan start address.
(defun varyobj-page-scan-start (index)
  (- (+ immobile-space-start immobile-fixedobj-subspace-size
        (* (1+ index) immobile-card-bytes))
     (* 2 n-word-bytes (deref varyobj-page-scan-start-offset index))))

(declaim (inline hole-p))
(defun hole-p (raw-address)
  (eql (sap-ref-32 (int-sap raw-address) 0)
       (logior (ash 2 n-widetag-bits) code-header-widetag)))

(defun freed-hole-p (address)
  (and (hole-p address)
       ;; A hole is not considered to have been freed until it is
       ;; no longer in the chain of objects linked through
       ;; the debug_info slot.
       (eql (sap-ref-word (int-sap address)
                          (ash code-debug-info-slot word-shift))
            nil-value)))

(declaim (inline hole-size))
(defun hole-size (hole-address) ; in bytes
  (+ (sap-ref-lispobj (int-sap hole-address) (ash code-code-size-slot word-shift))
     (ash 2 word-shift))) ; add 2 boxed words

(declaim (inline (setf hole-size)))
(defun (setf hole-size) (new-size hole) ; NEW-SIZE is in bytes
  (setf (sap-ref-lispobj (int-sap hole) (ash code-code-size-slot word-shift))
        (- new-size (ash 2 word-shift)))) ; account for 2 boxed words

(declaim (inline hole-end-address))
(defun hole-end-address (hole-address)
  (+ hole-address (hole-size hole-address)))

(defun sorted-list-insert (item list key-fn)
  (declare (function key-fn))
  (let ((key (funcall key-fn item)) (tail list) prev)
    (loop
     (when (null tail)
       (let ((new-tail (list item)))
         (return (cond ((not prev) new-tail)
                       (t (setf (cdr prev) new-tail) list)))))
     (let ((head (car tail)))
       (when (< key (funcall key-fn head))
         (rplaca tail item)
         (rplacd tail (cons head (cdr tail)))
         (return list)))
     (setq prev tail tail (cdr tail)))))

;;; These routines are not terribly efficient, but very straightforward
;;; since we can assume the existence of hashtables.
(defun add-to-freelist (hole)
  (let* ((size (hole-size hole))
         (freelist *immobile-freelist*)
         (table (cdr freelist))
         (old (gethash (hole-size hole) table)))
    ;; Check for double-free error
    #!+immobile-space-debug (aver (not (member hole (gethash size table))))
    (unless old
      (setf (car freelist)
            (sorted-list-insert size (car freelist) #'identity)))
    (setf (gethash size table) (cons hole old))))

(defun remove-from-freelist (hole)
  (let* ((key (hole-size hole))
         (freelist *immobile-freelist*)
         (table (cdr freelist))
         (list (gethash key table))
         (old-length (length list))
         (new (delete hole list :count 1)))
    (declare (ignorable old-length))
    #!+immobile-space-debug (aver (= (length new) (1- old-length)))
    (cond (new
           (setf (gethash key table) new))
          (t
           (setf (car freelist) (delete key (car freelist) :count 1))
           (remhash key table)))))

(defun find-in-freelist (size test)
  (let* ((freelist *immobile-freelist*)
         (hole-size
          (if (eq test '<=)
              (let ((sizes (member size (car freelist) :test '<=)))
                (unless sizes
                  (return-from find-in-freelist nil))
                (car sizes))
              size))
         (found (car (gethash hole-size (cdr freelist)))))
    (when found
      (remove-from-freelist found))
    found))

(defun set-immobile-space-free-pointer (free-ptr)
  (declare (type (and fixnum unsigned-byte) free-ptr))
  (setq *immobile-space-free-pointer* (int-sap free-ptr))
  ;; When the free pointer is not page-aligned - it usually won't be -
  ;; then we create an unboxed array from the pointer to the page end
  ;; so that it appears as one contiguous object when scavenging.
  ;; instead of a bunch of cons cells.
  (when (logtest free-ptr (1- immobile-card-bytes))
    (let ((n-trailing-bytes
           (- (nth-value 1 (ceiling free-ptr immobile-card-bytes)))))
      (setf (sap-ref-word (int-sap free-ptr) 0) simple-array-fixnum-widetag
            (sap-ref-word (int-sap free-ptr) n-word-bytes)
            ;; Convert bytes to words, subtract the header and vector length.
            (ash (- (ash n-trailing-bytes (- word-shift)) 2)
                 n-fixnum-tag-bits)))))

(defun unallocate (hole)
  #!+immobile-space-debug
  (awhen *in-use-bits* (mark-range it hole (hole-size hole) nil))
  (let* ((hole-end (hole-end-address hole))
         (end-is-free-ptr (eql hole-end (sap-int *immobile-space-free-pointer*))))
    ;; First, ensure that no page's scan-start points to this hole.
    ;; For smaller-than-page objects, this will do nothing if the hole
    ;; was not the scan-start. For larger-than-page, we have to update
    ;; a range of pages. Example:
    ;;   |  page1 |  page2 |  page3 |  page4  |
    ;;        |-- hole A ------ | -- hole B --
    ;; If page1 had an object preceding the hole, then it is not empty,
    ;; but if it pointed to the hole, and the hole extended to the end
    ;; of the first page, then that page is empty.
    ;; Pages (1+ first-page) through (1- last-page) inclusive
    ;; must become empty. last-page may or may not be depending
    ;; on whether another object can be found on it.
    (let ((first-page (varyobj-page-index hole))
          (last-page (varyobj-page-index (1- hole-end))))
      (when (and (eql (varyobj-page-scan-start first-page) hole)
                 (< first-page last-page))
        (setf (deref varyobj-page-scan-start-offset first-page) 0))
      (loop for page from (1+ first-page) below last-page
            do (setf (deref varyobj-page-scan-start-offset page) 0))
      ;; Only touch the offset for the last page if it pointed to this hole.
      ;; If the following object is a hole that is in the pending free list,
      ;; it's ok, but if it's a hole that is already in the freelist,
      ;; it's not OK, so look beyond that object. We don't have to iterate,
      ;; since there can't be two consecutive holes - so it's either the
      ;; object after this hole, or the one after that.
      (when (eql (varyobj-page-scan-start last-page) hole)
        (let* ((page-end (varyobj-page-address (1+ last-page)))
               (new-scan-start (cond (end-is-free-ptr page-end)
                                     ((freed-hole-p hole-end)
                                      (hole-end-address hole-end))
                                     (t hole-end))))
          (setf (deref varyobj-page-scan-start-offset last-page)
                (if (< new-scan-start page-end)
                    ;; Compute new offset backwards relative to the page end.
                    (/ (- page-end new-scan-start) (* 2 n-word-bytes))
                    0))))) ; Page becomes empty

    (unless *immobile-freelist*
      (setf *immobile-freelist* (cons nil (make-hash-table :test #'eq))))

    ;; find-preceding is the most expensive operation in this sequence
    ;; of steps. Not sure how to improve it, but I doubt it's a problem.
    (let* ((predecessor (find-preceding-object hole))
           (pred-is-free (and (not (eql predecessor 0))
                              (freed-hole-p predecessor))))
      (when pred-is-free
        (remove-from-freelist predecessor)
        (setf hole predecessor))
      (when end-is-free-ptr
        ;; Give back space below the free pointer for better space conservation.
        ;; Consider when the hole touching the free pointer is equal in size
        ;; to another hole that could have been used instead. Taking space at
        ;; the free pointer diminishes the opportunity to use the frontier
        ;; to later allocate a larger object that would not have fit
        ;; into any existing hole.
        (set-immobile-space-free-pointer hole)
        (return-from unallocate))
      (let* ((successor hole-end)
             (succ-is-free (freed-hole-p successor)))
        (when succ-is-free
          (setf hole-end (hole-end-address successor))
          (remove-from-freelist successor)))
      ;; The hole must be an integral number of doublewords.
      (aver (zerop (rem (- hole-end hole) 16)))
      (setf (hole-size hole) (- hole-end hole))))
  (add-to-freelist hole))

(defun allocate-immobile-bytes (n-bytes word0 word1 lowtag)
  (declare (type (and fixnum unsigned-byte) n-bytes))
  (setq n-bytes (logandc2 (+ n-bytes (1- (* 2 n-word-bytes)))
                          (1- (* 2 n-word-bytes))))
  ;; Can't allocate fewer than 4 words due to min hole size.
  (aver (>= n-bytes (* 4 n-word-bytes)))
  (sb!thread::with-system-mutex (*immobile-space-mutex* :without-gcing t)
   (unless (zerop varyobj-holes)
     ;; If deferred sweep needs to happen, do so now.
     ;; Concurrency could potentially be improved here: at most one thread
     ;; should do this step, but it doesn't need to be exclusive with GC
     ;; as long as we can atomically pop items off the list of holes.
     (let ((hole-addr varyobj-holes))
       (setf varyobj-holes 0)
       (loop
        (let ((next (sap-ref-word (int-sap hole-addr)
                                  (ash code-debug-info-slot word-shift))))
          (setf (sap-ref-word (int-sap hole-addr)
                              (ash code-debug-info-slot word-shift))
                nil-value)
          (unallocate hole-addr)
          (if (eql (setq hole-addr next) 0) (return))))))
   (let ((addr
          (or (and *immobile-freelist*
                   (or (find-in-freelist n-bytes '=) ; 1. Exact match?
                       ;; 2. Try splitting a hole, adding some slack so that
                       ;;    both pieces can potentially be used.
                       (let ((found (find-in-freelist (+ n-bytes 192) '<=)))
                         (when found
                           (let* ((actual-size (hole-size found))
                                  (remaining (- actual-size n-bytes)))
                             (aver (zerop (rem actual-size 16)))
                             (setf (hole-size found) remaining) ; Shorten the lower piece
                             (add-to-freelist found)
                             (+ found remaining)))))) ; Consume the upper piece
              ;; 3. Extend the frontier.
              (let* ((addr (sap-int *immobile-space-free-pointer*))
                     (free-ptr (+ addr n-bytes))
                      (limit (+ immobile-space-start
                                (- immobile-space-size immobile-card-bytes))))
                ;; The last page can't be used, because GC uses it as scratch space.
                (when (> free-ptr limit)
                  (format t "~&Immobile space exhausted~%")
                  (sb!impl::%halt))
                (set-immobile-space-free-pointer free-ptr)
                addr))))
     (aver (not (logtest addr lowtag-mask))) ; Assert proper alignment
     ;; Compute the start and end of the first page consumed.
     (let* ((page-start (logandc2 addr (1- immobile-card-bytes)))
            (page-end (+ page-start immobile-card-bytes))
            (index (varyobj-page-index addr))
            (obj-end (+ addr n-bytes)))
       ;; Mark the page as being used by a nursery object.
       (setf (deref varyobj-page-header-gens index)
             (logior (deref varyobj-page-header-gens index) 1))
       ;; On the object's first page, set the scan start only if addr
       ;; is lower than the current page-scan-start object.
       ;; Note that offsets are expressed in doublewords backwards from
       ;; page end, so that we can direct the scan start to any doubleword
       ;; on the page or in the preceding 1MiB (approximately).
       (when (< addr (varyobj-page-scan-start index))
         (setf (deref varyobj-page-scan-start-offset index)
               (ash (- page-end addr) (- (1+ word-shift)))))
       ;; On subsequent pages, always set the scan start, since there can not
       ;; be a lower-addressed object touching those pages.
       (loop
        (setq page-start page-end)
        (incf page-end immobile-card-bytes)
        (incf index)
        (when (>= page-start obj-end) (return))
        (setf (deref varyobj-page-scan-start-offset index)
              (ash (- page-end addr) (- (1+ word-shift))))))
     #!+immobile-space-debug ; "address sanitizer"
     (awhen *in-use-bits* (mark-range it addr n-bytes t))
     (setf (sap-ref-word (int-sap addr) 0) word0
           (sap-ref-word (int-sap addr) n-word-bytes) word1)
     ;; 0-fill the remainder of the object
     (#!+64-bit system-area-ub64-fill
      #!-64-bit system-area-ub32-fill
      0 (int-sap addr) 2 (- (ash n-bytes (- word-shift)) 2))
     (%make-lisp-obj (logior addr lowtag)))))

(defun allocate-immobile-vector (widetag length words)
  (allocate-immobile-bytes (pad-data-block (+ words vector-data-offset))
                           widetag
                           (fixnumize length)
                           other-pointer-lowtag))

(defun allocate-immobile-simple-vector (n-elements)
  (allocate-immobile-vector simple-vector-widetag n-elements n-elements))
(defun allocate-immobile-bit-vector (n-elements)
  (allocate-immobile-vector simple-bit-vector-widetag n-elements
                            (ceiling n-elements n-word-bits)))
(defun allocate-immobile-byte-vector (n-elements)
  (allocate-immobile-vector simple-array-unsigned-byte-8-widetag n-elements
                            (ceiling n-elements n-word-bytes)))
(defun allocate-immobile-word-vector (n-elements)
  (allocate-immobile-vector #!+64-bit simple-array-unsigned-byte-64-widetag
                            #!-64-bit simple-array-unsigned-byte-32-widetag
                            n-elements n-elements))

;;; This is called when we're already inside WITHOUT-GCing
(defun allocate-immobile-code (n-boxed-words n-unboxed-bytes)
  (let* ((unrounded-header-n-words (+ code-constants-offset n-boxed-words))
         (rounded-header-words (* 2 (ceiling unrounded-header-n-words 2)))
         (total-bytes (+ (* rounded-header-words n-word-bytes)
                         (logandc2 (+ n-unboxed-bytes lowtag-mask) lowtag-mask)))
         (code (allocate-immobile-bytes
                total-bytes
                (logior (ash rounded-header-words n-widetag-bits) code-header-widetag)
                (ash n-unboxed-bytes n-fixnum-tag-bits)
                other-pointer-lowtag)))
    (setf (%code-debug-info code) nil)
    code))
) ; end PROGN
