import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:resqnet/core/services/theme_service.dart';

void main() {
  testWidgets('ThemeService drives light/dark MaterialApp theme',
      (WidgetTester tester) async {
    final themeService = ThemeService();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: themeService,
        child: Consumer<ThemeService>(
          builder: (context, theme, _) => MaterialApp(
            theme: theme.isDarkMode ? ThemeData.dark() : ThemeData.light(),
            home: const Scaffold(body: Text('ResQNet')),
          ),
        ),
      ),
    );

    expect(find.text('ResQNet'), findsOneWidget);
  });
}
