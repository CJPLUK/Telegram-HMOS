// Undo / 轻提示浮条的根叠加层宿主（iOS UndoOverlayController：挂在 window 级容器、非模态，
// 只有浮条本身接收触摸）。
//
// 仓颉 components/UndoToast.cj 此前只挂在 MainTabPage 的根 Stack 里；被 routerPush 页面盖住时退回
// bindContentCover 全屏模态层，浮条停留期间浮条以外的触摸全部被模态层吃掉（与 S3-25 的全屏透明层
// 同类问题）。本文件把 UndoToast 改挂到 ArkTS 根容器 pages/Home.ets 的 Stack 里、位于整个
// Navigation 栈之上（与 S7-59 InAppNotificationBanner 同一位置），所以在任何页面上都可见。
//
// 触摸 / 遮挡语义（对位 iOS UndoOverlayControllerNode.hitTest：面板矩形外返回 nil 透传，面板内由
// 面板自己吃掉）。历史上两版都出过问题：
//   - 第一版 `hitTestBehavior(shown ? Default : None)` + 零面积 responseRegion：整屏触摸失效——这两个
//     属性只作用于本自定义组件外面那层 `__Common__` 包装节点，而 CJHybridComponent 内部是
//     Column(100%) → NodeContainer(100%) → 仓颉根 Stack(100%) 一串铺满整屏、hitTestBehavior 为 Default
//     的子节点，命中测试仍会下探子树并挡住兄弟节点 Navigation。
//   - 第二版（c628716f5）常驻全屏 + 隐藏 `.enabled(false)` / 显示 `HitTestMode.Transparent`：命中测试
//     确实透传了，但节点本身仍然是一块常驻、铺满整屏、叠在 Navigation 之上的可见区域。系统相册选择
//     器（PhotoViewPicker → com.huawei.hmos.photos PickerUIExtensionAbility，安全访问模式）这类
//     安全控件 / UIExtension 在响应点击前会核对自己是否被宿主应用的其它组件覆盖，被覆盖即拒绝点击
//     ——它不看 hitTest 结果，只看有没有节点压在自己上面（S3-10：附件面板里相册选择器完全点不动，
//     应用自己的关闭按钮可点；W3 尚无本叠加层时正常）。
// 本版让叠加层"不显示时不存在、显示时只有浮条那么大"：
//   1. 隐藏：外层 `.visibility(Visibility.None)`——不参与布局、不渲染、没有帧矩形，任何组件之上都
//      没有它；再叠一道 `.enabled(false)`。NodeController.makeNode 在 NodeContainer 创建时就执行
//      （与 visibility 无关），所以仓颉 UndoToast 照常在 aboutToAppear 向 UndoToastService 注册
//      presenter，不能按 shown 条件创建/销毁也不必。
//   2. 显示、尚未测量（仓颉侧 visible 翻转的同一回合推来 w/h=0）：外层与内层都铺满，让仓颉侧按
//      整屏布局量出浮条矩形；这一两帧内外层 HitTestMode.Transparent，不阻塞下层页面。
//   3. 显示、已测量：外层收缩成浮条矩形（外扩 PAD vp）并 `.clip(true)`，内层 CJHybridComponent 保持
//      测量时的整屏尺寸（onAreaChange 记下的 fullW/fullH，不用 display 推算——键盘抬起时页面会
//      变矮）、用 position 反向平移 (-x, -y)，浮条正好落在外层矩形里，仓颉侧布局输入不变、矩形不
//      会因容器变化而抖动。此时压在 Navigation 之上的只有浮条本身那一块；外层 clip 让矩形外的
//      触摸根本不进入子树，矩形内由浮条 / Undo 的 onClick 赢得手势仲裁（c628716f5 已验证）。
// responseRegion 继续按仓颉推送的浮条矩形设置在内层（内层坐标系与仓颉根节点一致）。
// 显隐信号（visible）在仓颉侧 visible 翻转的同一回合推送，不等浮条测量完成；矩形随 onAreaChange 补推。
//
// argJson (cangjie → ArkTS): {visible: boolean, x, y, w, h}（vp；未测量时 w/h 为 0）
import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';

export const UNDO_TOAST_REGION_KEY: string = 'undoToastRegion';

// 外层矩形在浮条四周外扩的余量（vp）：吸收 px 取整，避免圆角边被裁掉一像素；余量带内触摸仍透传。
const UNDO_TOAST_CLIP_PAD: number = 2;

