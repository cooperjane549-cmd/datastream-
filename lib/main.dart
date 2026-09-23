import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:tapjoy_offerwall/tapjoy_offerwall.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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

      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
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

      if (user == null) {
        throw Exception("Authentication failed.");
      }

      final deviceRef = FirebaseFirestore.instance.collection('devices').doc(deviceId);
      final deviceSnapshot = await deviceRef.get();

      if (deviceSnapshot.exists) {
        final registeredUid = deviceSnapshot.data()?['registeredUid'];

        if (registeredUid != user.uid) {
          await FirebaseAuth.instance.signOut();
          await GoogleSignIn().signOut();

          if (mounted) {
            _showDeviceBoundDialog();
          }
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
        await userRef.set({
          'userId': user.uid,
          'email': user.email,
          'displayName': user.displayName,
          'boundDeviceId': deviceId,
          'balanceUsd': 0.00,
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
      if (mounted) {
        setState(() => _isLoggingIn = false);
      }
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
              const Text(
                'DataStream',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              const Text(
                'Earn global eSIM data by completing social tasks',
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
                      label: const Text(
                        'Sign in with Google',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
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
// MAIN NAVIGATION SCREEN
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

  @override
  void initState() {
    super.initState();
    _initTapjoy();
  }

  void _initTapjoy() {
    Tapjoy.connect(
      sdkKey: Platform.isAndroid ? "YOUR_ANDROID_TAPJOY_SDK_KEY" : "YOUR_IOS_TAPJOY_SDK_KEY",
      options: {"debug": true},
      onConnectSuccess: () async {
        await Tapjoy.setUserID(userId: widget.user.uid);
        _loadOfferwallPlacement();
      },
      onConnectFailure: (code, message) {
        debugPrint("Tapjoy Connection Failed: $message");
      },
    );
  }

  void _loadOfferwallPlacement() async {
    _offerwallPlacement = await TJPlacement.getPlacement(
      placementName: "DataStream_Offerwall",
      onRequestSuccess: (placement) {
        debugPrint("Tapjoy: request reached servers");
      },
      onRequestFailure: (placement, error) {
        debugPrint("Tapjoy: request failed - $error");
      },
      onContentReady: (placement) {
        debugPrint("Tapjoy: content ready to show");
      },
      onContentShow: (placement) {
        debugPrint("Tapjoy: content shown");
      },
      onContentDismiss: (placement) {
        _loadOfferwallPlacement();
      },
    );
    await _offerwallPlacement?.requestContent();
  }

  void _showOfferwall() async {
    if (_offerwallPlacement != null) {
      final isReady = await _offerwallPlacement!.isContentReady();
      if (isReady == true) {
        await _offerwallPlacement!.showContent();
        return;
      } else {
        await _offerwallPlacement!.requestContent();
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offerwall loading... Please try again in a few seconds.')),
      );
    }
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
        double userBalanceUsd = 0.00;
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          userBalanceUsd = (data?['balanceUsd'] as num?)?.toDouble() ?? 0.00;
        }

        final screens = [
          EsimStoreTab(
            userBalanceUsd: userBalanceUsd,
            onShowOfferwall: _showOfferwall,
            user: widget.user,
            onSignOut: _signOut,
          ),
          EarnTasksTab(
            userId: widget.user.uid,
          ),
          PromoteTab(
            userId: widget.user.uid,
            userBalanceUsd: userBalanceUsd,
          ),
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
              BottomNavigationBarItem(
                icon: Icon(Icons.cell_tower),
                label: 'eSIM & Wallet',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.task_alt),
                label: 'Earn Data',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.campaign),
                label: 'Promote',
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// TAB 1: ESIM STORE & WALLET HUB (M-PESA TELEGRAM + PAYPAL + QR SCAN)
// =============================================================================
class EsimStoreTab extends StatelessWidget {
  final double userBalanceUsd;
  final VoidCallback onShowOfferwall;
  final User user;
  final VoidCallback onSignOut;

  const EsimStoreTab({
    super.key,
    required this.userBalanceUsd,
    required this.onShowOfferwall,
    required this.user,
    required this.onSignOut,
  });

  Future<void> _redeemPackage(BuildContext context, Map<String, dynamic> package) async {
    final double cost = package['priceUsd'];

    if (userBalanceUsd < cost) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Insufficient Data Credits', style: TextStyle(color: Colors.white)),
          content: Text(
            'You need \$${cost.toStringAsFixed(2)} to claim this plan. Complete social tasks or top up your balance.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
              onPressed: () {
                Navigator.pop(context);
                onShowOfferwall();
              },
              child: const Text('Earn Credits', style: TextStyle(color: Colors.black)),
            )
          ],
        ),
      );
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('https://your-render-service.onrender.com/api/esim/redeem'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': user.uid,
          'packageId': package['id'],
          'packageCostUsd': cost,
        }),
      );

      final result = json.decode(response.body);

      if (response.statusCode == 200 && result['success'] == true) {
        if (context.mounted) {
          _showQrModal(context, result['esimDetails']['lpaString']);
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result['message'] ?? 'Redemption failed')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Network error connecting to eSIM server.')),
        );
      }
    }
  }

  void _showTopUpOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Payment Method',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.phone_android, color: Colors.greenAccent),
              title: const Text('M-Pesa (Manual Verification)', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Send money & verify via Telegram Bot', style: TextStyle(color: Colors.white60)),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
              onTap: () {
                Navigator.pop(context);
                _showMpesaSubmitDialog(context);
              },
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(Icons.payment, color: Colors.blueAccent),
              title: const Text('PayPal', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Instant automatic checkout', style: TextStyle(color: Colors.white60)),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
              onTap: () {
                Navigator.pop(context);
                _launchPayPalCheckout(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMpesaSubmitDialog(BuildContext context) {
    final mpesaCodeController = TextEditingController();
    final amountController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('M-Pesa Deposit Verification', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Send M-Pesa payment to the designated till/number, then paste your M-Pesa transaction reference below for Telegram Bot review.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: mpesaCodeController,
              decoration: const InputDecoration(
                labelText: 'M-Pesa Ref (e.g. UGFQVB4S6R)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Amount Sent (KES)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            onPressed: () async {
              if (mpesaCodeController.text.isEmpty) return;

              await FirebaseFirestore.instance.collection('mpesa_deposits').add({
                'userId': user.uid,
                'email': user.email,
                'mpesaRef': mpesaCodeController.text.trim(),
                'amountKes': double.tryParse(amountController.text) ?? 0.0,
                'status': 'pending',
                'createdAt': FieldValue.serverTimestamp(),
              });

              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment submitted! Awaiting Telegram Admin approval.')),
                );
              }
            },
            child: const Text('Submit Code', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Future<void> _launchPayPalCheckout(BuildContext context) async {
    final Uri paypalUrl = Uri.parse('https://your-render-service.onrender.com/paypal/checkout?userId=${user.uid}');
    if (await canLaunchUrl(paypalUrl)) {
      await launchUrl(paypalUrl, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open PayPal endpoint.')),
        );
      }
    }
  }

  void _showQrModal(BuildContext context, String lpaString) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'DataStream eSIM Ready!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: lpaString,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Scan this QR code in your device settings to activate your profile.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                minimumSize: const Size.fromHeight(45),
              ),
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
        title: const Row(
          children: [
            Icon(Icons.stream, color: Colors.tealAccent),
            SizedBox(width: 8),
            Text('DataStream', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: Colors.tealAccent),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const QRScannerScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: onSignOut,
          )
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
                    Text(user.email ?? '', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text('Data Credits Balance', style: TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text('\$${userBalanceUsd.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.tealAccent,
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(42),
                            ),
                            icon: const Icon(Icons.add_card, size: 18),
                            label: const Text('Top Up', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: () => _showTopUpOptions(context),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white12,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(42),
                            ),
                            icon: const Icon(Icons.bolt, size: 18, color: Colors.tealAccent),
                            label: const Text('Tapjoy', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: onShowOfferwall,
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Available Data Packs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('config').doc('data_packs').collection('items').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Colors.tealAccent));
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  final fallbackPacks = [
                    {'id': 'kenya-1gb-7days', 'title': 'Kenya 1 GB High-Speed Data', 'validity': '7 Days', 'priceUsd': 2.50},
                    {'id': 'global-3gb-30days', 'title': 'Global 3 GB Roaming Data', 'validity': '30 Days', 'priceUsd': 6.00},
                  ];

                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: fallbackPacks.length,
                    itemBuilder: (context, index) {
                      final package = fallbackPacks[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: const Icon(Icons.cell_tower, color: Colors.tealAccent),
                          title: Text(package['title'] as String, style: const TextStyle(color: Colors.white)),
                          subtitle: Text('Validity: ${package['validity']}', style: const TextStyle(color: Colors.white60)),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                            onPressed: () => _redeemPackage(context, package),
                            child: Text('\$${(package['priceUsd'] as double).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                      );
                    },
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

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(Icons.cell_tower, color: Colors.tealAccent),
                        title: Text(data['name'] ?? 'Data Pack', style: const TextStyle(color: Colors.white)),
                        subtitle: Text('Validity: ${data['validityDays'] ?? 7} Days', style: const TextStyle(color: Colors.white60)),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                          onPressed: () => _redeemPackage(context, {
                            'id': data['id'],
                            'priceUsd': (data['priceUsd'] ?? 0.0).toDouble(),
                          }),
                          child: Text('\$${(data['priceUsd'] ?? 0.0).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white)),
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
// QR SCANNER SCREEN
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
// TAB 2: EARN TASKS
// =============================================================================
class EarnTasksTab extends StatelessWidget {
  final String userId;

  const EarnTasksTab({super.key, required this.userId});

  void _showSubmissionModal(BuildContext context, Map<String, dynamic> task) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Task: ${task['platform']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 8),
            Text('Target Link: ${task['targetUrl']}', style: const TextStyle(color: Colors.tealAccent)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
              icon: const Icon(Icons.open_in_new, color: Colors.white),
              label: const Text('1. Open Link & Perform Action', style: TextStyle(color: Colors.white)),
              onPressed: () async {
                final Uri url = Uri.parse(task['targetUrl'] ?? '');
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.tealAccent),
              icon: const Icon(Icons.upload_file),
              label: const Text('2. Upload Screenshot Proof'),
              onPressed: () {},
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
              onPressed: () async {
                await FirebaseFirestore.instance.collection('task_submissions').add({
                  'taskId': task['id'],
                  'userId': userId,
                  'status': 'pending',
                  'submittedAt': FieldValue.serverTimestamp(),
                });

                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Proof submitted! Pending promoter approval.')),
                  );
                }
              },
              child: const Text('Submit for Review', style: TextStyle(color: Colors.white)),
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
        title: const Text('Earn Social Data'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('campaigns')
            .where('status', isEqualTo: 'active')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.tealAccent));
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text('No active campaigns available.', style: TextStyle(color: Colors.white54)),
            );
          }

          final campaigns = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(16.0),
            itemCount: campaigns.length,
            itemBuilder: (context, index) {
              final data = campaigns[index].data() as Map<String, dynamic>;
              data['id'] = campaigns[index].id;

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: Icon(
                    data['platform'] == 'Instagram' ? Icons.camera_alt : Icons.video_library,
                    color: Colors.tealAccent,
                  ),
                  title: Text('${data['platform']} - ${data['actionType'] ?? 'Task'}', style: const TextStyle(color: Colors.white)),
                  subtitle: Text(
                    'Earn: \$${((data['costPerUserUsd'] ?? 0.008) * 0.70).toStringAsFixed(3)} in Data',
                    style: const TextStyle(color: Colors.tealAccent),
                  ),
                  trailing: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                    onPressed: () => _showSubmissionModal(context, data),
                    child: const Text('Start Task', style: TextStyle(color: Colors.white)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// =============================================================================
// TAB 3: PROMOTE / CREATE CAMPAIGN (DYNAMIC FIRESTORE PRICING)
// =============================================================================
class PromoteTab extends StatefulWidget {
  final String userId;
  final double userBalanceUsd;

  const PromoteTab({super.key, required this.userId, required this.userBalanceUsd});

  @override
  State<PromoteTab> createState() => _PromoteTabState();
}

class _PromoteTabState extends State<PromoteTab> {
  final _formKey = GlobalKey<FormState>();
  String _selectedPlatform = 'Instagram';
  String _selectedAction = 'Followers';
  String _targetUrl = '';
  int _quantity = 2000;

  final List<String> _platforms = ['Instagram', 'Facebook', 'Twitter (X)', 'TikTok', 'YouTube'];
  final List<String> _actions = ['Followers', 'Likes', 'Comments', 'Views'];

  Future<void> _createCampaign(double ratePerUnit) async {
    final double totalCost = _quantity * ratePerUnit;
    final double appCommission = totalCost * 0.30;
    final double earnerPool = totalCost * 0.70;

    if (widget.userBalanceUsd < totalCost) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Insufficient balance (\$${widget.userBalanceUsd.toStringAsFixed(2)}). Please top up.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final userRef = FirebaseFirestore.instance.collection('users').doc(widget.userId);
    await userRef.update({
      'balanceUsd': FieldValue.increment(-totalCost),
    });

    await FirebaseFirestore.instance.collection('campaigns').add({
      'promoterId': widget.userId,
      'platform': _selectedPlatform,
      'actionType': _selectedAction,
      'targetUrl': _targetUrl,
      'quantity': _quantity,
      'ratePerUnit': ratePerUnit,
      'totalCost': totalCost,
      'appCommission': appCommission,
      'earnerPool': earnerPool,
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Campaign Published! Balance deducted.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('config').doc('pricing').snapshots(),
      builder: (context, snapshot) {
        double ratePerUnit = 0.008; // Default: $16 for 2000 units
        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          ratePerUnit = (data?['rate_per_unit'] as num?)?.toDouble() ?? 0.008;
        }

        final double totalCost = _quantity * ratePerUnit;
        final double appCommission = totalCost * 0.30;
        final double earnerPool = totalCost * 0.70;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Create Campaign'),
            backgroundColor: const Color(0xFF1E293B),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    value: _selectedPlatform,
                    dropdownColor: const Color(0xFF1E293B),
                    decoration: const InputDecoration(labelText: 'Select Platform', labelStyle: TextStyle(color: Colors.white70)),
                    items: _platforms.map((p) => DropdownMenuItem(value: p, child: Text(p, style: const TextStyle(color: Colors.white)))).toList(),
                    onChanged: (val) => setState(() => _selectedPlatform = val!),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _selectedAction,
                    dropdownColor: const Color(0xFF1E293B),
                    decoration: const InputDecoration(labelText: 'Interaction Type', labelStyle: TextStyle(color: Colors.white70)),
                    items: _actions.map((a) => DropdownMenuItem(value: a, child: Text(a, style: const TextStyle(color: Colors.white)))).toList(),
                    onChanged: (val) => setState(() => _selectedAction = val!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Target Post/Profile Link', labelStyle: TextStyle(color: Colors.white70)),
                    style: const TextStyle(color: Colors.white),
                    onChanged: (val) => _targetUrl = val,
                    validator: (val) => val == null || val.isEmpty ? 'Please enter a valid URL' : null,
                  ),
                  const SizedBox(height: 16),
                  Text('Quantity: $_quantity', style: const TextStyle(color: Colors.white70)),
                  Slider(
                    value: _quantity.toDouble(),
                    min: 100,
                    max: 10000,
                    divisions: 99,
                    activeColor: Colors.tealAccent,
                    label: '$_quantity',
                    onChanged: (val) => setState(() => _quantity = val.toInt()),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    color: const Color(0xFF1E293B),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            const Text('Total Campaign Budget:', style: TextStyle(color: Colors.white70)),
                            Text('\$${totalCost.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ]),
                          const Divider(color: Colors.white24),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            const Text('Earner Reward Pool (70%):', style: TextStyle(color: Colors.white70)),
                            Text('\$${earnerPool.toStringAsFixed(2)}', style: const TextStyle(color: Colors.tealAccent)),
                          ]),
                          const SizedBox(height: 4),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            const Text('Platform Fee (30%):', style: TextStyle(color: Colors.white70)),
                            Text('\$${appCommission.toStringAsFixed(2)}', style: const TextStyle(color: Colors.grey)),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: () {
                      if (_formKey.currentState!.validate()) {
                        _createCampaign(ratePerUnit);
                      }
                    },
                    child: const Text('Launch Campaign', style: TextStyle(color: Colors.white, fontSize: 16)),
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
