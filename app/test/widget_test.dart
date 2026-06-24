import 'package:flutter_test/flutter_test.dart';

import 'package:sahin/main.dart';

void main() {
  testWidgets('Açılışta Şahin başlığı ve mic butonu görünür', (tester) async {
    await tester.pumpWidget(const SahinApp());
    await tester.pump();

    expect(find.text('Şahin'), findsWidgets);
    expect(find.byType(HomePage), findsOneWidget);
  });
}
