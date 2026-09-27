import {NativeModules} from 'react-native';

// ビューモード用の没入表示(ステータスバー/ナビゲーションバーを隠す)。Android のみ。
const {SystemUi} = NativeModules as {
  SystemUi?: {setImmersive: (enabled: boolean) => void};
};

export function setImmersiveMode(enabled: boolean): void {
  try {
    SystemUi?.setImmersive(enabled);
  } catch {
    // モジュール未搭載のビルドではバーを隠さないだけにする。
  }
}
