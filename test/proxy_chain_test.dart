import 'package:mihomo_tui/src/service/mihomo_api.dart';
import 'package:mihomo_tui/src/util/proxy_chain.dart';
import 'package:test/test.dart';

ProxyNode node(String name, {String? now, List<String> all = const []}) =>
    ProxyNode(
        name: name,
        type: all.isEmpty ? 'Shadowsocks' : 'Selector',
        now: now,
        all: all);

ProxySnapshot snapshotOf(List<ProxyNode> nodes) => ProxySnapshot(
      groups: nodes.where((n) => n.isGroup).toList(),
      nodes: {for (final n in nodes) n.name: n},
    );

void main() {
  group('resolveSelectedNode', () {
    test('returns the node itself when it is a leaf', () {
      final leaf = node('香港 01');
      final group = node('节点选择', now: '香港 01', all: ['香港 01']);
      final snapshot = snapshotOf([leaf, group]);
      expect(resolveSelectedNode(snapshot, group)?.name, '香港 01');
    });

    test('walks nested groups down to the leaf', () {
      final leaf = node('新加坡 02');
      final child = node('自动选择', now: '新加坡 02', all: ['新加坡 02']);
      final parent = node('节点选择', now: '自动选择', all: ['自动选择']);
      final snapshot = snapshotOf([leaf, child, parent]);
      expect(resolveSelectedNode(snapshot, parent)?.name, '新加坡 02');
    });

    test('stops on cycles', () {
      final a = node('A', now: 'B', all: ['B']);
      final b = node('B', now: 'A', all: ['A']);
      final snapshot = snapshotOf([a, b]);
      // Must terminate (and return something sensible).
      expect(resolveSelectedNode(snapshot, a), isNotNull);
    });

    test('returns null when nothing is selected', () {
      final group = node('节点选择', all: ['x']);
      expect(resolveSelectedNode(snapshotOf([group]), group), isNull);
    });
  });

  group('selectedOutbound', () {
    final match = node('节点选择', now: 'Rule exit', all: ['Rule exit']);
    final inner = node('HK', now: '香港 01', all: ['香港 01']);
    final global = node('GLOBAL', now: 'HK', all: ['HK']);
    final snapshot =
        snapshotOf([node('Rule exit'), node('香港 01'), match, inner, global]);

    test('uses GLOBAL in global mode and follows nested groups', () {
      expect(
        selectedOutbound(snapshot, mode: 'global', matchTarget: match.name),
        '香港 01',
      );
    });

    test('uses MATCH as the fallback in rule mode', () {
      expect(
        selectedOutbound(snapshot, mode: 'rule', matchTarget: match.name),
        'Rule exit',
      );
      expect(
        selectedOutbound(snapshot, mode: 'rule', matchTarget: 'Rule exit'),
        'Rule exit',
      );
    });

    test('keeps DIRECT and missing routes explicit', () {
      expect(selectedOutbound(null, mode: 'direct', matchTarget: match.name),
          'DIRECT');
      expect(
          selectedOutbound(snapshot, mode: 'rule', matchTarget: null), isNull);
      expect(selectedOutbound(snapshot, mode: null, matchTarget: match.name),
          isNull);
    });
  });
}
