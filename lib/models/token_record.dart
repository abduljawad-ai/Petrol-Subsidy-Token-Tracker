// Token record model for FuelToken Tracker

enum TokenStatus {
  active,
  redeemed,
  expired,
  pending,
  unknown,
}

enum VehicleType {
  motorcycle,
  rickshaw,
  qingqi,
  smallCar,
  other,
}

class TokenRecord {
  final String id;
  final String tokenCode;        // The actual code shown to pump attendant
  final String vehicleNumber;    // Vehicle plate number
  final VehicleType vehicleType;
  final String? personName;      // Owner name (optional)
  final String? mobileNumber;    // Source mobile number
  final String? cnic;            // CNIC (optional)
  final TokenStatus status;
  final DateTime dateReceived;
  final DateTime dateImported;
  final DateTime? expiryDate;
  final DateTime? redeemedAt;   // When it was used at the pump (null until used)
  final double? subsidyAmount;   // Rs per litre
  final int? fuelLitres;         // Quota in litres
  final int? litresUsed;         // Already used
  final String? originalMessage; // Raw SMS text
  final String? notes;
  final bool isPotentialDuplicate;

  const TokenRecord({
    required this.id,
    required this.tokenCode,
    required this.vehicleNumber,
    required this.vehicleType,
    this.personName,
    this.mobileNumber,
    this.cnic,
    required this.status,
    required this.dateReceived,
    required this.dateImported,
    this.expiryDate,
    this.redeemedAt,
    this.subsidyAmount,
    this.fuelLitres,
    this.litresUsed,
    this.originalMessage,
    this.notes,
    this.isPotentialDuplicate = false,
  });

  /// Masked token code for list display (e.g. "266 •••• 719" or "840 •••• 225")
  /// so bystanders cannot read the full token from a distance.
  String get maskedTokenCode {
    final code = tokenCode.trim();
    if (code.length <= 4) return '••••';
    if (code.length <= 6) {
      return '${code.substring(0, 2)} •••• ${code.substring(code.length - 2)}';
    }
    return '${code.substring(0, 3)} •••• ${code.substring(code.length - 3)}';
  }

  bool get isExpired {
    if (expiryDate == null) return false;
    return DateTime.now().isAfter(expiryDate!);
  }

  TokenStatus get effectiveStatus {
    if (isExpired && status == TokenStatus.active) return TokenStatus.expired;
    return status;
  }

  String get vehicleTypeLabel {
    switch (vehicleType) {
      case VehicleType.motorcycle:
        return 'Motorcycle';
      case VehicleType.rickshaw:
        return 'Rickshaw';
      case VehicleType.qingqi:
        return 'Qingqi';
      case VehicleType.smallCar:
        return 'Small Car (≤800cc)';
      case VehicleType.other:
        return 'Other';
    }
  }

  String get statusLabel {
    switch (effectiveStatus) {
      case TokenStatus.active:
        return 'ACTIVE';
      case TokenStatus.redeemed:
        return 'REDEEMED';
      case TokenStatus.expired:
        return 'EXPIRED';
      case TokenStatus.pending:
        return 'PENDING';
      case TokenStatus.unknown:
        return 'UNKNOWN';
    }
  }

  TokenRecord copyWith({
    String? id,
    String? tokenCode,
    String? vehicleNumber,
    VehicleType? vehicleType,
    String? personName,
    String? mobileNumber,
    String? cnic,
    TokenStatus? status,
    DateTime? dateReceived,
    DateTime? dateImported,
    DateTime? expiryDate,
    DateTime? redeemedAt,
    double? subsidyAmount,
    int? fuelLitres,
    int? litresUsed,
    String? originalMessage,
    String? notes,
    bool? isPotentialDuplicate,
  }) {
    return TokenRecord(
      id: id ?? this.id,
      tokenCode: tokenCode ?? this.tokenCode,
      vehicleNumber: vehicleNumber ?? this.vehicleNumber,
      vehicleType: vehicleType ?? this.vehicleType,
      personName: personName ?? this.personName,
      mobileNumber: mobileNumber ?? this.mobileNumber,
      cnic: cnic ?? this.cnic,
      status: status ?? this.status,
      dateReceived: dateReceived ?? this.dateReceived,
      dateImported: dateImported ?? this.dateImported,
      expiryDate: expiryDate ?? this.expiryDate,
      redeemedAt: redeemedAt ?? this.redeemedAt,
      subsidyAmount: subsidyAmount ?? this.subsidyAmount,
      fuelLitres: fuelLitres ?? this.fuelLitres,
      litresUsed: litresUsed ?? this.litresUsed,
      originalMessage: originalMessage ?? this.originalMessage,
      notes: notes ?? this.notes,
      isPotentialDuplicate: isPotentialDuplicate ?? this.isPotentialDuplicate,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tokenCode': tokenCode,
      'vehicleNumber': vehicleNumber,
      'vehicleType': vehicleType.index,
      'personName': personName,
      'mobileNumber': mobileNumber,
      'cnic': cnic,
      'status': status.index,
      'dateReceived': dateReceived.millisecondsSinceEpoch,
      'dateImported': dateImported.millisecondsSinceEpoch,
      'expiryDate': expiryDate?.millisecondsSinceEpoch,
      'redeemedAt': redeemedAt?.millisecondsSinceEpoch,
      'subsidyAmount': subsidyAmount,
      'fuelLitres': fuelLitres,
      'litresUsed': litresUsed,
      'originalMessage': originalMessage,
      'notes': notes,
      'isPotentialDuplicate': isPotentialDuplicate ? 1 : 0,
    };
  }

  /// Tolerant row decoder. Values can arrive as int or double depending on
  /// the SQLite column affinity / JSON round-trip, and enum ordinals can be
  /// out of range after a downgrade — never let that crash a screen.
  factory TokenRecord.fromMap(Map<String, dynamic> map) {
    return TokenRecord(
      id: map['id']?.toString() ?? '',
      tokenCode: map['tokenCode']?.toString() ?? '',
      vehicleNumber: map['vehicleNumber']?.toString() ?? '',
      vehicleType: _enumAt(
          VehicleType.values, map['vehicleType'], VehicleType.other),
      personName: map['personName'] as String?,
      mobileNumber: map['mobileNumber'] as String?,
      cnic: map['cnic'] as String?,
      status: _enumAt(TokenStatus.values, map['status'], TokenStatus.unknown),
      dateReceived: _date(map['dateReceived']),
      dateImported: _date(map['dateImported']),
      expiryDate: _dateOrNull(map['expiryDate']),
      redeemedAt: _dateOrNull(map['redeemedAt']),
      subsidyAmount: (map['subsidyAmount'] as num?)?.toDouble(),
      fuelLitres: (map['fuelLitres'] as num?)?.toInt(),
      litresUsed: (map['litresUsed'] as num?)?.toInt(),
      originalMessage: map['originalMessage'] as String?,
      notes: map['notes'] as String?,
      isPotentialDuplicate: _asBool(map['isPotentialDuplicate']),
    );
  }

  static T _enumAt<T>(List<T> values, dynamic raw, T fallback) {
    final index = (raw as num?)?.toInt();
    if (index == null || index < 0 || index >= values.length) return fallback;
    return values[index];
  }

  static DateTime _date(dynamic raw) => DateTime.fromMillisecondsSinceEpoch(
      (raw as num?)?.toInt() ?? 0);

  static DateTime? _dateOrNull(dynamic raw) {
    final ms = (raw as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static bool _asBool(dynamic raw) =>
      raw == true || (raw is num && raw.toInt() == 1);
}
