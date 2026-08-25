enum PaymentStatus { paid, pending, partial }

class Customer {
  const Customer({required this.id, required this.name, this.phone});
  final String id;
  final String name;
  final String? phone;
}

class Supplier {
  const Supplier({required this.id, required this.name, this.phone});
  final String id;
  final String name;
  final String? phone;
}

class Sale {
  const Sale({
    required this.id,
    required this.productType,
    required this.productLabel,
    required this.quantity,
    required this.unit,
    required this.amountUsd,
    required this.paymentStatus,
    required this.soldAt,
    this.customerId,
  });

  final String id;
  final String productType; // milk | eggs | produce | animals | farm_products
  final String productLabel;
  final double quantity;
  final String unit;
  final double amountUsd;
  final PaymentStatus paymentStatus;
  final DateTime soldAt;
  final String? customerId;
}

class Expense {
  const Expense({
    required this.id,
    required this.category,
    required this.amountUsd,
    required this.incurredAt,
    this.supplierId,
    this.linkedEntityType,
    this.linkedEntityId,
  });

  final String id;
  final String category; // feed | medicine | labor | fuel | other
  final double amountUsd;
  final DateTime incurredAt;
  final String? supplierId;
  final String? linkedEntityType;
  final String? linkedEntityId;
}
