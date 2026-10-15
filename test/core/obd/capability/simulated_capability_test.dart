import 'package:elm_obd2/core/obd/capability/capability_probe.dart';
import 'package:elm_obd2/core/obd/simulated/simulated_elm327_connector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the probe works against the simulator end to end', () async {
    final sim = SimulatedElm327Connector();
    await sim.connect();
    addTearDown(sim.dispose);

    final profile = await CapabilityProbe(sim).run(adapterAddress: 'SIM');

    expect(profile.vin, SimulatedElm327Connector.simulatedVin);
    expect(profile.protocol!.code, '6');
    // PIDs from the first three ranges, proving the chain was followed.
    expect(profile.supportedPids, containsAll(['05', '0C', '0D', '2F', '5C']));
    expect(profile.supportedPids.contains('62'), isFalse);
  });
}
