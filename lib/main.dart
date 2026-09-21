import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_tapjoy/flutter_tapjoy.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DataStreamApp());
}

class DataStreamApp extends StatelessWidget {
  const DataStreamApp({Super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DataStream',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Dark slate background
        cardColor: const Color(0xFF1E293B),
        useMaterial3: true,
      ),
      home: const MainNavigationScreen(userId: "user_12345"),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  final String userId;

  const MainNavigationScreen({Super.key, required this.userId});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  double _userBalanceUsd = 0.00;
  bool _isLoading = false;
  TJPlacement? _offerwallPlacement;

  // Mock Active Tasks for "Earn Tasks" Tab
  final List<Map<String, dynamic>> _activeTasks = [
    {
      'id': 'task_1',
      'platform': 'Instagram',
      'action': 'Follow Account',
      'url': 'https://instagram.com/example',
      'payoutUsd': 0.07, // 70% of 0.10 campaign cost
    },
    {
      'id': 'task_2',
      'platform': 'YouTube',
      'action': 'Like & Comment',
      'url': 'https://youtube.com/watch?v=example',
      'payoutUsd': 0.14, // 70% of 0.20 campaign cost
    },
  ];

  @override
  void initState() {
    super.initState();
    _initTapjoy();
    _fetchUserBalance();
  }

  // Initialize Tapjoy SDK
  void _initTapjoy() {
    TapJoyPlugin.shared.setConnectionResultHandler((connected) {
      if (connected) {
        debugPrint("Tapjoy Connected Successfully");
        TapJoyPlugin.shared.setUserID(userID: widget.userId);
        _loadOfferwallPlacement();
      } else {
        debugPrint("Tapjoy Connection Failed");
      }
    });

    TapJoyPlugin.shared.connect(
      androidApiKey: "YOUR_ANDROID_TAPJOY_SDK_KEY",
      iOSApiKey: "YOUR_IOS_TAPJOY_SDK_KEY",
      debug: true,
    );
  }

  void _loadOfferwallPlacement() {
    _offerwallPlacement = TJPlacement(name: "DataStream_Offerwall");
    _offerwallPlacement?.setHandler((event, error) {
      if (event == TJPlacementEvent.requestSuccess) {
        debugPrint("Placement content ready");
      }
    });
    TapJoyPlugin.shared.addPlacement(placement: _offerwallPlacement!);
  }

  void _showOfferwall() {
    if (_offerwallPlacement != null) {
      _offerwallPlacement!.showContent();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Offerwall loading... Please try again.')),
      );
    }
  }

  Future<void> _fetchUserBalance() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('https://your-backend-api.com/api/user/${widget.userId}/balance'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _userBalanceUsd = (data['balanceUsd'] as num).toDouble();
        });
      }
    } catch (e) {
      debugPrint("Error fetching balance: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      EsimStoreTab(
        userBalanceUsd: _userBalanceUsd,
        isLoading: _isLoading,
        onRefreshBalance: _fetchUserBalance,
        onShowOfferwall: _showOfferwall,
        userId: widget.userId,
      ),
      EarnTasksTab(
        tasks: _activeTasks,
        userId: widget.userId,
      ),
      PromoteTab(
        userId: widget.userId,
        onCampaignCreated: _fetchUserBalance,
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
  }
}

// =============================================================================
// TAB 1: ESIM STORE & WALLET HUB
// =============================================================================
class EsimStoreTab extends StatelessWidget {
  final double userBalanceUsd;
  final bool isLoading;
  final VoidCallback onRefreshBalance;
  final VoidCallback onShowOfferwall;
  final String userId;

  EsimStoreTab({
    Super.key,
    required this.userBalanceUsd,
    required this.isLoading,
    required this.onRefreshBalance,
    required this.onShowOfferwall,
    required this.userId,
  });

  final List<Map<String, dynamic>> _esimPackages = [
    {
      'id': 'kenya-1gb-7days',
      'title': 'Kenya 1 GB High-Speed Data',
      'validity': '7 Days',
      'priceUsd': 2.50,
    },
    {
      'id': 'global-3gb-30days',
      'title': 'Global 3 GB Roaming Data',
      'validity': '30 Days',
      'priceUsd': 6.00,
    },
  ];

