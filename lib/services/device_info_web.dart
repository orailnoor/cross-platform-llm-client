/// Web device info — no RAM detection, use generous defaults.
Future<Map<String, double>> getDeviceInfo() async {
  return {'totalRamGB': 8.0, 'availableRamGB': 4.0};
}
