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

// =============================================================================
// APP CONFIGURATION
// =============================================================================
class AppConfig {
  static const String baseUrl = 'https://datastream-backend.onrender.com';

  // Placeholder until a CPA network is picked. Each network gives you an
  // offerwall link that takes your user's ID as a query param â€” put that
  // template here once you have it, e.g.
  // 'https://network.example.com/offers?subid={uid}'
  static const String offerwallUrlTemplate = '';
}

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
// BACKEND CLIENT â€” every call attaches the user's Firebase ID token, so the
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
        // dataBalanceMb is the only balance field now. It is never written
        // to again from the client â€” the backend ledger owns all changes.
        await userRef.set({
          'userId': user.uid,
          'email': user.email,
          'displayName': user.displayName ?? '',
          'boundDeviceId': deviceId,
          'dataBalanceMb': 0,
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
// MAIN NAVIGATION â€” two tabs now: Wallet (top up / redeem) and Earn (offerwall).
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

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(widget.user.uid).snapshots(),
      builder: (context, snapshot) {
        int balanceMb = 0;
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          balanceMb = ((data?['dataBalanceMb'] as num?) ?? 0).toInt();
        }

        final screens = [
          WalletTab(user: widget.user, balanceMb: balanceMb, onSignOut: _signOut),
          EarnTab(user: widget.user),
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

// Formats MB as a readable string (e.g. 1536 -> "1.5 GB").
String formatMb(int mb) {
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB';
  return '$mb MB';
}

// =============================================================================
// TAB 1: WALLET â€” balance, top up (M-Pesa via backend), redeem eSIM packs
// =============================================================================
class WalletTab extends StatefulWidget {
  final User user;
  final int balanceMb;
  final VoidCallback onSignOut;

  const WalletTab({super.key, required this.user, required this.balanceMb, required this.onSignOut});

  @override
  State<WalletTab> createState() => _WalletTabState();
}

class _WalletTabState extends State<WalletTab> {
  bool _redeeming = false;

  Future<void> _redeemPackage(Map<String, dynamic> package) async {
    final int costMb = ((package['costMb'] as num?) ?? 0).toInt();

    if (widget.balanceMb < costMb) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Not Enough Data Credits', style: TextStyle(color: Colors.white)),
          content: Text(
            'You need ${formatMb(costMb)} of credits to claim this plan. Earn more or top up.',
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

  void _showTopUpDialog() {
    final phoneController = TextEditingController();
    final amountController = TextEditingController();
    bool submitting = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Top Up with M-Pesa', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'M-Pesa Phone (07... or 01...)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Amount (KES)'),
              ),
              const SizedBox(height: 8),
              const Text(
                'You will get an M-Pesa prompt on your phone. Enter your PIN to complete payment.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
              onPressed: submitting
                  ? null
                  : () async {
                      final amount = int.tryParse(amountController.text.trim());
                      if (amount == null || amount <= 0 || phoneController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Enter a valid phone number and amount')),
                        );
                        return;
                      }
                      setDialogState(() => submitting = true);
                      try {
                        final result = await BackendApi.topUp(
                          amountKes: amount,
                          phone: phoneController.text.trim(),
                        );
                        if (context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(result['message'] as String? ?? 'Check your phone')),
                          );
                        }
                      } catch (e) {
                        setDialogState(() => submitting = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
                          );
                        }
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Send STK Push', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
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
                    const Text('Data Credits Balance', style: TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text(formatMb(widget.balanceMb),
                        style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent,
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(42),
                      ),
                      icon: const Icon(Icons.add_card, size: 18),
                      label: const Text('Top Up with M-Pesa', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: _showTopUpDialog,
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

                final docs = snapshot.data!.docs;
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    data['id'] = docs[index].id;
                    final costMb = ((data['costMb'] as num?) ?? 0).toInt();

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(Icons.cell_tower, color: Colors.tealAccent),
                        title: Text(data['name'] ?? 'Data Pack', style: const TextStyle(color: Colors.white)),
                        subtitle: Text('Validity: ${data['validityDays'] ?? 7} Days',
                            style: const TextStyle(color: Colors.white60)),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                          onPressed: _redeeming ? null : () => _redeemPackage(data),
                          child: Text(formatMb(costMb), style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
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
// TAB 2: EARN â€” CPA/offerwall entry point.
// This opens the offer network's page in the browser with the user's uid
// attached, so completed offers can be matched back via the backend's
// /postback/:network endpoint. Fill in AppConfig.offerwallUrlTemplate once
// a network is chosen; until then this tab explains that it's coming soon.
// =============================================================================
class EarnTab extends StatelessWidget {
  final User user;
  const EarnTab({super.key, required this.user});

  Future<void> _openOfferwall(BuildContext context) async {
    if (AppConfig.offerwallUrlTemplate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offerwall not connected yet.')),
      );
      return;
    }
    final url = AppConfig.offerwallUrlTemplate.replaceAll('{uid}', user.uid);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
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
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Offers', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _openOfferwall(context),
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
