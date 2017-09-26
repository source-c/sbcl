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

(in-package "CL-USER")

;;; In sbcl-0.6.9 FOO-NAMESTRING functions  returned "" instead of NIL.
(with-test (:name (file-namestring directory-namestring :name))
  (let ((pathname0 (make-pathname :host nil
                                  :directory
                                  (pathname-directory
                                   *default-pathname-defaults*)
                                  :name "getty"))
        (pathname1 (make-pathname :host nil
                                  :directory nil
                                  :name nil)))
    (assert (equal (file-namestring pathname0) "getty"))
    (assert (equal (directory-namestring pathname0)
                   (directory-namestring *default-pathname-defaults*)))
    (assert (equal (file-namestring pathname1) ""))
    (assert (equal (directory-namestring pathname1) ""))))

;;; In sbcl-0.6.9 DIRECTORY failed on paths with :WILD or
;;; :WILD-INFERIORS in their directory components.
(with-test (:name (directory :wild-inferiors))
  (let ((dir (directory "../**/*.*")))
    ;; We know a little bit about the structure of this result;
    ;; let's test to make sure that this test file is in it.
    (assert (find-if (lambda (pathname)
                       (search "tests/filesys.pure.lisp"
                               (namestring pathname)))
                     dir))))
;;; In sbcl-0.9.7 DIRECTORY failed on pathnames with character-set
;;; components.
(with-test (:name (directory :character-set :pattern) )
  (let ((dir (directory "[f]*.*")))
    ;; We know a little bit about the structure of this result;
    ;; let's test to make sure that this test file is in it.
    (assert (find-if (lambda (pathname)
                       (search "filesys.pure.lisp"
                               (namestring pathname)))
                     dir))))

;;; Set *default-pathname-defaults* to something other than the unix
;;; cwd, to catch functions which access the filesystem without
;;; merging properly.  We should test more functions than just OPEN
;;; here, of course

(with-test (:name (open *default-pathname-defaults*))
  (let ((*default-pathname-defaults*
         (make-pathname :directory
                        (butlast
                         (pathname-directory *default-pathname-defaults*))
                        :defaults *default-pathname-defaults*)))
    ;; SBCL 0.7.1.2 failed to merge on OPEN
    (with-open-file (i "tests/filesys.pure.lisp")
      (assert i))))

