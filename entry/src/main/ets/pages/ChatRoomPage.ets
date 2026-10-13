import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { EmojiGridPanel } from './EmojiGridPanel';
import {
  setEmojiGridUpdateListener, setStickerGridUpdateListener, EmojiGridUpdate
} from '../interop/impls/EmojiGridImpl';
import { setAttachGridUpdateListener, AttachGridUpdate } from '../interop/impls/AttachGridImpl';
import { AttachPhotoGrid } from './AttachPhotoGrid';
import { setAttachMapUpdateListener, AttachMapUpdate } from '../interop/impls/AttachMapImpl';
import { setAttachLocationUpdateListener, AttachLocationUpdate } from '../interop/impls/AttachLocationImpl';
import { AttachLocationView } from './AttachLocationView';
import { dispatchEvent, registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { KeyboardAvoidMode, UIContext } from '@kit.ArkUI';

// WP-F P0-1：会话页键盘避让改为 RESIZE（与 GroupCallScreen.ets 同一做法）。默认 OFFSET 会把整页
// 上推一个键盘高度，头部（标题/头像）和置顶栏移出屏幕；iOS 键盘弹起时只压缩消息列表，头部和
// 置顶栏保持可见。仓颉侧在输入框每次取焦时通过 chatRoom.keyboardAvoid 再断言一次（页面栈上层
// 的 GroupCallScreen 退出时会把模式复位成 OFFSET）。
let chatRoomKeyboardAvoidCtx: UIContext | null = null;
function applyChatRoomKeyboardAvoid(resize: boolean): void {
  const ctx = chatRoomKeyboardAvoidCtx;
  if (ctx == null) {
    return;
  }
  try {
    ctx.setKeyboardAvoidMode(resize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.OFFSET);
  } catch (_e) {
    // 宿主不支持时保持平台默认
  }
}
registerArkFunc('chatRoom.keyboardAvoid', (arg: string, onResult: (r: string) => void): void => {
  applyChatRoomKeyboardAvoid(arg !== 'offset');
  onResult('{}');
});

// 系统返回键先交给仓颉会话页（ChatRoomPage.cj registerChatRoomBackHandler）：全屏图片/视频查看器
// 打开时仓颉关闭查看器并同步回调本函数表示已消费，本页留在栈里；否则照旧出栈返回上一页。
let chatRoomBackHandled: boolean = false;
registerArkFunc('chatRoom.backHandled', (_arg: string, onResult: (r: string) => void): void => {
  chatRoomBackHandled = true;
  onResult('{}');
});

// route_map buildFunction for "ChatRoomPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function chatRoomPageBuilder() {
  ChatRoomPageShell();
}

