// 位置 / 实时位置查看页（对位 iOS LocationUI/LocationViewController，glass 版）。
//
// 结构：底层 CJHybridComponent('LocationViewPage') 只做数据（读参数、定位、筛活跃实时位置、
// 推状态、收动作）；上层 LocationViewContent 全 ArkTS：HMS 地图 + 玻璃按钮（关闭 / Share|Show All /
// 标题）+ 地图右下控制组（地图模式 / 定位）+ 可折叠列表（info / 分享-停止 / 参与者）。
// 列表初始从 topInset = 屏高 − 100（live 再 +66）处露出；上推列表先收缩地图区（iOS
// updateFloatingHeaderOffset），到底后再滚列表内容。
import { CJHybridComponent } from '@cangjie/cjhybridcomponent';
import { CustomTransition } from '../router/CustomTransition';
import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { image } from '@kit.ImageKit';
import { display, LengthMetricsUnit } from '@kit.ArkUI';
import {
  setLocationViewUpdateListener, sendLocationViewAction,
  LocationViewState, LocationViewParticipant
} from '../interop/impls/LocationViewImpl';

@Builder
export function locationViewPageBuilder() {
  LocationViewPageShell();
}

@Component
struct LocationViewPageShell {
  @State ctTransX: number = 0;
  @State ctTransY: number = 0;
  @State ctDim: number = 0;
  @State stateJson: string = '';
  private ctNavId: string = '';

  aboutToAppear(): void {
    setLocationViewUpdateListener((raw: string): void => {
      this.stateJson = raw;
    });
  }

  aboutToDisappear(): void {
    setLocationViewUpdateListener(null);
  }

  build() {
    NavDestination() {
      Stack() {
        CJHybridComponent({
          library: 'ohos_app_cangjie_entry',
          component: 'LocationViewPage'
        })
          .width('100%')
          .height('100%');
        LocationViewContent({ stateJson: this.stateJson })
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
    });
  }
}

interface PinInfo {
  avatar: string;
  name: string;
  isSelf: boolean;
  pixel: image.PixelMap | null;
}

interface ParticipantRow {
  msgId: number;
  peerId: number;
  isSelf: boolean;
  name: string;
  avatar: string;
  lat: number;
  lng: number;
  heading: number;
  updated: number;
  begin: number;
  period: number;
}

const LIVE_INDEFINITE: number = 0x7fffffff;
const SAFE_TOP: number = 36;
const SAFE_BOTTOM: number = 28;

function toNum(s: string): number {
  const v: number = parseFloat(s);
  return isNaN(v) ? 0 : v;
}

function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r: number = 6371000;
  const dLat: number = (lat2 - lat1) * Math.PI / 180;
  const dLon: number = (lon2 - lon1) * Math.PI / 180;
  const a: number = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/** iOS Locale.usesMetricSystem：US / LR / MM 为英制（MKDistanceFormatter → yd / mi） */
function usesImperial(): boolean {
  try {
    const region: string = i18n.System.getSystemRegion();
    return region === 'US' || region === 'LR' || region === 'MM';
  } catch (_e) {
    return false;
  }
}

const IMPERIAL: boolean = usesImperial();

/** iOS shortStringForDistance（MKDistanceFormatter abbreviated） */
function distanceString(meters: number): string {
  if (IMPERIAL) {
    const yards: number = meters / 0.9144;
    if (yards < 1760) {
      return `${Math.round(yards)} yd`;
    }
    return `${(yards / 1760).toFixed(1)} mi`;
  }
  if (meters < 1000) {
    return `${Math.round(meters)} m`;
  }
  return `${(meters / 1000).toFixed(1)} km`;
}

