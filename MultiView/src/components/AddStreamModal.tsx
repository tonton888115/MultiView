import React, { useState } from 'react';
import {
  KeyboardAvoidingView,
  Modal,
  Platform as RNPlatform,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  TouchableWithoutFeedback,
  View,
} from 'react-native';
import { COMFORTABLE_STREAM_COUNT, PLATFORMS, platformInfo } from '../config';
import { Platform } from '../types';

interface Props {
  visible: boolean;
  currentCount: number;
  onClose: () => void;
  onAdd: (platform: Platform, channel: string) => void;
}

export default function AddStreamModal({ visible, currentCount, onClose, onAdd }: Props) {
  const [platform, setPlatform] = useState<Platform>('kick');
  const [channel, setChannel] = useState('');
  const info = platformInfo(platform);
  const canAdd = channel.trim().length > 0;

  function submit() {
    if (!canAdd) {
      return;
    }
    onAdd(platform, channel.trim());
    setChannel('');
  }

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <TouchableWithoutFeedback onPress={onClose}>
        <View style={styles.backdrop}>
          <TouchableWithoutFeedback>
            <KeyboardAvoidingView
              behavior={RNPlatform.OS === 'ios' ? 'padding' : undefined}
              style={styles.sheet}>
              <Text style={styles.title}>配信を追加</Text>

              <View style={styles.platformRow}>
                {PLATFORMS.map(p => {
                  const active = p.id === platform;
                  return (
                    <TouchableOpacity
                      key={p.id}
                      style={[
                        styles.platformBtn,
                        active && { backgroundColor: p.color, borderColor: p.color },
                      ]}
                      onPress={() => setPlatform(p.id)}>
                      <Text style={[styles.platformText, active && styles.platformTextActive]}>
                        {p.label}
                      </Text>
                    </TouchableOpacity>
                  );
                })}
              </View>

              <TextInput
                style={styles.input}
                placeholder={info.hint}
                placeholderTextColor="#777"
                autoCapitalize="none"
                autoCorrect={false}
                value={channel}
                onChangeText={setChannel}
                onSubmitEditing={submit}
                returnKeyType="done"
              />

              {currentCount >= COMFORTABLE_STREAM_COUNT && (
                <Text style={styles.warn}>
                  同時視聴は{COMFORTABLE_STREAM_COUNT}画面程度までが快適です
                </Text>
              )}

              <View style={styles.actions}>
                <TouchableOpacity style={styles.cancelBtn} onPress={onClose}>
                  <Text style={styles.cancelText}>キャンセル</Text>
                </TouchableOpacity>
                <TouchableOpacity
                  style={[styles.addBtn, !canAdd && styles.addBtnDisabled]}
                  disabled={!canAdd}
                  onPress={submit}>
                  <Text style={styles.addText}>追加</Text>
                </TouchableOpacity>
              </View>
            </KeyboardAvoidingView>
          </TouchableWithoutFeedback>
        </View>
      </TouchableWithoutFeedback>
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
  sheet: {
    backgroundColor: '#1c1c1e',
    borderRadius: 14,
    padding: 18,
  },
  title: { color: '#fff', fontSize: 17, fontWeight: '700', marginBottom: 14 },
  platformRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 14 },
  platformBtn: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#444',
  },
  platformText: { color: '#ccc', fontSize: 13, fontWeight: '600' },
  platformTextActive: { color: '#000' },
  input: {
    backgroundColor: '#2c2c2e',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: '#fff',
    fontSize: 15,
  },
  warn: { color: '#ffb340', fontSize: 12, marginTop: 10 },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 10, marginTop: 18 },
  cancelBtn: { paddingHorizontal: 16, paddingVertical: 10 },
  cancelText: { color: '#aaa', fontSize: 15 },
  addBtn: {
    paddingHorizontal: 20,
    paddingVertical: 10,
    backgroundColor: '#0a84ff',
    borderRadius: 8,
  },
  addBtnDisabled: { backgroundColor: '#3a3a3c' },
  addText: { color: '#fff', fontSize: 15, fontWeight: '600' },
});
