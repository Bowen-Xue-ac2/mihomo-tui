import 'package:mihomo_tui/src/ui/views/logs_view.dart';
import 'package:test/test.dart';

void main() {
  test('density modes cycle in order', () {
    expect(LogMode.standard.next, LogMode.compact);
    expect(LogMode.compact.next, LogMode.standard);
  });

  test('modes have labels', () {
    expect(LogMode.standard.label, 'Standard');
    expect(LogMode.compact.label, 'Compact');
  });
}