/** iOS stringForRelativeLiveLocationTimestamp */
function updatedString(updated: number, now: number): string {
  const diff: number = Math.max(0, now - updated);
  if (diff < 60) {
    return 'updated just now';
  }
  if (diff < 3600) {
    const m: number = Math.floor(diff / 60);
    return m === 1 ? 'updated 1 minute ago' : `updated ${m} minutes ago`;
  }
  if (diff < 86400) {
    const h: number = Math.floor(diff / 3600);
    return h === 1 ? 'updated 1 hour ago' : `updated ${h} hours ago`;
  }
  const d: number = Math.floor(diff / 86400);
  return d === 1 ? 'updated 1 day ago' : `updated ${d} days ago`;
}

/** iOS ChatMessageLiveLocationTimerNode 文案：分钟数 / "Nh" / "∞" */
function remainingLabel(begin: number, period: number, now: number): string {
  if (period === LIVE_INDEFINITE) {
    return '∞';
  }
  const remaining: number = Math.max(0, begin + period - now);
  if (remaining > 3600) {
    const h: number = Math.round(remaining / 3600);
    return h > 99 ? '99+' : `${h}h`;
  }
  return `${Math.round(remaining / 60)}`;
}

function remainingProgress(begin: number, period: number, now: number): number {
  if (period === LIVE_INDEFINITE || period <= 0) {
    return 1;
  }
  const remaining: number = Math.max(0, begin + period - now);
  return Math.min(1, remaining / period);
}

@Component
struct LocationViewContent {
  @Prop @Watch('onStateChanged') stateJson: string = '';
  @State subjectLat: number = 0;
  @State subjectLng: number = 0;
  @State subjectIsLive: boolean = false;
  @State subjectTitle: string = '';
  @State subjectVenueTitle: string = '';
  @State subjectVenueAddress: string = '';
  @State subjectMsgId: number = 0;
  @State subjectIsSent: boolean = false;
  @State userOk: boolean = false;
  @State userLat: number = 0;
  @State userLng: number = 0;
  @State ownActive: boolean = false;
  @State ownBegin: number = 0;
  @State ownPeriod: number = 0;
  @State ownUpdated: number = 0;
  @State participants: ParticipantRow[] = [];
  @State now: number = 0;
  @State showDurations: boolean = false;
  @State mapTypeIndex: number = 0;
  @State mapFailed: boolean = false;
  // 可折叠地图区：列表顶边的 y（vp）
  @State headerH: number = 0;
  @State screenW: number = 360;
  @State screenH: number = 740;
  private maxHeaderH: number = 0;
  private minHeaderH: number = 120;
  private initialized: boolean = false;
  private scroller: Scroller = new Scroller();
  private controller: map.MapComponentController | undefined = undefined;
  private markers: Map<number, map.Marker> = new Map<number, map.Marker>();
  private subjectMarker: map.Marker | undefined = undefined;
  private pendingPin: PinInfo = { avatar: '', name: '', isSelf: false, pixel: null };
  // 头像 PixelMap 缓存：MapKit setIconBuilder 是同步截图，Image(文件路径) 异步解码来不及
  // → 1002601005（真机实锤）；先解码成 PixelMap 再进 builder。
  private avatarPixels: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private mapOptions: mapCommon.MapOptions = {
    position: { target: { latitude: 0, longitude: 0 }, zoom: 15.5 },
    zoomControlsEnabled: false,
    myLocationControlsEnabled: false,
    compassControlsEnabled: false
  };
  private mapCallback: AsyncCallback<map.MapComponentController> =
    (err: BusinessError, ctrl: map.MapComponentController): void => {
      if (err) {
        console.error(`[LocationView] MapComponent init failed: ${err.code} ${err.message}`);
        this.mapFailed = true;
        return;
      }
      this.controller = ctrl;
      try {
        ctrl.setMyLocationEnabled(true);
      } catch (e) {
        console.error(`[LocationView] myLocation failed: ${JSON.stringify(e)}`);
      }
      // 状态可能晚于地图初始化到达：只有已拿到主体坐标时才定位相机/同步标注，
      // 否则等 applyState 首次到达时再做（真机实锤：先到的回调把相机停在 (0,0) 海面）。
      if (this.initialized) {
        this.centerOnSubject();
        this.syncMarkers();
      }
    };