;;; OPEN, LOAD and friends should signal an error of type FILE-ERROR
;;; if they are fed wild pathname designators; firstly, with wild
;;; pathnames that don't correspond to any files:
(with-test (:name (open :wild file-error 1))
  (assert (typep (nth-value 1 (ignore-errors (open "non-existent*.lisp")))
                 'file-error)))
(with-test (:name (load :wild file-error 1))
  (assert (typep (nth-value 1 (ignore-errors (load "non-existent*.lisp")))
                 'file-error)))
;;; then for pathnames that correspond to precisely one:
(with-test (:name (open :wild file-error 2))
  (assert (typep (nth-value 1 (ignore-errors (open "filesys.pur*.lisp")))
                 'file-error)))
(with-test (:name (load :wild file-error 2))
  (assert (typep (nth-value 1 (ignore-errors (load "filesys.pur*.lisp")))
                 'file-error)))
;;; then for pathnames corresponding to many:
(with-test (:name (open :wild file-error 3))
  (assert (typep (nth-value 1 (ignore-errors (open "*.lisp")))
                 'file-error)))
(with-test (:name (load :wild file-error 3))
  (assert (typep (nth-value 1 (ignore-errors (load "*.lisp")))
                 'file-error)))

;;; ANSI: FILE-LENGTH should signal an error of type TYPE-ERROR if
;;; STREAM is not a stream associated with a file.
;;;
;;; (Peter Van Eynde's ansi-test suite caught this, and Eric Marsden
;;; reported a fix for CMU CL, which was ported to sbcl-0.6.12.35.)
(with-test (:name (file-length *terminal-io* type-error))
  (assert (typep (nth-value 1 (ignore-errors (file-length *terminal-io*)))
                 'type-error)))

;;; A few cases Windows does have enough marbles to pass right now
(with-test (:name (sb-ext:native-namestring :win32)
                  :skipped-on '(not :win32))
  (assert (equal "C:\\FOO" (native-namestring "C:\\FOO")))
  (assert (equal "C:\\FOO" (native-namestring "C:/FOO")))
  (assert (equal "C:\\FOO\\BAR" (native-namestring "C:\\FOO\\BAR")))
  (assert (equal "C:\\FOO\\BAR" (native-namestring "C:\\FOO\\BAR\\" :as-file t))))

(with-test (:name (sb-ext:parse-native-namestring :as-directory :junk-allowed))
  (assert
   (equal
    (parse-native-namestring "foo.lisp" nil *default-pathname-defaults*
                             :as-directory t)
    (parse-native-namestring "foo.lisp" nil *default-pathname-defaults*
                             :as-directory t
                             :junk-allowed t))))

;;; Test for NATIVE-PATHNAME / NATIVE-NAMESTRING stuff
;;;
;;; given only safe characters in the namestring, NATIVE-PATHNAME will
;;; never error, and NATIVE-NAMESTRING on the result will return the
;;; original namestring.
(with-test (:name (sb-ext:native-namestring sb-ext:native-pathname :random))
  (let ((safe-chars
         (coerce
          (cons #\Newline
                (loop for x from 32 to 127 collect (code-char x)))
          'simple-base-string))
        (tricky-sequences #("/../" "../" "/.." "." "/." "./" "/./"
                            "[]" "*" "**" "/**" "**/" "/**/" "?"
                            "\\*" "\\[]" "\\?" "\\*\\*" "*\\*")))
   (labels ((canon (s)
              #+win32
              ;; We canonicalize to \ as the directory separator
              ;; on windows -- though both \ and / are legal.
              (substitute #\\ #\/ s)
              #+unix
              ;; Consecutive separators become a single separator
              (let ((p (search "//" s)))
                (if p
                    (canon (concatenate 'string (subseq s 0 p) (subseq s (1+ p))))
                    s))))
    (loop repeat 1000
          for length = (random 32)
          for native-namestring = (coerce
                                   (loop repeat length
                                         collect
                                         (char safe-chars
                                               (random (length safe-chars))))
                                   'simple-base-string)
          for pathname = (native-pathname native-namestring)
          for nnn = (native-namestring pathname)
          do (setf native-namestring (canon native-namestring))
             (unless (string= nnn native-namestring)
               (error "1: wanted ~S, got ~S" native-namestring nnn)))
    (loop repeat 1000
          for native-namestring = (with-output-to-string (s)
                                    (write-string "mu" s)
                                    (loop
                                      (let ((r (random 1.0)))
                                        (cond
                                          ((< r 1/20) (return))
                                          ((< r 1/2)
                                           (write-char
                                            (char safe-chars
                                                  (random (length safe-chars)))
                                            s))
                                          (t (write-string
                                              (aref tricky-sequences
                                                    (random
                                                     (length tricky-sequences)))
                                              s))))))
          for pathname = (native-pathname native-namestring)
          for tricky-nnn = (native-namestring pathname)
          do (setf native-namestring (canon native-namestring))
             (unless (string= tricky-nnn native-namestring)
               (error "2: wanted ~S, got ~S" native-namestring tricky-nnn))))))

;;; USER-HOMEDIR-PATHNAME and the extension SBCL-HOMEDIR-PATHNAME both
;;; used to call PARSE-NATIVE-NAMESTRING without supplying a HOST
;;; argument, and so would lose when *DEFAULT-PATHNAME-DEFAULTS* was a
;;; logical pathname.
(with-test (:name (user-homedir-pathname :robustness))
  (let ((*default-pathname-defaults* (pathname "SYS:")))
    (assert (not (typep (user-homedir-pathname)
                        'logical-pathname)))))

(with-test (:name (sb-int:sbcl-homedir-pathname :robustness))
  (let ((*default-pathname-defaults* (pathname "SYS:")))
    (assert (not (typep (sb-int:sbcl-homedir-pathname)
                        'logical-pathname)))))

(with-test (:name (file-author stringp))
  #-win32
  (assert (stringp (file-author (user-homedir-pathname))))
  #+win32
  (assert (not (file-author (user-homedir-pathname)))))
(with-test (:name (file-write-date integerp))
  (assert (integerp (file-write-date (user-homedir-pathname)))))

;;; Canonicalization of pathnames for DIRECTORY
(with-test (:name (directory :/.))
  (assert (equal (directory #p".") (directory #p"./")))
  (assert (equal (directory #p".") (directory #p""))))
(with-test (:name (directory :/..))
  (assert (equal (directory #p"..") (directory #p"../"))))
(with-test (:name (directory :unspecific))
  (assert (equal (directory #p".")
                 (directory (make-pathname
                             :name :unspecific
                             :type :unspecific)))))

;;; This used to signal a TYPE-ERROR.
(with-test (:name (directory :..*))
  (directory "somedir/..*"))

;;; DIRECTORY used to treat */** as **.
(with-test (:name (directory :*/**))
  (assert (equal (directory "*/**/*.*")
                 (mapcan (lambda (directory)
                           (directory (merge-pathnames "**/*.*" directory)))
                         (directory "*/")))))

;;; Generated with
;;; (loop for exist in '(nil t)
;;;       append
;;;       (loop for (if-exists if-does-not-exist) in '((nil :error)
;;;                                                    (:error nil)
;;;                                                    (nil nil)
;;;                                                    (:error :error))
;;;             collect (list 'do-open exist if-exists if-does-not-exist)))
(with-test (:name (open :never-openning))
  (flet ((do-open (existing if-exists if-does-not-exist
                   &optional (direction :output))
           (open (if existing
                     #.(or *compile-file-truename* *load-truename*)
                     "a-really-non-existing-file")
                 :direction direction
                 :if-exists if-exists :if-does-not-exist if-does-not-exist)))
    (assert-error
     (do-open nil nil :error))
    (assert (not
             (do-open nil :error nil)))
    (assert (not
             (do-open t nil :error)))
    (assert-error
     (do-open t :error nil))
    (assert (not
             (do-open nil nil nil)))
    (assert-error
     (do-open nil :error :error))
    (assert (not
             (do-open t nil nil)))
    (assert-error (do-open t :error :error))

    (assert-error
     (do-open nil nil :error :io))
    (assert (not
             (do-open nil :error nil :io)))
    (assert (not
             (do-open t nil :error :io)))
    (assert-error
     (do-open t :error nil :io))
    (assert (not
             (do-open nil nil nil :io)))
    (assert-error
     (do-open nil :error :error :io))
    (assert (not
             (do-open t nil nil :io)))
    (assert-error (do-open t :error :error :io))))

(with-test (:name (open :new-version))
  (multiple-value-bind (value error)
      (ignore-errors (open #.(or *compile-file-truename* *load-truename*)
                           :direction :output
                           :if-exists :new-version))
    (assert (not value))
    (assert error)
    (assert (equal (simple-condition-format-control error)
                   "OPEN :IF-EXISTS :NEW-VERSION is not supported ~
                            when a new version must be created."))))

(with-test (:name :parse-native-namestring-canon :skipped-on '(not :unix))
  (let ((pathname (parse-native-namestring "foo/bar//baz")))
    (assert (string= (car (last (pathname-directory pathname))) "bar"))))