  Future<void> _redeemPackage(BuildContext context, Map<String, dynamic> package) async {
    final double cost = package['priceUsd'];

    if (userBalanceUsd < cost) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Insufficient Data Credits', style: TextStyle(color: Colors.white)),
          content: Text(
            'You need \$${cost.toStringAsFixed(2)} to claim this plan. Complete social tasks or watch ads to top up.',
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

    // Call Backend API
    try {
      final response = await http.post(
        Uri.parse('https://your-backend-api.com/api/esim/redeem'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'packageId': package['id'],
          'packageCostUsd': cost,
        }),
      );

      final result = json.decode(response.body);

      if (response.statusCode == 200 && result['success'] == true) {
        onRefreshBalance();
        _showQrModal(context, result['esimDetails']['lpaString']);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] ?? 'Redemption failed')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error connecting to server.')),
      );
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
          IconButton(icon: const Icon(Icons.refresh), onPressed: onRefreshBalance)
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Wallet Card
                  Card(
                    color: const Color(0xFF0F766E),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        children: [
                          const Text('Data Credits Balance', style: TextStyle(color: Colors.white70, fontSize: 16)),
                          const SizedBox(height: 8),
                          Text('\$${userBalanceUsd.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.tealAccent,
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(45),
                            ),
                            icon: const Icon(Icons.bolt),
                            label: const Text('Stream Free Data (Tapjoy)', style: TextStyle(fontWeight: FontWeight.bold)),
                            onPressed: onShowOfferwall,
                          )
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  const Text('Available Data Packs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 12),

                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _esimPackages.length,
                    itemBuilder: (context, index) {
                      final package = _esimPackages[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: const Icon(Icons.cell_tower, color: Colors.tealAccent),
                          title: Text(package['title'], style: const TextStyle(color: Colors.white)),
                          subtitle: Text('Validity: ${package['validity']}', style: const TextStyle(color: Colors.white60)),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                            onPressed: () => _redeemPackage(context, package),
                            child: Text('\$${package['priceUsd'].toStringAsFixed(2)}', style: const TextStyle(color: Colors.white)),
                          ),
                        ),
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
// TAB 2: EARN TASKS (SOCIAL MEDIA JOBS)
// =============================================================================
class EarnTasksTab extends StatelessWidget {
  final List<Map<String, dynamic>> tasks;
  final String userId;

  const EarnTasksTab({Super.key, required this.tasks, required this.userId});

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
            Text('Task: ${task['action']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 8),
            Text('Platform: ${task['platform']}', style: const TextStyle(color: Colors.tealAccent)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
              icon: const Icon(Icons.open_in_new, color: Colors.white),
              label: const Text('1. Open Link & Perform Action', style: TextStyle(color: Colors.white)),
              onPressed: () {
                // Open URL in browser or app
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.tealAccent),
              icon: const Icon(Icons.upload_file),
              label: const Text('2. Upload Screenshot Proof'),
              onPressed: () {
                // Upload screenshot to Firebase Storage
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
              onPressed: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Proof submitted! Pending promoter approval.')),
                );
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
      body: ListView.builder(
        padding: const EdgeInsets.all(16.0),
        itemCount: tasks.length,
        itemBuilder: (context, index) {
          final task = tasks[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(
                task['platform'] == 'Instagram' ? Icons.camera_alt : Icons.video_library,
                color: Colors.tealAccent,
              ),
              title: Text('${task['action']} (${task['platform']})', style: const TextStyle(color: Colors.white)),
              subtitle: Text('Earn: \$${task['payoutUsd'].toStringAsFixed(2)} in Data', style: const TextStyle(color: Colors.tealAccent)),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: () => _showSubmissionModal(context, task),
                child: const Text('Start Task', style: TextStyle(color: Colors.white)),
              ),
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// TAB 3: PROMOTE / CREATE CAMPAIGN (30% / 70% SPLIT)
// =============================================================================
class PromoteTab extends StatefulWidget {
  final String userId;
  final VoidCallback onCampaignCreated;

  const PromoteTab({Super.key, required this.userId, required this.onCampaignCreated});

  @override
  State<PromoteTab> createState() => _PromoteTabState();
}

class _PromoteTabState extends State<PromoteTab> {
  final _formKey = GlobalKey<FormState>();
  String _selectedPlatform = 'Instagram';
  String _targetUrl = '';
  int _taskCap = 50; // Total users needed
  double _costPerUserUsd = 0.10; // Promoter pays 10 cents per user

  @override
  Widget build(BuildContext context) {
    final double totalCost = _taskCap * _costPerUserUsd;
    final double appCommission = totalCost * 0.30; // 30% Platform Fee
    final double earnerPool = totalCost * 0.70;    // 70% Distributed to Workers

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
                items: ['Instagram', 'TikTok', 'YouTube'].map((p) => DropdownMenuItem(value: p, child: Text(p, style: const TextStyle(color: Colors.white)))).toList(),
                onChanged: (val) => setState(() => _selectedPlatform = val!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Target Post/Profile Link', labelStyle: TextStyle(color: Colors.white70)),
                style: const TextStyle(color: Colors.white),
                onChanged: (val) => _targetUrl = val,
                validator: (val) => val == null || val.isEmpty ? 'Please enter a valid URL' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Task Cap (Number of Users Required)', labelStyle: TextStyle(color: Colors.white70)),
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                initialValue: '50',
                onChanged: (val) => setState(() => _taskCap = int.tryParse(val) ?? 0),
              ),
              const SizedBox(height: 24),

              // CAMPAIGN SUMMARY CARD
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Campaign Published! Funds reserved.')),
                    );
                    widget.onCampaignCreated();
                  }
                },
                child: const Text('Launch Campaign', style: TextStyle(color: Colors.white, fontSize: 16)),
              )
            ],
          ),
        ),
      ),
    );
  }
}
