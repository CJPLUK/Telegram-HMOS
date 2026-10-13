// Phase1：ArkTS 表情网格（ImageAnimator 帧动画，系统驱动零逐帧应用开销）。
//
// 数据：getEmojiGridRows()（仓颉行表 JSON，含每格的 .acv3/静帧路径）。
// 帧：libentry.so 的 emojiLoadCachedFrames/.emojiLoadRawFrame（BGRA buffer →
//     image.createPixelMap）。
// 事件：emojiGridEvent("cell|doc|emoji" / "button|group" / "expand|group" /
//       "top|group")。
import {
  getEmojiGridRows, emojiGridEvent, getStickerGridRows, stickerGridEvent
} from 'libohos_app_cangjie_entry.so';
import {
  emojiLoadCachedFrames, emojiLoadRawFrame, EmojiCachedFrames,
  emojiAnimOpen, emojiAnimNextBatch, emojiAnimClose, EmojiAnimHandle
} from 'libemoji_frames.so';
import { image } from '@kit.ImageKit';
import { FrameNode, NodeController, RenderNode, DrawContext } from '@kit.ArkUI';
import { displaySync, drawing } from '@kit.ArkGraphics2D';
import { hilog } from '@kit.PerformanceAnalysisKit';

// ============================================================================
// RenderNode 贴纸动画管线（生产实现；前期 spike 实测背书：
// 30 格@30fps 主线程 avg 4.1ms / max 11.9ms）。
// 结构：List 照旧承担布局/滚动/点击/头行；动画帧由本层（挂在 List 之下的
// 单个 RenderNode）每拍绘制。帧来源是 native 增量解帧会话
// （emojiAnimOpen/Next：句柄只持文件偏移索引 + 2×帧缓冲 ≈150KB/会话），
// 每 doc 仅一块池化 PixelMap 驻留 —— iOS AnimationCache「压缩存储 +
// 每拍解一帧」内存模型的对位，替代 ImageAnimator 的全帧驻留（90 帧
// ×74KB/doc）。
// ============================================================================
const RENDERNODE_STICKER = true;

/** 网格里一个待动画格子的布局槽（内容坐标系，vp）。 */
interface AnimSlot {
  doc: string;
  cache: string;
  stat: string;
  xVp: number;
  yVp: number;
  sizeVp: number;
}

/** 单个 doc 的解帧会话 + 池化位图。 */
/** 全链路诊断日志开关（[ChainTrace]）：默认关；排查加载时延时打开。 */
const CHAIN_TRACE = false;

class AnimSession {
  handle: number = 0;
  raster: number = 0;
  durationMs: number = 33;
  accMs: number = 0;
  pm: PixelMap | null = null;
  buf: ArrayBuffer = new ArrayBuffer(0);
  hasFrame: boolean = false;
  lastUsedTick: number = 0;
  /** 渐进升格：快段（≤24 帧）会话定期重开探测全量文件是否已替换。 */
  frameCount: number = 0;
  lastUpgradeTick: number = 0;
  upgradeTries: number = 0;
}

class StickerAnimNode extends RenderNode {
  slots: AnimSlot[] = [];
  /** 线性过滤采样：默认最近邻放大 136px 会出颗粒，与 Image 组件观感不一致。 */
  private sampling = new drawing.SamplingOptions(drawing.FilterMode.FILTER_MODE_LINEAR);
  sessions = new Map<string, AnimSession>();
  /** 会话打不开（.acv3 未建成）的 doc：静帧兜底 + 已发 need 标记。 */
  private staticFallback = new Map<string, PixelMap>();
  private needSent = new Set<string>();
  private openFailed = new Set<string>();
  private traceOpenOk = new Set<string>();
  private traceOpenMiss = new Set<string>();
  private traceStaticMiss = new Set<string>();
  pxScale: number = 3.25;
  viewportHVp: number = 600;
  /** true=贴纸面板(136px/stickerGrid 通道), false=emoji 面板(84px/emojiGrid 通道) */
  stickerMode: boolean = true;
  getScrollY: () => number = () => 0;
  private tickCount: number = 0;
  private static readonly SESSION_CAP = 64;  // 须大于满屏可见格数（5 列 ×~9 行 ≈45），否则超额格子永久静止

  draw(ctx: DrawContext) {
    const canvas = ctx.canvas;
    const scrollY = this.getScrollY();
    for (const slot of this.slots) {
      const topVp = slot.yVp - scrollY;
      if (topVp + slot.sizeVp < 0 || topVp > this.viewportHVp) {
        continue;
      }
      const s = this.sessions.get(slot.doc);
      let pmDraw: PixelMap | null = null;
      if (s != null && s.hasFrame && s.pm != null) {
        pmDraw = s.pm;
      } else {
        pmDraw = this.staticFallback.get(slot.doc) ?? null;
      }
      if (pmDraw == null) {
        continue;
      }
      const l = slot.xVp * this.pxScale;
      const t = topVp * this.pxScale;
      const r = l + slot.sizeVp * this.pxScale;
      const b = t + slot.sizeVp * this.pxScale;
      canvas.drawImageRect(pmDraw, { left: l, top: t, right: r, bottom: b }, this.sampling);
    }
  }

  /** 每拍：可见槽开/推进会话，离屏会话按 LRU 收割，然后重绘。 */
  /** 批解码在飞标志：飞行期本拍跳过（契约：飞行期不 open/close/evict，
   *  杜绝原生侧 use-after-free；批通常 <8ms，30fps 下不产生实际跳拍）。 */
  private batchInFlight: boolean = false;

