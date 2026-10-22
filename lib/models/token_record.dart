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

  int get litresRemaining {
    if (fuelLitres == null) return 0;
    return fuelLitres! - (litresUsed ?? 0);
  }

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

  factory TokenRecord.fromMap(Map<String, dynamic> map) {
    return TokenRecord(
      id: map['id'] as String,
      tokenCode: map['tokenCode'] as String,
      vehicleNumber: map['vehicleNumber'] as String,
      vehicleType: VehicleType.values[map['vehicleType'] as int],
      personName: map['personName'] as String?,
      mobileNumber: map['mobileNumber'] as String?,
      cnic: map['cnic'] as String?,
      status: TokenStatus.values[map['status'] as int],
      dateReceived: DateTime.fromMillisecondsSinceEpoch(map['dateReceived'] as int),
      dateImported: DateTime.fromMillisecondsSinceEpoch(map['dateImported'] as int),
      expiryDate: map['expiryDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['expiryDate'] as int)
          : null,
      redeemedAt: map['redeemedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['redeemedAt'] as int)
          : null,
      subsidyAmount: map['subsidyAmount'] as double?,
      fuelLitres: map['fuelLitres'] as int?,
      litresUsed: map['litresUsed'] as int?,
      originalMessage: map['originalMessage'] as String?,
      notes: map['notes'] as String?,
      isPotentialDuplicate: (map['isPotentialDuplicate'] as int? ?? 0) == 1,
    );
  }
}
