import 'package:flutter/material.dart';
import 'package:telephony/telephony.dart';
import 'local_db_service.dart';
import '../models/sale_transaction.dart';

class MpesaListenerService {
  static final MpesaListenerService instance = MpesaListenerService._init();
  final Telephony telephony = Telephony.instance;

  MpesaListenerService._init();

  static const String appTillNumber = "3043489";

  void initializeListener({
    required String storeTillNumber,
    required List<SaleTransaction> currentSales,
    required Function(String saleId, String mpesaCode) onDebtAutoCleared,
    required Function(bool isSubscribed, DateTime expiryDate) onSubscriptionUpdated,
  }) async {
    bool? permissionsGranted = await telephony.requestPhoneAndSmsPermissions;

    if (permissionsGranted == true) {
      telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          _processIncomingSms(
            message.body ?? '',
            storeTillNumber,
            currentSales,
            onDebtAutoCleared,
            onSubscriptionUpdated,
          );
        },
        listenInBackground: true,
      );
    }
  }

  void _processIncomingSms(
    String body,
    String storeTillNumber,
    List<SaleTransaction> currentSales,
    Function(String saleId, String mpesaCode) onDebtAutoCleared,
    Function(bool isSubscribed, DateTime expiryDate) onSubscriptionUpdated,
  ) {
    if (!body.contains("Confirmed") && !body.contains("received")) return;

    // Extract M-Pesa Code (e.g., QA12345678)
    final RegExp codeRegex = RegExp(r'^([A-Z0-9]{10})\s+Confirmed');
    final matchCode = codeRegex.firstMatch(body);
    final String mpesaCode = matchCode != null ? matchCode.group(1)! : '';

    // Extract Amount
    final RegExp amountRegex = RegExp(r'KES\s*([\d,]+\.?\d*)');
    final matchAmount = amountRegex.firstMatch(body);
    double amount = 0.0;
    if (matchAmount != null) {
      amount = double.tryParse(matchAmount.group(1)!.replaceAll(',', '')) ?? 0.0;
    }

    // 1. Check for App Subscription Payment (Till 3043489)
    if (body.contains(appTillNumber) || body.contains("3043489")) {
      if (amount >= 1100) {
        DateTime expiry = DateTime.now().add(const Duration(days: 365));
        onSubscriptionUpdated(true, expiry);
      } else if (amount >= 100) {
        DateTime expiry = DateTime.now().add(const Duration(days: 30));
        onSubscriptionUpdated(true, expiry);
      }
      return;
    }

    // 2. Check for Store Debt Clearance Payment
    if (storeTillNumber.isNotEmpty && body.contains(storeTillNumber)) {
      // Find matching unpaid credit sale with similar total amount
      final unpaidSales = currentSales.where((s) =>
          s.paymentMethod == 'CREDIT' &&
          !s.isPaid &&
          (s.totalAmount - amount).abs() < 1.0).toList();

      if (unpaidSales.isNotEmpty) {
        final saleToClear = unpaidSales.first;
        LocalDbService.instance.markSalePaid(saleToClear.id, mpesaCode);
        onDebtAutoCleared(saleToClear.id, mpesaCode);
      }
    }
  }
}
