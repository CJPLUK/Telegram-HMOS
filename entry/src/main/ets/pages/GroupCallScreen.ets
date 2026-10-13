// 群 Video Chat 页 —— 对位 iOS VideoChatScreenV2Impl
// （submodules/TelegramCallsUI/Sources/VideoChatScreen.swift）。
//
// 布局（竖屏单列，iOS update(...) :2204-2790）：
//   顶栏 56：左 40 圆「…」更多 / 中 标题+副标题 / 右 40 圆 关闭（收起，通话不断）
//   成员列表：Invite Members 行 + 成员行（头像 40、名字、状态文案、右侧麦克风态）
//   底部控制：侧按钮 56（音频路由 / 离开）+ 中间大麦克风（径向渐变，按状态换色）
// 配色（VideoChatMicButtonComponent.swift:481-511）：
//   connecting 灰；自静音 蓝→0x55adfe；被管理员静音/举手 0x3252EF→0xC64688；开麦 0x33C659→0x0BA8A5
// 数据与动作全部经 GroupCallImpl 通道与仓颉 GroupCallSession 交互；本文件只画 UI。
import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import {
  setGroupCallUpdateListener, sendGroupCallAction,
  GroupCallState, GroupCallMemberState, GroupCallMessageState, GroupCallInviteState, GroupCallDisplayAsState } from '../interop/impls/GroupCallImpl';

const SAFE_TOP: number = 38;
const SAFE_BOTTOM: number = 28;
const COLOR_BG: string = '#000000';
const COLOR_PANEL: string = '#1C1C1E';
const COLOR_SECONDARY: string = '#8E8E93';
const COLOR_ACCENT: string = '#42A2FF';
const COLOR_GREEN: string = '#33C758';
const COLOR_RED: string = '#FF3B30';

@Builder
export function groupCallScreenBuilder() {
  GroupCallScreenShell();
}

@Component
struct GroupCallScreenShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  @State stateJson: string = '';
  private ctNavId: string = '';

  // 黑底页面：状态栏内容改浅色，离开时还原（与 PeerInfoPage 同一做法）
  private setLightStatusBar(light: boolean): void {
    window.getLastWindow(getContext()).then((w: window.Window): void => {
      w.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: light ? '#FFFFFFFF' : '#FF000000'
      });
    });
  }

  aboutToAppear(): void {
    // 键盘弹起时只收缩布局：标题和成员留在原位，输入条贴着键盘（默认 OFFSET 会把整页顶走）
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.setLightStatusBar(true);
    setGroupCallUpdateListener((raw: string): void => {
      this.stateJson = raw;
    });
  }

  aboutToDisappear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.setLightStatusBar(false);
    setGroupCallUpdateListener(null);
  }

  build() {
    NavDestination() {
      Stack() {
        CJHybridComponent({
          library: 'ohos_app_cangjie_entry',
          component: 'GroupCallScreen'
        })
          .width('100%')
          .height('100%');
        VideoChatContent({ stateJson: this.stateJson })
          .width('100%')
          .height('100%');
        if (this.ctDim > 0.001) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Black)
            .opacity(this.ctDim);
        }
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .hideTitleBar(true)
    .translate({ x: `${this.ctTransX}%`, y: `${this.ctTransY}%` })
    .onReady((ctx: NavDestinationContext) => {
      this.ctNavId = ctx.navDestinationId ?? '';
      CustomTransition.register(this.ctNavId, (x: number, y: number, d: number) => {
        this.ctTransX = x;
        this.ctTransY = y;
        this.ctDim = d;
      });
    })
    .onDisAppear(() => {
      CustomTransition.unregister(this.ctNavId);
    })
    .onBackPressed((): boolean => {
      sendGroupCallAction('minimize');
      return true;
    });
  }
}

// 主干 app 内多语言：仓颉 trSource 的结果按源英文查表；未翻译的条目保持英文
let gCallStrings: Record<string, string> = {};
function L(english: string): string {
  const v: string | undefined = gCallStrings[english];
  return v === undefined ? english : v;
}

function toNum(s: string): number {
  const v: number = Number(s);
  return isNaN(v) ? 0 : v;
}

function avatarColor(peerId: number): string {
  const colors: string[] = ['#FF885E', '#FFCD6A', '#A0DE7E', '#53EDD6', '#72D5FD', '#82B1FF', '#E0A2F3'];
  const idx: number = Math.abs(peerId) % colors.length;
  return colors[idx];
}

interface VideoTileModel {
  key: string;        // 'local' 或远端 endpointId
  endpoint: string;   // '' = 本地预览
  name: string;
  isSpeaking: boolean;
  isPaused: boolean;
  isMuted: boolean;
}

// 一路视频 = 一个 XComponent surface。surface 就绪后把 surfaceId 交给仓颉 → 原生
// SurfaceFrameSink 直接往这个窗口送帧（iOS VideoChatParticipantVideoComponent）。
@Component
struct VideoTile {
  @Prop endpoint: string = '';
  @Prop name: string = '';
  @Prop isSpeaking: boolean = false;
  @Prop isPaused: boolean = false;
  @Prop isMuted: boolean = false;
  @Prop isExpanded: boolean = false;
  @Prop tileW: number = 160;
  @Prop tileH: number = 160;
  private xc: XComponentController = new XComponentController();
  private bound: boolean = false;

  aboutToDisappear(): void {
    if (!this.bound) {
      return;
    }
    if (this.endpoint.length === 0) {
      sendGroupCallAction('bindLocalSurface', 0, '0');
    } else {
      sendGroupCallAction('bindRemoteSurface', 0, `0|${this.endpoint}`);
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.endpoint === 'myscreen') {
        // iOS isMyScreencast 占位：图标 + "You are sharing your screen" + Stop Sharing
        Column() {
          Image($r('app.media.vc_ic_ctx_sharescreen')).width(40).height(40).fillColor('#FFFFFF').margin({ bottom: 10 });
          Text(L('You are sharing your screen')).fontSize(15).fontColor('#FFFFFF').textAlign(TextAlign.Center);
          Text(L('Stop Sharing'))
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .height(32)
            .padding({ left: 16, right: 16 })
            .borderRadius(16)
            .backgroundColor('#33FFFFFF')
            .margin({ top: 12 })
            .onClick((): void => {
              sendGroupCallAction('stopScreenShare');
            });
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#1C1C1E')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      } else {
      XComponent({
        id: `gc_video_${this.endpoint.length === 0 ? 'local' : this.endpoint}`,
        type: XComponentType.SURFACE,
        controller: this.xc
      })
        .onLoad((): void => {
          const sid: string = this.xc.getXComponentSurfaceId();
          this.bound = true;
          if (this.endpoint.length === 0) {
            sendGroupCallAction('bindLocalSurface', 0, sid);
          } else {
            sendGroupCallAction('bindRemoteSurface', 0, `${sid}|${this.endpoint}`);
          }
        })
        .width('100%')
        .height('100%');
      }
      if (this.isPaused) {
        Column() {
          Text(L('Video paused')).fontSize(13).fontColor('#FFFFFF');
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center);
      }
      Row() {
        Text(this.name)
          .fontSize(16)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (this.isMuted) {
          Image($r('app.media.callui_ic_mute')).width(36).height(36).fillColor('#FFFFFF');
        }
      }
      .width('100%')
      .height(this.isExpanded ? 48 : 36)
      .alignItems(VerticalAlign.Center)
      .padding({ left: this.isExpanded ? 14 : 8, right: 2 })
      .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], ['#99000000', 1]] });
    }
    .width(this.tileW)
    .height(this.tileH)
    .borderRadius(16)
    .clip(true)
    .backgroundColor('#1A1A1A')
    .borderWidth(this.isSpeaking ? 2 : 0)
    .borderColor(COLOR_GREEN);
  }
}

@Component
struct VideoChatContent {
  @Prop @Watch('onStateChanged') stateJson: string = '';
  @State callState: string = 'connecting';
  @State errorText: string = '';
  @State title: string = '';
  @State isMuted: boolean = true;
  @State canUnmute: boolean = true;
  @State raisedHand: boolean = false;
  @State canManage: boolean = false;
  @State speakerOn: boolean = true;
  @State isRecording: boolean = false;
  @State selfLevel: number = 0;
  @State members: GroupCallMemberState[] = [];
  @State messages: GroupCallMessageState[] = [];
  @State messagesEnabled: boolean = true;
  @State canChangeMessages: boolean = false;
  @State joinMuted: boolean = false;
  @State canChangeJoinMuted: boolean = false;
  @State showPermissionsMenu: boolean = false;
  @State displayAs: GroupCallDisplayAsState[] = [];
  @State showDisplayAsMenu: boolean = false;
  @State inputActive: boolean = false;
  @State inputText: string = '';
  @State cameraOn: boolean = false;
  @State screenSharing: boolean = false;
  @State screenConnected: boolean = false;
  @State cameraFront: boolean = true;
  @State expandedKey: string = '';
  // iOS ExpandedVideoState.isMainParticipantPinned / isUIHidden / focusedSpeakerAutoSwitchDeadline
  @State expandedPinned: boolean = false;
  @State expandedUIHidden: boolean = false;
  private autoSwitchDeadline: number = 0;
  @State contentW: number = 328;
  @State gridH: number = 0;
  @State showMoreMenu: boolean = false;
  @State showLeaveSheet: boolean = false;
  @State showInviteSheet: boolean = false;
  // 预约流程（iOS 全在通话页内完成）
  @State mode: string = 'call';
  // 主干的 app 内多语言：仓颉侧 trSource 把源英文映射到当前语言包，这里按英文原文查表
  @State strings: Record<string, string> = {};
  private t(english: string): string {
    return L(english);
  }
  @State scheduleDate: number = 0;
  @State reminderSet: boolean = false;
  @State routeCanManage: boolean = false;
  @State pickedDate: Date = new Date(Date.now() + 3600 * 1000);
  @State nowTick: number = Date.now();
  @State showAbortConfirm: boolean = false;
  private tickTimer: number = -1;
  private lastToast: string = '';
  @State inviteList: GroupCallInviteState[] = [];
  @State inviteLoading: boolean = false;
  @State inviteQuery: string = '';
  @State addConfirmPeer: GroupCallInviteState | null = null;
  @State showEndConfirm: boolean = false;
  @State showTitleEditor: boolean = false;
  // 自己那一行的菜单：Edit Bio / Change Name（iOS VideoChatScreenParticipantContextMenu:104-160）
  @State showBioEditor: boolean = false;
  @State bioDraft: string = '';
  @State showNameEditor: boolean = false;
  @State firstNameDraft: string = '';
  @State lastNameDraft: string = '';
  @State selfFirstName: string = '';
  @State selfLastName: string = '';
  @State selfIsUser: boolean = true;
  @State titleDraft: string = '';
  @State menuMember: GroupCallMemberState | null = null;
  @State menuVolume: number = 100;
  @State removeTarget: GroupCallMemberState | null = null;

