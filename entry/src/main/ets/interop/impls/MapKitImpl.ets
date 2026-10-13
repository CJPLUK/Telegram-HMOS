// HMS Map Kit 能力反转（仓颉 → ArkTS）：
//   map.staticImage    {lat,lng,w,h,zoom} → staticMap.getMapImage → 沙箱 jpg 路径（气泡/详情页地图快照，对位 iOS MKMapSnapshotter）
//   map.nearbySearch   {lat,lng,query,radius} → site.nearbySearch → POI 列表（附件面板「OR CHOOSE A PLACE」）
//   map.queryLocation  {lat,lng,name} → sceneMap.queryLocation 拉起系统地图查看页（点位置气泡）
// 三者均可能因 Map Kit 鉴权/网络失败（1002600003 等）返回 ok=false，仓颉侧各自有兜底。
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { staticMap, site, sceneMap, mapCommon } from '@kit.MapKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

interface StaticImageArgs {
  lat: number;
  lng: number;
  w: number;
  h: number;
  zoom?: number;
}

interface NearbyArgs {
  lat: number;
  lng: number;
  query?: string;
  radius?: number;
}

interface QueryLocationArgs {
  lat: number;
  lng: number;
  name?: string;
}

interface PoiOut {
  id: string;
  name: string;
  address: string;
  lat: number;
  lng: number;
  type: string;
}

async function renderStaticMap(a: StaticImageArgs): Promise<string> {
  let pixelMap: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  let output: fileIo.File | undefined = undefined;
  let path: string = '';
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const loc: mapCommon.LatLng = { latitude: a.lat, longitude: a.lng };
    const options: staticMap.StaticMapOptions = {
      location: loc,
      zoom: a.zoom ?? 15,
      imageWidth: Math.max(64, Math.floor(a.w)),
      imageHeight: Math.max(64, Math.floor(a.h))
    };
    path = context.cacheDir + '/mapkit_' + a.lat.toFixed(5) + '_' + a.lng.toFixed(5) + '_' +
      Math.floor(a.w).toString() + 'x' + Math.floor(a.h).toString() + '_' + (a.zoom ?? 15).toString() + '_nm.jpg';  // _nm：无 marker 版本（iOS 快照不带 marker）
    // 同参数图片已生成过：直接复用（气泡列表里同一位置会反复请求）
    if (fileIo.accessSync(path)) {
      return path;
    }
    pixelMap = await staticMap.getMapImage(context, options);
    output = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    packer = image.createImagePacker();
    const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 90 };
    await packer.packToFile(pixelMap, output.fd, packOpts);
    return path;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.error(`[MapKit] staticImage failed: code=${err.code} msg=${err.message}`);
    if (path.length > 0) {
      try { fileIo.unlinkSync(path); } catch (_e2) {}
    }
    return '';
  } finally {
    if (output !== undefined) {
      try { fileIo.closeSync(output); } catch (_e3) {}
    }
    if (packer !== undefined) {
      try { packer.release(); } catch (_e4) {}
    }
    if (pixelMap !== undefined) {
      try { pixelMap.release(); } catch (_e5) {}
    }
  }
}

async function searchNearby(a: NearbyArgs): Promise<PoiOut[]> {
  const out: PoiOut[] = [];
  try {
    const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    const params: site.NearbySearchParams = {
      location: { latitude: a.lat, longitude: a.lng },
      radius: a.radius ?? 1000
    };
    if (a.query !== undefined && a.query.length > 0) {
      params.query = a.query;
    }
    const result: site.NearbySearchResult = await site.nearbySearch(context, params);
    const sites: site.Site[] = result.sites ?? [];
    for (let i: number = 0; i < sites.length; i++) {
      const s: site.Site = sites[i];
      if (s.location === undefined) {
        continue;
      }
      let type: string = '';
      if (s.poi !== undefined && s.poi.poiTypes !== undefined && s.poi.poiTypes.length > 0) {
        type = s.poi.poiTypes[0];
      }
      out.push({
        id: s.siteId,
        name: s.name ?? '',
        address: s.formatAddress ?? '',
        lat: s.location.latitude,
        lng: s.location.longitude,
        type: type
      });
    }
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    console.error(`[MapKit] nearbySearch failed: code=${err.code} msg=${err.message}`);
  }
  return out;
}

export function registerMapKit(): void {
  registerArkFunc('map.staticImage', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: StaticImageArgs = JSON.parse(argJson) as StaticImageArgs;
      renderStaticMap(a).then((p: string): void => {
        onResult(JSON.stringify({ ok: p.length > 0, path: p }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, path: '' }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false, path: '' }));
    }
  });

  registerArkFunc('map.nearbySearch', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: NearbyArgs = JSON.parse(argJson) as NearbyArgs;
      searchNearby(a).then((list: PoiOut[]): void => {
        onResult(JSON.stringify({ ok: true, sites: list }));
      }).catch((): void => {
        onResult(JSON.stringify({ ok: false, sites: [] as PoiOut[] }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false, sites: [] as PoiOut[] }));
    }
  });

  registerArkFunc('map.queryLocation', (argJson: string, onResult: (r: string) => void): void => {
    try {
      const a: QueryLocationArgs = JSON.parse(argJson) as QueryLocationArgs;
      const context: common.UIAbilityContext = getContext() as common.UIAbilityContext;
      const opts: sceneMap.LocationQueryOptions = {
        location: { latitude: a.lat, longitude: a.lng }
      };
      if (a.name !== undefined && a.name.length > 0) {
        opts.name = a.name;
      }
      sceneMap.queryLocation(context, opts).then((): void => {
        onResult(JSON.stringify({ ok: true }));
      }).catch((e: BusinessError): void => {
        console.error(`[MapKit] queryLocation failed: code=${e.code} msg=${e.message}`);
        onResult(JSON.stringify({ ok: false }));
      });
    } catch (_e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