  step(frameMs: number): void {
    this.tickCount++;
    if (this.tickCount % 900 === 0) {
      this.needSent.clear(); // ~30s 重置：首次补建失败（如下载瞬断）后允许重发 need
    }
    if (this.batchInFlight) {
      return;
    }
    const scrollY = this.getScrollY();
    if (CHAIN_TRACE && this.tickCount % 90 === 0) {
      let vis = 0;
      for (const sl of this.slots) {
        const tv = sl.yVp - scrollY;
        if (tv + sl.sizeVp >= 0 && tv <= this.viewportHVp) { vis++; }
      }
      console.info(`[RNDbg] mode=${this.stickerMode} tick=${this.tickCount} scrollY=${scrollY.toFixed(1)} viewport=${this.viewportHVp.toFixed(1)} slots=${this.slots.length} visible=${vis} sessions=${this.sessions.size} static=${this.staticFallback.size} failed=${this.openFailed.size}`);
    }
    let opens = 0;
    const dueS: AnimSession[] = [];
    const dueH: number[] = [];
    const dueB: ArrayBuffer[] = [];
    for (const slot of this.slots) {
      const topVp = slot.yVp - scrollY;
      if (topVp + slot.sizeVp < 0 || topVp > this.viewportHVp) {
        continue;
      }
      let s: AnimSession | undefined = this.sessions.get(slot.doc);
      if (s == undefined) {
        if (this.openFailed.has(slot.doc) && this.tickCount % 15 !== 0) {
          this.ensureStaticFallback(slot);
          continue;
        }
        // 满员先按 LRU 收割一个离屏会话腾位；全部在屏（收不动）则静帧兜底，
        // 且不得标 openFailed / 发 need（那是"文件坏"通道，满员混进去会永久静止）。
        if (this.sessions.size >= StickerAnimNode.SESSION_CAP && !this.evictLruOffscreen()) {
          this.ensureStaticFallback(slot);
          continue;
        }
        // open 含整文件偏移扫描（~ms 级 I/O）：跳包瞬间几十格挤一拍会顶爆
        // 帧预算，每拍限 3 个，其余下一拍继续（静帧先顶上）。
        if (opens >= 3) {
          this.ensureStaticFallback(slot);
          continue;
        }
        opens++;
        const openedS = this.openSession(slot);
        if (openedS == null) {
          if (CHAIN_TRACE && !this.traceOpenMiss.has(slot.doc)) {
            this.traceOpenMiss.add(slot.doc);
            console.info(`[ChainTrace] open-miss doc=${slot.doc} cache=...${slot.cache.slice(-26)} t=${Date.now()}`);
          }
          this.openFailed.add(slot.doc);
          this.ensureStaticFallback(slot);
          if (!this.needSent.has(slot.doc)) {
            this.needSent.add(slot.doc);
            if (CHAIN_TRACE) {
              console.info(`[ChainTrace] need-sent doc=${slot.doc} t=${Date.now()}`);
            }
            gridEmit(this.stickerMode, `need|${slot.doc}`);
          }
          continue;
        }
        this.openFailed.delete(slot.doc);
        s = openedS;
        if (CHAIN_TRACE && !this.traceOpenOk.has(slot.doc)) {
          this.traceOpenOk.add(slot.doc);
          console.info(`[ChainTrace] open-ok doc=${slot.doc} frames=${s.frameCount} raster=${s.raster} t=${Date.now()}`);
        }
      }
      s.lastUsedTick = this.tickCount;
      // 渐进升格（iOS AnimationCache 对位）：快段会话每 ~5s 重开一次，
      // 全量 .acv3 原子替换落盘后帧数变多即无缝切换；连续 4 次没变
      // 视为本就是短动画，停止探测。
      if (s.frameCount > 1 && s.frameCount <= 24 && s.upgradeTries < 4
        && this.tickCount - s.lastUpgradeTick >= 150) {
        s.lastUpgradeTick = this.tickCount;
        const re: EmojiAnimHandle | null = emojiAnimOpen(slot.cache);
        if (re != null && re.frameCount > s.frameCount && re.raster === s.raster) {
          emojiAnimClose(s.handle);
          s.handle = re.handle;
          s.frameCount = re.frameCount;
          s.durationMs = Math.max(16, re.frameDurationMs);
        } else {
          if (re != null) {
            emojiAnimClose(re.handle);
          }
          s.upgradeTries++;
        }
      }
      s.accMs += frameMs;
      if (s.accMs >= s.durationMs) {
        s.accMs = s.accMs % s.durationMs;
        if (s.pm != null) {
          dueS.push(s);
          dueH.push(s.handle);
          dueB.push(s.buf);
        }
      }
    }
    this.evictStale();
    if (dueH.length > 0) {
      // 解帧批量下移原生线程（主线程曾 45% 单核，Next 解码是主项）；
      // 回来只做 writeBufferToPixelsSync（74KB memcpy 级）+ 重绘。
      this.batchInFlight = true;
      emojiAnimNextBatch(dueH, dueB).then((res: number[]) => {
        let advanced = false;
        for (let i = 0; i < dueS.length && i < res.length; i++) {
          const ds = dueS[i];
          if (res[i] >= 0 && ds.pm != null) {
            ds.pm.writeBufferToPixelsSync(ds.buf);
            ds.hasFrame = true;
            advanced = true;
          }
        }
        this.batchInFlight = false;
        if (advanced) {
          this.invalidate();
        }
      }).catch(() => {
        this.batchInFlight = false;
      });
    }
  }

  private openSession(slot: AnimSlot): AnimSession | null {
    if (this.sessions.size >= StickerAnimNode.SESSION_CAP) {
      return null; // 本拍已满：evictStale 腾位后下一拍再开
    }
    const opened: EmojiAnimHandle | null = emojiAnimOpen(slot.cache);
    if (opened == null) {
      return null;
    }
    const s = new AnimSession();
    s.handle = opened.handle;
    s.raster = opened.raster;
    s.frameCount = opened.frameCount;
    s.lastUpgradeTick = this.tickCount;
    s.durationMs = Math.max(16, opened.frameDurationMs);
    s.buf = new ArrayBuffer(opened.raster * opened.raster * 4);
    try {
      s.pm = image.createPixelMapSync(s.buf, {
        size: { width: opened.raster, height: opened.raster },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        alphaType: image.AlphaType.PREMUL
      });
    } catch (_e) {
      emojiAnimClose(opened.handle);
      return null;
    }
    this.sessions.set(slot.doc, s);
    return s;
  }

  /** 收割最久未触达的离屏会话（lastUsedTick < 本拍）。全在屏则返回 false。 */
  private evictLruOffscreen(): boolean {
    let lruDoc = '';
    let lruTick = this.tickCount;
    this.sessions.forEach((s, doc) => {
      if (s.lastUsedTick < this.tickCount && s.lastUsedTick < lruTick) {
        lruTick = s.lastUsedTick;
        lruDoc = doc;
      }
    });
    if (lruDoc === '') {
      return false;
    }
    this.closeSession(lruDoc);
    return true;
  }

  private evictStale(): void {
    if (this.sessions.size < StickerAnimNode.SESSION_CAP) {
      return;
    }
    // 60 拍（~2s）没被可见集触达的会话收割
    const stale: string[] = [];
    this.sessions.forEach((s, doc) => {
      if (this.tickCount - s.lastUsedTick > 60) {
        stale.push(doc);
      }
    });
    for (const doc of stale) {
      this.closeSession(doc);
    }
  }

  /** .acv3 未就绪的格子：读一次静帧代表图当兜底（避免空洞）。 */
  private ensureStaticFallback(slot: AnimSlot): void {
    if (slot.stat.length === 0 || this.staticFallback.has(slot.doc)) {
      return;
    }
    const raster = this.stickerMode ? 136 : 84;
    const raw = emojiLoadRawFrame(slot.stat, raster, false);
    if (raw == null) {
      if (CHAIN_TRACE && !this.traceStaticMiss.has(slot.doc)) {
        this.traceStaticMiss.add(slot.doc);
        console.info(`[ChainTrace] static-miss doc=${slot.doc} t=${Date.now()}`);
      }
      return;
    }
    try {
      const pm = image.createPixelMapSync(raw, {
        size: { width: raster, height: raster },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        alphaType: image.AlphaType.PREMUL
      });
      this.staticFallback.set(slot.doc, pm);
      if (this.staticFallback.size > 96) {
        const oldest = this.staticFallback.keys().next().value as string;
        this.staticFallback.get(oldest)?.release();
        this.staticFallback.delete(oldest);
      }
      this.invalidate();
    } catch (_e) {
      // 静帧也没有：保持空位，need 已发，建成后自动补上
    }
  }

