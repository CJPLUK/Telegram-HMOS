// 独立 napi 模块 emoji_frames：帧通道专用。
// 不能挂在 'entry' 名下 —— 仓颉混合框架在运行时已注册同名 'entry' 模块
//（命名空间是 ArkUI Node API，真机 Object.keys 实锤），本库避开冲突。
#include "napi/native_api.h"

napi_value EmojiLoadCachedFrames(napi_env env, napi_callback_info info);
napi_value EmojiLoadRawFrame(napi_env env, napi_callback_info info);
napi_value EmojiAnimOpen(napi_env env, napi_callback_info info);
napi_value EmojiAnimNextBatch(napi_env env, napi_callback_info info);
napi_value EmojiAnimClose(napi_env env, napi_callback_info info);

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "emojiLoadCachedFrames", nullptr, EmojiLoadCachedFrames, nullptr, nullptr, nullptr,
          napi_default, nullptr },
        { "emojiLoadRawFrame", nullptr, EmojiLoadRawFrame, nullptr, nullptr, nullptr,
          napi_default, nullptr },
        { "emojiAnimOpen", nullptr, EmojiAnimOpen, nullptr, nullptr, nullptr,
          napi_default, nullptr },
        { "emojiAnimNextBatch", nullptr, EmojiAnimNextBatch, nullptr, nullptr, nullptr,
          napi_default, nullptr },
        { "emojiAnimClose", nullptr, EmojiAnimClose, nullptr, nullptr, nullptr,
          napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module emojiFramesModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "emoji_frames",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEmojiFramesModule(void)
{
    napi_module_register(&emojiFramesModule);
}
