# OHOS port: CMake wrapper for the Chromium-vendored libsrtp (2.2.0-pre, BUILD.gn only).
# Source list + defines transcribed 1:1 from third_party/libsrtp/BUILD.gn.
# The vendored tree ships no CMakeLists; this file is ours (added by the HarmonyOS port).
#
# BORINGSSL_INCLUDE must point at the BoringSSL headers in third_party/prebuilt/include
# (set by voip/CMakeLists.txt) -- system OpenSSL must never be picked up.
cmake_minimum_required(VERSION 3.10)
project(libsrtp2 C)

if(NOT DEFINED BORINGSSL_INCLUDE)
  message(FATAL_ERROR "Pass -DBORINGSSL_INCLUDE=<skeleton out/include> (boringssl headers)")
endif()
if(NOT EXISTS "${BORINGSSL_INCLUDE}/openssl/evp.h")
  message(FATAL_ERROR "BORINGSSL_INCLUDE=${BORINGSSL_INCLUDE} does not contain openssl/evp.h")
endif()

add_compile_definitions(
  PACKAGE_STRING="libsrtp2_2.1.0-pre"
  PACKAGE_VERSION="2.1.0-pre"
  HAVE_CONFIG_H
  OPENSSL
  HAVE_STDLIB_H HAVE_STRING_H HAVE_STDINT_H HAVE_INTTYPES_H
  HAVE_INT16_T HAVE_INT32_T HAVE_INT8_T
  HAVE_UINT16_T HAVE_UINT32_T HAVE_UINT64_T HAVE_UINT8_T
  # posix branch of BUILD.gn
  HAVE_ARPA_INET_H HAVE_NETINET_IN_H HAVE_SYS_TYPES_H HAVE_UNISTD_H
)

include_directories(
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/config
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${CMAKE_CURRENT_SOURCE_DIR}/crypto/include
  ${BORINGSSL_INCLUDE}
)

add_library(srtp2 STATIC
  crypto/cipher/aes_gcm_ossl.c
  crypto/cipher/aes_icm_ossl.c
  crypto/cipher/cipher.c
  crypto/cipher/null_cipher.c
  crypto/hash/auth.c
  crypto/hash/hmac_ossl.c
  crypto/hash/null_auth.c
  crypto/kernel/alloc.c
  crypto/kernel/crypto_kernel.c
  crypto/kernel/err.c
  crypto/kernel/key.c
  crypto/math/datatypes.c
  crypto/math/stat.c
  crypto/replay/rdb.c
  crypto/replay/rdbx.c
  srtp/ekt.c
  srtp/srtp.c
)

install(TARGETS srtp2 ARCHIVE DESTINATION lib)
install(FILES include/srtp.h include/ekt.h crypto/include/auth.h
              crypto/include/cipher.h crypto/include/cipher_types.h
              crypto/include/crypto_types.h
        DESTINATION include/srtp2)