  closeSession(doc: string): void {
    const s = this.sessions.get(doc);
    if (s != null) {
      emojiAnimClose(s.handle);
      s.pm?.release();
      s.pm = null; // 批解码完成回调以 pm==null 识别已销毁会话
      this.sessions.delete(doc);
    }
  }

  closeAll(): void {
    const docs: string[] = [];
    this.sessions.forEach((_s, doc) => docs.push(doc));
    for (const doc of docs) {
      this.closeSession(doc);
    }
    this.staticFallback.forEach((pm) => pm.release());
    this.staticFallback.clear();
    this.openFailed.clear();
  }
}

class StickerAnimController extends NodeController {
  animNode: StickerAnimNode = new StickerAnimNode();

  makeNode(uiContext: UIContext): FrameNode {
    const node = new FrameNode(uiContext);
    this.animNode.pxScale = uiContext.vp2px(1);
    this.animNode.frame = { x: 0, y: 0, width: 2000, height: 3000 };
    this.animNode.clipToFrame = true;
    const root = node.getRenderNode();
    if (root != null) {
      root.appendChild(this.animNode);
    }
    return node;
  }
}

interface GridCell {
  doc: string;
  tint: boolean;
  e: string;
  x: string;
  lock: boolean;
  /** 「新建贴纸」action 格(iOS recent 组头部 .icon(.add) 对位),仅贴纸面板。 */
  cr?: boolean;
  cache: string;
  static: string;
}

interface GridRow {
  kind: number;
  key: string;
  group: string;
  title: string;
  sub: string;
  badge: string;
  clear: string;
  locked: boolean;
  embedded: boolean;
  h: number;
  item: number;
  hsp: number;
  inset: number;
  act?: string; // 贴纸精选头行的动作按钮文案（"Add"）
  cells: GridCell[];
}

interface GridPayload {
  rows: GridRow[];
}

class RowDataSource implements IDataSource {
  private rows: GridRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): GridRow {
    return this.rows[index];
  }

  setRows(rows: GridRow[]): void {
    this.rows = rows;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}

// 全局帧缓存（跨挂载复用）。真 LRU + 像素字节预算：
// 旧版 CAP=24 且 get 不刷新热度（实为 FIFO），来回划动刚看过的包就被
// 顶掉，每次都从磁盘重解重建 PixelMap ——「上下划动反复加载」的主因。
class FrameCache {
  private static frames = new Map<string, PixelMap[]>();
  private static durations = new Map<string, number>();
  private static bytes = new Map<string, number>();
  private static order: string[] = [];
  private static total = 0;
  // 84×84×4 ≈ 28KB/帧，~45 帧/doc ≈ 1.3MB：96MB ≈ 前后 70+ 个包位
  private static readonly BUDGET = 96 * 1024 * 1024;

  private static touch(doc: string): void {
    const i = FrameCache.order.indexOf(doc);
    if (i >= 0) {
      FrameCache.order.splice(i, 1);
    }
    FrameCache.order.push(doc);
  }

  static get(doc: string): PixelMap[] | undefined {
    const f = FrameCache.frames.get(doc);
    if (f !== undefined) {
      FrameCache.touch(doc);
    }
    return f;
  }

  static duration(doc: string): number {
    return FrameCache.durations.get(doc) ?? 33;
  }

  static put(doc: string, f: PixelMap[], durationMs: number, raster: number): void {
    if (FrameCache.frames.has(doc)) {
      return;
    }
    const cost = f.length * raster * raster * 4;
    FrameCache.frames.set(doc, f);
    FrameCache.durations.set(doc, durationMs);
    FrameCache.bytes.set(doc, cost);
    FrameCache.order.push(doc);
    FrameCache.total += cost;
    while (FrameCache.total > FrameCache.BUDGET && FrameCache.order.length > 1) {
      const old = FrameCache.order.shift();
      if (old !== undefined) {
        FrameCache.total -= FrameCache.bytes.get(old) ?? 0;
        FrameCache.frames.delete(old);
        FrameCache.durations.delete(old);
        FrameCache.bytes.delete(old);
      }
    }
  }
}

// 静帧全局缓存：静帧同样跨挂载复用（28KB/张，160 张 ≈ 4.5MB），
// 否则每次划回来都要磁盘读 + createPixelMap 一遍。
class StaticCache {
  private static maps = new Map<string, PixelMap>();
  private static order: string[] = [];
  private static readonly CAP = 160;

  static get(key: string): PixelMap | undefined {
    const p = StaticCache.maps.get(key);
    if (p !== undefined) {
      const i = StaticCache.order.indexOf(key);
      if (i >= 0) {
        StaticCache.order.splice(i, 1);
      }
      StaticCache.order.push(key);
    }
    return p;
  }

  static put(key: string, p: PixelMap): void {
    if (StaticCache.maps.has(key)) {
      return;
    }
    StaticCache.maps.set(key, p);
    StaticCache.order.push(key);
    while (StaticCache.order.length > StaticCache.CAP) {
      const old = StaticCache.order.shift();
      if (old !== undefined) {
        StaticCache.maps.delete(old);
      }
    }
  }
}

// 装帧并发闸：滑入瞬间几十个格子同时 createPixelMap × 全帧会淹没 JS 线程
// （每帧一次异步创建，40 格 × 60 帧 = 2400 个在飞任务），限 4 路排队。
class LoadGate {
  private static running = 0;
  private static queue: Array<() => void> = [];

  static async acquire(): Promise<void> {
    if (LoadGate.running < 4) {
      LoadGate.running++;
      return;
    }
    await new Promise<void>((resolve) => {
      LoadGate.queue.push(resolve);
    });
    LoadGate.running++;
  }

  static release(): void {
    LoadGate.running--;
    // LIFO：最新入队的（= 当前屏上的格子）先服务。深滚会让几百个
    // 已滚走的死格子排在队头，FIFO 会把落点格子饿上几十秒（真机：
    // 深处成片"只有锁没有图"实锤）。死格子由 alive 短路放行。
    const next = LoadGate.queue.pop();
    if (next !== undefined) {
      next();
    }
  }
}

// 事件按通道分流（emoji / 贴纸共用本面板组件）
function gridEmit(sticker: boolean, payload: string): void {
  if (sticker) {
    stickerGridEvent(payload);
  } else {
    emojiGridEvent(payload);
  }
}

/**
 * R6V S2-37 诊断通道：ArkTS 侧的触摸/手势日志同时走两条路 —— hilog（CjTelegram 标签）与
 * 仓颉事件管道（"log|…"，由 StickerKeyboardPanel.handleStkGridEvent 用 Hilog 打出）。真机六轮里
 * 只有仓颉侧日志被稳定抓到；hilog 若抛异常也不能再吞掉后面的事件上报（W5 的处理函数都是先
 * hilog 再 gridEmit）。永不抛出。
 */
