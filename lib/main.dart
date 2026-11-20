import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'utils/app_urls.dart';
import 'navigation.dart';

void main() => runApp(const MotoJaDriverApp());

abstract final class DriverColors {
  static const primary = Color(0xff59009a);
  static const primaryDark = Color(0xff7000b8);
  static const ink = Color(0xff101014);
  static const muted = Color(0xff747582);
  static const surfaceTint = Color(0xfff2e6ff);
  static const border = Color(0xffe4e4ec);
  static const success = Color(0xff1baf55);
  static const danger = Color(0xffe5484d);
}

ThemeData _driverTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: DriverColors.primary).copyWith(
    primary: DriverColors.primary,
    onPrimary: Colors.white,
    secondary: DriverColors.ink,
    onSecondary: Colors.white,
    surface: Colors.white,
    onSurface: DriverColors.ink,
    error: DriverColors.danger,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: DriverColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w800,
        color: DriverColors.ink,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: DriverColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: DriverColors.border,
        disabledForegroundColor: DriverColors.muted,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DriverColors.surfaceTint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: const TextStyle(
        color: DriverColors.muted,
        fontWeight: FontWeight.w500,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DriverColors.primary, width: 2),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: DriverColors.border,
      thickness: 1,
      space: 1,
    ),
  );
}

