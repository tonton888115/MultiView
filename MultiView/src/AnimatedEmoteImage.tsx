import React from 'react';
import {
  Image,
  Platform,
  requireNativeComponent,
  type ImageStyle,
  type StyleProp,
  type ViewStyle,
} from 'react-native';

type NativeAnimatedImageProps = {
  sourceUrl: string;
  style?: StyleProp<ViewStyle>;
};

const NativeAnimatedImage = Platform.OS === 'android'
  ? requireNativeComponent<NativeAnimatedImageProps>('MVAnimatedImage')
  : null;

export function AnimatedEmoteImage({url, style}: {url: string; style?: StyleProp<ImageStyle>}) {
  if (NativeAnimatedImage) {
    return <NativeAnimatedImage sourceUrl={url} style={style as StyleProp<ViewStyle>} />;
  }
  return <Image source={{uri: url}} resizeMode="contain" style={style} />;
}
