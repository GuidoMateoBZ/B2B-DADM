import 'package:flutter_test/flutter_test.dart';

import 'package:app/services/node_id_validator.dart';

void main() {
  group('NodeIdValidator', () {
    test('rejects empty or too short node IDs', () {
      expect(NodeIdValidator.validationError(' '), isNotNull);
      expect(NodeIdValidator.validationError('ab'), isNotNull);
    });

    test('rejects own node ID and reserved broadcast address', () {
      expect(
        NodeIdValidator.validationError('my-node', myNodeId: 'my-node'),
        isNotNull,
      );
      expect(NodeIdValidator.validationError('ALL'), isNotNull);
    });

    test('accepts a valid different node ID', () {
      expect(
        NodeIdValidator.validationError('peer-node', myNodeId: 'my-node'),
        isNull,
      );
    });
  });
}