  aboutToAppear(): void {
    this.applyState();
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  onStateChanged(): void {
    this.applyState();
  }

  private applyState(): void {
    if (this.stateJson.length === 0) {
      return;
    }
    try {
      const s: GroupCallState = JSON.parse(this.stateJson) as GroupCallState;
      this.callState = s.state;
      this.errorText = s.error ?? '';
      this.title = s.title ?? '';
      this.isMuted = s.isMuted;
      this.canUnmute = s.canUnmute;
      this.raisedHand = s.raisedHand;
      this.canManage = s.canManage;
      this.speakerOn = s.speakerOn;
      this.isRecording = s.isRecording;
      this.selfLevel = toNum(s.selfLevel);
      this.members = s.members ?? [];
      this.messages = s.messages ?? [];
      this.messagesEnabled = s.messagesEnabled ?? true;
      this.canChangeMessages = s.canChangeMessages ?? false;
      this.joinMuted = s.joinMuted ?? false;
      this.displayAs = s.displayAs ?? [];
      this.canChangeJoinMuted = s.canChangeJoinMuted ?? false;
      this.inviteList = s.inviteList ?? [];
      const note: string = s.toast ?? '';
      if (note.length > 0 && note !== this.lastToast) {
        this.toast(note.substring(note.indexOf('|') + 1));
      }
      this.lastToast = note;
      this.inviteLoading = s.inviteLoading ?? false;
      this.selfFirstName = s.selfFirstName ?? '';
      this.selfLastName = s.selfLastName ?? '';
      this.selfIsUser = s.selfIsUser ?? true;
      this.strings = s.strings ?? {};
      gCallStrings = this.strings;
      this.mode = s.mode ?? 'call';
      this.scheduleDate = s.scheduleDate ?? 0;
      this.reminderSet = s.reminderSet ?? false;
      this.routeCanManage = s.routeCanManage ?? false;
      this.syncTicker();
      if (!this.messagesEnabled) {
        this.inputActive = false;
      }
      this.cameraOn = s.cameraOn ?? false;
      this.screenSharing = s.screenSharing ?? false;
      this.screenConnected = s.screenConnected ?? false;
      this.cameraFront = s.cameraFront ?? true;
      if (this.expandedKey.length > 0 &&
        !this.videoTiles().some((t: VideoTileModel): boolean => t.key === this.expandedKey)) {
        this.setExpanded('');   // 被放大的那路关了视频
      }
      this.autoExpandPresentation();
      this.followActiveSpeaker();
    } catch (e) {
      console.error(`[GroupCall] bad state: ${JSON.stringify(e)}`);
    }
  }

  // ---------- 文案 ----------

  private subtitleText(): string {
    if (this.callState === 'failed') {
      return this.errorText.length > 0 ? this.errorText : this.t('Connection failed');
    }
    if (this.callState !== 'connected') {
      return this.t('Connecting...');
    }
    const speaking: GroupCallMemberState[] = this.members.filter((m: GroupCallMemberState): boolean => m.isSpeaking && !m.isSelf);
    if (speaking.length === 1) {
      return `${speaking[0].name} is speaking`;
    }
    if (speaking.length > 1) {
      return `${speaking.length} people are speaking`;
    }
    const n: number = Math.max(this.members.length, 1);
    return n === 1 ? '1 participant' : `${n} participants`;
  }

  private subtitleColor(): string {
    if (this.callState === 'failed') {
      return COLOR_RED;
    }
    if (this.callState === 'connected' &&
      this.members.some((m: GroupCallMemberState): boolean => m.isSpeaking && !m.isSelf)) {
      return COLOR_GREEN;
    }
    return '#80FFFFFF';
  }

  private memberStatus(m: GroupCallMemberState): string {
    if (m.isSpeaking && !m.isMuted) {
      return m.volume !== 10000 && !m.isSelf ? `${Math.round(m.volume / 100)}% speaking` : this.t('speaking');
    }
    if (m.raiseHand) {
      return 'wants to speak';
    }
    if (m.isSelf) {
      return this.t('this is you');
    }
    if (m.mutedByYou) {
      return 'muted for you';
    }
    if (m.about.length > 0) {
      return m.about;
    }
    return this.t('listening');
  }

  private memberStatusColor(m: GroupCallMemberState): string {
    if (m.isSpeaking && !m.isMuted) {
      return COLOR_GREEN;
    }
    if (m.raiseHand || m.isSelf) {
      return COLOR_ACCENT;
    }
    if (m.mutedByYou) {
      return COLOR_RED;
    }
    return COLOR_SECONDARY;
  }

  private micLabel(): string {
    if (this.callState === 'failed') {
      return this.t('Tap to retry');
    }
    if (this.callState !== 'connected') {
      return this.t('Connecting...');
    }
    if (!this.canUnmute) {
      return this.raisedHand ? this.t('You asked to speak') : this.t('Muted by admin');
    }
    return this.isMuted ? this.t('Unmute') : "You're Live";
  }

  private micHint(): string {
    if (this.callState !== 'connected') {
      return '';
    }
    if (!this.canUnmute) {
      return this.raisedHand ? this.t('We let the speakers know') : this.t('Tap if you want to speak');
    }
    return '';
  }

  private micColors(): Array<[ResourceColor, number]> {
    if (this.callState !== 'connected') {
      return [['#2A2A2C', 0], ['#1C1C1E', 1]];
    }
    if (!this.canUnmute) {
      return [['#C64688', 0], ['#3252EF', 1]];
    }
    if (this.isMuted) {
      return [['#55ADFE', 0], ['#007AFF', 1]];
    }
    return [['#33C659', 0], ['#0BA8A5', 1]];
  }

  private glowColor(): string {
    if (this.callState !== 'connected') {
      return '#00000000';
    }
    if (!this.canUnmute) {
      return '#553252EF';
    }
    return this.isMuted ? '#55007AFF' : '#5533C659';
  }

  private onMicTap(): void {
    if (this.callState === 'failed') {
      sendGroupCallAction('retry');
      return;
    }
    if (this.callState !== 'connected') {
      return;
    }
    sendGroupCallAction('toggleMute');
  }

  private onLeaveTap(): void {
    // iOS onLeavePressed:1073 —— 普通成员直接离开；管理员弹 Leave / End
    if (this.canManage) {
      this.showLeaveSheet = true;
    } else {
      sendGroupCallAction('leave');
    }
  }

  // ---------- 视频 ----------

  private videoTiles(): VideoTileModel[] {
    const tiles: VideoTileModel[] = [];
    if (this.screenSharing) {
      // 自己的共享：占位卡（不做本地预览，iOS 同：VideoChatParticipantVideoComponent isMyScreencast）
      tiles.push({ key: 'myscreen', endpoint: 'myscreen', name: this.t('You'), isSpeaking: false, isPaused: false, isMuted: this.isMuted });
    }
    if (this.cameraOn) {
      tiles.push({ key: 'local', endpoint: '', name: this.t('You'), isSpeaking: false, isPaused: false, isMuted: this.isMuted });
    }
    // iOS：屏幕共享的画面排在摄像头之前
    for (const m of this.members) {
      const screen: string = m.presentationEndpoint ?? '';
      if (!m.isSelf && screen.length > 0) {
        tiles.push({
          key: screen, endpoint: screen, name: m.name,
          isSpeaking: m.isSpeaking && !m.isMuted, isPaused: m.presentationPaused ?? false, isMuted: m.isMuted
        });
      }
    }
    for (const m of this.members) {
      if (!m.isSelf && m.videoEndpoint.length > 0) {
        tiles.push({
          key: m.videoEndpoint, endpoint: m.videoEndpoint, name: m.name,
          isSpeaking: m.isSpeaking && !m.isMuted, isPaused: m.videoPaused, isMuted: m.isMuted
        });
      }
    }
    return tiles;
  }

  private visibleTiles(): VideoTileModel[] {
    const all: VideoTileModel[] = this.videoTiles();
    if (this.expandedKey.length === 0) {
      return all;
    }
    return all.filter((t: VideoTileModel): boolean => t.key === this.expandedKey);
  }

  // iOS VideoChatScreen.swift:1599 —— 有人开始共享屏幕：自动把它放大并 pin 住（其余画面降到缩略画质）。
  // 不这样做的话我们会同时向 SFU 要 720p 摄像头 + 全尺寸屏幕两路 Full，SFU 撑不住就降层/停发摄像头（真机复现卡顿）。
  private lastPresentationKey: string = '';
  private autoExpandPresentation(): void {
    const screen: VideoTileModel | undefined = this.videoTiles().find((t: VideoTileModel): boolean =>
      this.members.some((m: GroupCallMemberState): boolean => (m.presentationEndpoint ?? '') === t.key && t.key.length > 0));
    const key: string = screen ? screen.key : '';
    if (key === this.lastPresentationKey) {
      return;
    }
    this.lastPresentationKey = key;
    if (key.length > 0) {
      this.setExpanded(key);
      this.expandedPinned = true;
    } else if (this.expandedPinned) {
      // 共享结束：回到宫格
      this.setExpanded('');
    }
  }

  // iOS VideoChatScreen.swift:1621 —— 放大态且未 pin：正在说话、开着视频的别人自动顶上来，
  // 每次切换后 1s 内不再切。
  private followActiveSpeaker(): void {
    if (this.expandedKey.length === 0 || this.expandedPinned || Date.now() < this.autoSwitchDeadline) {
      return;
    }
    const next: VideoTileModel | undefined = this.videoTiles().find((t: VideoTileModel): boolean =>
      t.key !== 'local' && t.key !== this.expandedKey && t.isSpeaking);
    if (next) {
      this.autoSwitchDeadline = Date.now() + 1000;
      this.expandedKey = next.key;
      sendGroupCallAction('expandVideo', 0, next.key);
    }
  }

  private setExpanded(key: string): void {
    if (key.length === 0) {
      this.gridH = 0;
    }
    this.expandedPinned = false;
    this.expandedUIHidden = false;
    this.autoSwitchDeadline = Date.now() + 1000;
    this.expandedKey = key;
    // 放大的那路向服务器要 Full 画质，其余降到缩略（iOS :1950-2012）
    sendGroupCallAction('expandVideo', 0, key === 'local' ? '' : key);
  }

  // iOS ItemLayout.Grid：间距 4；单路 1 列，否则 2 列；行高 min(180, 宽)。放大时整宽 4:5。
  private tileWidth(count: number): number {
    if (this.expandedKey.length > 0 || count <= 1) {
      return this.contentW;
    }
    return (this.contentW - 4) / 2;
  }

  private tileHeight(count: number): number {
    if (this.expandedKey.length > 0) {
      // iOS 放大态：视频铺满标题栏与控制区之间的整块区域
      return this.gridH > 120 ? this.gridH - 12 : this.contentW * 1.25;
    }
    return Math.min(180, this.tileWidth(count));
  }

  // iOS VideoChatExpandedControlsComponent：左上 "‹ Back"(12,12)，右上 pin（48pt 图标，pin 住时左侧带 "Unpin" 17pt）。
  @Builder
  expandedControls() {
    Row() {
      Row() {
        Image($r('app.media.callui_v2_back')).width(13).height(22).fillColor('#FFFFFF');
        Text(this.t('Back')).fontSize(17).fontColor('#FFFFFF').margin({ left: 6 });
      }
      .height(44)
      .padding({ left: 12, right: 12 })
      .onClick((): void => {
        this.setExpanded('');
      });
      Blank();
      Row() {
        if (this.expandedPinned) {
          Text(this.t('Unpin')).fontSize(17).fontColor('#FFFFFF').margin({ left: 4 });
        }
        Column() {
          Image(this.expandedPinned ? $r('app.media.vc_ic_unpin') : $r('app.media.vc_ic_pin'))
            .width(48)
            .height(48)
            .fillColor('#FFFFFF');
        }
        .width(48)
        .height(44)
        .justifyContent(FlexAlign.Center);
      }
      .height(44)
      .onClick((): void => {
        this.expandedPinned = !this.expandedPinned;
      });
    }
    .width('100%')
    .height(68)
    .alignItems(VerticalAlign.Top)
    .padding({ top: 12 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#66000000', 0], ['#00000000', 1]] });
  }

  @Builder
  videoGrid() {
    if (this.videoTiles().length > 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.visibleTiles(), (t: VideoTileModel): void => {
            VideoTile({
              endpoint: t.endpoint, name: t.name, isSpeaking: t.isSpeaking, isPaused: t.isPaused,
              isMuted: t.isMuted, isExpanded: this.expandedKey.length > 0,
              tileW: this.tileWidth(this.videoTiles().length),
              tileH: this.tileHeight(this.videoTiles().length)
            })
              .margin({ bottom: 4 })
              .onClick((): void => {
                if (this.expandedKey === t.key) {
                  this.expandedUIHidden = !this.expandedUIHidden;
                } else {
                  this.setExpanded(t.key);
                }
              });
          }, (t: VideoTileModel): string => t.key);
        }
        .width('100%');
        if (this.expandedKey.length > 0 && !this.expandedUIHidden) {
          this.expandedControls();
        }
      }
      .width('100%')
      .layoutWeight(this.expandedKey.length > 0 ? 1 : 0)
      .padding({ left: 16, right: 16, top: 8 })
      .onAreaChange((_o: Area, n: Area): void => {
        const w: number = Number(n.width) - 32;
        if (w > 0 && Math.abs(w - this.contentW) > 0.5) {
          this.contentW = w;
        }
        const h: number = Number(n.height);
        if (this.expandedKey.length > 0 && Math.abs(h - this.gridH) > 0.5) {
          this.gridH = h;
        }
      });
    }
  }

