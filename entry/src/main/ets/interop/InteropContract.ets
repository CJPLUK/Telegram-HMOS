// 双侧共享契约清单（ArkTS 侧）—— SSOT §3.1 / D3。
// 必须与 cangjie interop/interop.cj 的常量逐条对应；Reviewer 校验两侧一致。
// 注意 ArkTS 严格模式：禁 `as const`、禁无类型对象字面量，用 class + static readonly。
export class InteropMethod {
  static readonly ROUTER_PUSH: string = 'router.push';
  static readonly ROUTER_POP: string = 'router.pop';
  static readonly ROUTER_REPLACE: string = 'router.replace';
  // ic_interop_contract_router_replace_top_const: 命名一致性债务补齐，与 interop/interop.cj:20
  // ROUTER_REPLACE_TOP 一字不差；ets/interop/InteropRegistry.ets 现有内联字面量
  // 'router.replaceTop' 已功能正确，未强制切换引用（该切换非本契约强制约束）。
  static readonly ROUTER_REPLACE_TOP: string = 'router.replaceTop';
  static readonly HAPTIC_VIBRATE: string = 'haptic.vibrate';
  // ---- Phase 3 能力反转契约（与 interop.cj 一字不差）----
  static readonly BADGE_SET: string = 'badge.set';
  static readonly GEOCODE_REVERSE: string = 'geocode.reverse';
  static readonly GEOCODE_FORWARD: string = 'geocode.forward';
  static readonly AUDIO_LIST_DEVICES: string = 'audio.listDevices';
  static readonly AUDIO_SET_ROUTE: string = 'audio.setRoute';
  static readonly NOTIF_PUBLISH: string = 'notif.publish';
  static readonly NOTIF_CANCEL_GROUP: string = 'notif.cancelGroup';
  static readonly NOTIF_ENABLED: string = 'notif.enabled';
  static readonly NOTIF_REQUEST_ENABLE: string = 'notif.requestEnable';
  static readonly BGPRIVACY_SET: string = 'bgprivacy.set';
  static readonly LOCALAUTH_AVAILABLE: string = 'localauth.available';
  static readonly LOCALAUTH_AUTHENTICATE: string = 'localauth.authenticate';
  // CG-01 passkeys: WebAuthn registration ceremony via @kit.OnlineAuthenticationKit fido2
  // (与 interop.cj PASSKEY_REGISTER 一字不差), 见 impls/PasskeyImpl.ets
  static readonly PASSKEY_REGISTER: string = 'passkey.register';
  static readonly PUSH_GET_TOKEN: string = 'push.getToken';
  static readonly BGTASK_START: string = 'bgtask.start';
  static readonly BGTASK_STOP: string = 'bgtask.stop';
  static readonly CAMERA_REC_PREPARE: string = 'camera.rec.prepare';
  static readonly CAMERA_REC_START: string = 'camera.rec.start';
  static readonly CAMERA_REC_PAUSE: string = 'camera.rec.pause';
  static readonly CAMERA_REC_RESUME: string = 'camera.rec.resume';
  static readonly CAMERA_REC_STOP: string = 'camera.rec.stop';
  static readonly SHARE_LINK: string = 'share.link';
  static readonly LANGUAGE_DISPLAY_NAMES: string = 'language.displayNames';
  static readonly IAP_RECEIPT: string = 'iap.receipt';
  static readonly SCAN_DECODE_FILE: string = 'scan.decodeFile';
  static readonly SCAN_PICK_ALBUM: string = 'scan.pickAlbum';
  static readonly PICK_PHOTO_ALBUM: string = 'photo.pickAlbum';
  static readonly PICK_CONTACTS: string = 'contact.pick';
  static readonly ADD_CONTACT_VIA_UI: string = 'contact.addViaUi';
  static readonly COMPONENT_SNAPSHOT_CAPTURE: string = 'componentSnapshot.capture';
  static readonly COMPONENT_SNAPSHOT_RELEASE: string = 'componentSnapshot.release';
  // 后台来电上报系统通话界面（Call Service Kit，iOS CallKit 等价），见 impls/VoipCallImpl.ets
  static readonly VOIP_REPORT_INCOMING: string = 'voip.reportIncoming';
  static readonly VOIP_REPORT_STATE: string = 'voip.reportState';
  // S7-59 in-app message banner（与 interop.cj INAPP_BANNER_SHOW 一字不差），见 impls/InAppBannerImpl.ets
  static readonly INAPP_BANNER_SHOW: string = 'inappBanner.show';
  // UndoToast 根叠加层命中区（与 interop.cj UNDO_TOAST_REGION 一字不差），见 impls/UndoToastOverlayImpl.ets
  static readonly UNDO_TOAST_REGION: string = 'undoToast.region';
}

export class InteropEvent {
  static readonly FOREGROUND_CHANGED: string = 'app.foregroundChanged';
  // payload 是原始 Want.uri 字符串本身，不是 JSON：URI 含 '://'、'?'、'&'，
  // 仓内 services/JsonParser.cj 是简化版解析器，包一层 JSON 反而引入解析风险。
  static readonly EXTERNAL_URI: string = 'app.externalUri';
  // payload 是 JSON，{colorMode, fontSizeScale}，字段值直接透传
  // ConfigurationConstant.ColorMode 序数 / Configuration.fontSizeScale，不做翻译。
  static readonly CONFIGURATION_CHANGED: string = 'app.configurationChanged';
  // TC-0025 M4（生产者侧）：payload 是 JSON，{top, bottom, left, right}（vp），来自
  // window.getWindowAvoidArea(TYPE_SYSTEM) 与 TYPE_NAVIGATION_INDICATOR 取较大者合并。
  // 冷启动投一次 + avoidAreaChange 增量投递（EntryAbility.dispatchSafeAreaChanged）。
  static readonly SAFE_AREA_CHANGED: string = 'app.safeAreaChanged';
  // 消息通知点击：payload 是 JSON {peerId, peerType, peerName, msgId}（均为字符串），
  // 来自 wantAgent 的 want.parameters（EntryAbility.notificationClickPayload）。
  static readonly NOTIFICATION_CLICK: string = 'app.notificationClick';
  // 系统来电界面上的用户操作：payload JSON {callId: string, event: number(voipCall.VoipCallUiEvent)}
  static readonly VOIP_UI_EVENT: string = 'voip.uiEvent';
}
