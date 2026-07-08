const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');
const fs = require('fs');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * SUBSTドライブ(tools/android-zfold7.ps1 が長パス対策で X: を割り当てる)経由で
 * gradle からバンドルすると、node の require.resolve は実パス(C:)を返す一方で
 * Metro の projectRoot が X: のままになり、「Failed to get the SHA-1 for:
 * ...metro-runtime\src\polyfills\require.js」で release バンドルが失敗する。
 * projectRoot を realpath へ正規化して、どちらのパスで起動されても一貫させる。
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const projectRoot = fs.realpathSync(__dirname);

const config = {
  projectRoot,
  watchFolders: [projectRoot],
};

module.exports = mergeConfig(getDefaultConfig(projectRoot), config);
