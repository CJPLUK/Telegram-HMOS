// 非 arm64（无 tgcalls_ohos libopus.a / libyuv.a）构建桩：直接回 ok=false，上层各自退回原路径。
#include "napi/native_api.h"

static napi_value failPromise(napi_env env, const char* msg) {
    napi_value obj, v, promise;
    napi_deferred deferred;
    napi_create_promise(env, &deferred, &promise);
    napi_create_object(env, &obj);
    napi_get_boolean(env, false, &v); napi_set_named_property(env, obj, "ok", v);
    napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &v); napi_set_named_property(env, obj, "error", v);
    napi_resolve_deferred(env, deferred, obj);
    return promise;
}
napi_value OpusOggEncodeVoice(napi_env env, napi_callback_info) { return failPromise(env, "opus encoder unavailable on this abi"); }
napi_value RoundVideoSquare(napi_env env, napi_callback_info) { return failPromise(env, "video transcoder unavailable on this abi"); }
