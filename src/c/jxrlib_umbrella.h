// jxrlib_umbrella.h — single translation unit for `addTranslateC` in build.zig.
//
// Pulls in the 4creators/jxrlib public headers needed by jxc. Anything not
// reachable from this umbrella is intentionally not exposed to Zig.
//
// On MinGW/MSVC, <wchar.h> declares wcscat_s / wcscpy_s / etc. for every TU
// that pulls in <windows.h>. jxrlib doesn't call them, but `translate-c`
// still generates bindings for the declarations — and Zig 0.16 errors on the
// resulting `extern_local_wcscat_s`-style unused local constants in
// ReleaseSafe mode. Define `__STDC_WANT_SECURE_LIB__` to 0 *before* any
// system header is pulled in to suppress those declarations.

#ifndef JXC_JXRLIB_UMBRELLA_H_
#define JXC_JXRLIB_UMBRELLA_H_

#if defined(_WIN32) && !defined(__STDC_WANT_SECURE_LIB__)
#  define __STDC_WANT_SECURE_LIB__ 0
#endif

#include <JXRGlue.h>
#include <JXRMeta.h>

#endif // JXC_JXRLIB_UMBRELLA_H_