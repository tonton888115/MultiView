import React from 'react';
import {
  requireNativeComponent,
  type HostComponent,
  type NativeSyntheticEvent,
  type ViewProps,
} from 'react-native';

type NativePlayerEvent = {
  type: 'status' | 'error' | 'firstFrame';
  message: string;
};

export type NativeHlsPlayerProps = ViewProps & {
  sourceUrl?: string | null;
  headers?: Record<string, string>;
  paused?: boolean;
  muted?: boolean;
  volume?: number;
  liveTargetOffsetMs?: number;
  maxBitrate?: number;
  resizeMode?: 'contain' | 'cover' | 'stretch';
  onPlayerEvent?: (event: NativeSyntheticEvent<NativePlayerEvent>) => void;
};

const NativeHlsPlayerComponent =
  requireNativeComponent<NativeHlsPlayerProps>('NativeHlsPlayer') as HostComponent<NativeHlsPlayerProps>;

export const NativeHlsPlayer = React.forwardRef<React.ElementRef<typeof NativeHlsPlayerComponent>, NativeHlsPlayerProps>(
  (props, ref) => <NativeHlsPlayerComponent ref={ref} {...props} />,
);
