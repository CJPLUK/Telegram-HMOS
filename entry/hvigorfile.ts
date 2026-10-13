import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import type { HvigorPlugin } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

// The Cangjie SDK extends the standard module build-profile schema with
// cangjieOptions. CLI builds must install that validator before hapTasks reads
// entry/build-profile.json5.
(function patchCangjieSchema() {
  try {
    const fs = require('fs') as typeof import('fs');
    const cjBuildBase = path.join(os.homedir(), '.cangjie', 'build');

    const schemaName = 'ohos-module-build-profile-schema.json';
    let cjSchema = '';
    if (fs.existsSync(cjBuildBase)) {
      for (const ver of fs.readdirSync(cjBuildBase).sort().reverse()) {
        const candidate = path.join(cjBuildBase, ver, 'cj-plugin-cache', schemaName);
        if (fs.existsSync(candidate)) {
          cjSchema = candidate;
          break;
        }
      }
    }
    if (!cjSchema) {
      const appSupport = path.join(os.homedir(), 'Library', 'Application Support', 'Huawei');
      if (fs.existsSync(appSupport)) {
        for (const product of fs.readdirSync(appSupport).sort().reverse()) {
          const candidate = path.join(appSupport, product, 'cj-plugin-cache', schemaName);
          if (fs.existsSync(candidate)) {
            cjSchema = candidate;
            break;
          }
        }
      }
    }
    if (!cjSchema) return;

    const { ValidatorStore } = require('@ohos/hvigor-ohos-plugin/src/utils/validate/validator-store');
    const { BuildProfileSchemaFileConst } = require('@ohos/hvigor-ohos-plugin/src/const/common-const');
    const standardSchema: string = BuildProfileSchemaFileConst.HAP_MODULE_BUILD_PROFILE_SCHEMA_PATH;
    const validator = ValidatorStore.addValidator(cjSchema, false);
    ValidatorStore.getValidatorMap().set(`${standardSchema}:false`, validator);
  } catch (_) {
    // The subsequent schema validation provides the actionable failure.
  }
})();

// API 22 devices resolve ArkTS native modules from libs/<abi>, while the
// current Cangjie Hvigor extension leaves the generated entry module under
// libs/<abi>/cjbins.  Stage the same library in the standard ABI directory
// after the extension moves its outputs and before native stripping/packages.
// This keeps clean installs working; incremental installs used to hide the
// problem by retaining an older root-level copy on the device.
const cangjieNativeModuleCompat: HvigorPlugin = {
  pluginId: 'cangjie-native-module-compat',
  apply(node) {
    node.afterNodeEvaluate((configuredNode) => {
      const moveTask = configuredNode.getAllTasks().find(
        (task) => task.getName().endsWith('@MoveCangjieLibs')
      );
      if (!moveTask) return;

      moveTask.afterRun(() => {
        const libraryName = 'libohos_app_cangjie_entry.so';
        for (const abi of ['arm64-v8a', 'x86_64']) {
          const abiDir = path.join(
            __dirname,
            'build', 'default', 'intermediates', 'libs', 'default', abi
          );
          const cangjieLibrary = path.join(abiDir, 'cjbins', libraryName);
          if (!fs.existsSync(cangjieLibrary)) continue;
          fs.copyFileSync(cangjieLibrary, path.join(abiDir, libraryName));
        }
      });
    });
  }
};

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [cangjieNativeModuleCompat]
}