function stkDiag(sticker: boolean, msg: string): void {
  try {
    hilog.info(0x0000, 'CjTelegram', '[ArkStk] %{public}s', msg);
  } catch (_e) {
    // hilog 不可用时不影响事件链
  }
  if (!sticker) {
    return;
  }
  try {
    stickerGridEvent(`log|${msg}`);
  } catch (_e2) {
    // 桥未就绪时忽略
  }
}

async function bufferToPixelMap(buf: ArrayBuffer, raster: number): Promise<PixelMap> {
  return image.createPixelMap(buf, {
    size: { width: raster, height: raster },
    srcPixelFormat: image.PixelMapFormat.BGRA_8888,
    pixelFormat: image.PixelMapFormat.BGRA_8888,
    alphaType: image.AlphaType.PREMUL
  });
}

// 单个自定义表情格：帧就绪 → ImageAnimator；否则静帧/占位。
@Component
struct EmojiAnimCell {
  @Prop doc: string = '';
  @Prop cachePath: string = '';
  @Prop staticPath: string = '';
  @Prop tint: boolean = false;
  @Prop glyph: number = 32;
  @Prop sticker: boolean = false;
  // 贴纸帧数封顶：136px × 300+ 帧 = 20MB+/doc，整屏就是数百 MB。
  // 超限按等距抽帧、时长同步放大（观感 = 低帧率循环，iOS 网格同样降档）。
  @Prop maxFrames: number = 0;
  /** RenderNode 动画层接管：本格不装帧不渲染动画（层在底下画）。 */
  @Prop rnAnimated: boolean = false;
  @State frames: PixelMap[] = [];
  @State staticFrame: PixelMap | null = null;
  @State durationMs: number = 33;

  private alive: boolean = true;

  aboutToAppear(): void {
    this.alive = true;
    this.loadAsync();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private cacheKey(): string {
    return this.tint ? `${this.doc}#t` : this.doc;
  }

  /** 尝试从 .acv3 装帧。'ok' 帧已上屏 / 'miss' 文件缺失或坏 / 'dead' 格子已销毁 */
  private async tryLoadCache(): Promise<string> {
    const key = this.cacheKey();
    const cached = FrameCache.get(key);
    if (cached !== undefined) {
      this.durationMs = FrameCache.duration(key);
      this.frames = cached;
      return 'ok';
    }
    if (this.cachePath.length === 0) {
      return 'miss';
    }
    await LoadGate.acquire();
    try {
      if (!this.alive) {
        return 'dead';
      }
      const again = FrameCache.get(key);
      if (again !== undefined) {
        this.durationMs = FrameCache.duration(key);
        this.frames = again;
        return 'ok';
      }
      const data: EmojiCachedFrames | null = emojiLoadCachedFrames(this.cachePath, this.tint);
      if (data == null || data.frames.length <= 1) {
        return 'miss';
      }
      // 帧数封顶（贴纸）：等距抽帧 + 时长放大，帧内存 ∝ maxFrames。
      let stride = 1;
      if (this.maxFrames > 0 && data.frames.length > this.maxFrames) {
        stride = Math.ceil(data.frames.length / this.maxFrames);
      }
      // 并行建 PixelMap：逐帧串行 await 时 60 帧要吃 60 趟微任务往返，
      // 首屏付费包「转好几秒才动」的大头。native 解码池自己排队。
      const jobs: Promise<PixelMap>[] = [];
      for (let fi = 0; fi < data.frames.length; fi += stride) {
        jobs.push(bufferToPixelMap(data.frames[fi], data.raster));
      }
      const pms = await Promise.all(jobs);
      const effDuration = data.frameDurationMs * stride;
      FrameCache.put(key, pms, effDuration, data.raster);
      this.durationMs = effDuration;
      this.frames = pms;
      return 'ok';
    } finally {
      LoadGate.release();
    }
  }

  private async loadStaticInterim(): Promise<void> {
    if (this.staticPath.length === 0 || this.staticFrame != null) {
      return;
    }
    const key = this.tint ? `${this.staticPath}#t` : this.staticPath;
    const hit = StaticCache.get(key);
    if (hit !== undefined) {
      this.staticFrame = hit;
      return;
    }
    // 光栅跟通道走：emoji 静帧 84、贴纸 136 —— 用 84 去读 136 的 .bgra
    // 会解出噪声花屏（真机实锤）。
    const raster = this.sticker ? 136 : 84;
    const raw = emojiLoadRawFrame(this.staticPath, raster, this.tint);
    if (raw != null) {
      const pm = await bufferToPixelMap(raw, raster);
      StaticCache.put(key, pm);
      this.staticFrame = pm;
    }
  }

  private async loadAsync(): Promise<void> {
    if (this.rnAnimated) {
      return; // 动画帧归 RenderNode 层；格子零装帧
    }
    const t0 = Date.now();
    try {
      // 挂载稳定期：fling 路过的格子 150ms 内就销毁，不为它们启动装帧
      //（真机：深滚峰值 RSS 1.66GB 的主要来源）。缓存命中不受影响。
      const hot = FrameCache.get(this.cacheKey());
      if (hot !== undefined) {
        this.durationMs = FrameCache.duration(this.cacheKey());
        this.frames = hot;
        this.upgradeShortLoopAsync();
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 150));
      if (!this.alive) {
        return;
      }
      if (await this.tryLoadCache() !== 'miss') {
        if (CHAIN_TRACE && this.frames.length > 1) {
          console.info(`[ChainTrace] cell-ok doc=${this.doc} frames=${this.frames.length} ms=${Date.now() - t0}`);
        }
        this.upgradeShortLoopAsync();
        return;
      }
      if (CHAIN_TRACE) {
        console.info(`[ChainTrace] cell-miss doc=${this.doc} sticker=${this.sticker} t=${Date.now()}`);
      }
      // .acv3 缺失/损坏：静帧顶上，向仓颉要一次紧急补建，然后按路径
      // 退避重试 —— 构建落盘即自动升格为动画，无需整表刷代际。
      await this.loadStaticInterim();
      if (this.doc.length > 0 && this.doc !== '0') {
        gridEmit(this.sticker, `need|${this.doc}`);
      }
      // 前几轮 0.8s 间隔紧贴快段就绪时刻（≤2s 起播预算），后段放缓、
      // 20 轮总窗 ~2min 覆盖冷队列深度。
      for (let attempt = 0; attempt < 20 && this.alive; attempt++) {
        await new Promise<void>((resolve) => setTimeout(resolve, Math.min(800 + attempt * 800, 8000)));
        if (!this.alive) {
          return;
        }
        const r = await this.tryLoadCache();
        if (r !== 'miss') {
          if (CHAIN_TRACE && this.frames.length > 1) {
            console.info(`[ChainTrace] cell-ok doc=${this.doc} frames=${this.frames.length} attempt=${attempt} ms=${Date.now() - t0}`);
          }
          this.upgradeShortLoopAsync();
          return;
        }
        // .acv3 还没好，但代表帧可能已被 need 处理先落盘 —— 每轮都补试静帧，
        // 搜索结果 doc 从 🔒 空占位到静帧只差这一步（动画随后自动升格）。
        await this.loadStaticInterim();
      }
      if (CHAIN_TRACE) {
        console.info(`[ChainTrace] cell-giveup doc=${this.doc} ms=${Date.now() - t0}`);
      }
    } catch (e) {
      console.error(`[ArkGrid] load failed doc=${this.doc}: ${e}`);
    }
  }

