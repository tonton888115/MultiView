import React, {useCallback, useEffect, useRef, useState} from 'react';
import {Modal, Pressable, StyleSheet, Text, TextInput, TouchableOpacity, useWindowDimensions, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {WebView} from 'react-native-webview';
import {postStreamComment, type AuthCommit, type AuthState} from '../auth';
import {chatURL, desktopUserAgent, mobileUserAgent} from '../playback';
import {injectWebComment} from '../webInject';
import {appSafeAreaEdges, focusedPaneLayout} from '../layout';
import type {AppSettings, NiconicoCommentSender, StreamItem} from '../types';
import {platformInfo} from '../platforms';
import {useAutoHidingChrome} from '../useAutoHidingChrome';
import {VolumeOverlay} from '../components/VolumeOverlay';
import {ViewerCountBadge} from '../components/ViewerCountBadge';
import {sharedStyles} from '../components/sharedStyles';
import {StreamPlayer} from '../players/StreamPlayer';

export function FocusModal({
  stream,
  settings,
  streamCount,
  volume,
  muted,
  reloadKey,
  onReload,
  onVolume,
  onClose,
  onRemove,
  auth,
  onAuth,
}: {
  stream: StreamItem | null;
  settings: AppSettings;
  streamCount: number;
  volume: number;
  muted: boolean;
  reloadKey: number;
  onReload: () => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  onClose: () => void;
  onRemove: (id: string) => void;
  auth: AuthState;
  onAuth: AuthCommit;
}) {
  const {width: windowWidth, height: windowHeight} = useWindowDimensions();
  const paneLayout = focusedPaneLayout(windowWidth, windowHeight, settings.showChat);
  const useWideLayout = paneLayout === 'wide';
  const chatRef = useRef<WebView>(null);
  const niconicoCommentRef = useRef<NiconicoCommentSender | null>(null);
  const setNiconicoCommentBridge = useCallback((send: NiconicoCommentSender | null) => {
    niconicoCommentRef.current = send;
  }, []);
  const [commentText, setCommentText] = useState('');
  const [commentStatus, setCommentStatus] = useState('');
  const chat = stream ? chatURL(stream) : null;
  const showFocusChatColumn = paneLayout !== 'solo';
  const {chromeVisible, showChrome} = useAutoHidingChrome(stream?.id ?? 'closed');
  const [webViewerCount, setWebViewerCount] = useState<number | null>(null);

  useEffect(() => {
    setCommentText('');
    setWebViewerCount(null);
  }, [stream?.id]);

  const sendComment = useCallback(() => {
    const text = commentText.trim();
    if (!text || !stream) {
      return;
    }
    setCommentStatus('送信中');
    if (stream.platform === 'niconico') {
      const send = niconicoCommentRef.current;
      if (!send) {
        setCommentStatus('ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。');
        return;
      }
      send(text)
        .then(() => {
          setCommentText('');
          setCommentStatus('送信しました');
        })
        .catch(error => {
          setCommentStatus(error instanceof Error ? error.message : String(error));
        });
      return;
    }
    let operationBase = auth;
    const commitOperationAuth = async (nextAuth: AuthState) => {
      await onAuth(nextAuth, operationBase);
      operationBase = nextAuth;
    };
    postStreamComment(auth, stream, text, commitOperationAuth)
      .then(async nextAuth => {
        await commitOperationAuth(nextAuth);
        setCommentText('');
        setCommentStatus('送信しました');
      })
      .catch(error => {
        if (!chatRef.current) {
          setCommentStatus(error instanceof Error ? error.message : String(error));
          return;
        }
        injectWebComment(chatRef.current, text);
        setCommentStatus('Webチャット入力を試行しました（未確認）');
      });
  }, [auth, commentText, onAuth, stream]);

  const removeFocused = useCallback(() => {
    if (!stream) {
      return;
    }
    onRemove(stream.id);
    onClose();
  }, [onClose, onRemove, stream]);

  return (
    <Modal visible={!!stream} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={sharedStyles.modal} edges={appSafeAreaEdges}>
        {stream && (
          <View style={[styles.focusSurface, useWideLayout && styles.focusSurfaceWide]}>
            {showFocusChatColumn && (
              <View style={[styles.focusChatColumn, useWideLayout && styles.focusChatColumnWide]}>
                <View style={styles.focusChatPanel}>
                  {chat ? (
                    <WebView
                      ref={chatRef}
                      source={{uri: chat}}
                      userAgent={stream.platform === 'youtube' ? desktopUserAgent : mobileUserAgent}
                      javaScriptEnabled
                      domStorageEnabled
                      sharedCookiesEnabled
                      thirdPartyCookiesEnabled
                      setSupportMultipleWindows={false}
                      style={styles.focusChatWeb}
                    />
                  ) : (
                    <View style={styles.focusUnavailable}>
                      <Text style={styles.focusUnavailableText}>このサービスはチャット入力未対応です</Text>
                    </View>
                  )}
                </View>
                <View style={styles.focusComposer}>
                  <TextInput
                    value={commentText}
                    onChangeText={setCommentText}
                    autoCapitalize="none"
                    autoCorrect={false}
                    placeholder="コメント"
                    placeholderTextColor="rgba(255,255,255,0.55)"
                    style={styles.focusInput}
                    returnKeyType="send"
                    onSubmitEditing={sendComment}
                  />
                  <TouchableOpacity style={styles.focusSend} onPress={sendComment}>
                    <Text style={styles.focusSendText}>送信</Text>
                  </TouchableOpacity>
                  {!!commentStatus && <Text style={styles.focusStatus} numberOfLines={1}>{commentStatus}</Text>}
                </View>
              </View>
            )}
            <View
              style={[
                styles.focusPlayer,
                showFocusChatColumn ? styles.focusPlayerStacked : styles.focusPlayerSolo,
                showFocusChatColumn && useWideLayout && styles.focusPlayerWide,
              ]}
              onTouchStart={showChrome}>
              <StreamPlayer
                stream={stream}
                settings={settings}
                streamCount={streamCount}
                paused={false}
                muted={muted || volume <= 0}
                volume={volume}
                reloadKey={reloadKey}
                onNiconicoCommentBridge={setNiconicoCommentBridge}
                onViewerCount={setWebViewerCount}
              />
              <View style={sharedStyles.playerChrome} pointerEvents="box-none">
                {!chromeVisible && <Pressable style={sharedStyles.chromeRevealTouch} onPress={showChrome} />}
                {settings.showViewerCount && <ViewerCountBadge stream={stream} externalCount={webViewerCount} visible={chromeVisible} />}
                <View
                  style={[sharedStyles.autoHideChrome, !chromeVisible && sharedStyles.autoHideChromeHidden]}
                  pointerEvents={chromeVisible ? 'box-none' : 'none'}>
                  <TouchableOpacity style={[sharedStyles.overlayButton, styles.focusCloseButton]} onPress={onClose}>
                    <Text style={sharedStyles.overlayIcon}>‹</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={[sharedStyles.overlayButton, styles.focusReloadButton]} onPress={onReload}>
                    <Text style={sharedStyles.overlayIcon}>↻</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={[sharedStyles.overlayButton, styles.focusRemoveButton]} onPress={removeFocused}>
                    <Text style={sharedStyles.overlayIcon}>✕</Text>
                  </TouchableOpacity>
                  <VolumeOverlay
                    stream={stream}
                    volume={volume}
                    color={platformInfo(stream.platform).color}
                    onVolume={onVolume}
                    onInteract={showChrome}
                    mode="focus"
                  />
                </View>
              </View>
            </View>
          </View>
        )}
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  focusSurface: {
    flex: 1,
    paddingHorizontal: 10,
    paddingTop: 10,
    paddingBottom: 10,
    backgroundColor: '#000',
  },
  focusSurfaceWide: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  focusChatColumn: {
    flex: 1,
    minHeight: 0,
  },
  focusChatColumnWide: {
    height: '100%',
    marginRight: 10,
  },
  focusChatPanel: {
    flex: 1,
    minHeight: 100,
    borderRadius: 18,
    overflow: 'hidden',
    backgroundColor: '#090d12',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.1)',
  },
  focusChatWeb: {
    flex: 1,
    backgroundColor: '#000',
  },
  focusUnavailable: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 18,
  },
  focusUnavailableText: {
    color: '#9aa7b7',
    fontSize: 14,
    textAlign: 'center',
  },
  focusComposer: {
    height: 48,
    marginTop: 8,
    marginBottom: 8,
    flexDirection: 'row',
    alignItems: 'center',
  },
  focusStatus: {
    position: 'absolute',
    left: 12,
    right: 70,
    top: -22,
    color: '#dce6f3',
    fontSize: 11,
    fontWeight: '700',
  },
  focusInput: {
    flex: 1,
    height: 40,
    paddingHorizontal: 12,
    borderRadius: 14,
    backgroundColor: 'rgba(255,255,255,0.1)',
    color: '#fff',
    fontSize: 15,
  },
  focusSend: {
    width: 54,
    height: 40,
    marginLeft: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  focusSendText: {
    color: '#67a8ff',
    fontSize: 14,
    fontWeight: '800',
  },
  focusPlayer: {
    backgroundColor: '#000',
    position: 'relative',
  },
  focusPlayerStacked: {
    width: '100%',
    aspectRatio: 16 / 9,
  },
  focusPlayerSolo: {
    flex: 1,
    width: '100%',
    height: '100%',
  },
  focusPlayerWide: {
    width: '58%',
    maxHeight: '100%',
  },
  focusCloseButton: {
    position: 'absolute',
    top: 10,
    left: 10,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
  focusRemoveButton: {
    position: 'absolute',
    top: 10,
    right: 10,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
  focusReloadButton: {
    position: 'absolute',
    top: 10,
    right: 54,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
});
