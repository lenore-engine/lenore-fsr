// Force-included into every FidelityFX host source: the Microsoft CRT names
// the upstream code uses outside its `_WIN32` branches, given their meaning on
// a POSIX libc.
#pragma once

#include <stddef.h>
#include <wchar.h>

// `ffx_message.cpp` reaches `FFX_UNUSED` without including the header that
// defines it.
#include <FidelityFX/host/ffx_util.h>

#define _countof(a) (sizeof(a) / sizeof((a)[0]))

// The array form is the only one upstream calls: labels and binding names into
// fixed-size name arrays. It truncates instead of reporting because no call
// site reads the result.
template <size_t N>
static inline int wcscpy_s(wchar_t (&dst)[N], const wchar_t* src)
{
    static_assert(N > 0, "wcscpy_s into an empty array");
    size_t i = 0;
    for (; i + 1 < N && src[i]; ++i) dst[i] = src[i];
    dst[i] = 0;
    return 0;
}
