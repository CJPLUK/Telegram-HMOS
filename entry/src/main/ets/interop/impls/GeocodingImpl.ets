// Geocoding capability — real @kit.LocationKit geoLocationManager impl (Phase 3 reversal, SSOT §5).
// ArkTS owns the system-module calls; cangjie GeocodingService calls via callArkAsync(GEOCODE_*, argJson, cb).
//
// Two methods:
//   GEOCODE_REVERSE  — geoLocationManager.getAddressesFromLocation({latitude, longitude, maxItems:1})
//     argJson (cangjie → ArkTS): {"lat": number, "lng": number}
//     result  (ArkTS → cangjie): {"ok": boolean, "name": string, "road": string, "city": string,
//                                 "province": string, "country": string, "countryCode": string}
//   GEOCODE_FORWARD  — geoLocationManager.getAddressesFromLocationName({description, maxItems:1})
//     argJson (cangjie → ArkTS): {"address": string}
//     result  (ArkTS → cangjie): {"ok": boolean, "lat": number, "lng": number,
//                                 "name": string, "city": string, "country": string}
// On any failure or empty result: {"ok": false}. Offline / no backend → ok:false (cangjie returns None).
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { geoLocationManager } from '@kit.LocationKit';

interface ReverseArgs {
  lat: number;
  lng: number;
}

interface ForwardArgs {
  address: string;
}

interface ReverseResult {
  ok: boolean;
  name: string;
  road: string;
  city: string;
  province: string;
  country: string;
  countryCode: string;
}

interface ForwardResult {
  ok: boolean;
  lat: number;
  lng: number;
  name: string;
  city: string;
  country: string;
}

function str(v: string | undefined): string {
  return (typeof v === 'string') ? v : '';
}

function num(v: number | undefined): number {
  return (typeof v === 'number') ? v : 0;
}

export function registerGeocoding(): void {
  // ---- reverse geocode: coordinates → address ----
  registerArkFunc(InteropMethod.GEOCODE_REVERSE, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: ReverseArgs = JSON.parse(argJson) as ReverseArgs;
      const request: geoLocationManager.ReverseGeoCodeRequest = {
        latitude: args.lat,
        longitude: args.lng,
        maxItems: 1
      };
      geoLocationManager.getAddressesFromLocation(request)
        .then((addresses: Array<geoLocationManager.GeoAddress>): void => {
          if (addresses && addresses.length > 0) {
            const a: geoLocationManager.GeoAddress = addresses[0];
            const result: ReverseResult = {
              ok: true,
              name: str(a.placeName),
              road: str(a.roadName),
              city: str(a.locality),
              province: str(a.administrativeArea),
              country: str(a.countryName),
              countryCode: str(a.countryCode)
            };
            onResult(JSON.stringify(result));
          } else {
            onResult(JSON.stringify({ ok: false }));
          }
        })
        .catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });

  // ---- forward geocode: address → coordinates ----
  registerArkFunc(InteropMethod.GEOCODE_FORWARD, (argJson: string, onResult: (r: string) => void): void => {
    try {
      const args: ForwardArgs = JSON.parse(argJson) as ForwardArgs;
      const request: geoLocationManager.GeoCodeRequest = {
        description: args.address,
        maxItems: 1
      };
      geoLocationManager.getAddressesFromLocationName(request)
        .then((addresses: Array<geoLocationManager.GeoAddress>): void => {
          if (addresses && addresses.length > 0) {
            const a: geoLocationManager.GeoAddress = addresses[0];
            const result: ForwardResult = {
              ok: true,
              lat: num(a.latitude),
              lng: num(a.longitude),
              name: str(a.placeName),
              city: str(a.locality),
              country: str(a.countryName)
            };
            onResult(JSON.stringify(result));
          } else {
            onResult(JSON.stringify({ ok: false }));
          }
        })
        .catch((): void => {
          onResult(JSON.stringify({ ok: false }));
        });
    } catch (e) {
      onResult(JSON.stringify({ ok: false }));
    }
  });
}
