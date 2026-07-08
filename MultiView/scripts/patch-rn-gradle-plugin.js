const fs = require('node:fs');
const path = require('node:path');

// React Native Gradle plugin (node_modules内ソースからincluded buildでコンパイルされる)
// への局所パッチ。npm install で node_modules が再生成されるたびに postinstall で
// 再適用する。各パッチは冪等で、適用済み/対象欠落なら黙ってスキップする。

const pluginRoot = path.join(__dirname, '..', 'node_modules', '@react-native', 'gradle-plugin');

function applyPatch(name, filePath, test, apply) {
  if (!fs.existsSync(filePath)) {
    console.warn(`[patch-rn-gradle-plugin] ${name}: target not found, skipped.`);
    return;
  }
  const source = fs.readFileSync(filePath, 'utf8');
  if (!test(source)) {
    console.log(`[patch-rn-gradle-plugin] ${name}: already applied.`);
    return;
  }
  fs.writeFileSync(filePath, apply(source));
  console.log(`[patch-rn-gradle-plugin] ${name}: applied.`);
}

// パッチ1: foojay resolver プラグイン行の除去(ローカルGradle互換)。
const foojayPattern =
  /\r?\nplugins \{ id\("org\.gradle\.toolchains\.foojay-resolver-convention"\)\.version\("[^"]+"\) \}\r?\n/;
applyPatch(
  'foojay-resolver removal',
  path.join(pluginRoot, 'settings.gradle.kts'),
  source => foojayPattern.test(source),
  source => source.replace(foojayPattern, '\n'),
);

// パッチ2: Os.cliPath のドライブ跨ぎフォールバック。
// 長パス対策のSUBSTドライブ(X:)でビルドしつつ Metro バンドルだけ実パス(C:)で実行する
// 構成(app/build.gradle の react.root + MULTIVIEW_REPO_REAL_ROOT 参照)では、
// Windows専用の relativeTo(base) が「different roots」で投げて release バンドルが
// 失敗する。異ドライブ時は絶対パスへフォールバックさせる(このリポジトリのパスには
// スペースが無いため安全)。
const cliPathOriginal = `  fun File.cliPath(base: File): String =
      if (isWindows()) {
        this.relativeTo(base).path
      } else {
        absolutePath
      }`;
const cliPathPatched = `  fun File.cliPath(base: File): String =
      if (isWindows()) {
        try {
          this.relativeTo(base).path
        } catch (e: IllegalArgumentException) {
          // Different drive roots (e.g. SUBST alias X: vs the real C: path used for
          // Metro bundling) cannot be relativized. Fall back to the absolute path;
          // this project has no spaces in its paths so it is safe on Windows too.
          absolutePath
        }
      } else {
        absolutePath
      }`;
applyPatch(
  'Os.cliPath cross-drive fallback',
  path.join(pluginRoot, 'shared', 'src', 'main', 'kotlin', 'com', 'facebook', 'react', 'utils', 'Os.kt'),
  source => source.includes(cliPathOriginal),
  source => source.replace(cliPathOriginal, cliPathPatched),
);