  // ---------- 构件 ----------

  @Builder
  roundIconButton(icon: Resource, iconSize: number, action: () => void) {
    Column() {
      Image(icon).width(iconSize).height(iconSize);
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor('#99161616')
    .borderWidth(0.5)
    .borderColor('#33FFFFFF')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(action);
  }

  @Builder
  topBar() {
    Row() {
      this.roundIconButton($r('app.media.vc_ic_more'), 28, (): void => {
        this.showMoreMenu = true;
      });
      Column() {
        Row() {
          Text(this.title.length > 0 ? this.title : this.t('Video Chat'))
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.isRecording) {
            Column().width(8).height(8).borderRadius(4).backgroundColor(COLOR_RED).margin({ left: 5 });
          }
        }
        .justifyContent(FlexAlign.Center);
        Text(this.subtitleText())
          .fontSize(12)
          .fontColor(this.subtitleColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 8, right: 8 });
      this.roundIconButton($r('app.media.vc_ic_minimize'), 28, (): void => {
        sendGroupCallAction('minimize');
      });
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  avatarView(m: GroupCallMemberState, size: number) {
    Stack() {
      if (m.avatar.length > 0) {
        Image(m.avatar).width(size).height(size).borderRadius(size / 2).objectFit(ImageFit.Cover);
      } else {
        Text(m.name.length > 0 ? m.name.substring(0, 1).toUpperCase() : '?')
          .width(size)
          .height(size)
          .borderRadius(size / 2)
          .backgroundColor(avatarColor(m.peerId))
          .fontColor('#FFFFFF')
          .fontSize(size * 0.42)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center);
      }
      if (m.isSpeaking && !m.isMuted) {
        Column()
          .width(size + 6)
          .height(size + 6)
          .borderRadius((size + 6) / 2)
          .borderWidth(2)
          .borderColor(COLOR_GREEN);
      }
    }
    .width(size + 6)
    .height(size + 6);
  }

  @Builder
  micStatusIcon(m: GroupCallMemberState) {
    if (m.raiseHand) {
      Text('✋').fontSize(20);
    } else if (m.isMuted) {
      Image($r('app.media.callui_ic_mute'))
        .width(48)
        .height(48)
        .fillColor(m.canSelfUnmute ? COLOR_SECONDARY : COLOR_RED);
    } else {
      Column() {
        Image($r('app.media.callui_ic_mic'))
          .width(22)
          .height(22)
          .fillColor(m.isSpeaking ? COLOR_GREEN : COLOR_SECONDARY);
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center);
    }
  }

  // 已邀请但还没进来的人（iOS VideoChatParticipantsComponent invitedPeers：副标题 "invited"，右侧 Call/GroupPeerInvited）
  private invitedPeers(): GroupCallInviteState[] {
    return this.inviteList.filter((c: GroupCallInviteState): boolean =>
      c.invited && !this.members.some((m: GroupCallMemberState): boolean => m.peerId === c.peerId));
  }

  @Builder
  invitedRow(c: GroupCallInviteState, isLast: boolean) {
    Column() {
      Row() {
        Stack() {
          if (c.avatar.length > 0) {
            Image(c.avatar).width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover);
          } else {
            Text(c.name.length > 0 ? c.name.substring(0, 1).toUpperCase() : '?')
              .width(40)
              .height(40)
              .borderRadius(20)
              .backgroundColor(avatarColor(c.peerId))
              .fontColor('#FFFFFF')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center);
          }
        }
        .width(46)
        .height(46);
        Column() {
          Text(c.name)
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.t('invited')).fontSize(15).fontColor(COLOR_SECONDARY).margin({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 });
        Column() {
          Image($r('app.media.vc_ic_invited')).width(24).height(24).fillColor(COLOR_SECONDARY);
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center);
      }
      .width('100%')
      .height(60)
      .padding({ left: 13, right: 6 })
      .alignItems(VerticalAlign.Center);
      if (!isLast) {
        Divider().strokeWidth(0.5).color('#2E2E30').margin({ left: 63 });
      }
    }
    .width('100%');
  }

  private toast(text: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: text, duration: 3000, bottom: 190 });
    } catch (e) {
      console.error(`[GroupCall] toast failed: ${JSON.stringify(e)}`);
    }
  }

  @Builder
  memberRow(m: GroupCallMemberState, isLast: boolean) {
    Column() {
      Row() {
        this.avatarView(m, 40);
        Column() {
          Text(m.name)
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.memberStatus(m))
            .fontSize(15)
            .fontColor(this.memberStatusColor(m))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 });
        this.micStatusIcon(m);
      }
      .width('100%')
      .height(60)
      .padding({ left: 13, right: 6 })
      .alignItems(VerticalAlign.Center);
      if (!isLast) {
        Divider().strokeWidth(0.5).color('#2E2E30').margin({ left: 63 });
      }
    }
    .width('100%')
    .onClick((): void => {
      this.menuVolume = m.volume > 0 ? Math.round(m.volume / 100) : 100;
      this.menuMember = m;
    });
  }

  @Builder
  inviteRow() {
    Column() {
      Row() {
        Column() {
          Image($r('app.media.vc_ic_adduser')).width(26).height(26).fillColor('#42A2FF');
        }
        .width(46)
        .height(46)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
        Text(this.t('Invite Members'))
          .fontSize(17)
          .fontColor('#42A2FF')
          .margin({ left: 10 });
      }
      .width('100%')
      .height(52)
      .padding({ left: 13, right: 13 })
      .alignItems(VerticalAlign.Center);
      Divider().strokeWidth(0.5).color('#2E2E30').margin({ left: 62 });
    }
    .width('100%')
    .onClick((): void => {
      this.inviteQuery = '';
      this.showInviteSheet = true;
      sendGroupCallAction('invite');
    });
  }

  @Builder
  memberList() {
    Scroll() {
      Column() {
        Column() {
          this.inviteRow();
          ForEach(this.members, (m: GroupCallMemberState, index: number): void => {
            this.memberRow(m, index === this.members.length - 1 && this.invitedPeers().length === 0);
          }, (m: GroupCallMemberState): string =>
            `${m.peerId}_${m.isMuted}_${m.isSpeaking}_${m.raiseHand}_${m.canSelfUnmute}_${m.mutedByYou}_${m.name}_${m.avatar}_${m.about}_${this.invitedPeers().length}`);
          ForEach(this.invitedPeers(), (c: GroupCallInviteState, index: number): void => {
            this.invitedRow(c, index === this.invitedPeers().length - 1);
          }, (c: GroupCallInviteState): string => `inv_${c.peerId}_${c.avatar}`);
        }
        .width('100%')
        .borderRadius(26)
        .backgroundColor('#1A1A1A')
        .clip(true);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top);
  }

  // ===== 底部按钮排（iOS VideoChatScreen.swift:2643-2801 + VideoChatActionButtonComponent）=====
  // 顺序：[audio|rotate] [video] (MIC) [message|share] [leave]；全部 56pt；标题 regular 13 白、圆下 5pt。
  // 注意：@Builder 的按值参数不随状态刷新，所以每个按钮各写一个 builder，在里面直接读 this.xxx。

  private micPhase(): string {
    if (this.callState !== 'connected') {
      return 'connecting';
    }
    if (!this.canUnmute) {
      return 'raise';
    }
    return this.isMuted ? 'muted' : 'unmuted';
  }

  // 激活态底色随麦克风状态变（VideoChatActionButtonComponent.swift:145-147 配色表）
  private activeTint(): string {
    const p: string = this.micPhase();
    if (p === 'muted') {
      return '#21477D';
    }
    if (p === 'unmuted') {
      return '#34C659';
    }
    if (p === 'raise') {
      return '#3252EF';
    }
    return '#B825272E';
  }

  private buttonCount(): number {
    let n: number = 3;
    if (this.canUnmute || this.cameraOn) {
      n += 1;
    }
    n += 1;   // message / share
    return n;
  }

  private buttonSpacing(): number {
    const n: number = this.buttonCount();
    const remaining: number = this.contentW + 32 - 32 - 56 * n;
    return Math.max(8, Math.min(33, Math.floor(remaining / (n - 1))));
  }

  @Builder
  actionLabel(text: string) {
    Text(text).fontSize(13).fontColor('#FFFFFF').maxLines(1).margin({ top: 5 }).height(18);
  }

  @Builder
  audioButton() {
    Column() {
      Column() {
        Image($r('app.media.vc_ic_speaker')).width(60).height(60).fillColor('#FFFFFF');
      }
      .width(56).height(56).borderRadius(28).clip(true)
      .backgroundColor(this.speakerOn ? this.activeTint() : (this.micPhase() === 'raise' ? '#23306B' : '#B825272E'))
      .animation({ duration: 200, curve: Curve.EaseInOut })
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      this.actionLabel(this.t('speaker'));
    }
    .width(56).alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      sendGroupCallAction('toggleSpeaker');
    });
  }

  @Builder
  rotateButton() {
    Column() {
      Column() {
        Image($r('app.media.vc_ic_rotate')).width(44).height(44).fillColor('#FFFFFF');
      }
      .width(56).height(56).borderRadius(28).clip(true)
      .backgroundColor(this.activeTint())
      .animation({ duration: 200, curve: Curve.EaseInOut })
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      this.actionLabel(this.t('rotate'));
    }
    .width(56).alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      sendGroupCallAction('flipCamera');
    });
  }

  @Builder
  videoButton() {
    Column() {
      Column() {
        Image($r('app.media.vc_ic_video')).width(58).height(58).fillColor('#FFFFFF');
      }
      .width(56).height(56).borderRadius(28).clip(true)
      .backgroundColor(this.cameraOn ? this.activeTint() : (this.micPhase() === 'raise' ? '#3252EF' : '#B825272E'))
      .animation({ duration: 200, curve: Curve.EaseInOut })
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      this.actionLabel(this.t('video'));
    }
    .width(56).alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      sendGroupCallAction('toggleCamera');
    });
  }

  @Builder
  messageButton() {
    Column() {
      Column() {
        Image(this.messagesEnabled ? $r('app.media.vc_ic_message') : $r('app.media.vc_ic_share'))
          .width(56).height(56).fillColor('#FFFFFF');
      }
      .width(56).height(56).borderRadius(28).clip(true)
      .backgroundColor('#B825272E')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      Text(this.messagesEnabled ? this.t('message') : this.t('share'))
        .fontSize(13).fontColor('#FFFFFF').maxLines(1).margin({ top: 5 }).height(18);
    }
    .width(56).alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      // iOS onMessagePressed:1063 —— 允许发消息 → 打开输入条；否则分享邀请链接
      if (this.messagesEnabled) {
        this.openMessageInput();
      } else {
        sendGroupCallAction('shareLink');
      }
    });
  }

  @Builder
  leaveButton() {
    Column() {
      Column() {
        Image($r('app.media.vc_ic_leave')).width(22).height(22);
      }
      .width(56).height(56).borderRadius(28)
      .backgroundColor('#330D0B')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      this.actionLabel(this.t('leave'));
    }
    .width(56).alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      this.onLeaveTap();
    });
  }

  private micGradient(): Array<[ResourceColor, number]> {
    const p: string = this.micPhase();
    if (p === 'connecting') {
      return [['#1A1A1A', 0], ['#1A1A1A', 1]];
    }
    if (p === 'raise') {
      return [['#3252EF', 0], ['#C64688', 1]];
    }
    if (p === 'muted') {
      return [['#55B3F8', 0], ['#55ADFE', 1]];
    }
    return [['#33C659', 0], ['#0BA8A5', 1]];
  }

  private blobTint(): string {
    const p: string = this.micPhase();
    if (p === 'unmuted') {
      return '#5933C758';
    }
    return '#00000000';
  }

  // iOS compact 态标题小写（VideoChatMicButtonComponent.swift:419-421）
  private micTitle(): string {
    if (this.callState === 'failed') {
      return 'tap to retry';
    }
    const p: string = this.micPhase();
    if (p === 'connecting') {
      return 'connecting...';
    }
    if (p === 'raise') {
      return this.raisedHand ? 'you asked to speak' : 'muted by admin';
    }
    return p === 'muted' ? this.t('unmute') : this.t('mute');
  }

  @Builder
  micButton() {
    Column() {
      Stack() {
        // 说话光晕：iOS CallBlobsLayer，blobScale ≈ 1.0…1.5，仅开麦时显示
        Column()
          .width(56).height(56).borderRadius(28)
          .backgroundColor(this.blobTint())
          .scale({
            x: 1.28 + Math.min(this.selfLevel * 1.2, 1) * 0.5,
            y: 1.28 + Math.min(this.selfLevel * 1.2, 1) * 0.5
          })
          .animation({ duration: 160, curve: Curve.EaseOut });
        Column() {
          if (this.callState !== 'connected' && this.callState !== 'failed') {
            LoadingProgress().width(30).height(30).color('#55B3F8');
          } else if (!this.canUnmute) {
            Text('✋').fontSize(24);
          } else if (this.isMuted) {
            Image($r('app.media.callui_ic_mute')).width(66).height(66).fillColor('#FFFFFF');
          } else {
            Image($r('app.media.callui_ic_mic')).width(28).height(28).fillColor('#FFFFFF');
          }
        }
        .width(56).height(56).borderRadius(28).clip(true)
        .linearGradient({ angle: 45, colors: this.micGradient() })
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      }
      .width(56).height(56);
      Text(this.micTitle())
        .fontSize(13).fontColor('#FFFFFF').maxLines(1).textAlign(TextAlign.Center)
        .width(104).height(18).margin({ top: 5, left: -24, right: -24 });
    }
    .width(56)
    .alignItems(HorizontalAlign.Center)
    .onClick((): void => this.onMicTap());
  }

  @Builder
  controls() {
    Row({ space: this.buttonSpacing() }) {
      // 自己的视频开着时第一格从音频路由变成翻转（:2653-2656）
      if (this.cameraOn) {
        this.rotateButton();
      } else {
        this.audioButton();
      }
      // 被管理员静音时隐藏摄像头按钮（:2646-2649）
      if (this.canUnmute || this.cameraOn) {
        this.videoButton();
      }
      this.micButton();
      this.messageButton();
      this.leaveButton();
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Top)
    .padding({ bottom: SAFE_BOTTOM + 20, top: 12 });
  }

  // ===== 通话内消息（iOS MessageListComponent / MessageItemComponent / MessageInputPanelComponent(.videoChat)）=====

  @Builder
  messagePill(m: GroupCallMessageState) {
    Row() {
      if (m.avatar.length > 0) {
        Image(m.avatar).width(28).height(28).borderRadius(14).objectFit(ImageFit.Cover);
      } else {
        Text(m.name.length > 0 ? m.name.substring(0, 1).toUpperCase() : '?')
          .width(28).height(28).borderRadius(14)
          .backgroundColor(avatarColor(m.peerId))
          .fontColor('#FFFFFF').fontSize(12).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center);
      }
      Text() {
        Span(m.name.length > 40 ? `${m.name.substring(0, 40)}… ` : `${m.name} `).fontWeight(600);
        Span(m.text);
      }
      .fontSize(14)
      .fontColor('#FFFFFF')
      .margin({ left: 10 })
      .constraintSize({ maxWidth: 330 - 4 - 28 - 10 - 13 });
    }
    .padding({ left: 4, right: 13, top: 4, bottom: 4 })
    .constraintSize({ minHeight: 36 })
    .borderRadius(18)
    .backgroundColor('#B825272E')
    .borderWidth(0.5)
    .borderColor('#26FFFFFF')
    .alignItems(VerticalAlign.Center)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.01, y: 0.01 }))
      .animation({ duration: 200, curve: Curve.EaseOut }));
  }

  @Builder
  messageList() {
    // 自下而上堆叠、水平居中、项间距 6；只有胶囊本身可点（iOS point(inside:) 覆写）
    Column({ space: 6 }) {
      ForEach(this.messages, (m: GroupCallMessageState): void => {
        this.messagePill(m);
      }, (m: GroupCallMessageState): string => m.id);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 8, right: 8, bottom: 8 })
    .hitTestBehavior(HitTestMode.None);
  }

  // iOS activateInput()：输入条一出现键盘就起来。输入条是条件渲染的，等它挂载后再要焦点。
  private openMessageInput(): void {
    this.inputActive = true;
    setTimeout((): void => {
      try {
        this.getUIContext().getFocusController().requestFocus('gc_message_input');
      } catch (e) {
        console.error(`[GroupCall] requestFocus failed: ${JSON.stringify(e)}`);
      }
    }, 120);
  }

  private submitMessage(): void {
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      this.inputActive = false;
      return;
    }
    sendGroupCallAction('sendMessage', 0, text);
    this.inputText = '';
  }

  @Builder
  inputPanel() {
    Row() {
      TextInput({ text: this.inputText, placeholder: this.t('Message') })
        .id('gc_message_input')
        .focusable(true)
        .focusOnTouch(true)
        .layoutWeight(1)
        .height(40)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .placeholderColor('#4DFFFFFF')
        .caretColor('#42A2FF')
        .backgroundColor('#B825272E')
        .borderRadius(20)
        .padding({ left: 16, right: 16 })
        .maxLength(128)
        .enterKeyType(EnterKeyType.Send)
        .onChange((v: string): void => {
          this.inputText = v;
        })
        .onSubmit((): void => {
          this.submitMessage();
        });
      // 有字 = send，无字 = close（MessageInputPanelComponent.swift:2077-2090）
      Column() {
        if (this.inputText.trim().length > 0) {
          Image($r('app.media.vc_ic_send')).width(28).height(28);
        } else {
          Image($r('app.media.vc_ic_leave')).width(14).height(14);
        }
      }
      .width(40).height(40).borderRadius(20)
      .backgroundColor(this.inputText.trim().length > 0 ? '#42A2FF' : '#B825272E')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .margin({ left: 6 })
      .onClick((): void => {
        if (this.inputText.trim().length > 0) {
          this.submitMessage();
        } else {
          this.inputActive = false;
        }
      });
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 8 })
    .alignItems(VerticalAlign.Center);
  }

  // ---------- 弹层 ----------

  @Builder
  sheetItem(label: string, color: string, action: () => void) {
    Text(label)
      .width('100%')
      .height(56)
      .fontSize(17)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .onClick(action);
  }

  @Builder
  scrim(onDismiss: () => void) {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#80000000')
      .onClick(onDismiss);
  }

  @Builder
  moreMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.scrim((): void => {
        this.showMoreMenu = false;
      });
      Column() {
        if (this.displayAs.length > 1) {
          this.displayAsEntry();
        }
        if (this.canManage) {
          this.menuRow(this.t('Edit Title'), '#FFFFFF', (): void => {
            this.showMoreMenu = false;
            this.titleDraft = this.title;
            this.showTitleEditor = true;
          }, $r('app.media.vc_ic_edit'));
        }
        if (this.canChangeMessages) {
          // iOS VideoChatScreenMoreMenu.swift:230 — Call/MessagesDisable | Call/MessagesEnable + toast
          this.menuRow(this.messagesEnabled ? this.t('Disable Messages') : this.t('Enable Messages'), '#FFFFFF', (): void => {
            this.showMoreMenu = false;
            const enabling: boolean = !this.messagesEnabled;
            sendGroupCallAction('toggleMessages');
            this.toast(enabling ? this.t('Messages enabled') : this.t('Messages disabled'));
          }, this.messagesEnabled ? $r('app.media.vc_ic_messages_disable') : $r('app.media.vc_ic_messages_enable'));
        }
        if (this.canManage && this.canChangeJoinMuted) {
          // iOS VideoChatScreenMoreMenu.swift:264 — Chat/Context Menu/Restrict → 子菜单
          this.menuRow(this.t('Edit Permissions'), '#FFFFFF', (): void => {
            this.showMoreMenu = false;
            this.showPermissionsMenu = true;
          }, $r('app.media.vc_ic_ctx_restrict'));
        }
        // iOS VideoChatScreenMoreMenu.swift:363 — Call/Context Menu/ShareScreen
        this.menuRow(this.screenSharing ? this.t('Stop Screen Sharing') : this.t('Share Screen'), '#FFFFFF', (): void => {
          this.showMoreMenu = false;
          sendGroupCallAction(this.screenSharing ? 'stopScreenShare' : 'shareScreen');
        }, $r('app.media.vc_ic_ctx_sharescreen'));
        this.menuRow(this.t('Share Invite Link'), '#FFFFFF', (): void => {
          this.showMoreMenu = false;
          sendGroupCallAction('shareLink');
        }, $r('app.media.vc_ic_link'));
        if (this.canManage) {
          this.menuRow(this.isRecording ? this.t('Stop Recording') : this.t('Start Recording'), '#FFFFFF', (): void => {
            this.showMoreMenu = false;
            sendGroupCallAction('toggleRecord');
          });
          this.menuRow(this.t('End Video Chat'), COLOR_RED, (): void => {
            this.showMoreMenu = false;
            this.showEndConfirm = true;
          }, $r('app.media.vc_ic_clear'));
        }
        this.menuRow(this.t('Leave Video Chat'), COLOR_RED, (): void => {
          this.showMoreMenu = false;
          sendGroupCallAction('leave');
        }, $r('app.media.vc_ic_clear'));
      }
      .width(250)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true)
      .margin({ left: 16, top: SAFE_TOP + 56 });
    }
    .width('100%')
    .height('100%');
  }

  private currentDisplayAs(): GroupCallDisplayAsState | undefined {
    return this.displayAs.find((p: GroupCallDisplayAsState): boolean => p.current);
  }

  @Builder
  displayAsAvatar(p: GroupCallDisplayAsState | undefined, size: number) {
    if (p !== undefined && p.avatar.length > 0) {
      Image(p.avatar).width(size).height(size).borderRadius(size / 2).objectFit(ImageFit.Cover);
    } else {
      Text(p !== undefined && p.name.length > 0 ? p.name.substring(0, 1).toUpperCase() : '?')
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor(avatarColor(p?.peerId ?? 0))
        .fontColor('#FFFFFF')
        .fontSize(size * 0.45)
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center);
    }
  }

  // iOS VideoChatScreenMoreMenu.swift:167-186：两行文字（"Display Me As..." + 当前身份名）+ 右侧 28pt 头像，下面一条粗分隔
  @Builder
  displayAsEntry() {
    Column() {
      Row() {
        Column() {
          Text(this.t('Display Me As...')).fontSize(17).fontColor('#FFFFFF');
          Text(this.currentDisplayAs()?.name ?? '')
            .fontSize(14)
            .fontColor(COLOR_SECONDARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        this.displayAsAvatar(this.currentDisplayAs(), 28);
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 });
      Column().width('100%').height(8).backgroundColor('#33000000');
    }
    .width('100%')
    .onClick((): void => {
      this.showMoreMenu = false;
      this.showDisplayAsMenu = true;
    });
  }

  // iOS contextMenuDisplayAsItems（:700）：‹ Back / 分隔 / 每个身份一行（名字 + 头像），当前项不可再点
  @Builder
  displayAsMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.scrim((): void => {
        this.showDisplayAsMenu = false;
      });
      Column() {
        Row() {
          Image($r('app.media.vc_ic_ctx_back')).width(24).height(24).fillColor('#FFFFFF');
          Text(this.t('Back')).fontSize(17).fontColor('#FFFFFF').margin({ left: 12 });
        }
        .width('100%')
        .height(44)
        .padding({ left: 16, right: 16 })
        .onClick((): void => {
          this.showDisplayAsMenu = false;
          this.showMoreMenu = true;
        });
        Column().width('100%').height(8).backgroundColor('#33000000');
        ForEach(this.displayAs, (p: GroupCallDisplayAsState, index: number): void => {
          Column() {
            Row() {
              Column() {
                Text(p.name)
                  .fontSize(17)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                if (p.current) {
                  Text(this.t('current')).fontSize(14).fontColor(COLOR_SECONDARY).margin({ top: 1 });
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start);
              this.displayAsAvatar(p, 28);
            }
            .width('100%')
            .height(p.current ? 56 : 44)
            .padding({ left: 16, right: 16 });
            if (index < this.displayAs.length - 1) {
              Divider().strokeWidth(0.5).color('#48484A');
            }
          }
          .width('100%')
          .onClick((): void => {
            this.showDisplayAsMenu = false;
            if (!p.current) {
              sendGroupCallAction('displayAs', p.peerId);
            }
          });
        }, (p: GroupCallDisplayAsState): string => `${p.peerId}_${p.current}_${p.avatar}`);
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true)
      .margin({ left: 16, top: SAFE_TOP + 56 });
    }
    .width('100%')
    .height('100%');
  }

  // iOS contextMenuPermissionItems（:748）：‹ Back / 分隔 / 两个单选项，选中项右侧打勾。
  @Builder
  permissionsMenu() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.scrim((): void => {
        this.showPermissionsMenu = false;
      });
      Column() {
        Row() {
          Image($r('app.media.vc_ic_ctx_back')).width(24).height(24).fillColor('#FFFFFF');
          Text(this.t('Back')).fontSize(17).fontColor('#FFFFFF').margin({ left: 12 });
        }
        .width('100%')
        .height(44)
        .padding({ left: 16, right: 16 })
        .onClick((): void => {
          this.showPermissionsMenu = false;
          this.showMoreMenu = true;
        });
        Column().width('100%').height(8).backgroundColor('#33000000');
        this.permissionRow(this.t('New participants can speak'), false);
        this.permissionRow(this.t('New paricipants are muted'), true);
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true)
      .margin({ left: 16, top: SAFE_TOP + 56 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  permissionRow(label: string, muted: boolean) {
    Column() {
      Row() {
        Text(label).fontSize(17).fontColor('#FFFFFF').layoutWeight(1);
        if (this.joinMuted === muted) {
          Image($r('app.media.vc_ic_ctx_check')).width(24).height(24).fillColor('#FFFFFF');
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 });
      if (!muted) {
        Divider().strokeWidth(0.5).color('#48484A');
      }
    }
    .width('100%')
    .onClick((): void => {
      this.showPermissionsMenu = false;
      sendGroupCallAction('setJoinMuted', 0, muted ? '1' : '0');
    });
  }

  // iOS ContextMenuActionItem：左文字 17pt，右侧 24pt 图标，同色。
  @Builder
  menuRow(label: string, color: string, action: () => void, icon?: Resource) {
    Column() {
      Row() {
        Text(label)
          .fontSize(17)
          .fontColor(color)
          .layoutWeight(1)
          .textAlign(TextAlign.Start);
        if (icon) {
          Image(icon)
            .width(24)
            .height(24)
            .fillColor(color);
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 });
      Divider().strokeWidth(0.5).color('#48484A');
    }
    .width('100%')
    .onClick(action);
  }

  // ---------- 邀请面板（iOS ChannelMembersSearchController mode:.inviteToCall） ----------

  private filteredInvites(member: boolean): GroupCallInviteState[] {
    const q: string = this.inviteQuery.trim().toLowerCase();
    return this.inviteList.filter((c: GroupCallInviteState): boolean =>
      c.isMember === member && (q.length === 0 || c.name.toLowerCase().indexOf(q) >= 0));
  }

  private onInviteTap(c: GroupCallInviteState): void {
    if (c.invited) {
      return;
    }
    if (c.isMember) {
      // VideoChatScreenInviteMembers.swift:135 —— 直接邀请、收起面板、toast
      this.showInviteSheet = false;
      sendGroupCallAction('inviteUser', c.peerId);
    } else {
      this.addConfirmPeer = c;
    }
  }

  @Builder
  inviteSectionHeader(label: string) {
    Text(label)
      .width('100%')
      .height(28)
      .padding({ left: 16, top: 6 })
      .fontSize(13)
      .fontColor(COLOR_SECONDARY)
      .backgroundColor('#1C1C1E');
  }

  @Builder
  inviteRowView(c: GroupCallInviteState) {
    Row() {
      if (c.avatar.length > 0) {
        Image(c.avatar).width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover);
      } else {
        Text(c.name.length > 0 ? c.name.substring(0, 1).toUpperCase() : '?')
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(avatarColor(c.peerId))
          .fontColor('#FFFFFF')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center);
      }
      Column() {
        Text(c.name)
          .fontSize(17)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (c.invited) {
          Text(this.t('invited')).fontSize(14).fontColor(COLOR_SECONDARY).margin({ top: 1 });
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 });
      if (c.invited) {
        Image($r('app.media.vc_ic_invited')).width(24).height(24).fillColor(COLOR_SECONDARY);
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .opacity(c.invited ? 0.5 : 1)
    .onClick((): void => {
      this.onInviteTap(c);
    });
  }

  @Builder
  inviteSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.scrim((): void => {
        this.showInviteSheet = false;
      });
      Column() {
        Stack() {
          Text(this.t('Invite Members')).fontSize(17).fontWeight(600).fontColor('#FFFFFF');
          Row() {
            Text(this.t('Cancel'))
              .fontSize(17)
              .fontColor(COLOR_ACCENT)
              .height(56)
              .padding({ left: 16, right: 16 })
              .onClick((): void => {
                this.showInviteSheet = false;
              });
            Blank();
          }
          .width('100%');
        }
        .width('100%')
        .height(56);
        TextInput({ placeholder: this.t('Search'), text: this.inviteQuery })
          .height(36)
          .margin({ left: 16, right: 16, bottom: 8 })
          .borderRadius(10)
          .backgroundColor('#2C2C2E')
          .fontColor('#FFFFFF')
          .placeholderColor(COLOR_SECONDARY)
          .fontSize(17)
          .onChange((v: string): void => {
            this.inviteQuery = v;
          });
        Row() {
          Column() {
            Image($r('app.media.vc_ic_link')).width(24).height(24).fillColor(COLOR_ACCENT);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center);
          Text(this.t('Copy Invite Link')).fontSize(17).fontColor(COLOR_ACCENT).margin({ left: 12 });
        }
        .width('100%')
        .height(52)
        .padding({ left: 16, right: 16 })
        .onClick((): void => {
          this.showInviteSheet = false;
          sendGroupCallAction('shareLink');
        });
        Divider().strokeWidth(0.5).color('#38383A');
        if (this.inviteLoading && this.inviteList.length === 0) {
          Column() {
            LoadingProgress().width(28).height(28).color(COLOR_SECONDARY);
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else {
          List() {
            if (this.filteredInvites(true).length > 0) {
              ListItem() {
                this.inviteSectionHeader(this.t('GROUP MEMBERS'));
              }
              ForEach(this.filteredInvites(true), (c: GroupCallInviteState): void => {
                ListItem() {
                  this.inviteRowView(c);
                }
              }, (c: GroupCallInviteState): string => `m${c.peerId}_${c.invited}`);
            }
            if (this.filteredInvites(false).length > 0) {
              ListItem() {
                this.inviteSectionHeader(this.t('CONTACTS'));
              }
              ForEach(this.filteredInvites(false), (c: GroupCallInviteState): void => {
                ListItem() {
                  this.inviteRowView(c);
                }
              }, (c: GroupCallInviteState): string => `c${c.peerId}_${c.invited}`);
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring);
        }
      }
      .width('100%')
      .height('88%')
      .padding({ bottom: SAFE_BOTTOM })
      .borderRadius({ topLeft: 14, topRight: 14 })
      .backgroundColor('#1C1C1E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  // iOS :165-168 —— "%1$@ isn't a member of "%2$@" yet. Add them to the group?"  [Cancel] [Add]
  @Builder
  addConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.addConfirmPeer = null;
      });
      Column() {
        Text(`${this.addConfirmPeer?.name ?? ''} isn't a member of "${this.title}" yet. Add them to the group?`)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
          .margin({ top: 20, bottom: 18 });
        Divider().strokeWidth(0.5).color('#48484A');
        Row() {
          Text(this.t('Cancel'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.addConfirmPeer = null;
            });
          Divider().vertical(true).height(44).strokeWidth(0.5).color('#48484A');
          Text(this.t('Add'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              const id: number = this.addConfirmPeer?.peerId ?? 0;
              this.addConfirmPeer = null;
              this.showInviteSheet = false;
              if (id !== 0) {
                sendGroupCallAction('addAndInviteUser', id);
              }
            });
        }
        .width('100%');
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  leaveSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.scrim((): void => {
        this.showLeaveSheet = false;
      });
      Column() {
        Column() {
          Text(this.t('Leave video chat'))
            .fontSize(13)
            .fontColor(COLOR_SECONDARY)
            .height(44)
            .textAlign(TextAlign.Center)
            .width('100%');
          Divider().strokeWidth(0.5).color('#48484A');
          this.sheetItem(this.t('End Video Chat'), COLOR_RED, (): void => {
            this.showLeaveSheet = false;
            this.showEndConfirm = true;
          });
          Divider().strokeWidth(0.5).color('#48484A');
          this.sheetItem(this.t('Leave Video Chat'), COLOR_ACCENT, (): void => {
            this.showLeaveSheet = false;
            sendGroupCallAction('leave');
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .clip(true);
        Column() {
          this.sheetItem(this.t('Cancel'), COLOR_ACCENT, (): void => {
            this.showLeaveSheet = false;
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: SAFE_BOTTOM + 6 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  endConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.showEndConfirm = false;
      });
      Column() {
        Text(this.t('End Video Chat')).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').margin({ top: 20 });
        Text(this.t('Are you sure you want to end this video chat?'))
          .fontSize(13)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
          .margin({ top: 4, bottom: 18 });
        Divider().strokeWidth(0.5).color('#48484A');
        Row() {
          Text(this.t('Cancel'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showEndConfirm = false;
            });
          Divider().vertical(true).height(44).strokeWidth(0.5).color('#48484A');
          Text(this.t('End'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_RED)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showEndConfirm = false;
              sendGroupCallAction('end');
            });
        }
        .width('100%');
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  titleEditor() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.showTitleEditor = false;
      });
      Column() {
        Text(this.t('Video Chat Title')).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').margin({ top: 20 });
        Text(this.t('Edit a title of this video chat.'))
          .fontSize(13)
          .fontColor('#FFFFFF')
          .margin({ top: 4, bottom: 12 });
        TextInput({ text: this.titleDraft, placeholder: this.t('Title') })
          .height(36)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .placeholderColor(COLOR_SECONDARY)
          .backgroundColor('#1C1C1E')
          .borderRadius(8)
          .maxLength(40)
          .margin({ left: 16, right: 16, bottom: 16 })
          .onChange((v: string): void => {
            this.titleDraft = v;
          });
        Divider().strokeWidth(0.5).color('#48484A');
        Row() {
          Text(this.t('Cancel'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showTitleEditor = false;
            });
          Divider().vertical(true).height(44).strokeWidth(0.5).color('#48484A');
          Text(this.t('Save'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showTitleEditor = false;
              sendGroupCallAction('editTitle', 0, this.titleDraft.trim());
            });
        }
        .width('100%');
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  dialogField(value: string, placeholder: string, maxLen: number, onEdit: (v: string) => void) {
    TextInput({ text: value, placeholder: placeholder })
      .height(36)
      .fontSize(15)
      .fontColor('#FFFFFF')
      .placeholderColor(COLOR_SECONDARY)
      .backgroundColor('#1C1C1E')
      .borderRadius(8)
      .maxLength(maxLen)
      .margin({ left: 16, right: 16, bottom: 8 })
      .onChange(onEdit);
  }

  @Builder
  dialogButtons(onCancel: () => void, onSave: () => void) {
    Divider().strokeWidth(0.5).color('#48484A').margin({ top: 8 });
    Row() {
      Text(this.t('Cancel'))
        .layoutWeight(1)
        .height(44)
        .fontSize(17)
        .fontColor(COLOR_ACCENT)
        .textAlign(TextAlign.Center)
        .onClick(onCancel);
      Divider().vertical(true).height(44).strokeWidth(0.5).color('#48484A');
      Text(this.t('Save'))
        .layoutWeight(1)
        .height(44)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ACCENT)
        .textAlign(TextAlign.Center)
        .onClick(onSave);
    }
    .width('100%');
  }

  // iOS VoiceChat.EditBioTitle "Bio" / EditBioText / placeholder "Bio" / Save，上限 70 字（maxBioLength）
  @Builder
  bioEditor() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.showBioEditor = false;
      });
      Column() {
        Text(this.t('Bio')).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').margin({ top: 20 });
        Text('Any details such as age, occupation or city.')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
          .margin({ top: 4, bottom: 12 });
        this.dialogField(this.bioDraft, this.t('Bio'), 70, (v: string): void => {
          this.bioDraft = v;
        });
        this.dialogButtons((): void => {
          this.showBioEditor = false;
        }, (): void => {
          this.showBioEditor = false;
          sendGroupCallAction('editBio', 0, this.bioDraft.trim());
        });
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  // iOS VoiceChat.ChangeNameTitle "Change Name"，两个输入框 First Name / Last Name，Save
  @Builder
  nameEditor() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.showNameEditor = false;
      });
      Column() {
        Text(this.t('Change Name')).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').margin({ top: 20, bottom: 12 });
        this.dialogField(this.firstNameDraft, this.t('First Name'), 64, (v: string): void => {
          this.firstNameDraft = v;
        });
        this.dialogField(this.lastNameDraft, this.t('Last Name'), 64, (v: string): void => {
          this.lastNameDraft = v;
        });
        this.dialogButtons((): void => {
          this.showNameEditor = false;
        }, (): void => {
          const first: string = this.firstNameDraft.trim();
          if (first.length === 0) {
            return;   // iOS：名字为空时 Save 不可用
          }
          this.showNameEditor = false;
          sendGroupCallAction('changeName', 0, `${first}\n${this.lastNameDraft.trim()}`);
        });
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  // ---------- 成员菜单（iOS VideoChatScreenParticipantContextMenu） ----------

  // iOS VoiceChatVolumeContextItem：整行滑杆 0–200%，左侧百分比、右侧喇叭；拖到 0 视为静音。
  @Builder
  volumeRow(m: GroupCallMemberState) {
    Stack() {
      Slider({ value: this.menuVolume, min: 0, max: 200, step: 1, style: SliderStyle.InSet })
        .width('100%')
        .height(44)
        .trackThickness(44)
        .trackColor('#00000000')
        .selectedColor(this.menuVolume > 100 ? '#33C659' : COLOR_ACCENT)
        .blockColor('#00000000')
        .trackBorderRadius(0)
        .selectedBorderRadius(0)
        .onChange((v: number, mode: SliderChangeMode): void => {
          this.menuVolume = Math.round(v);
          const done: boolean = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
          sendGroupCallAction(done ? 'setVolumeDone' : 'setVolume', m.peerId, `${this.menuVolume}`);
        });
      Row() {
        Text(`${this.menuVolume}%`).fontSize(17).fontColor('#FFFFFF');
        Blank();
        Image($r('app.media.vc_ic_speaker')).width(24).height(24).fillColor('#FFFFFF');
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 })
      .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height(44)
    .backgroundColor('#3A3A3C');
  }

  @Builder
  memberMenu(m: GroupCallMemberState) {
    Stack({ alignContent: Alignment.Bottom }) {
      this.scrim((): void => {
        this.menuMember = null;
      });
      Column() {
        Column() {
          Row() {
            this.avatarView(m, 40);
            Column() {
              Text(m.name).fontSize(17).fontColor('#FFFFFF').maxLines(1);
              Text(this.memberStatus(m)).fontSize(13).fontColor(this.memberStatusColor(m)).margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 10 })
            .layoutWeight(1);
          }
          .width('100%')
          .height(64)
          .padding({ left: 14, right: 14 });
          Divider().strokeWidth(0.5).color('#48484A');
          if (!m.isSelf) {
            // :44-70 —— 被管理员禁言或已被我静音时不给滑杆
            if (!(m.isMuted && !m.canSelfUnmute) && !m.mutedByYou) {
              this.volumeRow(m);
              Column().width('100%').height(8).backgroundColor('#33000000');
            }
            if (this.canManage) {
              // :168-204（管理员分支）
              if (m.isMuted && !m.canSelfUnmute) {
                this.menuRow(this.t('Allow to Speak'), '#FFFFFF', (): void => {
                  this.menuMember = null;
                  sendGroupCallAction('adminUnmute', m.peerId);
                  this.toast(`${m.name} can now speak`);
                }, m.raiseHand ? $r('app.media.vc_ic_ctx_allow') : $r('app.media.vc_ic_ctx_unmute'));
              } else {
                this.menuRow(this.t('Mute'), '#FFFFFF', (): void => {
                  this.menuMember = null;
                  sendGroupCallAction('adminMute', m.peerId);
                }, $r('app.media.vc_ic_ctx_mute'));
              }
            } else {
              // 普通成员：仅对自己静音（:211-228）
              this.menuRow(m.mutedByYou ? this.t('Unmute for Me') : this.t('Mute for Me'), '#FFFFFF', (): void => {
                this.menuMember = null;
                sendGroupCallAction(m.mutedByYou ? 'unmuteForMe' : 'muteForMe', m.peerId);
              }, m.mutedByYou ? $r('app.media.vc_ic_ctx_unmute') : $r('app.media.vc_ic_ctx_mute'));
            }
            // :245 Conversation_ContextMenuSendMessage
            this.menuRow(this.t('Send Message'), '#FFFFFF', (): void => {
              this.menuMember = null;
              sendGroupCallAction('sendMessageTo', m.peerId);
            }, $r('app.media.vc_ic_ctx_message'));
            if (this.canManage) {
              // :260 VoiceChat_RemovePeer（红）→ 确认
              this.menuRow(this.t('Remove'), COLOR_RED, (): void => {
                this.removeTarget = m;
                this.menuMember = null;
              }, $r('app.media.vc_ic_clear'));
            }
          } else if (this.selfIsUser) {
            // iOS 自己那一行：Add/Edit Bio、Change Name（没有 Mute 项——静音用大按钮）
            this.menuRow(m.about.length > 0 ? this.t('Edit Bio') : this.t('Add Bio'), '#FFFFFF', (): void => {
              this.menuMember = null;
              this.bioDraft = m.about;
              this.showBioEditor = true;
            }, $r('app.media.vc_ic_ctx_info'));
            this.menuRow(this.t('Change Name'), '#FFFFFF', (): void => {
              this.menuMember = null;
              this.firstNameDraft = this.selfFirstName;
              this.lastNameDraft = this.selfLastName;
              this.showNameEditor = true;
            }, $r('app.media.vc_ic_ctx_changename'));
          }
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .clip(true);
        Column() {
          this.sheetItem(this.t('Cancel'), COLOR_ACCENT, (): void => {
            this.menuMember = null;
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: SAFE_BOTTOM + 6 });
    }
    .width('100%')
    .height('100%');
  }

  // iOS :280-320 ActionSheet："Are you sure you want to remove %@ from the group chat?" [Remove] [Cancel]
  @Builder
  removeConfirm() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.scrim((): void => {
        this.removeTarget = null;
      });
      Column() {
        Column() {
          Text(`Are you sure you want to remove ${this.removeTarget?.name ?? ''} from the group chat?`)
            .fontSize(13)
            .fontColor(COLOR_SECONDARY)
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .width('100%');
          Divider().strokeWidth(0.5).color('#48484A');
          this.sheetItem(this.t('Remove'), COLOR_RED, (): void => {
            const id: number = this.removeTarget?.peerId ?? 0;
            this.removeTarget = null;
            if (id !== 0) {
              sendGroupCallAction('removeMember', id);
            }
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .clip(true);
        Column() {
          this.sheetItem(this.t('Cancel'), COLOR_ACCENT, (): void => {
            this.removeTarget = null;
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: SAFE_BOTTOM + 6 });
    }
    .width('100%')
    .height('100%');
  }

  // ---------- 预约（iOS VoiceChatController 的 schedule / scheduled 两种形态） ----------

  private syncTicker(): void {
    const need: boolean = this.mode === 'scheduled' || this.mode === 'setup';
    if (need && this.tickTimer < 0) {
      this.tickTimer = setInterval((): void => {
        this.nowTick = Date.now();
      }, 1000);
    } else if (!need && this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  private clock(d: Date): string {
    return `${this.pad2(d.getHours())}:${this.pad2(d.getMinutes())}`;
  }

  private dayWord(d: Date): string {
    const today: Date = new Date(this.nowTick);
    const startOfToday: number = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
    const diffDays: number = Math.floor((d.getTime() - startOfToday) / 86400000);
    if (diffDays === 0) {
      return 'today';
    }
    if (diffDays === 1) {
      return 'tomorrow';
    }
    const months: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return `on ${months[d.getMonth()]} ${d.getDate()}`;
  }

  // iOS 的选择器有 minimumDate：选到过去会弹回。这里选到过去就顶回 "现在 + 1 分钟"（滚轮跟着 selected 回弹）。
  private clampFuture(d: Date): Date {
    const min: number = Date.now() + 60000;
    return d.getTime() < min ? new Date(min) : d;
  }

  // ScheduleVoiceChat.ScheduleToday / ScheduleTomorrow / ScheduleOn
  private scheduleButtonTitle(): string {
    const word: string = this.dayWord(this.pickedDate);
    return word.startsWith('on ') ? `Start ${word} at ${this.clock(this.pickedDate)}` : `Start ${word} at ${this.clock(this.pickedDate)}`;
  }

  // "in 1 hour" / "in 25 minutes" —— ScheduleVoiceChat.GroupText 的 %@
  private inText(): string {
    const mins: number = Math.max(1, Math.round((this.pickedDate.getTime() - this.nowTick) / 60000));
    if (mins < 60) {
      return mins === 1 ? '1 minute' : `${mins} minutes`;
    }
    const hours: number = Math.round(mins / 60);
    if (hours < 24) {
      return hours === 1 ? '1 hour' : `${hours} hours`;
    }
    const days: number = Math.round(hours / 24);
    return days === 1 ? '1 day' : `${days} days`;
  }

  // 倒计时：<1 天 "HH:MM:SS"（不足 1 小时 "MM:SS"），否则 "N days"；过点后变 "Late by"
  private countdownText(): string {
    let left: number = Math.floor((this.scheduleDate * 1000 - this.nowTick) / 1000);
    if (left < 0) {
      left = -left;
    }
    if (left >= 86400) {
      const days: number = Math.round(left / 86400);
      return days === 1 ? '1 day' : `${days} days`;
    }
    const h: number = Math.floor(left / 3600);
    const m: number = Math.floor((left % 3600) / 60);
    const sec: number = left % 60;
    return h > 0 ? `${h}:${this.pad2(m)}:${this.pad2(sec)}` : `${this.pad2(m)}:${this.pad2(sec)}`;
  }

  private scheduledDateLine(): string {
    const d: Date = new Date(this.scheduleDate * 1000);
    const word: string = this.dayWord(d);
    const cap: string = word.startsWith('on ') ? word.substring(3) : word.charAt(0).toUpperCase() + word.substring(1);
    return `${cap} at ${this.clock(d)}`;
  }

  @Builder
  gradientPillButton(label: string, action: () => void) {
    Text(label)
      .width('100%')
      .height(50)
      .borderRadius(25)
      .fontSize(17)
      .fontWeight(600)
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .linearGradient({ angle: 90, colors: [['#0077FF', 0], ['#7C5CFF', 0.55], ['#C751C0', 1]] })
      .onClick(action);
  }

  // mode = 'new'：Start / Schedule 的选择
  @Builder
  newCallSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%').backgroundColor(COLOR_BG);
      Column() {
        Column() {
          this.sheetItem(this.t('Start Video Chat'), COLOR_ACCENT, (): void => {
            sendGroupCallAction('startNow');
          });
          Divider().strokeWidth(0.5).color('#48484A');
          this.sheetItem(this.t('Schedule Video Chat'), COLOR_ACCENT, (): void => {
            this.pickedDate = new Date(Date.now() + 3600 * 1000);
            sendGroupCallAction('openSchedule');
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .clip(true);
        Column() {
          this.sheetItem(this.t('Cancel'), COLOR_ACCENT, (): void => {
            sendGroupCallAction('closeSetup');
          });
        }
        .borderRadius(14)
        .backgroundColor('#F22C2C2E')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: SAFE_BOTTOM + 6 });
    }
    .width('100%')
    .height('100%');
  }

  // mode = 'setup'：选时间 + "Start today at 21:30"
  @Builder
  scheduleSetup() {
    Column() {
      Column().height(SAFE_TOP + 2);
      Stack() {
        Text(this.t('Schedule Video Chat')).fontSize(17).fontWeight(600).fontColor('#FFFFFF');
        Row() {
          Text(this.t('Cancel'))
            .fontSize(17)
            .fontColor(COLOR_ACCENT)
            .height(56)
            .padding({ left: 16, right: 16 })
            .onClick((): void => {
              sendGroupCallAction('closeSetup');
            });
          Blank();
        }
        .width('100%');
      }
      .width('100%')
      .height(56);
      Blank();
      Row() {
        DatePicker({
          start: new Date(this.nowTick),
          end: new Date(this.nowTick + 7 * 86400000),
          selected: this.pickedDate
        })
          .lunar(false)
          .textStyle({ color: '#99FFFFFF', font: { size: 18 } })
          .selectedTextStyle({ color: '#FFFFFF', font: { size: 22, weight: FontWeight.Medium } })
          .disappearTextStyle({ color: '#4DFFFFFF', font: { size: 15 } })
          .layoutWeight(3)
          .height(200)
          .onDateChange((d: Date): void => {
            const next: Date = new Date(this.pickedDate.getTime());
            next.setFullYear(d.getFullYear(), d.getMonth(), d.getDate());
            this.pickedDate = this.clampFuture(next);
          });
        TimePicker({ selected: this.pickedDate })
          .useMilitaryTime(true)
          .textStyle({ color: '#99FFFFFF', font: { size: 18 } })
          .selectedTextStyle({ color: '#FFFFFF', font: { size: 22, weight: FontWeight.Medium } })
          .disappearTextStyle({ color: '#4DFFFFFF', font: { size: 15 } })
          .layoutWeight(2)
          .height(200)
          .onChange((v: TimePickerResult): void => {
            const next: Date = new Date(this.pickedDate.getTime());
            next.setHours(v.hour, v.minute, 0, 0);
            this.pickedDate = this.clampFuture(next);
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16 });
      Blank();
      Text(`The members of the group will be notified that the video chat will start in ${this.inText()}.`)
        .fontSize(14)
        .fontColor(COLOR_SECONDARY)
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
        .margin({ bottom: 20 });
      Column() {
        // 文案随滚轮变化，不能按值传进 @Builder（不刷新）→ 直接内联
        Text(this.scheduleButtonTitle())
          .width('100%')
          .height(50)
          .borderRadius(25)
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .linearGradient({ angle: 90, colors: [['#0077FF', 0], ['#7C5CFF', 0.55], ['#C751C0', 1]] })
          .onClick((): void => {
            // iOS 要求至少晚于当前 ~10 秒；过去的时间直接顶到 1 分钟后
            const at: number = Math.max(this.pickedDate.getTime(), Date.now() + 60000);
            sendGroupCallAction('schedule', 0, `${Math.floor(at / 1000)}`);
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: SAFE_BOTTOM + 16 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG);
  }

  // mode = 'scheduled'：倒计时 + Start Now（管理员）/ Set Reminder
  @Builder
  scheduledView() {
    Column() {
      Column().height(SAFE_TOP + 2);
      Row() {
        this.roundIconButton($r('app.media.vc_ic_more'), 28, (): void => {
          if (this.routeCanManage) {
            this.showAbortConfirm = true;
          }
        });
        Column() {
          Text(this.title.length > 0 ? this.title : this.t('Video Chat'))
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#FFFFFF')
            .maxLines(1);
          Text(this.t('Scheduled')).fontSize(12).fontColor(COLOR_SECONDARY).margin({ top: 1 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);
        this.roundIconButton($r('app.media.vc_ic_minimize'), 28, (): void => {
          sendGroupCallAction('closeSetup');
        });
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 });
      Blank();
      Text(this.scheduleDate * 1000 >= this.nowTick ? this.t('Starts in') : this.t('Late by'))
        .fontSize(17)
        .fontWeight(600)
        .fontColor('#FFFFFF');
      Text(this.countdownText())
        .fontSize(54)
        .fontWeight(FontWeight.Bold)
        .fontColor('#7C8CFF')
        .fontFeature('"tnum" on')
        .margin({ top: 6 });
      Text(this.scheduledDateLine()).fontSize(17).fontColor('#FFFFFF').margin({ top: 8 });
      Blank();
      Column() {
        if (this.routeCanManage) {
          this.gradientPillButton(this.t('Start Now'), (): void => {
            sendGroupCallAction('startScheduled');
          });
        } else {
          // 按值传进 @Builder 的文案不会随状态刷新 → 用条件分支重建
          if (this.reminderSet) {
            this.gradientPillButton(this.t('Cancel Reminder'), (): void => {
              sendGroupCallAction('toggleReminder');
            });
          } else {
            this.gradientPillButton(this.t('Set Reminder'), (): void => {
              sendGroupCallAction('toggleReminder');
            });
          }
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: SAFE_BOTTOM + 16 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG);
  }

  // iOS VoiceChat.CancelConfirmation*："Abort Video Chat" / "Do you want to abort the scheduled video chat?"
  @Builder
  abortConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      this.scrim((): void => {
        this.showAbortConfirm = false;
      });
      Column() {
        Text(this.t('Abort Video Chat')).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').margin({ top: 20 });
        Text(this.t('Do you want to abort the scheduled video chat?'))
          .fontSize(13)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16 })
          .margin({ top: 4, bottom: 18 });
        Divider().strokeWidth(0.5).color('#48484A');
        Row() {
          Text(this.t('Cancel'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontColor(COLOR_ACCENT)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showAbortConfirm = false;
            });
          Divider().vertical(true).height(44).strokeWidth(0.5).color('#48484A');
          Text(this.t('Abort'))
            .layoutWeight(1)
            .height(44)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_RED)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.showAbortConfirm = false;
              sendGroupCallAction('cancelScheduled');
            });
        }
        .width('100%');
      }
      .width(270)
      .borderRadius(14)
      .backgroundColor('#F22C2C2E')
      .clip(true);
    }
    .width('100%')
    .height('100%');
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Column().height(SAFE_TOP + 2);
        this.topBar();
        this.videoGrid();
        if (this.expandedKey.length === 0) {
          this.memberList();
        }
        // 给底部浮层（按钮排）留出位置，列表最后几行不被盖住
        Column().height(SAFE_BOTTOM + 118);
      }
      .width('100%')
      .height('100%')
      .backgroundColor(COLOR_BG);

      // 输入时压暗其余内容，点一下收起（iOS inputDimView：black@40%，VideoChatScreen.swift:3404-3419）
      if (this.inputActive) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick((): void => {
            this.inputActive = false;
          });
      }

      // 底部浮层：消息胶囊自下而上叠在按钮排 / 输入条之上，不挤压成员列表
      Column() {
        this.messageList();
        if (this.inputActive) {
          this.inputPanel();
        } else {
          this.controls();
        }
      }
      .width('100%');

      if (this.showMoreMenu) {
        this.moreMenu();
      }
      if (this.showPermissionsMenu) {
        this.permissionsMenu();
      }
      if (this.showDisplayAsMenu) {
        this.displayAsMenu();
      }
      if (this.showLeaveSheet) {
        this.leaveSheet();
      }
      if (this.showInviteSheet) {
        this.inviteSheet();
      }
      if (this.addConfirmPeer !== null) {
        this.addConfirm();
      }
      if (this.showEndConfirm) {
        this.endConfirm();
      }
      if (this.showBioEditor) {
        this.bioEditor();
      }
      if (this.showNameEditor) {
        this.nameEditor();
      }
      if (this.showTitleEditor) {
        this.titleEditor();
      }
      if (this.menuMember !== null) {
        this.memberMenu(this.menuMember);
      }
      if (this.removeTarget !== null) {
        this.removeConfirm();
      }
      if (this.mode === 'new') {
        this.newCallSheet();
      } else if (this.mode === 'setup') {
        this.scheduleSetup();
      } else if (this.mode === 'scheduled') {
        this.scheduledView();
      }
      if (this.showAbortConfirm) {
        this.abortConfirm();
      }
    }
    .width('100%')
    .height('100%');
  }
}
