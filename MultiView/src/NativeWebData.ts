import {NativeModules} from 'react-native';

// iOS の WebLoginCookies.clearAll / NiconicoSession.logout に対応する Android ネイティブ
// モジュール(WebDataModule.kt)の薄いラッパー。NativeHandoffQr と同じく、モジュール
// 欠落時(旧バイナリ+新JSの Fast Refresh 等)でも設定画面全体が壊れないよう、失敗は
// false で吸収し呼び出し側がアラートで案内できるようにする。
type WebDataModuleType = {
  clearWebData(): Promise<void>;
  clearCookiesForDomain(domain: string): Promise<void>;
};

const native: WebDataModuleType | undefined = NativeModules.WebData;

export function isWebDataAvailable(): boolean {
  return !!native;
}

// 全ドメインの WebView Cookie / Web ストレージを削除する。成功で true。
export async function clearAllWebData(): Promise<boolean> {
  if (!native) {
    return false;
  }
  try {
    await native.clearWebData();
    return true;
  } catch {
    return false;
  }
}

// 指定ドメイン(例: 'nicovideo.jp')の Cookie だけを失効させる。成功で true。
export async function clearCookiesForDomain(domain: string): Promise<boolean> {
  if (!native || !domain) {
    return false;
  }
  try {
    await native.clearCookiesForDomain(domain);
    return true;
  } catch {
    return false;
  }
}
