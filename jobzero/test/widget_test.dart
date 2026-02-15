import 'package:flutter_test/flutter_test.dart';
import 'package:jobzero/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const JobZeroApp());
    expect(find.text('JobZero'), findsOneWidget);
  });
}
