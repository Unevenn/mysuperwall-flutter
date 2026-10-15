import 'package:flutter/material.dart';
import 'package:mysuperwall_sdk/mysuperwall_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MySuperWallClient.initialize(
    appKey: 'YOUR_APP_KEY', // Dashboard > Settings > App Key
    // userId: 'user_123456', // If omitted, the SDK will auto-generate and cache an anonymous ID!
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MySuperWall Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool? _isHealthy;
  String _currentLocale = 'en';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MySuperWall SDK Test'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _checkHealth,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // SDK Health Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _isHealthy == true
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: _isHealthy == true ? Colors.green : Colors.red,
                    width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: _isHealthy == true ? Colors.green : Colors.red,
                        shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isHealthy == true
                        ? 'SDK Online'
                        : (_isHealthy == false
                            ? 'SDK Offline'
                            : 'Checking SDK...'),
                    style: TextStyle(
                        color: _isHealthy == true ? Colors.green : Colors.red,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            const Icon(Icons.star, size: 80, color: Colors.amber),
            const SizedBox(height: 20),
            const Text(
              'Unlock Premium Experience',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const Padding(
              padding: EdgeInsets.all(24.0),
              child: Text(
                'This example demonstrates how to integrate MySuperWall into your app with just a few lines of code.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 20),

            // Typical trigger points
            ElevatedButton(
              onPressed: () => _showPaywall('premium'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(200, 50)),
              child: const Text('Simulate App Launch'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _showPaywall('open_features'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(200, 50)),
              child: const Text('Open Feature Lock'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _showPaywall('settings_premium'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(200, 50)),
              child: const Text('Settings Upsell'),
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Test Locale: ',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _currentLocale,
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text('English (EN)')),
                    DropdownMenuItem(value: 'tr', child: Text('Turkish (TR)')),
                    DropdownMenuItem(value: 'de', child: Text('German (DE)')),
                    DropdownMenuItem(value: 'es', child: Text('Spanish (ES)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _currentLocale = val;
                      });
                      MySuperWallClient.instance.setLocale(val);
                      _prefetchPaywalls(); // Re-fetch paywall in the new language
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _checkHealth();
    // 3. Pre-load paywalls for instant display
    _prefetchPaywalls();
  }

  Future<void> _checkHealth() async {
    final status = await MySuperWallClient.instance.healthCheck();
    setState(() => _isHealthy = status);
  }

  Future<void> _prefetchPaywalls() async {
    try {
      await MySuperWallClient.instance.prefetchPaywall(
        triggerKey: 'Premium',
      );
      debugPrint('Prefetched Premium paywall into cache.');
    } catch (e) {
      debugPrint('Failed to prefetch: $e');
    }
  }

  void _showPaywall(String triggerKey) async {
    try {
      // 2. Trigger a paywall event
      final result = await MySuperWallClient.instance.handleTrigger(
        context,
        triggerKey: triggerKey,
        onPurchase: (productId) {
          // Handle successful purchase here using your choice of IAP provider
          debugPrint('Purchased product: $productId');
          _unlockPremiumFeatures();
        },
        onRestore: () {
          debugPrint('User requested restore purchases.');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Restoring purchases...')),
          );
        },
        onDismiss: () {
          debugPrint('Paywall dismissed by user.');
        },
      );

      if (!result.show) {
        debugPrint('No paywall configuration for this trigger or user.');
      }
    } catch (e) {
      debugPrint('Error triggering paywall: $e');
    }
  }

  void _unlockPremiumFeatures() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Features Unlocked!')),
    );
  }
}
