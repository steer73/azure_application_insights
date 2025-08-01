import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:azure_application_insights/src/connection_string.dart';
import 'package:azure_application_insights/src/context.dart';
import 'package:azure_application_insights/src/processing.dart';
import 'package:azure_application_insights/src/telemetry.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';

/// A [Processor] that stores telemetry locally when transmission fails and
/// attempts to resend stored telemetry when connectivity is available.
class OfflineStorageProcessor implements Processor {
  OfflineStorageProcessor({
    required String connectionString,
    required this.httpClient,
    required this.storageFilePath,
    required this.timeout,
    this.next,
    Logger? logger,
  })  : logger = logger ?? Logger('OfflineStorageProcessor'),
        _storageFile = File(storageFilePath),
        _outstandingFutures = <Future<void>>{} {
    _parsedConnectionString = parseConnectionString(connectionString);
    final ingestionEndpoint = _parsedConnectionString.getIngestionEndpoint();
    _ingestionEndpoint =
        ingestionEndpoint.replace(path: '${ingestionEndpoint.path}/v2/track');
  }

  @override
  final Processor? next;

  /// HTTP client used to submit telemetry.
  final Client httpClient;

  /// Path to the file used for offline storage.
  final String storageFilePath;

  /// How long to wait before timing out on telemetry submission.
  final Duration timeout;

  /// A [Logger] to which processing information will be written.
  final Logger logger;

  late final ConnectionString _parsedConnectionString;
  late final Uri _ingestionEndpoint;
  final File _storageFile;
  final Set<Future<void>> _outstandingFutures;
  bool _transmitting = false;

  @override
  void process({
    required List<ContextualTelemetryItem> contextualTelemetryItems,
  }) {
    for (final item in contextualTelemetryItems) {
      final serialized = _serializeTelemetryItem(contextualTelemetry: item);
      _storageFile.writeAsStringSync(
        jsonEncode(serialized) + '\n',
        mode: FileMode.append,
        flush: true,
      );
    }

    final future = _transmitStored();
    _outstandingFutures.add(future);
    future.whenComplete(() => _outstandingFutures.remove(future));

    next?.process(contextualTelemetryItems: contextualTelemetryItems);
  }

  @override
  Future<void> flush() async {
    final next = this.next;
    await _transmitStored();
    await Future.wait([
      ..._outstandingFutures,
      if (next != null) next.flush(),
    ]);
  }

  Future<void> _transmitStored() async {
    if (_transmitting) {
      return;
    }
    if (!_storageFile.existsSync()) {
      return;
    }
    final lines = _storageFile.readAsLinesSync();
    if (lines.isEmpty) {
      return;
    }

    _transmitting = true;
    try {
      final items = lines
          .where((l) => l.isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final encoded = jsonEncode(items);

      try {
        final response = await httpClient
            .post(_ingestionEndpoint, body: encoded)
            .timeout(timeout);
        final success = response.statusCode >= 200 && response.statusCode < 300;
        if (success) {
          _storageFile.writeAsStringSync('');
        } else {
          logger.severe('Failed to submit offline telemetry: ${response.statusCode}');
        }
      } on Object catch (e) {
        logger.warning('Failed to submit offline telemetry: $e');
      }
    } finally {
      _transmitting = false;
    }
  }

  Map<String, dynamic> _serializeTelemetryItem({
    required ContextualTelemetryItem contextualTelemetry,
  }) {
    final serializedTelemetry = contextualTelemetry.telemetryItem
        .serialize(context: contextualTelemetry.context);
    final contextProperties = contextualTelemetry.context.properties;
    final serializedContext =
        contextProperties.isEmpty ? null : contextProperties;
    return <String, dynamic>{
      'name': contextualTelemetry.telemetryItem.envelopeName,
      'time': contextualTelemetry.telemetryItem.timestamp.toIso8601String(),
      'iKey': _parsedConnectionString.instrumentationKey,
      'tags': <String, dynamic>{
        'ai.internal.sdkVersion': '1',
        if (serializedContext != null) ...serializedContext,
      },
      'data': serializedTelemetry,
    };
  }
}
