import React, { useEffect, useState } from 'react';
import {
  Modal,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { Settings } from '../types';

interface Props {
  visible: boolean;
  settings: Settings;
  onClose: () => void;
  onSave: (settings: Settings) => void;
}

export default function SettingsModal({ visible, settings, onClose, onSave }: Props) {
  const [baseUrl, setBaseUrl] = useState(settings.baseUrl);
  const [showChat, setShowChat] = useState(settings.showChat);
  const [proxyUrl, setProxyUrl] = useState(settings.proxyUrl);

  useEffect(() => {
    if (visible) {
      setBaseUrl(settings.baseUrl);
      setShowChat(settings.showChat);
      setProxyUrl(settings.proxyUrl);
    }
  }, [visible, settings]);

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <View style={styles.sheet}>
          <Text style={styles.title}>設定</Text>

          <Text style={styles.label}>GitHub Pages のベースURL</Text>
          <TextInput
            style={styles.input}
            placeholder="https://ユーザー名.github.io/MultiView"
            placeholderTextColor="#777"
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            value={baseUrl}
            onChangeText={setBaseUrl}
          />
          <Text style={styles.help}>
            player.html を置いた GitHub Pages の URL です。末尾の /player.html は不要。
          </Text>

          <View style={styles.switchRow}>
            <Text style={styles.label}>コメント弾幕を表示</Text>
            <Switch value={showChat} onValueChange={setShowChat} />
          </View>

          <Text style={[styles.label, styles.topGap]}>CORSプロキシ (任意)</Text>
          <TextInput
            style={styles.input}
            placeholder="https://xxx.workers.dev/?url="
            placeholderTextColor="#777"
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            value={proxyUrl}
            onChangeText={setProxyUrl}
          />
          <Text style={styles.help}>
            Kick / ツイキャスのコメント取得に使う中継。未設定でもTwitchの弾幕は動きます。
          </Text>

          <View style={styles.actions}>
            <TouchableOpacity style={styles.cancelBtn} onPress={onClose}>
              <Text style={styles.cancelText}>キャンセル</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={styles.saveBtn}
              onPress={() =>
                onSave({ baseUrl: baseUrl.trim(), showChat, proxyUrl: proxyUrl.trim() })
              }>
              <Text style={styles.saveText}>保存</Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.6)',
    justifyContent: 'center',
    padding: 24,
  },
  sheet: { backgroundColor: '#1c1c1e', borderRadius: 14, padding: 18 },
  title: { color: '#fff', fontSize: 17, fontWeight: '700', marginBottom: 16 },
  label: { color: '#ddd', fontSize: 14, marginBottom: 8 },
  topGap: { marginTop: 22 },
  input: {
    backgroundColor: '#2c2c2e',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: '#fff',
    fontSize: 15,
  },
  help: { color: '#888', fontSize: 12, marginTop: 8 },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 22,
  },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 10, marginTop: 24 },
  cancelBtn: { paddingHorizontal: 16, paddingVertical: 10 },
  cancelText: { color: '#aaa', fontSize: 15 },
  saveBtn: {
    paddingHorizontal: 20,
    paddingVertical: 10,
    backgroundColor: '#0a84ff',
    borderRadius: 8,
  },
  saveText: { color: '#fff', fontSize: 15, fontWeight: '600' },
});