  private centerOnSubject(): void {
    if (this.controller === undefined) {
      return;
    }
    try {
      // iOS viewMapSpan 0.008° ≈ zoom 15.3
      this.controller.moveCamera(map.newLatLng({ latitude: this.subjectLat, longitude: this.subjectLng }, 15.5));
    } catch (e) {
      console.error(`[LocationView] center failed: ${JSON.stringify(e)}`);
    }
  }

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
      const s: LocationViewState = JSON.parse(this.stateJson) as LocationViewState;
      const firstLoad: boolean = !this.initialized;
      this.subjectLat = toNum(s.subject.lat);
      this.subjectLng = toNum(s.subject.lng);
      this.subjectIsLive = s.subject.isLive;
      this.subjectTitle = s.subject.title ?? '';
      this.subjectVenueTitle = s.subject.venueTitle ?? '';
      this.subjectVenueAddress = s.subject.venueAddress ?? '';
      this.subjectMsgId = s.subject.msgId;
      this.subjectIsSent = s.subject.isSent;
      this.userOk = s.user.ok;
      this.userLat = toNum(s.user.lat);
      this.userLng = toNum(s.user.lng);
      this.ownActive = s.own.active;
      this.ownBegin = s.own.begin ?? 0;
      this.ownPeriod = s.own.period ?? 0;
      this.now = s.now;
      console.info(`[LocationView] state own=${s.own.active}/${s.own.msgId} parts=${(s.participants ?? []).length} subjLive=${s.subject.isLive}`);
      const rows: ParticipantRow[] = [];
      const list: LocationViewParticipant[] = s.participants ?? [];
      // iOS：被点开的那条固定排第一，其余按服务返回顺序
      list.sort((a: LocationViewParticipant, b: LocationViewParticipant): number => {
        if (a.msgId === this.subjectMsgId) { return -1; }
        if (b.msgId === this.subjectMsgId) { return 1; }
        return 0;
      });
      for (const p of list) {
        rows.push({
          msgId: p.msgId, peerId: p.peerId, isSelf: p.isSelf, name: p.name, avatar: p.avatar,
          lat: toNum(p.lat), lng: toNum(p.lng), heading: p.heading, updated: p.updated,
          begin: p.begin, period: p.period
        });
      }
      this.participants = rows;
      for (const r of rows) {
        if (r.isSelf) { this.ownUpdated = r.updated; }
      }
      if (firstLoad) {
        this.initialized = true;
        this.mapOptions = {
          position: { target: { latitude: this.subjectLat, longitude: this.subjectLng }, zoom: 15.5 },
          zoomControlsEnabled: false,
          myLocationControlsEnabled: false,
          compassControlsEnabled: false
        };
        this.resetHeader();
        this.centerOnSubject();
      }
      this.syncMarkers();
    } catch (e) {
      console.error(`[LocationView] bad state: ${JSON.stringify(e)}`);
    }
  }

  private resetHeader(): void {
    // iOS topInset = 屏高 − 底安全区 − 100（live +66）
    let top: number = this.screenH - SAFE_BOTTOM - 100;
    // 有实时行（自己的 Sharing+Stop 或对方的参与者行）时多露 66，让第二行可见
    if (this.ownActive || this.visibleParticipants().length > 0) {
      top -= 66;
    }
    // 参与者多时多露一些（iOS 首屏滚到第 2 项）
    this.maxHeaderH = top;
    if (this.headerH === 0 || this.headerH > top) {
      this.headerH = top;
    }
  }

  private subjectForList(): ParticipantRow | null {
    for (const p of this.participants) {
      if (p.msgId === this.subjectMsgId) { return p; }
    }
    return null;
  }

  // ---------- 标注 ----------

  @Builder
  avatarPinBuilder() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width(50).height(50).borderRadius(25)
        .backgroundColor(this.pendingPin.isSelf ? '#0088FF' : '#FFFFFF')
        .shadow({ radius: 6, color: '#40000000', offsetY: 2 });
      if (this.pendingPin.pixel !== null) {
        Image(this.pendingPin.pixel).width(44).height(44).borderRadius(22).objectFit(ImageFit.Cover).margin({ top: 3 });
      } else {
        Text(this.pendingPin.name.length > 0 ? this.pendingPin.name.substring(0, 1) : '?')
          .width(44).height(44).borderRadius(22).backgroundColor('#5C6BC0')
          .fontColor('#FFFFFF').fontSize(18).textAlign(TextAlign.Center).margin({ top: 3 });
      }
      Column().width(12).height(12).backgroundColor(this.pendingPin.isSelf ? '#0088FF' : '#FFFFFF')
        .rotate({ angle: 45 }).margin({ top: 43 });
    }
    .width(50).height(56);
  }

  @Builder
  subjectPinBuilder() {
    // iOS LocationPinAnnotation：accent 大头针 + 图标圆
    Stack({ alignContent: Alignment.Top }) {
      Column().width(46).height(46).borderRadius(23).backgroundColor('#007AFF')
        .shadow({ radius: 6, color: '#40000000', offsetY: 2 });
      Column() {
        Image($r('app.media.loc_ic_maprow')).width(20).height(20).fillColor('#007AFF');
      }
      .width(34).height(34).borderRadius(17).backgroundColor('#FFFFFF')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).margin({ top: 6 });
      Column().width(12).height(12).backgroundColor('#007AFF').rotate({ angle: 45 }).margin({ top: 39 });
    }
    .width(46).height(52);
  }

  /** iOS LocationPinAnnotation（头像针）：圆底 + 头像 + 小尾巴，50×56vp，锚点在尾尖。 */
  private drawAvatarPin(info: PinInfo): image.PixelMap | null {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      const W: number = 50;
      const H: number = 56;
      const off: OffscreenCanvas = new OffscreenCanvas(W * d, H * d, LengthMetricsUnit.PX);
      const ctx: OffscreenCanvasRenderingContext2D = off.getContext('2d');
      ctx.scale(d, d);
      ctx.shadowBlur = 6;
      ctx.shadowColor = '#40000000';
      ctx.shadowOffsetY = 2;
      ctx.fillStyle = info.isSelf ? '#0088FF' : '#FFFFFF';
      ctx.beginPath();
      ctx.moveTo(19, 43);
      ctx.lineTo(31, 43);
      ctx.lineTo(25, 52);
      ctx.closePath();
      ctx.fill();
      ctx.beginPath();
      ctx.arc(25, 24, 22, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.shadowColor = '#00000000';
      ctx.shadowOffsetY = 0;
      ctx.save();
      ctx.beginPath();
      ctx.arc(25, 24, 19, 0, Math.PI * 2);
      ctx.clip();
      if (info.pixel !== null) {
        ctx.drawImage(info.pixel, 6, 5, 38, 38);
      } else {
        ctx.fillStyle = '#5C6BC0';
        ctx.fillRect(6, 5, 38, 38);
        ctx.fillStyle = '#FFFFFF';
        ctx.font = 'bold 16px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(info.name.length > 0 ? info.name.substring(0, 1).toUpperCase() : '?', 25, 24);
      }
      ctx.restore();
      return ctx.getPixelMap(0, 0, W * d, H * d);
    } catch (e) {
      console.error(`[LocationView] drawAvatarPin failed: ${JSON.stringify(e)}`);
      return null;
    }
  }

  private async loadAvatarPixel(path: string): Promise<image.PixelMap | null> {
    if (path.length === 0) {
      return null;
    }
    const cached: image.PixelMap | undefined = this.avatarPixels.get(path);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const src: image.ImageSource = image.createImageSource(path);
      const px: image.PixelMap = await src.createPixelMap({ desiredSize: { width: 132, height: 132 } });
      src.release();
      this.avatarPixels.set(path, px);
      return px;
    } catch (e) {
      console.error(`[LocationView] avatar decode failed ${path}: ${JSON.stringify(e)}`);
      return null;
    }
  }

  private syncMarkers(): void {
    const ctrl: map.MapComponentController | undefined = this.controller;
    if (ctrl === undefined) {
      return;
    }
    // 静态主体针（live 主体由参与者头像针表示）
    if (!this.subjectIsLive && this.subjectMarker !== undefined) {
      this.subjectMarker.setPosition({ latitude: this.subjectLat, longitude: this.subjectLng });
    }
    if (!this.subjectIsLive && this.subjectMarker === undefined) {
      const opts: mapCommon.MarkerOptions = {
        position: { latitude: this.subjectLat, longitude: this.subjectLng },
        anchorU: 0.5, anchorV: 1.0
      };
      ctrl.addMarker(opts).then((m: map.Marker): void => {
        this.subjectMarker = m;
        m.setIconBuilder(this.subjectPinBuilder.bind(this)).catch((e: BusinessError): void => {
          console.error(`[LocationView] subject icon failed: ${e.code}`);
        });
      }).catch((e: BusinessError): void => {
        console.error(`[LocationView] subject marker failed: ${e.code}`);
      });
    }
    const seen: Set<number> = new Set<number>();
    for (const p of this.participants) {
      seen.add(p.msgId);
      // 自己也用头像 pin（iOS userLocationAnnotation 是蓝点上叠头像；这里以蓝环头像针呈现）
      const existing: map.Marker | undefined = this.markers.get(p.msgId);
      if (existing !== undefined) {
        existing.setPosition({ latitude: p.lat, longitude: p.lng });
        continue;
      }
      const opts: mapCommon.MarkerOptions = {
        position: { latitude: p.lat, longitude: p.lng },
        anchorU: 0.5, anchorV: 1.0
      };
      const info: PinInfo = { avatar: p.avatar, name: p.name, isSelf: p.isSelf, pixel: null };
      this.loadAvatarPixel(p.avatar).then((px: image.PixelMap | null): Promise<void> => {
        info.pixel = px;
        return ctrl.addMarker(opts).then((m: map.Marker): void => {
          this.markers.set(p.msgId, m);
          // setIconBuilder 在真机上对含 Image/Text 的 builder 稳定报 1002601005
          // （Failed to generate the icon），改为自绘 PixelMap 走 setIcon。
          const icon: image.PixelMap | null = this.drawAvatarPin(info);
          if (icon !== null) {
            m.setIcon(icon).catch((e: BusinessError): void => {
              console.error(`[LocationView] avatar icon failed: ${e.code} ${e.message}`);
            });
          }
        });
      }).catch((e: BusinessError): void => {
        console.error(`[LocationView] marker failed: ${e.code}`);
      });
    }
    // 过期/停止的参与者移除
    const gone: number[] = [];
    this.markers.forEach((m: map.Marker, id: number): void => {
      if (!seen.has(id)) {
        gone.push(id);
        try { m.remove(); } catch (_e) {}
      }
    });
    for (const id of gone) {
      this.markers.delete(id);
    }
  }

  private goTo(lat: number, lng: number): void {
    if (this.controller === undefined) {
      return;
    }
    try {
      this.controller.animateCamera(map.newLatLng({ latitude: lat, longitude: lng }, 15.5), 300);
    } catch (e) {
      console.error(`[LocationView] goTo failed: ${JSON.stringify(e)}`);
    }
  }

  /** iOS showAll：用户位置 + 全部标注的并集，padding (88,80,160,80) */
  private showAll(): void {
    if (this.controller === undefined) {
      return;
    }
    let minLat: number = this.subjectLat;
    let maxLat: number = this.subjectLat;
    let minLng: number = this.subjectLng;
    let maxLng: number = this.subjectLng;
    const consider = (lat: number, lng: number): void => {
      minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat);
      minLng = Math.min(minLng, lng); maxLng = Math.max(maxLng, lng);
    };
    for (const p of this.participants) { consider(p.lat, p.lng); }
    if (this.userOk) { consider(this.userLat, this.userLng); }
    const pad: number = 0.0006;
    const bounds: mapCommon.LatLngBounds = {
      northeast: { latitude: maxLat + pad, longitude: maxLng + pad },
      southwest: { latitude: minLat - pad, longitude: minLng - pad }
    };
    try {
      this.controller.animateCamera(map.newLatLngBounds(bounds, 100), 300);
    } catch (e) {
      console.error(`[LocationView] showAll failed: ${JSON.stringify(e)}`);
    }
  }

  private cycleMapType(): void {
    if (this.controller === undefined) {
      return;
    }
    this.mapTypeIndex = (this.mapTypeIndex + 1) % 3;
    const t: mapCommon.MapType = this.mapTypeIndex === 0 ? mapCommon.MapType.STANDARD :
      (this.mapTypeIndex === 1 ? mapCommon.MapType.SATELLITE : mapCommon.MapType.HYBRID);
    try { this.controller.setMapType(t); } catch (_e) {}
  }

  private locateMe(): void {
    if (this.userOk) {
      this.goTo(this.userLat, this.userLng);
    }
  }

  // ---------- 列表数据 ----------

  private infoTitle(): string {
    return this.subjectVenueTitle.length > 0 ? this.subjectVenueTitle : 'Location';
  }

  private infoSubtitle(): string {
    const parts: string[] = [];
    if (this.subjectVenueAddress.length > 0) {
      parts.push(this.subjectVenueAddress);
    }
    if (this.userOk) {
      const d: number = haversineMeters(this.userLat, this.userLng, this.subjectLat, this.subjectLng);
      parts.push(d < 10 ? 'You are here' : `${distanceString(d)} away`);
    }
    return parts.join(' • ');
  }

  private participantSubtitle(p: ParticipantRow): string {
    const t: string = updatedString(p.updated, this.now);
    if (this.userOk) {
      const d: number = haversineMeters(this.userLat, this.userLng, p.lat, p.lng);
      return `${t} • ${distanceString(d)} away`;
    }
    return t;
  }

  private visibleParticipants(): ParticipantRow[] {
    // iOS：自己的那条不进列表（成为用户蓝点）
    return this.participants.filter((p: ParticipantRow): boolean => !p.isSelf);
  }

  private showLiveRows(): boolean {
    return this.subjectIsLive || this.ownActive || this.visibleParticipants().length > 0;
  }

  // ---------- builders ----------

  @Builder
  glassButton(icon: Resource | null, label: string, onTap: () => void) {
    Row() {
      if (icon !== null) {
        Image(icon).width(18).height(18).fillColor('#000000');
      }
      if (label.length > 0) {
        Text(label).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#000000');
      }
    }
    .height(44)
    .padding({ left: label.length > 0 ? 16 : 13, right: label.length > 0 ? 16 : 13 })
    .borderRadius(22)
    .backgroundColor('#E6FFFFFF')
    .shadow({ radius: 8, color: '#26000000', offsetY: 2 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { onTap(); });
  }

  @Builder
  mapControl(icon: Resource, onTap: () => void) {
    Column() {
      Image(icon).width(22).height(22).fillColor('#007AFF');
    }
    .width(40).height(40).borderRadius(20)
    .backgroundColor('#F2FFFFFF')
    .shadow({ radius: 6, color: '#26000000', offsetY: 1 })
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .onClick((): void => { onTap(); });
  }

  @Builder
  actionIcon(kind: string) {
    // iOS LocationActionListItem 40 圆：start/extend 绿 0x6cc138，stop 红 0xff6464 + 斜杠
    Stack() {
      Column().width(40).height(40).borderRadius(20)
        .backgroundColor(kind === 'stop' ? '#FF6464' : '#6CC138');
      Image($r('app.media.loc_ic_sendlocation')).width(20).height(20).fillColor('#FFFFFF');
      if (kind === 'stop') {
        Column().width(26).height(2).backgroundColor('#FFFFFF').rotate({ angle: -45 });
      }
    }
    .width(40).height(40);
  }

  @Builder
  remainingRing(begin: number, period: number, size: number) {
    Stack() {
      Progress({ value: Math.round(remainingProgress(begin, period, this.now) * 100), total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color('#007AFF')
        .backgroundColor('#66007AFF')
        .style({ strokeWidth: 1.5 });
      Text(remainingLabel(begin, period, this.now))
        .fontSize(remainingLabel(begin, period, this.now).length > 2 ? 10 : 12)
        .fontWeight(FontWeight.Bold)
        .fontColor('#007AFF');
    }
    .width(size).height(size);
  }

  @Builder
  toggleRow(kind: string, title: string, subtitle: string, onTap: () => void) {
    Row() {
      this.actionIcon(kind);
      Column() {
        Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#000000').maxLines(1);
        Text(subtitle).fontSize(15).fontColor('#8E8E93').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 16 });
    }
    .width('100%')
    .height(64)
    .padding({ left: 22, right: 22 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { onTap(); });
  }

  @Builder
  durationRow(title: string, seconds: number) {
    Row() {
      Image($r('app.media.loc_ic_clock')).width(16).height(16).fillColor('#0088CC').margin({ right: 12 });
      Text(title).fontSize(16).fontColor('#0088CC');
    }
    .width('100%')
    .height(48)
    .padding({ left: 78, right: 22 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.showDurations = false;
      sendLocationViewAction('startLive', seconds, '', '', '');
    });
  }

  @Builder
  participantRow(p: ParticipantRow) {
    Row() {
      if (p.avatar.length > 0) {
        Image(p.avatar).width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover);
      } else {
        Text(p.name.length > 0 ? p.name.substring(0, 1) : '?')
          .width(40).height(40).borderRadius(20).backgroundColor('#5C6BC0')
          .fontColor('#FFFFFF').fontSize(17).textAlign(TextAlign.Center);
      }
      Column() {
        Text(p.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#000000').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.participantSubtitle(p)).fontSize(15).fontColor('#8E8E93').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 16 });
      if (p.begin + p.period > this.now || p.period === LIVE_INDEFINITE) {
        this.remainingRing(p.begin, p.period, 24);
      }
    }
    .width('100%')
    .height(64)
    .padding({ left: 22, right: 26 })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { this.goTo(p.lat, p.lng); });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 地图
      if (!this.mapFailed) {
        MapComponent({ mapOptions: this.mapOptions, mapCallback: this.mapCallback })
          .width('100%')
          .height('100%');
      } else {
        Column() {
          Text('地图初始化失败').fontSize(14).fontColor('#8E8E93');
        }
        .width('100%').height('100%').backgroundColor('#E8E8E8')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
      }

      // 顶部玻璃控件：关闭 / 标题 / Share|Show All
      Row() {
        this.glassButton($r('app.media.nav_ic_close'), '', (): void => {
          sendLocationViewAction('close', 0, '', '', '');
        });
        Blank();
        Text('Location').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#000000');
        Blank();
        if (this.showLiveRows()) {
          this.glassButton(null, 'Show All', (): void => { this.showAll(); });
        } else {
          this.glassButton(null, 'Share', (): void => {
            sendLocationViewAction('share', 0, `${this.subjectLat}`, `${this.subjectLng}`, this.infoTitle());
          });
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: SAFE_TOP + 8 })
      .alignItems(VerticalAlign.Center);

      // 地图右下控制组（贴在列表顶边上方）
      Column({ space: 8 }) {
        this.mapControl($r('app.media.loc_ic_maprow'), (): void => { this.cycleMapType(); });
        this.mapControl($r('app.media.loc_ic_sendlocation'), (): void => { this.locateMe(); });
      }
      .position({ x: this.screenW - 40 - 16, y: Math.max(SAFE_TOP + 70, this.headerH - 96 - 12) })
      .opacity(this.headerH < 180 ? 0 : 1);

      // 可折叠列表面板
      Scroll(this.scroller) {
        Column() {
          Column().width(36).height(5).borderRadius(2.5).backgroundColor('#33000000').margin({ top: 8, bottom: 8 });
          if (!this.subjectIsLive) {
            // info 行（iOS LocationInfoListItem）
            Column() {
              Row() {
                this.actionIcon('location');
                Column() {
                  Text(this.infoTitle()).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#000000').maxLines(1);
                  Text(this.infoSubtitle()).fontSize(15).fontColor('#8E8E93').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 16 });
              }
              .width('100%')
              .padding({ left: 22, right: 22, top: 6 })
              .alignItems(VerticalAlign.Center)
              .onClick((): void => { this.goTo(this.subjectLat, this.subjectLng); });
              Button('Get Directions')
                .width('100%')
                .height(52)
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .backgroundColor('#007AFF')
                .borderRadius(26)
                .margin({ left: 30, right: 30, top: 14, bottom: 8 })
                .onClick((): void => {
                  sendLocationViewAction('openIn', 0, `${this.subjectLat}`, `${this.subjectLng}`, this.infoTitle());
                });
            }
            .width('100%');
          }
          if (this.showLiveRows()) {
            if (this.ownActive) {
              // iOS：Sharing Location（剩余时间环）+ Stop Sharing Live Location
              Row() {
                this.actionIcon('start');
                Column() {
                  Text('Sharing Location').fontSize(17).fontWeight(FontWeight.Medium).fontColor('#000000').maxLines(1);
                  Text(updatedString(this.ownUpdated > 0 ? this.ownUpdated : this.ownBegin, this.now))
                    .fontSize(15).fontColor('#8E8E93').maxLines(1);
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 16 });
                if (this.ownPeriod > 0) {
                  this.remainingRing(this.ownBegin, this.ownPeriod, 24);
                }
              }
              .width('100%')
              .height(64)
              .padding({ left: 22, right: 26 })
              .alignItems(VerticalAlign.Center);
              this.toggleRow('stop', 'Stop Sharing Live Location', 'Tap to stop sharing your location', (): void => {
                sendLocationViewAction('stop', 0, '', '', '');
              });
            } else {
              this.toggleRow('start', 'Share My Live Location for...', 'Updated in real time as you move', (): void => {
                this.showDurations = !this.showDurations;
              });
              if (this.showDurations) {
                this.durationRow('15 minutes', 900);
                this.durationRow('1 hour', 3600);
                this.durationRow('8 hours', 28800);
                this.durationRow('Until I turn it off', LIVE_INDEFINITE);
              }
            }
            ForEach(this.visibleParticipants(), (p: ParticipantRow): void => {
              this.participantRow(p);
            }, (p: ParticipantRow): string => `${p.msgId}_${p.updated}`);
          }
          Blank().height(SAFE_BOTTOM + 24);
        }
        .width('100%')
        .backgroundColor('#FFFFFF')
        .borderRadius({ topLeft: 24, topRight: 24 })
        .constraintSize({ minHeight: this.screenH - this.minHeaderH });
      }
      .width('100%')
      .height(this.screenH - this.headerH)
      .position({ x: 0, y: this.headerH })
      .scrollBar(BarState.Off)
      .backgroundColor(Color.Transparent)
      .edgeEffect(EdgeEffect.None)
      .onScrollFrameBegin((offset: number, _state: ScrollState): OnScrollFrameBeginHandlerResult => {
        // iOS updateFloatingHeaderOffset：先收/放地图区，再滚列表
        if (offset > 0 && this.headerH > this.minHeaderH) {
          const take: number = Math.min(offset, this.headerH - this.minHeaderH);
          this.headerH -= take;
          return { offsetRemain: offset - take };
        }
        if (offset < 0 && this.scroller.currentOffset().yOffset <= 0 && this.headerH < this.maxHeaderH) {
          const give: number = Math.min(-offset, this.maxHeaderH - this.headerH);
          this.headerH += give;
          return { offsetRemain: offset + give };
        }
        return { offsetRemain: offset };
      });
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_o: Area, n: Area): void => {
      this.screenW = n.width as number;
      this.screenH = n.height as number;
      this.resetHeader();
    });
  }
}
