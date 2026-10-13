import { AbilityConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { registerAllCapabilities } from '../interop/InteropRegistry';
import { appStartup, dispatchEvent } from 'libohos_app_cangjie_entry.so';
import { InteropEvent } from '../interop/InteropContract';

interface NotificationClickPayload {
  peerId: string;
  peerType: string;
  peerName: string;
  msgId: string;
}

export default class EntryAbility extends UIAbility {
  // 冷启动时 Want 携带的外部 URI（tg:// / https://t.me/...）先缓存，
  // 待 onWindowStageCreate 里 appStartup（cangjie 侧订阅）完成后再投递——
  // dispatchEvent 是即时 fan-out、无重放缓冲，此时投递会被静默丢弃。
  private pendingExternalUri: string = '';
  // 冷启动由消息通知拉起时的会话参数（JSON），同 pendingExternalUri 等 appStartup 后再投递。
  private pendingNotificationClick: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onCreate');
    // CALL-BG: 供 impls 在无 UI 上下文时取 ability context（appStartup 早期
    // getContext() 为 undefined —— ContinuousTaskImpl 实锤）。
    globalThis.abilityContext = this.context;
    // 启动时注册所有 ArkTS 侧能力/router 实现进 cangjie（反转模式，SSOT §5）。
    registerAllCapabilities();
    // 只缓存不派发：cangjie 侧的 EVT_EXTERNAL_URI 订阅尚未建立（在下面
    // onWindowStageCreate 的 appStartup 之后才注册），此时派发不安全。
    this.pendingExternalUri = want.uri ?? '';
    this.pendingNotificationClick = this.notificationClickPayload(want);
  }

  // 消息通知 wantAgent 带回的会话参数（LocalNotificationImpl.getPeerAgent 写入）。
  // 对齐 iOS AppDelegate.userNotificationCenter(_:didReceive:) → openChatWhenReady(peerId, messageId)。
  private notificationClickPayload(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const peerId: Object | undefined = params['notif_peer_id'];
    if (peerId === undefined || String(peerId) === '' || String(peerId) === '0') {
      return '';
    }
    const peerType: Object | undefined = params['notif_peer_type'];
    const peerName: Object | undefined = params['notif_peer_name'];
    const msgId: Object | undefined = params['notif_msg_id'];
    const payload: NotificationClickPayload = {
      peerId: String(peerId),
      peerType: peerType === undefined ? '' : String(peerType),
      peerName: peerName === undefined ? '' : String(peerName),
      msgId: msgId === undefined ? '' : String(msgId)
    };
    return JSON.stringify(payload);
  }

  onDestroy(): void {
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // TC-0025：应用级沉浸式窗口铺底（对齐源侧 NativeWindowHostView.frame 归零 +
    // WindowContent.intrinsicInsets 分工）——窗口内容根铺满物理屏幕，安全区量测
    // 单独经 SAFE_AREA_CHANGED 通道下发，供页面自行内缩。必须在 loadContent 之前
    // 发起（不阻塞，失败只记日志），否则首帧仍按系统默认非沉浸式布局绘制。
    this.applyImmersiveWindowLayout(windowStage);

    // 应用级启动初始化（复刻原 cangjie MainAbility.onWindowStageCreate）。
    // 把 UIAbilityContext 传入 cangjie，cangjie 侧 createUIAbilityContextFromJSValue
    // 还原后交给 getAuthStorage().initialize(ctx) 等（原时机：onWindowStageCreate）。
    try {
      appStartup(this.context);
      hilog.info(0x0000, 'testTag', '%{public}s', 'appStartup invoked');
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'appStartup failed: %{public}s', JSON.stringify(e) ?? '');
    }

    // 冷启动系统色模式/字号缩放读取：与外部 URI 同一时机、同一理由——appStartup 已
    // 完成，cangjie 侧 EVT_CONFIGURATION_CHANGED 订阅已就位，dispatchEvent 无重放
    // 缓冲，早投会被丢弃。后续系统配置变更走 onConfigurationUpdate 增量投递。
    this.dispatchConfigurationChanged(this.context.config);

    // 冷启动缓存的外部 URI（若有）：appStartup 已完成，cangjie 侧 EVT_EXTERNAL_URI
    // 订阅已就位，此时投递才安全。
    if (this.pendingExternalUri.length > 0) {
      dispatchEvent(InteropEvent.EXTERNAL_URI, this.pendingExternalUri);
      hilog.info(0x0000, 'testTag', 'external uri dispatched: %{public}s', this.pendingExternalUri);
      this.pendingExternalUri = '';
    }
    if (this.pendingNotificationClick.length > 0) {
      dispatchEvent(InteropEvent.NOTIFICATION_CLICK, this.pendingNotificationClick);
      hilog.info(0x0000, 'testTag', 'notification click dispatched: %{public}s', this.pendingNotificationClick);
      this.pendingNotificationClick = '';
    }

    // CALL-BG: 首启请求通知授权——后台/桌面来电靠通知横幅+铃声触达（消息通知同理）。
    // 未授权时 isNotificationEnabled=false → 弹系统授权窗；已授权/被拒则静默。
    notificationManager.isNotificationEnabled().then((enabled: boolean) => {
      if (!enabled) {
        notificationManager.requestEnableNotification(this.context)
          .then(() => hilog.info(0x0000, 'testTag', 'notification permission granted'))
          .catch(() => hilog.info(0x0000, 'testTag', 'notification permission declined'));
      }
    }).catch(() => {});

    windowStage.loadContent('pages/Home', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色 / 字号缩放变更回调（如系统 Settings 切换 Dark mode）。事件通道与
    // 常量本就完整存在（interop.cj 的 EVT_CONFIGURATION_CHANGED、dispatchEvent、
    // subscribe），只是从未接通；此处补上发送端，接收端见 AppStartup.runAppStartup。
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onConfigurationUpdate');
    this.dispatchConfigurationChanged(newConfig);
  }

  // 冷启动读取（onWindowStageCreate）与热更新回调（onConfigurationUpdate）共用同一
  // 投递形态：字段值直接透传 ConfigurationConstant.ColorMode 序数 / fontSizeScale，
  // 不做任何翻译；两侧可选字段缺失时由 cangjie 侧订阅方（AppStartup.cj）定默认值。
  private dispatchConfigurationChanged(config: Configuration): void {
    dispatchEvent(InteropEvent.CONFIGURATION_CHANGED, JSON.stringify({
      colorMode: config.colorMode,
      fontSizeScale: config.fontSizeScale
    }));
  }

  // TC-0025 M1：ability 级开启沉浸式全屏布局，收回上/下沿系统条区域的背景所有权
  // 给应用（对齐源侧 NativeWindowHostView.frame 归零 + 高度补回）。不调用
  // setWindowSystemBarEnable —— 源侧竖屏从不隐藏状态栏，隐藏会直接回归 PASS 第 1 条。
  // statusBarContentColor 本次固定日间深色值；主题驱动字色是另一条已知缺口（本
  // 报告「观察项」），不在本次范围。
  private applyImmersiveWindowLayout(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window): void => {
      mainWindow.setWindowLayoutFullScreen(true).then((): void => {
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#FF000000',
          navigationBarContentColor: '#FF000000'
        }).catch((): void => {
          hilog.error(0x0000, 'testTag', 'setWindowSystemBarProperties failed');
        });
        // TC-0025 M4（生产者侧）：安全区量测下发通道。冷启动投一次，随后
        // avoidAreaChange 增量投递（折叠屏/旋转/系统条尺寸变化）。消费与逐页
        // 应用（padding）不在本 feature 范围。
        this.dispatchSafeAreaChanged(mainWindow);
        mainWindow.on('avoidAreaChange', (_data: window.AvoidAreaOptions): void => {
          this.dispatchSafeAreaChanged(mainWindow);
        });
      }).catch((): void => {
        hilog.error(0x0000, 'testTag', 'setWindowLayoutFullScreen failed');
      });
    }).catch((): void => {
      hilog.error(0x0000, 'testTag', 'applyImmersiveWindowLayout: getMainWindow failed');
    });
  }

  // 读取系统条 + 底部导航指示区两类避让区域，取较大者合并为一份 {top,bottom,left,right}
  // （vp），经既有 dispatchEvent 通道投递给 cangjie 侧 AppStartup 单例。
  private dispatchSafeAreaChanged(mainWindow: window.Window): void {
    try {
      const systemArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navIndicatorArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const top = px2vp(systemArea.topRect.height);
      const bottom = Math.max(px2vp(systemArea.bottomRect.height), px2vp(navIndicatorArea.bottomRect.height));
      const left = Math.max(px2vp(systemArea.leftRect.width), px2vp(navIndicatorArea.leftRect.width));
      const right = Math.max(px2vp(systemArea.rightRect.width), px2vp(navIndicatorArea.rightRect.width));
      dispatchEvent(InteropEvent.SAFE_AREA_CHANGED, JSON.stringify({ top, bottom, left, right }));
      // 桥接给 ArkTS 侧壳（如 DIALOG 模态壳）消费：这些壳挂在祖先 Navigation.expandSafeArea
      // 展开的容器下，自身拿到的布局盒本就从 y=0 起算；expandSafeArea 语义只能扩不能缩，
      // 无法在壳自己身上反向内缩出顶部安全区，只能由持有该值的这里对外发布。
      AppStorage.setOrCreate<number>('safeAreaTopVp', top);
    } catch (e) {
      hilog.error(0x0000, 'testTag', 'dispatchSafeAreaChanged failed: %{public}s', JSON.stringify(e) ?? '');
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 热启动路径：singleton launchType 下再次隐式/显式拉起走这里。能进 onNewWant
    // 说明 onWindowStageCreate 早已执行完、cangjie 侧订阅已就位，可直接 dispatch。
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onNewWant');
    const uri: string = want.uri ?? '';
    if (uri.length > 0) {
      dispatchEvent(InteropEvent.EXTERNAL_URI, uri);
      hilog.info(0x0000, 'testTag', 'onNewWant external uri: %{public}s', uri);
    }
    const notifClick: string = this.notificationClickPayload(want);
    if (notifClick.length > 0) {
      dispatchEvent(InteropEvent.NOTIFICATION_CLICK, notifClick);
      hilog.info(0x0000, 'testTag', 'onNewWant notification click: %{public}s', notifClick);
    }
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onForeground');
    // 熄屏 / 切后台期间系统会冻结进程并断开 MTProto 的 TCP 连接。回到前台时网络可达性
    // **并未变化**（一直有网），故 ReachabilityService 的监听器不会触发；
    // 而全应用没有任何一处主动重连 —— 连接只能等到下一次实际请求时被动重建
    // （MTProtoClient.sendRPCRequestConcurrent 里的
    //  `if (!transport.isConnected()) { transport.connect() }`），
    // 表现为亮屏后 "Connecting..." 持续 10~20 秒才消失。
    //
    // 对齐 iOS：Network.swift:961 以 shouldKeepConnection 信号驱动
    // mtProto.resume() / pause()，由**应用前后台状态**而非网络变化控制连接。
    //
    // 事件通道与常量本就完整存在（interop.cj 的 @Interop[ArkTS] dispatchEvent、
    // EVT_FOREGROUND_CHANGED、subscribe），只是从未接通；此处补上发送端，
    // 接收端见 AppStartup.runAppStartup。
    dispatchEvent(InteropEvent.FOREGROUND_CHANGED, '{"foreground":true}');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onBackground');
    // Keep the Cangjie side in sync with the real Ability lifecycle. Animated
    // message nodes use this signal to stop posting frame updates while ArkUI's
    // main queue is frozen in background; otherwise every 16–34 ms timer tick
    // is replayed on the next foreground and can trigger LIFECYCLE_TIMEOUT.
    dispatchEvent(InteropEvent.FOREGROUND_CHANGED, '{"foreground":false}');
  }
}
