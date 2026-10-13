import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { storageStatistics } from '@kit.CoreFileKit';

interface StorageStatsResult {
  ok: boolean;
  freeBytes: number;
  totalBytes: number;
}

export function registerStorageStats(): void {
  registerArkFunc('storage.stats', (_argJson: string, onResult: (r: string) => void): void => {
    Promise.all([storageStatistics.getFreeSize(), storageStatistics.getTotalSize()]).then((values: number[]): void => {
      const result: StorageStatsResult = { ok: true, freeBytes: values[0], totalBytes: values[1] };
      onResult(JSON.stringify(result));
    }).catch((): void => {
      const result: StorageStatsResult = { ok: false, freeBytes: 0, totalBytes: 0 };
      onResult(JSON.stringify(result));
    });
  });
}
