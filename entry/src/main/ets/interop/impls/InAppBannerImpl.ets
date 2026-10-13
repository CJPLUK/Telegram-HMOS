// S7-59 In-app message banner (iOS ChatMessageNotificationItem + NotificationContainerController).
// Cangjie NotificationCoordinator decides (foreground, chat not visible, not muted, In-App Preview on)
// and calls INAPP_BANNER_SHOW with a JSON payload; this file stores it in AppStorage and the root
// container (pages/Home.ets) renders InAppNotificationBanner above the Navigation stack, so the
// banner shows over every page. Tapping it re-dispatches the payload as NOTIFICATION_CLICK, the
// same path a system-notification tap takes, which opens the chat.
//
// argJson (cangjie → ArkTS): {title, text, avatarPath, avatarLetter, avatarColor(number rgb),
//                             peerId, peerType, peerName, msgId}
import { registerArkFunc, dispatchEvent } from 'libohos_app_cangjie_entry.so';
import { InteropMethod, InteropEvent } from '../InteropContract';
import { window } from '@kit.ArkUI';

export const IN_APP_BANNER_KEY: string = 'inAppBannerPayload';

interface InAppBannerPayload {
  title?: string;
  text?: string;
  avatarPath?: string;
  avatarLetter?: string;
  avatarColor?: number;
  peerId?: string;
  peerType?: string;
  peerName?: string;
  msgId?: string;
}

export function registerInAppBanner(): void {
  registerArkFunc(InteropMethod.INAPP_BANNER_SHOW, (argJson: string, onResult: (r: string) => void): void => {
    // A monotonically changing value so an identical payload still re-triggers the banner.
    AppStorage.setOrCreate<string>(IN_APP_BANNER_KEY, `${Date.now()}\n${argJson}`);
    onResult('{"ok":true}');
  });
}

@Component
export struct InAppNotificationBanner {
  @StorageLink('inAppBannerPayload') @Watch('onPayload') payloadRaw: string = '';
  @State shown: boolean = false;
  @State offsetY: number = -160;
  @State title: string = '';
  @State text: string = '';
  @State avatarPath: string = '';
  @State avatarLetter: string = '';
  @State avatarColor: number = 0x317AFF;
  @State topInset: number = 0;
  private clickJson: string = '';
  private timerId: number = -1;
  private dragStartY: number = 0;

  onPayload(): void {
    const nl = this.payloadRaw.indexOf('\n');
    if (nl < 0) {
      return;
    }
    let p: InAppBannerPayload;
    try {
      p = JSON.parse(this.payloadRaw.substring(nl + 1)) as InAppBannerPayload;
    } catch (e) {
      return;
    }
    this.title = p.title ?? '';
    this.text = p.text ?? '';
    this.avatarPath = p.avatarPath ?? '';
    this.avatarLetter = p.avatarLetter ?? '';
    this.avatarColor = p.avatarColor ?? 0x317AFF;
    this.clickJson = JSON.stringify({
      peerId: p.peerId ?? '0',
      peerType: p.peerType ?? 'user',
      peerName: p.peerName ?? '',
      msgId: p.msgId ?? '0'
    });
    this.updateTopInset();
    this.present();
  }

  private updateTopInset(): void {
    try {
      window.getLastWindow(getContext(this)).then((w: window.Window): void => {
        const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.topInset = px2vp(area.topRect.height);
      }).catch((): void => {});
    } catch (e) {
    }
  }

  private present(): void {
    this.shown = true;
    this.getUIContext().animateTo({ duration: 350, curve: Curve.Friction }, () => {
      this.offsetY = 0;
    });
    this.resetTimer();
  }

  // iOS NotificationContainerControllerNode.resetTimeoutTimer: 5 s.
  private resetTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
    }
    this.timerId = setTimeout((): void => {
      this.timerId = -1;
      this.dismiss();
    }, 5000);
  }

  private dismiss(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.shown = false;
      }
    }, () => {
      this.offsetY = -160;
    });
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
    }
  }

  build() {
    if (this.shown) {
      Column() {
      Row() {
        Stack() {
          if (this.avatarPath.length > 0) {
            Image(this.avatarPath.startsWith('file://') ? this.avatarPath : 'file://' + this.avatarPath)
              .width(54)
              .height(54)
              .borderRadius(27)
              .objectFit(ImageFit.Cover);
          } else {
            Text(this.avatarLetter)
              .fontSize(22)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
              .width(54)
              .height(54)
              .borderRadius(27)
              .textAlign(TextAlign.Center)
              .backgroundColor('#' + ('000000' + Math.floor(this.avatarColor).toString(16)).slice(-6));
          }
        }
        .width(54)
        .height(54)
        .margin({ left: 12, right: 11 })

        Column() {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FF000000')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.text.replace(/\n\n/g, ' '))
            .fontSize(16)
            .fontColor('#FF000000')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 1 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ right: 10 })
      }
      .width('100%')
      .constraintSize({ minHeight: 74 })
      .padding({ top: 6, bottom: 6 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#F2F9F9F9')
      .backdropBlur(30)
      .borderRadius(24)
      .shadow({ radius: 16, color: '#26000000', offsetY: 4 })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: this.topInset + 4 })
      .translate({ y: this.offsetY })
      .onClick(() => {
        const payload = this.clickJson;
        this.dismiss();
        if (payload.length > 0) {
          dispatchEvent(InteropEvent.NOTIFICATION_CLICK, payload);
        }
      })
      .gesture(
        PanGesture({ direction: PanDirection.Vertical })
          .onActionStart((e: GestureEvent) => {
            this.dragStartY = this.offsetY;
            if (this.timerId >= 0) {
              clearTimeout(this.timerId);
              this.timerId = -1;
            }
          })
          .onActionUpdate((e: GestureEvent) => {
            this.offsetY = Math.min(0, this.dragStartY + e.offsetY);
          })
          .onActionEnd(() => {
            if (this.offsetY < -30) {
              this.dismiss();
            } else {
              this.getUIContext().animateTo({ duration: 200 }, () => {
                this.offsetY = 0;
              });
              this.resetTimer();
            }
          })
      )
    }
  }
}
