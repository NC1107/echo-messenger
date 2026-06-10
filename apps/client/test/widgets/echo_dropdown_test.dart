import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/echo_dropdown.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: EchoTheme.darkTheme,
  home: Scaffold(body: child),
);

void main() {
  group('EchoDropdown', () {
    testWidgets('renders label and the selected value', (tester) async {
      await tester.pumpWidget(
        _wrap(
          EchoDropdown<String>(
            value: 'a',
            labelText: 'Pick one',
            onChanged: (_) {},
            items: const [
              DropdownMenuItem(value: 'a', child: Text('Alpha')),
              DropdownMenuItem(value: 'b', child: Text('Beta')),
            ],
          ),
        ),
      );

      expect(find.text('Pick one'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('shows the hint when value is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          EchoDropdown<String>(
            value: null,
            hintText: 'Choose…',
            onChanged: (_) {},
            items: const [DropdownMenuItem(value: 'a', child: Text('Alpha'))],
          ),
        ),
      );

      expect(find.text('Choose…'), findsOneWidget);
    });

    testWidgets('fires onChanged with the picked value', (tester) async {
      String? picked;
      await tester.pumpWidget(
        _wrap(
          EchoDropdown<String>(
            value: 'a',
            onChanged: (v) => picked = v,
            items: const [
              DropdownMenuItem(value: 'a', child: Text('Alpha')),
              DropdownMenuItem(value: 'b', child: Text('Beta')),
            ],
          ),
        ),
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();

      expect(picked, 'b');
    });
  });
}
