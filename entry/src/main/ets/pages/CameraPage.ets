import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { publishCameraPreviewSurface, clearCameraPreviewSurface, setCameraPreviewLayoutListener,
  CameraPreviewLayout } from '../interop/impls/CameraPreviewImpl';

// route_map buildFunction for "CameraPage": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
// 取景 XComponent 垫在仓颉页下方（同 VideoCallScreen 远端视频面）：仓颉预览区透明，控件浮在其上。
@Builder
export function cameraPageBuilder() {
  CameraPageShell();
}

@Component
struct CameraPageShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  // 取景面布局：round/square → 1:1（round 再圆形裁剪）；否则 9:16 竖屏，对应 1920x1080 预览档
  @State pvRound: boolean = false;
  @State pvSquare: boolean = false;
  private xcCtrl: XComponentController = new XComponentController();

  aboutToAppear(): void {
    setCameraPreviewLayoutListener((l: CameraPreviewLayout): void => {
      this.pvRound = l.round;
      this.pvSquare = l.square;
    });
  }

  aboutToDisappear(): void {
    setCameraPreviewLayoutListener(null);
    clearCameraPreviewSurface();
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'cameraPreviewSurface',
          type: XComponentType.SURFACE,
          controller: this.xcCtrl
        })
          .onLoad(() => {
            publishCameraPreviewSurface(this.xcCtrl.getXComponentSurfaceId());
          })
          .width('100%')
          .aspectRatio((this.pvRound || this.pvSquare) ? 1 : 9 / 16)
          .borderRadius(this.pvRound ? 1000 : 0)
          .clip(true);
        CJHybridComponent({
          library: 'ohos_app_cangjie_entry',
          component: 'CameraPage'
        })
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
      .backgroundColor(Color.Black)
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
    });
  }
}
