import 'dart:io';

import 'package:azure_application_insights/azure_application_insights.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group('OfflineStorageProcessor', () {
    late Directory tempDir;
    late File storageFile;
    late MockClient httpClient;
    late OfflineStorageProcessor sut;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync();
      storageFile = File('${tempDir.path}/telemetry.txt');
      httpClient = MockClient();
      sut = OfflineStorageProcessor(
        connectionString: 'InstrumentationKey=key',
        httpClient: httpClient,
        storageFilePath: storageFile.path,
        timeout: const Duration(seconds: 10),
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('process stores telemetry to file', () {
      sut.process(
        contextualTelemetryItems: [
          ContextualTelemetryItem(
            telemetryItem: EventTelemetryItem(
              name: 'anything',
              timestamp: DateTime.utc(2020, 10, 26),
            ),
            context: TelemetryContext(),
          ),
        ],
      );

      final lines = storageFile.readAsLinesSync();
      expect(lines, hasLength(1));
      expect(lines.first.contains('AppEvents'), isTrue);
    });

    test('flush transmits stored telemetry and clears file on success', () async {
      when(httpClient.post(any, body: anyNamed('body')))
          .thenAnswer((_) async => Response('', 200));

      sut.process(
        contextualTelemetryItems: [
          ContextualTelemetryItem(
            telemetryItem: EventTelemetryItem(
              name: 'anything',
              timestamp: DateTime.utc(2020, 10, 26),
            ),
            context: TelemetryContext(),
          ),
        ],
      );

      await sut.flush();

      expect(storageFile.readAsStringSync(), isEmpty);
    });

    test('flush retains file when transmission fails', () async {
      when(httpClient.post(any, body: anyNamed('body')))
          .thenAnswer((_) async => Response('', 500));

      sut.process(
        contextualTelemetryItems: [
          ContextualTelemetryItem(
            telemetryItem: EventTelemetryItem(name: 'anything'),
            context: TelemetryContext(),
          ),
        ],
      );

      final before = storageFile.readAsStringSync();
      await sut.flush();
      final after = storageFile.readAsStringSync();
      expect(after, before);
    });
  });
}
