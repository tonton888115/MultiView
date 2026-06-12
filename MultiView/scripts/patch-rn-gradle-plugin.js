const fs = require('node:fs');
const path = require('node:path');

const settingsPath = path.join(
  __dirname,
  '..',
  'node_modules',
  '@react-native',
  'gradle-plugin',
  'settings.gradle.kts',
);

if (!fs.existsSync(settingsPath)) {
  console.warn('[patch-rn-gradle-plugin] React Native Gradle plugin settings not found.');
  process.exit(0);
}

const source = fs.readFileSync(settingsPath, 'utf8');
const pluginLinePattern =
  /\r?\nplugins \{ id\("org\.gradle\.toolchains\.foojay-resolver-convention"\)\.version\("[^"]+"\) \}\r?\n/;

if (!pluginLinePattern.test(source)) {
  console.log('[patch-rn-gradle-plugin] foojay resolver plugin line already absent.');
  process.exit(0);
}

fs.writeFileSync(settingsPath, source.replace(pluginLinePattern, '\n'));
console.log('[patch-rn-gradle-plugin] Removed foojay resolver plugin line for local Gradle compatibility.');
