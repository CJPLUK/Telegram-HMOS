import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { i18n } from '@kit.LocalizationKit';

interface LanguageDisplayNamesArgs {
  codes?: string[];
}

/** Mirrors Foundation Locale(code).localizedString(forLanguageCode: code). */
export function registerLanguageDisplayNames(): void {
  registerArkFunc(InteropMethod.LANGUAGE_DISPLAY_NAMES,
    (argJson: string, onResult: (result: string) => void): void => {
      try {
        const args: LanguageDisplayNamesArgs = JSON.parse(argJson) as LanguageDisplayNamesArgs;
        const codes: string[] = Array.isArray(args.codes) ? args.codes : [];
        const names: string[] = codes.map((code: string): string => {
          try {
            return i18n.System.getDisplayLanguage(code, code, true);
          } catch (_) {
            return code;
          }
        });
        onResult(JSON.stringify({ names: names }));
      } catch (_) {
        onResult('{"names":[]}');
      }
    });
}
