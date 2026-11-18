import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/src/app/shared_prefs_store.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'preferences adapter preserves typed values and removes saved keys',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = SharedPreferencesKeyValueStore(preferences);
      await store.writeString('title', 'Montréal 🦙');
      await store.writeInt('count', 7);
      await store.writeDouble('temperature', 0.25);
      await store.writeBool('enabled', true);
      expect(preferences.getString('title'), 'Montréal 🦙');
      expect(preferences.getInt('count'), 7);
      expect(preferences.getDouble('temperature'), 0.25);
      expect(preferences.getBool('enabled'), isTrue);
      final reader = SharedPreferencesKeyValueStore(preferences);
      expect(await reader.readString('title'), 'Montréal 🦙');
      expect(await reader.readInt('count'), 7);
      expect(await reader.readDouble('temperature'), 0.25);
      expect(await reader.readBool('enabled'), isTrue);
      await reader.remove('title');
      expect(await store.readString('title'), isNull);
      expect(preferences.containsKey('title'), isFalse);
    },
  );

  test(
    'shell settings survive rebuilding their production preferences adapter',
    () async {
      SharedPreferences.setMockInitialValues({
        'studio.settings.v1': jsonEncode(
          const StudioSettings(
            temperature: 0.6,
            maxTokens: 123,
            autoLoadLastModel: false,
          ).toJson(),
        ),
      });
      final preferences = await SharedPreferences.getInstance();
      final first = StudioShellController(
        keyValueStore: SharedPreferencesKeyValueStore(preferences),
      );
      final second = StudioShellController(
        keyValueStore: SharedPreferencesKeyValueStore(preferences),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.initialize();
      expect(first.currentSettings.maxTokens, 123);
      await first.updateSettings(
        (settings) => settings.copyWith(temperature: 0.2),
      );
      final saved =
          jsonDecode(preferences.getString('studio.settings.v1')!) as Map;
      expect(saved['temperature'], 0.2);
      await second.initialize();
      expect(second.currentSettings.temperature, 0.2);
      expect(second.currentSettings.maxTokens, 123);
      expect(second.currentSettings.autoLoadLastModel, isFalse);
    },
  );
}
