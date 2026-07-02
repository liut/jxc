// jxrlib_umbrella.h — single translation unit for `addTranslateC` in build.zig.
//
// Pulls in the 4creators/jxrlib public headers needed by jxc. Anything not
// reachable from this umbrella is intentionally not exposed to Zig.
//
// On Windows the full jxrlib headers pull in <windows.h> / <wchar.h> / etc.,
// which in turn declare C11 Annex-K "secure" functions (wcscat_s, …). jxrlib
// itself does not call them, but `translate-c` emits wrapper structs that
// Zig 0.16 in ReleaseSafe reports as "unused local constant". Skipping the
// full headers and using a minimal hand-rolled subset avoids all of that.

#ifndef JXC_JXRLIB_UMBRELLA_H_
#define JXC_JXRLIB_UMBRELLA_H_

#ifdef _WIN32
#  include "jxrlib_minimal.h"
#else
#  include <JXRGlue.h>
#  include <JXRMeta.h>
#endif

#endif // JXC_JXRLIB_UMBRELLA_H_