  /** 渐进升格：装到的是快段（≤24 帧）时，定期重读 .acv3，全量替换
   *  落盘后换装完整帧集并刷新共享缓存。连续两次帧数没变视为短动画。 */
  private async upgradeShortLoopAsync(): Promise<void> {
    if (this.frames.length <= 1 || this.frames.length > 24 || this.cachePath.length === 0) {
      return;
    }
    for (let attempt = 0; attempt < 3 && this.alive; attempt++) {
      await new Promise<void>((resolve) => setTimeout(resolve, 5000));
      if (!this.alive) {
        return;
      }
      await LoadGate.acquire();
      try {
        const data: EmojiCachedFrames | null = emojiLoadCachedFrames(this.cachePath, this.tint);
        if (data == null) {
          return;
        }
        if (data.frames.length <= this.frames.length) {
          continue;
        }
        let stride = 1;
        if (this.maxFrames > 0 && data.frames.length > this.maxFrames) {
          stride = Math.ceil(data.frames.length / this.maxFrames);
        }
        const jobs: Promise<PixelMap>[] = [];
        for (let fi = 0; fi < data.frames.length; fi += stride) {
          jobs.push(bufferToPixelMap(data.frames[fi], data.raster));
        }
        const pms = await Promise.all(jobs);
        const effDuration = data.frameDurationMs * stride;
        FrameCache.put(this.cacheKey(), pms, effDuration, data.raster);
        this.durationMs = effDuration;
        this.frames = pms;
        return;
      } finally {
        LoadGate.release();
      }
    }
  }

  private frameInfos(): ImageFrameInfo[] {
    const out: ImageFrameInfo[] = [];
    for (const f of this.frames) {
      out.push({ src: f });
    }
    return out;
  }

  build() {
    if (this.frames.length > 1) {
      ImageAnimator()
        .images(this.frameInfos())
        .duration(this.frames.length * this.durationMs)
        .state(AnimationStatus.Running)
        .iterations(-1)
        .fillMode(FillMode.Forwards)
        .width(this.glyph)
        .height(this.glyph)
    } else if (this.staticFrame != null) {
      Image(this.staticFrame)
        .width(this.glyph)
        .height(this.glyph)
        .objectFit(ImageFit.Contain)
    } else {
      Column()
        .width(this.glyph)
        .height(this.glyph)
    }
  }
}

@Component
export struct EmojiGridPanel {
  @Prop @Watch('onGenChanged') gen: number = 0;
  @Prop scrollRow: number = -1;
  @Prop @Watch('onScrollSeqChanged') scrollSeq: number = 0;
  /** 贴纸模式：数据/事件走 stickerGrid 通道，格子近满幅、帧数封顶。 */
  @Prop sticker: boolean = false;
  // ---- RenderNode 贴纸动画层 ----
  private rnController: StickerAnimController = new StickerAnimController();
  private rnSync: displaySync.DisplaySync | null = null;

  private rnActive(): boolean {
    // 贴纸与 emoji 网格共用 RN 动画层；tint 模板 emoji 例外（RN 不做染色，
    // 留在 ImageAnimator 路径），见 rebuildAnimSlots / rnAnimated。
    return RENDERNODE_STICKER;
  }

  /** 由行表布局参数推算每个动画格的内容坐标（无需逐格 onAreaChange）。 */
  private rebuildAnimSlots(rows: GridRow[]): void {
    const slots: AnimSlot[] = [];
    // 字形比例与 EmojiAnimCell 的 glyph 一致（贴纸 0.94 / emoji 0.8），居中绘制
    const ratio = this.sticker ? 0.94 : 0.8;
    const prefix: number[] = [];
    let y = 0;
    for (const row of rows) {
      prefix.push(y);
      if (row.kind !== 0 && row.kind !== 2 && !row.embedded) {
        let x = row.inset;
        for (const cell of row.cells) {
          if (cell.doc.length > 0 && cell.doc !== '0' && cell.cache.length > 0 && !cell.tint) {
            const size = row.item * ratio;
            const pad = (row.item - size) / 2;
            // itemsRow 顶对齐（VerticalAlign.Top）：格子高 = row.item，
            // 字形在格内居中 —— 居中基准是 item 不是 row.h。
            slots.push({ doc: cell.doc, cache: cell.cache, stat: cell.static,
              xVp: x + pad, yVp: y + pad, sizeVp: size });
          }
          x += row.item + row.hsp;
        }
      }
      y += row.h;
    }
    this.rowYPrefix = prefix;
    this.rnController.animNode.stickerMode = this.sticker;
    this.rnController.animNode.slots = slots;
    console.info(`[RNAnim] slots=${slots.length}`);
  }

  /** 槽位坐标系里每行的起始 y（rebuildAnimSlots 同步维护）。 */
  private rowYPrefix: number[] = [];
  /** List 当前首可见行下标（onScrollIndex 维护）。 */
  private firstVisIndex: number = 0;
  private rnDbgTick: number = 0;
  /** 上一帧的滚动偏移：Scroller 未绑定（List 尚未 build / 正在卸载）时沿用。 */
  private lastScrollY: number = 0;

  private startRnSync(): void {
    if (this.rnSync != null) {
      return;
    }
    const node = this.rnController.animNode;
    node.getScrollY = (): number => {
      // currentOffset 在 LazyForEach 变高行 + scrollToIndex 远跳后是估算值
      //（emoji 行高 30/38/40/50/118 混排，跳分类后整层平移错位，真机实锤）。
      // 锚定首可见行：真实偏移 = 该行槽位前缀高度 − 它在视口内的 y。
      //
      // 必须 try/catch：本闭包在 RenderNode.draw（vsync 刷帧）里跑，而
      // startRnSync 由 aboutToAppear→reload 触发，早于 List 首次 build；
      // 面板经 `if (visible)` 卸载时也会有帧落在 List 拆除之后。此时
      // Scroller 未绑定，getItemRect/currentOffset 抛 100004
      // "Controller not bound to component"，draw 回调里未捕获 = JS_ERROR
      // 整进程闪退（2026-09-15 jscrash 真机实锤）。
      try {
        const fi = this.firstVisIndex;
        if (fi >= 0 && fi < this.rowYPrefix.length) {
          const r = this.scroller.getItemRect(fi);
          if (r != null && (r.height as number) > 0) {
            if (CHAIN_TRACE && this.rnDbgTick++ % 90 === 0) {
              const off = this.scroller.currentOffset();
              console.info(`[RNDbg] anchor fi=${fi} prefix=${this.rowYPrefix[fi]} rect.y=${r.y} rect.h=${r.height} cur=${off != null ? off.yOffset : -1}`);
            }
            this.lastScrollY = this.rowYPrefix[fi] - (r.y as number);
            return this.lastScrollY;
          }
        }
        const off = this.scroller.currentOffset();
        this.lastScrollY = off != null ? off.yOffset : this.lastScrollY;
      } catch (e) {
        // Scroller 未绑定：保持上一帧偏移，不中断绘制
      }
      return this.lastScrollY;
    };
    this.rnSync = displaySync.create();
    this.rnSync.setExpectedFrameRateRange({ expected: 30, min: 30, max: 30 });
    this.rnSync.on('frame', () => {
      node.step(33.4);
    });
    this.rnSync.start();
  }

