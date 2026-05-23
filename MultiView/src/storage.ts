import AsyncStorage from '@react-native-async-storage/async-storage';
import { DEFAULT_SETTINGS, STORAGE_KEYS } from './config';
import { Settings, Stream } from './types';

export async function loadStreams(): Promise<Stream[]> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEYS.streams);
    return raw ? (JSON.parse(raw) as Stream[]) : [];
  } catch {
    return [];
  }
}

export async function saveStreams(streams: Stream[]): Promise<void> {
  try {
    await AsyncStorage.setItem(STORAGE_KEYS.streams, JSON.stringify(streams));
  } catch (e) {
    console.warn('saveStreams failed', e);
  }
}

export async function loadSettings(): Promise<Settings> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEYS.settings);
    if (!raw) {
      return DEFAULT_SETTINGS;
    }
    const parsed = JSON.parse(raw);
    return {
      ...DEFAULT_SETTINGS,
      ...parsed,
      danmaku: { ...DEFAULT_SETTINGS.danmaku, ...(parsed.danmaku || {}) },
    };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export async function saveSettings(settings: Settings): Promise<void> {
  try {
    await AsyncStorage.setItem(STORAGE_KEYS.settings, JSON.stringify(settings));
  } catch (e) {
    console.warn('saveSettings failed', e);
  }
}
