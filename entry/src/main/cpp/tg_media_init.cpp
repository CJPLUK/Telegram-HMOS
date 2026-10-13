// 独立 napi 模块 tg_media：语音 Opus/OGG 编码 + 圆形视频方形转码（同 emoji_frames，避开 'entry' 模块名冲突）。
#include "napi/native_api.h"

napi_value OpusOggEncodeVoice(napi_env env, napi_callback_info info);
napi_value RoundVideoSquare(napi_env env, napi_callback_info info);

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "encodeVoice", nullptr, OpusOggEncodeVoice, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "squareVideo", nullptr, RoundVideoSquare, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module tgMediaModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tg_media",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTgMediaModule(void)
{
    napi_module_register(&tgMediaModule);
}
