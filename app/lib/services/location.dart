import 'package:geolocator/geolocator.dart';

/// GPS konumu (geolocator). Açılışta akışa abone olur, en son konumu önbellekte tutar;
/// böylece /chat isteğinde anlık gecikme olmadan konum gönderilir.
class LocationService {
  Position? _last;

  Position? get last => _last;

  Future<void> start() async {
    if (!await _ensurePermission()) return;
    try {
      _last = await Geolocator.getLastKnownPosition();
    } catch (_) {}
    try {
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 25,
        ),
      ).listen((p) => _last = p, onError: (_) {});
    } catch (_) {}
    // İlk doğru konumu da bir kez almayı dene (akış gecikebilir).
    if (_last == null) {
      try {
        _last = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
      } catch (_) {}
    }
  }

  Future<bool> _ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      return perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }
}
