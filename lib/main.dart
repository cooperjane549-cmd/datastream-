import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:tapjoy_offerwall/tapjoy_offerwall.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

// =============================================================================
// APP CONFIGURATION
// =============================================================================
class AppConfig {
  static const String baseUrl = 'https://datastream-backend.onrender.com';

  static const String androidTapjoySdkKey = '98q-tCRlRHGFR9evTmRXSwECjZTE4O68v0xbvzcxBFssmkbmCWRBmKXSj0rw';
  static const String iosTapjoySdkKey = 'YOUR_IOS_TAPJOY_SDK_KEY';

  // Fallback CPA network, used whenever Tapjoy has no content ready (e.g.
  // while the Tapjoy account is still pending approval). Fill in once a
  // network is picked, e.g. 'https://network.example.com/offers?subid={uid}'
  static const String offerwallUrlTemplate = '';

  // How long to wait for Tapjoy content before falling back to the CPA link.
  static const Duration tapjoyReadyTimeout = Duration(seconds: 4);

  // Google Play Console "Managed Products" (consumables) — the ONLY way to
  // add funds now. M-Pesa top-up has been removed from the app; PayHero's
  // webhook code still exists on the backend but nothing calls it anymore.
  //
  // The ID strings here must match EXACTLY what you type into Play Console
  // > Monetize > Products > In-app products. How many credits each one
  // grants is decided by the BACKEND (server.js's IAP_PRODUCT_CREDITS map),
  // never by this list — these are display-only, so a modified APK can't
  // claim a cheap product bought more than it should.
  static const List<String> iapProductIds = [
    'credits_small',   // e.g. $1 — set its real price in Play Console
    'credits_medium',  // e.g. $5
    'credits_large',   // e.g. $10
  ];

  // The wallet's unit of account. Balances and pack prices are stored as an
  // integer count of credits, where this many credits = $1 USD. This is a
  // real exchange rate, not a display estimate — it must match the
  // backend's CREDITS_PER_USD exactly, since both sides do this same
  // conversion. 1000 credits/$1 gives you three decimal places of
  // precision (1 credit = $0.001), enough for small offer payouts.
  static const double creditsPerUsd = 1000;
}

// Formats a credit balance as a USD string, e.g. 8400 -> "$8.40".
String formatUsd(int credits) => '\$${(credits / AppConfig.creditsPerUsd).toStringAsFixed(2)}';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase initialization error: $e");
  }
  runApp(const DataStreamApp());
}

class DataStreamApp extends StatelessWidget {
  const DataStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DataStream',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
          );
        }
        if (snapshot.hasData && snapshot.data != null) {
          return MainNavigationScreen(user: snapshot.data!);
        }
        return const LoginScreen();
      },
    );
  }
}

// =============================================================================
// BACKEND CLIENT — every call attaches the user's Firebase ID token, so the
// server can verify who is asking (see requireUser() in server.js).
// =============================================================================
class BackendApi {
  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not signed in');
    final token = await user.getIdToken();

    final response = await http.post(
      Uri.parse('${AppConfig.baseUrl}$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: json.encode(body),
    );

    Map<String, dynamic> parsed;
    try {
      parsed = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Server error (${response.statusCode})');
    }
    if (response.statusCode >= 400) {
      throw Exception(parsed['message'] ?? 'Request failed (${response.statusCode})');
    }
    return parsed;
  }

  static Future<Map<String, dynamic>> topUp({required int amountKes, required String phone}) {
    return _post('/topup', {'amountKes': amountKes, 'phone': phone});
  }

  // Sends a completed Play Billing purchase to the backend, which verifies
  // it directly with Google's Play Developer API before crediting anything.
  // The client's own claim about what it bought is never trusted.
  static Future<Map<String, dynamic>> verifyIapPurchase({
    required String productId,
    required String purchaseToken,
  }) {
    return _post('/iap/verify', {'productId': productId, 'purchaseToken': purchaseToken});
  }

