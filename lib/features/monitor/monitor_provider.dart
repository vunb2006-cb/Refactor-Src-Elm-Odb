import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/obd_service.dart';
import '../../core/obd/pid_constants.dart';
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

  bool _polling = false;
  DateTime? _sessionStart;

  LiveMonitorNotifier(this._obd) : super(const LiveMonitorState());

  void togglePid(String pidName) {
    final next = Set<String>.from(state.selectedPids);
    if (next.contains(pidName)) {
      next.remove(pidName);
    } else {
      next.add(pidName);
    }
    state = state.copyWith(selectedPids: next);
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

    await _pollLoop();
  }

  void stopPolling() {
    _polling = false;
    // State is updated at the end of _pollLoop when it exits.
  }

  Future<void> _pollLoop() async {
    while (_polling && mounted) {
      // Link down (for example while the app reconnects): wait instead of
      // spinning through reads that fail instantly. Polling resumes by itself
      // once the transport is connected again.
      if (!_obd.connector.isConnected) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final pids = state.selectedPids.toList();

      if (pids.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final elapsed =
          DateTime.now().difference(_sessionStart!).inSeconds;
      final newValues = <String, double>{};

      for (final pidName in pids) {
        if (!_polling || !mounted) break;

        final code = PidConstants.codeForName(pidName) ?? pidName;

        // Skip PIDs the ECU doesn't support (avoids command-timeout waste).
        if (_obd.supportedPids.isNotEmpty &&
            !_obd.isPidSupported(code)) {
          continue;
        }

        try {
          final value = await _obd.readPID(code);
          if (value != null) newValues[pidName] = value;
        } catch (_) {
          // Individual PID failure is non-fatal — skip and continue.
        }
      }

      if (!mounted) break;

      // Merge new values into history.
      final prev = state.history;
      final next = <String, List<ChartPoint>>{
        for (final k in prev.keys) k: prev[k]!,
      };
      for (final entry in newValues.entries) {
        next[entry.key] = [
          ...(next[entry.key] ?? []),
          (t: elapsed, v: entry.value),
        ];
      }

      state = state.copyWith(
        currentValues: {...state.currentValues, ...newValues},
        history: next,
      );
    }

    if (mounted) state = state.copyWith(isPolling: false);
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final liveMonitorProvider =
    StateNotifierProvider.autoDispose<LiveMonitorNotifier, LiveMonitorState>(
        (ref) {
  final notifier = LiveMonitorNotifier(ref.watch(obdServiceProvider));
  ref.onDispose(notifier.stopPolling);
  return notifier;
});
