import React from 'react';
import { StyleSheet, View } from 'react-native';
import { computeGrid } from '../layout';
import { Settings, Stream } from '../types';
import { buildPlayerUrl } from '../url';
import StreamCell from './StreamCell';

interface Props {
  streams: Stream[];
  settings: Settings;
  width: number;
  height: number;
  onRemove: (id: string) => void;
}

export default function Grid({ streams, settings, width, height, onRemove }: Props) {
  const { rows } = computeGrid(streams.length, width > height);
  const perRow = Math.max(1, Math.ceil(streams.length / rows));

  // Split into rows; each row's cells stretch to fill the width (no empty gaps).
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
            {rowStreams.map(stream => {
              const url = buildPlayerUrl(stream, settings);
              if (!url) {
                return null;
              }
              return (
                <StreamCell
                  key={stream.id}
                  stream={stream}
                  url={url}
                  width={cellW}
                  height={rowHeight}
                  onRemove={() => onRemove(stream.id)}
                />
              );
            })}
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
