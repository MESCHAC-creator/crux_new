import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// Locales that flutter_localizations does NOT support natively.
// Any locale outside this set falls back to French for Material/Cupertino
// internals (button labels, date pickers, etc.) while our AppTranslations
// handles all visible app text in the correct language.
const _flutterUnsupportedLocales = {'ha', 'yo', 'mg', 'wo'};

/// Returns the locale to use for Material/Cupertino widgets.
/// For locales unsupported by flutter_localizations, falls back to French
/// so widgets never throw a "no localizations found" error.
Locale materialFallback(Locale locale) =>
    _flutterUnsupportedLocales.contains(locale.languageCode)
        ? const Locale('fr')
        : locale;

/// Fallback Material delegate: accepts every locale, loads French for unsupported ones.
class FallbackMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const FallbackMaterialLocalizationsDelegate();
  static const instance = FallbackMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      GlobalMaterialLocalizations.delegate.load(materialFallback(locale));

  @override
  bool shouldReload(FallbackMaterialLocalizationsDelegate old) => false;
}

/// Fallback Cupertino delegate: accepts every locale, loads French for unsupported ones.
class FallbackCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const FallbackCupertinoLocalizationsDelegate();
  static const instance = FallbackCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      GlobalCupertinoLocalizations.delegate.load(materialFallback(locale));

  @override
  bool shouldReload(FallbackCupertinoLocalizationsDelegate old) => false;
}

/// The shared delegate list used in EVERY MaterialApp in this app.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  FallbackMaterialLocalizationsDelegate.instance,
  FallbackCupertinoLocalizationsDelegate.instance,
  GlobalWidgetsLocalizations.delegate,
];
