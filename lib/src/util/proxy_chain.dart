/// Helpers for walking mihomo's proxy-group selection chain.
library;

import '../service/mihomo_api.dart';

/// Follows `now` pointers from a group until a real (leaf) node is reached.
///
/// Groups may point at other groups, so `group.now` alone is often only the
/// first hop of a path. Returns null when the group has no selection.
ProxyNode? resolveSelectedNode(ProxySnapshot snapshot, ProxyNode group) {
  var current = _clean(group.now);
  final seen = <String>{group.name};
  var hops = 0;
  ProxyNode? last;
  while (current != null && hops++ < 16) {
    if (!seen.add(current)) break; // cycle guard
    final node = snapshot.nodes[current];
    if (node == null) return last;
    last = node;
    final next = _clean(node.now);
    if (!node.isGroup || next == null) return node;
    current = next;
  }
  return last;
}

String? _clean(String? value) =>
    value == null || value.trim().isEmpty ? null : value.trim();

/// Returns the outbound for the live mode or the MATCH fallback in rule mode.
String? selectedOutbound(
  ProxySnapshot? snapshot, {
  required String? mode,
  required String? matchTarget,
}) {
  if (mode == 'direct') return 'DIRECT';
  final target = switch (mode) {
    'global' => 'GLOBAL',
    'rule' => matchTarget,
    _ => null,
  };
  if (target == null || snapshot == null) return null;
  final node = snapshot.nodes[target];
  if (node == null) return null;
  return node.isGroup
      ? resolveSelectedNode(snapshot, node)?.name ?? node.now
      : node.name;
}
