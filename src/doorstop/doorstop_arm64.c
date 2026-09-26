/* Build wrapper for BSIPA's Doorstop on Windows ARM64 (llvm-mingw, -nostdlib).
 * Doorstop ships its own mini CRT (crt.h) whose signatures clash with the mingw
 * headers, so include the system headers first, then rename Doorstop's helpers.
 * The real mem* symbols for compiler-generated calls come from compat.c. */
#include <windows.h>
#include <shlwapi.h>
#include <intrin.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#undef EXIT_FAILURE
#define EXIT_FAILURE doorstop_exit_failure /* config.h also declares a local of that name */
static const int doorstop_exit_failure = 1;
#define memset doorstop_memset
#define memcpy doorstop_memcpy
#define wmemcpy doorstop_wmemcpy
#define wmemset doorstop_wmemset
#define wcslen doorstop_wcslen
#include "main.c"
