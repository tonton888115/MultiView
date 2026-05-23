import React, { useState } from 'react';
import {
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { DanmakuSettings, Settings } from '../types';

interface Props {
  settings: Settings;
  onChange: (next: Settings) => void;
}

function Stepper({
  label,
  value,
  min,
  max,
  step,
  display,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  display?: (v: number) => string;
  onChange: (v: number) => void;
}) {
  const clamp = (v: number) => Math.min(max, Math.max(min, Math.round(v * 1000) / 1000));
  return (
    <View style={styles.row}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.stepper}>
        <TouchableOpacity style={styles.stepBtn} onPress={() => onChange(clamp(value - step))}>
          <Text style={styles.stepText}>−</Text>
        </TouchableOpacity>
        <Text style={styles.value}>{display ? display(value) : String(value)}</Text>
        <TouchableOpacity style={styles.stepBtn} onPress={() => onChange(clamp(value + step))}>
          <Text style={styles.stepText}>＋</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

export default function SettingsTab({ settings, onChange }: Props) {
  const [ngWords, setNgWords] = useState(settings.danmaku.ngWords.join('\n'));
  const [ngUsers, setNgUsers] = useState(settings.danmaku.ngUsers.join('\n'));
  const [proxy, setProxy] = useState(settings.proxyUrl);

  const setDanmaku = (patch: Partial<DanmakuSettings>) =>
    onChange({ ...settings, danmaku: { ...settings.danmaku, ...patch } });

  const parseList = (t: string) =>
    t.split(/[\n,]/).map(s => s.trim()).filter(Boolean);

  const d = settings.danmaku;

  return (
    <ScrollView style={styles.root} contentContainerStyle={styles.content}>
      <Text style={styles.h}>弾幕</Text>

      <View style={styles.row}>
        <Text style={styles.label}>弾幕を表示</Text>
        <Switch value={settings.showChat} onValueChange={v => onChange({ ...settings, showChat: v })} />
      </View>
      <Stepper label="文字サイズ" value={d.fontSize} min={12} max={40} step={2}
        display={v => `${v}px`} onChange={v => setDanmaku({ fontSize: v })} />
      <Stepper label="速度" value={d.speed} min={0.05} max={0.3} step={0.01}
        display={v => `${Math.round((v / 0.13) * 100)}%`} onChange={v => setDanmaku({ speed: v })} />
      <Stepper label="不透明度" value={d.opacity} min={0.3} max={1} step={0.1}
        display={v => `${Math.round(v * 100)}%`} onChange={v => setDanmaku({ opacity: v })} />
      <Stepper label="最大行数" value={d.maxLines} min={0} max={20} step={1}
        display={v => (v === 0 ? '自動' : String(v))} onChange={v => setDanmaku({ maxLines: v })} />
      <Stepper label="最大文字数" value={d.maxLength} min={0} max={200} step={10}
        display={v => (v === 0 ? '無制限' : String(v))} onChange={v => setDanmaku({ maxLength: v })} />

      <Text style={[styles.h, styles.gap]}>NGフィルタ</Text>
      <Text style={styles.sub}>NGワード (改行/カンマ区切り)</Text>
      <TextInput
        style={styles.area}
        multiline
        placeholder="例: 宣伝, スパム"
        placeholderTextColor="#777"
        autoCapitalize="none"
        value={ngWords}
        onChangeText={t => {
          setNgWords(t);
          setDanmaku({ ngWords: parseList(t) });
        }}
      />
      <Text style={styles.sub}>NGユーザー (改行/カンマ区切り)</Text>
      <TextInput
        style={styles.area}
        multiline
        placeholder="ユーザー名"
        placeholderTextColor="#777"
        autoCapitalize="none"
        value={ngUsers}
        onChangeText={t => {
          setNgUsers(t);
          setDanmaku({ ngUsers: parseList(t) });
        }}
      />

      <Text style={[styles.h, styles.gap]}>コメント取得</Text>
      <Text style={styles.sub}>CORSプロキシ (任意 / Kick・ツイキャス用)</Text>
      <TextInput
        style={styles.input}
        placeholder="https://xxx.workers.dev/?url="
        placeholderTextColor="#777"
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="url"
        value={proxy}
        onChangeText={t => {
          setProxy(t);
          onChange({ ...settings, proxyUrl: t.trim() });
        }}
      />
      <Text style={styles.note}>
        弾幕の取得・送信の詳細は配信サービスごとに異なります。Twitchは弾幕がそのまま動き、
        Kick / ツイキャスはプロキシ設定でコメント取得が安定します。
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#111' },
  content: { padding: 16, paddingBottom: 40 },
  h: { color: '#fff', fontSize: 16, fontWeight: '800', marginBottom: 8 },
  gap: { marginTop: 24 },
  sub: { color: '#bbb', fontSize: 13, marginTop: 12, marginBottom: 6 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 8,
  },
  label: { color: '#ddd', fontSize: 14 },
  stepper: { flexDirection: 'row', alignItems: 'center' },
  stepBtn: {
    width: 36,
    height: 32,
    backgroundColor: '#2c2c2e',
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepText: { color: '#fff', fontSize: 18 },
  value: { color: '#fff', fontSize: 14, minWidth: 64, textAlign: 'center' },
  input: {
    backgroundColor: '#2c2c2e',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: '#fff',
    fontSize: 15,
  },
  area: {
    backgroundColor: '#2c2c2e',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: '#fff',
    fontSize: 14,
    minHeight: 64,
    textAlignVertical: 'top',
  },
  note: { color: '#888', fontSize: 12, marginTop: 14, lineHeight: 18 },
});
