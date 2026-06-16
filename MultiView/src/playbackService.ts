import {NativeModules} from 'react-native';

// 背景音声用前面サービスの開始/停止(Android)。配信が1本以上 & 音声ON の間だけ起動する。
const {PlaybackService} = NativeModules as {
  PlaybackService?: {start: () => void; stop: () => void};
};

export function startPlaybackService(): void {
  try {
    PlaybackService?.start();
  } catch {
    // サービス未対応環境では何もしない。
  }
}

export function stopPlaybackService(): void {
  try {
    PlaybackService?.stop();
  } catch {
    // no-op
  }
}