  private stopRnSync(): void {
    if (this.rnSync != null) {
      this.rnSync.stop();
      this.rnSync = null;
    }
    this.rnController.animNode.closeAll();
  }

  private source: RowDataSource = new RowDataSource();
  private scroller: Scroller = new Scroller();
  private lastTopGroup: string = '';
  private doneScrollSeq: number = 0;

  // S2-37：贴纸格长按识别（iOS PeekControllerGestureRecognizer longTapTimer 0.4s）。
  // W3：EmojiAnimCell 上的 LongPressGesture 真机不触发；W4：本组件内 onTouch + setTimeout(400)
  // 同样没有预览。两版共同点是长按判定留在 ArkTS 覆盖层里 —— 按住期间行表 gen 一变
  // （帧缓存落盘 → JSON 变化 → onDataReloaded 整表重建）被按的格子就被销毁，手势 / 定时器
  // 随之作废。现在 ArkTS 只上报原始触摸相位（press / unpress），400ms 计时放到仓颉侧
  // StickerKeyboardPanel（与 StickerGridCell / MessageBubble 同一套真机已验证的 spawn 计时），
  // 格子被重建也不影响计时；移动超过 ~5vp 视为滚动、上报 unpress|move 取消。
  // 长按成功后抬手的 onClick 由仓颉侧按 doc 吞掉（cell 事件在预览期间忽略）。
  private pressDoc: string = '';
  private pressX: number = 0;
  private pressY: number = 0;
  // R6V S2-37 容器级兜底：格子级 onTouch / LongPressGesture 在真机六轮里从未上报过任何相位
  //（仓颉侧没有一条 "[ArkStk] press"），而同一 Column 的 onClick 发送却是通的。List 自身的
  // onTouch 不依赖格子节点存活（行表 gen 变化整表重建也不丢），按触点几何反查格子。
  private listPressDoc: string = '';
  private listPressGroup: string = '';
  private listPressX: number = 0;
  private listPressY: number = 0;

  private handleCellTouch(e: TouchEvent, doc: string, group: string): void {
    if (!this.sticker) {
      return;
    }
    const pt: TouchObject | undefined = e.touches.length > 0 ? e.touches[0]
      : (e.changedTouches.length > 0 ? e.changedTouches[0] : undefined);
    switch (e.type) {
      case TouchType.Down:
        if (pt === undefined) {
          return;
        }
        this.pressDoc = doc;
        this.pressX = pt.x;
        this.pressY = pt.y;
        // 先上报再打日志：W5 版先 hilog 再 gridEmit，日志一旦抛异常事件就丢了。
        gridEmit(this.sticker, `press|${doc}|${group}|cell`);
        stkDiag(this.sticker, `ets cell touch down doc=${doc} group=${group} x=${Math.round(pt.x)} y=${Math.round(pt.y)}`);
        break;
      case TouchType.Move:
        if (this.pressDoc === doc && pt !== undefined) {
          const dx = pt.x - this.pressX;
          const dy = pt.y - this.pressY;
          if (dx * dx + dy * dy > 25) {
            this.pressDoc = '';
            gridEmit(this.sticker, `unpress|${doc}|move`);
            stkDiag(this.sticker, `ets cell touch move-cancel doc=${doc} dx=${Math.round(dx)} dy=${Math.round(dy)}`);
          }
        }
        break;
      case TouchType.Up:
        if (this.pressDoc === doc) {
          this.pressDoc = '';
          gridEmit(this.sticker, `unpress|${doc}|up`);
          stkDiag(this.sticker, `ets cell touch up doc=${doc}`);
        }
        break;
      case TouchType.Cancel:
        // 格子随行表重建被销毁时也会来 Cancel：仓颉侧只记录、不取消计时
        //（真正的滚动已由 Move 阈值提前取消）。
        if (this.pressDoc === doc) {
          this.pressDoc = '';
          gridEmit(this.sticker, `unpress|${doc}|cancel`);
          stkDiag(this.sticker, `ets cell touch cancel doc=${doc}`);
        }
        break;
      default:
        break;
    }
  }

  /**
   * 按 List 内触点坐标（vp，相对 List 左上角）+ 当前滚动偏移反查贴纸格；非贴纸格
   *（头行 / 按钮行 / 内嵌 trending 行 / 新建格 / 展开格）返回空串。
   */
  private cellAtListPoint(x: number, y: number): [string, string] {
    let offset = 0;
    try {
      offset = this.scroller.currentOffset().yOffset;
    } catch (_e) {
      offset = 0;
    }
    let acc = -offset;
    const n = this.source.totalCount();
    for (let i = 0; i < n; i++) {
      const row = this.source.getData(i);
      if (row === undefined) {
        break;
      }
      const top = acc;
      acc += row.h;
      if (y < top || y >= acc) {
        continue;
      }
      if (row.kind === 0 || row.kind === 2 || row.embedded || row.item <= 0) {
        return ['', row.group];
      }
      const rel = x - row.inset;
      if (rel < 0) {
        return ['', row.group];
      }
      const stride = row.item + row.hsp;
      const idx = Math.floor(rel / stride);
      if (idx < 0 || idx >= row.cells.length || rel - idx * stride > row.item) {
        return ['', row.group];
      }
      // 行内垂直范围：格子从行顶开始、高 item（itemsRow 以 VerticalAlign.Top 排布）
      if (y - top > row.item) {
        return ['', row.group];
      }
      const cell = row.cells[idx];
      if (cell.cr === true || cell.x.length > 0 || cell.e.length > 0 || cell.doc.length === 0 || cell.doc === '0') {
        return ['', row.group];
      }
      return [cell.doc, row.group];
    }
    return ['', ''];
  }

