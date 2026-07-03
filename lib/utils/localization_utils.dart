import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// Locales that flutter_localizations does NOT support natively.
const _flutterUnsupportedLocales = {'ha', 'yo', 'mg', 'wo'};

/// Returns the locale to use for Material/Cupertino widgets.
Locale materialFallback(Locale locale) =>
    _flutterUnsupportedLocales.contains(locale.languageCode)
        ? const Locale('fr')
        : locale;

/// Fallback Material delegate
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

/// Fallback Cupertino delegate
class FallbackCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<dynamic> {
  const FallbackCupertinoLocalizationsDelegate();
  static const instance = FallbackCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<dynamic> load(Locale locale) =>
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