  static Future<Map<String, dynamic>> redeem({required String packId}) {
    // A fresh requestId per tap makes retries safe: tapping twice on a slow
    // network reuses the id on the client, but a genuinely new attempt gets
    // a new one, matching how the backend's /redeem idempotency works.
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    return _post('/redeem', {'packId': packId, 'requestId': requestId});
  }
}

// =============================================================================
// LOGIN SCREEN (GOOGLE AUTH + HARDWARE DEVICE LOCKING)
// =============================================================================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoggingIn = false;

  Future<String?> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor;
    }
    return null;
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoggingIn = true);
    try {
      final String? deviceId = await _getDeviceId();
      if (deviceId == null) {
        throw Exception("Unable to verify unique device hardware ID.");
      }

      final GoogleSignIn googleSignIn = GoogleSignIn();
      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        setState(() => _isLoggingIn = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
      final User? user = userCredential.user;
      if (user == null) throw Exception("Authentication failed.");

      final deviceRef = FirebaseFirestore.instance.collection('devices').doc(deviceId);
      final deviceSnapshot = await deviceRef.get();

      if (deviceSnapshot.exists) {
        final registeredUid = deviceSnapshot.data()?['registeredUid'];
        if (registeredUid != user.uid) {
          await FirebaseAuth.instance.signOut();
          await GoogleSignIn().signOut();
          if (mounted) _showDeviceBoundDialog();
          setState(() => _isLoggingIn = false);
          return;
        }
      } else {
        await deviceRef.set({
          'deviceId': deviceId,
          'registeredUid': user.uid,
          'email': user.email,
          'boundAt': FieldValue.serverTimestamp(),
        });
      }

      final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final userSnapshot = await userRef.get();
      if (!userSnapshot.exists) {
        // creditBalance is the wallet's only balance field — an integer
        // count of USD-pegged credits (see AppConfig.creditsPerUsd), not a
        // literal data amount. It is never written to again from the
        // client — the backend ledger owns every change from here.
        await userRef.set({
          'userId': user.uid,
          'email': user.email,
          'displayName': user.displayName ?? '',
          'boundDeviceId': deviceId,
          'creditBalance': 0,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  void _showDeviceBoundDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Device Restricted', style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'This device is already registered to a different DataStream account. '
          'To prevent multi-account abuse, only one account is permitted per device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.tealAccent)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.stream, size: 80, color: Colors.tealAccent),
              const SizedBox(height: 16),
              const Text('DataStream',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text(
                'Earn data credits and redeem them for real eSIM data',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 48),
              _isLoggingIn
                  ? const CircularProgressIndicator(color: Colors.tealAccent)
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.g_mobiledata, size: 30, color: Colors.red),
                      label: const Text('Sign in with Google',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      onPressed: _signInWithGoogle,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// MAIN NAVIGATION — two tabs now: Wallet (top up / redeem) and Earn (offerwall).
// The old Promote tab (paid follows/likes/comments) has been removed.
// =============================================================================
class MainNavigationScreen extends StatefulWidget {
  final User user;
  const MainNavigationScreen({super.key, required this.user});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  TJPlacement? _offerwallPlacement;
  bool _isTapjoyConnected = false;

  @override
  void initState() {
    super.initState();
    _initTapjoy();
  }

  // Tries to bring up Tapjoy. If the key is a placeholder, or the account
  // isn't approved yet, or the connect call fails outright, this just never
  // sets _isTapjoyConnected — EarnTab's fallback timer handles the rest.
  // No crash, no blocking: the CPA link still works with Tapjoy absent.
  void _initTapjoy() {
    final String sdkKey = Platform.isAndroid ? AppConfig.androidTapjoySdkKey : AppConfig.iosTapjoySdkKey;
    if (sdkKey.isEmpty || sdkKey.startsWith('YOUR_')) {
      debugPrint("Tapjoy SDK Key is not configured for this platform.");
      return;
    }

    Tapjoy.connect(
      sdkKey: sdkKey,
      options: {"debug": true},
      onConnectSuccess: () async {
        debugPrint("Tapjoy Connected Successfully");
        if (mounted) setState(() => _isTapjoyConnected = true);
        await Tapjoy.setUserID(userId: widget.user.uid);
        _loadOfferwallPlacement();
      },
      onConnectFailure: (code, message) {
        debugPrint("Tapjoy Connection Failed: $code - $message");
      },
    );
  }

  void _loadOfferwallPlacement() async {
    if (!_isTapjoyConnected) return;
    _offerwallPlacement = await TJPlacement.getPlacement(
      placementName: "DataStream_Offerwall",
      onRequestSuccess: (placement) => debugPrint("Tapjoy: request reached servers"),
      onRequestFailure: (placement, error) => debugPrint("Tapjoy: request failed - $error"),
      onContentReady: (placement) => debugPrint("Tapjoy: content ready to show"),
      onContentShow: (placement) => debugPrint("Tapjoy: content shown"),
      onContentDismiss: (placement) => _loadOfferwallPlacement(),
    );
    await _offerwallPlacement?.requestContent();
  }

  // Returns true if it managed to show Tapjoy content, false if the caller
  // should fall back to the CPA link instead.
  Future<bool> _tryShowTapjoy() async {
    if (!_isTapjoyConnected || _offerwallPlacement == null) return false;
    final isReady = await _offerwallPlacement!.isContentReady();
    if (isReady != true) {
      await _offerwallPlacement?.requestContent();
      return false;
    }
    await _offerwallPlacement!.showContent();
    return true;
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(widget.user.uid).snapshots(),
      builder: (context, snapshot) {
        int creditBalance = 0;
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          creditBalance = ((data?['creditBalance'] as num?) ?? 0).toInt();
        }

        final screens = [
          WalletTab(user: widget.user, creditBalance: creditBalance, onSignOut: _signOut),
          EarnTab(user: widget.user, tryShowTapjoy: _tryShowTapjoy),
        ];

        return Scaffold(
          body: screens[_currentIndex],
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) => setState(() => _currentIndex = index),
            backgroundColor: const Color(0xFF1E293B),
            selectedItemColor: Colors.tealAccent,
            unselectedItemColor: Colors.white54,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.cell_tower), label: 'Wallet & eSIM'),
              BottomNavigationBarItem(icon: Icon(Icons.task_alt), label: 'Earn Data'),
            ],
          ),
        );
      },
    );
  }
}

