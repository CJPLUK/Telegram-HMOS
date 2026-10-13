// 附件面板 Location 页签的系统地图（HMS Map Kit MapComponent）。
// 初始化失败（如 1002600003 App authentication failed：应用未在 AGC 注册/未配置 client_id）
// 时本组件渲染为空，让仓颉侧的 OSM 快照兜底显示。
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';

@Component
export struct AttachMapView {
  @Prop lat: number = 0;
  @Prop lng: number = 0;
  @State failed: boolean = false;
  private controller: map.MapComponentController | undefined = undefined;
  private mapOptions: mapCommon.MapOptions = {
    position: {
      target: { latitude: 0, longitude: 0 },
      zoom: 15
    },
    zoomControlsEnabled: false,
    myLocationControlsEnabled: false
  };
  private mapCallback: AsyncCallback<map.MapComponentController> =
    (err: BusinessError, ctrl: map.MapComponentController): void => {
      if (err) {
        console.error(`[AttachMap] MapComponent init failed: code=${err.code} msg=${err.message}`);
        this.failed = true;
        return;
      }
      this.controller = ctrl;
      console.info('[AttachMap] MapComponent ready');
      this.applyPosition();
    };

  private applyPosition(): void {
    if (this.controller === undefined) {
      return;
    }
    try {
      const target: mapCommon.LatLng = { latitude: this.lat, longitude: this.lng };
      this.controller.moveCamera(map.newLatLng(target, 15));
      // iOS 在地图中心画用户头像针脚；这里用系统标记 + 我的位置蓝点
      const marker: mapCommon.MarkerOptions = { position: target };
      this.controller.addMarker(marker).catch((e: BusinessError): void => {
        console.error(`[AttachMap] addMarker failed: ${e.code}`);
      });
      this.controller.setMyLocationEnabled(true);
    } catch (e) {
      console.error(`[AttachMap] applyPosition error: ${JSON.stringify(e)}`);
    }
  }

  aboutToAppear(): void {
    this.mapOptions = {
      position: {
        target: { latitude: this.lat, longitude: this.lng },
        zoom: 15
      },
      zoomControlsEnabled: false,
      myLocationControlsEnabled: false
    };
  }

  build() {
    Column() {
      if (!this.failed) {
        MapComponent({ mapOptions: this.mapOptions, mapCallback: this.mapCallback })
          .width('100%')
          .height('100%');
      }
    }
    .width('100%')
    .height('100%')
    .clip(true);
  }
}
