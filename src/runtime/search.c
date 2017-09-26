/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#include <string.h>

#include "sbcl.h"
#include "runtime.h"
#include "os.h"
#include "search.h"
#include "thread.h"
#include "gc-internal.h"
#include "genesis/primitive-objects.h"

boolean search_for_type(int type, lispobj **start, int *count)
{
    lispobj obj;

    while ((*count == -1 || (*count > 0)) &&
           gc_managed_addr_p((lispobj)*start)) {
        obj = **start;
        if (*count != -1)
            *count -= 2;

        if (widetag_of(obj) == type)
            return 1;

        (*start) += 2;
    }
    return 0;
}

static int __attribute__((unused)) strcmp_ucs4_ascii(uint32_t* a, char* b)
{
  int i = 0;

  // Lisp terminates UCS4 strings with NULL bytes - probably to no avail
  // since null-terminated UCS4 isn't a common convention for any foreign ABI -
  // but length has been pre-checked, so hitting an ASCII null is a win.
  while (a[i] == ((unsigned char*)b)[i])
    if (b[i] == 0)
      return 0;
    else
      ++i;
  return a[i] - b[i]; // same return convention as strcmp()
}

lispobj* search_for_symbol(char *name, lispobj start, lispobj end)
{
    lispobj* where = (lispobj*)start;
    lispobj* limit = (lispobj*)end;
    struct symbol *symbol;
    lispobj namelen = make_fixnum(strlen(name));

    while (where < limit) {
        lispobj word = *where;
        if (widetag_of(word) == SYMBOL_WIDETAG &&
            lowtag_of((symbol = (struct symbol *)where)->name) == OTHER_POINTER_LOWTAG) {
            struct vector *symbol_name = VECTOR(symbol->name);
            if (gc_managed_addr_p((lispobj)symbol_name) &&
                ((widetag_of(symbol_name->header) == SIMPLE_BASE_STRING_WIDETAG
                  && symbol_name->length == namelen
                  && !strcmp((char *)symbol_name->data, name))
#ifdef LISP_FEATURE_SB_UNICODE
                 || (widetag_of(symbol_name->header) == SIMPLE_CHARACTER_STRING_WIDETAG
                     && symbol_name->length == namelen
                     && !strcmp_ucs4_ascii((uint32_t*)symbol_name->data, name))
#endif
                 ))
                return where;
        }
        where += OBJECT_SIZE(word, where);
    }
    return 0;
}
