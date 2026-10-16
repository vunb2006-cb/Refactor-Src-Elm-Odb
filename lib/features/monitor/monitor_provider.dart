import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/models/sensor_reading.dart';
import '../../core/obd/obd_service.dart';
import '../../core/obd/pid_constants.dart';
import '../../core/obd/scheduler/poll_scheduler.dart';
import '../../features/connect/connect_provider.dart';
import '../../features/session/session_provider.dart' show ChartPoint;

// ─── PID catalogue ────────────────────────────────────────────────────────────

/// All PIDs available for free-form monitoring, grouped by category.
const pidGroups = <String, List<String>>{
  'Engine': ['rpm', 'speed', 'engine_load', 'throttle', 'engine_run_time'],
  'Temperature': ['coolant_temp', 'iat', 'oil_temp'],
  'Fuel': [
    'stft_b1', 'ltft_b1', 'stft_b2', 'ltft_b2',
    'fuel_level', 'fuel_pressure', 'maf',
  ],
  'O2 / Emissions': [
    'o2_b1s1', 'o2_b1s2', 'map', 'baro_pressure', 'egr_commanded',
  ],
  'Fault': ['distance_mil_on'],
};

// ─── State ────────────────────────────────────────────────────────────────────

class LiveMonitorState {
  final bool isPolling;

  /// User-selected PIDs (by symbolic name, e.g. 'rpm').
  final Set<String> selectedPids;

  /// Latest value for each polled PID.
  final Map<String, double> currentValues;

  /// Time-series history: key = PID name, value = ordered (elapsed, value) list.
  final Map<String, List<ChartPoint>> history;

  /// PID hex codes the connected ECU reported as supported.
  /// Empty = scan not yet run (treat all as supported).
  final Set<String> vehicleSupportedPids;

  final String? errorMessage;

  const LiveMonitorState({
    this.isPolling = false,
    this.selectedPids = const {'rpm', 'coolant_temp'},
    this.currentValues = const {},
    this.history = const {},
    this.vehicleSupportedPids = const {},
    this.errorMessage,
  });

  LiveMonitorState copyWith({
    bool? isPolling,
    Set<String>? selectedPids,
    Map<String, double>? currentValues,
    Map<String, List<ChartPoint>>? history,
    bool clearHistory = false,
    Set<String>? vehicleSupportedPids,
    String? errorMessage,
    bool clearError = false,
  }) {
    return LiveMonitorState(
      isPolling: isPolling ?? this.isPolling,
      selectedPids: selectedPids ?? this.selectedPids,
      currentValues: currentValues ?? this.currentValues,
      history: clearHistory ? {} : (history ?? this.history),
      vehicleSupportedPids: vehicleSupportedPids ?? this.vehicleSupportedPids,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

class LiveMonitorNotifier extends StateNotifier<LiveMonitorState> {
  final ObdService _obd;
  final PollScheduler _scheduler;

  bool _polling = false;
  DateTime? _sessionStart;
  PollLease? _lease;
  StreamSubscription<SensorReading>? _readingSub;

  /// PID code to the symbolic name the screen uses ('0C' to 'rpm').
  static final Map<String, String> _nameByCode = {
    for (final e in PidConstants.nameToCode.entries) e.value: e.key,
  };

  LiveMonitorNotifier(this._obd, this._scheduler)
      : super(const LiveMonitorState());

  void togglePid(String pidName) {
    final next = Set<String>.from(state.selectedPids);
    if (next.contains(pidName)) {
      next.remove(pidName);
    } else {
      next.add(pidName);
    }
    state = state.copyWith(selectedPids: next);
    _syncLease();
  }

  void clearHistory() {
    _sessionStart = null;
    state = state.copyWith(clearHistory: true, currentValues: {});
  }

  Future<void> startPolling() async {
    if (_polling) return;
    _polling = true;
    _sessionStart = DateTime.now();

    state = state.copyWith(isPolling: true, clearHistory: true, clearError: true);

    // Read supported PIDs if we haven't yet — so we can reflect support in
    // the selector even before the user starts a diagnostic session.
    if (_obd.supportedPids.isEmpty) {
      try {
        await _obd.readSupportedPIDs();
        if (mounted) {
          state = state.copyWith(vehicleSupportedPids: _obd.supportedPids);
        }
      } catch (_) {
        // Non-fatal: some ECUs don't respond to the bitmask query.
        // Treat all PIDs as supported.
      }
    } else {
      state = state.copyWith(vehicleSupportedPids: _obd.supportedPids);
    }

    // The user may have pressed stop while the supported PIDs were read.
    if (!_polling || !mounted) return;

    _readingSub = _scheduler.readings.listen(_onReading);
    _lease = _scheduler.request(_requestedCodes(), owner: 'monitor');
  }

  void stopPolling() {
    _polling = false;
    _lease?.cancel();
    _lease = null;
    _readingSub?.cancel();
    _readingSub = null;
    if (mounted) state = state.copyWith(isPolling: false);
  }

  /// PID codes to read: what the user selected, minus what the vehicle does
  /// not support (avoids command-timeout waste).
  Set<String> _requestedCodes() {
    final codes = <String>{};
    for (final name in state.selectedPids) {
      final code = PidConstants.codeForName(name) ?? name;
      if (_obd.supportedPids.isNotEmpty && !_obd.isPidSupported(code)) continue;
      codes.add(code);
    }
    return codes;
  }

  void _syncLease() => _lease?.update(_requestedCodes());

  void _onReading(SensorReading r) {
    if (!mounted || !_polling) return;
    final name = _nameByCode[r.pid] ?? r.pid;
    if (!state.selectedPids.contains(name)) return;

    // After "clear history" the time axis restarts at the next reading.
    final start = _sessionStart ??= r.timestamp;
    final elapsed = r.timestamp.difference(start).inSeconds;

    final prev = state.history;
    final points = [
      ...(prev[name] ?? const <ChartPoint>[]),
      (t: elapsed, v: r.value),
    ];
    state = state.copyWith(
      currentValues: {...state.currentValues, name: r.value},
      history: {...prev, name: points},
    );
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final liveMonitorProvider =
    StateNotifierProvider.autoDispose<LiveMonitorNotifier, LiveMonitorState>(
        (ref) {
  final notifier = LiveMonitorNotifier(
    ref.watch(obdServiceProvider),
    ref.watch(pollSchedulerProvider),
  );
  ref.onDispose(notifier.stopPolling);
  return notifier;
});
