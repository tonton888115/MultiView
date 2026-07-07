import React, {useEffect, useMemo, useState} from 'react';
import {Alert, Image, Modal, ScrollView, Share, StyleSheet, Text, TextInput, TouchableOpacity, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {compactHandoffCode, decodeHandoff, handoffURL} from '../handoff';
import {encodeHandoffQrPngBase64, isHandoffQrAvailable, scanHandoffQr} from '../NativeHandoffQr';
import {makeStream} from '../playback';
import {appSafeAreaEdges} from '../layout';
import type {AppSettings, HandoffImporter, StreamItem} from '../types';
import {sharedStyles} from '../components/sharedStyles';

export function HandoffModal({
  visible,
  streams,
  settings,
  onClose,
  onImport,
}: {
  visible: boolean;
  streams: StreamItem[];
  settings: AppSettings;
  onClose: () => void;
  onImport: HandoffImporter;
}) {
  const [mode, setMode] = useState<'send' | 'receive'>('send');
  const [handoff, setHandoff] = useState('');
  const [handoffQrPng, setHandoffQrPng] = useState<string | null>(null);
  const compactCode = useMemo(() => compactHandoffCode(streams, settings.layoutMode), [settings.layoutMode, streams]);
  // QRの中身はURL形式にする。iOSのHandoffPayload.decodeはURL形式も受理し、
  // OS標準カメラで読んだ場合もディープリンクとしてこのアプリが開く(最大互換)。
  const handoffUrl = useMemo(() => handoffURL(streams, settings.layoutMode), [settings.layoutMode, streams]);
  const exportText = useMemo(
    () =>
      JSON.stringify(
        {
          version: 2,
          streams,
          settings,
          compactCode,
          url: handoffUrl,
        },
        null,
        2,
      ),
    [compactCode, handoffUrl, settings, streams],
  );

  useEffect(() => {
    if (visible) {
      setMode('send');
    }
  }, [visible]);

  useEffect(() => {
    let cancelled = false;
    if (!visible || !streams.length) {
      setHandoffQrPng(null);
      return;
    }
    encodeHandoffQrPngBase64(handoffUrl, 512).then(png => {
      if (!cancelled) {
        setHandoffQrPng(png);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [handoffUrl, streams.length, visible]);

  // iOS HandoffController.handleReceived と同じ受け取りフロー:
  // 解読 → タブ数を提示 → 置き換える(設定も反映) / 追加する(タブのみ) / キャンセル。
  const receiveHandoff = (raw: string): boolean => {
    let decoded: ReturnType<typeof decodeHandoff>;
    try {
      decoded = decodeHandoff(raw);
    } catch {
      Alert.alert('受け取れませんでした', 'コード/QRを認識できませんでした。JSON、iOS引き継ぎコード、multiview:// URL のいずれかを確認してください。');
      return false;
    }
    const nextStreams = decoded.streams.map(stream => makeStream(stream.platform, stream.channel));
    if (!nextStreams.length) {
      Alert.alert('タブが空です', '受け取れる視聴タブがありませんでした。');
      return false;
    }
    Alert.alert(`${nextStreams.length} タブを受け取りました`, 'この端末の視聴タブをどうしますか?', [
      {
        text: '置き換える',
        style: 'destructive',
        onPress: () => {
          onImport(nextStreams, decoded.settings, 'replace');
          setHandoff('');
          onClose();
        },
      },
      {
        text: '追加する',
        onPress: () => {
          onImport(nextStreams, {}, 'append');
          setHandoff('');
          onClose();
        },
      },
      {text: 'キャンセル', style: 'cancel'},
    ]);
    return true;
  };

  const importPayload = () => {
    receiveHandoff(handoff);
  };

  const scanHandoff = async () => {
    const scanned = await scanHandoffQr();
    if (scanned) {
      receiveHandoff(scanned);
    }
  };

  const shareHandoff = async () => {
    try {
      await Share.share({message: handoffUrl});
    } catch {
      // 共有シートのキャンセルは無視する。
    }
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={sharedStyles.modal} edges={appSafeAreaEdges}>
        <View style={sharedStyles.modalHeader}>
          <Text style={sharedStyles.modalTitle}>引き継ぎ</Text>
          <TouchableOpacity onPress={onClose}>
            <Text style={sharedStyles.closeText}>閉じる</Text>
          </TouchableOpacity>
        </View>
        <View style={styles.handoffModeTabs}>
          <TouchableOpacity
            style={[styles.handoffModeButton, mode === 'send' && styles.handoffModeButtonActive]}
            onPress={() => setMode('send')}>
            <Text style={[styles.handoffModeText, mode === 'send' && styles.handoffModeTextActive]}>送る</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.handoffModeButton, mode === 'receive' && styles.handoffModeButtonActive]}
            onPress={() => setMode('receive')}>
            <Text style={[styles.handoffModeText, mode === 'receive' && styles.handoffModeTextActive]}>受け取る</Text>
          </TouchableOpacity>
        </View>
        {mode === 'send' ? (
          <ScrollView style={styles.handoffBody} contentContainerStyle={styles.handoffContent}>
            {streams.length > 0 && handoffQrPng ? (
              <>
                <Text style={sharedStyles.settingNote}>
                  この端末で開いている {streams.length} タブのQRです。もう一方の端末で「受け取る」から読み取ってください。
                </Text>
                <Image
                  source={{uri: `data:image/png;base64,${handoffQrPng}`}}
                  style={styles.handoffQr}
                  resizeMode="contain"
                />
                <TouchableOpacity style={sharedStyles.fullButton} onPress={shareHandoff}>
                  <Text style={sharedStyles.fullButtonText}>共有 / コピー</Text>
                </TouchableOpacity>
                <Text style={sharedStyles.settingNote}>iOS互換の短いコードとURLも含めて出力します。</Text>
                <TextInput value={exportText} editable={false} multiline style={[styles.textArea, styles.readOnly]} />
              </>
            ) : (
              <Text style={sharedStyles.settingNote}>開いているタブがありません。</Text>
            )}
          </ScrollView>
        ) : (
          <ScrollView style={styles.handoffBody} contentContainerStyle={styles.handoffContent}>
            <Text style={sharedStyles.settingNote}>もう一方の端末の「送る」QRを読み取るか、コピーしたコードを貼り付けて受け取ります。</Text>
            {isHandoffQrAvailable() && (
              <TouchableOpacity style={sharedStyles.fullButton} onPress={scanHandoff}>
                <Text style={sharedStyles.fullButtonText}>QRをスキャン</Text>
              </TouchableOpacity>
            )}
            <TextInput
              value={handoff}
              onChangeText={setHandoff}
              multiline
              placeholder="ここに引き継ぎJSON / コード / URLを貼り付け"
              placeholderTextColor="#7d8794"
              style={styles.textArea}
            />
            <TouchableOpacity style={sharedStyles.fullButton} onPress={importPayload}>
              <Text style={sharedStyles.fullButtonText}>引き継ぎデータを読み込む</Text>
            </TouchableOpacity>
          </ScrollView>
        )}
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  handoffModeTabs: {
    height: 46,
    marginHorizontal: 16,
    marginTop: 14,
    padding: 3,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    flexDirection: 'row',
  },
  handoffModeButton: {
    flex: 1,
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  handoffModeButtonActive: {
    backgroundColor: '#2f8cff',
  },
  handoffModeText: {
    color: '#9aa7b7',
    fontSize: 14,
    fontWeight: '800',
  },
  handoffModeTextActive: {
    color: '#fff',
  },
  handoffBody: {
    flex: 1,
  },
  handoffContent: {
    paddingTop: 16,
    paddingBottom: 24,
  },
  textArea: {
    minHeight: 110,
    marginTop: 10,
    padding: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    textAlignVertical: 'top',
    fontSize: 12,
  },
  readOnly: {
    color: '#a9b5c6',
  },
  handoffQr: {
    width: 240,
    height: 240,
    alignSelf: 'center',
    marginTop: 12,
    borderRadius: 12,
    backgroundColor: '#ffffff',
  },
});
