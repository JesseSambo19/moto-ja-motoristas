import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'utils/app_urls.dart';

class RoadRoute {
  const RoadRoute({
    required this.points,
    required this.instructions,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final List<RouteInstruction> instructions;
  final double distanceMeters;
  final double durationSeconds;

  factory RoadRoute.fromOsrm(Map<String, dynamic> json) {
    final routes = json['routes'];
    if (json['code'] != 'Ok' || routes is! List || routes.isEmpty) {
      throw const RouteException('Não foi encontrada uma rota rodoviária para estes pontos.');
    }
    final route = Map<String, dynamic>.from(routes.first as Map);
    final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
    final coordinates = geometry['coordinates'] as List;
    final points = coordinates
        .whereType<List>()
        .where((pair) => pair.length >= 2 && pair[0] is num && pair[1] is num)
        .map(
          (pair) =>
              LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble()),
        )
        .toList(growable: false);

    final instructions = <RouteInstruction>[];
    final legs = route['legs'];
    if (legs is List) {
      for (final leg in legs.whereType<Map>()) {
        final steps = leg['steps'];
        if (steps is List) {
          for (final step in steps.whereType<Map>()) {
            final instruction = RouteInstruction.fromOsrm(
              Map<String, dynamic>.from(step),
            );
            if (instruction.type != 'depart') instructions.add(instruction);
          }
        }
      }
    }
    if (points.length < 2 || instructions.isEmpty) {
      throw const RouteException(
        'O serviço de navegação devolveu uma rota incompleta.',
      );
    }
    return RoadRoute(
      points: points,
      instructions: instructions,
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
    );
  }

  double distanceTo(LatLng position) {
    var nearest = double.infinity;
    for (final point in points) {
      final distance = const Distance().as(LengthUnit.Meter, position, point);
      if (distance < nearest) nearest = distance;
    }
    return nearest;
  }
}

class RouteInstruction {
  const RouteInstruction({
    required this.type,
    required this.modifier,
    required this.point,
    required this.roadName,
    required this.exit,
  });

  final String type;
  final String modifier;
  final LatLng point;
  final String roadName;
  final int? exit;

  factory RouteInstruction.fromOsrm(Map<String, dynamic> step) {
    final maneuver = Map<String, dynamic>.from(step['maneuver'] as Map);
    final location = maneuver['location'] as List;
    final rawExit = maneuver['exit'];
    return RouteInstruction(
      type: maneuver['type']?.toString() ?? 'continue',
      modifier: maneuver['modifier']?.toString() ?? 'straight',
      point: LatLng(
        (location[1] as num).toDouble(),
        (location[0] as num).toDouble(),
      ),
      roadName: step['name']?.toString() ?? '',
      exit: rawExit is num ? rawExit.toInt() : null,
    );
  }

  String get action {
    if (type == 'arrive') return 'Chegou ao destino';
    final direction = switch (modifier) {
      'sharp left' => 'fortemente \u00e0 esquerda',
      'slight left' => 'ligeiramente \u00e0 esquerda',
      'left' => '\u00e0 esquerda',
      'sharp right' => 'fortemente \u00e0 direita',
      'slight right' => 'ligeiramente \u00e0 direita',
      'right' => '\u00e0 direita',
      'uturn' => 'fa\u00e7a invers\u00e3o de marcha',
      _ => 'em frente',
    };
    final verb = switch (type) {
      'roundabout' || 'rotary' =>
        exit == null
            ? 'Na rotunda, saia'
            : 'Na rotunda, saia na $exit\u00aa sa\u00edda',
      'exit roundabout' || 'exit rotary' => 'Saia da rotunda',
      'merge' => 'Entre',
      'on ramp' => 'Entre na rampa',
      'off ramp' => 'Saia na rampa',
      'fork' => 'Na bifurca\u00e7\u00e3o, siga',
      'end of road' => 'No fim da estrada, vire',
      'continue' || 'new name' => 'Continue',
      _ => 'Vire',
    };
    final directionText = type == 'continue' || type == 'new name'
        ? ''
        : ' $direction';
    final road = roadName.isEmpty ? '' : ' para $roadName';
    return '$verb$directionText$road';
  }

  String voiceCue(double meters, {required bool immediate}) {
    if (type == 'arrive') {
      if (immediate) return 'Chegou ao destino.';
      return 'Dentro de ${formatDistance(meters)}, chegar\u00e1 ao destino.';
    }
    final prefix = immediate
        ? 'Agora, '
        : 'Dentro de ${formatDistance(meters)}, ';
    return '$prefix${action.toLowerCase()}.';
  }
}

String formatDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} quil\u00f3metros'
    : '${meters.round()} metros';

class RouteException implements Exception {
  const RouteException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RoadRoutingService {
  RoadRoutingService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<RoadRoute> route({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final base = Uri.parse(ROUTING_URL);
    final coordinates =
        '${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}';
    final uri = base.replace(
      path:
          '${base.path.replaceFirst(RegExp(r'/$'), '')}/route/v1/driving/$coordinates',
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
        'alternatives': 'false',
      },
    );
    try {
      final response = await _client
          .get(uri, headers: const {'User-Agent': 'MotoJaMotorista/1.0'})
          .timeout(const Duration(seconds: 18));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RouteException(
          'O serviço de navegação devolveu um erro (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const RouteException(
          'O serviço de navegação devolveu dados inválidos.',
        );
      }
      return RoadRoute.fromOsrm(decoded);
    } on RouteException {
      rethrow;
    } catch (_) {
      throw const RouteException(
        'Não foi possível obter uma rota rodoviária. Verifica a ligação à internet e tenta novamente.',
      );
    }
  }

  void dispose() => _client.close();
}

class VoiceGuidance {
  static const _channel = MethodChannel('com.motoja.driver/voice-guidance');

  Future<void> speak(String text) async {
    await _channel.invokeMethod<bool>('speak', {'text': text});
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // The platform may not provide native speech (e.g. a web preview).
    }
  }
}
