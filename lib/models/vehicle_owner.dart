/// Owner details belong to a VEHICLE, not to a single weekly token.
///
/// SMS/OCR imports never carry the owner's name or CNIC, so the freshest
/// non-empty values ever recorded for a plate are re-used for every new token
/// of that same plate (and copied onto older tokens that were missing them).
class VehicleOwner {
  final String? personName;
  final String? cnic;

  const VehicleOwner({this.personName, this.cnic});

  bool get isEmpty => personName == null && cnic == null;

  /// Trimmed value, or null when blank — blank and NULL mean the same thing.
  static String? clean(Object? value) {
    final s = value?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}
