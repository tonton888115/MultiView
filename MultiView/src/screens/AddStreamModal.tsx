import React, {useEffect, useMemo, useState} from 'react';
import {Modal, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {appSafeAreaEdges} from '../layout';
import type {AppSettings, PlatformId} from '../types';
import {orderedPlatforms, platformInfo} from '../platforms';
import {Pill} from '../components/Pill';
import {sharedStyles} from '../components/sharedStyles';

export function AddStreamModal({
  visible,
  settings,
  onClose,
  onAdd,
}: {
  visible: boolean;
  settings: AppSettings;
  onClose: () => void;
  onAdd: (platform: PlatformId, channel: string) => void;
}) {
  // order を毎レンダー再生成すると下の effect が毎回走るため useMemo で固定する。
  const order = useMemo(() => orderedPlatforms(settings.platformOrder), [settings.platformOrder]);
  const [platform, setPlatform] = useState<PlatformId>(order[0]);
  const [text, setText] = useState('');
  const info = platformInfo(platform);

  useEffect(() => {
    if (!order.includes(platform)) {
      setPlatform(order[0]);
    }
  }, [order, platform]);

  const submit = () => {
    const value = text.trim();
    if (!value) {
      return;
    }
    onAdd(platform, value);
    setText('');
    onClose();
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={sharedStyles.modal} edges={appSafeAreaEdges}>
        <View style={sharedStyles.modalHeader}>
          <Text style={sharedStyles.modalTitle}>配信を追加</Text>
          <TouchableOpacity onPress={onClose}>
            <Text style={sharedStyles.closeText}>閉じる</Text>
          </TouchableOpacity>
        </View>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={sharedStyles.sourceTabs}>
          {order.map(id => {
            const item = platformInfo(id);
            return (
              <Pill
                key={item.id}
                active={platform === item.id}
                color={item.color}
                label={item.label}
                onPress={() => setPlatform(item.id)}
              />
            );
          })}
        </ScrollView>
        <TextInput
          value={text}
          onChangeText={setText}
          autoCapitalize="none"
          autoCorrect={false}
          placeholder={info.hint}
          placeholderTextColor="#7d8794"
          style={styles.input}
        />
        <TouchableOpacity style={sharedStyles.fullButton} onPress={submit}>
          <Text style={sharedStyles.fullButtonText}>追加</Text>
        </TouchableOpacity>
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  input: {
    height: 48,
    marginHorizontal: 16,
    marginTop: 16,
    paddingHorizontal: 12,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    fontSize: 16,
  },
});
