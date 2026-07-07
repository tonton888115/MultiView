import React from 'react';
import {StyleSheet, Text, TouchableOpacity} from 'react-native';

export function Pill({active, color, label, onPress}: {active: boolean; color?: string; label: string; onPress: () => void}) {
  return (
    <TouchableOpacity
      style={[styles.pill, active && styles.pillActive, active && color ? {borderColor: color} : null]}
      onPress={onPress}>
      <Text style={[styles.pillText, active && styles.pillTextActive]}>{label}</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  pill: {
    height: 32,
    paddingHorizontal: 14,
    marginRight: 8,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    alignItems: 'center',
    justifyContent: 'center',
  },
  pillActive: {
    backgroundColor: '#1b2633',
  },
  pillText: {
    color: '#9aa7b7',
    fontSize: 13,
    fontWeight: '700',
  },
  pillTextActive: {
    color: '#f7f9fc',
  },
});
