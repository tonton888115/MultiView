import React from 'react';
import {StyleSheet, Switch, Text, TouchableOpacity, View} from 'react-native';
import type {AppSettings} from '../types';
import {Pill} from './Pill';
import {sharedStyles} from './sharedStyles';

export function SettingSwitch({title, value, onValueChange}: {title: string; value: boolean; onValueChange: (value: boolean) => void}) {
  return (
    <View style={sharedStyles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <Switch value={value} onValueChange={onValueChange} />
    </View>
  );
}

export function LayoutModeSettingRow({value, onChange}: {value: AppSettings['layoutMode']; onChange: (value: AppSettings['layoutMode']) => void}) {
  return (
    <View style={sharedStyles.settingRow}>
      <Text style={styles.settingTitle}>表示レイアウト</Text>
      <View style={sharedStyles.iconSegment}>
        <TouchableOpacity
          style={[sharedStyles.iconSegmentButton, value === 'stacked' && sharedStyles.iconSegmentButtonActive]}
          onPress={() => onChange('stacked')}>
          <Text style={[sharedStyles.iconSegmentText, value === 'stacked' && sharedStyles.iconSegmentTextActive]}>▥</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[sharedStyles.iconSegmentButton, value === 'grid' && sharedStyles.iconSegmentButtonActive]}
          onPress={() => onChange('grid')}>
          <Text style={[sharedStyles.iconSegmentText, value === 'grid' && sharedStyles.iconSegmentTextActive]}>▦</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

export function NumberSettingRow({
  title,
  value,
  min,
  max,
  step,
  onChange,
  formatValue = numericValue => String(Math.round(numericValue)),
}: {
  title: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  formatValue?: (value: number) => string;
}) {
  const setValue = (next: number) => onChange(Math.min(max, Math.max(min, next)));
  return (
    <View style={sharedStyles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <View style={styles.stepper}>
        <TouchableOpacity style={styles.stepperButton} onPress={() => setValue(value - step)}>
          <Text style={styles.stepperButtonText}>−</Text>
        </TouchableOpacity>
        <Text style={styles.stepperValue}>{formatValue(value)}</Text>
        <TouchableOpacity style={styles.stepperButton} onPress={() => setValue(value + step)}>
          <Text style={styles.stepperButtonText}>＋</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

export function QualityRow({
  title,
  value,
  onChange,
}: {
  title: string;
  value: 'high' | 'economy';
  onChange: (value: 'high' | 'economy') => void;
}) {
  return (
    <View style={sharedStyles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <View style={styles.segment}>
        <Pill active={value === 'high'} label="高画質" onPress={() => onChange('high')} />
        <Pill active={value === 'economy'} label="エコノミー" onPress={() => onChange('economy')} />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  settingTitle: {
    flex: 1,
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '700',
    marginRight: 14,
  },
  segment: {
    flexDirection: 'row',
  },
  stepper: {
    minWidth: 128,
    height: 36,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    flexDirection: 'row',
    alignItems: 'center',
    overflow: 'hidden',
  },
  stepperButton: {
    width: 38,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepperButtonText: {
    color: '#dce6f3',
    fontSize: 22,
    fontWeight: '800',
    lineHeight: 24,
  },
  stepperValue: {
    flex: 1,
    color: '#f7f9fc',
    fontSize: 13,
    fontWeight: '800',
    textAlign: 'center',
  },
});