  private handleListTouch(e: TouchEvent): void {
    if (!this.sticker) {
      return;
    }
    const pt: TouchObject | undefined = e.touches.length > 0 ? e.touches[0]
      : (e.changedTouches.length > 0 ? e.changedTouches[0] : undefined);
    switch (e.type) {
      case TouchType.Down: {
        if (pt === undefined) {
          return;
        }
        const hit = this.cellAtListPoint(pt.x, pt.y);
        this.listPressDoc = hit[0];
        this.listPressGroup = hit[1];
        this.listPressX = pt.x;
        this.listPressY = pt.y;
        if (hit[0].length > 0) {
          gridEmit(this.sticker, `press|${hit[0]}|${hit[1]}|list`);
        }
        stkDiag(this.sticker, `ets list touch down x=${Math.round(pt.x)} y=${Math.round(pt.y)} doc=${hit[0]} group=${hit[1]} cellPress=${this.pressDoc}`);
        break;
      }
      case TouchType.Move:
        if (this.listPressDoc.length > 0 && pt !== undefined) {
          const dx = pt.x - this.listPressX;
          const dy = pt.y - this.listPressY;
          if (dx * dx + dy * dy > 25) {
            const doc = this.listPressDoc;
            this.listPressDoc = '';
            gridEmit(this.sticker, `unpress|${doc}|move`);
            stkDiag(this.sticker, `ets list touch move-cancel doc=${doc} dx=${Math.round(dx)} dy=${Math.round(dy)}`);
          }
        }
        break;
      case TouchType.Up:
        if (this.listPressDoc.length > 0) {
          const doc = this.listPressDoc;
          this.listPressDoc = '';
          gridEmit(this.sticker, `unpress|${doc}|up`);
          stkDiag(this.sticker, `ets list touch up doc=${doc}`);
        } else {
          stkDiag(this.sticker, 'ets list touch up (no cell)');
        }
        break;
      case TouchType.Cancel:
        if (this.listPressDoc.length > 0) {
          const doc = this.listPressDoc;
          this.listPressDoc = '';
          gridEmit(this.sticker, `unpress|${doc}|cancel`);
          stkDiag(this.sticker, `ets list touch cancel doc=${doc}`);
        }
        break;
      default:
        break;
    }
  }

  aboutToAppear(): void {
    this.reload();
    // 面板重挂时若带着未消费的跳转（挂载前点了导航），布局完成后补跳
    if (this.scrollSeq > this.doneScrollSeq && this.scrollRow >= 0) {
      const row = this.scrollRow;
      this.doneScrollSeq = this.scrollSeq;
      setTimeout(() => {
        this.safeScrollToRow(row);
      }, 32);
    } else {
      this.doneScrollSeq = this.scrollSeq;
    }
  }

  aboutToDisappear(): void {
    this.stopRnSync();
  }

  onGenChanged(): void {
    this.reload();
  }

  onScrollSeqChanged(): void {
    // 仓颉导航跳转转发（iOS 同款瞬时定位）。延迟一拍执行：跳转可能与
    // 数据代际同载荷到达（分类切换 = 换表 + 跳转），先让 reload 的
    // setRows/布局落地，再对新表 scrollToIndex —— 否则落在旧表上。
    if (this.scrollSeq !== this.doneScrollSeq && this.scrollRow >= 0) {
      this.doneScrollSeq = this.scrollSeq;
      const row = this.scrollRow;
      setTimeout(() => {
        this.safeScrollToRow(row);
      }, 48);
    }
  }

  /** 延时跳转落地时 List 可能已随面板卸载：Scroller 未绑定会抛 100004，定时器里未捕获同样闪退。 */
  private safeScrollToRow(row: number): void {
    try {
      this.scroller.scrollToIndex(row, false, ScrollAlign.START);
    } catch (e) {
      console.warn(`[ArkGrid] scrollToIndex skipped (scroller unbound): ${e}`);
    }
  }

  private reload(): void {
    const json = this.sticker ? getStickerGridRows() : getEmojiGridRows();
    console.info(`[ArkGrid] reload sticker=${this.sticker} jsonLen=${json.length}`);
    if (json.length === 0) {
      return;
    }
    try {
      const payload: GridPayload = JSON.parse(json) as GridPayload;
      console.info(`[ArkGrid] rows=${payload.rows.length}`);
      this.source.setRows(payload.rows);
      if (this.rnActive()) {
        this.rebuildAnimSlots(payload.rows);
        this.startRnSync();
      }
    } catch (e) {
      console.error(`[ArkGrid] parse failed: ${e}`);
    }
  }

  @Builder
  headerRow(row: GridRow) {
    if ((row.act ?? '').length > 0) {
      this.featuredHeaderRow(row)
    } else {
      this.plainHeaderRow(row)
    }
  }

