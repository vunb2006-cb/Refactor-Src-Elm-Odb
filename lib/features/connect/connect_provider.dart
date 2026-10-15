import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/obd/elm327_connector.dart';
import '../../core/obd/obd_service.dart';
import '../../core/obd/reconnect/reconnect_status.dart';
import '../../core/obd/reconnect/reconnect_supervisor.dart';
import '../../core/obd/simulated/fault_profile.dart';
import '../../core/obd/simulated/simulated_elm327_connector.dart';
import 'bluetooth_errors.dart';

// ─── Singleton connector & service ────────────────────────────────────────────

final elm327Provider = Provider<Elm327Connector>((ref) {
  final connector = Elm327Connector();
  ref.onDispose(connector.dispose);
  return connector;
});

/// Watches the real adapter and reconnects automatically after a lost link
/// (see [ReconnectSupervisor]). It is created together with
/// [connectNotifierProvider], so it is already listening when the first
/// connection is made.
final reconnectSupervisorProvider = Provider<ReconnectSupervisor>((ref) {
  final supervisor = ReconnectSupervisor(ref.watch(elm327Provider))..start();
  ref.onDispose(supervisor.dispose);
  return supervisor;
});

/// Reconnect status for the UI: idle, waiting (with the next attempt time),
/// attempting, or gave up.
final reconnectStatusProvider = StreamProvider<ReconnectStatus>((ref) async* {
  final supervisor = ref.watch(reconnectSupervisorProvider);
  yield supervisor.status;
  yield* supervisor.statusStream;
});

final simulatedElm327Provider = Provider<SimulatedElm327Connector>((ref) {
  final connector = SimulatedElm327Connector();
  ref.onDispose(connector.dispose);
  return connector;
});

/// True while the app is running against [simulatedElm327Provider] instead
/// of real Bluetooth hardware. Flip via the "Simulate Vehicle" entry point
/// on the connect screen.
final isSimulatingProvider = StateProvider<bool>((ref) => false);

/// The transport currently backing [obdServiceProvider] — real or simulated.
final activeTransportProvider = Provider<ObdTransport>((ref) {
  return ref.watch(isSimulatingProvider)
      ? ref.watch(simulatedElm327Provider)
      : ref.watch(elm327Provider);
});

final obdServiceProvider = Provider<ObdService>((ref) {
  return ObdService(ref.watch(activeTransportProvider));
});

// ─── Connection state ─────────────────────────────────────────────────────────

final connectionStateProvider = StreamProvider<Elm327State>((ref) {
  return ref.watch(activeTransportProvider).stateStream;
});

/// The Bluetooth address of the currently (or most recently) connected device.
final lastConnectedAddressProvider = Provider<String?>((ref) {
  return ref.watch(activeTransportProvider).lastConnectedAddress;
});

/// Starts simulate mode: flips [isSimulatingProvider], connects the virtual
/// ECU with the chosen [profile], and waits until it reports connected.
Future<void> startSimulating(WidgetRef ref, FaultProfile profile) async {
  ref.read(isSimulatingProvider.notifier).state = true;
  final connector = ref.read(simulatedElm327Provider);
  connector.ecu.setFault(profile);
  await connector.connect();
}

/// Stops simulate mode and reverts [obdServiceProvider]/etc. to the real
/// hardware connector.
Future<void> stopSimulating(WidgetRef ref) async {
  await ref.read(simulatedElm327Provider).disconnect();
  ref.read(isSimulatingProvider.notifier).state = false;
}

// ─── Bonded devices ───────────────────────────────────────────────────────────

/// Result of listing paired devices — never throws; [errorMessage] set on failure.
class BondedDevicesResult {
  final List<BluetoothDevice> devices;
  final String? errorMessage;

  const BondedDevicesResult({
    required this.devices,
    this.errorMessage,
  });

  bool get hasError => errorMessage != null;
}

final bondedDevicesProvider =
    FutureProvider.autoDispose<BondedDevicesResult>((ref) async {
  try {
    final list = await ref.watch(elm327Provider).getBondedDevices();
    return BondedDevicesResult(devices: list);
  } catch (e) {
    return BondedDevicesResult(
      devices: const [],
      errorMessage: formatBluetoothAccessError(e),
    );
  }
});

// ─── Connect UI (per-device loading + friendly errors) ────────────────────────

class ConnectUiState {
  /// Address of the device currently being connected to; only that row shows a spinner.
  final String? connectingAddress;
  final String? errorMessage;

  const ConnectUiState({
    this.connectingAddress,
    this.errorMessage,
  });

  bool get isConnecting => connectingAddress != null;

  ConnectUiState copyWith({
    String? connectingAddress,
    String? errorMessage,
    bool clearConnecting = false,
    bool clearError = false,
  }) {
    return ConnectUiState(
      connectingAddress:
          clearConnecting ? null : (connectingAddress ?? this.connectingAddress),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class ConnectNotifier extends StateNotifier<ConnectUiState> {
  final Elm327Connector _connector;

  ConnectNotifier(this._connector) : super(const ConnectUiState());

  /// Returns true if the ELM is connected and ready.
  Future<bool> connect(String address) async {
    state = ConnectUiState(connectingAddress: address, errorMessage: null);
    try {
      await _connector.connect(address);
      state = const ConnectUiState();
      return _connector.isConnected;
    } catch (e) {
      state = ConnectUiState(
        errorMessage: formatElmConnectionError(e),
      );
      return false;
    }
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<void> disconnect() async {
    await _connector.disconnect();
    state = const ConnectUiState();
  }
}

final connectNotifierProvider =
    StateNotifierProvider<ConnectNotifier, ConnectUiState>((ref) {
  ref.watch(reconnectSupervisorProvider); // start listening for lost links
  return ConnectNotifier(ref.watch(elm327Provider));
});