interface UndoToastRegionPayload {
  visible?: boolean;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
}

export function registerUndoToastOverlay(): void {
  registerArkFunc(InteropMethod.UNDO_TOAST_REGION, (argJson: string, onResult: (r: string) => void): void => {
    AppStorage.setOrCreate<string>(UNDO_TOAST_REGION_KEY, argJson);
    onResult('{"ok":true}');
  });
}

@Component
export struct UndoToastOverlayHost {
  @StorageLink('undoToastRegion') @Watch('onRegion') regionRaw: string = '';
  @State shown: boolean = false;
  @State regionX: number = 0;
  @State regionY: number = 0;
  @State regionW: number = 0;
  @State regionH: number = 0;
  // 内层 CJHybridComponent 铺满时量到的整屏尺寸（vp）；仓颉侧浮条矩形就是在这个尺寸下量出来的。
  @State fullW: number = 0;
  @State fullH: number = 0;

  onRegion(): void {
    let p: UndoToastRegionPayload;
    try {
      p = JSON.parse(this.regionRaw) as UndoToastRegionPayload;
    } catch (e) {
      return;
    }
    const w = p.w ?? 0;
    const h = p.h ?? 0;
    const visible = p.visible ?? false;
    const measured = visible && w > 0 && h > 0;
    this.shown = visible;
    this.regionX = measured ? (p.x ?? 0) : 0;
    this.regionY = measured ? (p.y ?? 0) : 0;
    this.regionW = measured ? w : 0;
    this.regionH = measured ? h : 0;
  }

  aboutToAppear(): void {
    // @StorageLink 初始化不触发 @Watch：宿主重建时若 AppStorage 已有区域值，先按它同步一次。
    if (this.regionRaw.length > 0) {
      this.onRegion();
    }
  }

  /** 已显示、浮条矩形与整屏尺寸都已知：外层可以收缩到浮条矩形。 */
  private clipped(): boolean {
    return this.shown && this.regionW > 0 && this.regionH > 0 && this.fullW > 0 && this.fullH > 0;
  }

  private hostWidth(): Length {
    return this.clipped() ? this.regionW + UNDO_TOAST_CLIP_PAD * 2 : '100%';
  }

  private hostHeight(): Length {
    return this.clipped() ? this.regionH + UNDO_TOAST_CLIP_PAD * 2 : '100%';
  }

  private hostPosition(): Position {
    if (!this.clipped()) {
      return { x: 0, y: 0 };
    }
    return { x: this.regionX - UNDO_TOAST_CLIP_PAD, y: this.regionY - UNDO_TOAST_CLIP_PAD };
  }

  private innerWidth(): Length {
    return this.clipped() ? this.fullW : '100%';
  }

  private innerHeight(): Length {
    return this.clipped() ? this.fullH : '100%';
  }

  private innerPosition(): Position {
    if (!this.clipped()) {
      return { x: 0, y: 0 };
    }
    return { x: UNDO_TOAST_CLIP_PAD - this.regionX, y: UNDO_TOAST_CLIP_PAD - this.regionY };
  }

  build() {
    // 常驻挂载：仓颉 UndoToast 在 aboutToAppear 向 UndoToastService 注册 presenter，
    // 必须在任何 showUndo() 之前就存在，因此不能按 shown 条件创建/销毁。显隐 / 覆盖语义见文件头。
    Stack({ alignContent: Alignment.TopStart }) {
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'UndoToastOverlay'
      })
        .width(this.innerWidth())
        .height(this.innerHeight())
        .position(this.innerPosition())
        .hitTestBehavior(HitTestMode.Transparent)
        .responseRegion({ x: this.regionX, y: this.regionY, width: this.regionW, height: this.regionH })
        .onAreaChange((_o: Area, n: Area): void => {
          // 只在铺满阶段记录整屏尺寸；收缩阶段内层尺寸是我们自己写死的 fullW/fullH，不回写。
          if (!this.clipped()) {
            this.fullW = n.width as number;
            this.fullH = n.height as number;
          }
        })
    }
    .width(this.hostWidth())
    .height(this.hostHeight())
    .position(this.hostPosition())
    .clip(true)
    .visibility(this.shown ? Visibility.Visible : Visibility.None)
    .enabled(this.shown)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