  // 贴纸精选头行（iOS itemFeaturedHeaderHeight=60：左标题+副题，右 Add 药丸）
  @Builder
  featuredHeaderRow(row: GridRow) {
    Row() {
      Column() {
        Text(row.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(0xFF1C1C1E)
          .maxLines(1)
        Text(row.sub)
          .fontSize(12)
          .fontColor(0xFF8E8E93)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(row.act ?? 'Add')
        .fontSize(13)
        .fontColor(Color.White)
        .height(28)
        .padding({ left: 14, right: 14 })
        .borderRadius(14)
        .backgroundColor(0xFF317AFF)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          gridEmit(this.sticker, `button|${row.group}`);
        })
    }
    .width('100%')
    .height(row.h)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  plainHeaderRow(row: GridRow) {
    Row() {
      Blank().width(28)
      Blank()
      if (row.locked) {
        Text('🔒').fontSize(11).opacity(0.55).margin({ right: 4 })
      }
      Text(row.title)
        .fontSize(12)
        .fontColor(0xFF8E8E93)
        .fontWeight(FontWeight.Medium)
      Blank()
      if (row.clear.length > 0) {
        Text('×')
          .fontSize(22)
          .fontColor(0xFFA1A7AD)
          .width(28)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            gridEmit(this.sticker, `clear|${row.clear}`);
          })
      } else {
        Blank().width(28)
      }
    }
    .width('100%')
    .height(row.h)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  buttonRow(row: GridRow) {
    Row() {
      Text(row.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .maxLines(1)
      if (row.locked) {
        Text('🔒').fontSize(13).margin({ left: 6 })
      }
    }
    .width('100%')
    .height(40)
    .margin({ top: 4, bottom: 6 })
    .borderRadius(20)
    .justifyContent(FlexAlign.Center)
    .linearGradient(row.locked
      ? { angle: 90, colors: [[0xFF0077FF, 0.0], [0xFF6B93FF, 0.33], [0xFF8878FF, 0.66], [0xFFE46ACE, 1.0]] }
      : { angle: 90, colors: [[0xFF007AFF, 0.0], [0xFF007AFF, 1.0]] })
    .onClick(() => {
      gridEmit(this.sticker, `button|${row.group}`);
    })
  }

  @Builder
  cellView(row: GridRow, cell: GridCell, idx: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (cell.cr === true) {
        // 「新建贴纸」格:与旧仓颉网格 buildCreateTile 同款视觉(+ / 双行标签)
        Column() {
          Text('+')
            .fontSize(28)
            .fontColor(0xFF8E8E93)
          Text('Create\nSticker')
            .fontSize(10)
            .fontColor(0xFF8E8E93)
            .textAlign(TextAlign.Center)
        }
        .width(row.item)
        .height(row.item)
        .borderRadius(12)
        .backgroundColor(0x12000000)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          gridEmit(this.sticker, 'create|');
        })
      } else if (cell.x.length > 0) {
        Column() {
          Text(cell.x)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(0xFF8E8E93)
        }
        .width(row.item)
        .height(row.item)
        .borderRadius(row.item / 2)
        .backgroundColor(0x14767680)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          gridEmit(this.sticker, `expand|${row.group}`);
        })
      } else if (cell.e.length > 0) {
        Text(cell.e)
          .fontSize(row.item * 0.72)
          .onClick(() => {
            gridEmit(this.sticker, `cell|0|${cell.e}`);
          })
      } else {
        // S2-37：点击 / 长按都挂在这个内置 Column 上（自定义组件上的 LongPressGesture 真机不触发）。
        // 触摸相位（press / unpress，见 handleCellTouch）上报仓颉侧 StickerKeyboardPanel，
        // 400ms 计时在仓颉侧完成后打开 StickerPreviewOverlay（Send Without Sound /
        // Add to Favorites …），抬手后菜单保留。事件带 group 便于识别 Recently Used 分区。
        Column() {
          EmojiAnimCell({
            doc: cell.doc,
            cachePath: cell.cache,
            staticPath: cell.static,
            tint: cell.tint,
            // 贴纸近满幅（iOS 贴纸格 ~2px 留边）；emoji 保持 0.8
            glyph: this.sticker ? row.item * 0.94 : row.item * 0.8,
            sticker: this.sticker,
            maxFrames: this.sticker ? 90 : 0,
            // RN 动画层接管的格子：不装帧、不占内存，只留占位与锁角标
            rnAnimated: this.rnActive() && !row.embedded && cell.cache.length > 0 && !cell.tint
          })
        }
        .width(row.item)
        .height(row.item)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          // 长按已弹出预览时这次抬手不是发送：仓颉侧 handleStkGridEvent 按 doc 吞掉。
          gridEmit(this.sticker, `cell|${cell.doc}|`);
          if (this.sticker) {
            stkDiag(this.sticker, `ets click doc=${cell.doc} group=${row.group}`);
          }
        })
        .onTouch((e: TouchEvent) => {
          this.handleCellTouch(e, cell.doc, row.group);
        })
        // W5 S2-37 第二路：内置 Column 上的 LongPressGesture（W3 失效的是挂在自定义组件
        // EmojiAnimCell 上的那次）。parallelGesture 不抢 List 滚动；仓颉侧 "long" 事件直接开
        // 预览并与 press 计时去重。贴纸面板专用（emoji 面板无长按菜单）。
        .parallelGesture(
          LongPressGesture({ fingers: 1, repeat: false, duration: 400 })
            .onAction(() => {
              if (!this.sticker) {
                return;
              }
              gridEmit(this.sticker, `long|${cell.doc}|${row.group}`);
              stkDiag(this.sticker, `ets longpress gesture doc=${cell.doc} group=${row.group}`);
            })
        )
        if (cell.lock) {
          Column() {
            Text('🔒')
              .fontSize(9)
              .width(15)
              .height(15)
              .textAlign(TextAlign.Center)
              .borderRadius(8)
              .backgroundColor(0x66FFFFFF)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
        }
      }
    }
    .width(row.item)
    .height(row.item)
    .margin({ left: idx === 0 ? 0 : row.hsp })
  }

  @Builder
  itemsRow(row: GridRow) {
    if (row.embedded) {
      List({ space: 0 }) {
        ForEach(row.cells, (cell: GridCell, idx: number) => {
          ListItem() {
            this.cellView(row, cell, idx)
          }
        }, (cell: GridCell, idx: number) => `${row.key}#${cell.doc}#${idx}`)
      }
      .listDirection(Axis.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(row.h)
      .padding({ left: row.inset, right: row.inset })
    } else {
      Row() {
        ForEach(row.cells, (cell: GridCell, idx: number) => {
          this.cellView(row, cell, idx)
        }, (cell: GridCell, idx: number) => `${row.key}#${cell.doc}#${cell.e}#${idx}`)
      }
      .width('100%')
      .height(row.h)
      .padding({ left: row.inset, right: row.inset })
      .alignItems(VerticalAlign.Top)
    }
  }

  build() {
    if (this.rnActive()) {
      // RenderNode 动画层垫底，List（透明底）浮其上承担布局/滚动/点击；
      // 锁角标/头行等由 List 内容自然盖在动画帧之上。
      Stack() {
        NodeContainer(this.rnController)
          .width('100%')
          .height('100%')
          // 父组件默认不裁剪子节点：RenderNode 画布会溢出面板压到
          // 下方页签行（真机实锤），必须显式裁剪。
          .clip(true)
        this.gridList()
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .backgroundColor(0xFFF1F3F5)
      .onAreaChange((_o: Area, n: Area) => {
        const node = this.rnController.animNode;
        node.viewportHVp = n.height as number;
        // frame 同步视口并裁剪：越界绘制会盖到页签行（真机实锤）
        node.frame = {
          x: 0, y: 0,
          width: (n.width as number) * node.pxScale,
          height: (n.height as number) * node.pxScale
        };
      })
    } else {
      this.gridList()
    }
  }

  @Builder
  gridList() {
    List({ space: 0, scroller: this.scroller }) {
      LazyForEach(this.source, (row: GridRow) => {
        ListItem() {
          if (row.kind === 0) {
            this.headerRow(row)
          } else if (row.kind === 2) {
            this.buttonRow(row)
          } else {
            this.itemsRow(row)
          }
        }
      }, (row: GridRow) => row.key)
    }
    .width('100%')
    .height('100%')
    // 4 行预挂载：回划时格子还活着（配合大缓存，反复加载观感消失）
    .cachedCount(4)
    // 对位旧仓颉 List 的 padding(bottom:12)：最后一个分组的底按钮不被裁半
    .contentEndOffset(12)
    .scrollBar(BarState.Off)
    // RN 动画层模式下 List 透明垫上层（动画帧从底层透出）
    .backgroundColor(this.rnActive() ? Color.Transparent : 0xFFF1F3F5)
    // R6V S2-37：List 级触摸相位兜底（见 handleListTouch）。onTouch 不消费事件，不影响滚动与 onClick。
    .onTouch((e: TouchEvent) => {
      this.handleListTouch(e);
    })
    .onDidScroll(() => {
      // 滚动帧同步：动画层立即按最新偏移重画（纯 drawImageRect ~1-2ms），
      // 否则贴纸以 30fps 步进跟随、与 60/120fps 滚动的 List 内容脱钩
      //（「仿佛不在一个图层」的直接成因）。解帧节奏仍归 displaySync。
      if (this.rnActive()) {
        this.rnController.animNode.invalidate();
      }
    })
    .onScrollIndex((first: number) => {
      this.firstVisIndex = first;
      const row = this.source.getData(first);
      if (row !== undefined && row.group !== this.lastTopGroup) {
        this.lastTopGroup = row.group;
        gridEmit(this.sticker, `top|${row.group}`);
      }
    })
  }
}
