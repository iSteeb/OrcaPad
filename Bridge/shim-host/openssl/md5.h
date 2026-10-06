#pragma once
// OrcaPad host-build adapter: openssl/md5.h surface for the Linux host test
// build. The iOS/Darwin build maps this header onto CommonCrypto
// (Bridge/shim/openssl/md5.h); the host toolchain has neither, so this is a
// self-contained RFC 1321 implementation. Nothing in the linked engine
// closure invokes MD5_* (only utils.cpp does, which is not compiled), but a
// shim must be real, not a fake: Bridge/tools/contract_tests.cpp verifies
// known digests.
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#define MD5_DIGEST_LENGTH 16

struct MD5_CTX {
    uint32_t state[4];
    uint32_t count[2];
    unsigned char buffer[64];
};

namespace orcapad_md5 {

inline uint32_t left_rotate(uint32_t value, uint32_t bits) {
    return (value << bits) | (value >> (32 - bits));
}

// RFC 1321: K[i] = floor(abs(sin(i + 1)) * 2^32), computed once.
inline const uint32_t *round_constants() {
    static uint32_t table[64];
    static bool ready = false;
    if (!ready) {
        for (uint32_t index = 0; index < 64; ++index) {
            double sine = std::sin(static_cast<double>(index) + 1.0);
            if (sine < 0.0) sine = -sine;
            table[index] = static_cast<uint32_t>(sine * 4294967296.0);
        }
        ready = true;
    }
    return table;
}

inline void transform(MD5_CTX *ctx, const unsigned char block[64]) {
    uint32_t message[16];
    std::memcpy(message, block, 64);

    static const uint32_t shifts[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    const uint32_t *constants = round_constants();

    uint32_t a = ctx->state[0];
    uint32_t b = ctx->state[1];
    uint32_t c = ctx->state[2];
    uint32_t d = ctx->state[3];

    for (uint32_t index = 0; index < 64; ++index) {
        uint32_t f;
        uint32_t g;
        if (index < 16) {
            f = (b & c) | (~b & d);
            g = index;
        } else if (index < 32) {
            f = (d & b) | (~d & c);
            g = (5 * index + 1) % 16;
        } else if (index < 48) {
            f = b ^ c ^ d;
            g = (3 * index + 5) % 16;
        } else {
            f = c ^ (b | ~d);
            g = (7 * index) % 16;
        }
        const uint32_t temporary = d;
        d = c;
        c = b;
        b = b + left_rotate(
                     a + f + constants[index] + message[g],
                     shifts[index]);
        a = temporary;
    }

    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
}

} // namespace orcapad_md5

inline int MD5_Init(MD5_CTX *ctx) {
    if (!ctx) return 0;
    ctx->state[0] = 0x67452301u;
    ctx->state[1] = 0xefcdab89u;
    ctx->state[2] = 0x98badcfeu;
    ctx->state[3] = 0x10325476u;
    ctx->count[0] = 0;
    ctx->count[1] = 0;
    return 1;
}

inline int MD5_Update(MD5_CTX *ctx, const void *data, size_t length) {
    if (!ctx || (!data && length > 0)) return 0;
    const unsigned char *input = static_cast<const unsigned char *>(data);
    const size_t block_size = 64;
    size_t index = (ctx->count[0] >> 3) % block_size;
    const uint32_t bit_count_low =
        static_cast<uint32_t>(length) << 3;
    const uint32_t bit_count_high =
        static_cast<uint32_t>(length >> 29);
    ctx->count[0] += bit_count_low;
    if (ctx->count[0] < bit_count_low) ++ctx->count[1];
    ctx->count[1] += bit_count_high;

    size_t part = block_size - index;
    if (length >= part) {
        std::memcpy(ctx->buffer + index, input, part);
        orcapad_md5::transform(ctx, ctx->buffer);
        size_t offset = part;
        for (; offset + block_size <= length; offset += block_size)
            orcapad_md5::transform(
                ctx, input + offset);
        index = 0;
        std::memcpy(ctx->buffer, input + offset, length - offset);
    } else {
        std::memcpy(ctx->buffer + index, input, length);
    }
    return 1;
}

inline int MD5_Final(unsigned char *digest, MD5_CTX *ctx) {
    if (!digest || !ctx) return 0;
    // RFC 1321: append 0x80 + zeros + the ORIGINAL 64-bit bit length —
    // the length must be snapshotted BEFORE the padding update mutates count.
    static const unsigned char padding[64] = { 0x80 };
    const uint32_t count_low = ctx->count[0];
    const uint32_t count_high = ctx->count[1];
    const size_t block_size = 64;
    size_t index = (count_low >> 3) % block_size;
    const size_t pad_length =
        (index < 56) ? (56 - index) : (120 - index);
    MD5_Update(ctx, padding, pad_length);
    unsigned char bits[8];
    const uint32_t counts[2] = { count_low, count_high };
    for (int byte = 0; byte < 8; ++byte)
        bits[byte] = static_cast<unsigned char>(
            (counts[byte >> 2] >> ((byte & 3) * 8)) & 0xffu);
    MD5_Update(ctx, bits, 8);
    for (int word = 0; word < 4; ++word)
        for (int byte = 0; byte < 4; ++byte)
            digest[word * 4 + byte] = static_cast<unsigned char>(
                (ctx->state[word] >> (8 * byte)) & 0xffu);
    return 1;
}

inline unsigned char *MD5(const unsigned char *data, size_t length,
                          unsigned char *digest) {
    if (!data || !digest) return nullptr;
    MD5_CTX ctx;
    if (!MD5_Init(&ctx)) return nullptr;
    if (!MD5_Update(&ctx, data, length)) return nullptr;
    if (!MD5_Final(digest, &ctx)) return nullptr;
    return digest;
}