@Component
struct ChatRoomPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';

  // Phase1：ArkTS 表情网格覆盖层几何（px → vp 由 px2vp 转）
  @State emojiGridVisible: boolean = false;
  @State emojiGridX: number = 0;
  @State emojiGridY: number = 0;
  @State emojiGridW: number = 0;
  @State emojiGridH: number = 0;
  @State emojiGridGen: number = 0;
  @State emojiGridScrollRow: number = -1;
  @State emojiGridScrollSeq: number = 0;
  // 贴纸 Phase1 覆盖层（同构第二实例）
  @State stkGridVisible: boolean = false;
  @State stkGridX: number = 0;
  @State stkGridY: number = 0;
  @State stkGridW: number = 0;
  @State stkGridH: number = 0;
  @State stkGridGen: number = 0;
  @State stkGridScrollRow: number = -1;
  @State stkGridScrollSeq: number = 0;
  // 附件面板内嵌图库网格覆盖层（几何由仓颉 AttachmentPanel 占位块推送）
  @State attachGridVisible: boolean = false;
  @State attachGridX: number = 0;
  @State attachGridY: number = 0;
  @State attachGridW: number = 0;
  @State attachGridH: number = 0;
  // 附件面板 Location 页签系统地图覆盖层
  @State attachMapVisible: boolean = false;
  @State attachMapX: number = 0;
  @State attachMapY: number = 0;
  @State attachMapW: number = 0;
  @State attachMapH: number = 0;
  @State attachMapLat: number = 0;
  @State attachMapLng: number = 0;
  // Location 页签整块 ArkTS 覆盖层（AttachLocationView）：几何 + 状态 JSON
  @State attachLocVisible: boolean = false;
  @State attachLocX: number = 0;
  @State attachLocY: number = 0;
  @State attachLocW: number = 0;
  @State attachLocH: number = 0;
  @State attachLocState: string = '';

  aboutToAppear(): void {
    chatRoomKeyboardAvoidCtx = this.getUIContext();
    applyChatRoomKeyboardAvoid(true);
    setEmojiGridUpdateListener((u: EmojiGridUpdate): void => {
      this.emojiGridVisible = u.visible && u.w > 0 && u.h > 0;
      this.emojiGridX = px2vp(u.x);
      this.emojiGridY = px2vp(u.y);
      this.emojiGridW = px2vp(u.w);
      this.emojiGridH = px2vp(u.h);
      this.emojiGridGen = u.gen;
      // 导航跳转：行号先落，序号后落（@Watch 挂在序号上）
      this.emojiGridScrollRow = u.sr ?? -1;
      this.emojiGridScrollSeq = u.ss ?? 0;
    });
    setAttachGridUpdateListener((u: AttachGridUpdate): void => {
      this.attachGridVisible = u.visible && u.w > 0 && u.h > 0;
      this.attachGridX = px2vp(u.x);
      this.attachGridY = px2vp(u.y);
      this.attachGridW = px2vp(u.w);
      this.attachGridH = px2vp(u.h);
    });
    setAttachMapUpdateListener((u: AttachMapUpdate): void => {
      this.attachMapVisible = u.visible && u.w > 0 && u.h > 0;
      this.attachMapX = px2vp(u.x);
      this.attachMapY = px2vp(u.y);
      this.attachMapW = px2vp(u.w);
      this.attachMapH = px2vp(u.h);
      this.attachMapLat = u.lat;
      this.attachMapLng = u.lng;
    });
    setAttachLocationUpdateListener((u: AttachLocationUpdate, raw: string): void => {
      this.attachLocVisible = u.visible && u.w > 0 && u.h > 0;
      this.attachLocX = px2vp(u.x);
      this.attachLocY = px2vp(u.y);
      this.attachLocW = px2vp(u.w);
      this.attachLocH = px2vp(u.h);
      this.attachLocState = raw;
    });
    setStickerGridUpdateListener((u: EmojiGridUpdate): void => {
      this.stkGridVisible = u.visible && u.w > 0 && u.h > 0;
      this.stkGridX = px2vp(u.x);
      this.stkGridY = px2vp(u.y);
      this.stkGridW = px2vp(u.w);
      this.stkGridH = px2vp(u.h);
      this.stkGridGen = u.gen;
      this.stkGridScrollRow = u.sr ?? -1;
      this.stkGridScrollSeq = u.ss ?? 0;
    });
  }

  aboutToDisappear(): void {
    applyChatRoomKeyboardAvoid(false);
    chatRoomKeyboardAvoidCtx = null;
    setEmojiGridUpdateListener(null);
    setStickerGridUpdateListener(null);
    setAttachGridUpdateListener(null);
    setAttachMapUpdateListener(null);
    setAttachLocationUpdateListener(null);
  }

  build() {
    NavDestination() {
      Stack() {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'ChatRoomPage'
      })
        .width('100%')
        .height('100%')
        .expandSafeArea(
          [SafeAreaType.SYSTEM],
          [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]
        );
        if (this.emojiGridVisible) {
          EmojiGridPanel({
            gen: this.emojiGridGen,
            scrollRow: this.emojiGridScrollRow,
            scrollSeq: this.emojiGridScrollSeq
          })
            .position({ x: this.emojiGridX, y: this.emojiGridY })
            .width(this.emojiGridW)
            .height(this.emojiGridH);
        }
        if (this.stkGridVisible) {
          EmojiGridPanel({
            gen: this.stkGridGen,
            scrollRow: this.stkGridScrollRow,
            scrollSeq: this.stkGridScrollSeq,
            sticker: true
          })
            .position({ x: this.stkGridX, y: this.stkGridY })
            .width(this.stkGridW)
            .height(this.stkGridH);
        }
        if (this.attachGridVisible) {
          AttachPhotoGrid()
            .position({ x: this.attachGridX, y: this.attachGridY })
            .width(this.attachGridW)
            .height(this.attachGridH);
        }
        if (this.attachLocVisible) {
          AttachLocationView({ stateJson: this.attachLocState })
            .position({ x: this.attachLocX, y: this.attachLocY })
            .width(this.attachLocW)
            .height(this.attachLocH);
        }
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
    // 本页（重新）可见时用 RESIZE；被上层页面盖住时还原平台默认，上层页面按各自约定避让。
    .onShown((_reason: VisibilityChangeReason) => {
      chatRoomKeyboardAvoidCtx = this.getUIContext();
      applyChatRoomKeyboardAvoid(true);
    })
    .onHidden((_reason: VisibilityChangeReason) => {
      applyChatRoomKeyboardAvoid(false);
    })
    .onBackPressed((): boolean => {
      chatRoomBackHandled = false;
      dispatchEvent('chatRoomPage.backPressed', '{}');
      return chatRoomBackHandled;
    });
  }
}
