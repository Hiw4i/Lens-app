import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_preference_keys.dart';

part 'shared_preferences_provider.g.dart';

@Riverpod(keepAlive: true)
Future<SharedPreferencesWithCache> sharedPreferences(Ref ref) {
  return SharedPreferencesWithCache.create(
    cacheOptions: const SharedPreferencesWithCacheOptions(
      allowList: AppPreferenceKeys.all,
    ),
  );
}