// Formats a pack's nominal data size as a readable string (e.g. 1536 -> "1.5 GB").
// Only used for display — the wallet itself holds USD-pegged credits (see formatUsd).
String formatMb(int mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB';
  return '$mb MB';
}

// =============================================================================
// TAB 1: WALLET — balance, top up (M-Pesa via backend), redeem eSIM packs
// =============================================================================
class WalletTab extends StatefulWidget {
  final User user;
  final int creditBalance;
  final VoidCallback onSignOut;

  const WalletTab({super.key, required this.user, required this.creditBalance, required this.onSignOut});

  @override
  State<WalletTab> createState() => _WalletTabState();
}

class _WalletTabState extends State<WalletTab> {
  bool _redeeming = false;
  String _selectedCountry = 'All';

  // --- In-app purchase (worldwide payment path) ---------------------------
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _iapSub;
  List<ProductDetails> _iapProducts = [];
  bool _iapAvailable = false;
  String? _verifyingPurchaseId; // productId currently being verified server-side

  @override
  void initState() {
    super.initState();
    _initIap();
  }

  Future<void> _initIap() async {
    final available = await _iap.isAvailable();
    if (!mounted) return;
    setState(() => _iapAvailable = available);
    if (!available) return;

    // Listen for purchase results for the lifetime of this screen.
    _iapSub = _iap.purchaseStream.listen(_onPurchaseUpdate, onError: (e) {
      debugPrint('IAP stream error: $e');
    });

    final response = await _iap.queryProductDetails(AppConfig.iapProductIds.toSet());
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint('IAP products not found in Play Console: ${response.notFoundIDs}');
    }
    if (mounted) setState(() => _iapProducts = response.productDetails);
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.pending) continue;

      if (purchase.status == PurchaseStatus.error) {
        if (mounted) {
          setState(() => _verifyingPurchaseId = null);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Purchase failed: ${purchase.error?.message ?? 'unknown error'}')),
          );
        }
        continue;
      }

      if (purchase.status == PurchaseStatus.purchased || purchase.status == PurchaseStatus.restored) {
        final token = purchase.verificationData.serverVerificationData;
        try {
          // The credit only happens once the BACKEND confirms this token
          // with Google directly — this call is what actually adds MB.
          await BackendApi.verifyIapPurchase(productId: purchase.productID, purchaseToken: token);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Purchase confirmed — credits added.')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not verify purchase: ${e.toString().replaceFirst('Exception: ', '')}')),
            );
          }
          // Don't complete the purchase on our side if verification failed —
          // leaves it pending so a retry (or Play's own restore) can recover it.
          continue;
        }
      }

      // Consumables must be completed, or Play will refund them automatically.
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      if (mounted) setState(() => _verifyingPurchaseId = null);
    }
  }

  Future<void> _buyCredits(ProductDetails product) async {
    setState(() => _verifyingPurchaseId = product.id);
    final param = PurchaseParam(productDetails: product);
    try {
      await _iap.buyConsumable(purchaseParam: param, autoConsume: true);
    } catch (e) {
      if (mounted) {
        setState(() => _verifyingPurchaseId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start purchase: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _iapSub?.cancel();
    super.dispose();
  }

  Future<void> _redeemPackage(Map<String, dynamic> package) async {
    final int costCredits = ((package['costCredits'] as num?) ?? 0).toInt();

    if (widget.creditBalance < costCredits) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Not Enough Credits', style: TextStyle(color: Colors.white)),
          content: Text(
            'You need ${formatUsd(costCredits)} of credits to claim this plan. Earn more or buy credits.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK', style: TextStyle(color: Colors.tealAccent)),
            ),
          ],
        ),
      );
      return;
    }

    setState(() => _redeeming = true);
    try {
      final result = await BackendApi.redeem(packId: package['id'] as String);
      final lpaString = (result['esimDetails'] as Map<String, dynamic>?)?['lpaString'] as String?;
      if (lpaString != null && mounted) {
        _showQrModal(lpaString);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Redeemed, but no activation code was returned.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  void _showQrModal(String lpaString) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('DataStream eSIM Ready!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: lpaString, version: QrVersions.auto, size: 200.0),
            ),
            const SizedBox(height: 16),
            SelectableText(lpaString,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.tealAccent, fontSize: 12)),
            const SizedBox(height: 8),
            const Text('Scan this QR code in your device settings to activate your profile.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, minimumSize: const Size.fromHeight(45)),
              onPressed: () => Navigator.pop(context),
              child: const Text('Done', style: TextStyle(color: Colors.white)),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.stream, color: Colors.tealAccent),
          SizedBox(width: 8),
          Text('DataStream', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: Colors.tealAccent),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const QRScannerScreen()),
            ),
          ),
          IconButton(icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: widget.onSignOut),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: const Color(0xFF0F766E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Text(widget.user.email ?? '', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text('Credits Balance', style: TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(formatUsd(widget.creditBalance),
                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.creditBalance} credits — buys different amounts of data by country',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(44),
                      ),
                      icon: const Icon(Icons.shopping_cart, size: 18),
                      label: const Text('Buy Credits', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: _iapProducts.isEmpty ? null : _showBuyCreditsSheet,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Available Data Packs',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 12),
            if (_redeeming) const Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('config')
                  .doc('data_packs')
                  .collection('items')
                  .where('active', isNotEqualTo: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Colors.tealAccent));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No data packs configured yet.', style: TextStyle(color: Colors.white54)),
                  );
                }

                final allDocs = snapshot.data!.docs;

                // Build the country chip list from whatever packs exist,
                // so adding a new country in Firestore shows up automatically.
                final countries = <String>{'All'};
                for (final doc in allDocs) {
                  final c = (doc.data() as Map<String, dynamic>)['country'] as String?;
                  if (c != null && c.isNotEmpty) countries.add(c);
                }
                if (!countries.contains(_selectedCountry)) _selectedCountry = 'All';

                final docs = _selectedCountry == 'All'
                    ? allDocs
                    : allDocs
                        .where((d) => (d.data() as Map<String, dynamic>)['country'] == _selectedCountry)
                        .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: countries.map((c) {
                          final selected = c == _selectedCountry;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(c),
                              selected: selected,
                              onSelected: (_) => setState(() => _selectedCountry = c),
                              backgroundColor: const Color(0xFF1E293B),
                              selectedColor: Colors.tealAccent,
                              labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (docs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No packs for this country yet.', style: TextStyle(color: Colors.white54)),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final data = docs[index].data() as Map<String, dynamic>;
                          data['id'] = docs[index].id;
                          final costCredits = ((data['costCredits'] as num?) ?? 0).toInt();
                          final sizeMb = ((data['sizeMb'] as num?) ?? 0).toInt();

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: const Icon(Icons.cell_tower, color: Colors.tealAccent),
                              title: Text(
                                '${data['name'] ?? 'Data Pack'}${sizeMb > 0 ? ' — ${formatMb(sizeMb)}' : ''}',
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '${data['country'] ?? 'Global'} · Validity: ${data['validityDays'] ?? 7} Days',
                                style: const TextStyle(color: Colors.white60),
                              ),
                              trailing: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                                onPressed: _redeeming ? null : () => _redeemPackage(data),
                                child: Text(formatUsd(costCredits), style: const TextStyle(color: Colors.white)),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBuyCreditsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Buy Data Credits',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 4),
              const Text('Priced in your local currency by Google Play.',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 16),
              ..._iapProducts.map((p) {
                final busy = _verifyingPurchaseId == p.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: busy
                        ? null
                        : () {
                            Navigator.pop(context);
                            _buyCredits(p);
                          },
                    child: busy
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(p.title, style: const TextStyle(color: Colors.white)),
                              Text(p.price, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ],
                          ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// QR SCANNER SCREEN (unchanged)
// =============================================================================
class QRScannerScreen extends StatelessWidget {
  const QRScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan eSIM Activation Code')),
      body: MobileScanner(
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (barcode.rawValue != null) {
              final String code = barcode.rawValue!;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Scanned eSIM Code: $code')),
              );
              break;
            }
          }
        },
      ),
    );
  }
}

