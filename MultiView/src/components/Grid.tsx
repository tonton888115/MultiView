import React from 'react';
import { StyleSheet, View } from 'react-native';
import { computeGrid } from '../layout';
import { Settings, Stream } from '../types';
import StreamCell from './StreamCell';

interface Props {
  streams: Stream[];
  settings: Settings;
  width: number;
  height: number;
  onFocus: (stream: Stream) => void;
  onRemove: (stream: Stream) => void;
}

export default function Grid({ streams, settings, width, height, onFocus, onRemove }: Props) {
  const { rows } = computeGrid(streams.length, width > height);
  const perRow = Math.max(1, Math.ceil(streams.length / rows));

  const chunks: Stream[][] = [];
  for (let i = 0; i < streams.length; i += perRow) {
    chunks.push(streams.slice(i, i + perRow));
  }
  const rowHeight = chunks.length > 0 ? Math.floor(height / chunks.length) : height;

  return (
    <View style={[styles.grid, { width, height }]}>
      {chunks.map((rowStreams, ri) => {
        const cellW = Math.floor(width / rowStreams.length);
        return (
          <View key={ri} style={[styles.row, { height: rowHeight }]}>
            {rowStreams.map(stream => (
              <StreamCell
                key={stream.id}
                stream={stream}
                settings={settings}
                width={cellW}
                height={rowHeight}
                onFocus={onFocus}
                onRemove={onRemove}
              />
            ))}
          </View>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  grid: { backgroundColor: '#000' },
  row: { flexDirection: 'row' },
});
