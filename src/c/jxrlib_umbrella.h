// jxrlib_umbrella.h — single translation unit for `addTranslateC` in build.zig.
//
// Pulls in the 4creators/jxrlib public headers needed by jxc. Anything not
// reachable from this umbrella is intentionally not exposed to Zig.
//
// On Windows, <wchar.h> / <string.h> transitively pulled in by the jxrlib
// headers declare C11 Annex-K "secure" functions (wcscat_s, wcscpy_s, …).
// jxrlib doesn't call them, but `translate-c` emits an `extern_local_X`
// wrapper struct for every declared function. Zig 0.16 in ReleaseSafe errors
// on those wrappers as "unused local constant"s. We can't suppress them at
// the preprocessor level (MinGW UCRT ignores __STDC_WANT_*_LIB_* flags), so
// we instead reference them from an `export fn`. The exported dummy keeps
// the wrappers referenced in the generated Zig, while the linker strips any
// references to it (nothing in jxc calls the dummy).

#ifndef JXC_JXRLIB_UMBRELLA_H_
#define JXC_JXRLIB_UMBRELLA_H_

#include <JXRGlue.h>
#include <JXRMeta.h>

#if defined(_WIN32) && !defined(JXC_UMBRELLA_NO_WCS_USED)
/* Reference the secure-* functions so translate-c emits used (not
 * unused-local) bindings. The function body is never actually executed
 * at runtime. */
#  ifdef _MSC_VER
#    define JXC_EXPORT __declspec(dllexport)
#  else
#    define JXC_EXPORT __attribute__((dllexport))
#  endif
JXC_EXPORT void jxc_unused_wcs(void) {
    (void)wcscat_s((wchar_t *)0, (rsize_t)0, (const wchar_t *)0);
    (void)wcscpy_s((wchar_t *)0, (rsize_t)0, (const wchar_t *)0);
}
#endif

#endif // JXC_JXRLIB_UMBRELLA_H_