// =============================================================================
// TAB 2: EARN — Tapjoy first, CPA link as fallback.
// Tapping "Open Offers" tries Tapjoy's placement immediately; if it isn't
// ready within AppConfig.tapjoyReadyTimeout (covers "not connected", "not
// yet approved", or "no content for this user right now"), it opens the CPA
// network link instead, with the user's uid attached so completed offers
// there match back via the backend's /postback/:network endpoint.
// =============================================================================
class EarnTab extends StatefulWidget {
  final User user;
  final Future<bool> Function() tryShowTapjoy;
  const EarnTab({super.key, required this.user, required this.tryShowTapjoy});

  @override
  State<EarnTab> createState() => _EarnTabState();
}

class _EarnTabState extends State<EarnTab> {
  bool _loading = false;

  Future<void> _openOffers() async {
    setState(() => _loading = true);
    try {
      final shownViaTapjoy = await widget.tryShowTapjoy().timeout(
        AppConfig.tapjoyReadyTimeout,
        onTimeout: () => false,
      );
      if (shownViaTapjoy) return;
      await _openCpaFallback();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCpaFallback() async {
    if (AppConfig.offerwallUrlTemplate.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No offers available right now — check back shortly.')),
        );
      }
      return;
    }
    final url = AppConfig.offerwallUrlTemplate.replaceAll('{uid}', widget.user.uid);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the offerwall.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Earn Data'), backgroundColor: const Color(0xFF1E293B)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.card_giftcard, size: 64, color: Colors.tealAccent),
              const SizedBox(height: 16),
              const Text(
                'Complete surveys, app installs, and offers to earn data credits.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: _loading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.open_in_new),
                label: const Text('Open Offers', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: _loading ? null : _openOffers,
              ),
              const SizedBox(height: 8),
              Text('Credits usually post within a few minutes of completing an offer.',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
