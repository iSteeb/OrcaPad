#pragma once
// OrcaPad adapter shim: OpenSSL MD5 surface mapped onto Darwin CommonCrypto
// (ships in the iOS SDK — no libcrypto build needed for the core subset).
#include <CommonCrypto/CommonDigest.h>
#include <cstddef>

#define MD5_DIGEST_LENGTH CC_MD5_DIGEST_LENGTH

using MD5_CTX = CC_MD5_CTX;

inline int MD5_Init(MD5_CTX *c) { return CC_MD5_Init(c); }
inline int MD5_Update(MD5_CTX *c, const void *data, size_t n) { return CC_MD5_Update(c, data, (CC_LONG)n); }
inline int MD5_Final(unsigned char *md, MD5_CTX *c) { return CC_MD5_Final(md, c); }

inline unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md) {
    return CC_MD5(d, (CC_LONG)n, md);
}
