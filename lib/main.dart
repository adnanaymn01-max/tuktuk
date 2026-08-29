// CUSTOMER + DRIVER AREA-TO-AREA HISTORY (من المنطقة -> إلى المنطقة)
// PERFORMANCE NOTE:
// flutter run = Debug mode وهو أبطأ بشكل واضح.
// قياس السرعة الحقيقي يكون بـ flutter run --release على جهاز فعلي.
//
// ============================================================
// TUKTUK PROFESSIONAL UI EDITION - PRO V2 DRIVER/CUSTOMER EXPERIENCE
// Google Maps + live ETA + smoother tracking + driver/customer ratings + cancel reasons + smart driver availability
// ============================================================

// ============================================================
// Google Maps + Google Places/Geocoding + road routing via OSRM
// Google Routes API is NOT called in this build, so there is no Routes 403.
// NOTE: router.project-osrm.org is suitable for testing/development.
// ============================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';


// ============================================================
// SUPABASE STORAGE
// ============================================================
// حط هنا القيمتين اللي حفظتهن من Supabase Connect.
// Publishable key آمن للاستخدام داخل تطبيق العميل مع سياسات RLS صحيحة.
// لا تحط Secret key أو service_role داخل التطبيق.
const String supabaseUrl = 'https://oseelwtwmqpgbdumhfgu.supabase.co';
const String supabasePublishableKey = 'sb_publishable_8nq5y2x4a5cV9biKnHM5kQ_pkP7ekR6';

bool get supabaseConfigured =>
    supabaseUrl.startsWith('https://') &&
    !supabaseUrl.contains('PASTE_') &&
    supabasePublishableKey.isNotEmpty &&
    !supabasePublishableKey.contains('PASTE_');


// ============================================================
// DRIVER REFERRAL / INVITE SETTINGS
// ============================================================
const int driverReferralRequiredRides = 3;
const int driverReferralRewardIqd = 1000;

String compactPlaceName(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';

  final parts = value
      .split(RegExp(r'[,،]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  bool isPlusCode(String v) =>
      RegExp(
        r'^[A-Z0-9]{4,}\+[A-Z0-9]{2,}$',
        caseSensitive: false,
      ).hasMatch(v);

  for (final part in parts) {
    if (isPlusCode(part)) continue;
    if (part == 'العراق' ||
        part == 'محافظة بغداد' ||
        part == 'بغداد') {
      continue;
    }
    return part;
  }

  return value;
}

bool placeNeedsAreaLookup(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return true;

  final first =
      value.split(RegExp(r'[,،]')).first.trim();

  final plusCode = RegExp(
    r'^[A-Z0-9]{4,}\+[A-Z0-9]{2,}$',
    caseSensitive: false,
  ).hasMatch(first);

  return plusCode ||
      value.contains('محافظة بغداد') ||
      value.endsWith('العراق');
}

Future<void> logoutUser(BuildContext context) async {
  await FcmService.removeCurrentSessionToken();

  final prefs = await SharedPreferences.getInstance();

  // نمسح كل بيانات الجلسة من الجهاز.
  await prefs.remove('session_role');
  await prefs.remove('session_user_id');

  await prefs.remove('customer_logged_in');
  await prefs.remove('customer_id');
  await prefs.remove('customer_phone');
  await prefs.remove('driver_logged_in');
  await prefs.remove('driver_id');
  await prefs.remove('driver_phone');

  if (!context.mounted) return;

  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => const RolePage(),
    ),
    (route) => false,
  );
}

Widget logoutListTile(BuildContext context) {
  return ListTile(
    leading: const Icon(
      Icons.logout_rounded,
      color: Colors.red,
    ),
    title: const Text(
      'تسجيل الخروج',
      style: TextStyle(
        color: Colors.red,
        fontWeight: FontWeight.bold,
      ),
    ),
    onTap: () async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تسجيل الخروج'),
              content: const Text(
                'متأكد تريد تسجل خروج من الحساب؟',
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, false),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () =>
                      Navigator.pop(dialogContext, true),
                  child: const Text('تسجيل الخروج'),
                ),
              ],
            ),
          );
        },
      );

      if (ok == true && context.mounted) {
        await logoutUser(context);
      }
    },
  );
}



final GlobalKey<NavigatorState> appNavigatorKey =
    GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // بالخلفية نهيّئ Firebase فقط.
}

class FcmService {
  static StreamSubscription<String>? _tokenSub;
  static StreamSubscription<RemoteMessage>? _openSub;
  static StreamSubscription<RemoteMessage>? _foregroundSub;

  // iOS can need a short moment after permission is granted before APNs
  // gives Firebase a device token. We never block login or show that
  // temporary state as an error to the user; we retry quietly in background.
  static Timer? _apnsRetryTimer;
  static int _apnsRetryAttempt = 0;
  static const int _maxApnsRetryAttempts = 12;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void _scheduleTokenRetry() {
    if (!_isIos || _apnsRetryAttempt >= _maxApnsRetryAttempts) return;
    if (_apnsRetryTimer?.isActive == true) return;

    _apnsRetryTimer = Timer(const Duration(seconds: 1), () {
      _apnsRetryTimer = null;
      _apnsRetryAttempt++;
      unawaited(syncCurrentSessionToken());
    });
  }

  static Future<String?> _getTokenSafely({
    bool scheduleRetry = true,
  }) async {
    try {
      if (_isIos) {
        final apnsToken = await FirebaseMessaging.instance.getAPNSToken();

        if (apnsToken == null || apnsToken.isEmpty) {
          if (scheduleRetry) _scheduleTokenRetry();
          return null;
        }
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) {
        if (scheduleRetry) _scheduleTokenRetry();
        return null;
      }

      _apnsRetryAttempt = 0;
      _apnsRetryTimer?.cancel();
      _apnsRetryTimer = null;
      return token;
    } catch (e) {
      // APNs/FCM may still be warming up on iOS. Keep the app smooth and
      // retry in the background instead of surfacing a technical error.
      debugPrint('FCM TOKEN WAIT: $e');
      if (scheduleRetry) _scheduleTokenRetry();
      return null;
    }
  }

  static Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    _tokenSub?.cancel();
    _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen(
      (_) {
        _apnsRetryAttempt = 0;
        unawaited(syncCurrentSessionToken());
      },
    );

    _openSub?.cancel();
    _openSub = FirebaseMessaging.onMessageOpenedApp.listen(
      _handleOpenedMessage,
    );

    _foregroundSub?.cancel();
    _foregroundSub = FirebaseMessaging.onMessage.listen(
      (message) {
        final context = appNavigatorKey.currentContext;
        if (context == null) return;

        final title = message.notification?.title ??
            stringValue(message.data['title']);
        final body = message.notification?.body ??
            stringValue(message.data['body']);

        if (title.isEmpty && body.isEmpty) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              title.isEmpty ? body : '$title\n$body',
            ),
          ),
        );
      },
    );

    // Existing sessions should get their token as soon as APNs is ready,
    // without delaying the first screen.
    unawaited(syncCurrentSessionToken());
  }

  static Future<void> syncCurrentSessionToken() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('session_role') ?? '';
    final userId = prefs.getString('session_user_id') ?? '';

    if (role.isEmpty || userId.isEmpty) return;

    await saveTokenForUser(
      role: role,
      userId: userId,
    );
  }

  static Future<void> saveTokenForUser({
    required String role,
    required String userId,
  }) async {
    if (role.isEmpty || userId.isEmpty) return;

    final token = await _getTokenSafely();
    if (token == null || token.isEmpty) return;

    final collection =
        role == 'driver' ? 'drivers' : 'customers';
    final oppositeCollection =
        role == 'driver' ? 'customers' : 'drivers';

    // نفس الجهاز ممكن يكون دخل سابقاً بحساب من النوع الثاني.
    // نشيل توكن هذا الجهاز من الطرف المقابل حتى الإشعار ما يرجع
    // لنفس الشخص بالغلط.
    try {
      final oldDocs = await FirebaseFirestore.instance
          .collection(oppositeCollection)
          .where('fcmTokens', arrayContains: token)
          .get();

      for (final oldDoc in oldDocs.docs) {
        await oldDoc.reference.set({
          'fcmTokens': FieldValue.arrayRemove([token]),
          'fcmUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (_) {}

    await FirebaseFirestore.instance
        .collection(collection)
        .doc(userId)
        .set({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'lastFcmToken': token,
      'fcmUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> removeCurrentSessionToken() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('session_role') ?? '';
    final userId = prefs.getString('session_user_id') ?? '';

    if (role.isEmpty || userId.isEmpty) return;

    final token = await _getTokenSafely(scheduleRetry: false);
    if (token == null || token.isEmpty) return;

    final collection =
        role == 'driver' ? 'drivers' : 'customers';

    try {
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(userId)
          .set({
        'fcmTokens': FieldValue.arrayRemove([token]),
        'fcmUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> handleInitialMessage() async {
    final message =
        await FirebaseMessaging.instance.getInitialMessage();
    if (message != null) {
      _handleOpenedMessage(message);
    }
  }

  static Future<void> _handleOpenedMessage(
    RemoteMessage message,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('session_role') ?? '';
    final userId = prefs.getString('session_user_id') ?? '';

    if (role.isEmpty || userId.isEmpty) return;

    final rideId = stringValue(message.data['rideId']);
    final type = stringValue(message.data['type']);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;

      // إذا الإشعار رسالة، نفتح المحادثة مباشرة.
      if (rideId.isNotEmpty && type == 'message') {
        navigator.push(
          MaterialPageRoute(
            builder: (_) => RideChatPage(
              rideId: rideId,
              senderRole: role,
            ),
          ),
        );
        return;
      }

      // إذا زبون وضغط على إشعار رحلة، نفتح تتبع الرحلة.
      if (rideId.isNotEmpty && role == 'customer') {
        navigator.push(
          MaterialPageRoute(
            builder: (_) => CustomerRideTrackingPage(
              rideId: rideId,
            ),
          ),
        );
        return;
      }

      // إذا سائق وضغط على إشعار رحلة مقبولة/جارية، نفتح الرحلة نفسها.
      if (rideId.isNotEmpty && role == 'driver') {
        try {
          final driverSnap = await FirebaseFirestore.instance
              .collection('drivers')
              .doc(userId)
              .get();

          final rideSnap = await FirebaseFirestore.instance
              .collection('ride_requests')
              .doc(rideId)
              .get();

          if (driverSnap.exists && rideSnap.exists) {
            final driverData = driverSnap.data()!;
            final rideData = rideSnap.data()!;
            final status = stringValue(rideData['status']);

            if (stringValue(rideData['driverId']) == userId &&
                (status == 'accepted' ||
                    status == 'arrived' ||
                    status == 'started')) {
              navigator.push(
                MaterialPageRoute(
                  builder: (_) => DriverActiveRidePage(
                    rideId: rideId,
                    driver: DriverProfile(
                      id: driverSnap.id,
                      name: stringValue(driverData['name']),
                      phone: stringValue(driverData['phone']),
                      active: driverData['active'] != false,
                      approvalStatus:
                          stringValue(driverData['approvalStatus']).isEmpty
                              ? 'approved'
                              : stringValue(driverData['approvalStatus']),
                      tuktukNumber:
                          stringValue(driverData['tuktukNumber']),
                      tuktukColor:
                          stringValue(driverData['tuktukColor']),
                      profilePhotoUrl:
                          stringValue(driverData['profilePhotoUrl']),
                      verified: driverData['verified'] == true,
                    ),
                  ),
                ),
              );
              return;
            }
          }
        } catch (_) {}
      }

      navigator.push(
        MaterialPageRoute(
          builder: (_) => AppNotificationsPage(
            role: role,
            userId: userId,
          ),
        ),
      );
    });
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint(
      'FLUTTER UI ERROR: ${details.exceptionAsString()}',
    );

    return const Material(
      color: Color(0xffF8F8F8),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'صار شي بسيط بالواجهة 💛\nجرّب ترجع للصفحة السابقة أو افتح التطبيق مرة ثانية.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  };

  runApp(const TuktukApp());
}

Future<void> _initializeCriticalServices() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // لا نوقف فتح التطبيق بانتظار إعدادات التسعيرة أو الإشعارات.
  // القيم الافتراضية موجودة، وأول تحديث من Firestore يطبق تلقائياً.
  unawaited(PricingSettingsService.start());
  unawaited(_initializeOptionalServices());
}

Future<void> _initializeOptionalServices() async {
  try {
    if (supabaseConfigured) {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabasePublishableKey,
      );
    }
  } catch (e) {
    debugPrint('SUPABASE INIT ERROR: $e');
  }

  try {
    await FcmService.initialize();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FcmService.handleInitialMessage();
    });
  } catch (e) {
    debugPrint('FCM INIT ERROR: $e');
  }
}


class TuktukApp extends StatelessWidget {
  const TuktukApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'تكتك',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: null,
        scaffoldBackgroundColor: const Color(0xffF6F7F9),
        visualDensity: VisualDensity.adaptivePlatformDensity,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffFFC107),
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          backgroundColor: Colors.white,
          foregroundColor: Color(0xff161616),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            color: Color(0xff161616),
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xffF5F6F8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(
              color: Color(0xffFFC107),
              width: 1.4,
            ),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: const Color(0xffFFC107),
            foregroundColor: const Color(0xff151515),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: AppBootstrapGate(),
      ),
    );
  }
}



class AppBootstrapGate extends StatefulWidget {
  const AppBootstrapGate({super.key});

  @override
  State<AppBootstrapGate> createState() =>
      _AppBootstrapGateState();
}

class _AppBootstrapGateState
    extends State<AppBootstrapGate> {
  late final Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = _initializeCriticalServices();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.done) {
          if (snapshot.hasError) {
            return _StartupProblemCard(
              onRetry: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) =>
                        const AppBootstrapGate(),
                  ),
                );
              },
            );
          }

          return const StartupGate();
        }

        return const _FastStartupScreen();
      },
    );
  }
}

class _FastStartupScreen extends StatelessWidget {
  const _FastStartupScreen();

  @override
  Widget build(BuildContext context) {
    // متعمد نخليها بيضاء وفارغة حتى ما تظهر شاشة ثانية
    // بعد الـ native splash. أول ما تجهز Firebase ينتقل التطبيق مباشرة.
    return const Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(),
    );
  }
}

class _StartupProblemCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _StartupProblemCard({
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffF7F7F7),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.wifi_off_rounded,
                    size: 48,
                    color: Color(0xffD69B00),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'ما قدرنا نجهّز التطبيق هسه 💛',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'تأكد من الإنترنت وجرّب مرة ثانية. بياناتك محفوظة وما راح يضيع شي.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black54,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: onRetry,
                      child: const Text(
                        'إعادة المحاولة',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// EXTERNAL PUSH - ONE SERVER FOR DRIVER + CUSTOMER
// ============================================================

class ExternalPushService {
  static Future<void> _send({
    required String token,
    required String title,
    required String body,
    Map<String, String> data = const {},
  }) async {
    if (!supabaseConfigured || token.trim().isEmpty) return;

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'send-notification',
        body: {
          'token': token.trim(),
          'title': title,
          'body': body,
          'data': data,
        },
      );

      debugPrint(
        'PUSH OK: ${response.status} $title',
      );
    } catch (e) {
      debugPrint('PUSH ERROR: $e');
    }
  }

  static List<String> _tokens(
    Map<String, dynamic> data,
  ) {
    final result = <String>{};

    final list = data['fcmTokens'];
    if (list is Iterable) {
      for (final item in list) {
        final token = item?.toString().trim() ?? '';
        if (token.isNotEmpty) result.add(token);
      }
    }

    final last = stringValue(data['lastFcmToken']).trim();
    if (last.isNotEmpty) result.add(last);

    return result.toList();
  }

  static Future<void> notifyDriversForNewRide({
    required String rideId,
    required double pickupLat,
    required double pickupLng,
    required int fare,
  }) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('drivers')
          .where('active', isEqualTo: true)
          .get();

      final candidates = <Map<String, dynamic>>[];

      for (final doc in snapshot.docs) {
        final data = doc.data();

        if (data['acceptingRides'] == false ||
            data['online'] == false) {
          continue;
        }

        final tokens = _tokens(data);
        if (tokens.isEmpty) continue;

        final driverLat = doubleValue(data['lat']);
        final driverLng = doubleValue(data['lng']);

        double km = 9999;

        if (driverLat != 0 && driverLng != 0) {
          km = Geolocator.distanceBetween(
                driverLat,
                driverLng,
                pickupLat,
                pickupLng,
              ) /
              1000;

          // بالبداية ننبّه أقرب السائقين فقط.
          if (km > 5) continue;
        }

        candidates.add({
          'tokens': tokens,
          'km': km,
        });
      }

      candidates.sort(
        (a, b) => (a['km'] as double)
            .compareTo(b['km'] as double),
      );

      final jobs = <Future<void>>[];

      // نقلل الإزعاج: أقرب 5 سائقين فقط ياخذون Push أولي.
      for (final candidate in candidates.take(5)) {
        final km = candidate['km'] as double;
        final tokens =
            (candidate['tokens'] as List).cast<String>();

        final distanceText = km >= 9000
            ? 'قريب منك'
            : '${km.toStringAsFixed(1)} كم';

        for (final token in tokens) {
          jobs.add(
            _send(
              token: token,
              title: 'طلب رحلة جديد 🛺',
              body: '$distanceText • الأجرة $fare د.ع',
              data: {
                'type': 'ride_request',
                'rideId': rideId,
                'targetRole': 'driver',
              },
            ),
          );
        }
      }

      if (jobs.isNotEmpty) {
        await Future.wait(jobs);
      } else {
        debugPrint(
          'PUSH DRIVER: no nearby online driver with FCM token',
        );
      }
    } catch (e) {
      debugPrint('PUSH DRIVER QUERY ERROR: $e');
    }
  }

  static Future<void> sendToUser({
    required String role,
    required String userId,
    required String title,
    required String body,
    Map<String, String> data = const {},
  }) async {
    if (userId.isEmpty) return;

    final collection =
        role == 'driver' ? 'drivers' : 'customers';

    try {
      final snap = await FirebaseFirestore.instance
          .collection(collection)
          .doc(userId)
          .get();

      if (!snap.exists) return;

      final tokens = _tokens(snap.data() ?? {});
      for (final token in tokens) {
        await _send(
          token: token,
          title: title,
          body: body,
          data: data,
        );
      }
    } catch (e) {
      debugPrint('PUSH USER ERROR: $e');
    }
  }
}


// ============================================================
// RIDE ACTIONS
// ============================================================

class RideActions {
  static Future<void> cancelRide({
    required String rideId,
    required String canceledBy,
    String cancelReason = '',
  }) async {
    final ref = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(rideId);

    String customerId = '';
    String driverId = '';

    await FirebaseFirestore.instance.runTransaction(
      (transaction) async {
        final snap = await transaction.get(ref);
        if (!snap.exists) return;

        final data = snap.data()!;
        final status = stringValue(data['status']);

        if (status == 'completed' || status == 'canceled') {
          return;
        }

        customerId = stringValue(data['customerId']);
        driverId = stringValue(data['driverId']);

        final rewardDiscount =
            intValue(data['rewardDiscount']);
        final rewardRefunded =
            data['rewardRefunded'] == true;

        transaction.update(ref, {
          'status': 'canceled',
          'canceledBy': canceledBy,
          'cancelReason': cancelReason.trim(),
          'canceledAt': FieldValue.serverTimestamp(),
          if (rewardDiscount > 0 && !rewardRefunded)
            'rewardRefunded': true,
          if (rewardDiscount > 0 && !rewardRefunded)
            'rewardRefundedAt':
                FieldValue.serverTimestamp(),
        });

        // إذا الزبون استخدم مكافأة وانلغت الرحلة، نرجعها كاملة.
        if (customerId.isNotEmpty &&
            rewardDiscount > 0 &&
            !rewardRefunded) {
          final customerRef = FirebaseFirestore.instance
              .collection('customers')
              .doc(customerId);

          final customerSnap =
              await transaction.get(customerRef);

          if (customerSnap.exists) {
            final oldCredit = intValue(
              customerSnap.data()?['rewardBalance'],
            );

            final newCredit =
                oldCredit + rewardDiscount;

            transaction.update(customerRef, {
              'rewardBalance': newCredit,
              'rewardUpdatedAt':
                  FieldValue.serverTimestamp(),
            });

            final refundRef =
                FirebaseFirestore.instance
                    .collection(
                      'customer_reward_transactions',
                    )
                    .doc();

            transaction.set(refundRef, {
              'customerId': customerId,
              'rideId': rideId,
              'type': 'ride_discount_refund',
              'amount': rewardDiscount,
              'creditBefore': oldCredit,
              'creditAfter': newCredit,
              'createdAt':
                  FieldValue.serverTimestamp(),
            });
          }
        }
      },
    );

    if (driverId.isNotEmpty) {
      final driverRef = FirebaseFirestore.instance
          .collection('drivers')
          .doc(driverId);

      await FirebaseFirestore.instance.runTransaction(
        (transaction) async {
          final driverSnap =
              await transaction.get(driverRef);

          if (!driverSnap.exists) return;

          final activeRideId =
              stringValue(driverSnap.data()?['activeRideId']);

          if (activeRideId == rideId) {
            transaction.update(driverRef, {
              'activeRideId': FieldValue.delete(),
              'activeRideStatus': FieldValue.delete(),
              'activeRideUpdatedAt':
                  FieldValue.serverTimestamp(),
            });
          }
        },
      );
    }

    if (canceledBy == 'driver' &&
        customerId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('app_notifications')
          .add({
        'targetType': 'customer',
        'targetId': customerId,
        'type': 'ride',
        'title': 'تم إلغاء الرحلة',
        'body':
            'السائق ألغى الرحلة. تگدر تطلب سائق ثاني، وإذا مستخدم مكافأة رجعت لرصيدك.',
        'rideId': rideId,
        'readBy': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });

      await ExternalPushService.sendToUser(
        role: 'customer',
        userId: customerId,
        title: 'تم إلغاء الرحلة',
        body:
            'السائق ألغى الرحلة. وإذا مستخدم مكافأة رجعت لرصيدك.',
        data: {
          'type': 'ride',
          'rideId': rideId,
          'status': 'canceled',
        },
      );
    }

    if (canceledBy == 'customer' &&
        driverId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('app_notifications')
          .add({
        'targetType': 'driver',
        'targetId': driverId,
        'type': 'ride',
        'title': 'تم إلغاء الرحلة',
        'body': 'الزبون ألغى الرحلة.',
        'rideId': rideId,
        'readBy': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });

      await ExternalPushService.sendToUser(
        role: 'driver',
        userId: driverId,
        title: 'تم إلغاء الرحلة',
        body: 'الزبون ألغى الرحلة.',
        data: {
          'type': 'ride',
          'rideId': rideId,
          'status': 'canceled',
        },
      );
    }
  }
}


