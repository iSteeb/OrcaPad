// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: the subset of boost.beast's base64 detail API used
// by GCode.cpp (encoded_size / encode). Standard base64 alphabet, padded.
#include <cstddef>
#include <cstdint>

namespace boost { namespace beast { namespace detail { namespace base64 {

inline std::size_t encoded_size(std::size_t n) {
    return 4 * ((n + 2) / 3);
}

inline std::size_t encode(void *dest, const void *src, std::size_t n) {
    static const char *tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *s = static_cast<const uint8_t *>(src);
    char *d = static_cast<char *>(dest);
    std::size_t i = 0, o = 0;
    while (i + 2 < n) {
        uint32_t v = (uint32_t(s[i]) << 16) | (uint32_t(s[i+1]) << 8) | s[i+2];
        d[o++] = tbl[(v >> 18) & 63]; d[o++] = tbl[(v >> 12) & 63];
        d[o++] = tbl[(v >> 6) & 63];  d[o++] = tbl[v & 63];
        i += 3;
    }
    if (i + 1 == n) {
        uint32_t v = uint32_t(s[i]) << 16;
        d[o++] = tbl[(v >> 18) & 63]; d[o++] = tbl[(v >> 12) & 63];
        d[o++] = '='; d[o++] = '=';
    } else if (i + 2 == n) {
        uint32_t v = (uint32_t(s[i]) << 16) | (uint32_t(s[i+1]) << 8);
        d[o++] = tbl[(v >> 18) & 63]; d[o++] = tbl[(v >> 12) & 63];
        d[o++] = tbl[(v >> 6) & 63];  d[o++] = '=';
    }
    return o;
}

}}}} // namespace boost::beast::detail::base64
