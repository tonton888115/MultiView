import React, {useCallback} from 'react';
import {Alert, Modal, ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {WebView} from 'react-native-webview';
import {
  authStatus,
  hasUsableAuthSession,
  serviceLabel,
  signOut,
  updateAuthConfig,
  type AuthCommit,
  type AuthState,
  type OAuthService,
  type PendingDeviceOAuth,
} from '../auth';
import {clearAllWebData, clearCookiesForDomain} from '../NativeWebData';
import {mobileUserAgent} from '../playback';
import {appSafeAreaEdges} from '../layout';
import type {AppSettings} from '../types';
import {orderedPlatforms, platformInfo} from '../platforms';
import {LayoutModeSettingRow, NumberSettingRow, QualityRow, SettingSwitch} from '../components/settingsRows';
import {sharedStyles} from '../components/sharedStyles';

export function SettingsScreen({
  settings,
  onSettings,
  onMovePlatform,
  onClear,
  auth,
  onAuth,
  onLogin,
  pendingDeviceOAuth,
  onResumeDeviceOAuth,
  onCancelDeviceOAuth,
  onNiconicoLogin,
}: {
  settings: AppSettings;
  onSettings: (patch: Partial<AppSettings>) => void;
  onMovePlatform: (index: number, delta: number) => void;
  onClear: () => void;
  auth: AuthState;
  onAuth: AuthCommit;
  onLogin: (service: OAuthService) => void;
  pendingDeviceOAuth: PendingDeviceOAuth | null;
  onResumeDeviceOAuth: (pending: PendingDeviceOAuth) => void;
  onCancelDeviceOAuth: () => void;
  onNiconicoLogin: () => void;
}) {
  const order = orderedPlatforms(settings.platformOrder);

  // iOS Screens.swift confirmClearWebData と同じ確認→削除→完了通知のフロー。
  // OAuth 連携(AsyncStorage 保存)は消さない — WebView 側の Cookie/閲覧データのみ。
  const confirmClearWebData = useCallback(() => {
    Alert.alert(
      'Webログイン情報と履歴を削除',
      'Kick、ニコ生、YouTube、Twitch、ツイキャスのWebView Cookie・閲覧データを削除します。OAuth連携のログイン状態は残します。',
      [
        {text: 'キャンセル', style: 'cancel'},
        {
          text: '削除',
          style: 'destructive',
          onPress: () => {
            void clearAllWebData().then(ok => {
              Alert.alert(
                ok ? '削除しました' : '削除できませんでした',
                ok
                  ? 'WebViewのCookieと閲覧データを削除しました。'
                  : 'ネイティブモジュールを利用できません。アプリを最新バイナリへ更新してください。',
              );
            });
          },
        },
      ],
    );
  }, []);

  // iOS Screens.swift handleNiconicoRow のログアウトに対応。Android はニコ生の
  // ログイン状態を state 管理していない(Cookie が唯一の実体)ため、削除完了の通知のみ。
  const confirmNiconicoLogout = useCallback(() => {
    Alert.alert('ニコ生からログアウト', '保存されたログイン情報(Cookie)を削除します。', [
      {text: 'キャンセル', style: 'cancel'},
      {
        text: 'ログアウト',
        style: 'destructive',
        onPress: () => {
          void clearCookiesForDomain('nicovideo.jp').then(ok => {
            Alert.alert(
              ok ? 'ログアウトしました' : 'ログアウトできませんでした',
              ok
                ? 'ニコ生のログインCookieを削除しました。プレイヤーは次回読み込みから未ログイン状態になります。'
                : 'ネイティブモジュールを利用できません。アプリを最新バイナリへ更新してください。',
            );
          });
        },
      },
    ]);
  }, []);

  return (
    <ScrollView style={styles.settings} contentContainerStyle={styles.settingsContent}>
      <Text style={styles.sectionTitle}>再生</Text>
      <SettingSwitch title="音声を有効にして開始" value={settings.playAudio} onValueChange={value => onSettings({playAudio: value})} />
      <SettingSwitch title="拡大時にチャットを表示" value={settings.showChat} onValueChange={value => onSettings({showChat: value})} />
      <SettingSwitch title="同接数を左下に表示" value={settings.showViewerCount} onValueChange={value => onSettings({showViewerCount: value})} />
      <SettingSwitch title="レイド先を自動追加" value={settings.autoFollowRaids} onValueChange={value => onSettings({autoFollowRaids: value})} />
      <SettingSwitch title="YouTubeをiframe優先で再生" value={settings.youtubePreferIframe} onValueChange={value => onSettings({youtubePreferIframe: value})} />
      <SettingSwitch title="YouTubeライブを安定バッファで再生" value={settings.youtubeStableBuffer} onValueChange={value => onSettings({youtubeStableBuffer: value})} />

      <Text style={styles.sectionTitle}>表示</Text>
      <LayoutModeSettingRow value={settings.layoutMode} onChange={value => onSettings({layoutMode: value})} />

      <Text style={styles.sectionTitle}>画質</Text>
      <QualityRow title="Wi-Fi時の画質" value={settings.wifiQuality} onChange={value => onSettings({wifiQuality: value})} />
      <QualityRow title="モバイル通信時の画質" value={settings.mobileQuality} onChange={value => onSettings({mobileQuality: value})} />
      <SettingSwitch
        title="3本以上で自動エコノミー画質"
        value={settings.autoEconomyOnManyStreams}
        onValueChange={value => onSettings({autoEconomyOnManyStreams: value})}
      />
      <SettingSwitch
        title="ニコ生 低遅延"
        value={settings.niconicoLowLatency}
        onValueChange={value => onSettings({niconicoLowLatency: value})}
      />

      <Text style={styles.sectionTitle}>弾幕・通知</Text>
      <SettingSwitch title="弾幕を表示" value={settings.showDanmaku} onValueChange={value => onSettings({showDanmaku: value})} />
      <SettingSwitch title="スタンプ/絵文字を弾幕に表示" value={settings.showEmotes} onValueChange={value => onSettings({showEmotes: value})} />
      <NumberSettingRow
        title="文字サイズ"
        value={settings.danmakuFontSize}
        min={12}
        max={40}
        step={1}
        onChange={value => onSettings({danmakuFontSize: Math.round(value)})}
      />
      <NumberSettingRow
        title="速度"
        value={Math.round((settings.danmakuSpeed / 0.13) * 100)}
        min={20}
        max={300}
        step={10}
        formatValue={value => `${Math.round(value)}%`}
        onChange={value => onSettings({danmakuSpeed: (Math.round(value) / 100) * 0.13})}
      />
      <NumberSettingRow
        title="透過度"
        value={Math.round(settings.danmakuOpacity * 100)}
        min={30}
        max={100}
        step={5}
        formatValue={value => `${Math.round(value)}%`}
        onChange={value => onSettings({danmakuOpacity: Math.round(value) / 100})}
      />
      <NumberSettingRow
        title="最大行数"
        value={settings.danmakuMaxLines}
        min={0}
        max={20}
        step={1}
        formatValue={value => (value === 0 ? '自動' : String(Math.round(value)))}
        onChange={value => onSettings({danmakuMaxLines: Math.round(value)})}
      />
      <NumberSettingRow
        title="最大文字数"
        value={settings.danmakuMaxLength}
        min={0}
        max={500}
        step={25}
        formatValue={value => (value === 0 ? '無制限' : String(Math.round(value)))}
        onChange={value => onSettings({danmakuMaxLength: Math.round(value)})}
      />
      <SettingSwitch title="ギフト演出を表示" value={settings.showGiftEffects} onValueChange={value => onSettings({showGiftEffects: value, niconicoShowGift: value})} />
      <SettingSwitch title="ギフト通知音" value={settings.giftSoundEnabled} onValueChange={value => onSettings({giftSoundEnabled: value})} />
      <SettingSwitch title="ニコ生 ニコニ広告を表示" value={settings.niconicoShowNicoad} onValueChange={value => onSettings({niconicoShowNicoad: value})} />
      <SettingSwitch title="ニコ生 お知らせ通知を表示" value={settings.niconicoShowNotification} onValueChange={value => onSettings({niconicoShowNotification: value})} />

      <Text style={styles.sectionTitle}>サービス順</Text>
      {order.map((platform, index) => {
        const item = platformInfo(platform);
        return (
          <View key={platform} style={styles.orderRow}>
            <View style={[styles.platformDot, {backgroundColor: item.color}]} />
            <Text style={styles.orderLabel}>{item.label}</Text>
            <TouchableOpacity disabled={index === 0} style={[styles.smallButton, index === 0 && styles.disabled]} onPress={() => onMovePlatform(index, -1)}>
              <Text style={styles.smallButtonText}>上へ</Text>
            </TouchableOpacity>
            <TouchableOpacity disabled={index === order.length - 1} style={[styles.smallButton, index === order.length - 1 && styles.disabled]} onPress={() => onMovePlatform(index, 1)}>
              <Text style={styles.smallButtonText}>下へ</Text>
            </TouchableOpacity>
          </View>
        );
      })}

      <Text style={styles.sectionTitle}>Web</Text>
      <SettingSwitch title="Web広告ブロック" value={settings.blockWebAds} onValueChange={value => onSettings({blockWebAds: value})} />
      <TouchableOpacity style={sharedStyles.settingRow} onPress={confirmClearWebData}>
        <Text style={styles.dangerRowText}>Webログイン情報と履歴を削除</Text>
      </TouchableOpacity>

      <Text style={styles.sectionTitle}>認証・コメント送信</Text>
      <AuthServicePanel service="kick" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel
        service="twitch"
        auth={auth}
        onAuth={onAuth}
        onLogin={onLogin}
        pendingDeviceOAuth={pendingDeviceOAuth?.service === 'twitch' ? pendingDeviceOAuth : null}
        onResumeDeviceOAuth={onResumeDeviceOAuth}
        onCancelDeviceOAuth={onCancelDeviceOAuth}
      />
      <AuthServicePanel service="twitcasting" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel
        service="youtube"
        auth={auth}
        onAuth={onAuth}
        onLogin={onLogin}
        pendingDeviceOAuth={pendingDeviceOAuth?.service === 'youtube' ? pendingDeviceOAuth : null}
        onResumeDeviceOAuth={onResumeDeviceOAuth}
        onCancelDeviceOAuth={onCancelDeviceOAuth}
      />
      <NiconicoLoginPanel onLogin={onNiconicoLogin} onLogout={confirmNiconicoLogout} />

      <TouchableOpacity
        style={styles.clearButton}
        onPress={() => {
          Alert.alert('配信リストを削除', '保存済みの配信リストを空にします。', [
            {text: 'キャンセル', style: 'cancel'},
            {text: '削除', style: 'destructive', onPress: onClear},
          ]);
        }}>
        <Text style={styles.clearButtonText}>配信リストを空にする</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

function AuthServicePanel({
  service,
  auth,
  onAuth,
  onLogin,
  pendingDeviceOAuth = null,
  onResumeDeviceOAuth,
  onCancelDeviceOAuth,
}: {
  service: OAuthService;
  auth: AuthState;
  onAuth: AuthCommit;
  onLogin: (service: OAuthService) => void;
  pendingDeviceOAuth?: PendingDeviceOAuth | null;
  onResumeDeviceOAuth?: (pending: PendingDeviceOAuth) => void;
  onCancelDeviceOAuth?: () => void;
}) {
  const state = auth[service];
  const label = serviceLabel(service);
  const sessionUsable = hasUsableAuthSession(auth, service);
  const setConfig = (patch: Partial<typeof state.config>) => {
    void onAuth(updateAuthConfig(auth, service, patch), auth, [service]).catch(() => undefined);
  };
  const logout = () => {
    void onAuth(signOut(auth, service), auth, [service]).catch(() => undefined);
  };
  const redirectHelp = service === 'youtube'
    ? 'YouTubeは外部ブラウザのDevice Code認証を使います。Client IDはDevice/TVまたはInstalled app向けを使ってください。'
    : service === 'twitch'
      ? 'Twitchは外部ブラウザのDevice Code認証を使い、access tokenを自動更新します。開発者ポータルでPublicクライアントを使ってください。'
      : 'Redirect URIは開発者ポータルに登録した値と完全一致させてください。';
  return (
    <View style={styles.authPanel}>
      <View style={styles.authHeader}>
        <View>
          <Text style={styles.authTitle}>{label}</Text>
          <Text style={styles.authStatus}>{authStatus(auth, service)}</Text>
        </View>
        <TouchableOpacity
          style={[styles.smallButton, (sessionUsable || pendingDeviceOAuth) && styles.dangerButton]}
          onPress={() => (pendingDeviceOAuth ? onCancelDeviceOAuth?.() : sessionUsable ? logout() : onLogin(service))}>
          <Text style={styles.smallButtonText}>
            {pendingDeviceOAuth ? '認証キャンセル' : sessionUsable ? 'ログアウト' : state.token ? '再ログイン' : 'ログイン'}
          </Text>
        </TouchableOpacity>
      </View>
      {pendingDeviceOAuth && (
        <View style={styles.pendingAuthCard}>
          <Text style={styles.pendingAuthLabel}>外部ブラウザで次のコードを入力してください</Text>
          <Text selectable style={styles.pendingAuthCode}>{pendingDeviceOAuth.userCode}</Text>
          <Text selectable style={styles.pendingAuthURL}>{pendingDeviceOAuth.verificationUrl}</Text>
          <TouchableOpacity
            style={styles.pendingAuthButton}
            onPress={() => onResumeDeviceOAuth?.(pendingDeviceOAuth)}>
            <Text style={styles.smallButtonText}>ブラウザをもう一度開く</Text>
          </TouchableOpacity>
        </View>
      )}
      <TextInput
        value={state.config.clientId}
        onChangeText={value => setConfig({clientId: value})}
        autoCapitalize="none"
        autoCorrect={false}
        placeholder={`${label} Client ID`}
        placeholderTextColor="#7d8794"
        style={styles.authInput}
      />
      {service === 'kick' && (
        <TextInput
          value={state.config.clientSecret ?? ''}
          onChangeText={value => setConfig({clientSecret: value})}
          autoCapitalize="none"
          autoCorrect={false}
          secureTextEntry
          placeholder="Kick Client Secret (任意)"
          placeholderTextColor="#7d8794"
          style={styles.authInput}
        />
      )}
      {service !== 'youtube' && service !== 'twitch' && (
        <TextInput
          value={state.config.redirectURI}
          onChangeText={value => setConfig({redirectURI: value})}
          autoCapitalize="none"
          autoCorrect={false}
          placeholder="Redirect URI"
          placeholderTextColor="#7d8794"
          style={styles.authInput}
        />
      )}
      <Text style={sharedStyles.settingNote}>{redirectHelp}</Text>
    </View>
  );
}

function NiconicoLoginPanel({onLogin, onLogout}: {onLogin: () => void; onLogout: () => void}) {
  return (
    <View style={styles.authPanel}>
      <View style={styles.authHeader}>
        <View>
          <Text style={styles.authTitle}>ニコ生</Text>
          <Text style={styles.authStatus}>WebログインCookieを利用</Text>
        </View>
        <View style={styles.authHeaderButtons}>
          <TouchableOpacity style={styles.smallButton} onPress={onLogin}>
            <Text style={styles.smallButtonText}>ログイン</Text>
          </TouchableOpacity>
          <TouchableOpacity style={[styles.smallButton, styles.dangerButton]} onPress={onLogout}>
            <Text style={styles.smallButtonText}>ログアウト</Text>
          </TouchableOpacity>
        </View>
      </View>
      <Text style={sharedStyles.settingNote}>
        ニコ生は公開OAuthがないため、iOSと同じくアプリ内WebViewでログインしてCookieをプレイヤーとコメント送信に共有します。
      </Text>
    </View>
  );
}

export function NiconicoLoginModal({visible, onClose}: {visible: boolean; onClose: () => void}) {
  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={sharedStyles.modal} edges={appSafeAreaEdges}>
        <View style={styles.loginHeader}>
          <Text style={styles.loginTitle}>ニコ生ログイン</Text>
          <TouchableOpacity style={styles.smallButton} onPress={onClose}>
            <Text style={styles.smallButtonText}>完了</Text>
          </TouchableOpacity>
        </View>
        <WebView
          source={{uri: 'https://account.nicovideo.jp/login?site=niconico&next_url=%2F'}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          setSupportMultipleWindows={false}
          style={styles.loginWeb}
        />
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  sectionTitle: {
    color: '#f7f9fc',
    fontSize: 18,
    fontWeight: '700',
    marginBottom: 10,
  },
  platformDot: {
    width: 9,
    height: 9,
    borderRadius: 5,
    marginRight: 8,
  },
  smallButton: {
    minWidth: 54,
    height: 30,
    paddingHorizontal: 10,
    marginRight: 6,
    marginBottom: 4,
    borderRadius: 7,
    backgroundColor: '#1a2532',
    alignItems: 'center',
    justifyContent: 'center',
  },
  smallButtonText: {
    color: '#dce6f3',
    fontSize: 12,
    fontWeight: '700',
  },
  disabled: {
    opacity: 0.35,
  },
  dangerButton: {
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 7,
    backgroundColor: '#3a1720',
    alignItems: 'center',
    justifyContent: 'center',
  },
  settings: {
    flex: 1,
  },
  settingsContent: {
    padding: 16,
    paddingBottom: 24,
  },
  // iOS の赤文字テーブル行(破壊的操作)に対応する設定行テキスト。
  dangerRowText: {
    flex: 1,
    color: '#ff8fa0',
    fontSize: 15,
    fontWeight: '700',
  },
  authPanel: {
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
  },
  authHeader: {
    minHeight: 36,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  authHeaderButtons: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  authTitle: {
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '800',
  },
  authStatus: {
    marginTop: 2,
    color: '#8c98a8',
    fontSize: 12,
    fontWeight: '700',
  },
  pendingAuthCard: {
    marginTop: 8,
    padding: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#2f8cff',
    backgroundColor: '#101b29',
  },
  pendingAuthLabel: {
    color: '#c8d5e6',
    fontSize: 12,
  },
  pendingAuthCode: {
    marginTop: 6,
    color: '#fff',
    fontSize: 22,
    fontWeight: '900',
    letterSpacing: 2,
  },
  pendingAuthURL: {
    marginTop: 4,
    color: '#8ebeff',
    fontSize: 12,
  },
  pendingAuthButton: {
    minHeight: 36,
    marginTop: 8,
    paddingHorizontal: 12,
    alignSelf: 'flex-start',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 7,
    backgroundColor: '#2f8cff',
  },
  authInput: {
    minHeight: 42,
    marginTop: 8,
    paddingHorizontal: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    fontSize: 13,
  },
  loginHeader: {
    minHeight: 52,
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
  },
  loginTitle: {
    color: '#edf3fb',
    fontSize: 17,
    fontWeight: '800',
  },
  loginWeb: {
    flex: 1,
    backgroundColor: '#05070a',
  },
  orderRow: {
    minHeight: 48,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
    flexDirection: 'row',
    alignItems: 'center',
  },
  orderLabel: {
    flex: 1,
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '700',
  },
  clearButton: {
    minHeight: 44,
    marginHorizontal: 16,
    marginTop: 14,
    borderRadius: 7,
    backgroundColor: '#2a151b',
    alignItems: 'center',
    justifyContent: 'center',
  },
  clearButtonText: {
    color: '#ffb4c0',
    fontSize: 15,
    fontWeight: '800',
  },
});