Future<String?> showRideCancelReasonDialog(
  BuildContext context, {
  required bool isDriver,
}) async {
  final reasons = isDriver
      ? <String>[
          'الزبون ما موجود',
          'موقع الزبون غير واضح',
          'مشكلة بالتكتك',
          'الطريق مغلق',
          'سبب آخر',
        ]
      : <String>[
          'السائق بعيد',
          'تأخر السائق',
          'غيرت رأيي',
          'مشكلة بالموقع',
          'سبب آخر',
        ];

  final selected = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'سبب إلغاء الرحلة',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                ...reasons.map(
                  (reason) => ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    leading: const Icon(
                      Icons.radio_button_unchecked_rounded,
                    ),
                    title: Text(
                      reason,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () => Navigator.pop(
                      sheetContext,
                      reason,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  if (selected == null) return null;
  if (selected != 'سبب آخر') return selected;

  final controller = TextEditingController();
  final custom = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اكتب سبب الإلغاء'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'اكتب السبب باختصار',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext),
              child: const Text('رجوع'),
            ),
            ElevatedButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(dialogContext, value);
              },
              child: const Text('تأكيد'),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  return custom;
}

// ============================================================
// DISCOUNTS / REWARDS / INVITES
// ============================================================

class PromoResult {
  final String code;
  final int discount;
  final int finalPrice;

  const PromoResult({
    required this.code,
    required this.discount,
    required this.finalPrice,
  });
}

class PromoService {
  static Future<PromoResult> apply({
    required String rawCode,
    required int originalPrice,
    required String customerId,
  }) async {
    final code = rawCode.trim().toUpperCase();

    if (code.isEmpty) {
      throw Exception('أدخل كود الخصم');
    }

    final snap = await FirebaseFirestore.instance
        .collection('promo_codes')
        .doc(code)
        .get();

    if (!snap.exists) {
      throw Exception('كود الخصم غير صحيح');
    }

    final data = snap.data()!;

    if (data['active'] == false) {
      throw Exception('كود الخصم غير فعال');
    }

    final expiresAt = timestampToDate(data['expiresAt']);
    if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
      throw Exception('انتهت صلاحية الكود');
    }

    final minFare = intValue(data['minFare']);
    if (minFare > 0 && originalPrice < minFare) {
      throw Exception('الكروة أقل من الحد المطلوب للكود');
    }

    final usedBy = (data['usedBy'] is List)
        ? (data['usedBy'] as List).map((e) => e.toString()).toList()
        : <String>[];

    if (customerId.isNotEmpty && usedBy.contains(customerId)) {
      throw Exception('استخدمت هذا الكود سابقاً');
    }

    final type = stringValue(data['type']);
    final value = intValue(data['value']);
    final maxDiscount = intValue(data['maxDiscount']);

    int discount = 0;

    if (type == 'percent') {
      discount = ((originalPrice * value) / 100).round();
      if (maxDiscount > 0 && discount > maxDiscount) {
        discount = maxDiscount;
      }
    } else {
      discount = value;
    }

    if (discount < 0) discount = 0;
    if (discount > originalPrice) discount = originalPrice;

    return PromoResult(
      code: code,
      discount: discount,
      finalPrice: originalPrice - discount,
    );
  }

  static Future<void> markUsed({
    required String code,
    required String customerId,
  }) async {
    if (code.isEmpty || customerId.isEmpty) return;

    await FirebaseFirestore.instance
        .collection('promo_codes')
        .doc(code)
        .set({
      'usedBy': FieldValue.arrayUnion([customerId]),
      'lastUsedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}


class RewardService {
  static Future<String> claim({
    required String rewardId,
    required String role,
    required String userId,
  }) async {
    if (userId.isEmpty) {
      throw Exception('الحساب غير معروف');
    }

    final rewardRef = FirebaseFirestore.instance
        .collection('rewards')
        .doc(rewardId);

    final userCollection =
        role == 'driver' ? 'drivers' : 'customers';

    final userRef = FirebaseFirestore.instance
        .collection(userCollection)
        .doc(userId);

    final transactionRef = FirebaseFirestore.instance
        .collection(
          role == 'driver'
              ? 'driver_balance_transactions'
              : 'customer_reward_transactions',
        )
        .doc();

    String resultMessage = 'تم استلام المكافأة ✅';

    await FirebaseFirestore.instance.runTransaction(
      (transaction) async {
        final rewardSnap = await transaction.get(rewardRef);
        final userSnap = await transaction.get(userRef);

        if (!rewardSnap.exists || !userSnap.exists) {
          throw Exception('المكافأة أو الحساب غير موجود');
        }

        final reward = rewardSnap.data()!;
        final active = reward['active'] != false;

        if (!active) {
          throw Exception('المكافأة غير فعالة');
        }

        final targetRole = stringValue(reward['targetRole']);
        final targetId = stringValue(reward['targetId']);

        final roleAllowed =
            targetRole == 'all' || targetRole == role;

        final userAllowed =
            targetId.isEmpty || targetId == userId;

        if (!roleAllowed || !userAllowed) {
          throw Exception('هذه المكافأة مو مخصصة لهذا الحساب');
        }

        final claimedByRaw = reward['claimedBy'];
        final claimedBy = claimedByRaw is List
            ? claimedByRaw.map((e) => e.toString()).toList()
            : <String>[];

        if (claimedBy.contains(userId)) {
          throw Exception('استلمت هذه المكافأة سابقاً');
        }

        final type = stringValue(reward['type']);
        final value = intValue(reward['value']);

        if (value <= 0) {
          throw Exception('قيمة المكافأة غير صحيحة');
        }

        if (role == 'driver') {
          final oldBalance =
              intValue(userSnap.data()?['balance']);
          final newBalance = oldBalance + value;

          transaction.update(userRef, {
            'balance': newBalance,
            'balanceUpdatedAt': FieldValue.serverTimestamp(),
          });

          transaction.set(transactionRef, {
            'driverId': userId,
            'type': 'reward',
            'amount': value,
            'balanceBefore': oldBalance,
            'balanceAfter': newBalance,
            'rewardId': rewardId,
            'createdAt': FieldValue.serverTimestamp(),
          });

          resultMessage =
              'تمت إضافة $value د.ع إلى رصيد السائق ✅';
        } else {
          // للزبون تتحول المكافأة إلى رصيد خصم يستخدم بالرحلات.
          final oldCredit =
              intValue(userSnap.data()?['rewardBalance']);
          final newCredit = oldCredit + value;

          transaction.update(userRef, {
            'rewardBalance': newCredit,
            'rewardUpdatedAt': FieldValue.serverTimestamp(),
          });

          transaction.set(transactionRef, {
            'customerId': userId,
            'type': 'reward_credit',
            'amount': value,
            'creditBefore': oldCredit,
            'creditAfter': newCredit,
            'rewardId': rewardId,
            'createdAt': FieldValue.serverTimestamp(),
          });

          resultMessage =
              'تمت إضافة $value د.ع إلى مكافآت رحلاتك ✅';
        }

        transaction.update(rewardRef, {
          'claimedBy': FieldValue.arrayUnion([userId]),
          'lastClaimedAt': FieldValue.serverTimestamp(),
        });
      },
    );

    return resultMessage;
  }
}

class RewardsPage extends StatelessWidget {
  final String role;
  final String userId;

  const RewardsPage({
    super.key,
    required this.role,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المكافآت والتخفيضات'),
        ),
        body: Column(
          children: [
            if (role == 'customer' && userId.isNotEmpty)
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('customers')
                    .doc(userId)
                    .snapshots(),
                builder: (context, customerSnapshot) {
                  final balance = intValue(
                    customerSnapshot.data?.data()?['rewardBalance'],
                  );

                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xffFFF5CC),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Color(0xffFFC21A),
                          child: Icon(
                            Icons.savings_rounded,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'رصيد مكافآتك',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'تقدر تستخدمه على الرحلة ويقلل الكروة حتى أقل من الحد الأدنى.',
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '$balance د.ع',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('rewards')
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            final docs = snapshot.data!.docs.where((doc) {
              final data =
                  doc.data() as Map<String, dynamic>;

              final targetRole =
                  stringValue(data['targetRole']);
              final targetId =
                  stringValue(data['targetId']);
              final active = data['active'] != false;

              if (!active) return false;

              final roleAllowed =
                  targetRole == 'all' ||
                  targetRole == role;

              final userAllowed =
                  targetId.isEmpty ||
                  targetId == userId;

              return roleAllowed && userAllowed;
            }).toList();

            if (docs.isEmpty) {
              return const Center(
                child: Text(
                  'ماكو مكافآت حالياً',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data =
                    doc.data() as Map<String, dynamic>;

                final claimedRaw = data['claimedBy'];
                final claimed = claimedRaw is List
                    ? claimedRaw
                        .map((e) => e.toString())
                        .contains(userId)
                    : false;

                final value = intValue(data['value']);

                return Card(
                  margin: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor:
                                  Color(0xffFFF3C4),
                              child: Icon(
                                Icons.card_giftcard_rounded,
                                color: Colors.black,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    stringValue(
                                              data['title'],
                                            )
                                            .isEmpty
                                        ? 'مكافأة'
                                        : stringValue(
                                            data['title'],
                                          ),
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight:
                                          FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    stringValue(
                                      data['description'],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (value > 0) ...[
                          const SizedBox(height: 12),
                          Text(
                            '$value د.ع',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: Colors.green,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: claimed
                                ? null
                                : () async {
                                    try {
                                      final message =
                                          await RewardService.claim(
                                        rewardId: doc.id,
                                        role: role,
                                        userId: userId,
                                      );

                                      if (!context.mounted) {
                                        return;
                                      }

                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          backgroundColor:
                                              Colors.green,
                                          content:
                                              Text(message),
                                        ),
                                      );
                                    } catch (e) {
                                      if (!context.mounted) {
                                        return;
                                      }

                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            e
                                                .toString()
                                                .replaceFirst(
                                                  'Exception: ',
                                                  '',
                                                ),
                                          ),
                                        ),
                                      );
                                    }
                                  },
                            icon: Icon(
                              claimed
                                  ? Icons.check_rounded
                                  : Icons
                                      .redeem_rounded,
                            ),
                            label: Text(
                              claimed
                                  ? 'تم الاستلام'
                                  : 'استلام المكافأة',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
            ),
          ],
        ),
      ),
    );
  }
}


class DriverReferralService {
  static String buildInviteCode(
    String driverId,
  ) {
    final clean = driverId
        .replaceAll(
          RegExp(r'[^A-Za-z0-9]'),
          '',
        )
        .toUpperCase();

    final suffix =
        clean.length > 6
            ? clean.substring(
                clean.length - 6,
              )
            : clean;

    return 'DRV$suffix';
  }

  static Future<String>
      ensureInviteCode(
    String driverId,
  ) async {
    final ref = FirebaseFirestore
        .instance
        .collection('drivers')
        .doc(driverId);

    final snap = await ref.get();

    if (!snap.exists) return '';

    final current = stringValue(
      snap.data()?['inviteCode'],
    ).trim();

    if (current.isNotEmpty) {
      return current;
    }

    final code =
        buildInviteCode(driverId);

    await ref.set({
      'inviteCode': code,
      'inviteCodeUpdatedAt':
          FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return code;
  }

  static Future<String>
      findInviterIdByCode(
    String rawCode,
  ) async {
    final code =
        rawCode.trim().toUpperCase();

    if (code.isEmpty) return '';

    final snap = await FirebaseFirestore
        .instance
        .collection('drivers')
        .where(
          'inviteCode',
          isEqualTo: code,
        )
        .limit(1)
        .get();

    if (snap.docs.isEmpty) {
      throw Exception(
        'كود الدعوة غير صحيح',
      );
    }

    return snap.docs.first.id;
  }

  static Future<void>
      createPendingReferral({
    required String inviterDriverId,
    required String referredDriverId,
    required String code,
  }) async {
    if (inviterDriverId.isEmpty ||
        referredDriverId.isEmpty ||
        inviterDriverId ==
            referredDriverId) {
      return;
    }

    await FirebaseFirestore.instance
        .collection('driver_referrals')
        .doc(referredDriverId)
        .set({
      'inviterDriverId':
          inviterDriverId,
      'referredDriverId':
          referredDriverId,
      'code':
          code.trim().toUpperCase(),
      'requiredRides':
          driverReferralRequiredRides,
      'rewardAmount':
          driverReferralRewardIqd,
      'completedRides': 0,
      'status': 'pending',
      'createdAt':
          FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void>
      recordCompletedRide({
    required String rideId,
    required String referredDriverId,
  }) async {
    final referralRef =
        FirebaseFirestore.instance
            .collection(
              'driver_referrals',
            )
            .doc(referredDriverId);

    final rideRef =
        FirebaseFirestore.instance
            .collection(
              'ride_requests',
            )
            .doc(rideId);

    final rewardTxRef =
        FirebaseFirestore.instance
            .collection(
              'driver_balance_transactions',
            )
            .doc();

    String rewardedInviterId = '';

    await FirebaseFirestore.instance
        .runTransaction(
      (transaction) async {
        final rideSnap =
            await transaction.get(
          rideRef,
        );

        if (!rideSnap.exists) return;

        final rideData =
            rideSnap.data()!;

        if (rideData[
                'referralRideCounted'] ==
            true) {
          return;
        }

        final referralSnap =
            await transaction.get(
          referralRef,
        );

        if (!referralSnap.exists) {
          return;
        }

        final referral =
            referralSnap.data()!;

        final status =
            stringValue(
          referral['status'],
        );

        if (status == 'rewarded' ||
            status == 'canceled') {
          transaction.update(
            rideRef,
            {
              'referralRideCounted':
                  true,
            },
          );
          return;
        }

        final inviterId =
            stringValue(
          referral[
              'inviterDriverId'],
        );

        if (inviterId.isEmpty) {
          return;
        }

        final inviterRef =
            FirebaseFirestore
                .instance
                .collection('drivers')
                .doc(inviterId);

        final inviterSnap =
            await transaction.get(
          inviterRef,
        );

        if (!inviterSnap.exists) {
          return;
        }

        final savedRequired =
            intValue(
          referral[
              'requiredRides'],
        );

        final savedReward =
            intValue(
          referral[
              'rewardAmount'],
        );

        final required =
            savedRequired > 0
                ? savedRequired
                : driverReferralRequiredRides;

        final reward =
            savedReward > 0
                ? savedReward
                : driverReferralRewardIqd;

        final newCompleted =
            intValue(
                  referral[
                      'completedRides'],
                ) +
                1;

        transaction.update(
          rideRef,
          {
            'referralRideCounted':
                true,
          },
        );

        if (newCompleted >=
            required) {
          final oldBalance =
              intValue(
            inviterSnap
                .data()?['balance'],
          );

          final newBalance =
              oldBalance + reward;

          transaction.update(
            inviterRef,
            {
              'balance': newBalance,
              'balanceUpdatedAt':
                  FieldValue
                      .serverTimestamp(),
            },
          );

          transaction.update(
            referralRef,
            {
              'completedRides':
                  newCompleted,
              'status': 'rewarded',
              'rewardedAt':
                  FieldValue
                      .serverTimestamp(),
            },
          );

          transaction.set(
            rewardTxRef,
            {
              'driverId': inviterId,
              'type':
                  'referral_reward',
              'amount': reward,
              'balanceBefore':
                  oldBalance,
              'balanceAfter':
                  newBalance,
              'referredDriverId':
                  referredDriverId,
              'rideId': rideId,
              'createdAt':
                  FieldValue
                      .serverTimestamp(),
            },
          );

          rewardedInviterId =
              inviterId;
        } else {
          transaction.update(
            referralRef,
            {
              'completedRides':
                  newCompleted,
              'updatedAt':
                  FieldValue
                      .serverTimestamp(),
            },
          );
        }
      },
    );

    if (rewardedInviterId
        .isNotEmpty) {
      await FirebaseFirestore.instance
          .collection(
            'app_notifications',
          )
          .add({
        'targetType': 'driver',
        'targetId':
            rewardedInviterId,
        'type': 'reward',
        'title':
            'وصلتك مكافأة دعوة 🎁',
        'body':
            'صديقك كمل $driverReferralRequiredRides رحلات. تمت إضافة $driverReferralRewardIqd د.ع إلى رصيدك.',
        'readBy': <String>[],
        'createdAt':
            FieldValue
                .serverTimestamp(),
      });

      await ExternalPushService
          .sendToUser(
        role: 'driver',
        userId:
            rewardedInviterId,
        title:
            'وصلتك مكافأة دعوة 🎁',
        body:
            'تمت إضافة $driverReferralRewardIqd د.ع إلى رصيدك.',
        data: const {
          'type': 'reward',
        },
      );
    }
  }
}

class DriverInviteFriendsPage
    extends StatefulWidget {
  final String driverId;
  final String driverName;

  const DriverInviteFriendsPage({
    super.key,
    required this.driverId,
    required this.driverName,
  });

  @override
  State<DriverInviteFriendsPage>
      createState() =>
          _DriverInviteFriendsPageState();
}

class _DriverInviteFriendsPageState
    extends State<DriverInviteFriendsPage> {
  String _code = '';
  int _pending = 0;
  int _rewarded = 0;
  bool _loading = true;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final code =
          await DriverReferralService
              .ensureInviteCode(
        widget.driverId,
      );

      final referrals =
          await FirebaseFirestore
              .instance
              .collection(
                'driver_referrals',
              )
              .where(
                'inviterDriverId',
                isEqualTo:
                    widget.driverId,
              )
              .get();

      int pending = 0;
      int rewarded = 0;

      for (final doc
          in referrals.docs) {
        final status =
            stringValue(
          doc.data()['status'],
        );

        if (status ==
            'rewarded') {
          rewarded++;
        } else {
          pending++;
        }
      }

      if (!mounted) return;

      setState(() {
        _code = code;
        _pending = pending;
        _rewarded = rewarded;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void>
      _shareWhatsApp() async {
    if (_sharing) return;

    setState(() {
      _sharing = true;
    });

    try {
      var code = _code;

      if (code.isEmpty) {
        code =
            await DriverReferralService
                .ensureInviteCode(
          widget.driverId,
        );
      }

      if (code.isEmpty) {
        throw Exception(
          'تعذر إنشاء كود الدعوة',
        );
      }

      final name =
          widget.driverName.trim();

      final message =
          'هلا 👋 ${name.isEmpty ? '' : 'أنا $name وأدعوك '}'
          'تسجل كسائق بتطبيق تكتك. '
          'وقت التسجيل اكتب كود الدعوة: $code\n'
          'بعد ما تكمل $driverReferralRequiredRides رحلات، '
          'تنحسب مكافأة الدعوة 🎁';

      final uri = Uri.parse(
        'https://wa.me/?text=${Uri.encodeComponent(message)}',
      );

      final opened =
          await launchUrl(
        uri,
        mode: LaunchMode
            .externalApplication,
      );

      if (!opened) {
        throw Exception(
          'تعذر فتح واتساب',
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            e
                .toString()
                .replaceFirst(
                  'Exception: ',
                  '',
                ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
        });
      }
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Directionality(
      textDirection:
          TextDirection.rtl,
      child: Scaffold(
        backgroundColor:
            const Color(
          0xffF6F7F9,
        ),
        appBar: AppBar(
          title: const Text(
            'دعوة الأصدقاء',
          ),
        ),
        body: _loading
            ? const Center(
                child:
                    CircularProgressIndicator(),
              )
            : ListView(
                padding:
                    const EdgeInsets.all(
                  18,
                ),
                children: [
                  Container(
                    padding:
                        const EdgeInsets.all(
                      22,
                    ),
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.white,
                      borderRadius:
                          BorderRadius
                              .circular(
                        24,
                      ),
                    ),
                    child: Column(
                      children: [
                        const CircleAvatar(
                          radius: 34,
                          backgroundColor:
                              Color(
                            0xffFFF3C4,
                          ),
                          child: Icon(
                            Icons
                                .card_giftcard_rounded,
                            size: 36,
                            color:
                                Color(
                              0xffA97400,
                            ),
                          ),
                        ),
                        const SizedBox(
                          height: 14,
                        ),
                        const Text(
                          'ادعُ صديق واربح',
                          style:
                              TextStyle(
                            fontSize: 22,
                            fontWeight:
                                FontWeight
                                    .w900,
                          ),
                        ),
                        const SizedBox(
                          height: 8,
                        ),
                        Text(
                          'إذا سجل صديقك بكودك وكمل '
                          '$driverReferralRequiredRides رحلات، '
                          'يضاف إلى رصيدك $driverReferralRewardIqd د.ع.',
                          textAlign:
                              TextAlign
                                  .center,
                          style:
                              const TextStyle(
                            color:
                                Colors
                                    .black54,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(
                          height: 20,
                        ),
                        Container(
                          width:
                              double
                                  .infinity,
                          padding:
                              const EdgeInsets
                                  .all(
                            16,
                          ),
                          decoration:
                              BoxDecoration(
                            color:
                                const Color(
                              0xffFFF8DE,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              16,
                            ),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                'كود دعوتك',
                                style:
                                    TextStyle(
                                  color:
                                      Colors
                                          .black54,
                                  fontWeight:
                                      FontWeight
                                          .w700,
                                ),
                              ),
                              const SizedBox(
                                height:
                                    5,
                              ),
                              SelectableText(
                                _code,
                                textAlign:
                                    TextAlign
                                        .center,
                                style:
                                    const TextStyle(
                                  fontSize:
                                      28,
                                  fontWeight:
                                      FontWeight
                                          .w900,
                                  letterSpacing:
                                      2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        SizedBox(
                          width:
                              double
                                  .infinity,
                          height: 56,
                          child:
                              ElevatedButton
                                  .icon(
                            onPressed:
                                _sharing
                                    ? null
                                    : _shareWhatsApp,
                            icon:
                                const Icon(
                              Icons
                                  .send_rounded,
                            ),
                            label: Text(
                              _sharing
                                  ? 'جاري فتح واتساب...'
                                  : 'إرسال الدعوة عبر واتساب',
                              style:
                                  const TextStyle(
                                fontSize:
                                    16,
                                fontWeight:
                                    FontWeight
                                        .w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    height: 14,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _stat(
                          'بانتظار الإكمال',
                          _pending,
                        ),
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      Expanded(
                        child: _stat(
                          'مكافآت مكتملة',
                          _rewarded,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _stat(
    String title,
    int value,
  ) {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        vertical: 18,
        horizontal: 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style:
                const TextStyle(
              fontSize: 24,
              fontWeight:
                  FontWeight.w900,
            ),
          ),
          const SizedBox(
            height: 4,
          ),
          Text(
            title,
            textAlign:
                TextAlign.center,
            style:
                const TextStyle(
              color:
                  Colors.black54,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}


class InviteFriendsPage extends StatefulWidget {
  final String customerId;

  const InviteFriendsPage({
    super.key,
    required this.customerId,
  });

  @override
  State<InviteFriendsPage> createState() =>
      _InviteFriendsPageState();
}

class _InviteFriendsPageState extends State<InviteFriendsPage> {
  String _code = '';
  int _invites = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ref = FirebaseFirestore.instance
        .collection('customers')
        .doc(widget.customerId);

    final snap = await ref.get();
    final data = snap.data() ?? {};

    String code = stringValue(data['inviteCode']);

    if (code.isEmpty) {
      final suffix = widget.customerId
          .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
          .toUpperCase();
      code = 'TUK${suffix.length > 6 ? suffix.substring(0, 6) : suffix}';

      await ref.set({
        'inviteCode': code,
      }, SetOptions(merge: true));
    }

    final inviteSnap = await FirebaseFirestore.instance
        .collection('customer_invites')
        .where('inviterId', isEqualTo: widget.customerId)
        .get();

    if (!mounted) return;

    setState(() {
      _code = code;
      _invites = inviteSnap.docs.length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('دعوة الأصدقاء'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  const Icon(
                    Icons.card_giftcard_rounded,
                    size: 80,
                    color: Color(0xffFFC107),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'كود دعوتك',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    _code,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.people_rounded),
                      title: const Text('عدد الدعوات'),
                      trailing: Text(
                        '$_invites',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'شارك الكود ويا أصدقائك. المدير يحدد مكافأة الدعوة والخصم من لوحة الإدارة.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black54,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ============================================================
// HELPERS / MODELS
// ============================================================

class DriverProfile {
  final String id;
  final String name;
  final String phone;
  final bool active;
  final String approvalStatus;
  final String tuktukNumber;
  final String tuktukColor;
  final String profilePhotoUrl;
  final bool verified;

  const DriverProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.active,
    this.approvalStatus = 'approved',
    this.tuktukNumber = '',
    this.tuktukColor = '',
    this.profilePhotoUrl = '',
    this.verified = false,
  });
}

class SavedPlace {
  final String name;
  final double lat;
  final double lng;

  const SavedPlace({
    required this.name,
    required this.lat,
    required this.lng,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'lat': lat,
        'lng': lng,
      };

  factory SavedPlace.fromMap(Map<String, dynamic> map) {
    return SavedPlace(
      name: map['name']?.toString() ?? '',
      lat: (map['lat'] as num).toDouble(),
      lng: (map['lng'] as num).toDouble(),
    );
  }
}

// ============================================================
// GOOGLE MAPS WEB SERVICES
// ============================================================
// ضع هنا API key 2 فقط (المفتاح الثاني لخدمات الويب).
// المفتاح الأول يبقى داخل AndroidManifest.xml لتشغيل Google Maps.
// API key 2 لازم يسمح بـ Routes API + Places API (New) + Geocoding API.
// لا ترسل المفتاح لأي شخص.
const String googleWebApiKey = 'AIzaSyDUZKuNmmfqcZvVIB3k9lIaScyUT2JMGPs';

// تشخيص آمن: لا يطبع المفتاح كامل، فقط آخر 4 رموز حتى نتأكد
// أن التطبيق فعلاً يستخدم API key 2 وليس مفتاح Android القديم.
String get googleWebApiKeyDiagnostic {
  if (googleWebApiKey.isEmpty ||
      googleWebApiKey == 'PASTE_API_KEY_2_HERE') {
    return 'API key 2 غير مضاف';
  }

  final tail = googleWebApiKey.length >= 4
      ? googleWebApiKey.substring(googleWebApiKey.length - 4)
      : 'قصير';

  return 'API key 2 مستخدم • آخر 4: $tail';
}

class PlaceResult {
  final String placeId;
  final String displayName;
  final String secondaryText;
  final double? lat;
  final double? lng;

  const PlaceResult({
    required this.placeId,
    required this.displayName,
    this.secondaryText = '',
    this.lat,
    this.lng,
  });
}

class GoogleRouteResult {
  final int distanceMeters;
  final String duration;
  final String encodedPolyline;
  final List<LatLng> points;

  const GoogleRouteResult({
    required this.distanceMeters,
    required this.duration,
    required this.encodedPolyline,
    required this.points,
  });
}

class GoogleMapsService {
  static bool get isConfigured =>
      googleWebApiKey.isNotEmpty &&
      googleWebApiKey != 'PASTE_API_KEY_2_HERE';

  static Future<String> reverseGeocode(LatLng point) async {
    _ensureConfigured();

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'latlng': '${point.latitude},${point.longitude}',
        'language': 'ar',
        'region': 'iq',
        'key': googleWebApiKey,
      },
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Geocoding HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status']?.toString() ?? '';

    if (status != 'OK') {
      if (status == 'ZERO_RESULTS') return '';
      throw Exception(data['error_message']?.toString() ?? status);
    }

    final results = (data['results'] as List<dynamic>? ?? []);
    if (results.isEmpty) return '';

    return results.first['formatted_address']?.toString() ?? '';
  }

  static Future<String> reverseGeocodeArea(
    LatLng point,
  ) async {
    _ensureConfigured();

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      {
        'latlng':
            '${point.latitude},${point.longitude}',
        'language': 'ar',
        'region': 'iq',
        'key': googleWebApiKey,
      },
    );

    try {
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 4),
          );

      if (response.statusCode != 200) {
        return '';
      }

      final data =
          jsonDecode(response.body)
              as Map<String, dynamic>;

      if (stringValue(data['status']) !=
          'OK') {
        return '';
      }

      final results =
          data['results']
                  as List<dynamic>? ??
              const [];

      const wantedTypes = <String>[
        'neighborhood',
        'sublocality_level_1',
        'sublocality',
        'locality',
        'administrative_area_level_3',
      ];

      for (final rawResult
          in results.take(8)) {
        if (rawResult
            is! Map<String, dynamic>) {
          continue;
        }

        final components =
            rawResult[
                    'address_components']
                as List<dynamic>? ??
            const [];

        for (final wanted
            in wantedTypes) {
          for (final rawComponent
              in components) {
            if (rawComponent
                is! Map<String, dynamic>) {
              continue;
            }

            final types = (rawComponent[
                        'types']
                    as List<dynamic>? ??
                const [])
                .map(
                  (e) => e.toString(),
                )
                .toList();

            if (!types.contains(wanted)) {
              continue;
            }

            final name = stringValue(
              rawComponent['long_name'],
            ).trim();

            if (name.isNotEmpty &&
                name != 'بغداد' &&
                name !=
                    'محافظة بغداد' &&
                name != 'العراق') {
              return name;
            }
          }
        }
      }

      for (final rawResult
          in results.take(4)) {
        if (rawResult
            is! Map<String, dynamic>) {
          continue;
        }

        final cleaned =
            compactPlaceName(
          stringValue(
            rawResult[
                'formatted_address'],
          ),
        );

        if (cleaned.isNotEmpty) {
          return cleaned;
        }
      }
    } catch (_) {}

    return '';
  }

  static Future<List<PlaceResult>> autocomplete(
    String input, {
    LatLng? center,
  }) async {
    _ensureConfigured();

    final body = <String, dynamic>{
      'input': input.trim(),
      'includedRegionCodes': ['iq'],
      'languageCode': 'ar',
    };

    if (center != null) {
      body['locationBias'] = {
        'circle': {
          'center': {
            'latitude': center.latitude,
            'longitude': center.longitude,
          },
          'radius': 50000.0,
        },
      };
    }

    final response = await http.post(
      Uri.parse(
        'https://places.googleapis.com/v1/places:autocomplete',
      ),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': googleWebApiKey,
        'X-Goog-FieldMask':
            'suggestions.placePrediction.placeId,'
            'suggestions.placePrediction.text.text,'
            'suggestions.placePrediction.structuredFormat.mainText.text,'
            'suggestions.placePrediction.structuredFormat.secondaryText.text',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('Places HTTP ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final suggestions = data['suggestions'] as List<dynamic>? ?? [];
    final results = <PlaceResult>[];

    for (final raw in suggestions) {
      if (raw is! Map<String, dynamic>) continue;
      final prediction = raw['placePrediction'];
      if (prediction is! Map<String, dynamic>) continue;

      final placeId = prediction['placeId']?.toString() ?? '';
      if (placeId.isEmpty) continue;

      final text = prediction['text'];
      final structured = prediction['structuredFormat'];

      String displayName = '';
      String secondary = '';

      if (structured is Map<String, dynamic>) {
        final mainText = structured['mainText'];
        final secondaryText = structured['secondaryText'];

        if (mainText is Map<String, dynamic>) {
          displayName = mainText['text']?.toString() ?? '';
        }

        if (secondaryText is Map<String, dynamic>) {
          secondary = secondaryText['text']?.toString() ?? '';
        }
      }

      if (displayName.isEmpty && text is Map<String, dynamic>) {
        displayName = text['text']?.toString() ?? '';
      }

      results.add(
        PlaceResult(
          placeId: placeId,
          displayName: displayName,
          secondaryText: secondary,
        ),
      );
    }

    return results;
  }


  static Future<List<PlaceResult>> searchPlaces(
    String input, {
    LatLng? center,
  }) async {
    final query = input.trim();
    if (query.length < 2) return [];

    // First try Places Autocomplete (New).
    try {
      final places = await autocomplete(
        query,
        center: center,
      );
      if (places.isNotEmpty) return places;
    } catch (_) {
      // Fall through to Geocoding search.
    }

    // Fallback: Geocoding search. This keeps the map search usable
    // even when Places API (New) is not enabled for the key.
    final params = <String, String>{
      'address': query,
      'language': 'ar',
      'region': 'iq',
      'components': 'country:IQ',
      'key': googleWebApiKey,
    };

    if (center != null) {
      params['bounds'] =
          '${center.latitude - 0.7},${center.longitude - 0.7}|'
          '${center.latitude + 0.7},${center.longitude + 0.7}';
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/geocode/json',
      params,
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception(
        'Search HTTP ${response.statusCode}',
      );
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;
    final status = data['status']?.toString() ?? '';

    if (status == 'ZERO_RESULTS') return [];

    if (status != 'OK') {
      throw Exception(
        data['error_message']?.toString() ?? status,
      );
    }

    final rawResults =
        data['results'] as List<dynamic>? ?? [];
    final results = <PlaceResult>[];

    for (final raw in rawResults.take(8)) {
      if (raw is! Map<String, dynamic>) continue;

      final geometry = raw['geometry'];
      if (geometry is! Map<String, dynamic>) continue;

      final location = geometry['location'];
      if (location is! Map<String, dynamic>) continue;

      final lat = doubleValue(location['lat']);
      final lng = doubleValue(location['lng']);
      if (lat == null || lng == null) continue;

      final address =
          raw['formatted_address']?.toString() ?? '';
      final placeId =
          raw['place_id']?.toString() ?? '';

      results.add(
        PlaceResult(
          placeId: placeId,
          displayName:
              address.isEmpty ? query : address,
          secondaryText: '',
          lat: lat,
          lng: lng,
        ),
      );
    }

    return results;
  }

  static Future<PlaceResult?> placeDetails(String placeId) async {
    _ensureConfigured();

    final response = await http.get(
      Uri.parse(
        'https://places.googleapis.com/v1/places/$placeId?languageCode=ar',
      ),
      headers: {
        'X-Goog-Api-Key': googleWebApiKey,
        'X-Goog-FieldMask':
            'id,displayName,formattedAddress,location',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Place Details HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final location = data['location'];

    if (location is! Map<String, dynamic>) return null;

    final latitude = doubleValue(location['latitude']);
    final longitude = doubleValue(location['longitude']);

    final displayNameRaw = data['displayName'];
    final displayName = displayNameRaw is Map<String, dynamic>
        ? stringValue(displayNameRaw['text'])
        : '';

    final formattedAddress = stringValue(data['formattedAddress']);

    return PlaceResult(
      placeId: placeId,
      displayName:
          displayName.isNotEmpty
              ? displayName
              : formattedAddress,
      secondaryText:
          formattedAddress,
      lat: latitude,
      lng: longitude,
    );
  }

  static Future<GoogleRouteResult> computeRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    // مسار حقيقي على الشوارع بدون Google Routes API.
    // نخلي Google Maps للخريطة والبحث، ونستخدم OSRM للمسار.
    final coordinates =
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';

    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '$coordinates'
      '?overview=full'
      '&geometries=polyline'
      '&steps=false'
      '&alternatives=false',
    );

    final response = await http.get(
      uri,
      headers: {
        'User-Agent': 'TuktukApp/1.0',
      },
    ).timeout(
      const Duration(seconds: 12),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'تعذر جلب مسار الشوارع HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final code = stringValue(data['code']);

    if (code != 'Ok') {
      throw Exception(
        stringValue(data['message']).isNotEmpty
            ? stringValue(data['message'])
            : 'ماكو مسار متاح بين النقطتين',
      );
    }

    final routes = data['routes'] as List<dynamic>? ?? [];

    if (routes.isEmpty) {
      throw Exception('ماكو مسار متاح بين النقطتين');
    }

    final route = routes.first as Map<String, dynamic>;

    final distanceMeters =
        doubleValue(route['distance']).round();

    final durationSeconds =
        doubleValue(route['duration']).round();

    final encoded =
        stringValue(route['geometry']);

    final points = decodePolyline(encoded);

    if (distanceMeters <= 0 || points.isEmpty) {
      throw Exception('المسار المستلم غير صالح');
    }

    return GoogleRouteResult(
      distanceMeters: distanceMeters,
      duration: '${durationSeconds}s',
      encodedPolyline: encoded,
      points: points,
    );
  }

  static List<LatLng> decodePolyline(String encoded) {
    if (encoded.isEmpty) return [];

    final points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < encoded.length) {
      int result = 0;
      int shift = 0;
      int byte;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);

      final deltaLat = (result & 1) != 0
          ? ~(result >> 1)
          : (result >> 1);
      lat += deltaLat;

      result = 0;
      shift = 0;

      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);

      final deltaLng = (result & 1) != 0
          ? ~(result >> 1)
          : (result >> 1);
      lng += deltaLng;

      points.add(
        LatLng(
          lat / 1e5,
          lng / 1e5,
        ),
      );
    }

    return points;
  }

  static String prettyDuration(String raw) {
    if (raw.isEmpty) return '--';

    final secondsText = raw.endsWith('s')
        ? raw.substring(0, raw.length - 1)
        : raw;
    final seconds = double.tryParse(secondsText)?.round() ?? 0;

    if (seconds <= 0) return '--';

    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes د';

    final hours = minutes ~/ 60;
    final remaining = minutes % 60;

    if (remaining == 0) return '$hours س';
    return '$hours س $remaining د';
  }

  static void _ensureConfigured() {
    if (!isConfigured) {
      throw Exception('Google API Key غير مضاف داخل main.dart');
    }
  }
}


String stringValue(dynamic value) => value?.toString() ?? '';

class PricingSettingsService {
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _subscription;

  static final ValueNotifier<int> revision =
      ValueNotifier<int>(0);

  static int minimumFare = 1000;
  static double baseFare = 500;
  static double perKm = 300;
  static int roundTo = 250;

  static double clearRoadPercent = -10;
  static double normalRoadPercent = 0;
  static double mediumTrafficPercent = 10;
  static double heavyTrafficPercent = 15;

  static double nightPercent = -5;
  static double peakPercent = 5;

  static double commissionPercent = 10;

  static Future<void> start() async {
    await _subscription?.cancel();

    _subscription = FirebaseFirestore.instance
        .collection('settings')
        .doc('pricing')
        .snapshots()
        .listen(
      (snapshot) {
        final data = snapshot.data();
        if (data == null) {
          debugPrint(
            'PRICING: settings/pricing غير موجود، نستخدم الأسعار الافتراضية',
          );
          return;
        }

        minimumFare = _positiveInt(
          data['minimumFare'],
          minimumFare,
        );

        baseFare = _nonNegativeDouble(
          data['baseFare'],
          baseFare,
        );

        perKm = _nonNegativeDouble(
          data['perKm'],
          perKm,
        );

        roundTo = _positiveInt(
          data['roundTo'],
          roundTo,
        );

        clearRoadPercent = _double(
          data['clearRoadPercent'],
          clearRoadPercent,
        );

        normalRoadPercent = _double(
          data['normalRoadPercent'],
          normalRoadPercent,
        );

        mediumTrafficPercent = _double(
          data['mediumTrafficPercent'],
          mediumTrafficPercent,
        );

        heavyTrafficPercent = _double(
          data['heavyTrafficPercent'],
          heavyTrafficPercent,
        );

        nightPercent = _double(
          data['nightPercent'],
          nightPercent,
        );

        peakPercent = _double(
          data['peakPercent'],
          peakPercent,
        );

        commissionPercent = _boundedPercent(
          data['commissionPercent'],
          commissionPercent,
        );

        revision.value++;

        debugPrint(
          'PRICING UPDATED: min=$minimumFare, perKm=$perKm, commission=$commissionPercent%',
        );
      },
      onError: (error) {
        debugPrint(
          'PRICING LISTENER ERROR: $error',
        );
      },
    );
  }

  static int _positiveInt(
    dynamic value,
    int fallback,
  ) {
    final parsed = intValue(value);
    return parsed > 0 ? parsed : fallback;
  }

  static double _nonNegativeDouble(
    dynamic value,
    double fallback,
  ) {
    final parsed = doubleValue(value);
    return parsed >= 0 ? parsed : fallback;
  }

  static double _double(
    dynamic value,
    double fallback,
  ) {
    if (value == null) return fallback;
    final parsed =
        double.tryParse(value.toString());
    return parsed ?? fallback;
  }

  static double _boundedPercent(
    dynamic value,
    double fallback,
  ) {
    final parsed = _double(
      value,
      fallback,
    );

    if (parsed < 0) return 0;
    if (parsed > 100) return 100;
    return parsed;
  }

  static double percentMultiplier(
    double percent,
  ) {
    final multiplier =
        1.0 + (percent / 100.0);

    // حماية من تسعيرة سالبة لو دخلت نسبة غير صحيحة.
    return multiplier < 0.05
        ? 0.05
        : multiplier;
  }

  static Map<String, dynamic> snapshot() {
    return {
      'minimumFare': minimumFare,
      'baseFare': baseFare,
      'perKm': perKm,
      'roundTo': roundTo,
      'clearRoadPercent': clearRoadPercent,
      'normalRoadPercent': normalRoadPercent,
      'mediumTrafficPercent':
          mediumTrafficPercent,
      'heavyTrafficPercent':
          heavyTrafficPercent,
      'nightPercent': nightPercent,
      'peakPercent': peakPercent,
      'commissionPercent':
          commissionPercent,
    };
  }
}


int intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double doubleValue(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int calculateFare(
  double km, {
  String? duration,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();

  final durationSeconds = duration == null
      ? 0
      : (double.tryParse(
                duration.replaceAll('s', ''),
              ) ??
              0)
          .round();

  final minimumFare =
      PricingSettingsService.minimumFare;

  var fare =
      PricingSettingsService.baseFare +
          (km * PricingSettingsService.perKm);

  double trafficPercent =
      PricingSettingsService.normalRoadPercent;

  if (durationSeconds > 0 && km > 0.05) {
    final hours =
        durationSeconds / 3600.0;
    final averageSpeed = km / hours;

    if (averageSpeed >= 28) {
      trafficPercent =
          PricingSettingsService
              .clearRoadPercent;
    } else if (averageSpeed >= 18) {
      trafficPercent =
          PricingSettingsService
              .normalRoadPercent;
    } else if (averageSpeed >= 11) {
      trafficPercent =
          PricingSettingsService
              .mediumTrafficPercent;
    } else {
      trafficPercent =
          PricingSettingsService
              .heavyTrafficPercent;
    }
  }

  final hour = current.hour;
  double timePercent = 0;

  if (hour >= 23 || hour < 6) {
    timePercent =
        PricingSettingsService
            .nightPercent;
  } else if ((hour >= 7 && hour < 9) ||
      (hour >= 13 && hour < 15) ||
      (hour >= 17 && hour < 20)) {
    timePercent =
        PricingSettingsService
            .peakPercent;
  }

  fare *= PricingSettingsService
      .percentMultiplier(
    trafficPercent,
  );

  fare *= PricingSettingsService
      .percentMultiplier(
    timePercent,
  );

  if (fare < minimumFare) {
    fare = minimumFare.toDouble();
  }

  final roundTo =
      PricingSettingsService.roundTo;

  if (roundTo > 0) {
    fare =
        (fare / roundTo).round() *
            roundTo.toDouble();
  }

  if (fare < minimumFare) {
    fare = minimumFare.toDouble();
  }

  return fare.toInt();
}

String fareTrafficLabel({
  required double km,
  required String? duration,
}) {
  final durationSeconds = duration == null
      ? 0
      : (double.tryParse(duration.replaceAll('s', '')) ?? 0).round();

  if (durationSeconds <= 0 || km <= 0.05) {
    return 'حركة طبيعية';
  }

  final hours = durationSeconds / 3600.0;
  final averageSpeed = km / hours;

  if (averageSpeed >= 28) return 'الطريق سالك';
  if (averageSpeed >= 18) return 'حركة طبيعية';
  if (averageSpeed >= 11) return 'زحمة متوسطة';
  return 'زحمة قوية';
}

int commissionForFare(int fare) =>
    (fare *
            (PricingSettingsService
                    .commissionPercent /
                100.0))
        .round();


String normalizePhone(String value) {
  var phone = value.replaceAll(RegExp(r'[^0-9+]'), '');

  if (phone.startsWith('00964')) {
    phone = '+964${phone.substring(5)}';
  } else if (phone.startsWith('964')) {
    phone = '+$phone';
  } else if (phone.startsWith('07')) {
    phone = '+964${phone.substring(1)}';
  }

  return phone;
}

String hashPassword(String password) {
  return sha256.convert(utf8.encode(password)).toString();
}

Future<void> saveSession({
  required String role,
  required String userId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('session_role', role);
  await prefs.setString('session_user_id', userId);

  await FcmService.saveTokenForUser(
    role: role,
    userId: userId,
  );
}

Future<void> clearSession() async {
  await FcmService.removeCurrentSessionToken();

  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('session_role');
  await prefs.remove('session_user_id');
}



DateTime? timestampToDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  return null;
}

String formatRideDate(dynamic value) {
  final date = timestampToDate(value);
  if (date == null) return '—';

  String two(int n) => n.toString().padLeft(2, '0');

  return '${two(date.day)}/${two(date.month)}/${date.year} '
      '${two(date.hour)}:${two(date.minute)}';
}

String rideStatusArabic(String status) {
  switch (status) {
    case 'searching':
      return 'جاري البحث';
    case 'accepted':
      return 'مقبولة';
    case 'arrived':
      return 'وصل السائق';
    case 'started':
      return 'جارية';
    case 'completed':
      return 'مكتملة';
    case 'canceled':
      return 'ملغية';
    default:
      return status;
  }
}

Color rideStatusColor(String status) {
  switch (status) {
    case 'completed':
      return const Color(0xff23B26D);
    case 'canceled':
      return const Color(0xffD83232);
    case 'started':
      return const Color(0xff3178F6);
    case 'arrived':
      return const Color(0xffF59E0B);
    case 'accepted':
      return const Color(0xff8B5CF6);
    default:
      return const Color(0xff777777);
  }
}



// ============================================================
// PROFESSIONAL IN-APP NOTIFICATIONS
// ============================================================

class AppNotificationsPage extends StatelessWidget {
  final String role;
  final String userId;

  const AppNotificationsPage({
    super.key,
    required this.role,
    required this.userId,
  });

  bool _visibleForUser(Map<String, dynamic> data) {
    final targetType = stringValue(data['targetType']);
    final targetId = stringValue(data['targetId']);

    if (targetType == 'all') return true;

    if (role == 'customer') {
      if (targetType == 'customers') return true;
      return targetType == 'customer' &&
          targetId == userId;
    }

    if (role == 'driver') {
      if (targetType == 'drivers') return true;
      return targetType == 'driver' &&
          targetId == userId;
    }

    return false;
  }

  Future<void> _markRead(
    String id,
    Map<String, dynamic> data,
  ) async {
    final readByRaw = data['readBy'];
    final readBy = readByRaw is List
        ? readByRaw.map((e) => e.toString()).toList()
        : <String>[];

    if (readBy.contains(userId)) return;

    await FirebaseFirestore.instance
        .collection('app_notifications')
        .doc(id)
        .update({
      'readBy': FieldValue.arrayUnion([userId]),
    });
  }

  IconData _icon(String type) {
    switch (type) {
      case 'ride':
        return Icons.electric_rickshaw_rounded;
      case 'message':
        return Icons.chat_bubble_rounded;
      case 'reward':
        return Icons.card_giftcard_rounded;
      case 'support':
        return Icons.support_agent_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الإشعارات'),
        ),
        body: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('app_notifications')
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            final docs = snapshot.data!.docs.where((doc) {
              final data =
                  doc.data() as Map<String, dynamic>;
              return _visibleForUser(data);
            }).toList();

            docs.sort((a, b) {
              final ad =
                  a.data() as Map<String, dynamic>;
              final bd =
                  b.data() as Map<String, dynamic>;
              final at =
                  timestampToDate(ad['createdAt']) ??
                      DateTime.fromMillisecondsSinceEpoch(
                        0,
                      );
              final bt =
                  timestampToDate(bd['createdAt']) ??
                      DateTime.fromMillisecondsSinceEpoch(
                        0,
                      );
              return bt.compareTo(at);
            });

            if (docs.isEmpty) {
              return const Center(
                child: Text(
                  'ما عندك إشعارات حالياً',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data =
                    doc.data() as Map<String, dynamic>;
                final readByRaw = data['readBy'];
                final readBy = readByRaw is List
                    ? readByRaw
                        .map((e) => e.toString())
                        .toList()
                    : <String>[];
                final unread =
                    !readBy.contains(userId);

                return Card(
                  color: unread
                      ? const Color(0xffFFF9E5)
                      : Colors.white,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          const Color(0xffFFC107),
                      child: Icon(
                        _icon(
                          stringValue(data['type']),
                        ),
                        color: Colors.black,
                      ),
                    ),
                    title: Text(
                      stringValue(data['title']),
                      style: TextStyle(
                        fontWeight: unread
                            ? FontWeight.w900
                            : FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      stringValue(data['body']),
                    ),
                    isThreeLine: true,
                    trailing: unread
                        ? const Icon(
                            Icons.circle,
                            size: 10,
                            color: Colors.red,
                          )
                        : null,
                    onTap: () async {
                      await _markRead(
                        doc.id,
                        data,
                      );

                      if (!context.mounted) return;

                      final rideId =
                          stringValue(data['rideId']);
                      final type =
                          stringValue(data['type']);

                      if (rideId.isNotEmpty &&
                          type == 'message') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => RideChatPage(
                              rideId: rideId,
                              senderRole: role,
                            ),
                          ),
                        );
                        return;
                      }

                      if (rideId.isNotEmpty &&
                          role == 'customer') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                CustomerRideTrackingPage(
                              rideId: rideId,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class NotificationBadgeIcon extends StatelessWidget {
  final String role;
  final String userId;
  final VoidCallback onPressed;

  const NotificationBadgeIcon({
    super.key,
    required this.role,
    required this.userId,
    required this.onPressed,
  });

  bool _visibleForUser(Map<String, dynamic> data) {
    final targetType = stringValue(data['targetType']);
    final targetId = stringValue(data['targetId']);

    if (targetType == 'all') return true;

    if (role == 'customer') {
      if (targetType == 'customers') return true;
      return targetType == 'customer' &&
          targetId == userId;
    }

    if (role == 'driver') {
      if (targetType == 'drivers') return true;
      return targetType == 'driver' &&
          targetId == userId;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('app_notifications')
          .snapshots(),
      builder: (context, snapshot) {
        int unread = 0;

        if (snapshot.hasData) {
          for (final doc in snapshot.data!.docs) {
            final data =
                doc.data() as Map<String, dynamic>;

            if (!_visibleForUser(data)) continue;

            final readByRaw = data['readBy'];
            final readBy = readByRaw is List
                ? readByRaw
                    .map((e) => e.toString())
                    .toList()
                : <String>[];

            if (!readBy.contains(userId)) {
              unread++;
            }
          }
        }

        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: 'الإشعارات',
              onPressed: onPressed,
              icon: const Icon(
                Icons.notifications_none_rounded,
              ),
            ),
            if (unread > 0)
              Positioned(
                top: 3,
                right: 3,
                child: Container(
                  constraints:
                      const BoxConstraints(
                    minWidth: 18,
                    minHeight: 18,
                  ),
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius:
                        BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white,
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}


// ============================================================
// TECHNICAL SUPPORT - CUSTOMER / DRIVER
// ============================================================

class TechnicalSupportPage extends StatefulWidget {
  final String role;
  final String userId;
  final String userName;
  final String userPhone;
  final String initialSubject;
  final String initialMessage;

  const TechnicalSupportPage({
    super.key,
    required this.role,
    required this.userId,
    required this.userName,
    required this.userPhone,
    this.initialSubject = '',
    this.initialMessage = '',
  });

  @override
  State<TechnicalSupportPage> createState() =>
      _TechnicalSupportPageState();
}

class _TechnicalSupportPageState
    extends State<TechnicalSupportPage> {
  final _subjectController = TextEditingController();
  final _messageController = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _subjectController.text =
        widget.initialSubject;
    _messageController.text =
        widget.initialMessage;
  }

  void _fillQuickRequest(
    String subject,
    String message,
  ) {
    setState(() {
      _subjectController.text = subject;
      _messageController.text = message;
    });
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  String get _roleArabic =>
      widget.role == 'driver' ? 'سائق' : 'زبون';

  Future<void> _sendTicket() async {
    final subject = _subjectController.text.trim();
    final message = _messageController.text.trim();

    if (subject.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('بس اكتب شنو تحتاج، وفريق الدعم يتابع وياك 💛'),
        ),
      );
      return;
    }

    if (_sending) return;
    setState(() => _sending = true);

    try {
      await FirebaseFirestore.instance
          .collection('support_tickets')
          .add({
        'role': widget.role,
        'userId': widget.userId,
        'userName': widget.userName,
        'userPhone': widget.userPhone,
        'subject': subject,
        'message': message,
        'status': 'open',
        'managerReply': '',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      _subjectController.clear();
      _messageController.clear();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            'وصلتنا رسالتك ✅\nفريق الدعم راح يتابعها وياك بأقرب وقت.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text(
            'ما قدرنا نرسل الرسالة هسه. تأكد من الإنترنت وجرّب مرة ثانية 💛',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  String _statusText(String status) {
    switch (status) {
      case 'open':
        return 'جديد';
      case 'in_progress':
        return 'قيد المتابعة';
      case 'closed':
        return 'تم الحل';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'open':
        return Colors.orange;
      case 'in_progress':
        return Colors.blue;
      case 'closed':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('support_tickets')
        .where('userId', isEqualTo: widget.userId)
        .snapshots();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الدعم الفني'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xffFFF7D8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Color(0xffFFC107),
                    child: Icon(
                      Icons.support_agent_rounded,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'أهلاً ${widget.userName.isEmpty ? _roleArabic : widget.userName} 💛\nفريق الدعم حاضر يساعدك. اكتب طلبك براحتك وراح نتابعه وياك.',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'شلون نكدر نساعدك؟',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.role == 'driver')
                  ActionChip(
                    avatar: const Icon(
                      Icons.account_balance_wallet_rounded,
                      size: 18,
                    ),
                    label: const Text(
                      'تعبئة رصيد',
                    ),
                    onPressed: () {
                      _fillQuickRequest(
                        'طلب تعبئة رصيد',
                        'مرحباً فريق الدعم، أريد تعبئة رصيد حساب السائق. أتمنى تتواصلون وياي لإكمال التعبئة. شكراً 💛',
                      );
                    },
                  ),
                ActionChip(
                  avatar: const Icon(
                    Icons.route_rounded,
                    size: 18,
                  ),
                  label: const Text(
                    'مشكلة بالرحلة',
                  ),
                  onPressed: () {
                    _fillQuickRequest(
                      'مساعدة بخصوص رحلة',
                      'مرحباً فريق الدعم، عندي موضوع بخصوص رحلة وأحتاج مساعدتكم.',
                    );
                  },
                ),
                ActionChip(
                  avatar: const Icon(
                    Icons.person_outline_rounded,
                    size: 18,
                  ),
                  label: const Text(
                    'مشكلة بالحساب',
                  ),
                  onPressed: () {
                    _fillQuickRequest(
                      'مساعدة بالحساب',
                      'مرحباً فريق الدعم، أحتاج مساعدتكم بخصوص حسابي.',
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(
                labelText: 'عنوان المشكلة',
                hintText: 'مثال: تعبئة رصيد',
                prefixIcon: Icon(Icons.title_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'تفاصيل المشكلة',
                hintText: 'اكتب شنو المشكلة بالتفصيل...',
                prefixIcon: Icon(Icons.chat_rounded),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _sending ? null : _sendTicket,
                icon: const Icon(Icons.send_rounded),
                label: Text(
                  _sending ? 'جاري الإرسال...' : 'إرسال للدعم الفني',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'طلبات الدعم السابقة',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            StreamBuilder<QuerySnapshot>(
              stream: query,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }

                final docs = [...snapshot.data!.docs];

                docs.sort((a, b) {
                  final ad = a.data() as Map<String, dynamic>;
                  final bd = b.data() as Map<String, dynamic>;

                  final at = timestampToDate(ad['createdAt']) ??
                      DateTime.fromMillisecondsSinceEpoch(0);
                  final bt = timestampToDate(bd['createdAt']) ??
                      DateTime.fromMillisecondsSinceEpoch(0);

                  return bt.compareTo(at);
                });

                if (docs.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(
                        child: Text(
                          'ما عندك طلبات دعم سابقة',
                        ),
                      ),
                    ),
                  );
                }

                return Column(
                  children: docs.map((doc) {
                    final data =
                        doc.data() as Map<String, dynamic>;
                    final status =
                        stringValue(data['status']);
                    final reply =
                        stringValue(data['managerReply']);

                    return Card(
                      margin:
                          const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    stringValue(
                                      data['subject'],
                                    ),
                                    style:
                                        const TextStyle(
                                      fontSize: 17,
                                      fontWeight:
                                          FontWeight.w900,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration:
                                      BoxDecoration(
                                    color:
                                        _statusColor(status)
                                            .withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius:
                                        BorderRadius
                                            .circular(10),
                                  ),
                                  child: Text(
                                    _statusText(status),
                                    style: TextStyle(
                                      color:
                                          _statusColor(status),
                                      fontWeight:
                                          FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              stringValue(data['message']),
                            ),
                            if (reply.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding:
                                    const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xffF2F7FF,
                                  ),
                                  borderRadius:
                                      BorderRadius.circular(
                                    14,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'رد الدعم الفني',
                                      style: TextStyle(
                                        color:
                                            Color(0xff3178F6),
                                        fontWeight:
                                            FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(reply),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}


// ============================================================
// ROLE PAGE
// ============================================================


class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Widget? _page;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {

          final prefs = await SharedPreferences.getInstance();
          final role = prefs.getString('session_role') ?? '';
          final userId = prefs.getString('session_user_id') ?? '';

          Widget page = const RolePage();

          if (role == 'customer' && userId.isNotEmpty) {
            // الزبون يدخل فوراً من الجلسة المحلية.
            // CustomerPage تحمل بيانات الحساب بالخلفية، فلا داعي نوقف
            // فتح التطبيق على قراءة Firestore إضافية.
            page = CustomerPage(
              customerId: userId,
            );
          } else if (role == 'driver' && userId.isNotEmpty) {
            final snap = await FirebaseFirestore.instance
                .collection('drivers')
                .doc(userId)
                .get();

            if (snap.exists) {
              final data = snap.data()!;
              final approval =
                  stringValue(data['approvalStatus']).isEmpty
                      ? 'approved'
                      : stringValue(data['approvalStatus']);

              if (approval == 'approved' &&
                  data['active'] != false) {
                final driver = DriverProfile(
                  id: snap.id,
                  name: stringValue(data['name']),
                  phone: stringValue(data['phone']),
                  active: true,
                  approvalStatus: approval,
                  tuktukNumber:
                      stringValue(data['tuktukNumber']),
                  tuktukColor:
                      stringValue(data['tuktukColor']),
                  profilePhotoUrl:
                      stringValue(data['profilePhotoUrl']),
                  verified: data['verified'] == true,
                );

                String activeRideId = '';

                // أولاً نجرب الرحلة المحفوظة محلياً.
                final savedRideId =
                    prefs.getString('driver_active_ride_id') ?? '';

                if (savedRideId.isNotEmpty) {
                  final savedRide = await FirebaseFirestore.instance
                      .collection('ride_requests')
                      .doc(savedRideId)
                      .get();

                  if (savedRide.exists) {
                    final savedData = savedRide.data()!;
                    final savedStatus =
                        stringValue(savedData['status']);

                    if (stringValue(savedData['driverId']) == snap.id &&
                        (savedStatus == 'accepted' ||
                            savedStatus == 'arrived' ||
                            savedStatus == 'started')) {
                      activeRideId = savedRide.id;
                    }
                  }
                }

                // ما نسوي Query لكل رحلات السائق وقت التشغيل.
                // الرحلة النشطة تُحفظ محلياً عند القبول، وهذا أسرع بكثير.
                // إذا ماكو ID محفوظ نفتح الرئيسية مباشرة.
                if (activeRideId.isNotEmpty) {
                  page = DriverActiveRidePage(
                    rideId: activeRideId,
                    driver: driver,
                  );
                } else {
                  await prefs.remove('driver_active_ride_id');
                  page = DriverHomePage(
                    driver: driver,
                  );
                }
              } else {
                await clearSession();
              }
            } else {
              await clearSession();
            }
          }

          if (!mounted) return;
          setState(() => _page = page);
  
    } catch (e) {
      debugPrint('STARTUP RESTORE ERROR: $e');

      if (!mounted) return;

      setState(() {
        _page = const RolePage();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _page ??
        const Scaffold(
          backgroundColor: Colors.white,
          body: SizedBox.expand(),
        );
  }
}


class RolePage extends StatelessWidget {
  const RolePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  color: const Color(0xffFFC107),
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 26,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.electric_rickshaw_rounded,
                  size: 66,
                  color: Color(0xff171717),
                ),
              ),
              const SizedBox(height: 26),
              const Text(
                'تكتك',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'مشوارك أسهل وأسرع',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _RoleEntryCard(
                icon: Icons.person_rounded,
                title: 'أنا زبون',
                subtitle: 'حدد موقعك واطلب أقرب تكتك',
                filled: true,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CustomerAuthPage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _RoleEntryCard(
                icon: Icons.electric_rickshaw_rounded,
                title: 'أنا سائق',
                subtitle: 'استلم الطلبات وابدأ العمل',
                filled: false,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverAuthPage(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleEntryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool filled;
  final VoidCallback onTap;

  const _RoleEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? const Color(0xffFFC107) : Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 17,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: filled
                ? null
                : Border.all(
                    color: const Color(0xffE8E8E8),
                  ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: filled
                      ? Colors.white.withValues(alpha: 0.78)
                      : const Color(0xffF5F6F8),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Icon(
                  icon,
                  color: const Color(0xff191919),
                  size: 29,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: filled
                            ? Colors.black87
                            : Colors.black54,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_back_ios_new_rounded,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// CUSTOMER
// ============================================================

class CustomerPage extends StatefulWidget {
  final String? customerId;

  const CustomerPage({
    super.key,
    this.customerId,
  });

  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  final GlobalKey<ScaffoldState> _customerScaffoldKey =
      GlobalKey<ScaffoldState>();

  GoogleMapController? _mapController;

  final TextEditingController _customerNameController =
      TextEditingController();
  final TextEditingController _customerPhoneController =
      TextEditingController();

  final TextEditingController _mapSearchController =
      TextEditingController();
  final FocusNode _mapSearchFocus = FocusNode();

  List<PlaceResult> _mapSearchResults = [];
  Timer? _mapSearchDebounce;
  bool _mapSearchLoading = false;
  bool _showMapSearchResults = false;

  LatLng? _currentLocation;
  LatLng? _cameraTarget;
  LatLng? _pickup;
  LatLng? _destination;

  String _currentAddress = 'جاري تحديد المكان...';
  String _pickupAddress = '';
  String _destinationAddress = '';

  bool _loadingLocation = true;
  bool _loadingAddress = false;
  bool _loadingRoute = false;
  bool _sendingRequest = false;

  // 0 = اختيار الانطلاق، 1 = اختيار الوصول، 2 = عرض المسار والكروة
  int _selectionStep = 0;

  double _distanceKm = 0;
  int _price = 0;
  int _discountAmount = 0;
  String _promoCode = '';

  int _rewardBalance = 0;
  bool _useRewardBalance = true;

  int get _rewardApplied {
    if (!_useRewardBalance || _rewardBalance <= 0) {
      return 0;
    }

    final afterPromo = _price - _discountAmount;
    if (afterPromo <= 0) return 0;

    return _rewardBalance > afterPromo
        ? afterPromo
        : _rewardBalance;
  }
  int _routeDistanceMeters = 0;

  int get _finalPrice {
    final value =
        _price - _discountAmount - _rewardApplied;
    return value < 0 ? 0 : value;
  }

  String get _trafficLabel => fareTrafficLabel(
        km: _routeDistanceMeters / 1000.0,
        duration: _routeDuration,
      );
  String _routeDuration = '';
  String _routeEncodedPolyline = '';
  List<LatLng> _routePoints = [];

  Timer? _addressDebounce;
  String? _rideRequestId;
  bool _restoringActiveRide = false;
  List<SavedPlace> _savedPlaces = [];

  late final VoidCallback _pricingListener;

  @override
  void initState() {
    super.initState();

    _pricingListener = () {
      if (!mounted) return;

      if (_selectionStep == 2 &&
          _routeDistanceMeters > 0) {
        final km =
            _routeDistanceMeters / 1000.0;

        setState(() {
          _distanceKm = km;
          _price = calculateFare(
            km,
            duration: _routeDuration,
          );

          // إذا المدير غيّر السعر، نلغي أي حساب خصم قديم
          // حتى ما تبقى قيمة محسوبة على تسعيرة سابقة.
          _discountAmount = 0;
          _promoCode = '';
        });
      }
    };

    PricingSettingsService
        .revision
        .addListener(
      _pricingListener,
    );

    // نخلي الواجهة تظهر أولاً، وبعدين نحمل البيانات بالتوازي.
    unawaited(_loadCustomerProfile());

    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      unawaited(
        _loadSavedPlaces(),
      );
      unawaited(
        _getCurrentLocation(),
      );
      unawaited(
        _restoreActiveCustomerRide(),
      );
    });
  }

  @override
  void dispose() {
    PricingSettingsService
        .revision
        .removeListener(
      _pricingListener,
    );

    _addressDebounce?.cancel();
    _mapSearchDebounce?.cancel();
    _mapSearchController.dispose();
    _mapSearchFocus.dispose();
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    super.dispose();
  }

  Future<void> _loadCustomerProfile() async {
    final customerId = widget.customerId;
    if (customerId == null || customerId.isEmpty) return;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('customers')
          .doc(customerId)
          .get();

      if (!snap.exists || !mounted) return;

      final data = snap.data()!;
      _customerNameController.text =
          stringValue(data['name']);
      _customerPhoneController.text =
          stringValue(data['phone']);

      setState(() {
        _rewardBalance =
            intValue(data['rewardBalance']);
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_customer_name',
        _customerNameController.text,
      );
      await prefs.setString(
        'last_customer_phone',
        _customerPhoneController.text,
      );
    } catch (_) {}
  }

  Future<void> _loadSavedPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('saved_places') ?? [];
    final places = <SavedPlace>[];

    for (final item in raw) {
      try {
        final map = jsonDecode(item) as Map<String, dynamic>;
        places.add(SavedPlace.fromMap(map));
      } catch (_) {}
    }

    if (!mounted) return;

    setState(() {
      _savedPlaces = places;
    });
  }

  Future<void> _savePlaces() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'saved_places',
      _savedPlaces.map((e) => jsonEncode(e.toMap())).toList(),
    );
  }

  Future<void> _getCurrentLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        if (!mounted) return;

        setState(() {
          _loadingLocation = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('فعّل GPS من الهاتف'),
          ),
        );
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;

        setState(() {
          _loadingLocation = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('اسمح للتطبيق باستخدام الموقع'),
          ),
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final location = LatLng(
        position.latitude,
        position.longitude,
      );

      if (!mounted) return;

      setState(() {
        _currentLocation = location;
        _cameraTarget = location;
        _loadingLocation = false;
      });

      await _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(location, 17),
      );

      await _loadAddressForPoint(location);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingLocation = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ما قدرنا نحدد موقعك هسه، تأكد من GPS وجرّب مرة ثانية 💛'),
        ),
      );
    }
  }

  void _onCameraMove(CameraPosition position) {
    if (_selectionStep >= 2) return;

    _cameraTarget = position.target;

    if (!_loadingAddress && mounted) {
      setState(() {
        _currentAddress = 'جاري تحديد العنوان...';
      });
    }
  }

  void _onCameraIdle() {
    if (_selectionStep >= 2 || _cameraTarget == null) return;

    _addressDebounce?.cancel();
    _addressDebounce = Timer(
      const Duration(milliseconds: 350),
      () {
        final point = _cameraTarget;
        if (point != null) {
          _loadAddressForPoint(point);
        }
      },
    );
  }

  Future<void> _loadAddressForPoint(LatLng point) async {
    if (!GoogleMapsService.isConfigured) {
      if (!mounted) return;

      setState(() {
        _currentAddress = 'ضع مفتاح Google API داخل main.dart أولاً';
      });
      return;
    }

    setState(() {
      _loadingAddress = true;
    });

    try {
      final address = await GoogleMapsService.reverseGeocode(point);

      if (!mounted) return;

      setState(() {
        _currentAddress = address.isEmpty ? 'موقع على الخريطة' : address;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _currentAddress = 'موقع على الخريطة';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingAddress = false;
        });
      }
    }
  }

  void _openTopSearch() {
    // إذا المسار محسوب، نخلي البحث يغيّر نقطة الوصول بدل ما يختفي.
    if (_selectionStep == 2) {
      _editDestination();
    }

    _openPlaceSearch();
  }

  void _openPlaceSearch() {
    if (!GoogleMapsService.isConfigured) {
      _showApiKeyMessage();
      return;
    }

    setState(() {
      _showMapSearchResults = true;
    });

    _mapSearchFocus.requestFocus();
  }

  void _closeMapSearch() {
    _mapSearchDebounce?.cancel();
    _mapSearchFocus.unfocus();

    setState(() {
      _showMapSearchResults = false;
      _mapSearchLoading = false;
      _mapSearchResults = [];
    });
  }

  void _onMapSearchChanged(String value) {
    _mapSearchDebounce?.cancel();

    final query = value.trim();

    if (query.length < 2) {
      setState(() {
        _mapSearchResults = [];
        _mapSearchLoading = false;
        _showMapSearchResults = query.isNotEmpty;
      });
      return;
    }

    setState(() {
      _mapSearchLoading = true;
      _showMapSearchResults = true;
    });

    _mapSearchDebounce = Timer(
      const Duration(milliseconds: 350),
      () async {
        try {
          final results = await GoogleMapsService.searchPlaces(
            query,
            center: _cameraTarget ?? _currentLocation,
          );

          if (!mounted ||
              _mapSearchController.text.trim() != query) {
            return;
          }

          setState(() {
            _mapSearchResults = results;
            _mapSearchLoading = false;
          });
        } catch (e) {
          if (!mounted) return;

          setState(() {
            _mapSearchResults = [];
            _mapSearchLoading = false;
          });

          ScaffoldMessenger.of(context)
              .hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'تعذر البحث: $e',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        }
      },
    );
  }

  Future<void> _selectMapSearchResult(
    PlaceResult result,
  ) async {
    _mapSearchDebounce?.cancel();

    setState(() {
      _mapSearchLoading = true;
    });

    try {
      PlaceResult? details = result;

      if (result.lat == null || result.lng == null) {
        details = await GoogleMapsService.placeDetails(
          result.placeId,
        );
      }

      if (details == null ||
          details.lat == null ||
          details.lng == null ||
          !mounted) {
        return;
      }

      final point = LatLng(
        details.lat!,
        details.lng!,
      );

      setState(() {
        _cameraTarget = point;
        _currentAddress = details!.displayName;
        _mapSearchController.text = details.displayName;
        _mapSearchResults = [];
        _mapSearchLoading = false;
        _showMapSearchResults = false;
      });

      _mapSearchFocus.unfocus();

      await _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(
          point,
          17,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _mapSearchLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تعذر فتح المكان: $e',
          ),
        ),
      );
    }
  }

  void _showApiKeyMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'حط نفس Google API Key بمكان PASTE_GOOGLE_API_KEY_HERE داخل main.dart',
        ),
      ),
    );
  }

  Future<void> _confirmMapPoint() async {
    final point = _cameraTarget;
    if (point == null) return;

    if (!GoogleMapsService.isConfigured) {
      _showApiKeyMessage();
      return;
    }

    if (_selectionStep == 0) {
      setState(() {
        _pickup = point;
        _pickupAddress = _currentAddress;
        _selectionStep = 1;
        _currentAddress = 'حرك الخريطة وحدد نقطة الوصول';
        _mapSearchController.clear();
        _mapSearchResults = [];
        _showMapSearchResults = false;
      });

      _mapSearchFocus.unfocus();
      return;
    }

    if (_selectionStep == 1) {
      setState(() {
        _destination = point;
        _destinationAddress = _currentAddress;
      });

      await _calculateGoogleRoute();
    }
  }

  Future<void> _calculateGoogleRoute() async {
    if (_pickup == null || _destination == null) return;

    setState(() {
      _loadingRoute = true;
    });

    try {
      final route = await GoogleMapsService.computeRoute(
        _pickup!,
        _destination!,
      );

      if (!mounted) return;

      final km = route.distanceMeters / 1000.0;

      setState(() {
        _routeDistanceMeters = route.distanceMeters;
        _distanceKm = km;

        // الكروة على مسافة الشوارع الحقيقية:
        // أقل كروة 1000، وبعدها كل 250 متر = 250 دينار.
        _price = calculateFare(
          km,
          duration: route.duration,
        );
        _discountAmount = 0;
        _promoCode = '';

        _routeDuration = route.duration;
        _routeEncodedPolyline = route.encodedPolyline;
        _routePoints = route.points;
        _selectionStep = 2;
      });

      await _fitRouteOnMap();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تعذر جلب مسار الشوارع: $e',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingRoute = false;
        });
      }
    }
  }

  Future<void> _fitRouteOnMap() async {
    if (_routePoints.isEmpty || _mapController == null) return;

    double minLat = _routePoints.first.latitude;
    double maxLat = _routePoints.first.latitude;
    double minLng = _routePoints.first.longitude;
    double maxLng = _routePoints.first.longitude;

    for (final point in _routePoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    if ((maxLat - minLat).abs() < 0.00001 &&
        (maxLng - minLng).abs() < 0.00001) {
      await _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_routePoints.first, 16),
      );
      return;
    }

    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        70,
      ),
    );
  }

  void _editPickup() {
    final point = _pickup ?? _currentLocation;

    setState(() {
      _selectionStep = 0;
      _destination = null;
      _destinationAddress = '';
      _routePoints = [];
      _routeEncodedPolyline = '';
      _distanceKm = 0;
      _price = 0;
      _discountAmount = 0;
      _promoCode = '';
      _cameraTarget = point;
      _currentAddress = _pickupAddress.isEmpty
          ? 'حرك الخريطة وحدد نقطة الانطلاق'
          : _pickupAddress;
    });

    if (point != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(point, 17),
      );
    }
  }

  void _clearPickupSelection() {
    final point = _currentLocation ?? _cameraTarget;

    setState(() {
      _pickup = null;
      _destination = null;
      _pickupAddress = '';
      _destinationAddress = '';
      _selectionStep = 0;
      _routePoints = [];
      _routeEncodedPolyline = '';
      _routeDistanceMeters = 0;
      _routeDuration = '';
      _distanceKm = 0;
      _price = 0;
      _discountAmount = 0;
      _promoCode = '';
      _cameraTarget = point;
      _currentAddress = 'حرك الخريطة وحدد نقطة الانطلاق';
    });

    if (point != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(point, 17),
      );
      unawaited(_loadAddressForPoint(point));
    }
  }

  void _clearDestinationSelection() {
    final point = _pickup ?? _currentLocation ?? _cameraTarget;

    setState(() {
      _destination = null;
      _destinationAddress = '';
      _selectionStep = 1;
      _routePoints = [];
      _routeEncodedPolyline = '';
      _routeDistanceMeters = 0;
      _routeDuration = '';
      _distanceKm = 0;
      _price = 0;
      _discountAmount = 0;
      _promoCode = '';
      _cameraTarget = point;
      _currentAddress = 'حرك الخريطة وحدد نقطة الوصول';
    });

    if (point != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(point, 17),
      );
      unawaited(_loadAddressForPoint(point));
    }
  }

  void _editDestination() {
    final point = _destination ?? _pickup ?? _currentLocation;

    setState(() {
      _selectionStep = 1;
      _routePoints = [];
      _routeEncodedPolyline = '';
      _distanceKm = 0;
      _price = 0;
      _discountAmount = 0;
      _promoCode = '';
      _cameraTarget = point;
      _currentAddress = _destinationAddress.isEmpty
          ? 'حرك الخريطة وحدد نقطة الوصول'
          : _destinationAddress;
    });

    if (point != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(point, 17),
      );
    }
  }

  Future<void> _useSavedPlace(SavedPlace place) async {
    final point = LatLng(place.lat, place.lng);

    setState(() {
      _cameraTarget = point;
      _currentAddress = place.name;
    });

    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(point, 17),
    );
  }

  Future<void> _addSavedPlace() async {
    final point = _selectionStep == 2
        ? (_destination ?? _pickup)
        : _cameraTarget;

    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حدد مكان أولاً')),
      );
      return;
    }

    String typedName = '';

    final placeName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('حفظ المكان'),
            content: TextFormField(
              autofocus: true,
              textInputAction: TextInputAction.done,
              onChanged: (value) {
                typedName = value.trim();
              },
              onFieldSubmitted: (value) {
                final name = value.trim();
                if (name.isEmpty) return;
                Navigator.pop(dialogContext, name);
              },
              decoration: const InputDecoration(
                labelText: 'اسم المكان',
                hintText: 'مثال: البيت أو العمل',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (typedName.isEmpty) return;
                  Navigator.pop(dialogContext, typedName);
                },
                child: const Text('حفظ'),
              ),
            ],
          ),
        );
      },
    );

    if (placeName == null ||
        placeName.trim().isEmpty ||
        !mounted) {
      return;
    }

    setState(() {
      _savedPlaces.add(
        SavedPlace(
          name: placeName.trim(),
          lat: point.latitude,
          lng: point.longitude,
        ),
      );
    });

    await _savePlaces();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم حفظ المكان'),
      ),
    );
  }

  Future<void> _removeSavedPlace(int index) async {
    setState(() {
      _savedPlaces.removeAt(index);
    });

    await _savePlaces();
  }

  void _openSavedPlaces() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _savedPlaces.isEmpty
                  ? const SizedBox(
                      height: 160,
                      child: Center(
                        child: Text('ما عندك أماكن محفوظة'),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _savedPlaces.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, index) {
                        final place = _savedPlaces[index];

                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Colors.amber,
                            child: Icon(
                              Icons.bookmark,
                              color: Colors.black,
                            ),
                          ),
                          title: Text(place.name),
                          subtitle: Text(
                            _selectionStep == 0
                                ? 'استخدامه كنقطة انطلاق'
                                : 'استخدامه كنقطة وصول',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () async {
                              Navigator.pop(sheetContext);
                              await _removeSavedPlace(index);
                            },
                          ),
                          onTap: () async {
                            Navigator.pop(sheetContext);
                            await _useSavedPlace(place);
                          },
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }


  Future<void> _openPromoCode() async {
    final controller = TextEditingController(
      text: _promoCode,
    );

    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: const Text(
              'كود الخصم',
              textAlign: TextAlign.center,
            ),
            content: TextField(
              controller: controller,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'مثال: TUKTUK20',
                prefixIcon: Icon(Icons.local_offer_rounded),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext),
                child: const Text('رجوع'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  controller.text.trim(),
                ),
                child: const Text('تطبيق'),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    if (code == null || code.trim().isEmpty) return;

    try {
      final result = await PromoService.apply(
        rawCode: code,
        originalPrice: _price,
        customerId: widget.customerId ?? '',
      );

      if (!mounted) return;

      setState(() {
        _promoCode = result.code;
        _discountAmount = result.discount;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تم تطبيق الخصم: ${result.discount} د.ع',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    }
  }

  Future<void> _openCustomerInfo() async {
    if (_pickup == null ||
        _destination == null ||
        _price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('حدد الانطلاق والوصول أولاً'),
        ),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(28),
        ),
      ),
      builder: (sheetContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                22,
                22,
                22,
                20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'تأكيد الطلب',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _confirmLocationRow(
                    color: const Color(0xff26A269),
                    title: 'موقعي الحالي',
                    subtitle: _pickupAddress,
                  ),
                  const SizedBox(height: 14),
                  _confirmLocationRow(
                    color: const Color(0xffF2673A),
                    title: 'الوجهة',
                    subtitle:
                        _destinationAddress,
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding:
                        const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color:
                          const Color(0xffFAFAFA),
                      borderRadius:
                          BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _confirmMetric(
                            icon:
                                Icons.route_rounded,
                            title: 'المسافة',
                            value:
                                '${_distanceKm.toStringAsFixed(1)} كم',
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 44,
                          color:
                              const Color(0xffE7E7E7),
                        ),
                        Expanded(
                          child: _confirmMetric(
                            icon:
                                Icons.schedule_rounded,
                            title:
                                'الوقت المتوقع',
                            value:
                                GoogleMapsService.prettyDuration(
                              _routeDuration,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      const Text(
                        'سعر الرحلة',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight:
                              FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$_price د.ع',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight:
                              FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  if (_rewardBalance > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text(
                          'الرصيد الحالي',
                          style: TextStyle(
                            color: Colors.black54,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '$_rewardBalance د.ع',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontWeight:
                                FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xffFFF8DC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '🎁 مكافآتك تنخصم من الكروة النهائية، وممكن تنزل الكروة عن أقل كروة.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding:
                          EdgeInsets.zero,
                      value:
                          _useRewardBalance,
                      activeColor:
                          const Color(0xffFFC21A),
                      title: const Text(
                        'استخدام الرصيد',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              FontWeight.w700,
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _useRewardBalance =
                              value;
                        });
                      },
                    ),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style:
                          ElevatedButton.styleFrom(
                        backgroundColor:
                            const Color(0xffFFC21A),
                        foregroundColor:
                            Colors.black,
                        elevation: 0,
                        shape:
                            RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(
                            14,
                          ),
                        ),
                      ),
                      onPressed: _sendingRequest
                          ? null
                          : () async {
                              Navigator.pop(
                                sheetContext,
                              );
                              await _sendRideRequest();
                            },
                      child: const Text(
                        'تأكيد الطلب',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight:
                              FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _confirmLocationRow({
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Container(
          width: 11,
          height: 11,
          margin:
              const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow:
                    TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _confirmMetric({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Column(
      children: [
        Icon(
          icon,
          size: 19,
          color: Colors.black87,
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }


  Future<void>
      _restoreActiveCustomerRide() async {
    if (_restoringActiveRide) return;

    _restoringActiveRide = true;

    try {
      final prefs =
          await SharedPreferences
              .getInstance();

      var rideId =
          prefs.getString(
                'customer_active_ride_id',
              ) ??
              '';

      if (rideId.isEmpty) {
        final customerId =
            widget.customerId ?? '';

        if (customerId.isNotEmpty) {
          final rides =
              await FirebaseFirestore
                  .instance
                  .collection(
                    'ride_requests',
                  )
                  .where(
                    'customerId',
                    isEqualTo:
                        customerId,
                  )
                  .get();

          DateTime newest =
              DateTime
                  .fromMillisecondsSinceEpoch(
            0,
          );

          for (final ride
              in rides.docs) {
            final data =
                ride.data();

            final status =
                stringValue(
              data['status'],
            );

            final active =
                status == 'searching' ||
                    status ==
                        'accepted' ||
                    status ==
                        'arrived' ||
                    status ==
                        'started';

            if (!active) continue;

            final created =
                timestampToDate(
                  data['createdAt'],
                ) ??
                DateTime
                    .fromMillisecondsSinceEpoch(
                  0,
                );

            if (created
                .isAfter(newest)) {
              newest = created;
              rideId = ride.id;
            }
          }
        }
      }

      if (rideId.isEmpty) {
        return;
      }

      final snap =
          await FirebaseFirestore
              .instance
              .collection(
                'ride_requests',
              )
              .doc(rideId)
              .get();

      if (!snap.exists) {
        await prefs.remove(
          'customer_active_ride_id',
        );
        return;
      }

      final status =
          stringValue(
        snap.data()?['status'],
      );

      final active =
          status == 'searching' ||
              status == 'accepted' ||
              status == 'arrived' ||
              status == 'started';

      if (!active) {
        await prefs.remove(
          'customer_active_ride_id',
        );
        return;
      }

      await prefs.setString(
        'customer_active_ride_id',
        rideId,
      );

      if (!mounted) return;

      setState(() {
        _rideRequestId =
            rideId;
      });

      _showRideTracking();
    } catch (_) {
      // نخلي التطبيق يفتح حتى إذا صار خطأ شبكة.
    } finally {
      _restoringActiveRide =
          false;
    }
  }

  Future<bool>
      _isRideStillActive(
    String rideId,
  ) async {
    try {
      final snap =
          await FirebaseFirestore
              .instance
              .collection(
                'ride_requests',
              )
              .doc(rideId)
              .get();

      if (!snap.exists) {
        return false;
      }

      final status =
          stringValue(
        snap.data()?['status'],
      );

      return status ==
              'searching' ||
          status ==
              'accepted' ||
          status ==
              'arrived' ||
          status ==
              'started';
    } catch (_) {
      return true;
    }
  }

  Future<void> _sendRideRequest() async {
    if (_pickup == null || _destination == null) return;
    if (_sendingRequest) return;

    setState(() {
      _sendingRequest = true;
    });

    try {
      final customerId = widget.customerId ?? '';

      // منع إنشاء رحلتين نشطات لنفس الزبون.
      if (customerId.isNotEmpty) {
        final existing = await FirebaseFirestore.instance
            .collection('ride_requests')
            .where('customerId', isEqualTo: customerId)
            .get();

        for (final ride in existing.docs) {
          final status =
              stringValue(ride.data()['status']);

          if (status == 'searching' ||
              status == 'accepted' ||
              status == 'arrived' ||
              status == 'started') {
            throw Exception(
              'عندك رحلة حالية. افتح الرحلة أو الغيها قبل طلب رحلة جديدة.',
            );
          }
        }
      }

      final prefs =
          await SharedPreferences.getInstance();

      await prefs.setString(
        'last_customer_name',
        _customerNameController.text.trim(),
      );

      await prefs.setString(
        'last_customer_phone',
        _customerPhoneController.text.trim(),
      );

      final rideRef =
          FirebaseFirestore.instance
              .collection(
                'ride_requests',
              )
              .doc();

      var pickupArea =
          compactPlaceName(
        _pickupAddress,
      );

      var destinationArea =
          compactPlaceName(
        _destinationAddress,
      );

      final areaResults =
          await Future.wait<String>([
        placeNeedsAreaLookup(
          _pickupAddress,
        )
            ? GoogleMapsService
                .reverseGeocodeArea(
                _pickup!,
              )
            : Future.value(
                pickupArea,
              ),
        placeNeedsAreaLookup(
          _destinationAddress,
        )
            ? GoogleMapsService
                .reverseGeocodeArea(
                _destination!,
              )
            : Future.value(
                destinationArea,
              ),
      ]).timeout(
        const Duration(
          seconds: 5,
        ),
        onTimeout: () =>
            <String>[
          pickupArea,
          destinationArea,
        ],
      );

      if (areaResults[0]
          .trim()
          .isNotEmpty) {
        pickupArea =
            areaResults[0]
                .trim();
      }

      if (areaResults[1]
          .trim()
          .isNotEmpty) {
        destinationArea =
            areaResults[1]
                .trim();
      }

      final rewardToUse =
          _rewardApplied;

      final rideData = <String, dynamic>{
        'status': 'searching',
        'customerId': widget.customerId,
        'customerName':
            _customerNameController.text.trim(),
        'customerPhone':
            _customerPhoneController.text.trim(),
        'pickupLat': _pickup!.latitude,
        'pickupLng': _pickup!.longitude,
        'pickupAddress':
            _pickupAddress,
        'pickupArea':
            pickupArea,
        'destinationLat':
            _destination!.latitude,
        'destinationLng':
            _destination!.longitude,
        'destinationAddress':
            _destinationAddress,
        'destinationArea':
            destinationArea,
        'distanceKm': _distanceKm,
        'routeDistanceMeters': _routeDistanceMeters,
        'routeDuration': _routeDuration,
        'routePolyline': _routeEncodedPolyline,
        'originalPrice': _price,
        'discountAmount': _discountAmount,
        'promoCode': _promoCode,
        'rewardDiscount': rewardToUse,
        'rewardRefunded': false,
        'price': _finalPrice,
        'pricingModel': 'dynamic_v1',
        'trafficLabel': _trafficLabel,
        'pricingHour': DateTime.now().hour,
        'commissionPercent': PricingSettingsService.commissionPercent,
        'pricingSettings': PricingSettingsService.snapshot(),
        'commissionAmount':
            commissionForFare(_finalPrice),
        'commissionCharged': false,
        'driverId': null,
        'driverName': null,
        'driverPhone': null,
        'driverLat': null,
        'driverLng': null,
        'createdAt': FieldValue.serverTimestamp(),
        'acceptedAt': null,
        'arrivedAt': null,
        'startedAt': null,
        'completedAt': null,
        'canceledAt': null,
      };

      if (customerId.isNotEmpty &&
          rewardToUse > 0) {
        final customerRef =
            FirebaseFirestore.instance
                .collection('customers')
                .doc(customerId);

        final rewardTxRef =
            FirebaseFirestore.instance
                .collection(
                  'customer_reward_transactions',
                )
                .doc();

        await FirebaseFirestore.instance
            .runTransaction(
          (transaction) async {
            final customerSnap =
                await transaction.get(customerRef);

            if (!customerSnap.exists) {
              throw Exception(
                'حساب الزبون غير موجود',
              );
            }

            final available = intValue(
              customerSnap.data()?['rewardBalance'],
            );

            if (available < rewardToUse) {
              throw Exception(
                'رصيد المكافآت تغير. ارجع وحاول مرة ثانية.',
              );
            }

            transaction.update(customerRef, {
              'rewardBalance':
                  available - rewardToUse,
              'rewardUpdatedAt':
                  FieldValue.serverTimestamp(),
            });

            transaction.set(rewardTxRef, {
              'customerId': customerId,
              'rideId': rideRef.id,
              'type': 'ride_discount',
              'amount': -rewardToUse,
              'creditBefore': available,
              'creditAfter':
                  available - rewardToUse,
              'createdAt':
                  FieldValue.serverTimestamp(),
            });

            transaction.set(
              rideRef,
              rideData,
            );
          },
        );

        if (mounted) {
          setState(() {
            _rewardBalance -= rewardToUse;
            if (_rewardBalance < 0) {
              _rewardBalance = 0;
            }
          });
        }
      } else {
        await rideRef.set(rideData);
      }

      await ExternalPushService
          .notifyDriversForNewRide(
        rideId: rideRef.id,
        pickupLat: _pickup!.latitude,
        pickupLng: _pickup!.longitude,
        fare: _finalPrice,
      );

      if (_promoCode.isNotEmpty) {
        await PromoService.markUsed(
          code: _promoCode,
          customerId: customerId,
        );
      }

      await prefs.setString(
        'customer_active_ride_id',
        rideRef.id,
      );

      if (!mounted) return;

      setState(() {
        _rideRequestId =
            rideRef.id;
        _sendingRequest =
            false;
      });

      _showRideTracking();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _sendingRequest = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e
                .toString()
                .replaceFirst('Exception: ', ''),
          ),
        ),
      );
    }
  }

  void _showRideTracking() {
    final rideId = _rideRequestId;
    if (rideId == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerRideTrackingPage(
          rideId: rideId,
        ),
      ),
    ).then((_) async {
      final prefs =
          await SharedPreferences
              .getInstance();

      final active =
          await _isRideStillActive(
        rideId,
      );

      if (active) {
        await prefs.setString(
          'customer_active_ride_id',
          rideId,
        );
      } else {
        await prefs.remove(
          'customer_active_ride_id',
        );
      }

      if (!mounted) return;

      setState(() {
        _rideRequestId =
            active
                ? rideId
                : null;
      });
    });
  }

  Widget _buildCustomerDrawer() {
    final name = _customerNameController.text.trim().isEmpty
        ? 'حساب الزبون'
        : _customerNameController.text.trim();

    final phone = _customerPhoneController.text.trim().isEmpty
        ? 'رقم الموبايل'
        : _customerPhoneController.text.trim();

    void closeDrawer() {
      Navigator.pop(context);
    }

    Widget item({
      required IconData icon,
      required String title,
      String? subtitle,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 22,
            vertical: 18,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 29,
                color: const Color(0xff646A78),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Color(0xff202538),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xff7C8190),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Drawer(
        width: MediaQuery.of(context).size.width * 0.88,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  22,
                  16,
                  22,
                  18,
                ),
                child: Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 38,
                      backgroundColor:
                          const Color(0xffF2F3F7),
                      child: const Icon(
                        Icons.person_rounded,
                        size: 47,
                        color: Color(0xff8C919C),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.only(top: 5),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight:
                                    FontWeight.w900,
                                color:
                                    Color(0xff202538),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              phone,
                              textDirection:
                                  TextDirection.ltr,
                              style: const TextStyle(
                                fontSize: 14,
                                color:
                                    Color(0xff7A7F8C),
                                fontWeight:
                                    FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: closeDrawer,
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 30,
                        color: Color(0xff646A78),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(
                height: 1,
                color: Color(0xffECEEF2),
              ),

              item(
                icon: Icons.notifications_none_rounded,
                title: 'الإشعارات',
                subtitle: 'تنبيهات الرحلات والرسائل والعروض',
                onTap: () {
                  closeDrawer();
                  final customerId =
                      widget.customerId ?? '';

                  Future.delayed(
                    const Duration(
                      milliseconds: 180,
                    ),
                    () {
                      if (!mounted) return;

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              AppNotificationsPage(
                            role: 'customer',
                            userId: customerId,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),

              const Divider(
                height: 1,
                indent: 22,
                endIndent: 22,
                color: Color(0xffECEEF2),
              ),

              item(
                icon: Icons.history_rounded,
                title: 'الرحلات',
                onTap: () {
                  closeDrawer();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const CustomerRideHistoryPage(),
                    ),
                  );
                },
              ),

              const Divider(
                height: 1,
                indent: 22,
                endIndent: 22,
                color: Color(0xffECEEF2),
              ),

              item(
                icon: Icons.star_border_rounded,
                title: 'المواقع المختارة',
                onTap: () {
                  closeDrawer();
                  Future.delayed(
                    const Duration(milliseconds: 180),
                    _openSavedPlaces,
                  );
                },
              ),

              const Divider(
                height: 1,
                indent: 22,
                endIndent: 22,
                color: Color(0xffECEEF2),
              ),

              item(
                icon: Icons.local_offer_outlined,
                title: 'التخفيضات والمكافآت',
                onTap: () async {
                  closeDrawer();

                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RewardsPage(
                        role: 'customer',
                        userId: widget.customerId ?? '',
                      ),
                    ),
                  );

                  // إذا استلم الزبون مكافأة نحدث رصيد الخصم مباشرة
                  // حتى يظهر بالحجز بدون ما يغلق ويفتح التطبيق.
                  if (mounted) {
                    await _loadCustomerProfile();
                  }
                },
              ),

              const Divider(
                height: 1,
                indent: 22,
                endIndent: 22,
                color: Color(0xffECEEF2),
              ),

              item(
                icon: Icons.settings_outlined,
                title: 'الإعدادات',
                onTap: () {
                  closeDrawer();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const CustomerAccountPage(),
                    ),
                  );
                },
              ),

              const Spacer(),

              Container(
                width: double.infinity,
                color: const Color(0xffF7F7FF),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 18,
                ),
                child: InkWell(
                  borderRadius:
                      BorderRadius.circular(18),
                  onTap: () {
                    closeDrawer();

                    final customerId =
                        widget.customerId ?? '';

                    Future.delayed(
                      const Duration(milliseconds: 180),
                      () {
                        if (!mounted) return;

                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                TechnicalSupportPage(
                              role: 'customer',
                              userId: customerId,
                              userName:
                                  _customerNameController
                                      .text
                                      .trim(),
                              userPhone:
                                  _customerPhoneController
                                      .text
                                      .trim(),
                            ),
                          ),
                        );
                      },
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.support_agent_rounded,
                          size: 31,
                          color: Color(0xff1616FF),
                        ),
                        SizedBox(width: 15),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                'الاتصال بالدعم',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight:
                                      FontWeight.w900,
                                  color:
                                      Color(0xff202538),
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'تواصل معنا في حال مواجهة أي مشكلة',
                                style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      Color(0xff737785),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initialCenter = _currentLocation ??
        const LatLng(
          33.3152,
          44.3661,
        );

    return Scaffold(
      key: _customerScaffoldKey,
      resizeToAvoidBottomInset: false,
      drawer: _buildCustomerDrawer(),
      drawerScrimColor: Colors.black26,
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: initialCenter,
                zoom: 16,
              ),
              onMapCreated: (controller) {
                _mapController = controller;
              },
              myLocationEnabled: _currentLocation != null,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: true,
              buildingsEnabled: true,
              trafficEnabled: false,
              onCameraMove: _onCameraMove,
              onCameraIdle: _onCameraIdle,
              markers: {
                if (_pickup != null)
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: _pickup!,
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueGreen,
                    ),
                    infoWindow: InfoWindow(
                      title: 'نقطة الانطلاق',
                      snippet: _pickupAddress,
                    ),
                  ),
                if (_destination != null && _selectionStep == 2)
                  Marker(
                    markerId: const MarkerId('destination'),
                    position: _destination!,
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueRed,
                    ),
                    infoWindow: InfoWindow(
                      title: 'نقطة الوصول',
                      snippet: _destinationAddress,
                    ),
                  ),
              },
              polylines: {
                if (_selectionStep == 2 && _routePoints.isNotEmpty)
                  Polyline(
                    polylineId: const PolylineId('google_route'),
                    points: _routePoints,
                    width: 8,
                    color: const Color(0xff171717),
                    startCap: Cap.roundCap,
                    endCap: Cap.roundCap,
                    jointType: JointType.round,
                  ),
              },
            ),
          ),

          // الدبوس ثابت بالنص أثناء اختيار الانطلاق أو الوصول.
          if (_selectionStep < 2)
            IgnorePointer(
              child: Center(
                child: Transform.translate(
                  offset: const Offset(0, -24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_pin,
                        size: 56,
                        color: _selectionStep == 0
                            ? Colors.green
                            : Colors.red,
                      ),
                      Container(
                        width: 22,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Colors.black12,
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        elevation: 4,
                        child: IconButton(
                          onPressed: () {
                            _customerScaffoldKey
                                .currentState
                                ?.openDrawer();
                          },
                          icon: const Icon(
                            Icons.menu_rounded,
                          ),
                          tooltip: 'القائمة',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Material(
                          color: Colors.white,
                          borderRadius:
                              BorderRadius.circular(18),
                          elevation: 4,
                          child: TextField(
                            controller:
                                _mapSearchController,
                            focusNode: _mapSearchFocus,
                            onTap: _openTopSearch,
                            onChanged:
                                _onMapSearchChanged,
                            textInputAction:
                                TextInputAction.search,
                            decoration:
                                InputDecoration(
                              hintText: _selectionStep == 0
                                  ? 'ابحث عن نقطة الانطلاق'
                                  : _selectionStep == 1
                                      ? 'ابحث عن نقطة الوصول'
                                      : 'غيّر الوجهة أو ابحث عن مكان',
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                ),
                                suffixIcon:
                                    _mapSearchController
                                            .text
                                            .isEmpty
                                        ? null
                                        : IconButton(
                                            onPressed: () {
                                              _mapSearchController
                                                  .clear();
                                              _onMapSearchChanged(
                                                '',
                                              );
                                            },
                                            icon: const Icon(
                                              Icons
                                                  .close_rounded,
                                            ),
                                          ),
                                filled: true,
                                fillColor: Colors.white,
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                border:
                                    OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(
                                    18,
                                  ),
                                  borderSide:
                                      BorderSide.none,
                                ),
                                enabledBorder:
                                    OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(
                                    18,
                                  ),
                                  borderSide:
                                      BorderSide.none,
                                ),
                                focusedBorder:
                                    OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(
                                    18,
                                  ),
                                  borderSide:
                                      const BorderSide(
                                    color:
                                        Color(0xffFFC107),
                                    width: 1.3,
                                  ),
                                ),
                              ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Material(
                        color: Colors.white,
                        borderRadius:
                            BorderRadius.circular(18),
                        elevation: 4,
                        child: NotificationBadgeIcon(
                          role: 'customer',
                          userId:
                              widget.customerId ?? '',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AppNotificationsPage(
                                  role:
                                      'customer',
                                  userId: widget
                                          .customerId ??
                                      '',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),

                  if (_showMapSearchResults ||
                      _mapSearchLoading) ...[
                    const SizedBox(height: 8),
                    Material(
                      color: Colors.white,
                      elevation: 8,
                      borderRadius:
                          BorderRadius.circular(20),
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(
                          maxHeight: 300,
                        ),
                        child: _mapSearchLoading
                            ? const Padding(
                                padding:
                                    EdgeInsets.all(20),
                                child: Center(
                                  child:
                                      CircularProgressIndicator(),
                                ),
                              )
                            : _mapSearchResults.isEmpty
                                ? Padding(
                                    padding:
                                        const EdgeInsets.all(
                                      18,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons
                                              .location_searching_rounded,
                                          color:
                                              Colors.black45,
                                        ),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Expanded(
                                          child: Text(
                                            _mapSearchController
                                                        .text
                                                        .trim()
                                                        .length <
                                                    2
                                                ? 'اكتب اسم المنطقة أو المحل'
                                                : 'ما لكينا نتائج، جرّب اسم ثاني',
                                            style:
                                                const TextStyle(
                                              color: Colors
                                                  .black54,
                                              fontWeight:
                                                  FontWeight
                                                      .w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.separated(
                                    shrinkWrap: true,
                                    padding:
                                        const EdgeInsets
                                            .symmetric(
                                      vertical: 6,
                                    ),
                                    itemCount:
                                        _mapSearchResults
                                            .length,
                                    separatorBuilder:
                                        (_, __) =>
                                            const Divider(
                                      height: 1,
                                    ),
                                    itemBuilder:
                                        (context, index) {
                                      final result =
                                          _mapSearchResults[
                                              index];

                                      return ListTile(
                                        leading: Container(
                                          width: 42,
                                          height: 42,
                                          decoration:
                                              BoxDecoration(
                                            color: const Color(
                                              0xffFFF5D1,
                                            ),
                                            borderRadius:
                                                BorderRadius
                                                    .circular(
                                              13,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons
                                                .location_on_rounded,
                                            color: Color(
                                              0xffD49B00,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          result.displayName,
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow
                                                  .ellipsis,
                                          style:
                                              const TextStyle(
                                            fontWeight:
                                                FontWeight
                                                    .w800,
                                          ),
                                        ),
                                        subtitle: result
                                                .secondaryText
                                                .isEmpty
                                            ? null
                                            : Text(
                                                result
                                                    .secondaryText,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow
                                                        .ellipsis,
                                              ),
                                        onTap: () {
                                          _selectMapSearchResult(
                                            result,
                                          );
                                        },
                                      );
                                    },
                                  ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          Positioned(
            right: 14,
            bottom: _selectionStep == 2 ? 265 : 280,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'my_location_google',
                  backgroundColor: Colors.white,
                  onPressed: _getCurrentLocation,
                  child: _loadingLocation
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.my_location,
                          color: Colors.black,
                        ),
                ),
                const SizedBox(height: 8),
                if (_selectionStep < 2)
                  FloatingActionButton.small(
                    heroTag: 'saved_google',
                    backgroundColor: Colors.white,
                    onPressed: _openSavedPlaces,
                    child: const Icon(
                      Icons.bookmarks_outlined,
                      color: Colors.black,
                    ),
                  ),
              ],
            ),
          ),

          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: const Color(0xffEEEEEE),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 24,
                      offset: Offset(0, -6),
                    ),
                  ],
                ),
                child: _selectionStep < 2
                    ? _buildSelectionCard()
                    : _buildRouteCard(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionCard() {
    final isPickup = _selectionStep == 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: isPickup
                  ? Colors.green.shade50
                  : Colors.red.shade50,
              child: Icon(
                isPickup ? Icons.trip_origin : Icons.location_on,
                color: isPickup ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isPickup ? 'حدد نقطة الانطلاق' : 'حدد نقطة الوصول',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _loadingAddress
                        ? 'جاري قراءة العنوان...'
                        : _currentAddress,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black54,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (!isPickup)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _clearPickupSelection,
              icon: const Icon(
                Icons.close_rounded,
                color: Colors.red,
              ),
              label: const Text(
                'إلغاء نقطة الانطلاق',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton.icon(
              onPressed: _addSavedPlace,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('حفظ المكان'),
            ),
            const Spacer(),
            if (_savedPlaces.isNotEmpty)
              TextButton.icon(
                onPressed: _openSavedPlaces,
                icon: const Icon(Icons.bookmarks_outlined),
                label: const Text('المحفوظة'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 56,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: _loadingAddress ? null : _confirmMapPoint,
            child: Text(
              isPickup ? 'تأكيد نقطة الانطلاق' : 'تأكيد نقطة الوصول',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRouteCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ridePointRow(
          dotColor: const Color(0xff26A269),
          title: 'موقعي الحالي',
          subtitle: _pickupAddress.isEmpty
              ? _currentAddress
              : _pickupAddress,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'تعديل نقطة الانطلاق',
                onPressed: _editPickup,
                icon: const Icon(
                  Icons.edit_location_alt_rounded,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: 'إلغاء نقطة الانطلاق',
                onPressed: _clearPickupSelection,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: Colors.red,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 18),
        _ridePointRow(
          dotColor: const Color(0xffF2673A),
          title: 'الوجهة',
          subtitle: _destinationAddress,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'تعديل الوجهة',
                onPressed: _editDestination,
                icon: const Icon(
                  Icons.edit_location_alt_rounded,
                  size: 19,
                ),
              ),
              IconButton(
                tooltip: 'إلغاء الوجهة',
                onPressed: _clearDestinationSelection,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: Colors.red,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  const Color(0xffFFC21A),
              foregroundColor: Colors.black,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(14),
              ),
            ),
            onPressed:
                _loadingRoute ? null : _openCustomerInfo,
            child: _loadingRoute
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  )
                : const Text(
                    'اطلب تكتك',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _ridePointRow({
    required Color dotColor,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Row(
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow:
                    TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black54,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        trailing,
      ],
    );
  }


  Widget _routeInfoBox({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 5),
          Text(
            title,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ============================================================
// PLACE SEARCH
// ============================================================


class GooglePlaceSearchDelegate extends SearchDelegate<PlaceResult?> {
  final LatLng? center;

  GooglePlaceSearchDelegate({
    this.center,
  }) : super(
          searchFieldLabel: 'ابحث عن منطقة، شارع أو محل',
          keyboardType: TextInputType.text,
        );

  Future<List<PlaceResult>> _results() async {
    if (query.trim().length < 2) return [];

    try {
      return await GoogleMapsService.autocomplete(
        query,
        center: center,
      );
    } catch (_) {
      return [];
    }
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          onPressed: () {
            query = '';
          },
          icon: const Icon(Icons.close),
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      onPressed: () {
        close(context, null);
      },
      icon: const Icon(Icons.arrow_back),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildList();

  @override
  Widget buildSuggestions(BuildContext context) => _buildList();

  Widget _buildList() {
    return FutureBuilder<List<PlaceResult>>(
      future: _results(),
      builder: (context, snapshot) {
        if (query.trim().length < 2) {
          return const Center(
            child: Text('اكتب اسم المنطقة أو المحل'),
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final items = snapshot.data ?? [];

        if (items.isEmpty) {
          return const Center(
            child: Text('ما لكينا نتائج'),
          );
        }

        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];

            return ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0xfffff3cd),
                child: Icon(
                  Icons.location_on_outlined,
                  color: Colors.black87,
                ),
              ),
              title: Text(
                item.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: item.secondaryText.isEmpty
                  ? null
                  : Text(
                      item.secondaryText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () async {
                final details = await GoogleMapsService.placeDetails(
                  item.placeId,
                );

                if (!context.mounted) return;

                if (details == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('تعذر فتح هذا المكان'),
                    ),
                  );
                  return;
                }

                close(context, details);
              },
            );
          },
        );
      },
    );
  }
}


class _SmoothDriverApproachMap extends StatefulWidget {
  final LatLng pickup;
  final LatLng? driver;
  final List<LatLng> route;
  final String driverName;

  const _SmoothDriverApproachMap({
    required this.pickup,
    required this.driver,
    required this.route,
    required this.driverName,
  });

  @override
  State<_SmoothDriverApproachMap> createState() =>
      _SmoothDriverApproachMapState();
}

class _SmoothDriverApproachMapState
    extends State<_SmoothDriverApproachMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  LatLng? _from;
  LatLng? _to;

  @override
  void initState() {
    super.initState();
    _from = widget.driver;
    _to = widget.driver;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..value = 1;
  }

  LatLng? _currentAnimatedPoint() {
    if (_from == null) return _to;
    if (_to == null) return _from;

    final t = Curves.easeOutCubic.transform(
      _controller.value,
    );

    return LatLng(
      _from!.latitude +
          (_to!.latitude - _from!.latitude) * t,
      _from!.longitude +
          (_to!.longitude - _from!.longitude) * t,
    );
  }

  @override
  void didUpdateWidget(
    covariant _SmoothDriverApproachMap oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    final oldPoint = oldWidget.driver;
    final newPoint = widget.driver;

    if (newPoint == null) return;

    final changed = oldPoint == null ||
        oldPoint.latitude != newPoint.latitude ||
        oldPoint.longitude != newPoint.longitude;

    if (!changed) return;

    _from = _currentAnimatedPoint() ?? oldPoint ?? newPoint;
    _to = newPoint;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final driver = _currentAnimatedPoint();

        return GoogleMap(
          initialCameraPosition: CameraPosition(
            target: driver ?? widget.pickup,
            zoom: 15.5,
          ),
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          compassEnabled: false,
          markers: {
            Marker(
              markerId: const MarkerId('pickup'),
              position: widget.pickup,
              infoWindow: const InfoWindow(
                title: 'موقعك',
              ),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
            ),
            if (driver != null)
              Marker(
                markerId: const MarkerId('driver'),
                position: driver,
                infoWindow: InfoWindow(
                  title: widget.driverName.isEmpty
                      ? 'السائق'
                      : widget.driverName,
                ),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueOrange,
                ),
              ),
          },
          polylines: {
            if (driver != null)
              Polyline(
                polylineId:
                    const PolylineId('driver_to_customer'),
                points: widget.route.isNotEmpty
                    ? widget.route
                    : <LatLng>[
                        driver,
                        widget.pickup,
                      ],
                width: 7,
                color: const Color(0xff171717),
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
                jointType: JointType.round,
              ),
          },
        );
      },
    );
  }
}


// ============================================================
// CUSTOMER TRACKING
// ============================================================


class CustomerRideTrackingPage extends StatelessWidget {
  final String rideId;

  const CustomerRideTrackingPage({
    super.key,
    required this.rideId,
  });


  Future<void> _cancelRide(
    BuildContext context,
  ) async {
    final reason = await showRideCancelReasonDialog(
      context,
      isDriver: false,
    );

    if (reason == null || reason.trim().isEmpty) return;

    await RideActions.cancelRide(
      rideId: rideId,
      canceledBy: 'customer',
      cancelReason: reason,
    );

    if (!context.mounted) return;

    final prefs =
        await SharedPreferences
            .getInstance();

    await prefs.remove(
      'customer_active_ride_id',
    );

    final customerId =
        prefs.getString(
              'session_user_id',
            ) ??
            '';

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CustomerPage(
          customerId:
              customerId.isEmpty ? null : customerId,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _openChat(
    BuildContext context,
  ) async {
    try {
      final messages =
          await FirebaseFirestore
              .instance
              .collection(
                'ride_requests',
              )
              .doc(rideId)
              .collection(
                'messages',
              )
              .where(
                'senderRole',
                isEqualTo:
                    'driver',
              )
              .get();

      if (messages
          .docs
          .isNotEmpty) {
        final batch =
            FirebaseFirestore
                .instance
                .batch();

        for (final message
            in messages.docs) {
          if (message.data()[
                  'readByCustomer'] ==
              true) {
            continue;
          }

          batch.update(
            message.reference,
            {
              'readByCustomer':
                  true,
              'readByCustomerAt':
                  FieldValue
                      .serverTimestamp(),
            },
          );
        }

        await batch.commit();
      }
    } catch (_) {}

    if (!context.mounted) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            RideChatPage(
          rideId: rideId,
          senderRole:
              'customer',
        ),
      ),
    );
  }

  Future<void> _showRatingDialog(
    BuildContext context,
  ) async {
    int rating = 5;
    final noteController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setLocalState) {
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
                title: const Text(
                  'قيّم الرحلة',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'شلون كانت تجربتك ويا السائق؟',
                      style: TextStyle(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                        5,
                        (index) => IconButton(
                          onPressed: () {
                            setLocalState(() {
                              rating = index + 1;
                            });
                          },
                          icon: Icon(
                            index < rating
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 36,
                            color: const Color(0xffFFC107),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: noteController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'ملاحظة اختيارية',
                      ),
                    ),
                  ],
                ),
                actionsAlignment: MainAxisAlignment.center,
                actions: [
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () async {
                        await FirebaseFirestore.instance
                            .collection('ride_requests')
                            .doc(rideId)
                            .update({
                          'customerRating': rating,
                          'customerRatingNote':
                              noteController.text.trim(),
                          'ratedAt':
                              FieldValue.serverTimestamp(),
                        });

                        if (!dialogContext.mounted) return;
                        Navigator.pop(dialogContext, true);
                      },
                      child: const Text(
                        'إرسال التقييم',
                        style: TextStyle(
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    noteController.dispose();

    if (result == true && context.mounted) {
      Navigator.pop(context);
    }
  }

  int _statusStep(String status) {
    switch (status) {
      case 'accepted':
        return 1;
      case 'arrived':
        return 2;
      case 'started':
        return 3;
      case 'completed':
        return 4;
      default:
        return 0;
    }
  }

  String _customerStatusText(String status) {
    switch (status) {
      case 'searching':
        return 'جاري البحث عن سائق';
      case 'accepted':
        return 'السائق بالطريق إليك';
      case 'arrived':
        return 'السائق وصل لموقعك';
      case 'started':
        return 'الرحلة بدأت';
      case 'completed':
        return 'وصلت بالسلامة';
      case 'canceled':
        return 'تم إلغاء الرحلة';
      default:
        return status;
    }
  }

  String _customerStatusSubtitle(
    String status,
    Map<String, dynamic> data,
  ) {
    final distanceMeters =
        intValue(data['driverRouteDistanceMeters']);

    if (status == 'accepted' && distanceMeters > 0) {
      return 'يبعد عنك ${(distanceMeters / 1000).toStringAsFixed(1)} كم';
    }

    if (status == 'started') {
      final eta =
          _driverEtaText(data['driverRouteDuration']);
      final clock =
          _driverEtaClockText(data['driverRouteDuration']);

      if (clock.isNotEmpty) {
        return 'الوصول $eta • تقريباً $clock';
      }
    }

    switch (status) {
      case 'searching':
        return 'نبحث عن أقرب سائق متاح';
      case 'accepted':
        return 'تابع موقع السائق مباشرة على الخريطة';
      case 'arrived':
        return 'توجه إلى نقطة الالتقاط';
      case 'started':
        return 'السائق متوجه إلى نقطة الوصول';
      case 'completed':
        return 'نتمنى كانت رحلتك مريحة';
      case 'canceled':
        return 'تگدر ترجع وتطلب رحلة جديدة';
      default:
        return '';
    }
  }


  Widget _searchingRideScreen(
    BuildContext context,
    Map<String, dynamic> data,
  ) {
    DateTime createdAt = DateTime.now();
    final rawCreatedAt = data['createdAt'];

    if (rawCreatedAt is Timestamp) {
      createdAt = rawCreatedAt.toDate();
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.fromLTRB(
            18,
            18,
            18,
            18,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 42,
                  ),
                  const Expanded(
                    child: Text(
                      'جاري البحث عن سائق',
                      textAlign:
                          TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 42,
                  ),
                ],
              ),
              const Spacer(flex: 2),
              SizedBox(
                width: 210,
                height: 225,
                child: Image.asset(
                  'assets/images/tuktuk_search_reference.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 20),
              StreamBuilder<int>(
                stream: Stream<int>.periodic(
                  const Duration(seconds: 1),
                  (value) => value,
                ),
                builder: (context, snapshot) {
                  final elapsed =
                      DateTime.now()
                          .difference(createdAt);

                  final totalSeconds =
                      elapsed.inSeconds < 0
                          ? 0
                          : elapsed.inSeconds;

                  final minutes =
                      totalSeconds ~/ 60;
                  final seconds =
                      totalSeconds % 60;

                  final value =
                      '${minutes.toString().padLeft(2, '0')}:'
                      '${seconds.toString().padLeft(2, '0')}';

                  String friendlyMessage;
                  if (totalSeconds < 20) {
                    friendlyMessage =
                        'ندور لك على أقرب سائق 🚕';
                  } else if (totalSeconds < 60) {
                    friendlyMessage =
                        'لحظات ونحاول نلقى لك سائق قريب 💛';
                  } else {
                    friendlyMessage =
                        'السائقين القريبين مشغولين شوي، ومستمرين بالبحث عنك';
                  }

                  return Column(
                    children: [
                      Text(
                        friendlyMessage,
                        textAlign:
                            TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight:
                              FontWeight.w700,
                        ),
                      ),
                      const SizedBox(
                        height: 7,
                      ),
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight:
                              FontWeight.w900,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  style:
                      OutlinedButton.styleFrom(
                    side:
                        const BorderSide(
                      color:
                          Color(0xffE75555),
                    ),
                    foregroundColor:
                        const Color(
                      0xffD94141,
                    ),
                    elevation: 0,
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(
                        12,
                      ),
                    ),
                  ),
                  onPressed: () =>
                      _cancelRide(context),
                  child: const Text(
                    'إلغاء الطلب',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  int _driverEtaSeconds(dynamic rawDuration) {
    final raw = stringValue(rawDuration).trim();
    if (raw.isEmpty) return 0;
    return (double.tryParse(
              raw.replaceAll('s', ''),
            ) ??
            0)
        .round();
  }

  String _driverEtaText(dynamic rawDuration) {
    final seconds = _driverEtaSeconds(rawDuration);
    if (seconds <= 0) return 'جاري حساب وقت الوصول';

    final minutes = (seconds / 60).ceil();
    if (minutes <= 1) return 'حوالي دقيقة';
    if (minutes < 60) return 'حوالي $minutes دقيقة';

    final hours = minutes ~/ 60;
    final remain = minutes % 60;
    if (remain == 0) return 'حوالي $hours ساعة';
    return 'حوالي $hours ساعة و$remain دقيقة';
  }

  String _driverEtaClockText(dynamic rawDuration) {
    final seconds = _driverEtaSeconds(rawDuration);
    if (seconds <= 0) return '';

    final arrival = DateTime.now().add(
      Duration(seconds: seconds),
    );

    final hour = arrival.hour % 12 == 0
        ? 12
        : arrival.hour % 12;
    final minute =
        arrival.minute.toString().padLeft(2, '0');
    final period =
        arrival.hour >= 12 ? 'م' : 'ص';

    return '$hour:$minute $period';
  }

  Widget _acceptedRideScreen(
    BuildContext context,
    Map<String, dynamic> data,
  ) {
    final driverName =
        stringValue(data['driverName']).trim();
    final driverPhone =
        stringValue(data['driverPhone']).trim();
    final driverPhoto =
        stringValue(data['driverProfilePhotoUrl']).trim();
    final tuktukNumber =
        stringValue(data['driverTuktukNumber']).trim();
    final tuktukColor =
        stringValue(data['driverTuktukColor']).trim();
    final rating = doubleValue(
      data['driverRating'] ?? data['rating'],
    );

    final pickup = LatLng(
      doubleValue(data['pickupLat']),
      doubleValue(data['pickupLng']),
    );

    LatLng? driver;
    if (data['driverLat'] != null &&
        data['driverLng'] != null) {
      driver = LatLng(
        doubleValue(data['driverLat']),
        doubleValue(data['driverLng']),
      );
    }

    final driverRoute =
        GoogleMapsService.decodePolyline(
      stringValue(data['driverRoutePolyline']),
    );

    final distanceMeters =
        intValue(data['driverRouteDistanceMeters']);
    final distanceText = distanceMeters > 0
        ? '${(distanceMeters / 1000).toStringAsFixed(1)} كم'
        : 'جاري حساب المسافة';
    final etaText =
        _driverEtaText(data['driverRouteDuration']);
    final etaClock =
        _driverEtaClockText(data['driverRouteDuration']);

    final mapTarget = driver ?? pickup;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned.fill(
            child: _SmoothDriverApproachMap(
              pickup: pickup,
              driver: driver,
              route: driverRoute,
              driverName: driverName,
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 2,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(context),
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.arrow_forward_rounded,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x18000000),
                          blurRadius: 14,
                        ),
                      ],
                    ),
                    child: const Text(
                      'السائق بالطريق إليك',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 28,
                      offset: Offset(0, -8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 42,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xffE4E4E4),
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xffFFF7D8),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'وقت الوصول',
                                  style: TextStyle(
                                    color: Colors.black54,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  etaClock.isEmpty
                                      ? etaText
                                      : '$etaText • $etaClock',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 12,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xffF2F4F7),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'يبعد عنك',
                                  style: TextStyle(
                                    color: Colors.black54,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  distanceText,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor:
                              const Color(0xffFFF3C4),
                          backgroundImage: driverPhoto.isNotEmpty
                              ? NetworkImage(driverPhoto)
                              : null,
                          child: driverPhoto.isEmpty
                              ? const Icon(
                                  Icons.person_rounded,
                                  color: Colors.black54,
                                  size: 30,
                                )
                              : null,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      driverName.isEmpty
                                          ? 'السائق'
                                          : driverName,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                  if (data['driverVerified'] == true) ...[
                                    const SizedBox(width: 5),
                                    const Icon(
                                      Icons.verified_rounded,
                                      size: 18,
                                      color: Color(0xff3178F6),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 17,
                                    color: Color(0xffFFC107),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    rating > 0
                                        ? rating.toStringAsFixed(1)
                                        : 'جديد',
                                    style: const TextStyle(
                                      color: Colors.black54,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              if (tuktukNumber.isNotEmpty ||
                                  tuktukColor.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '${tuktukColor.isNotEmpty ? 'تكتك $tuktukColor' : 'تكتك'}${tuktukNumber.isNotEmpty ? ' • رقم $tuktukNumber' : ''}',
                                  style: const TextStyle(
                                    color: Colors.black54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('ride_requests')
                          .doc(rideId)
                          .collection('messages')
                          .where(
                            'senderRole',
                            isEqualTo: 'driver',
                          )
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData ||
                            snapshot.data!.docs.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        QueryDocumentSnapshot? latestDoc;
                        int latestMillis = -1;

                        for (final doc in snapshot.data!.docs) {
                          final messageData =
                              doc.data() as Map<String, dynamic>;
                          final createdAt = messageData['createdAt'];
                          final millis = createdAt is Timestamp
                              ? createdAt.millisecondsSinceEpoch
                              : 0;

                          if (latestDoc == null || millis >= latestMillis) {
                            latestDoc = doc;
                            latestMillis = millis;
                          }
                        }

                        final message = latestDoc!.data()
                            as Map<String, dynamic>;
                        final text = stringValue(message['text']).trim();
                        if (text.isEmpty) return const SizedBox.shrink();

                        return InkWell(
                          borderRadius: BorderRadius.circular(15),
                          onTap: () => _openChat(context),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xffF7F8FA),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.chat_bubble_rounded,
                                  size: 19,
                                  color: Color(0xffA97400),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'السائق: $text',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _rideContactAction(
                            icon: Icons.phone_rounded,
                            label: 'اتصال',
                            onTap: driverPhone.isEmpty
                                ? null
                                : () async {
                                    await launchUrl(
                                      Uri(
                                        scheme: 'tel',
                                        path: driverPhone,
                                      ),
                                    );
                                  },
                          ),
                        ),
                        Expanded(
                          child: StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('ride_requests')
                                .doc(rideId)
                                .collection('messages')
                                .where(
                                  'senderRole',
                                  isEqualTo: 'driver',
                                )
                                .snapshots(),
                            builder: (context, snapshot) {
                              int unread = 0;
                              if (snapshot.hasData) {
                                for (final doc in snapshot.data!.docs) {
                                  final message = doc.data()
                                      as Map<String, dynamic>;
                                  if (message['readByCustomer'] != true) {
                                    unread++;
                                  }
                                }
                              }

                              return _rideContactActionWithBadge(
                                icon: Icons.chat_bubble_outline_rounded,
                                label: 'رسالة',
                                badgeCount: unread,
                                onTap: () => _openChat(context),
                              );
                            },
                          ),
                        ),
                        Expanded(
                          child: _rideContactAction(
                            icon: Icons.cancel_outlined,
                            label: 'إلغاء الرحلة',
                            danger: true,
                            onTap: () => _cancelRide(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _rideContactActionWithBadge({
    required IconData icon,
    required String label,
    required int badgeCount,
    required Future<void> Function()? onTap,
  }) {
    return InkWell(
      borderRadius:
          BorderRadius.circular(18),
      onTap: onTap == null
          ? null
          : () {
              onTap();
            },
      child: Padding(
        padding:
            const EdgeInsets.symmetric(
          vertical: 10,
          horizontal: 4,
        ),
        child: Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Stack(
              clipBehavior:
                  Clip.none,
              children: [
                Icon(
                  icon,
                  size: 28,
                  color:
                      const Color(
                    0xff202124,
                  ),
                ),
                if (badgeCount > 0)
                  PositionedDirectional(
                    end: -10,
                    top: -10,
                    child:
                        Container(
                      constraints:
                          const BoxConstraints(
                        minWidth: 20,
                        minHeight:
                            20,
                      ),
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal:
                            5,
                      ),
                      alignment:
                          Alignment
                              .center,
                      decoration:
                          const BoxDecoration(
                        color:
                            Colors.red,
                        shape:
                            BoxShape
                                .circle,
                      ),
                      child: Text(
                        badgeCount > 9
                            ? '9+'
                            : '$badgeCount',
                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                          fontSize:
                              11,
                          fontWeight:
                              FontWeight
                                  .w900,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(
              height: 6,
            ),
            Text(
              label,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight
                        .w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rideContactAction({
    required IconData icon,
    required String label,
    required Future<void> Function()? onTap,
    bool danger = false,
  }) {
    final color = danger
        ? Colors.red
        : const Color(0xff202124);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap == null
          ? null
          : () {
              onTap();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 12,
          horizontal: 4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: onTap == null
                  ? Colors.black26
                  : color,
              size: 27,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: onTap == null
                    ? Colors.black26
                    : color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('ride_requests')
              .doc(rideId)
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            final raw = snapshot.data!.data();

            if (raw == null) {
              return const Center(
                child: Text('الرحلة غير موجودة'),
              );
            }

            final data = raw as Map<String, dynamic>;
            final status = stringValue(data['status']);

            if (status == 'canceled') {
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!context.mounted) return;

                final prefs =
                    await SharedPreferences.getInstance();
                final customerId =
                    prefs.getString('session_user_id') ?? '';

                if (!context.mounted) return;

                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                    builder: (_) => CustomerPage(
                      customerId:
                          customerId.isEmpty ? null : customerId,
                    ),
                  ),
                  (route) => false,
                );
              });

              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            final step = _statusStep(status);

            final pickup = LatLng(
              doubleValue(data['pickupLat']),
              doubleValue(data['pickupLng']),
            );

            final destination = LatLng(
              doubleValue(data['destinationLat']),
              doubleValue(data['destinationLng']),
            );

            final storedTripRoute =
                GoogleMapsService.decodePolyline(
              stringValue(data['routePolyline']),
            );

            final tripRoute = storedTripRoute.isNotEmpty
                ? storedTripRoute
                : <LatLng>[pickup, destination];

            final storedDriverRoute =
                GoogleMapsService.decodePolyline(
              stringValue(data['driverRoutePolyline']),
            );

            LatLng? driver;

            if (data['driverLat'] != null &&
                data['driverLng'] != null) {
              driver = LatLng(
                doubleValue(data['driverLat']),
                doubleValue(data['driverLng']),
              );
            }

            final driverName =
                stringValue(data['driverName']);
            final driverPhone =
                stringValue(data['driverPhone']);
            final driverProfilePhotoUrl =
                stringValue(data['driverProfilePhotoUrl']);
            final driverVerified =
                data['driverVerified'] == true;
            final driverTuktukNumber =
                stringValue(data['driverTuktukNumber']).trim();
            final driverTuktukColor =
                stringValue(data['driverTuktukColor']).trim();
            final fare = intValue(data['price']);
            final alreadyRated =
                intValue(data['customerRating']) > 0;

            if (status == 'searching') {
              return _searchingRideScreen(
                context,
                data,
              );
            }

            if (status == 'accepted') {
              return _acceptedRideScreen(
                context,
                data,
              );
            }

            return Stack(
              children: [
                Positioned.fill(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: driver ?? pickup,
                      zoom: 15,
                    ),
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    myLocationButtonEnabled: false,
                    markers: {
                      Marker(
                        markerId:
                            const MarkerId('pickup'),
                        position: pickup,
                        infoWindow:
                            const InfoWindow(
                          title: 'نقطة الانطلاق',
                        ),
                        icon: BitmapDescriptor
                            .defaultMarkerWithHue(
                          BitmapDescriptor.hueGreen,
                        ),
                      ),
                      Marker(
                        markerId:
                            const MarkerId('destination'),
                        position: destination,
                        infoWindow:
                            const InfoWindow(
                          title: 'نقطة الوصول',
                        ),
                        icon: BitmapDescriptor
                            .defaultMarkerWithHue(
                          BitmapDescriptor.hueRed,
                        ),
                      ),
                      if (driver != null)
                        Marker(
                          markerId:
                              const MarkerId('driver'),
                          position: driver,
                          infoWindow:
                              const InfoWindow(
                            title: 'السائق',
                          ),
                          icon: BitmapDescriptor
                              .defaultMarkerWithHue(
                            BitmapDescriptor.hueOrange,
                          ),
                        ),
                    },
                    polylines: {
                      Polyline(
                        polylineId:
                            const PolylineId('trip'),
                        points: tripRoute,
                        width: 5,
                        color:
                            const Color(0xff777C86),
                        startCap: Cap.roundCap,
                        endCap: Cap.roundCap,
                        jointType: JointType.round,
                      ),
                      if (driver != null &&
                          storedDriverRoute.isNotEmpty)
                        Polyline(
                          polylineId:
                              const PolylineId(
                            'driver_live_route',
                          ),
                          points: storedDriverRoute,
                          width: 8,
                          color:
                              const Color(0xff171717),
                          startCap: Cap.roundCap,
                          endCap: Cap.roundCap,
                          jointType:
                              JointType.round,
                        ),
                    },
                  ),
                ),

                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Material(
                          color: Colors.white,
                          borderRadius:
                              BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius:
                                BorderRadius.circular(18),
                            onTap: () =>
                                Navigator.pop(context),
                            child: const SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(
                                Icons
                                    .arrow_forward_rounded,
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius:
                                BorderRadius.circular(18),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(
                                  0x18000000,
                                ),
                                blurRadius: 14,
                              ),
                            ],
                          ),
                          child: Text(
                            '$fare د.ع',
                            style: const TextStyle(
                              fontWeight:
                                  FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    child: Container(
                      margin:
                          const EdgeInsets.all(12),
                      padding:
                          const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius:
                            BorderRadius.circular(30),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(
                              0x22000000,
                            ),
                            blurRadius: 28,
                            offset: Offset(0, -8),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 5,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xffE4E4E4,
                              ),
                              borderRadius:
                                  BorderRadius.circular(
                                30,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration:
                                    BoxDecoration(
                                  color: const Color(
                                    0xffFFF3C4,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(17),
                                ),
                                child: Icon(
                                  status == 'completed'
                                      ? Icons
                                          .check_rounded
                                      : status ==
                                              'started'
                                          ? Icons
                                              .route_rounded
                                          : Icons
                                              .electric_rickshaw_rounded,
                                  color: const Color(
                                    0xff1B1B1B,
                                  ),
                                  size: 28,
                                ),
                              ),
                              const SizedBox(
                                width: 12,
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    Text(
                                      _customerStatusText(
                                        status,
                                      ),
                                      style:
                                          const TextStyle(
                                        fontSize: 20,
                                        fontWeight:
                                            FontWeight
                                                .w900,
                                      ),
                                    ),
                                    const SizedBox(
                                      height: 3,
                                    ),
                                    Text(
                                      _customerStatusSubtitle(
                                        status,
                                        data,
                                      ),
                                      style:
                                          const TextStyle(
                                        color: Colors
                                            .black54,
                                        fontWeight:
                                            FontWeight
                                                .w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          if (status != 'searching' &&
                              status != 'canceled') ...[
                            const SizedBox(height: 17),
                            Row(
                              children:
                                  List.generate(
                                4,
                                (index) {
                                  final active =
                                      step >= index + 1;
                                  return Expanded(
                                    child: Container(
                                      height: 5,
                                      margin:
                                          EdgeInsetsDirectional
                                              .only(
                                        end: index == 3
                                            ? 0
                                            : 5,
                                      ),
                                      decoration:
                                          BoxDecoration(
                                        color: active
                                            ? const Color(
                                                0xffFFC107,
                                              )
                                            : const Color(
                                                0xffEEEEEE,
                                              ),
                                        borderRadius:
                                            BorderRadius
                                                .circular(
                                          10,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],

                          if (driverName.isNotEmpty &&
                              status !=
                                  'completed') ...[
                            const SizedBox(height: 16),
                            Container(
                              padding:
                                  const EdgeInsets.all(13),
                              decoration:
                                  BoxDecoration(
                                color: const Color(
                                  0xffF7F8FA,
                                ),
                                borderRadius:
                                    BorderRadius.circular(
                                  20,
                                ),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 24,
                                    backgroundColor:
                                        const Color(0xffFFC107),
                                    backgroundImage:
                                        driverProfilePhotoUrl.isNotEmpty
                                            ? NetworkImage(
                                                driverProfilePhotoUrl,
                                              )
                                            : null,
                                    child: driverProfilePhotoUrl.isEmpty
                                        ? const Icon(
                                            Icons.person_rounded,
                                            color: Colors.black,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(
                                    width: 11,
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment
                                              .start,
                                      children: [
                                        const Text(
                                          'السائق',
                                          style:
                                              TextStyle(
                                            fontSize: 12,
                                            color: Colors
                                                .black54,
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                driverName,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style:
                                                    const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w900,
                                                  fontSize: 16,
                                                ),
                                              ),
                                            ),
                                            if (driverVerified) ...[
                                              const SizedBox(width: 5),
                                              const Icon(
                                                Icons.verified_rounded,
                                                size: 18,
                                                color: Color(0xff3178F6),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if (driverTuktukNumber.isNotEmpty ||
                                            driverTuktukColor.isNotEmpty) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            '${driverTuktukColor.isNotEmpty ? driverTuktukColor : 'تكتك'}${driverTuktukNumber.isNotEmpty ? ' • رقم $driverTuktukNumber' : ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.black54,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    onPressed:
                                        driverPhone.isEmpty
                                            ? null
                                            : () async {
                                                await launchUrl(
                                                  Uri(
                                                    scheme:
                                                        'tel',
                                                    path:
                                                        driverPhone,
                                                  ),
                                                );
                                              },
                                    icon: const Icon(
                                      Icons
                                          .phone_rounded,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      _openChat(
                                        context,
                                      );
                                    },
                                    icon: const Icon(
                                      Icons
                                          .chat_bubble_rounded,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          if (status == 'searching') ...[
                            const SizedBox(height: 16),
                            const LinearProgressIndicator(
                              minHeight: 5,
                              borderRadius:
                                  BorderRadius.all(
                                Radius.circular(20),
                              ),
                            ),
                          ],

                          if (status == 'searching' ||
                              status == 'accepted' ||
                              status == 'arrived') ...[
                            const SizedBox(height: 13),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () =>
                                    _cancelRide(context),
                                icon: const Icon(
                                  Icons.cancel_outlined,
                                  color: Colors.red,
                                ),
                                label: const Text(
                                  'إلغاء الرحلة',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight:
                                        FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],

                          if (status ==
                              'completed') ...[
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton.icon(
                                onPressed: alreadyRated
                                    ? () {
                                        Navigator.pop(
                                          context,
                                        );
                                      }
                                    : () {
                                        _showRatingDialog(
                                          context,
                                        );
                                      },
                                icon: Icon(
                                  alreadyRated
                                      ? Icons
                                          .check_circle_rounded
                                      : Icons
                                          .star_rounded,
                                ),
                                label: Text(
                                  alreadyRated
                                      ? 'تم التقييم'
                                      : 'قيّم الرحلة',
                                  style:
                                      const TextStyle(
                                    fontSize: 18,
                                    fontWeight:
                                        FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ],

                          if (status ==
                              'canceled') ...[
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                },
                                child: const Text(
                                  'رجوع',
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}



class CustomerAccountPage extends StatefulWidget {
  const CustomerAccountPage({super.key});

  @override
  State<CustomerAccountPage> createState() =>
      _CustomerAccountPageState();
}

class _CustomerAccountPageState
    extends State<CustomerAccountPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  String _customerId = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('session_user_id') ?? '';

    if (id.isEmpty) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }

    final snap = await FirebaseFirestore.instance
        .collection('customers')
        .doc(id)
        .get();

    if (snap.exists) {
      final data = snap.data()!;
      _customerId = id;
      _name.text = stringValue(data['name']);
      _phone.text = stringValue(data['phone']);
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_customerId.isEmpty) return;

    final name = _name.text.trim();
    final phone = normalizePhone(_phone.text);

    if (name.isEmpty || phone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تأكد من الاسم ورقم الموبايل'),
        ),
      );
      return;
    }

    setState(() => _saving = true);

    final update = <String, dynamic>{
      'name': name,
      'phone': phone,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (_password.text.isNotEmpty) {
      if (_password.text.length < 4) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'كلمة السر لازم تكون 4 أحرف أو أكثر',
            ),
          ),
        );
        return;
      }

      update['passwordHash'] =
          hashPassword(_password.text);
    }

    await FirebaseFirestore.instance
        .collection('customers')
        .doc(_customerId)
        .update(update);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_customer_name', name);
    await prefs.setString('last_customer_phone', phone);

    if (!mounted) return;

    setState(() => _saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم حفظ التغييرات'),
      ),
    );
  }

  Future<void> _logout() async {
    await clearSession();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const RolePage(),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(

          actions: [
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: () => logoutUser(context),
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
          title: const Text('حسابي'),
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const SizedBox(height: 10),
                  const CircleAvatar(
                    radius: 46,
                    backgroundColor: Color(0xffFFF3C4),
                    child: Icon(
                      Icons.person_rounded,
                      size: 52,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'الاسم',
                      prefixIcon:
                          Icon(Icons.person_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'رقم الموبايل',
                      prefixIcon:
                          Icon(Icons.phone_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText:
                          'كلمة سر جديدة (اختياري)',
                      prefixIcon:
                          Icon(Icons.lock_rounded),
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 54,
                    child: ElevatedButton(
                      onPressed:
                          _saving ? null : _save,
                      child: const Text(
                        'حفظ التغييرات',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(
                        Icons.logout_rounded,
                        color: Colors.red,
                      ),
                      label: const Text(
                        'تسجيل خروج',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ============================================================
// CUSTOMER RIDE HISTORY
// ============================================================

class CustomerRideHistoryPage extends StatefulWidget {
  const CustomerRideHistoryPage({super.key});

  @override
  State<CustomerRideHistoryPage> createState() =>
      _CustomerRideHistoryPageState();
}

class _CustomerRideHistoryPageState
    extends State<CustomerRideHistoryPage> {
  String _phone = '';
  bool _loadingPhone = true;

  @override
  void initState() {
    super.initState();
    _loadPhone();
  }

  Future<void> _loadPhone() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      _phone = prefs.getString('last_customer_phone') ?? '';
      _loadingPhone = false;
    });
  }

  Future<void> _askPhone() async {
    final controller = TextEditingController(
      text: _phone,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: const Text(
              'رقم الهاتف',
              style: TextStyle(
                fontWeight: FontWeight.w900,
              ),
            ),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                hintText: 'أدخل رقمك لرؤية رحلاتك',
                prefixIcon: Icon(Icons.phone_rounded),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                onPressed: () {
                  final phone = controller.text.trim();
                  if (phone.isEmpty) return;
                  Navigator.pop(dialogContext, phone);
                },
                child: const Text('عرض الرحلات'),
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();

    if (result == null || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_customer_phone', result);

    if (!mounted) return;

    setState(() {
      _phone = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('رحلاتي'),
          actions: [
            IconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const CustomerAccountPage(),
                  ),
                );
              },
              icon: const Icon(
                Icons.person_rounded,
              ),
              tooltip: 'حسابي',
            ),
          ],
        ),
        body: _loadingPhone
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : _phone.isEmpty
                ? _NoCustomerPhone(
                    onTap: _askPhone,
                  )
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('ride_requests')
                        .where(
                          'customerPhone',
                          isEqualTo: _phone,
                        )
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'تعذر تحميل الرحلات\n${snapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }

                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }

                      final docs =
                          snapshot.data!.docs.toList();

                      docs.sort((a, b) {
                        final ad = a.data()
                            as Map<String, dynamic>;
                        final bd = b.data()
                            as Map<String, dynamic>;

                        final at = timestampToDate(
                              ad['createdAt'],
                            ) ??
                            DateTime.fromMillisecondsSinceEpoch(
                              0,
                            );

                        final bt = timestampToDate(
                              bd['createdAt'],
                            ) ??
                            DateTime.fromMillisecondsSinceEpoch(
                              0,
                            );

                        return bt.compareTo(at);
                      });

                      final completed = docs.where((doc) {
                        final data = doc.data()
                            as Map<String, dynamic>;
                        return stringValue(
                              data['status'],
                            ) ==
                            'completed';
                      }).length;

                      final totalFare =
                          docs.fold<int>(0, (sum, doc) {
                        final data = doc.data()
                            as Map<String, dynamic>;
                        if (stringValue(
                              data['status'],
                            ) !=
                            'completed') {
                          return sum;
                        }
                        return sum +
                            intValue(data['price']);
                      });

                      if (docs.isEmpty) {
                        return const Center(
                          child: Text(
                            'ما عندك رحلات سابقة',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      }

                      return ListView(
                        padding:
                            const EdgeInsets.all(14),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _HistoryStatCard(
                                  icon:
                                      Icons.check_circle_rounded,
                                  title: 'المكتملة',
                                  value: '$completed',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _HistoryStatCard(
                                  icon:
                                      Icons.payments_rounded,
                                  title: 'إجمالي الكراوي',
                                  value:
                                      '$totalFare د.ع',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          ...docs.map(
                            (doc) => _CustomerRideHistoryCard(
                              rideId: doc.id,
                              data: doc.data()
                                  as Map<String, dynamic>,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}

class _NoCustomerPhone extends StatelessWidget {
  final VoidCallback onTap;

  const _NoCustomerPhone({
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.history_rounded,
              size: 74,
              color: Colors.black26,
            ),
            const SizedBox(height: 16),
            const Text(
              'حتى نعرض رحلاتك',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'أدخل نفس رقم الهاتف المستخدم بطلباتك',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: onTap,
              icon: const Icon(Icons.phone_rounded),
              label: const Text('أدخل رقم الهاتف'),
            ),
          ],
        ),
      ),
    );
  }
}

String _cleanRideAreaCandidate(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';

  final parts = value
      .split(RegExp(r'[,،]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  bool bad(String part) {
    final normalized = part.trim();
    if (normalized.isEmpty) return true;
    if (normalized == 'العراق' ||
        normalized == 'بغداد' ||
        normalized == 'محافظة بغداد') {
      return true;
    }

    if (RegExp(
      r'^[A-Z0-9]{4,}\+[A-Z0-9]{2,}',
      caseSensitive: false,
    ).hasMatch(normalized)) {
      return true;
    }

    // أرقام المحلات/البيوت/الرموز ما نعرضها كاسم منطقة.
    if (RegExp(r'\d{3,}').hasMatch(normalized)) return true;

    final streetWords = <String>[
      'شارع',
      'طريق',
      'زقاق',
      'محلة',
      'رقم',
      'بناية',
    ];

    for (final word in streetWords) {
      if (normalized.contains(word)) return true;
    }

    return false;
  }

  for (final part in parts) {
    if (!bad(part)) return part;
  }

  return '';
}

class _RideRoutePlaces extends StatefulWidget {
  final String rideId;
  final Map<String, dynamic> data;

  const _RideRoutePlaces({
    super.key,
    required this.rideId,
    required this.data,
  });

  @override
  State<_RideRoutePlaces> createState() =>
      _RideRoutePlacesState();
}

class _RideRoutePlacesState extends State<_RideRoutePlaces> {
  String pickup = '';
  String destination = '';
  bool resolving = false;

  @override
  void initState() {
    super.initState();
    _loadSavedNames();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveMissingAreas();
    });
  }

  @override
  void didUpdateWidget(covariant _RideRoutePlaces oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rideId != widget.rideId ||
        oldWidget.data != widget.data) {
      _loadSavedNames();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resolveMissingAreas();
      });
    }
  }

  void _loadSavedNames() {
    pickup = _cleanRideAreaCandidate(
      stringValue(widget.data['pickupArea']),
    );
    destination = _cleanRideAreaCandidate(
      stringValue(widget.data['destinationArea']),
    );

    // للرحلات القديمة اللي ما كان بيها pickupArea/destinationArea.
    pickup = pickup.isNotEmpty
        ? pickup
        : _cleanRideAreaCandidate(
            stringValue(widget.data['pickupAddress']),
          );

    destination = destination.isNotEmpty
        ? destination
        : _cleanRideAreaCandidate(
            stringValue(widget.data['destinationAddress']),
          );
  }

  Future<void> _resolveMissingAreas() async {
    if (resolving || !mounted) return;

    final needPickup = pickup.isEmpty;
    final needDestination = destination.isEmpty;

    if (!needPickup && !needDestination) return;

    final pickupLat = doubleValue(widget.data['pickupLat']);
    final pickupLng = doubleValue(widget.data['pickupLng']);
    final destinationLat =
        doubleValue(widget.data['destinationLat']);
    final destinationLng =
        doubleValue(widget.data['destinationLng']);

    setState(() => resolving = true);

    try {
      final results = await Future.wait<String>([
        needPickup && pickupLat != 0 && pickupLng != 0
            ? GoogleMapsService.reverseGeocodeArea(
                LatLng(pickupLat, pickupLng),
              )
            : Future.value(pickup),
        needDestination &&
                destinationLat != 0 &&
                destinationLng != 0
            ? GoogleMapsService.reverseGeocodeArea(
                LatLng(destinationLat, destinationLng),
              )
            : Future.value(destination),
      ]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => <String>[pickup, destination],
      );

      if (!mounted) return;

      final resolvedPickup =
          _cleanRideAreaCandidate(results[0]);
      final resolvedDestination =
          _cleanRideAreaCandidate(results[1]);

      setState(() {
        if (resolvedPickup.isNotEmpty) {
          pickup = resolvedPickup;
        }
        if (resolvedDestination.isNotEmpty) {
          destination = resolvedDestination;
        }
        resolving = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => resolving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pickupText = pickup.isNotEmpty
        ? pickup
        : resolving
            ? 'جاري تحديد المنطقة...'
            : 'الموقع غير محفوظ';

    final destinationText = destination.isNotEmpty
        ? destination
        : resolving
            ? 'جاري تحديد المنطقة...'
            : 'الموقع غير محفوظ';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: 4,
      ),
      child: Column(
        children: [
          _RideRoutePlaceRow(
            label: 'من',
            text: pickupText,
            type: _RideRoutePointType.pickup,
          ),
          const SizedBox(height: 14),
          _RideRoutePlaceRow(
            label: 'إلى',
            text: destinationText,
            type: _RideRoutePointType.destination,
          ),
        ],
      ),
    );
  }
}

enum _RideRoutePointType {
  pickup,
  destination,
}

class _RideRoutePlaceRow extends StatelessWidget {
  final String label;
  final String text;
  final _RideRoutePointType type;

  const _RideRoutePlaceRow({
    required this.label,
    required this.text,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    final pickup = type == _RideRoutePointType.pickup;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: pickup
                ? const Color(0xffF57C00)
                : const Color(0xff1515E8),
            shape: pickup
                ? BoxShape.circle
                : BoxShape.rectangle,
            borderRadius: pickup
                ? null
                : BorderRadius.circular(5),
          ),
          alignment: Alignment.center,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: pickup
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: pickup
                  ? null
                  : BorderRadius.circular(1.5),
            ),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                    color: Color(0xff22242B),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                TextSpan(text: text),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xff62646F),
              fontSize: 17,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _CustomerRideHistoryCard extends StatelessWidget {
  final String rideId;
  final Map<String, dynamic> data;

  const _CustomerRideHistoryCard({
    required this.rideId,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final status = stringValue(data['status']);
    final fare = intValue(data['price']);
    final distance = doubleValue(data['distanceKm']);
    final driverName = stringValue(data['driverName']);

    return Card(
      margin: const EdgeInsets.only(bottom: 11),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: status == 'searching' ||
                status == 'accepted' ||
                status == 'arrived' ||
                status == 'started'
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        CustomerRideTrackingPage(
                      rideId: rideId,
                    ),
                  ),
                );
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: rideStatusColor(status)
                          .withValues(alpha: 0.10),
                      borderRadius:
                          BorderRadius.circular(12),
                    ),
                    child: Text(
                      rideStatusArabic(status),
                      style: TextStyle(
                        color: rideStatusColor(status),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    formatRideDate(data['createdAt']),
                    style: const TextStyle(
                      color: Colors.black45,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              _RideRoutePlaces(
                key: ValueKey('customer_route_$rideId'),
                rideId: rideId,
                data: data,
              ),
              const SizedBox(height: 13),
              const Divider(height: 1),
              const SizedBox(height: 13),
              Row(
                children: [
                  const Icon(
                    Icons.route_rounded,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${distance.toStringAsFixed(1)} كم',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$fare د.ع',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              if (driverName.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.electric_rickshaw_rounded,
                      size: 19,
                      color: Colors.black54,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'السائق: $driverName',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryStatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _HistoryStatCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: const Color(0xffECECEC),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: const Color(0xffE4A900),
          ),
          const SizedBox(height: 9),
          Text(
            title,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// DRIVER RIDE HISTORY / DAILY ACCOUNT
// ============================================================

class DriverRideHistoryPage extends StatelessWidget {
  final DriverProfile driver;

  const DriverRideHistoryPage({
    super.key,
    required this.driver,
  });

  bool _isToday(dynamic timestamp) {
    final date = timestampToDate(timestamp);
    if (date == null) return false;

    final now = DateTime.now();

    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'حسابي ورحلاتي',
          ),
        ),
        body: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('drivers')
              .doc(driver.id)
              .snapshots(),
          builder: (context, driverSnapshot) {
            final balance = driverSnapshot.hasData
                ? intValue(
                    (driverSnapshot.data!.data()
                                as Map<String, dynamic>? ??
                            {})['balance'],
                  )
                : 0;

            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('ride_requests')
                  .where(
                    'driverId',
                    isEqualTo: driver.id,
                  )
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'تعذر تحميل الرحلات\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final docs = snapshot.data!.docs.toList();

                docs.sort((a, b) {
                  final ad =
                      a.data() as Map<String, dynamic>;
                  final bd =
                      b.data() as Map<String, dynamic>;

                  final at = timestampToDate(
                        ad['createdAt'],
                      ) ??
                      DateTime.fromMillisecondsSinceEpoch(
                        0,
                      );

                  final bt = timestampToDate(
                        bd['createdAt'],
                      ) ??
                      DateTime.fromMillisecondsSinceEpoch(
                        0,
                      );

                  return bt.compareTo(at);
                });

                final completedDocs = docs.where((doc) {
                  final data =
                      doc.data() as Map<String, dynamic>;
                  return stringValue(data['status']) ==
                      'completed';
                }).toList();

                final todayDocs =
                    completedDocs.where((doc) {
                  final data =
                      doc.data() as Map<String, dynamic>;
                  return _isToday(
                    data['completedAt'] ??
                        data['createdAt'],
                  );
                }).toList();

                final todayFare =
                    todayDocs.fold<int>(0, (sum, doc) {
                  final data =
                      doc.data() as Map<String, dynamic>;
                  return sum + intValue(data['price']);
                });

                final totalFare = completedDocs.fold<int>(
                  0,
                  (sum, doc) {
                    final data =
                        doc.data() as Map<String, dynamic>;
                    return sum + intValue(data['price']);
                  },
                );

                return ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _HistoryStatCard(
                            icon: Icons.today_rounded,
                            title: 'رحلات اليوم',
                            value: '${todayDocs.length}',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _HistoryStatCard(
                            icon: Icons.payments_rounded,
                            title: 'كراوي اليوم',
                            value: '$todayFare د.ع',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _HistoryStatCard(
                            icon:
                                Icons.account_balance_wallet_rounded,
                            title: 'رصيدي',
                            value: '$balance د.ع',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _HistoryStatCard(
                            icon:
                                Icons.directions_car_filled_rounded,
                            title: 'كل الرحلات',
                            value:
                                '${completedDocs.length}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Text(
                          'سجل الرحلات',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'المجموع $totalFare د.ع',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (docs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 80),
                        child: Center(
                          child: Text(
                            'ما عندك رحلات بعد',
                          ),
                        ),
                      )
                    else
                      ...docs.map(
                        (doc) => _DriverRideHistoryCard(
                          rideId: doc.id,
                          data: doc.data()
                              as Map<String, dynamic>,
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DriverRideHistoryCard extends StatelessWidget {
  final String rideId;
  final Map<String, dynamic> data;

  const _DriverRideHistoryCard({
    required this.rideId,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final status = stringValue(data['status']);
    final fare = intValue(data['price']);
    final distance = doubleValue(data['distanceKm']);
    final rating = intValue(data['customerRating']);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: rideStatusColor(status)
                        .withValues(alpha: 0.10),
                    borderRadius:
                        BorderRadius.circular(12),
                  ),
                  child: Text(
                    rideStatusArabic(status),
                    style: TextStyle(
                      color: rideStatusColor(status),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  formatRideDate(
                    data['completedAt'] ??
                        data['createdAt'],
                  ),
                  style: const TextStyle(
                    color: Colors.black45,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _RideRoutePlaces(
              key: ValueKey('driver_route_$rideId'),
              rideId: rideId,
              data: data,
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.route_rounded,
                  size: 19,
                ),
                const SizedBox(width: 7),
                Text(
                  '${distance.toStringAsFixed(1)} كم',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '$fare د.ع',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            if (rating > 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.star_rounded,
                    color: Color(0xffFFC107),
                    size: 20,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$rating / 5',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// DRIVER LOGIN
// ============================================================



// ============================================================
// FORGOT PASSWORD - SUPPORT VERIFIED RESET
// ============================================================

class ForgotPasswordPage extends StatefulWidget {
  final String role;

  const ForgotPasswordPage({
    super.key,
    required this.role,
  });

  @override
  State<ForgotPasswordPage> createState() =>
      _ForgotPasswordPageState();
}

class _ForgotPasswordPageState
    extends State<ForgotPasswordPage> {
  final _phone = TextEditingController();
  bool _loading = false;
  bool _sent = false;

  String get _roleArabic =>
      widget.role == 'driver' ? 'السائق' : 'الزبون';

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _sendRequest() async {
    final phone = normalizePhone(_phone.text);

    if (phone.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('اكتب رقم الموبايل بشكل صحيح'),
        ),
      );
      return;
    }

    if (_loading) return;
    setState(() => _loading = true);

    try {
      final collection =
          widget.role == 'driver'
              ? 'drivers'
              : 'customers';

      final result = await FirebaseFirestore.instance
          .collection(collection)
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      // لا نكشف للمستخدم هل الرقم موجود أم لا.
      if (result.docs.isNotEmpty) {
        final doc = result.docs.first;
        final data = doc.data();

        final oldRequests =
            await FirebaseFirestore.instance
                .collection(
                  'password_reset_requests',
                )
                .where(
                  'userId',
                  isEqualTo: doc.id,
                )
                .get();

        final hasOpen = oldRequests.docs.any(
          (request) {
            final requestData = request.data();
            return stringValue(
                  requestData['status'],
                ) ==
                'pending';
          },
        );

        if (!hasOpen) {
          await FirebaseFirestore.instance
              .collection(
                'password_reset_requests',
              )
              .add({
            'role': widget.role,
            'userId': doc.id,
            'userName':
                stringValue(data['name']),
            'phone': phone,
            'status': 'pending',
            'createdAt':
                FieldValue.serverTimestamp(),
            'updatedAt':
                FieldValue.serverTimestamp(),
          });

          await FirebaseFirestore.instance
              .collection('support_tickets')
              .add({
            'role': widget.role,
            'userId': doc.id,
            'userName':
                stringValue(data['name']),
            'userPhone': phone,
            'subject': 'نسيت كلمة السر',
            'message':
                'طلب استرجاع كلمة سر لحساب $_roleArabic. يحتاج تحقق من صاحب الحساب.',
            'status': 'open',
            'managerReply': '',
            'createdAt':
                FieldValue.serverTimestamp(),
            'updatedAt':
                FieldValue.serverTimestamp(),
          });
        }
      }

      if (!mounted) return;
      setState(() => _sent = true);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text(
            'تعذر إرسال الطلب: $e',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('نسيت كلمة السر'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const SizedBox(height: 30),
              const Icon(
                Icons.lock_reset_rounded,
                size: 82,
                color: Color(0xffE4A900),
              ),
              const SizedBox(height: 20),
              Text(
                _sent
                    ? 'تم استلام طلبك'
                    : 'استرجاع حساب $_roleArabic',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              if (!_sent) ...[
                const Text(
                  'اكتب رقم الموبايل المسجل بالحساب. حفاظاً على أمان الحساب، تغيير كلمة السر يتم بعد التحقق من صاحب الحساب.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black54,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _phone,
                  keyboardType:
                      TextInputType.phone,
                  decoration:
                      const InputDecoration(
                    labelText:
                        'رقم الموبايل',
                    hintText:
                        '07xxxxxxxxx',
                    prefixIcon: Icon(
                      Icons.phone_rounded,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed:
                        _loading
                            ? null
                            : _sendRequest,
                    icon: const Icon(
                      Icons.send_rounded,
                    ),
                    label: _loading
                        ? const CircularProgressIndicator()
                        : const Text(
                            'إرسال طلب الاسترجاع',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight:
                                  FontWeight.w900,
                            ),
                          ),
                  ),
                ),
              ] else ...[
                Container(
                  padding:
                      const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color:
                        const Color(0xffEAF8F0),
                    borderRadius:
                        BorderRadius.circular(20),
                  ),
                  child: const Column(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        color: Colors.green,
                        size: 52,
                      ),
                      SizedBox(height: 10),
                      Text(
                        'إذا كان الرقم مرتبطاً بحساب، تم إرسال طلب الاسترجاع للدعم الفني. بعد التحقق من صاحب الحساب يتم تحديث كلمة السر.',
                        textAlign:
                            TextAlign.center,
                        style: TextStyle(
                          fontWeight:
                              FontWeight.w700,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton(
                  onPressed: () =>
                      Navigator.pop(context),
                  child:
                      const Text('رجوع للدخول'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


class CustomerAuthPage extends StatefulWidget {
  const CustomerAuthPage({super.key});

  @override
  State<CustomerAuthPage> createState() =>
      _CustomerAuthPageState();
}

class _CustomerAuthPageState
    extends State<CustomerAuthPage> {
  bool _register = false;
  bool _loading = false;

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = normalizePhone(_phone.text);
    final password = _password.text;

    if (phone.length < 10 || password.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تأكد من رقم الموبايل وكلمة السر',
          ),
        ),
      );
      return;
    }

    if (_register && _name.text.trim().length < 2) {
      return;
    }

    setState(() => _loading = true);

    try {
      final old = await FirebaseFirestore.instance
          .collection('customers')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (_register) {
        if (old.docs.isNotEmpty) {
          throw Exception('هذا الرقم مسجل من قبل');
        }

        final ref = await FirebaseFirestore.instance
            .collection('customers')
            .add({
          'name': _name.text.trim(),
          'phone': phone,
          'passwordHash': hashPassword(password),
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await saveSession(
          role: 'customer',
          userId: ref.id,
        );

        if (!mounted) return;

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => CustomerPage(
              customerId: ref.id,
            ),
          ),
          (_) => false,
        );
      } else {
        if (old.docs.isEmpty) {
          throw Exception('الحساب غير موجود');
        }

        final doc = old.docs.first;
        final data = doc.data();

        if (data['active'] == false) {
          throw Exception('الحساب متوقف');
        }

        if (stringValue(data['passwordHash']) !=
            hashPassword(password)) {
          throw Exception('كلمة السر غير صحيحة');
        }

        await saveSession(
          role: 'customer',
          userId: doc.id,
        );

        if (!mounted) return;

        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => CustomerPage(
              customerId: doc.id,
            ),
          ),
          (_) => false,
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _register
              ? 'تسجيل زبون جديد'
              : 'دخول الزبون',
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const SizedBox(height: 24),
            const Icon(
              Icons.person_rounded,
              size: 74,
              color: Color(0xffE4A900),
            ),
            const SizedBox(height: 24),
            if (_register) ...[
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'الاسم',
                  prefixIcon:
                      Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم الموبايل',
                hintText: '07xxxxxxxxx',
                prefixIcon:
                    Icon(Icons.phone_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'كلمة السر',
                prefixIcon:
                    Icon(Icons.lock_rounded),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const CircularProgressIndicator()
                    : Text(
                        _register
                            ? 'إنشاء الحساب'
                            : 'دخول',
                        style: const TextStyle(
                          fontSize: 18,
                        ),
                      ),
              ),
            ),
            if (!_register) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: _loading
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                const ForgotPasswordPage(
                              role: 'customer',
                            ),
                          ),
                        );
                      },
                icon: const Icon(
                  Icons.lock_reset_rounded,
                ),
                label: const Text(
                  'نسيت كلمة السر؟',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.w800,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      setState(() {
                        _register = !_register;
                      });
                    },
              child: Text(
                _register
                    ? 'عندي حساب'
                    : 'أول مرة؟ إنشاء حساب',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DriverAuthPage extends StatefulWidget {
  const DriverAuthPage({super.key});

  @override
  State<DriverAuthPage> createState() =>
      _DriverAuthPageState();
}

class _DriverAuthPageState
    extends State<DriverAuthPage> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = normalizePhone(_phone.text);
    final password = _password.text;

    if (phone.length < 10 || password.length < 4) {
      return;
    }

    setState(() => _loading = true);

    try {
      final result = await FirebaseFirestore.instance
          .collection('drivers')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (result.docs.isEmpty) {
        throw Exception('حساب السائق غير موجود');
      }

      final doc = result.docs.first;
      final data = doc.data();

      if (stringValue(data['passwordHash']) !=
          hashPassword(password)) {
        throw Exception('كلمة السر غير صحيحة');
      }

      final approval =
          stringValue(data['approvalStatus']).isEmpty
              ? 'approved'
              : stringValue(data['approvalStatus']);

      if (approval == 'pending') {
        throw Exception(
          'طلب التسجيل قيد مراجعة المدير',
        );
      }

      if (approval == 'rejected') {
        throw Exception(
          'طلب التسجيل مرفوض',
        );
      }

      if (data['active'] == false) {
        throw Exception('الحساب متوقف');
      }

      final driver = DriverProfile(
        id: doc.id,
        name: stringValue(data['name']),
        phone: stringValue(data['phone']),
        active: true,
        approvalStatus: approval,
        tuktukNumber:
            stringValue(data['tuktukNumber']),
        tuktukColor:
            stringValue(data['tuktukColor']),
        profilePhotoUrl:
            stringValue(data['profilePhotoUrl']),
        verified: data['verified'] == true,
      );

      await saveSession(
        role: 'driver',
        userId: doc.id,
      );

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => DriverHomePage(
            driver: driver,
          ),
        ),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل دخول السائق'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const SizedBox(height: 20),
            const Icon(
              Icons.electric_rickshaw_rounded,
              size: 78,
              color: Color(0xffE4A900),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم الموبايل',
                prefixIcon:
                    Icon(Icons.phone_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(
                labelText: 'كلمة السر',
                prefixIcon:
                    Icon(Icons.lock_rounded),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _loading ? null : _login,
                child: _loading
                    ? const CircularProgressIndicator()
                    : const Text(
                        'دخول',
                        style: TextStyle(fontSize: 18),
                      ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _loading
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const ForgotPasswordPage(
                            role: 'driver',
                          ),
                        ),
                      );
                    },
              icon: const Icon(
                Icons.lock_reset_rounded,
              ),
              label: const Text(
                'نسيت كلمة السر؟',
                style: TextStyle(
                  fontWeight:
                      FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const DriverRegisterPage(),
                  ),
                );
              },
              child: const Text(
                'إنشاء حساب جديد',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DriverRegisterPage extends StatefulWidget {
  const DriverRegisterPage({super.key});

  @override
  State<DriverRegisterPage> createState() =>
      _DriverRegisterPageState();
}

class _DriverRegisterPageState
    extends State<DriverRegisterPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _tuktukNumber = TextEditingController();
  final _tuktukColor = TextEditingController();
  final _inviteCode = TextEditingController();

  final _picker = ImagePicker();
  XFile? _profilePhoto;
  XFile? _idFront;
  XFile? _idBack;
  bool _loading = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    _tuktukNumber.dispose();
    _tuktukColor.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _pickProfile() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 75,
      maxWidth: 1400,
    );

    if (file == null || !mounted) return;
    setState(() => _profilePhoto = file);
  }

  Future<void> _pickIdFront() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1800,
    );

    if (file == null || !mounted) return;
    setState(() => _idFront = file);
  }

  Future<void> _pickIdBack() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1800,
    );

    if (file == null || !mounted) return;
    setState(() => _idBack = file);
  }

  Future<String> _uploadDriverProfile({
    required String driverId,
    required XFile file,
  }) async {
    if (!supabaseConfigured) {
      throw Exception('أضف Supabase URL و Publishable Key داخل main.dart');
    }

    final bytes = await file.readAsBytes();
    final path = '$driverId/profile.jpg';

    await Supabase.instance.client.storage
        .from('driver-profiles')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );

    return Supabase.instance.client.storage
        .from('driver-profiles')
        .getPublicUrl(path);
  }

  Future<String> _uploadDriverDocument({
    required String driverId,
    required XFile file,
    required String fileName,
  }) async {
    if (!supabaseConfigured) {
      throw Exception('أضف Supabase URL و Publishable Key داخل main.dart');
    }

    final bytes = await file.readAsBytes();
    final path = '$driverId/$fileName';

    await Supabase.instance.client.storage
        .from('driver-documents')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );

    // نخزن المسار فقط لأن bucket مستمسكات السائق لازم يبقى Private.
    return path;
  }

  Future<void> _register() async {
    final phone = normalizePhone(_phone.text);
    final name = _name.text.trim();
    final password = _password.text;
    final tuktukNumber = _tuktukNumber.text.trim();
    final tuktukColor = _tuktukColor.text.trim();
    final referralCode =
        _inviteCode.text
            .trim()
            .toUpperCase();

    if (name.length < 2 ||
        phone.length < 10 ||
        password.length < 4 ||
        tuktukNumber.isEmpty ||
        tuktukColor.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'كمّل الاسم ورقم الموبايل وكلمة السر ورقم التكتك ولونه',
          ),
        ),
      );
      return;
    }

    if (_profilePhoto == null ||
        _idFront == null ||
        _idBack == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'اختار الصورة الشخصية وصورة الجنسية وجه وصورة الجنسية ظهر',
          ),
        ),
      );
      return;
    }

    if (!supabaseConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'أضف Supabase URL و Publishable Key داخل main.dart أولاً',
          ),
        ),
      );
      return;
    }

    setState(() => _loading = true);

    try {
      String inviterDriverId = '';

      if (referralCode.isNotEmpty) {
        inviterDriverId =
            await DriverReferralService
                .findInviterIdByCode(
          referralCode,
        );

        if (inviterDriverId.isEmpty) {
          throw Exception('كود الدعوة غير صحيح');
        }
      }

      final old = await FirebaseFirestore.instance
          .collection('drivers')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (old.docs.isNotEmpty) {
        throw Exception('هذا الرقم مسجل من قبل');
      }

      final ref = FirebaseFirestore.instance
          .collection('drivers')
          .doc();

      final profileUrl = await _uploadDriverProfile(
        driverId: ref.id,
        file: _profilePhoto!,
      );

      final idFrontPath = await _uploadDriverDocument(
        driverId: ref.id,
        file: _idFront!,
        fileName: 'id_front.jpg',
      );

      final idBackPath = await _uploadDriverDocument(
        driverId: ref.id,
        file: _idBack!,
        fileName: 'id_back.jpg',
      );

      await ref.set({
        'name': name,
        'phone': phone,
        'passwordHash':
            hashPassword(password),
        'tuktukNumber': tuktukNumber,
        'tuktukColor': tuktukColor,
        'inviteCode':
            DriverReferralService
                .buildInviteCode(
          ref.id,
        ),
        if (inviterDriverId.isNotEmpty)
          'referredByDriverId':
              inviterDriverId,
        if (referralCode.isNotEmpty)
          'referralCodeUsed':
              referralCode,
        'profilePhotoUrl': profileUrl,
        'profilePhotoPath': '${ref.id}/profile.jpg',
        'idFrontPath': idFrontPath,
        'idBackPath': idBackPath,
        'idDocumentStorage': 'supabase',
        'approvalStatus': 'pending',
        'verified': false,
        'active': false,
        'online': false,
        'balance': 0,
        'createdAt':
            FieldValue.serverTimestamp(),
      });

      if (inviterDriverId.isNotEmpty) {
        await DriverReferralService
            .createPendingReferral(
          inviterDriverId:
              inviterDriverId,
          referredDriverId: ref.id,
          code: referralCode,
        );
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text(
                'تم إرسال طلبك',
              ),
              content: const Text(
                'المدير يراجع بياناتك ومستمسكاتك. بعد الموافقة يصير حسابك فعال.',
              ),
              actions: [
                ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext),
                  child: const Text('تمام'),
                ),
              ],
            ),
          );
        },
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Widget _imageButton({
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xffF7F8FA),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: selected
                    ? const Color(0xff23B26D)
                    : const Color(0xffFFC107),
                child: Icon(
                  selected
                      ? Icons.check_rounded
                      : Icons.add_a_photo_rounded,
                  color: selected
                      ? Colors.white
                      : Colors.black,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  selected ? '$title ✓' : title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_left_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيل سائق'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'معلومات السائق',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'الاسم الكامل',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم الموبايل',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'كلمة السر',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tuktukNumber,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'رقم التكتك',
                hintText: 'مثال: 12345 أو رقم اللوحة',
                prefixIcon: Icon(
                  Icons.confirmation_number_outlined,
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tuktukColor,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'لون التكتك',
                hintText: 'مثال: أصفر، أحمر، أزرق',
                prefixIcon: Icon(
                  Icons.palette_outlined,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inviteCode,
              textCapitalization:
                  TextCapitalization.characters,
              decoration:
                  const InputDecoration(
                labelText:
                    'كود دعوة صديق (اختياري)',
                hintText:
                    'مثال: DRV12AB34',
                prefixIcon: Icon(
                  Icons.card_giftcard_rounded,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'الصور',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'الهوية/الجنسية تبقى للإدارة فقط. الزبون يشوف الصورة الشخصية بعد قبول الرحلة.',
              style: TextStyle(
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 12),
            _imageButton(
              title: 'الصورة الشخصية للسائق',
              selected: _profilePhoto != null,
              onTap: _pickProfile,
            ),
            const SizedBox(height: 10),
            _imageButton(
              title: 'صورة الجنسية - الوجه',
              selected: _idFront != null,
              onTap: _pickIdFront,
            ),
            const SizedBox(height: 10),
            _imageButton(
              title: 'صورة الجنسية - الظهر',
              selected: _idBack != null,
              onTap: _pickIdBack,
            ),
            const SizedBox(height: 22),
            SizedBox(
              height: 58,
              child: ElevatedButton.icon(
                onPressed:
                    _loading ? null : _register,
                icon: const Icon(
                  Icons.send_rounded,
                ),
                label: _loading
                    ? const CircularProgressIndicator()
                    : const Text(
                        'إرسال طلب التسجيل',
                        style: TextStyle(
                          fontSize: 18,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// DRIVER HOME - CENTER CARDS + AUTO ONLINE
// ============================================================


// ============================================================
// DRIVER SETTINGS
// ============================================================


class DriverAccountHubPage
    extends StatelessWidget {
  final DriverProfile driver;

  const DriverAccountHubPage({
    super.key,
    required this.driver,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor:
            const Color(0xffF7F7F7),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          title: const Text(
            'حسابي',
            style: TextStyle(
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        body: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('drivers')
              .doc(driver.id)
              .snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data()
                        as Map<String, dynamic>? ??
                    {};

            final name = stringValue(
              data['name'],
            ).isEmpty
                ? driver.name
                : stringValue(data['name']);

            final phone = stringValue(
              data['phone'],
            ).isEmpty
                ? driver.phone
                : stringValue(data['phone']);

            final photo = stringValue(
              data['profilePhotoUrl'],
            ).isEmpty
                ? driver.profilePhotoUrl
                : stringValue(
                    data['profilePhotoUrl'],
                  );

            final balance =
                intValue(data['balance']);
            final tuktukNumber = stringValue(
              data['tuktukNumber'],
            ).isEmpty
                ? driver.tuktukNumber
                : stringValue(data['tuktukNumber']);
            final tuktukColor = stringValue(
              data['tuktukColor'],
            ).isEmpty
                ? driver.tuktukColor
                : stringValue(data['tuktukColor']);


            return ListView(
              padding:
                  const EdgeInsets.all(16),
              children: [
                Container(
                  padding:
                      const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.circular(
                      20,
                    ),
                  ),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 54,
                        backgroundColor:
                            const Color(
                          0xffEFEFEF,
                        ),
                        backgroundImage:
                            photo.startsWith(
                                  'http',
                                )
                                ? NetworkImage(
                                    photo,
                                  )
                                : null,
                        child: photo.startsWith(
                              'http',
                            )
                            ? null
                            : const Icon(
                                Icons
                                    .person_rounded,
                                size: 58,
                                color:
                                    Colors.black38,
                              ),
                      ),
                      const SizedBox(
                        height: 12,
                      ),
                      Text(
                        name,
                        style:
                            const TextStyle(
                          fontSize: 22,
                          fontWeight:
                              FontWeight.w900,
                        ),
                      ),
                      const SizedBox(
                        height: 4,
                      ),
                      Text(
                        phone,
                        style:
                            const TextStyle(
                          color:
                              Colors.black54,
                        ),
                      ),
                      if (tuktukNumber.isNotEmpty ||
                          tuktukColor.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xffF7F8FA),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.electric_rickshaw_rounded,
                                size: 19,
                                color: Color(0xffA97400),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                '${tuktukColor.isNotEmpty ? tuktukColor : 'تكتك'}${tuktukNumber.isNotEmpty ? ' • رقم $tuktukNumber' : ''}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(
                        height: 14,
                      ),
                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets
                                .all(14),
                        decoration:
                            BoxDecoration(
                          color:
                              const Color(
                            0xffFFF7D8,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            16,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons
                                  .account_balance_wallet_rounded,
                              color:
                                  Color(
                                0xffA97400,
                              ),
                            ),
                            const SizedBox(
                              width: 10,
                            ),
                            const Text(
                              'الرصيد',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .w800,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '$balance د.ع',
                              style:
                                  const TextStyle(
                                fontSize: 18,
                                fontWeight:
                                    FontWeight
                                        .w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                  height: 14,
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.photo_camera_rounded,
                  title:
                      'الصورة وكلمة السر',
                  subtitle:
                      'تغيير الصورة الشخصية وكلمة المرور',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DriverSettingsPage(
                          driver: driver,
                        ),
                      ),
                    );
                  },
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.card_giftcard_rounded,
                  title: 'المكافآت',
                  subtitle:
                      'استلام مكافآتك وتحويلها إلى الرصيد',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            RewardsPage(
                          role: 'driver',
                          userId: driver.id,
                        ),
                      ),
                    );
                  },
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.group_add_rounded,
                  title:
                      'دعوة الأصدقاء',
                  subtitle:
                      'شارك عبر واتساب واربح $driverReferralRewardIqd د.ع بعد إكمال صديقك $driverReferralRequiredRides رحلات',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DriverInviteFriendsPage(
                          driverId:
                              driver.id,
                          driverName:
                              name,
                        ),
                      ),
                    );
                  },
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.receipt_long_rounded,
                  title: 'سجل الرحلات',
                  subtitle:
                      'الرحلات السابقة والأرباح',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DriverRideHistoryPage(
                          driver: driver,
                        ),
                      ),
                    );
                  },
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.account_balance_wallet_rounded,
                  title: 'تعبئة الرصيد',
                  subtitle:
                      'راسل الدعم حتى نساعدك بتعبئة رصيدك',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            TechnicalSupportPage(
                          role: 'driver',
                          userId: driver.id,
                          userName: driver.name,
                          userPhone: driver.phone,
                          initialSubject:
                              'طلب تعبئة رصيد',
                          initialMessage:
                              'مرحباً فريق الدعم، أريد تعبئة رصيد حساب السائق. أتمنى تتواصلون وياي لإكمال التعبئة. شكراً 💛',
                        ),
                      ),
                    );
                  },
                ),
                _accountTile(
                  context,
                  icon:
                      Icons.support_agent_rounded,
                  title: 'الدعم الفني',
                  subtitle:
                      'تواصل مع الإدارة',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            TechnicalSupportPage(
                          role: 'driver',
                          userId: driver.id,
                          userName: driver.name,
                          userPhone: driver.phone,
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _accountTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius:
            BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding:
            const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 6,
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color:
                const Color(0xffFFF5CC),
            borderRadius:
                BorderRadius.circular(14),
          ),
          child: Icon(
            icon,
            color:
                const Color(0xff8A6400),
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight:
                FontWeight.w900,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
          ),
        ),
        trailing: const Icon(
          Icons
              .arrow_back_ios_new_rounded,
          size: 16,
        ),
      ),
    );
  }
}

class DriverSettingsPage extends StatefulWidget {
  final DriverProfile driver;

  const DriverSettingsPage({
    super.key,
    required this.driver,
  });

  @override
  State<DriverSettingsPage> createState() =>
      _DriverSettingsPageState();
}

class _DriverSettingsPageState extends State<DriverSettingsPage> {
  final _password = TextEditingController();
  final _tuktukNumber = TextEditingController();
  final _tuktukColor = TextEditingController();
  final _picker = ImagePicker();

  String _photoUrl = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _photoUrl =
        widget.driver.profilePhotoUrl;
    _tuktukNumber.text = widget.driver.tuktukNumber;
    _tuktukColor.text = widget.driver.tuktukColor;
  }

  @override
  void dispose() {
    _password.dispose();
    _tuktukNumber.dispose();
    _tuktukColor.dispose();
    super.dispose();
  }

  Future<void> _changePhoto() async {
    if (!supabaseConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Supabase Storage غير مهيأ'),
        ),
      );
      return;
    }

    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1200,
    );

    if (file == null) return;

    setState(() => _saving = true);

    try {
      final bytes = await file.readAsBytes();
      final path =
          '${widget.driver.id}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';

      await Supabase.instance.client.storage
          .from('driver-profiles')
          .uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(
          contentType: 'image/jpeg',
          upsert: true,
        ),
      );

      // Bucket driver-profiles ممكن يكون Private، لذلك نستعمل رابط موقّع
      // بدل getPublicUrl حتى الصورة تظهر فعلاً داخل التطبيق.
      final url = await Supabase.instance.client.storage
          .from('driver-profiles')
          .createSignedUrl(
        path,
        60 * 60 * 24 * 365,
      );

      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .update({
        'profilePhotoUrl': url,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // نحدث أيضاً أي رحلة جارية حتى الزبون يشوف الصورة فوراً.
      final rides = await FirebaseFirestore.instance
          .collection('ride_requests')
          .where('driverId', isEqualTo: widget.driver.id)
          .get();

      for (final ride in rides.docs) {
        final status = stringValue(ride.data()['status']);
        if (status == 'accepted' ||
            status == 'arrived' ||
            status == 'started') {
          await ride.reference.update({
            'driverProfilePhotoUrl': url,
          });
        }
      }

      if (!mounted) return;

      setState(() {
        _photoUrl = url;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم حفظ صورتك وظهرت بحسابك 💛'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تعذر تغيير الصورة: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;

    if (_password.text.isNotEmpty &&
        _password.text.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('كلمة السر لازم تكون 4 أحرف أو أكثر'),
        ),
      );
      return;
    }

    setState(() => _saving = true);

    final tuktukNumber = _tuktukNumber.text.trim();
    final tuktukColor = _tuktukColor.text.trim();

    if (tuktukNumber.isEmpty || tuktukColor.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('اكتب رقم التكتك ولونه'),
        ),
      );
      setState(() => _saving = false);
      return;
    }

    final update =
        <String, dynamic>{
      'tuktukNumber': tuktukNumber,
      'tuktukColor': tuktukColor,
      'updatedAt':
          FieldValue.serverTimestamp(),
    };

    if (_password.text.isNotEmpty) {
      update['passwordHash'] =
          hashPassword(_password.text);
    }

    try {
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .update(update);

      final activeRides = await FirebaseFirestore.instance
          .collection('ride_requests')
          .where('driverId', isEqualTo: widget.driver.id)
          .get();

      for (final ride in activeRides.docs) {
        final status = stringValue(ride.data()['status']);
        if (status == 'accepted' ||
            status == 'arrived' ||
            status == 'started') {
          await ride.reference.set({
            'driverTuktukNumber': tuktukNumber,
            'driverTuktukColor': tuktukColor,
          }, SetOptions(merge: true));
        }
      }

      if (!mounted) return;

      _password.clear();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم حفظ بيانات السائق'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إعدادات السائق'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 58,
                    backgroundColor: const Color(0xffFFF3C4),
                    backgroundImage:
                        _photoUrl.isNotEmpty
                            ? NetworkImage(_photoUrl)
                            : null,
                    child: _photoUrl.isEmpty
                        ? const Icon(
                            Icons.person_rounded,
                            size: 64,
                            color: Colors.black,
                          )
                        : null,
                  ),
                  PositionedDirectional(
                    end: 0,
                    bottom: 0,
                    child: IconButton.filled(
                      onPressed:
                          _saving ? null : _changePhoto,
                      icon: const Icon(
                        Icons.camera_alt_rounded,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _tuktukNumber,
              decoration: const InputDecoration(
                labelText: 'رقم التكتك',
                prefixIcon: Icon(
                  Icons.confirmation_number_outlined,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tuktukColor,
              decoration: const InputDecoration(
                labelText: 'لون التكتك',
                prefixIcon: Icon(
                  Icons.palette_outlined,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'كلمة سر جديدة (اختياري)',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 54,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: const Text(
                  'حفظ التغييرات',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Divider(),
            logoutListTile(context),
          ],
        ),
      ),
    );
  }
}

class DriverHomePage extends StatefulWidget {
  final DriverProfile driver;

  const DriverHomePage({
    super.key,
    required this.driver,
  });

  @override
  State<DriverHomePage> createState() =>
      _DriverHomePageState();
}

class _DriverHomePageState
    extends State<DriverHomePage> with WidgetsBindingObserver {
  Timer? _heartbeatTimer;
  Timer? _offerTimer;
  Timer? _offerRefreshTimer;
  String? _currentOfferId;
  int _offerSeconds = 50;
  bool _accepting = false;
  bool _manualOnline = true;
  bool _manualOnlineLoaded = false;

  final Set<String>
      _skippedOfferIds =
      <String>{};

  final Set<String>
      _resolvingOfferAreas =
      <String>{};

  final Set<String>
      _alertedNearbyRides =
      <String>{};

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addObserver(this);

    unawaited(_loadManualOnlineState());

    _offerRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (mounted && _manualOnline) {
          setState(() {});
        }
      },
    );

    unawaited(
      DriverReferralService
          .ensureInviteCode(
        widget.driver.id,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _heartbeatTimer?.cancel();
    _offerTimer?.cancel();
    _offerRefreshTimer?.cancel();

    _goOffline();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_manualOnline) {
        unawaited(_goOnline());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      unawaited(_goOffline());
    }
  }

  Future<void> _loadManualOnlineState() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .get();

      final data = snap.data() ?? {};
      final enabled = data['acceptingRides'] != false;

      if (mounted) {
        setState(() {
          _manualOnline = enabled;
          _manualOnlineLoaded = true;
        });
      } else {
        _manualOnline = enabled;
        _manualOnlineLoaded = true;
      }

      if (enabled) {
        await _goOnline();
      } else {
        await _goOffline();
      }
    } catch (_) {
      _manualOnline = true;
      _manualOnlineLoaded = true;
      await _goOnline();
    }
  }

  Future<void> _setManualOnline(bool value) async {
    if (mounted) {
      setState(() {
        _manualOnline = value;
      });
    } else {
      _manualOnline = value;
    }

    try {
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .set({
        'acceptingRides': value,
        'availabilityUpdatedAt':
            FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    if (value) {
      await _goOnline();
    } else {
      await _goOffline();
      _offerTimer?.cancel();
      if (mounted) {
        setState(() {
          _currentOfferId = null;
          _offerSeconds = 50;
        });
      }
    }
  }

  void _openDriverSupport({
    String subject = '',
    String message = '',
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TechnicalSupportPage(
          role: 'driver',
          userId: widget.driver.id,
          userName: widget.driver.name,
          userPhone: widget.driver.phone,
          initialSubject: subject,
          initialMessage: message,
        ),
      ),
    );
  }

  Future<void> _logoutDriver() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            icon: const Icon(
              Icons.logout_rounded,
              color: Colors.red,
              size: 42,
            ),
            title: const Text(
              'تسجيل الخروج',
              textAlign: TextAlign.center,
            ),
            content: const Text(
              'متأكد تريد تسجل خروج من حساب السائق؟',
              textAlign: TextAlign.center,
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, false),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: () =>
                    Navigator.pop(dialogContext, true),
                child: const Text('تسجيل الخروج'),
              ),
            ],
          ),
        );
      },
    );

    if (ok != true || !mounted) return;

    await _goOffline();
    await clearSession();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const RolePage(),
      ),
      (route) => false,
    );
  }

  void _openDriverSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DriverSettingsPage(
          driver: widget.driver,
        ),
      ),
    );
  }

  void _openDriverAccount() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DriverAccountHubPage(
          driver: widget.driver,
        ),
      ),
    );
  }

  void _openDriverNotifications() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppNotificationsPage(
          role: 'driver',
          userId: widget.driver.id,
        ),
      ),
    );
  }

  void _openDriverInvites() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DriverInviteFriendsPage(
          driverId:
              widget.driver.id,
          driverName:
              widget.driver.name,
        ),
      ),
    );
  }

  Future<void>
      _ensureOfferAreaNames(
    String rideId,
    Map<String, dynamic> data,
  ) async {
    if (_resolvingOfferAreas
        .contains(rideId)) {
      return;
    }

    final currentPickup =
        stringValue(
      data['pickupArea'],
    ).trim();

    final currentDestination =
        stringValue(
      data['destinationArea'],
    ).trim();

    if (currentPickup.isNotEmpty &&
        currentDestination
            .isNotEmpty) {
      return;
    }

    final pickupLat =
        doubleValue(
      data['pickupLat'],
    );

    final pickupLng =
        doubleValue(
      data['pickupLng'],
    );

    final destinationLat =
        doubleValue(
      data['destinationLat'],
    );

    final destinationLng =
        doubleValue(
      data['destinationLng'],
    );

    if (pickupLat == 0 ||
        pickupLng == 0 ||
        destinationLat == 0 ||
        destinationLng == 0) {
      return;
    }

    _resolvingOfferAreas
        .add(rideId);

    try {
      final names =
          await Future.wait<String>([
        currentPickup.isNotEmpty
            ? Future.value(
                currentPickup,
              )
            : GoogleMapsService
                .reverseGeocodeArea(
                LatLng(
                  pickupLat,
                  pickupLng,
                ),
              ),
        currentDestination
                .isNotEmpty
            ? Future.value(
                currentDestination,
              )
            : GoogleMapsService
                .reverseGeocodeArea(
                LatLng(
                  destinationLat,
                  destinationLng,
                ),
              ),
      ]);

      final update =
          <String, dynamic>{};

      if (currentPickup.isEmpty &&
          names[0]
              .trim()
              .isNotEmpty) {
        update['pickupArea'] =
            names[0].trim();
      }

      if (currentDestination
              .isEmpty &&
          names[1]
              .trim()
              .isNotEmpty) {
        update[
                'destinationArea'] =
            names[1].trim();
      }

      if (update.isNotEmpty) {
        await FirebaseFirestore
            .instance
            .collection(
              'ride_requests',
            )
            .doc(rideId)
            .set(
              update,
              SetOptions(
                merge: true,
              ),
            );
      }
    } catch (_) {
      // ما نوقف عرض الطلب إذا فشل اسم المنطقة.
    } finally {
      _resolvingOfferAreas
          .remove(rideId);
    }
  }

  void _notifyNearbyRide({
    required String rideId,
    required int fare,
    required double kmAway,
  }) {
    if (_alertedNearbyRides.contains(rideId)) {
      return;
    }

    _alertedNearbyRides.add(rideId);

    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .hideCurrentSnackBar();

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          content: Row(
            children: [
              const Icon(
                Icons.electric_rickshaw_rounded,
                color: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'طلب رحلة قريب منك • ${kmAway.toStringAsFixed(1)} كم • $fare د.ع',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _goOnline() async {
    if (!_manualOnline) return;

    try {
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .set({
        'online': true,
        'acceptingRides': true,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    _heartbeatTimer?.cancel();

    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) async {
        if (!_manualOnline) {
          _heartbeatTimer?.cancel();
          return;
        }

        try {
          Position? position =
              await Geolocator.getLastKnownPosition();

          position ??=
              await Geolocator.getCurrentPosition(
            desiredAccuracy:
                LocationAccuracy.medium,
            timeLimit:
                const Duration(seconds: 6),
          );

          await FirebaseFirestore.instance
              .collection('drivers')
              .doc(widget.driver.id)
              .set({
            'online': true,
            'acceptingRides': true,
            'lastSeen':
                FieldValue.serverTimestamp(),
            'lat': position.latitude,
            'lng': position.longitude,
          }, SetOptions(merge: true));
        } catch (_) {}
      },
    );
  }

  Future<void> _goOffline() async {
    _heartbeatTimer?.cancel();

    try {
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .set({
        'online': false,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  void _startOfferTimer(
    String rideId,
  ) {
    if (_currentOfferId ==
            rideId &&
        _offerTimer?.isActive ==
            true) {
      return;
    }

    _offerTimer?.cancel();

    if (!mounted) return;

    setState(() {
      _currentOfferId =
          rideId;
      _offerSeconds = 50;
    });

    _offerTimer =
        Timer.periodic(
      const Duration(
        seconds: 1,
      ),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_offerSeconds <= 1) {
          timer.cancel();

          setState(() {
            _skippedOfferIds
                .add(rideId);
            _currentOfferId =
                null;
            _offerSeconds = 50;
          });

          return;
        }

        setState(() {
          _offerSeconds--;
        });
      },
    );
  }

  void _skipCurrentOffer(
    String rideId,
  ) {
    _offerTimer?.cancel();

    if (!mounted) return;

    setState(() {
      _skippedOfferIds
          .add(rideId);
      _currentOfferId = null;
      _offerSeconds = 50;
    });
  }

  
  Future<Position?> _getDriverPositionForRide() async {
    final serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      if (!mounted) return null;

      final open = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text(
                'فعّل الموقع',
                textAlign: TextAlign.center,
              ),
              content: const Text(
                'GPS مطفي. فعّله حتى تگدر تقبل الرحلة.',
                textAlign: TextAlign.center,
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, false),
                  child: const Text('رجوع'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, true),
                  child: const Text('فتح إعدادات الموقع'),
                ),
              ],
            ),
          );
        },
      );

      if (open == true) {
        await Geolocator.openLocationSettings();
      }

      return null;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return null;

      final open = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text(
                'صلاحية الموقع مطلوبة',
                textAlign: TextAlign.center,
              ),
              content: const Text(
                'اسمح لتطبيق تكتك باستخدام الموقع من إعدادات التطبيق.',
                textAlign: TextAlign.center,
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, false),
                  child: const Text('رجوع'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, true),
                  child: const Text('فتح الإعدادات'),
                ),
              ],
            ),
          );
        },
      );

      if (open == true) {
        await Geolocator.openAppSettings();
      }

      return null;
    }

    if (permission == LocationPermission.denied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'اسمح للموقع حتى تگدر تقبل الرحلة',
            ),
          ),
        );
      }
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 12),
      );
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

Future<void> _acceptRide(
    String rideId,
    int fare,
  ) async {
    if (_accepting) return;

    final commission =
        commissionForFare(fare);

    final driverRef = FirebaseFirestore.instance
        .collection('drivers')
        .doc(widget.driver.id);

    final rideRef = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(rideId);

    setState(() {
      _accepting = true;
    });

    try {
      final location =
          await _getDriverPositionForRide();

      if (location == null) {
        throw Exception(
          'تعذر تحديد موقع السائق. تأكد من صلاحية الموقع وجرب مرة ثانية.',
        );
      }

      await FirebaseFirestore.instance.runTransaction(
        (transaction) async {
          final driverSnap =
              await transaction.get(driverRef);

          final rideSnap =
              await transaction.get(rideRef);

          if (!driverSnap.exists ||
              !rideSnap.exists) {
            throw Exception('الطلب غير موجود');
          }

          final driverData = driverSnap.data()!;
          final rideData = rideSnap.data()!;

          final balance =
              intValue(driverData['balance']);

          final activeRideId =
              stringValue(driverData['activeRideId']);

          if (activeRideId.isNotEmpty &&
              activeRideId != rideId) {
            throw Exception(
              'عندك رحلة حالية. كملها أو الغيها قبل قبول رحلة جديدة.',
            );
          }

          final active =
              driverData['active'] is bool
                  ? driverData['active'] as bool
                  : true;

          if (!active) {
            throw Exception('الحساب معطل');
          }

          if (driverData['acceptingRides'] == false ||
              driverData['online'] == false) {
            throw Exception(
              'فعّل حالة متصل حتى تستلم الرحلات',
            );
          }

          if (balance < commission) {
            throw Exception('الرصيد غير كافي');
          }

          if (stringValue(rideData['status']) !=
              'searching') {
            throw Exception(
              'تم قبول الطلب من سائق آخر',
            );
          }

          transaction.update(
            driverRef,
            {
              'activeRideId': rideId,
              'activeRideStatus': 'accepted',
              'activeRideUpdatedAt':
                  FieldValue.serverTimestamp(),
            },
          );

          transaction.update(
            rideRef,
            {
              'status': 'accepted',
              'driverId': widget.driver.id,
              'driverName': widget.driver.name,
              'driverPhone': widget.driver.phone,
              'driverProfilePhotoUrl':
                  widget.driver.profilePhotoUrl,
              'driverTuktukNumber':
                  widget.driver.tuktukNumber,
              'driverTuktukColor':
                  widget.driver.tuktukColor,
              'driverVerified':
                  widget.driver.verified,
              'driverLat': location.latitude,
              'driverLng': location.longitude,
              'acceptedAt':
                  FieldValue.serverTimestamp(),
            },
          );
        },
      );

      final acceptedRideSnap =
          await rideRef.get();
      final acceptedRideData =
          acceptedRideSnap.data() ?? {};
      final customerId = stringValue(
        acceptedRideData['customerId'],
      );

      if (customerId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('app_notifications')
            .add({
          'targetType': 'customer',
          'targetId': customerId,
          'type': 'ride',
          'title': 'تم قبول رحلتك ✅',
          'body':
              '${widget.driver.name} قبل طلبك ومتوجه إليك.',
          'rideId': rideId,
          'readBy': <String>[],
          'createdAt':
              FieldValue.serverTimestamp(),
        });

        await ExternalPushService.sendToUser(
          role: 'customer',
          userId: customerId,
          title: 'تم قبول رحلتك ✅',
          body: '${widget.driver.name} قبل طلبك ومتوجه إليك.',
          data: {
            'type': 'ride',
            'rideId': rideId,
          },
        );
      }

      _offerTimer?.cancel();

      if (!mounted) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'driver_active_ride_id',
        rideId,
      );

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DriverActiveRidePage(
            rideId: rideId,
            driver: widget.driver,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final errorText = e.toString();

      if (errorText.contains('الرصيد غير كافي')) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(24),
                ),
                icon: const Icon(
                  Icons.account_balance_wallet_rounded,
                  color: Colors.red,
                  size: 44,
                ),
                title: const Text(
                  'ليس لديك رصيد كافٍ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                content: const Text(
                  'ليس لديك رصيد كافٍ لقبول الرحلة. لتعبئة الرصيد تواصل مع الدعم الفني.',
                  textAlign: TextAlign.center,
                ),
                actionsAlignment:
                    MainAxisAlignment.center,
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext),
                    child: const Text('لاحقاً'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(dialogContext);

                      Future.delayed(
                        const Duration(
                          milliseconds: 150,
                        ),
                        () {
                          if (mounted) {
                            _openDriverSupport();
                          }
                        },
                      );
                    },
                    icon: const Icon(
                      Icons.support_agent_rounded,
                    ),
                    label: const Text(
                      'الدعم الفني',
                    ),
                  ),
                ],
              ),
            );
          },
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'ما قدرنا نكمل قبول الطلب هسه، جرّب مرة ثانية 💛',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _accepting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id)
          .snapshots(),
      builder: (context, driverSnapshot) {
        if (!driverSnapshot.hasData) {
          return const Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        final driverData =
            driverSnapshot.data!.data()
                    as Map<String, dynamic>? ??
                {};
        final balance =
            intValue(driverData['balance']);
        final minimumCommission =
            commissionForFare(
              PricingSettingsService.minimumFare,
            );
        final lowBalanceLimit =
            minimumCommission > 0
                ? minimumCommission * 5
                : 1500;
        final isLowBalance =
            balance <= lowBalanceLimit;
        final estimatedTrips =
            minimumCommission > 0
                ? balance ~/ minimumCommission
                : 0;

        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            backgroundColor:
                const Color(0xffF8F8F8),
            body: SafeArea(
              child:
                  StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore
                    .instance
                    .collection(
                      'ride_requests',
                    )
                    .where(
                      'status',
                      isEqualTo:
                          'searching',
                    )
                    .limit(30)
                    .snapshots(),
                builder: (context, snapshot) {
                  final docs =
                      snapshot.data?.docs ??
                          const [];

                  final driverLat =
                      doubleValue(
                    driverData['lat'],
                  );
                  final driverLng =
                      doubleValue(
                    driverData['lng'],
                  );

                  final acceptingRides =
                      (_manualOnlineLoaded
                              ? _manualOnline
                              : driverData['acceptingRides'] != false) &&
                          driverData['online'] != false;

                  final available =
                      docs.where((doc) {
                    if (!acceptingRides) {
                      return false;
                    }

                    final data = doc.data()
                        as Map<String,
                            dynamic>;
                    final fare = intValue(
                      data['price'],
                    );

                    if (balance <= 0 ||
                        balance <
                            commissionForFare(
                              fare,
                            )) {
                      return false;
                    }

                    final pLat =
                        doubleValue(
                      data['pickupLat'],
                    );
                    final pLng =
                        doubleValue(
                      data['pickupLng'],
                    );

                    if (driverLat == 0 ||
                        driverLng == 0 ||
                        pLat == 0 ||
                        pLng == 0) {
                      return true;
                    }

                    final createdAt =
                        timestampToDate(
                          data['createdAt'],
                        ) ??
                            DateTime.now();

                    final ageSeconds =
                        DateTime.now()
                            .difference(createdAt)
                            .inSeconds;

                    // توزيع تدريجي: القريب جداً يشوف الطلب أولاً،
                    // وبعدها تتوسع دائرة العرض تلقائياً.
                    final maxMeters =
                        ageSeconds < 20
                            ? 2000.0
                            : ageSeconds < 40
                                ? 5000.0
                                : 10000.0;

                    return Geolocator
                            .distanceBetween(
                          driverLat,
                          driverLng,
                          pLat,
                          pLng,
                        ) <=
                        maxMeters;
                  }).toList();

                  available.sort(
                    (a, b) {
                      double distance(
                        QueryDocumentSnapshot
                            doc,
                      ) {
                        final data =
                            doc.data()
                                as Map<String,
                                    dynamic>;

                        if (driverLat == 0 ||
                            driverLng == 0) {
                          return 0;
                        }

                        return Geolocator
                            .distanceBetween(
                          driverLat,
                          driverLng,
                          doubleValue(
                            data[
                                'pickupLat'],
                          ),
                          doubleValue(
                            data[
                                'pickupLng'],
                          ),
                        );
                      }

                      return distance(a)
                          .compareTo(
                        distance(b),
                      );
                    },
                  );

                  QueryDocumentSnapshot?
                      offer;

                  if (_currentOfferId !=
                      null) {
                    for (final item
                        in available) {
                      if (item.id ==
                          _currentOfferId) {
                        offer = item;
                        break;
                      }
                    }
                  }

                  if (offer == null) {
                    for (final item
                        in available) {
                      if (!_skippedOfferIds
                          .contains(
                            item.id,
                          )) {
                        offer = item;
                        break;
                      }
                    }
                  }

                  Map<String, dynamic>
                      offerData = {};
                  int fare = 0;
                  double nearbyKm = 0;

                  if (offer != null) {
                    offerData =
                        offer.data()
                            as Map<String,
                                dynamic>;
                    fare = intValue(
                      offerData['price'],
                    );
                    final pLat =
                        doubleValue(
                      offerData[
                          'pickupLat'],
                    );
                    final pLng =
                        doubleValue(
                      offerData[
                          'pickupLng'],
                    );
                    if (driverLat != 0 &&
                        driverLng != 0 &&
                        pLat != 0 &&
                        pLng != 0) {
                      nearbyKm =
                          Geolocator
                                  .distanceBetween(
                                driverLat,
                                driverLng,
                                pLat,
                                pLng,
                              ) /
                              1000;
                    }

                    _notifyNearbyRide(
                      rideId: offer.id,
                      fare: fare,
                      kmAway: nearbyKm,
                    );

                    final selectedRideId =
                        offer.id;

                    final selectedRideData =
                        Map<String,
                            dynamic>.from(
                      offerData,
                    );

                    WidgetsBinding
                        .instance
                        .addPostFrameCallback(
                      (_) {
                        if (!mounted) {
                          return;
                        }

                        if (_currentOfferId !=
                                selectedRideId ||
                            _offerTimer
                                    ?.isActive !=
                                true) {
                          _startOfferTimer(
                            selectedRideId,
                          );
                        }

                        unawaited(
                          _ensureOfferAreaNames(
                            selectedRideId,
                            selectedRideData,
                          ),
                        );
                      },
                    );
                  }

                  return ListView(
                    padding:
                        const EdgeInsets
                            .fromLTRB(
                      16,
                      14,
                      16,
                      24,
                    ),
                    children: [
                      Row(
                        children: [
                          Switch.adaptive(
                            value: _manualOnlineLoaded
                                ? _manualOnline
                                : driverData['acceptingRides'] != false,
                            activeColor:
                                const Color(
                              0xff22A663,
                            ),
                            onChanged:
                                (value) async {
                              await _setManualOnline(value);
                            },
                          ),
                          Text(
                            (_manualOnlineLoaded
                                        ? _manualOnline
                                        : driverData['acceptingRides'] != false)
                                ? 'متصل'
                                : 'غير متصل',
                            style:
                                const TextStyle(
                              color: Color(
                                0xff16834D,
                              ),
                              fontWeight:
                                  FontWeight
                                      .w900,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip:
                                'دعوة الأصدقاء',
                            onPressed:
                                _openDriverInvites,
                            icon:
                                const Icon(
                              Icons
                                  .group_add_rounded,
                            ),
                          ),
                          IconButton(
                            onPressed:
                                _openDriverNotifications,
                            icon:
                                const Icon(
                              Icons
                                  .notifications_none_rounded,
                            ),
                          ),
                          IconButton(
                            onPressed:
                                _openDriverAccount,
                            icon:
                                const Icon(
                              Icons
                                  .person_outline_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(
                        height: 8,
                      ),
                      Container(
                        padding:
                            const EdgeInsets
                                .all(18),
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.white,
                          borderRadius:
                              BorderRadius
                                  .circular(
                            16,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'الرصيد الحالي',
                              style:
                                  TextStyle(
                                color:
                                    Colors
                                        .black54,
                                fontSize:
                                    13,
                              ),
                            ),
                            const SizedBox(
                              height: 4,
                            ),
                            Text(
                              '$balance د.ع',
                              style:
                                  const TextStyle(
                                fontSize: 28,
                                fontWeight:
                                    FontWeight
                                        .w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isLowBalance) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xffFFF1F0),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xffFFD0CC),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.account_balance_wallet_rounded,
                                color: Color(0xffD84A3A),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  estimatedTrips > 0
                                      ? 'رصيدك منخفض • يكفي تقريباً لـ $estimatedTrips رحلات بالحد الأدنى'
                                      : 'رصيدك منخفض، عبّي الرصيد حتى تبقى تستلم الطلبات',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  _openDriverSupport(
                                    subject: 'طلب تعبئة رصيد',
                                    message:
                                        'مرحباً، أريد تعبئة رصيد حساب السائق.',
                                  );
                                },
                                child: const Text('تعبئة'),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(
                        height: 14,
                      ),
                      Container(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 18,
                        ),
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.white,
                          borderRadius:
                              BorderRadius
                                  .circular(
                            16,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child:
                                  _driverMiniStat(
                                'الرحلات',
                                '${intValue(driverData['todayRides'])}',
                              ),
                            ),
                            Expanded(
                              child:
                                  _driverMiniStat(
                                'كم',
                                doubleValue(driverData['todayKm'])
                                    .toStringAsFixed(
                                  1,
                                ),
                              ),
                            ),
                            Expanded(
                              child:
                                  _driverMiniStat(
                                'الأرباح',
                                '${intValue(driverData['todayEarnings'])}',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        height: 18,
                      ),
                      const Text(
                        'طلبات قريبة',
                        style:
                            TextStyle(
                          fontSize: 17,
                          fontWeight:
                              FontWeight
                                  .w900,
                        ),
                      ),
                      const SizedBox(
                        height: 10,
                      ),
                      if (offer == null)
                        Container(
                          padding:
                              const EdgeInsets
                                  .all(24),
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              16,
                            ),
                          ),
                          child:
                              const Center(
                            child: Text(
                              'لا توجد طلبات قريبة حالياً',
                              style:
                                  TextStyle(
                                color:
                                    Colors
                                        .black54,
                              ),
                            ),
                          ),
                        )
                      else
                        Container(
                          padding:
                              const EdgeInsets
                                  .all(16),
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              16,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding:
                                        const EdgeInsets
                                            .symmetric(
                                      horizontal:
                                          10,
                                      vertical:
                                          6,
                                    ),
                                    decoration:
                                        BoxDecoration(
                                      color:
                                          const Color(
                                        0xffEAF8F0,
                                      ),
                                      borderRadius:
                                          BorderRadius
                                              .circular(
                                        20,
                                      ),
                                    ),
                                    child: Text(
                                      nearbyKm >
                                              0
                                          ? '${nearbyKm.toStringAsFixed(1)} كم عنك'
                                          : 'قريب منك',
                                      style:
                                          const TextStyle(
                                        color:
                                            Color(
                                          0xff16834D,
                                        ),
                                        fontSize:
                                            12,
                                        fontWeight:
                                            FontWeight
                                                .w900,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    width: 54,
                                    height: 54,
                                    alignment:
                                        Alignment
                                            .center,
                                    decoration:
                                        BoxDecoration(
                                      color:
                                          const Color(
                                        0xffFFF3C4,
                                      ),
                                      shape:
                                          BoxShape
                                              .circle,
                                      border:
                                          Border.all(
                                        color:
                                            const Color(
                                          0xffFFC21A,
                                        ),
                                        width: 2,
                                      ),
                                    ),
                                    child: Text(
                                      '$_offerSeconds',
                                      style:
                                          const TextStyle(
                                        fontSize:
                                            18,
                                        fontWeight:
                                            FontWeight
                                                .w900,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(
                                height: 14,
                              ),
                              Container(
                                width:
                                    double.infinity,
                                padding:
                                    const EdgeInsets
                                        .all(
                                  14,
                                ),
                                decoration:
                                    BoxDecoration(
                                  color:
                                      const Color(
                                    0xffF7F8FA,
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(
                                    14,
                                  ),
                                  border:
                                      Border.all(
                                    color:
                                        const Color(
                                      0xffE6E8EC,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    const Text(
                                      'من وين إلى وين',
                                      style:
                                          TextStyle(
                                        color:
                                            Colors
                                                .black54,
                                        fontSize:
                                            12,
                                        fontWeight:
                                            FontWeight
                                                .w800,
                                      ),
                                    ),
                                    const SizedBox(
                                      height: 10,
                                    ),
                                    Text(
                                      'من: ${stringValue(offerData['pickupArea']).trim().isNotEmpty ? stringValue(offerData['pickupArea']).trim() : compactPlaceName(stringValue(offerData['pickupAddress']))}',
                                      maxLines:
                                          2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      style:
                                          const TextStyle(
                                        fontSize:
                                            17,
                                        fontWeight:
                                            FontWeight
                                                .w900,
                                      ),
                                    ),
                                    const SizedBox(
                                      height: 8,
                                    ),
                                    Text(
                                      'إلى: ${stringValue(offerData['destinationArea']).trim().isNotEmpty ? stringValue(offerData['destinationArea']).trim() : compactPlaceName(stringValue(offerData['destinationAddress']))}',
                                      maxLines:
                                          2,
                                      overflow:
                                          TextOverflow
                                              .ellipsis,
                                      style:
                                          const TextStyle(
                                        fontSize:
                                            17,
                                        fontWeight:
                                            FontWeight
                                                .w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(
                                height: 12,
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child:
                                        Container(
                                      padding:
                                          const EdgeInsets
                                              .symmetric(
                                        vertical:
                                            10,
                                      ),
                                      decoration:
                                          BoxDecoration(
                                        color:
                                            const Color(
                                          0xffFFF8DE,
                                        ),
                                        borderRadius:
                                            BorderRadius
                                                .circular(
                                          12,
                                        ),
                                      ),
                                      child:
                                          Column(
                                        children: [
                                          const Text(
                                            'الكروة',
                                            style:
                                                TextStyle(
                                              color:
                                                  Colors
                                                      .black54,
                                              fontSize:
                                                  11,
                                            ),
                                          ),
                                          const SizedBox(
                                            height:
                                                2,
                                          ),
                                          Text(
                                            '$fare د.ع',
                                            style:
                                                const TextStyle(
                                              fontSize:
                                                  18,
                                              fontWeight:
                                                  FontWeight
                                                      .w900,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                    width: 10,
                                  ),
                                  Expanded(
                                    child:
                                        Container(
                                      padding:
                                          const EdgeInsets
                                              .symmetric(
                                        vertical:
                                            10,
                                      ),
                                      decoration:
                                          BoxDecoration(
                                        color:
                                            const Color(
                                          0xffF2F4F7,
                                        ),
                                        borderRadius:
                                            BorderRadius
                                                .circular(
                                          12,
                                        ),
                                      ),
                                      child:
                                          Column(
                                        children: [
                                          const Text(
                                            'وقت القرار',
                                            style:
                                                TextStyle(
                                              color:
                                                  Colors
                                                      .black54,
                                              fontSize:
                                                  11,
                                            ),
                                          ),
                                          const SizedBox(
                                            height:
                                                2,
                                          ),
                                          Text(
                                            '$_offerSeconds ثانية',
                                            style:
                                                const TextStyle(
                                              fontSize:
                                                  16,
                                              fontWeight:
                                                  FontWeight
                                                      .w900,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(
                                height: 14,
                              ),
                              SizedBox(
                                width:
                                    double.infinity,
                                height: 50,
                                child:
                                    ElevatedButton(
                                  style:
                                      ElevatedButton
                                          .styleFrom(
                                    backgroundColor:
                                        const Color(
                                      0xffFFC21A,
                                    ),
                                    foregroundColor:
                                        Colors
                                            .black,
                                    elevation:
                                        0,
                                    shape:
                                        RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(
                                        12,
                                      ),
                                    ),
                                  ),
                                  onPressed:
                                      _accepting
                                          ? null
                                          : () {
                                              _acceptRide(
                                                offer!.id,
                                                fare,
                                              );
                                            },
                                  child:
                                      const Text(
                                    'قبول الطلب',
                                    style:
                                        TextStyle(
                                      fontSize:
                                          17,
                                      fontWeight:
                                          FontWeight
                                              .w900,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(
                                height: 8,
                              ),
                              SizedBox(
                                width:
                                    double.infinity,
                                height: 44,
                                child:
                                    OutlinedButton(
                                  style:
                                      OutlinedButton
                                          .styleFrom(
                                    foregroundColor:
                                        Colors
                                            .red,
                                    side:
                                        const BorderSide(
                                      color:
                                          Color(
                                        0xffE75555,
                                      ),
                                    ),
                                    shape:
                                        RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(
                                        12,
                                      ),
                                    ),
                                  ),
                                  onPressed: () {
                                    _skipCurrentOffer(
                                      offer!.id,
                                    );
                                  },
                                  child:
                                      const Text(
                                    'تجاهل',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _driverMiniStat(
    String label,
    String value,
  ) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight:
                FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }

  Widget _driverOfferLine(
    Color color,
    String text,
  ) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text.isEmpty
                ? 'العنوان غير متوفر'
                : text,
            maxLines: 1,
            overflow:
                TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight:
                  FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }


  Widget _driverOfferRow(
    String title,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 7,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.black54,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// DRIVER ACTIVE RIDE
// ============================================================

class DriverActiveRidePage extends StatefulWidget {
  final String rideId;
  final DriverProfile driver;

  const DriverActiveRidePage({
    super.key,
    required this.rideId,
    required this.driver,
  });

  @override
  State<DriverActiveRidePage> createState() =>
      _DriverActiveRidePageState();
}

class _DriverActiveRidePageState
    extends State<DriverActiveRidePage> {
  StreamSubscription<Position>?
      _positionSubscription;

  bool _changing = false;
  DateTime? _lastDriverRouteUpdate;

  static const double _arriveRadiusMeters = 250;
  static const double _completeRadiusMeters = 400;

  Future<double?> _distanceFromCurrentPosition(
    LatLng target,
  ) async {
    try {
      Position? position;

      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      if (position == null) return null;

      return Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        target.latitude,
        target.longitude,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();

    _startLocationStream();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startLocationStream() async {
    final enabled =
        await Geolocator.isLocationServiceEnabled();

    if (!enabled) return;

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    late LocationSettings settings;

    if (defaultTargetPlatform ==
        TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        intervalDuration:
            const Duration(seconds: 2),
        foregroundNotificationConfig:
            const ForegroundNotificationConfig(
          notificationTitle:
              'تكتك • رحلة جارية',
          notificationText:
              'يتم تحديث موقع السائق أثناء الرحلة',
          enableWakeLock: true,
        ),
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      );
    }

    _positionSubscription =
        Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (position) async {
        try {
          final rideRef = FirebaseFirestore.instance
              .collection('ride_requests')
              .doc(widget.rideId);

          await rideRef.update({
            'driverLat': position.latitude,
            'driverLng': position.longitude,
          });

          // كل عدة ثواني نعيد حساب طريق السائق الحقيقي على الشوارع.
          final now = DateTime.now();
          final shouldRefreshRoute = _lastDriverRouteUpdate == null ||
              now.difference(_lastDriverRouteUpdate!).inSeconds >= 5;

          if (!shouldRefreshRoute) return;
          _lastDriverRouteUpdate = now;

          final rideSnap = await rideRef.get();
          final data = rideSnap.data();
          if (data == null) return;

          final status = stringValue(data['status']);
          if (status != 'accepted' &&
              status != 'arrived' &&
              status != 'started') {
            return;
          }

          final pickup = LatLng(
            doubleValue(data['pickupLat']),
            doubleValue(data['pickupLng']),
          );
          final destination = LatLng(
            doubleValue(data['destinationLat']),
            doubleValue(data['destinationLng']),
          );

          final driverPoint = LatLng(
            position.latitude,
            position.longitude,
          );

          final target = status == 'started'
              ? destination
              : pickup;

          final route = await GoogleMapsService.computeRoute(
            driverPoint,
            target,
          );

          await rideRef.update({
            'driverRoutePolyline': route.encodedPolyline,
            'driverRouteDistanceMeters': route.distanceMeters,
            'driverRouteDuration': route.duration,
            'driverRouteTarget': status == 'started'
                ? 'destination'
                : 'pickup',
            'driverRouteUpdatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {
          // إذا فشل تحديث المسار، يبقى تحديث موقع السائق شغال.
        }
      },
    );
  }

  Future<void> _markArrived() async {
    if (_changing) return;

    setState(() {
      _changing = true;
    });

    try {
      final rideRef = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(widget.rideId);

      final rideSnap = await rideRef.get();
      final rideData = rideSnap.data();

      if (rideData == null) {
        throw Exception('بيانات الرحلة غير موجودة');
      }

      if (stringValue(rideData['status']) != 'accepted') {
        throw Exception('حالة الرحلة تغيرت، حدّث الصفحة');
      }

      final pickup = LatLng(
        doubleValue(rideData['pickupLat']),
        doubleValue(rideData['pickupLng']),
      );

      final distance =
          await _distanceFromCurrentPosition(pickup);

      if (distance == null) {
        throw Exception(
          'ما قدرنا نحدد موقعك. فعّل GPS وحاول مرة ثانية.',
        );
      }

      if (distance > _arriveRadiusMeters) {
        throw Exception(
          'بعدك بعيد عن الزبون ${(distance / 1000).toStringAsFixed(1)} كم. زر وصلت يشتغل من تصير قريب من نقطة الالتقاط.',
        );
      }

      await rideRef.update({
        'status': 'arrived',
        'arrivedAt': FieldValue.serverTimestamp(),
        'arrivedDistanceMeters': distance.round(),
      });

      final customerId =
          stringValue(rideData['customerId']);

      if (customerId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('app_notifications')
            .add({
          'targetType': 'customer',
          'targetId': customerId,
          'type': 'ride',
          'title': 'وصل السائق 📍',
          'body':
              '${widget.driver.name} وصل إلى نقطة الانطلاق.',
          'rideId': widget.rideId,
          'readBy': <String>[],
          'createdAt':
              FieldValue.serverTimestamp(),
        });

        await ExternalPushService.sendToUser(
          role: 'customer',
          userId: customerId,
          title: 'وصل السائق 📍',
          body:
              '${widget.driver.name} وصل إلى نقطة الانطلاق.',
          data: {
            'type': 'ride',
            'rideId': widget.rideId,
            'status': 'arrived',
          },
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _changing = false;
        });
      }
    }
  }

  Future<void> _startRide() async {
    if (_changing) return;

    setState(() {
      _changing = true;
    });

    try {
      final rideRef = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(widget.rideId);

      final snap = await rideRef.get();
      final data = snap.data();

      if (data == null) {
        throw Exception('بيانات الرحلة غير موجودة');
      }

      if (stringValue(data['status']) != 'arrived') {
        throw Exception(
          'لازم تضغط وصلت للعميل قبل بدء الرحلة',
        );
      }

      await rideRef.update({
        'status': 'started',
        'startedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _changing = false;
        });
      }
    }
  }

  Future<void> _completeRide() async {
    if (_changing) return;

    setState(() {
      _changing = true;
    });

    try {
      final rideRef = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(widget.rideId);

      final preRideSnap = await rideRef.get();
      final preRideData = preRideSnap.data();

      if (preRideData == null) {
        throw Exception('بيانات الرحلة غير موجودة');
      }

      if (stringValue(preRideData['status']) != 'started') {
        throw Exception(
          'لازم تبدأ الرحلة قبل ما تنهيها',
        );
      }

      final destination = LatLng(
        doubleValue(preRideData['destinationLat']),
        doubleValue(preRideData['destinationLng']),
      );

      final distance =
          await _distanceFromCurrentPosition(destination);

      if (distance == null) {
        throw Exception(
          'ما قدرنا نحدد موقعك. فعّل GPS وحاول مرة ثانية.',
        );
      }

      if (distance > _completeRadiusMeters) {
        throw Exception(
          'بعدك بعيد عن الوجهة ${(distance / 1000).toStringAsFixed(1)} كم. إنهاء الرحلة يشتغل من تصير قريب من نقطة الوصول.',
        );
      }

      final driverRef = FirebaseFirestore.instance
          .collection('drivers')
          .doc(widget.driver.id);

      final balanceTxRef =
          FirebaseFirestore.instance
              .collection(
                'driver_balance_transactions',
              )
              .doc();

      final now = DateTime.now();
      final todayKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      await FirebaseFirestore.instance
          .runTransaction(
        (transaction) async {
          final rideSnapshot =
              await transaction.get(rideRef);

          final driverSnapshot =
              await transaction.get(driverRef);

          if (!rideSnapshot.exists ||
              !driverSnapshot.exists) {
            throw Exception(
              'بيانات الرحلة غير موجودة',
            );
          }

          final rideData =
              rideSnapshot.data()!;

          final driverData =
              driverSnapshot.data()!;

          if (stringValue(rideData['status']) != 'started') {
            throw Exception(
              'حالة الرحلة تغيرت، حدّث الصفحة',
            );
          }

          final fare =
              intValue(rideData['price']);

          final savedCommission =
              intValue(rideData['commissionAmount']);

          final commission = savedCommission > 0
              ? savedCommission
              : commissionForFare(fare);

          final savedCommissionPercent =
              doubleValue(rideData['commissionPercent']);

          final commissionPercent =
              savedCommissionPercent > 0
                  ? savedCommissionPercent
                  : PricingSettingsService.commissionPercent;

          final oldBalance =
              intValue(driverData['balance']);

          final alreadyCharged =
              rideData['commissionCharged'] ==
                  true;

          var newBalance = oldBalance;

          if (!alreadyCharged) {
            if (oldBalance < commission) {
              throw Exception(
                'الرصيد لا يكفي',
              );
            }

            newBalance =
                oldBalance - commission;

            transaction.set(
              balanceTxRef,
              {
                'driverId': widget.driver.id,
                'driverName':
                    widget.driver.name,
                'rideId': widget.rideId,
                'type': 'commission',
                'amount': -commission,
                'commissionAmount':
                    commission,
                'balanceBefore':
                    oldBalance,
                'balanceAfter':
                    newBalance,
                'createdAt':
                    FieldValue.serverTimestamp(),
              },
            );
          }

          final sameStatsDay =
              stringValue(driverData['statsDayKey']) ==
                  todayKey;

          final todayRides =
              (sameStatsDay
                      ? intValue(driverData['todayRides'])
                      : 0) +
                  1;

          final todayKm =
              (sameStatsDay
                      ? doubleValue(driverData['todayKm'])
                      : 0) +
                  doubleValue(rideData['distanceKm']);

          final todayEarnings =
              (sameStatsDay
                      ? intValue(driverData['todayEarnings'])
                      : 0) +
                  (fare - commission);

          transaction.update(
            driverRef,
            {
              'balance': newBalance,
              'balanceUpdatedAt':
                  FieldValue.serverTimestamp(),
              'activeRideId': FieldValue.delete(),
              'activeRideStatus': FieldValue.delete(),
              'activeRideUpdatedAt':
                  FieldValue.serverTimestamp(),
              'statsDayKey': todayKey,
              'todayRides': todayRides,
              'todayKm': todayKm,
              'todayEarnings': todayEarnings,
            },
          );

          transaction.update(
            rideRef,
            {
              'status': 'completed',
              'completedAt':
                  FieldValue.serverTimestamp(),
              'completedDistanceMeters':
                  distance.round(),
              'commissionPercent':
                  commissionPercent,
              'commissionAmount':
                  commission,
              'commissionCharged': true,
            },
          );
        },
      );

      await DriverReferralService
          .recordCompletedRide(
        rideId:
            widget.rideId,
        referredDriverId:
            widget.driver.id,
      );

      await _positionSubscription?.cancel();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('driver_active_ride_id');

      if (!mounted) return;

      await _showCustomerRatingDialog();

      if (!mounted) return;

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e
                .toString()
                .replaceFirst('Exception: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _changing = false;
        });
      }
    }
  }

  Future<void> _showCustomerRatingDialog() async {
    int rating = 5;
    final noteController = TextEditingController();

    final submit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setLocalState) {
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                title: const Text(
                  'قيّم الزبون',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'شلون كانت رحلتك ويا الزبون؟',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: List.generate(
                        5,
                        (index) => IconButton(
                          onPressed: () {
                            setLocalState(() {
                              rating = index + 1;
                            });
                          },
                          icon: Icon(
                            index < rating
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 34,
                            color: const Color(0xffFFC107),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: noteController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'ملاحظة اختيارية',
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, false),
                    child: const Text('تخطي'),
                  ),
                  ElevatedButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, true),
                    child: const Text('إرسال التقييم'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (submit != true) {
      noteController.dispose();
      return;
    }

    final rideRef = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(widget.rideId);

    try {
      final rideSnap = await rideRef.get();
      final rideData = rideSnap.data() ?? {};
      final customerId =
          stringValue(rideData['customerId']);

      await rideRef.set({
        'driverCustomerRating': rating,
        'driverCustomerRatingNote':
            noteController.text.trim(),
        'driverRatedCustomerAt':
            FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (customerId.isNotEmpty) {
        final customerRef = FirebaseFirestore.instance
            .collection('customers')
            .doc(customerId);

        await FirebaseFirestore.instance.runTransaction(
          (transaction) async {
            final customerSnap =
                await transaction.get(customerRef);

            if (!customerSnap.exists) return;

            final data = customerSnap.data()!;
            final oldTotal =
                intValue(data['ratingFromDriversTotal']);
            final oldCount =
                intValue(data['ratingFromDriversCount']);

            final newTotal = oldTotal + rating;
            final newCount = oldCount + 1;
            final average =
                newTotal / newCount;

            transaction.update(customerRef, {
              'ratingFromDriversTotal': newTotal,
              'ratingFromDriversCount': newCount,
              'ratingFromDriversAverage': average,
              'ratingFromDriversUpdatedAt':
                  FieldValue.serverTimestamp(),
            });
          },
        );
      }
    } catch (_) {
      // التقييم تحسين إضافي؛ ما نخلي فشله يمنع إكمال الرحلة.
    } finally {
      noteController.dispose();
    }
  }


  Future<void> _cancelRide() async {
    if (_changing) return;

    final reason = await showRideCancelReasonDialog(
      context,
      isDriver: true,
    );

    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _changing = true);

    try {
      await RideActions.cancelRide(
        rideId: widget.rideId,
        canceledBy: 'driver',
        cancelReason: reason,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('driver_active_ride_id');

      await _positionSubscription?.cancel();

      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => DriverHomePage(
            driver: widget.driver,
          ),
        ),
        (route) => false,
      );
    } finally {
      if (mounted) {
        setState(() => _changing = false);
      }
    }
  }

  Future<void> _openChat() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RideChatPage(
          rideId: widget.rideId,
          senderRole: 'driver',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('ride_requests')
              .doc(widget.rideId)
              .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            final raw =
                snapshot.data!.data();
            if (raw == null) {
              return const Center(
                child: Text(
                  'الرحلة غير موجودة',
                ),
              );
            }

            final data =
                raw as Map<String, dynamic>;
            final status =
                stringValue(data['status']);

            if (status == 'canceled') {
              WidgetsBinding.instance
                  .addPostFrameCallback(
                (_) async {
                  if (!mounted) return;
                  final prefs =
                      await SharedPreferences
                          .getInstance();
                  await prefs.remove(
                    'driver_active_ride_id',
                  );
                  if (!mounted) return;
                  Navigator.of(context)
                      .pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (_) =>
                          DriverHomePage(
                        driver:
                            widget.driver,
                      ),
                    ),
                    (route) => false,
                  );
                },
              );
              return const Center(
                child:
                    CircularProgressIndicator(),
              );
            }

            final fare =
                intValue(data['price']);
            final customerPhone =
                stringValue(
              data['customerPhone'],
            );
            final pickup = LatLng(
              doubleValue(data['pickupLat']),
              doubleValue(data['pickupLng']),
            );
            final destination =
                LatLng(
              doubleValue(
                data['destinationLat'],
              ),
              doubleValue(
                data['destinationLng'],
              ),
            );

            final storedTripRoute =
                GoogleMapsService
                    .decodePolyline(
              stringValue(
                data['routePolyline'],
              ),
            );
            final storedDriverRoute =
                GoogleMapsService
                    .decodePolyline(
              stringValue(
                data[
                    'driverRoutePolyline'],
              ),
            );

            LatLng? driver;
            if (data['driverLat'] != null &&
                data['driverLng'] != null) {
              driver = LatLng(
                doubleValue(
                  data['driverLat'],
                ),
                doubleValue(
                  data['driverLng'],
                ),
              );
            }

            final target =
                status == 'started'
                    ? destination
                    : pickup;

            final remainingMeters =
                intValue(
              data[
                  'driverRouteDistanceMeters'],
            );

            return Stack(
              children: [
                Positioned.fill(
                  child: GoogleMap(
                    initialCameraPosition:
                        CameraPosition(
                      target:
                          driver ?? target,
                      zoom: 16,
                    ),
                    zoomControlsEnabled:
                        false,
                    mapToolbarEnabled:
                        false,
                    myLocationButtonEnabled:
                        false,
                    markers: {
                      Marker(
                        markerId:
                            const MarkerId(
                          'pickup',
                        ),
                        position: pickup,
                        icon: BitmapDescriptor
                            .defaultMarkerWithHue(
                          BitmapDescriptor
                              .hueGreen,
                        ),
                      ),
                      Marker(
                        markerId:
                            const MarkerId(
                          'destination',
                        ),
                        position:
                            destination,
                        icon: BitmapDescriptor
                            .defaultMarkerWithHue(
                          BitmapDescriptor
                              .hueRed,
                        ),
                      ),
                      if (driver != null)
                        Marker(
                          markerId:
                              const MarkerId(
                            'driver',
                          ),
                          position:
                              driver,
                          icon: BitmapDescriptor
                              .defaultMarkerWithHue(
                            BitmapDescriptor
                                .hueOrange,
                          ),
                        ),
                    },
                    polylines: {
                      Polyline(
                        polylineId:
                            const PolylineId(
                          'live',
                        ),
                        points:
                            storedDriverRoute
                                    .isNotEmpty
                                ? storedDriverRoute
                                : <LatLng>[
                                    driver ??
                                        target,
                                    target,
                                  ],
                        width: 6,
                        color:
                            Colors.black,
                        startCap:
                            Cap.roundCap,
                        endCap:
                            Cap.roundCap,
                        jointType:
                            JointType.round,
                      ),
                      if (status ==
                              'started' &&
                          storedTripRoute
                              .isNotEmpty)
                        Polyline(
                          polylineId:
                              const PolylineId(
                            'trip',
                          ),
                          points:
                              storedTripRoute,
                          width: 5,
                          color:
                              const Color(
                            0xff24A36A,
                          ),
                          startCap:
                              Cap.roundCap,
                          endCap:
                              Cap.roundCap,
                          jointType:
                              JointType.round,
                        ),
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding:
                        const EdgeInsets
                            .all(14),
                    child: Row(
                      children: [
                        Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 13,
                            vertical: 9,
                          ),
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.white,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              14,
                            ),
                          ),
                          child: Text(
                            'رحلة جارية',
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight
                                      .w900,
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed:
                              _changing
                                  ? null
                                  : _cancelRide,
                          child:
                              const Text(
                            'إلغاء الرحلة',
                            style:
                                TextStyle(
                              color:
                                  Colors.red,
                              fontWeight:
                                  FontWeight
                                      .w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment:
                      Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    child: Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets
                              .fromLTRB(
                        20,
                        18,
                        20,
                        18,
                      ),
                      decoration:
                          const BoxDecoration(
                        color:
                            Colors.white,
                        borderRadius:
                            BorderRadius
                                .vertical(
                          top:
                              Radius.circular(
                            26,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .stretch,
                        children: [
                          Text(
                            status ==
                                    'started'
                                ? 'الوجهة'
                                : 'نقطة الالتقاط',
                            style:
                                const TextStyle(
                              color:
                                  Colors
                                      .black54,
                              fontSize:
                                  12,
                            ),
                          ),
                          const SizedBox(
                            height: 5,
                          ),
                          Text(
                            status ==
                                    'started'
                                ? stringValue(
                                    data[
                                        'destinationAddress'],
                                  )
                                : stringValue(
                                    data[
                                        'pickupAddress'],
                                  ),
                            maxLines: 1,
                            overflow:
                                TextOverflow
                                    .ellipsis,
                            style:
                                const TextStyle(
                              fontSize: 17,
                              fontWeight:
                                  FontWeight
                                      .w900,
                            ),
                          ),
                          const SizedBox(
                            height: 16,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child:
                                    _driverRideMetric(
                                  'المسافة المتبقية',
                                  remainingMeters >
                                          0
                                      ? '${(remainingMeters / 1000).toStringAsFixed(1)} كم'
                                      : '—',
                                ),
                              ),
                              Expanded(
                                child:
                                    _driverRideMetric(
                                  'السعر',
                                  '$fare د.ع',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(
                            height: 14,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child:
                                    OutlinedButton.icon(
                                  onPressed:
                                      _openChat,
                                  icon:
                                      const Icon(
                                    Icons
                                        .chat_bubble_outline_rounded,
                                  ),
                                  label:
                                      const Text(
                                    'رسالة',
                                  ),
                                ),
                              ),
                              const SizedBox(
                                width: 10,
                              ),
                              Expanded(
                                child:
                                    OutlinedButton.icon(
                                  onPressed:
                                      customerPhone
                                              .isEmpty
                                          ? null
                                          : () async {
                                              await launchUrl(
                                                Uri(
                                                  scheme:
                                                      'tel',
                                                  path:
                                                      customerPhone,
                                                ),
                                              );
                                            },
                                  icon:
                                      const Icon(
                                    Icons
                                        .phone_rounded,
                                  ),
                                  label:
                                      const Text(
                                    'اتصال',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(
                            height: 12,
                          ),
                          SizedBox(
                            height: 54,
                            child:
                                ElevatedButton(
                              style:
                                  ElevatedButton
                                      .styleFrom(
                                backgroundColor:
                                    const Color(
                                  0xff1FA35F,
                                ),
                                foregroundColor:
                                    Colors.white,
                                elevation: 0,
                                shape:
                                    RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(
                                    12,
                                  ),
                                ),
                              ),
                              onPressed:
                                  _changing
                                      ? null
                                      : status ==
                                              'accepted'
                                          ? _markArrived
                                          : status ==
                                                  'arrived'
                                              ? _startRide
                                              : status ==
                                                      'started'
                                                  ? _completeRide
                                                  : null,
                              child: Text(
                                status ==
                                        'accepted'
                                    ? 'وصلت للعميل'
                                    : status ==
                                            'arrived'
                                        ? 'بدء الرحلة'
                                        : 'إنهاء الرحلة',
                                style:
                                    const TextStyle(
                                  fontSize: 17,
                                  fontWeight:
                                      FontWeight
                                          .w900,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _driverRideMetric(
    String title,
    String value,
  ) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.black54,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            fontWeight:
                FontWeight.w900,
          ),
        ),
      ],
    );
  }

}

// ============================================================
// CHAT
// ============================================================

class RideChatPage extends StatefulWidget {
  final String rideId;
  final String senderRole;

  const RideChatPage({
    super.key,
    required this.rideId,
    required this.senderRole,
  });

  @override
  State<RideChatPage> createState() =>
      _RideChatPageState();
}

class _RideChatPageState
    extends State<RideChatPage> {
  final TextEditingController _controller =
      TextEditingController();

  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();

    if (text.isEmpty || _sending) return;

    setState(() {
      _sending = true;
    });

    try {
      final rideRef = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(widget.rideId);

      await rideRef
          .collection('messages')
          .add({
        'text': text,
        'senderRole':
            widget.senderRole,
        'createdAt':
            FieldValue
                .serverTimestamp(),
        'readByCustomer':
            widget.senderRole !=
                'driver',
        'readByDriver':
            widget.senderRole !=
                'customer',
      });

      final rideSnap = await rideRef.get();
      final rideData = rideSnap.data() ?? {};

      final targetRole =
          widget.senderRole == 'driver'
              ? 'customer'
              : 'driver';

      final targetId = widget.senderRole == 'driver'
          ? stringValue(
              rideData['customerId'],
            )
          : stringValue(
              rideData['driverId'],
            );

      if (targetId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('app_notifications')
            .add({
          'targetType': targetRole,
          'targetId': targetId,
          'type': 'message',
          'title': 'رسالة جديدة 💬',
          'body': text,
          'rideId': widget.rideId,
          'readBy': <String>[],
          'createdAt':
              FieldValue.serverTimestamp(),
        });

        await ExternalPushService.sendToUser(
          role: targetRole,
          userId: targetId,
          title: 'رسالة جديدة 💬',
          body: text,
          data: {
            'type': 'message',
            'rideId': widget.rideId,
          },
        );
      }

      _controller.clear();
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.amber,
          centerTitle: true,
          title: const Text(
            'الرسائل',
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('ride_requests')
                    .doc(widget.rideId)
                    .collection('messages')
                    .orderBy(
                      'createdAt',
                      descending: false,
                    )
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  final docs =
                      snapshot.data!.docs;

                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        'ابدأ المحادثة',
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: docs.length,
                    itemBuilder:
                        (context, index) {
                      final data = docs[index]
                              .data()
                          as Map<String, dynamic>;

                      final mine = stringValue(
                            data['senderRole'],
                          ) ==
                          widget.senderRole;

                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin:
                              const EdgeInsets.symmetric(
                            vertical: 4,
                          ),
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration:
                              BoxDecoration(
                            color: mine
                                ? Colors
                                    .amber.shade200
                                : Colors
                                    .grey.shade200,
                            borderRadius:
                                BorderRadius.circular(
                              16,
                            ),
                          ),
                          child: Text(
                            stringValue(
                              data['text'],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.white,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 4,
                        decoration:
                            const InputDecoration(
                          hintText: 'اكتب رسالة...',
                          border:
                              OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed:
                          _sending ? null : _sendMessage,
                      icon: const Icon(
                        Icons.send,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
