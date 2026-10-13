// MTProto 加解密原生加速：AES-256-IGE + SHA-256/SHA-1（OpenSSL libcrypto，复用 tgcalls_ohos 预编译静态库）。
// 此前 core/mtproto/CryptoUtils.cj 是纯仓颉实现：每 16 字节块重做一次 key expansion 并分配临时数组，
// 512 KB 上传分片要几秒 CPU + GC 风暴（真机 2026-09-11：4 个分片并发 10 s，堆每 200 ms 分配 30–60 MB）。
// 仓颉侧经 dlopen("libtg_media.so") + dlsym 调用（NativeCrypto.cj），找不到符号时退回纯仓颉实现。
#include <openssl/aes.h>
#include <openssl/sha.h>
#include <cstdint>
#include <cstring>

#define TG_EXPORT extern "C" __attribute__((visibility("default")))

TG_EXPORT int tg_crypto_ping() { return 1; }

// IGE：c_i = E(p_i ^ c_{i-1}) ^ p_{i-1}，c_{-1} = iv[0:16]，p_{-1} = iv[16:32]（Telegram 约定，与 AESIGE.encrypt 一致）
TG_EXPORT int tg_aes_ige_encrypt(const uint8_t* key, const uint8_t* iv, const uint8_t* in, uint8_t* out, size_t len) {
    if (len % 16 != 0 || !key || !iv || !in || !out) return -1;
    AES_KEY k;
    if (AES_set_encrypt_key(key, 256, &k) != 0) return -2;
    uint8_t cp[16], pp[16], t[16];
    memcpy(cp, iv, 16);
    memcpy(pp, iv + 16, 16);
    for (size_t i = 0; i < len; i += 16) {
        for (int j = 0; j < 16; j++) t[j] = in[i + j] ^ cp[j];
        AES_encrypt(t, t, &k);
        for (int j = 0; j < 16; j++) t[j] ^= pp[j];
        memcpy(pp, in + i, 16);
        memcpy(cp, t, 16);
        memcpy(out + i, t, 16);
    }
    return 0;
}

// p_i = D(c_i ^ p_{i-1}) ^ c_{i-1}
TG_EXPORT int tg_aes_ige_decrypt(const uint8_t* key, const uint8_t* iv, const uint8_t* in, uint8_t* out, size_t len) {
    if (len % 16 != 0 || !key || !iv || !in || !out) return -1;
    AES_KEY k;
    if (AES_set_decrypt_key(key, 256, &k) != 0) return -2;
    uint8_t cp[16], pp[16], t[16], cur[16];
    memcpy(cp, iv, 16);
    memcpy(pp, iv + 16, 16);
    for (size_t i = 0; i < len; i += 16) {
        memcpy(cur, in + i, 16);
        for (int j = 0; j < 16; j++) t[j] = cur[j] ^ pp[j];
        AES_decrypt(t, t, &k);
        for (int j = 0; j < 16; j++) t[j] ^= cp[j];
        memcpy(cp, cur, 16);
        memcpy(pp, t, 16);
        memcpy(out + i, t, 16);
    }
    return 0;
}

TG_EXPORT void tg_sha256(const uint8_t* in, size_t len, uint8_t* out) { SHA256(in, len, out); }
TG_EXPORT void tg_sha1(const uint8_t* in, size_t len, uint8_t* out) { SHA1(in, len, out); }
