#!/bin/sh
set -em

# --load argument skips compilation.
#
# This is a script to be run as part of make.sh. The only time you'd
# want to run it by itself is if you're trying to cross-compile the
# system or if you're doing some kind of troubleshooting.

# This software is part of the SBCL system. See the README file for
# more information.
#
# This software is derived from the CMU CL system, which was
# written at Carnegie Mellon University and released into the
# public domain. The software is in the public domain and is
# provided with absolutely no warranty. See the COPYING and CREDITS
# files for more information.

echo //entering make-target-2.sh

LANG=C
LC_ALL=C
export LANG LC_ALL

# Load our build configuration
. output/build-config

if [ -n "$SBCL_HOST_LOCATION" ]; then
    echo //copying host-2 files to target
    rsync -a "$SBCL_HOST_LOCATION/output/" output/
fi

# Do warm init stuff, e.g. building and loading CLOS, and stuff which
# can't be done until CLOS is running.
#
# Note that it's normal for the newborn system to think rather hard at
# the beginning of this process (e.g. using nearly 100Mb of virtual memory
# and >30 seconds of CPU time on a 450MHz CPU), and unless you built the
# system with the :SB-SHOW feature enabled, it does it rather silently,
# without trying to tell you about what it's doing. So unless it hangs
# for much longer than that, don't worry, it's likely to be normal.
if [ "$1" != --load ]; then
    echo //doing warm init - compilation phase
    echo '(load "loader.lisp") (load-sbcl-file "src/cold/warm.lisp")' | \
    ./src/runtime/sbcl \
        --core output/cold-sbcl.core \
        --lose-on-corruption \
        --no-sysinit --no-userinit
fi
echo //doing warm init - load and dump phase
echo '(load "loader.lisp") (load-sbcl-file "make-target-2-load.lisp" nil)
#+gencgc(setf (extern-alien "gc_coalesce_string_literals" char) 2)
(sb-ext:save-lisp-and-die "output/sbcl.core")' | \
./src/runtime/sbcl \
--core output/cold-sbcl.core \
--lose-on-corruption \
--no-sysinit --no-userinit

echo //checking for leftover cold-init symbols
./src/runtime/sbcl \
--core output/sbcl.core \
--lose-on-corruption \
--noinform \
--no-sysinit --no-userinit \
--eval '(restart-case
      (let (l)
        (sb-vm::map-allocated-objects
         (lambda (obj type size)
           (declare (ignore type size))
           (when (and (symbolp obj) (not (symbol-package obj))
                      (search "!" (string obj)))
             (push obj l)))
         :all)
        (format t "Found ~D:~%~S~%" (length l) l))
    (abort ()
      :report "Abort building SBCL."
      (sb-ext:exit :code 1)))' \
--quit
