import {NativeModules} from 'react-native';

// iOS Handoff.swift の HandoffQR / HandoffScannerController に対応する Android ネイティブ
// モジュール(HandoffQrModule.kt)の薄いラッパー。モジュール欠落時(旧バイナリ+新JSの
// Fast Refresh等)でも設定画面全体が壊れないよう、失敗は null で吸収する。
type HandoffQrModuleType = {
  encode(text: string, size: number): Promise<string>;
  scan(): Promise<string>;
};

const native: HandoffQrModuleType | undefined = NativeModules.HandoffQr;

export function isHandoffQrAvailable(): boolean {
  return !!native;
}

export async function encodeHandoffQrPngBase64(text: string, size = 512): Promise<string | null> {
  if (!native || !text) {
    return null;
  }
  try {
    return await native.encode(text, size);
  } catch {
    return null;
  }
}

// 戻り値 null はキャンセル/利用不可(呼び出し側は静かに無視してよい)。
export async function scanHandoffQr(): Promise<string | null> {
  if (!native) {
    return null;
  }
  try {
    return await native.scan();
  } catch {
    return null;
  }
}