class MotoJaDriverApp extends StatelessWidget {
  const MotoJaDriverApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MotoJá Motorista',
    debugShowCheckedModeBanner: false,
    theme: _driverTheme(),
    home: const DriverHome(),
  );
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class DriverApi {
  DriverApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  static const String baseUrl = API_URL;
  static const _tokenKey = 'motoja_driver_api_token';
  static const _profileKey = 'motoja_driver_profile';
  static const _legacyStorage = FlutterSecureStorage();

  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedToken = prefs.getString(_tokenKey);
    if (cachedToken != null) return cachedToken;
    // Migrate sessions created by earlier app versions.
    final legacyToken = await _legacyStorage.read(key: _tokenKey);
    if (legacyToken != null) {
      await prefs.setString(_tokenKey, legacyToken);
      try {
        await _legacyStorage.delete(key: _tokenKey);
      } catch (_) {}
    }
    return legacyToken;
  }
  Future<void> saveToken(String token) async {
    await (await SharedPreferences.getInstance()).setString(_tokenKey, token);
    try {
      await _legacyStorage.delete(key: _tokenKey);
    } catch (_) {}
  }
  Future<Map<String, dynamic>?> readCachedProfile() async {
    final json = (await SharedPreferences.getInstance()).getString(_profileKey);
    if (json == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(json) as Map);
    } catch (_) {
      return null;
    }
  }
  Future<void> saveCachedProfile(Map<String, dynamic> profile) async {
    await (await SharedPreferences.getInstance()).setString(_profileKey, jsonEncode(profile));
  }
  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileKey);
    try {
      await _legacyStorage.delete(key: _tokenKey);
    } catch (_) {}
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, Object?> body = const {},
    bool authenticated = true,
  }) async {
    final uri = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/$'), '')}/$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (authenticated) {
      final token = await readToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (method != 'GET' && method != 'DELETE') req.body = jsonEncode(body);
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 20));
      final response = await http.Response.fromStream(streamed);
      final data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) await clearSession();
        final errors = data['errors'];
        final first = errors is Map && errors.isNotEmpty
            ? errors.values.first
            : null;
        final message = first is List && first.isNotEmpty
            ? first.first.toString()
            : data['message']?.toString() ??
                  'Pedido falhou (${response.statusCode}).';
        throw ApiException(
          _portugueseError(message, response.statusCode),
          statusCode: response.statusCode,
        );
      }
      return data;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Não foi possível ligar à API MotoJá. Verifica a ligação à internet e se o servidor está ativo.',
      );
    }
  }

  String _portugueseError(String message, int statusCode) {
    final normalized = message.trim().toLowerCase();
    const translations = <String, String>{
      'the phone or password is incorrect.':
          'O número de telefone ou a palavra-passe estão incorretos.',
      'this phone number already has an account.':
          'Este número de telefone já tem uma conta.',
      'driver account required.': 'É necessária uma conta de motorista.',
      'moto-taxi driver account required.':
          'É necessária uma conta de motorista de moto-táxi.',
      'ride is unavailable or driver is not available for this ride type.':
          'Este pedido já não está disponível ou o motorista não está disponível para este tipo de viagem.',
      'invalid ride status transition.':
          'Esta alteração do estado da viagem não é válida.',
      'unauthenticated.':
          'A sessão expirou ou não está autenticada. Inicia sessão novamente.',
      'the given data was invalid.':
          'Os dados enviados são inválidos. Confirma os campos e tenta novamente.',
      'this ride can no longer be cancelled.':
          'Esta viagem já não pode ser cancelada.',
      'only completed rides can be rated.':
          'Só podes avaliar viagens concluídas.',
    };
    final translation = translations[normalized];
    if (translation != null) return translation;

    if (RegExp(r'[áàâãéêíóôõúç]', caseSensitive: false).hasMatch(message) ||
        normalized.startsWith('o campo ') ||
        normalized.startsWith('este ') ||
        normalized.startsWith('esta ') ||
        normalized.startsWith('é ')) {
      return message;
    }

    return switch (statusCode) {
      401 => 'A sessão expirou ou as credenciais estão incorretas. Inicia sessão novamente.',
      403 => 'Não tens autorização para realizar esta ação.',
      404 => 'O recurso solicitado não foi encontrado.',
      409 => 'Este pedido já não pode ser concluído. Atualiza a lista e tenta novamente.',
      422 => 'Os dados enviados são inválidos. Confirma os campos e tenta novamente.',
      429 => 'Foram feitas demasiadas tentativas. Aguarda um pouco e tenta novamente.',
      >= 500 => 'O servidor encontrou um problema. Tenta novamente mais tarde.',
      _ => 'Não foi possível concluir o pedido. Tenta novamente.',
    };
  }
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final api = DriverApi();
  final routing = RoadRoutingService();
  final voice = VoiceGuidance();
  final phone = TextEditingController();
  final password = TextEditingController();
  Timer? poller;
  StreamSubscription<Position>? locationSubscription;
  DateTime? lastLocationUpload;
  Position? livePosition;
  bool sendingLocation = false;
  Map<String, dynamic>? user;
  Map<String, dynamic>? activeRide;
  Map<String, dynamic> summary = const {};
  List<Map<String, dynamic>> recentRides = [];
  List<Map<String, dynamic>> rides = [];
  RoadRoute? roadRoute;
  RouteInstruction? nextInstruction;
  double? instructionDistanceMeters;
  String? routedPhase;
  String? navigationError;
  int instructionIndex = 0;
  int announcedStage = 0;
  DateTime? lastRouteRequest;
  bool routeLoading = false,
      voiceGuidanceEnabled = false,
      destinationAnnounced = false;
  bool loading = true,
      working = false,
      available = false,
      obscure = true,
      polling = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    poller?.cancel();
    locationSubscription?.cancel();
    phone.dispose();
    password.dispose();
    unawaited(voice.stop());
    routing.dispose();
    api.client.close();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    try {
      if (await api.readToken() != null) {
        user = await api.readCachedProfile();
        final result = await api.request('GET', 'me');
        final profile = Map<String, dynamic>.from(result['user'] as Map);
        if (profile['role'] != 'driver')
          throw const ApiException(
            'Esta conta não está registada como motorista.',
          );
        if (profile['vehicle_type'] != 'moto')
          throw const ApiException(
            'A aplicação MotoJá Motorista aceita apenas contas de moto-táxi.',
          );
        user = profile;
        await api.saveCachedProfile(profile);
        await _refreshSummary();
        available = profile['is_available'] == true;
        final active = await api.request('GET', 'driver/rides/active');
        if (active['ride'] != null)
          activeRide = Map<String, dynamic>.from(active['ride'] as Map);
        if (activeRide != null) {
          _startLiveLocation();
          unawaited(_loadRoadRoute());
        } else if (available) {
          _startLiveLocation();
          _startPolling();
        }
      }
    } catch (e) {
      if (e is ApiException && e.statusCode == 401) {
        await api.clearSession();
        user = null;
      } else if (user == null) {
        error = e.toString();
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<Position> _position() async {
    if (!await Geolocator.isLocationServiceEnabled())
      throw const ApiException(
        'Ativa a localização do telemóvel para ficares disponível.',
      );
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const ApiException(
        'A permissão de localização é necessária para receber pedidos próximos.',
      );
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
  }

  Future<void> _refreshSummary() async {
    try {
      final result = await api.request('GET', 'driver/summary');
      if (!mounted) return;
      setState(() {
        summary = Map<String, dynamic>.from(
          result['today'] as Map? ?? const {},
        );
        recentRides = _rideList(result['recent_rides']);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _refreshDashboard() async {
    await _refreshSummary();
    if (activeRide != null) {
      try {
        final response = await api.request('GET', 'driver/rides/active');
        if (mounted && response['ride'] != null) {
          final updated = Map<String, dynamic>.from(response['ride'] as Map);
          final phaseChanged = _phaseFor(updated) != routedPhase;
          setState(() => activeRide = updated);
          if (phaseChanged) unawaited(_loadRoadRoute());
        }
      } on ApiException catch (e) {
        if (mounted) setState(() => error = e.toString());
      }
    } else if (available) {
      await _poll();
    }
  }

  Future<void> _openNavigation(Map<String, dynamic> ride) async {
    final useDestination = ride['status'] == 'in_progress';
    final lat =
        ride[useDestination ? 'destination_latitude' : 'pickup_latitude'];
    final lng =
        ride[useDestination ? 'destination_longitude' : 'pickup_longitude'];
    if (lat is! num || lng is! num) return;
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${lat.toString()},${lng.toString()}',
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      setState(
        () => error = 'Não foi possível abrir a aplicação de navegação.',
      );
    }
  }

  String _phaseFor(Map<String, dynamic> ride) =>
      ride['status'] == 'in_progress' ? 'destination' : 'pickup';

  Future<void> _loadRoadRoute() async {
    final ride = activeRide;
    if (ride == null || routeLoading) return;
    final phase = _phaseFor(ride);
    final targetLat =
        ride[phase == 'destination'
            ? 'destination_latitude'
            : 'pickup_latitude'];
    final targetLng =
        ride[phase == 'destination'
            ? 'destination_longitude'
            : 'pickup_longitude'];
    if (targetLat is! num || targetLng is! num) {
      setState(
        () => navigationError =
            'As coordenadas do destino não estão disponíveis.',
      );
      return;
    }

    setState(() {
      routeLoading = true;
      navigationError = null;
    });
    lastRouteRequest = DateTime.now();
    try {
      final position = livePosition ?? await _position();
      final route = await routing.route(
        origin: LatLng(position.latitude, position.longitude),
        destination: LatLng(targetLat.toDouble(), targetLng.toDouble()),
      );
      if (!mounted ||
          activeRide?['id'] != ride['id'] ||
          _phaseFor(activeRide!) != phase)
        return;
      setState(() {
        roadRoute = route;
        routedPhase = phase;
        instructionIndex = 0;
        announcedStage = 0;
        destinationAnnounced = false;
        nextInstruction = route.instructions.first;
        instructionDistanceMeters = _distanceTo(
          route.instructions.first.point,
          livePosition ?? position,
        );
      });
    } catch (e) {
      if (mounted) setState(() => navigationError = e.toString());
    } finally {
      if (mounted) {
        final phaseChanged =
            activeRide != null && _phaseFor(activeRide!) != phase;
        setState(() => routeLoading = false);
        if (phaseChanged) unawaited(_loadRoadRoute());
      }
    }
  }

  double _distanceTo(LatLng point, Position position) =>
      Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        point.latitude,
        point.longitude,
      );

  Future<void> _toggleVoiceGuidance() async {
    if (!voiceGuidanceEnabled) {
      if (roadRoute == null) {
        await _loadRoadRoute();
        if (roadRoute == null) return;
      }
      setState(() => voiceGuidanceEnabled = true);
      try {
        final instruction = nextInstruction;
        await voice.speak(
          instruction == null
              ? 'Navegacao por voz iniciada. Vou orientar o percurso.'
              : 'Navegacao por voz iniciada. Vou avisar antes de cada manobra.',
        );
      } catch (_) {
        if (mounted) {
          setState(() {
            voiceGuidanceEnabled = false;
            navigationError = 'A voz não está disponível neste dispositivo.';
          });
        }
      }
    } else {
      setState(() => voiceGuidanceEnabled = false);
      await voice.stop();
    }
  }

  void _processNavigation(Position position) {
    final route = roadRoute;
    if (route == null || routedPhase != _phaseFor(activeRide ?? {})) return;
    if (instructionIndex >= route.instructions.length) return;

    var instruction = route.instructions[instructionIndex];
    var distance = _distanceTo(instruction.point, position);
    if (distance < 35 && instruction.type != 'arrive') {
      if (voiceGuidanceEnabled && announcedStage < 2) {
        unawaited(_speak(instruction.voiceCue(distance, immediate: true)));
      }
      instructionIndex++;
      announcedStage = 0;
      if (instructionIndex >= route.instructions.length) return;
      instruction = route.instructions[instructionIndex];
      distance = _distanceTo(instruction.point, position);
    }

    if (instruction.type == 'arrive' && distance < 25) {
      if (!destinationAnnounced) {
        destinationAnnounced = true;
        if (voiceGuidanceEnabled) {
          unawaited(_speak(_arrivalCue(distance, immediate: true)));
        }
      }
    } else if (voiceGuidanceEnabled && distance <= 500 && announcedStage == 0) {
      announcedStage = 1;
      unawaited(
        _speak(
          instruction.type == 'arrive'
              ? _arrivalCue(distance, immediate: false)
              : instruction.voiceCue(distance, immediate: false),
        ),
      );
    } else if (voiceGuidanceEnabled && distance <= 110 && announcedStage == 1) {
      announcedStage = 2;
      unawaited(_speak(instruction.voiceCue(distance, immediate: true)));
    }

    if (mounted) {
      setState(() {
        nextInstruction = instruction;
        instructionDistanceMeters = distance;
      });
    }
    final lastRequest = lastRouteRequest;
    if (route.distanceTo(LatLng(position.latitude, position.longitude)) > 120 &&
        !routeLoading &&
        (lastRequest == null ||
            DateTime.now().difference(lastRequest) >
                const Duration(seconds: 18))) {
      unawaited(_loadRoadRoute());
    }
  }

  String _arrivalCue(double meters, {required bool immediate}) {
    final arrival = routedPhase == 'pickup'
        ? 'ao ponto de recolha'
        : 'ao destino';
    return immediate
        ? 'Chegou $arrival.'
        : 'Faltam ${formatDistance(meters)} para chegar $arrival.';
  }

  Future<void> _speak(String text) async {
    try {
      await voice.speak(text);
    } catch (_) {
      if (mounted) {
        setState(() {
          voiceGuidanceEnabled = false;
          navigationError = 'A voz não está disponível neste dispositivo.';
        });
      }
    }
  }

  Future<void> _callRider(Map<String, dynamic> ride) async {
    final phoneNumber = ride['rider']?['phone']?.toString();
    if (phoneNumber == null || phoneNumber.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (!await launchUrl(uri) && mounted) {
      setState(() => error = 'Não foi possível iniciar a chamada.');
    }
  }

  Future<void> _login() async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final result = await api.request(
        'POST',
        'auth/login',
        authenticated: false,
        body: {'phone': phone.text.trim(), 'password': password.text},
      );
      final profile = Map<String, dynamic>.from(result['user'] as Map);
      if (profile['role'] != 'driver')
        throw const ApiException(
          'Esta é uma conta de passageiro. Inicia sessão com uma conta de motorista.',
        );
      if (profile['vehicle_type'] != 'moto')
        throw const ApiException(
          'A aplicação MotoJá Motorista aceita apenas contas de moto-táxi.',
        );
      if (result['token'] is! String)
        throw const ApiException('A API não devolveu um token de acesso.');
      await api.saveToken(result['token'] as String);
      await api.saveCachedProfile(profile);
      await _refreshSummary();
      final active = await api.request('GET', 'driver/rides/active');
      if (!mounted) return;
      setState(() {
        user = profile;
        available = profile['is_available'] == true;
        activeRide = active['ride'] == null
            ? null
            : Map<String, dynamic>.from(active['ride'] as Map);
      });
      if (activeRide != null) {
        _startLiveLocation();
        unawaited(_loadRoadRoute());
      } else if (available) {
        _startLiveLocation();
        _startPolling();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _setAvailability(bool value) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      Map<String, Object?> payload = {'is_available': value};
      if (value) {
        final pos = await _position();
        payload.addAll({'latitude': pos.latitude, 'longitude': pos.longitude});
        await api.request(
          'PUT',
          'driver/location',
          body: {'latitude': pos.latitude, 'longitude': pos.longitude},
        );
      }
      final result = await api.request(
        'POST',
        'driver/availability',
        body: payload,
      );
      if (!mounted) return;
      setState(() {
        available = value;
        user?['is_available'] = value;
        rides = value ? _rideList(result['rides']) : [];
      });
      if (value) {
        _startLiveLocation();
        if (activeRide == null) _startPolling();
      } else {
        poller?.cancel();
        locationSubscription?.cancel();
        locationSubscription = null;
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  List<Map<String, dynamic>> _rideList(dynamic value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : [];

  void _startPolling() {
    poller?.cancel();
    poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    _poll();
  }

  void _startLiveLocation() {
    locationSubscription?.cancel();
    _position()
        .then((position) {
          if (!mounted || (!available && activeRide == null)) return;
          _handleLivePosition(position);
          locationSubscription =
              Geolocator.getPositionStream(
                locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.high,
                  distanceFilter: 2,
                ),
              ).listen(
                _handleLivePosition,
                onError: (Object error) {
                  if (mounted)
                    setState(
                      () => this.error =
                          'A localização em tempo real foi interrompida: $error',
                    );
                },
              );
        })
        .catchError((Object error) {
          if (mounted) setState(() => this.error = error.toString());
        });
  }

  void _handleLivePosition(Position position) {
    if (!mounted || (!available && activeRide == null)) return;
    setState(() => livePosition = position);
    _processNavigation(position);
    final now = DateTime.now();
    if (sendingLocation ||
        (lastLocationUpload != null &&
            now.difference(lastLocationUpload!) < const Duration(seconds: 2)))
      return;
    sendingLocation = true;
    lastLocationUpload = now;
    api
        .request(
          'PUT',
          'driver/location',
          body: {
            'latitude': position.latitude,
            'longitude': position.longitude,
          },
        )
        .catchError((Object error) {
          if (mounted) setState(() => this.error = error.toString());
          return <String, dynamic>{};
        })
        .whenComplete(() => sendingLocation = false);
  }

  Future<void> _poll() async {
    if (!available || activeRide != null || working || polling || !mounted)
      return;
    polling = true;
    try {
      final before = rides.map((ride) => ride['id'].toString()).toSet();
      final pos = livePosition ?? await _position();
      await api.request(
        'PUT',
        'driver/location',
        body: {'latitude': pos.latitude, 'longitude': pos.longitude},
      );
      final result = await api.request(
        'POST',
        'driver/availability',
        body: {
          'is_available': true,
          'latitude': pos.latitude,
          'longitude': pos.longitude,
        },
      );
      final updated = _rideList(result['rides']);
      final hasNewRide = updated.any(
        (ride) => !before.contains(ride['id'].toString()),
      );
      if (mounted) {
        setState(() {
          rides = updated;
          error = null;
        });
        if (hasNewRide) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Novo pedido de viagem dispon?vel')),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      polling = false;
    }
  }

  Future<void> _accept(Map<String, dynamic> ride) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final result = await api.request(
        'POST',
        'driver/rides/${ride['id']}/accept',
      );
      if (!mounted) return;
      poller?.cancel();
      setState(() {
        activeRide = Map<String, dynamic>.from(result['ride'] as Map);
        rides = [];
        available = false;
      });
      _startLiveLocation();
      unawaited(_loadRoadRoute());
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          rides.removeWhere((r) => r['id'] == ride['id']);
        });
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _advanceRide(String status) async {
    final ride = activeRide;
    if (ride == null) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      final result = await api.request(
        'POST',
        'driver/rides/${ride['id']}/status',
        body: {'status': status},
      );
      if (!mounted) return;
      final updated = Map<String, dynamic>.from(result['ride'] as Map);
      setState(() {
        if (status == 'completed') {
          activeRide = null;
          available = true;
          user?['is_available'] = true;
          roadRoute = null;
          routedPhase = null;
          nextInstruction = null;
          voiceGuidanceEnabled = false;
          destinationAnnounced = false;
        } else {
          activeRide = updated;
        }
      });
      if (status == 'completed') {
        await voice.stop();
      } else if (status == 'in_progress') {
        unawaited(_loadRoadRoute());
      }
      if (status == 'completed') {
        await _refreshSummary();
        _startPolling();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _logout() async {
    poller?.cancel();
    locationSubscription?.cancel();
    locationSubscription = null;
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (available && activeRide == null)
        await api.request(
          'POST',
          'driver/availability',
          body: {'is_available': false},
        );
      await api.request('DELETE', 'auth/session');
    } catch (_) {}
    await api.clearSession();
    if (mounted)
      setState(() {
        user = null;
        activeRide = null;
        rides = [];
        available = false;
        working = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return user == null ? _loginScreen() : _driverScreen();
  }

  Widget _loginScreen() => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.two_wheeler,
                  size: 68,
                  color: DriverColors.primary,
                ),
                const SizedBox(height: 18),
                Text(
                  'MotoJá Motorista',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Entra com a tua conta de motorista MotoJá.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Número de telefone',
                    prefixIcon: Icon(Icons.phone),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: password,
                  obscureText: obscure,
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: 'Palavra-passe',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: obscure
                          ? 'Mostrar palavra-passe'
                          : 'Ocultar palavra-passe',
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
                if (error != null) _errorBanner(error!),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: working ? null : _login,
                  icon: working
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: const Text('Iniciar sessão'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _driverScreen() {
    final ride = activeRide;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MotoJá Motorista'),
        actions: [
          IconButton(
            tooltip: 'Terminar sessão',
            onPressed: working ? null : _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshDashboard,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Olá, ${user?['name'] ?? 'Motorista'}',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_vehicle()}  •  ${user?['vehicle_model'] ?? 'Modelo não indicado'}  •  ${user?['vehicle_plate'] ?? 'Matrícula não indicada'}',
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 12,
                          color: available
                              ? DriverColors.success
                              : DriverColors.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          available
                              ? 'Disponível · a receber pedidos'
                              : ride == null
                              ? 'Desligado'
                              : 'Em viagem',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        if (ride == null)
                          Switch(
                            value: available,
                            onChanged: working ? null : _setAvailability,
                          ),
                      ],
                    ),
                    if (ride == null)
                      Text(
                        available
                            ? 'A tua localização é partilhada enquanto estiveres disponível.'
                            : 'Fica disponível para receber pedidos de moto-táxi próximos.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
            _summaryCard(),
            if (error != null) _errorBanner(error!),
            if (ride != null) _activeRideCard(ride),
            if (ride == null) ...[
              if (available && rides.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 14, 4, 8),
                  child: Text(
                    'Pedidos no mapa',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _RequestsMap(rides: rides, position: livePosition),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Pedidos próximos',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (available)
                      IconButton(
                        onPressed: _poll,
                        tooltip: 'Actualizar pedidos',
                        icon: const Icon(Icons.refresh),
                      ),
                  ],
                ),
              ),
              if (!available)
                const _EmptyCard(
                  icon: Icons.power_settings_new,
                  title: 'Estás indisponível',
                  message: 'Ativa a disponibilidade quando estiveres pronto para aceitar pedidos.',
                ),
              if (available && rides.isEmpty)
                const _EmptyCard(
                  icon: Icons.search,
                  title: 'À procura de pedidos',
                  message:
                      'Os pedidos próximos são atualizados a cada 2 segundos.',
                ),
              ...rides.map(_rideCard),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryCard() {
    final total = (summary['gross_fare_kz'] as num?)?.round() ?? 0;
    final count = (summary['completed_rides'] as num?)?.toInt() ?? 0;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resumo de hoje',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _SummaryMetric(
                    icon: Icons.payments_outlined,
                    label: 'Tarifas brutas',
                    value: _money(total),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SummaryMetric(
                    icon: Icons.two_wheeler,
                    label: 'Viagens concluídas',
                    value: '$count',
                  ),
                ),
              ],
            ),
            if (recentRides.isNotEmpty) ...[
              const Divider(height: 26),
              const Text(
                'Viagens recentes',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              ...recentRides.map(
                (ride) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.check_circle_outline,
                    color: DriverColors.success,
                  ),
                  title: Text(
                    '${ride['pickup_name'] ?? 'Recolha'} → ${ride['destination_name'] ?? 'Destino'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${ride['rider_name'] ?? 'Passageiro'} · ${_dateTime(ride['completed_at'])}',
                  ),
                  trailing: Text(
                    _money(ride['fare_kz']),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Valores brutos das viagens concluídas; não incluem comissões nem pagamentos.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _dateTime(dynamic raw) {
    final date = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
    if (date == null) return 'Concluída';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _rideCard(Map<String, dynamic> ride) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ride['rider']?['name']?.toString() ?? 'Passageiro MotoJá',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(_money(ride['fare_kz'])),
            ],
          ),
          const Divider(height: 24),
          _routeLine(
            Icons.radio_button_checked,
            ride['pickup_name']?.toString() ?? _coordinates(ride, true),
          ),
          const SizedBox(height: 10),
          _routeLine(
            Icons.location_on_outlined,
            ride['destination_name']?.toString() ?? _coordinates(ride, false),
          ),
          const SizedBox(height: 12),
          Text(
            '${_distance(ride['distance_meters'])} de viagem  ·  ${ride['duration_seconds'] == null ? '—' : '${((ride['duration_seconds'] as num) / 60).round()} min estimados'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: working ? null : () => _accept(ride),
            child: const Text('Aceitar pedido'),
          ),
        ],
      ),
    ),
  );

  Widget _activeRideCard(Map<String, dynamic> ride) {
    final status = ride['status']?.toString() ?? 'accepted';
    final next = switch (status) {
      'accepted' => 'driver_arrived',
      'driver_arrived' => 'in_progress',
      'in_progress' => 'completed',
      _ => '',
    };
    final label = switch (next) {
      'driver_arrived' => 'Cheguei ao ponto de recolha',
      'in_progress' => 'Iniciar viagem',
      'completed' => 'Concluir viagem',
      _ => 'Viagem concluída',
    };
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.navigation, color: DriverColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Viagem ativa · ${_status(status)}',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(_money(ride['fare_kz'])),
              ],
            ),
            const SizedBox(height: 14),
            _LiveDriverMap(
              ride: ride,
              position: livePosition,
              route: roadRoute,
              instruction: nextInstruction,
              instructionDistanceMeters: instructionDistanceMeters,
              routeLoading: routeLoading,
              voiceGuidanceEnabled: voiceGuidanceEnabled,
            ),
            if (navigationError != null) ...[
              const SizedBox(height: 6),
              Text(
                navigationError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              status == 'in_progress'
                  ? 'Segue o mapa até ao destino.'
                  : 'Segue o mapa até ao ponto de recolha.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Divider(height: 24),
            Text(
              'Passageiro: ${ride['rider']?['name'] ?? 'Passageiro MotoJá'}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (ride['rider']?['phone'] != null)
              Text('Telefone: ${ride['rider']['phone']}'),
            const SizedBox(height: 14),
            _routeLine(
              Icons.radio_button_checked,
              ride['pickup_name']?.toString() ?? _coordinates(ride, true),
            ),
            const SizedBox(height: 10),
            _routeLine(
              Icons.location_on_outlined,
              ride['destination_name']?.toString() ?? _coordinates(ride, false),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: routeLoading ? null : _toggleVoiceGuidance,
                    icon: Icon(
                      voiceGuidanceEnabled
                          ? Icons.volume_off
                          : Icons.navigation,
                    ),
                    label: Text(
                      voiceGuidanceEnabled ? 'Parar voz' : 'Iniciar navegação',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Abrir no Google Maps',
                  onPressed: () => _openNavigation(ride),
                  icon: const Icon(Icons.map_outlined),
                ),
                if (ride['rider']?['phone'] != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _callRider(ride),
                      icon: const Icon(Icons.call),
                      label: const Text('Ligar'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: working || next.isEmpty
                  ? null
                  : () => _advanceRide(next),
              icon: const Icon(Icons.check),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routeLine(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 19),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
  Widget _errorBanner(String text) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: DriverColors.danger.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: const TextStyle(color: DriverColors.danger)),
  );
  String _vehicle() => 'Moto-táxi';
  String _status(String value) => switch (value) {
    'accepted' => 'aceite',
    'driver_arrived' => 'motorista chegou',
    'in_progress' => 'em curso',
    'completed' => 'concluída',
    _ => value.replaceAll('_', ' '),
  };
  String _money(dynamic value) =>
      value == null ? 'Indisponível' : 'Kz ${(value as num).round()}';
  String _distance(dynamic value) => value == null
      ? 'Distância indisponível'
      : '${((value as num) / 1000).toStringAsFixed(1)} km';
  String _coordinates(Map<String, dynamic> ride, bool pickup) {
    final lat = ride[pickup ? 'pickup_latitude' : 'destination_latitude'];
    final lng = ride[pickup ? 'pickup_longitude' : 'destination_longitude'];
    return lat == null || lng == null
        ? 'Localização indisponível'
        : '${(lat as num).toStringAsFixed(5)}, ${(lng as num).toStringAsFixed(5)}';
  }
}

class _RequestsMap extends StatelessWidget {
  const _RequestsMap({required this.rides, required this.position});
  final List<Map<String, dynamic>> rides;
  final Position? position;

  @override
  Widget build(BuildContext context) {
    final first = rides.first;
    final center = position != null
        ? LatLng(position!.latitude, position!.longitude)
        : LatLng(
            (first['pickup_latitude'] as num).toDouble(),
            (first['pickup_longitude'] as num).toDouble(),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 190,
        child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 12),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.motoja.driver',
            ),
            MarkerLayer(
              markers: [
                ...rides
                    .where(
                      (ride) =>
                          ride['pickup_latitude'] is num &&
                          ride['pickup_longitude'] is num,
                    )
                    .map(
                      (ride) => Marker(
                        point: LatLng(
                          (ride['pickup_latitude'] as num).toDouble(),
                          (ride['pickup_longitude'] as num).toDouble(),
                        ),
                        width: 44,
                        height: 44,
                        child: const _MapPin(
                          icon: Icons.person_pin_circle,
                          color: DriverColors.primary,
                        ),
                      ),
                    ),
                if (position != null)
                  Marker(
                    point: LatLng(position!.latitude, position!.longitude),
                    width: 46,
                    height: 46,
                    child: const _MapPin(
                      icon: Icons.two_wheeler,
                      color: DriverColors.ink,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveDriverMap extends StatefulWidget {
  const _LiveDriverMap({
    required this.ride,
    required this.position,
    required this.route,
    required this.instruction,
    required this.instructionDistanceMeters,
    required this.routeLoading,
    required this.voiceGuidanceEnabled,
  });

  final Map<String, dynamic> ride;
  final Position? position;
  final RoadRoute? route;
  final RouteInstruction? instruction;
  final double? instructionDistanceMeters;
  final bool routeLoading;
  final bool voiceGuidanceEnabled;

  @override
  State<_LiveDriverMap> createState() => _LiveDriverMapState();
}

class _LiveDriverMapState extends State<_LiveDriverMap> {
  final MapController _controller = MapController();
  bool _ready = false;

  LatLng _point(
    String latKey,
    String lngKey, [
    LatLng fallback = const LatLng(-8.8185, 13.2354),
  ]) {
    final latitude = widget.ride[latKey];
    final longitude = widget.ride[lngKey];
    if (latitude is num && longitude is num)
      return LatLng(latitude.toDouble(), longitude.toDouble());
    return fallback;
  }

  LatLng get _pickup => _point('pickup_latitude', 'pickup_longitude');
  LatLng get _destination =>
      _point('destination_latitude', 'destination_longitude');
  LatLng get _driver {
    final live = widget.position;
    if (live != null) return LatLng(live.latitude, live.longitude);
    final driver = widget.ride['driver'];
    if (driver is Map &&
        driver['latitude'] is num &&
        driver['longitude'] is num) {
      return LatLng(
        (driver['latitude'] as num).toDouble(),
        (driver['longitude'] as num).toDouble(),
      );
    }
    return _pickup;
  }

  void _fitRoute() {
    final points = widget.route?.points;
    if (points == null || points.length < 2) return;
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(34),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _LiveDriverMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (oldWidget.route != widget.route && widget.route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ready) _fitRoute();
      });
    } else if (oldWidget.position != widget.position) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ready) _controller.move(_driver, 15);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: SizedBox(
      height: 290,
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter: _driver,
          initialZoom: 14,
          minZoom: 4,
          maxZoom: 19,
          onMapReady: () {
            _ready = true;
            if (widget.route != null) {
              _fitRoute();
            } else {
              _controller.move(_driver, 14);
            }
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.motoja.driver',
            maxNativeZoom: 19,
          ),
          if (widget.route != null)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: widget.route!.points,
                  strokeWidth: 6,
                  color: DriverColors.primary,
                ),
              ],
            ),
          MarkerLayer(
            markers: [
              Marker(
                point: _pickup,
                width: 52,
                height: 52,
                child: const _MapPin(
                  icon: Icons.person_pin_circle,
                  color: DriverColors.primary,
                ),
              ),
              Marker(
                point: _destination,
                width: 48,
                height: 48,
                child: const _MapPin(
                  icon: Icons.location_on,
                  color: DriverColors.ink,
                ),
              ),
              Marker(
                point: _driver,
                width: 54,
                height: 54,
                child: const _MapPin(
                  icon: Icons.two_wheeler,
                  color: DriverColors.primary,
                ),
              ),
            ],
          ),
          Positioned(
            left: 10,
            top: 10,
            right: 58,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 6),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: widget.instruction != null && !widget.routeLoading
                    ? Row(
                        children: [
                          Icon(
                            _instructionIcon(widget.instruction!.modifier),
                            color: DriverColors.primary,
                            size: 27,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.instruction!.type == 'arrive' &&
                                          widget.ride['status'] != 'in_progress'
                                      ? 'Chegou ao ponto de recolha'
                                      : widget.instruction!.action,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (widget.instructionDistanceMeters != null)
                                  Text(
                                    'Em ${formatDistance(widget.instructionDistanceMeters!)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: DriverColors.muted,
                                    ),
                                  ),
                                Text(
                                  widget.voiceGuidanceEnabled
                                      ? 'Orientação por voz ativa'
                                      : 'Próxima manobra',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: DriverColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.routeLoading ? Icons.route : Icons.circle,
                            size: 10,
                            color: DriverColors.success,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.routeLoading
                                  ? 'A calcular rota rodoviária...'
                                  : widget.route == null
                                  ? 'Rota indisponível; abre o Google Maps'
                                  : 'Rota ${formatDistance(widget.route!.distanceMeters)} - ${(widget.route!.durationSeconds / 60).ceil()} min',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 10,
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              elevation: 2,
              child: IconButton(
                tooltip: 'Centrar no motorista',
                onPressed: () => _controller.move(_driver, 15),
                icon: const Icon(
                  Icons.my_location,
                  color: DriverColors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

IconData _instructionIcon(String modifier) => switch (modifier) {
  'left' || 'slight left' || 'sharp left' => Icons.turn_left,
  'right' || 'slight right' || 'sharp right' => Icons.turn_right,
  'uturn' => Icons.u_turn_left,
  _ => Icons.straight,
};

class _MapPin extends StatelessWidget {
  const _MapPin({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [
        BoxShadow(color: Colors.black26, blurRadius: 7, offset: Offset(0, 2)),
      ],
    ),
    child: Icon(icon, color: Colors.white, size: 25),
  );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title, message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(26),
      child: Column(
        children: [
          Icon(icon, size: 38, color: Colors.grey),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: DriverColors.surfaceTint,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: DriverColors.primary),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 3),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}
