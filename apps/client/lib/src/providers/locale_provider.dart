import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'locale_provider.g.dart';

/// SharedPreferences key used to persist the selected locale tag.
const kLocaleKey = 'app.locale';

/// Locales supported by Echo. Display names are in each language's own script.
/// RTL locales (Arabic, Hebrew, etc.) are deferred until RTL layout testing
/// is complete — tracked separately.
const kSupportedLocales = <LocaleEntry>[
  LocaleEntry(tag: 'en', displayName: 'English'),
  LocaleEntry(tag: 'es', displayName: 'Español'),
  LocaleEntry(tag: 'fr', displayName: 'Français'),
  LocaleEntry(tag: 'de', displayName: 'Deutsch'),
  LocaleEntry(tag: 'pt', displayName: 'Português'),
  LocaleEntry(tag: 'ja', displayName: '日本語'),
  LocaleEntry(tag: 'zh', displayName: '中文'),
];

/// Default locale used when no preference is stored.
const kDefaultLocale = Locale('en');

/// Immutable locale entry used in the picker.
@immutable
class LocaleEntry {
  final String tag;
  final String displayName;

  const LocaleEntry({required this.tag, required this.displayName});
}

/// Returns the display name for a locale tag, falling back to the raw tag.
String localeDisplayName(String tag) {
  for (final entry in kSupportedLocales) {
    if (entry.tag == tag) return entry.displayName;
  }
  return tag;
}

/// Returns the list of [Locale] objects for [MaterialApp.supportedLocales].
List<Locale> get supportedFlutterLocales =>
    kSupportedLocales.map((e) => Locale(e.tag)).toList();

/// Riverpod notifier that holds and persists the selected [Locale].
@Riverpod(keepAlive: true)
class AppLocale extends _$AppLocale {
  @override
  Locale build() {
    _load();
    return kDefaultLocale;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final tag = prefs.getString(kLocaleKey);
    if (tag == null) return;
    final supported = kSupportedLocales.map((e) => e.tag).toList();
    if (supported.contains(tag)) {
      state = Locale(tag);
    }
  }

  /// Selects a locale, persists it to [SharedPreferences], and updates state.
  Future<void> setLocale(Locale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLocaleKey, locale.languageCode);
  }

  /// Returns the persisted locale tag, or `'en'` if none is stored.
  String get currentTag => state.languageCode;
}

/// Convenience alias so callers use the historical short name.
final localeProvider = appLocaleProvider;
