// 附件面板 Location 页签（ArkTS 整块实现，对位 iOS LocationPickerControllerNode）。
//
// 布局：地图 header 固定在顶部，列表上滑时 header 高度 = max(0, 200 − offset) 逐渐收缩、
// 地图在其中居中（iOS updateFloatingHeaderOffset → headerFrame.height = listOffset）；
// 列表内容从地图下方开始并盖过地图。滚动、展开/收起、搜索框全在本进程内，只有
// 「发送 / 搜索 / 重试」动作经 dispatchEvent 回仓颉。
import { AttachMapView } from './AttachMapView';
import { AttachLocationUpdate, AttachVenue, sendAttachLocationAction } from '../interop/impls/AttachLocationImpl';

const MAP_HEIGHT: number = 200;

@Component
export struct AttachLocationView {
  @Prop @Watch('onStateChanged') stateJson: string = '';
  @State ready: boolean = false;
  @State loading: boolean = true;
  @State permission: boolean = true;
  @State error: string = '';
  @State name: string = '';
  @State accuracy: number = 0;
  @State lat: number = 0;
  @State lng: number = 0;
  @State venuesLoading: boolean = false;
  @State venues: AttachVenue[] = [];
  @State query: string = '';
  @State showDuration: boolean = false;
  @State showSearch: boolean = false;
  @State scrollY: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.applyState();
  }

  onStateChanged(): void {
    this.applyState();
  }

  private applyState(): void {
    if (this.stateJson.length === 0) {
      return;
    }
    try {
      const s: AttachLocationUpdate = JSON.parse(this.stateJson) as AttachLocationUpdate;
      this.ready = s.ready;
      this.loading = s.loading;
      this.permission = s.permission;
      this.error = s.error ?? '';
      this.name = s.name ?? '';
      this.accuracy = s.accuracy ?? 0;
      const lat: number = parseFloat(s.lat);
      const lng: number = parseFloat(s.lng);
      this.lat = isNaN(lat) ? 0 : lat;
      this.lng = isNaN(lng) ? 0 : lng;
      this.venuesLoading = s.venuesLoading;
      this.venues = s.venues ?? [];
    } catch (e) {
      console.error(`[AttachLocation] bad state: ${JSON.stringify(e)}`);
    }
  }

  private mapHeight(): number {
    const h: number = MAP_HEIGHT - this.scrollY;
    return h > 0 ? h : 0;
  }

  private subtitle(): string {
    if (this.ready) {
      return this.accuracy > 0 ? `Accurate to ${this.accuracy} m` : 'Accurate to 5 m';
    }
    return 'Waiting for GPS...';
  }

  private mapAreaText(): string {
    if (this.loading) {
      return '正在获取位置...';
    }
    if (!this.permission) {
      return '未授权位置权限';
    }
    if (this.error.length > 0) {
      return this.error;
    }
    return this.name;
  }

  private submitSearch(): void {
    sendAttachLocationAction('search', 0, '', this.query);
  }

  @Builder
  durationRow(title: string, seconds: number) {
    Row() {
      Image($r('app.media.loc_ic_clock'))
        .width(16).height(16).fillColor('#0088CC')
        .margin({ left: 8, right: 12 });
      Text(title).fontSize(16).fontColor('#0088CC');
    }
    .width('100%')
    .height(48)
    .padding({ left: 48, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#F8F8F8')
    .onClick((): void => {
      sendAttachLocationAction('sendLive', seconds, '', '');
    });
  }

  @Builder
  venueRow(v: AttachVenue) {
    Row() {
      Text(v.label)
        .fontSize(16).fontColor('#FFFFFF')
        .width(40).height(40).borderRadius(20)
        .backgroundColor(v.color)
        .textAlign(TextAlign.Center);
      Column() {
        Text(v.title).fontSize(16).fontColor('#000000').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(v.address).fontSize(13).fontColor('#8E8E93').margin({ top: 2 }).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 });
    }
    .width('100%')
    .height(60)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      sendAttachLocationAction('sendVenue', 0, v.id, '');
    });
  }

  @Builder
  mapPlaceholder() {
    Column() {
      if (this.loading) {
        LoadingProgress().width(48).height(48).color('#0088CC');
        Text('正在获取位置...').fontSize(14).fontColor('#8E8E93').margin({ top: 12 });
      } else if (!this.permission) {
        Image($r('app.media.loc_ic_maprow')).width(40).height(40).fillColor('#FF3B30');
        Text('需要位置权限').fontSize(16).fontColor('#FF3B30').margin({ top: 8 });
        Text('请在系统设置中授权位置权限').fontSize(13).fontColor('#8E8E93').margin({ top: 4 });
        Text('重新请求权限').fontSize(15).fontColor('#0088CC').margin({ top: 12 })
          .onClick((): void => {
            sendAttachLocationAction('retry', 0, '', '');
          });
      } else {
        Image($r('app.media.loc_ic_maprow')).width(48).height(48).fillColor('#0088CC');
        Text(this.mapAreaText()).fontSize(14).fontColor('#8E8E93').margin({ top: 8 });
      }
    }
    .width('100%')
    .height(MAP_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#E8E8E8');
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 固定地图 header：高度随滚动收缩，内容居中裁剪
      Stack({ alignContent: Alignment.Center }) {
        if (this.ready) {
          AttachMapView({ lat: this.lat, lng: this.lng })
            .width('100%')
            .height(MAP_HEIGHT);
        } else {
          this.mapPlaceholder();
        }
      }
      .width('100%')
      .height(this.mapHeight())
      .clip(true);

      Scroll(this.scroller) {
        Column() {
          Blank().height(MAP_HEIGHT);
          Column() {
            // 操作卡片
            Column() {
              Row() {
                Image($r('app.media.loc_ic_sendlocation'))
                  .width(20).height(20)
                  .fillColor(this.ready ? '#0088CC' : '#C7C7CC')
                  .margin({ right: 12 });
                Column() {
                  Text('Send My Current Location').fontSize(17).fontColor(this.ready ? '#000000' : '#C7C7CC');
                  Text(this.subtitle()).fontSize(13).fontColor('#8E8E93').margin({ top: 2 });
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
              }
              .width('100%')
              .height(60)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .onClick((): void => {
                if (this.ready) {
                  sendAttachLocationAction('sendCurrent', 0, '', '');
                }
              });

              Divider().color('#E5E5EA').strokeWidth(1).margin({ left: 48 });

              Row() {
                Image($r('app.media.loc_ic_sendlive'))
                  .width(20).height(20)
                  .fillColor(this.ready ? '#34C759' : '#C7C7CC')
                  .margin({ right: 12 });
                Column() {
                  Text('Share My Live Location for...').fontSize(17).fontColor(this.ready ? '#000000' : '#C7C7CC');
                  Text('Updated in real time as you move').fontSize(13).fontColor('#8E8E93').margin({ top: 2 });
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(this.showDuration ? '▲' : '▼').fontSize(12).fontColor('#C7C7CC');
              }
              .width('100%')
              .height(60)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .onClick((): void => {
                if (this.ready) {
                  this.showDuration = !this.showDuration;
                }
              });

              if (this.showDuration) {
                Divider().color('#E5E5EA').strokeWidth(1).margin({ left: 48 });
                this.durationRow('15 minutes', 900);
                Divider().color('#E5E5EA').strokeWidth(1).margin({ left: 48 });
                this.durationRow('1 hour', 3600);
                Divider().color('#E5E5EA').strokeWidth(1).margin({ left: 48 });
                this.durationRow('8 hours', 28800);
              }
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16, top: 16 });

            // 附近地点
            if (this.ready) {
              Row() {
                Text('OR CHOOSE A PLACE').fontSize(13).fontColor('#8E8E93').layoutWeight(1);
                Text('⌕').fontSize(18).fontColor('#007AFF')
                  .onClick((): void => {
                    this.showSearch = !this.showSearch;
                    if (!this.showSearch && this.query.length > 0) {
                      this.query = '';
                      this.submitSearch();
                    }
                  });
              }
              .width('100%')
              .padding({ left: 32, right: 32, top: 18, bottom: 6 });

              if (this.showSearch) {
                TextInput({ text: this.query, placeholder: 'Search places' })
                  .width('100%')
                  .height(36)
                  .fontSize(15)
                  .backgroundColor('#E3E3E8')
                  .borderRadius(10)
                  .padding({ left: 12, right: 12 })
                  .margin({ left: 16, right: 16, bottom: 8 })
                  .onChange((v: string): void => {
                    this.query = v;
                  })
                  .onSubmit((): void => {
                    this.submitSearch();
                  });
              }

              if (this.venuesLoading) {
                Column() {
                  LoadingProgress().width(24).height(24).color('#007AFF');
                }
                .width('100%')
                .padding({ top: 16, bottom: 16 })
                .alignItems(HorizontalAlign.Center);
              } else if (this.venues.length > 0) {
                Column() {
                  ForEach(this.venues, (v: AttachVenue): void => {
                    this.venueRow(v);
                  }, (v: AttachVenue, idx: number): string => `v_${idx}_${v.id}`);
                }
                .width('100%')
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
                .margin({ left: 16, right: 16 })
                .clip(true);
              } else {
                Text('No places found nearby').fontSize(13).fontColor('#8E8E93')
                  .width('100%').textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 });
              }
            }
            Blank().height(24);
          }
          .width('100%')
          .backgroundColor('#F2F2F7');
        }
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .scrollBar(BarState.Off)
      .onDidScroll((): void => {
        const off: OffsetResult = this.scroller.currentOffset();
        const y: number = off.yOffset > 0 ? off.yOffset : 0;
        if (Math.abs(y - this.scrollY) >= 1) {
          this.scrollY = y;
        }
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
    .clip(true);
  }
}
