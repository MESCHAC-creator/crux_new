import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

const _flutterUnsupportedLocales = {'ha', 'yo', 'mg', 'wo'};

Locale materialFallback(Locale locale) =>
    _flutterUnsupportedLocales.contains(locale.languageCode)
        ? const Locale('fr')
        : locale;

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

const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  FallbackMaterialLocalizationsDelegate.instance,
  FallbackCupertinoLocalizationsDelegate.instance,
  GlobalWidgetsLocalizations.delegate,
];