import '../obd_transport.dart';
import 'capability_probe.dart';
import 'capability_profile.dart';
import 'capability_repository.dart';

/// Gives the app a [CapabilityProfile] for the connected vehicle, probing only
/// when needed.
///
/// The VIN is read first because it is cheap and identifies the vehicle. A
/// stored profile for that VIN that is still fresh is reused, skipping the
/// whole PID chain. Without a VIN there is no safe way to tell whether the
/// adapter was moved to another car, so the vehicle is always probed again.
class CapabilityService {
  CapabilityService(
    this._transport,
    this._repository, {
    DateTime Function()? clock,
    this.maxAge = const Duration(days: 30),
  }) : _clock = clock ?? DateTime.now;

  final ObdTransport _transport;
  final CapabilityRepository _repository;
  final DateTime Function() _clock;

  /// Stored profiles older than this are probed again.
  final Duration maxAge;

  Future<CapabilityProfile> load({
    bool forceRefresh = false,
    String? adapterAddress,
  }) async {
    final probe = CapabilityProbe(_transport, clock: _clock);
    final vin = await probe.readVin();

    if (vin != null && !forceRefresh) {
      final cached = await _repository.load(vin);
      if (cached != null &&
          cached.hasPidInfo &&
          _clock().difference(cached.probedAt) < maxAge) {
        return cached;
      }
    }

    final profile = await probe.run(
      adapterAddress: adapterAddress,
      knownVin: vin,
      vinAlreadyRead: true,
    );
    // A probe that learned nothing about PIDs (adapter dropped mid-way) must
    // not overwrite a good stored profile.
    if (profile.hasPidInfo) await _repository.save(profile);
    return profile;
  }
}
