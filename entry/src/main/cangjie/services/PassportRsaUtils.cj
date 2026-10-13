package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog
import std.io.{ByteBuffer, SeekPosition}
import stdx.crypto.keys.*
import stdx.crypto.digest.*

/**
 * PassportRsaUtils — RSA-OAEP encryption for Telegram Passport credentials secret
 *
 * iOS: MTRsaEncryptPKCS1OAEP(encryptionProvider, botPublicKeyPem, credentialsSecret)
 * Uses stdx.crypto.keys.RSAPublicKey.decodeFromPem + OAEP(OAEPOption(SHA1(), SHA1()))
 *
 * This file is kept separate from PassportService.cj to avoid SHA1/SHA256 name collision
 * with ohos_app_cangjie_entry.core.mtproto.CryptoUtils custom static classes.
 */

/**
 * passportRsaOaepEncrypt — encrypt data (32 bytes credential secret) with bot PEM public key
 *
 * Uses RSA-OAEP with SHA1 as hash and SHA1 as MGF1 hash,
 * matching iOS OpenSSL RSA_PKCS1_OAEP_PADDING default (MGF1=SHA1).
 *
 * Returns encrypted bytes on success, empty array on failure.
 */
public func passportRsaOaepEncrypt(pemKey: String, data: Array<Byte>): Array<Byte> {
    try {
        let pubKey = RSAPublicKey.decodeFromPem(pemKey)
        let sha1Inst = SHA1()
        let sha1MgfInst = SHA1()
        let encOpt = OAEPOption(sha1Inst, sha1MgfInst)
        let inputBuf = ByteBuffer(data)
        let outputBuf = ByteBuffer()
        pubKey.encrypt(inputBuf, outputBuf, padType: OAEP(encOpt))
        // Seek to start before reading, then use bytes() to get all written content
        let _ = outputBuf.seek(SeekPosition.Begin(0))
        let result = outputBuf.bytes()
        return result
    } catch (e: Exception) {
        Hilog.warn(0, "CjTelegram", "[Passport] rsaOaepEncrypt exception")
        return Array<Byte>(0, repeat: 0)
    }
}
