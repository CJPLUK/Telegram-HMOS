import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { setVideoCallSurface, clearVideoCallSurface } from 'libohos_app_cangjie_entry.so';

// route_map buildFunction for "VideoCallScreen": 薄 ArkTS NavDestination 壳，内嵌仓颉页。
@Builder
export function videoCallScreenBuilder() {
  VideoCallScreenShell();
}

@Component
struct VideoCallScreenShell {
  // CTL-SHARED-003: push 转场位移/遮罩(由 CustomTransition 驱动)
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  private ctNavId: string = '';
  // 视频底图：HW 解码器 GPU 直渲到此 XComponent surface（零 CPU 拷贝，对齐 iOS）。
  private xcCtrl: XComponentController = new XComponentController();
  // 本 shell 绑定的 surfaceId。销毁时用它做 sid 匹配清除——双 push 场景下旧 shell
  // 的 onDisAppear 可能晚于新 shell 的 onLoad，无条件清零会误杀新绑定。
  private mySurfaceId: string = '0';
  build() {
    NavDestination() {
      Stack() {
      // 底层：远端视频 GPU 直渲面。仓颉控件(CJHybridComponent)浮在其上，
      // 仓颉侧远端视频区透明化后此面透出。
      XComponent({
        id: 'remoteVideoSurface',
        type: XComponentType.SURFACE,
        controller: this.xcCtrl
      })
        .onLoad(() => {
          const sid: string = this.xcCtrl.getXComponentSurfaceId();
          this.mySurfaceId = sid;
          setVideoCallSurface(sid);
        })
        .width('100%')
        .height('100%');
      CJHybridComponent({
        library: 'ohos_app_cangjie_entry',
        component: 'VideoCallScreen'
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
      // 释放 surface（sid 匹配：仅当本 shell 的绑定仍有效才清，防误杀新 shell）。
      clearVideoCallSurface(this.mySurfaceId);
      CustomTransition.unregister(this.ctNavId);
    });
  }
}
