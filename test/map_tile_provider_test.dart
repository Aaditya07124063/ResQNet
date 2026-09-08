// Tests for lib/core/services/map/map_tile_provider.dart (item 3 of the
// FINAL GAP CLOSURE requirements: provider selection and missing-
// configuration behavior). Exercises resolveMapTileProviderFrom (the
// @visibleForTesting decision function resolveMapTileProvider delegates
// to) rather than resolveMapTileProvider itself, since the latter reads
// real compile-time --dart-define values this test binary was not built
// with.
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/services/map/map_tile_provider.dart';

void main() {
  group('missing configuration (no RESQNET_TILE_URL_TEMPLATE)', () {
    test('falls back to OpenStreetMapDirectProvider — never crashes, never fabricates a URL', () {
      final provider = resolveMapTileProviderFrom(
        urlTemplate: '',
        apiKey: '',
        attribution: 'Map data providers',
        attributionUrl: '',
      );
      expect(provider, isA<OpenStreetMapDirectProvider>());
      expect(provider.urlTemplate, 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
      expect(provider.isProductionReady, false);
    });

    test('an empty url template is treated as absent even if other config values are non-empty', () {
      final provider = resolveMapTileProviderFrom(
        urlTemplate: '',
        apiKey: 'some-key',
        attribution: 'Someone',
        attributionUrl: 'https://example.com',
      );
      expect(provider, isA<OpenStreetMapDirectProvider>());
    });
  });

  group('configured provider (RESQNET_TILE_URL_TEMPLATE present)', () {
    test('a real configured provider is used and marked production-ready', () {
      final provider = resolveMapTileProviderFrom(
        urlTemplate: 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key={key}',
        apiKey: 'real-key-123',
        attribution: 'MapTiler / OpenStreetMap contributors',
        attributionUrl: 'https://www.maptiler.com/copyright/',
      );
      expect(provider, isA<ConfiguredTileProvider>());
      expect(provider.isProductionReady, true);
      expect(provider.urlTemplate, 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key=real-key-123');
      expect(provider.attributionText, 'MapTiler / OpenStreetMap contributors');
      expect(provider.attributionUrl, 'https://www.maptiler.com/copyright/');
    });

    test('a url template with no {key} placeholder is used as-is when an api key is supplied', () {
      final provider = resolveMapTileProviderFrom(
        urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.png',
        apiKey: 'unused-key',
        attribution: 'Example',
        attributionUrl: '',
      );
      expect(provider.urlTemplate, 'https://tiles.example.com/{z}/{x}/{y}.png');
    });

    test('an empty api key leaves the url template unchanged (no {key} substitution attempted)', () {
      final provider = resolveMapTileProviderFrom(
        urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.png?key={key}',
        apiKey: '',
        attribution: 'Example',
        attributionUrl: '',
      );
      expect(provider.urlTemplate, 'https://tiles.example.com/{z}/{x}/{y}.png?key={key}');
    });
  });

  group('OpenStreetMapDirectProvider', () {
    test('is explicitly marked not production-ready, with real attribution', () {
      const provider = OpenStreetMapDirectProvider();
      expect(provider.isProductionReady, false);
      expect(provider.attributionText, isNotEmpty);
      expect(provider.attributionUrl, isNotEmpty);
    });
  });
}
