import 'package:app/services/node_id_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NodeIdValidator', () {
    test('accepts a valid Node ID and trims surrounding whitespace', () {
      expect(
        NodeIdValidator.validationError('  abc123  ', myNodeId: 'own-id'),
        isNull,
      );
    });

    test('rejects an empty value', () {
      expect(NodeIdValidator.validationError('  '), isNotNull);
    });

    test('rejects the local Node ID', () {
      expect(
        NodeIdValidator.validationError('local-node', myNodeId: 'local-node'),
        isNotNull,
      );
    });

    test('rejects the reserved broadcast ID regardless of case', () {
      expect(NodeIdValidator.validationError('ALL'), isNotNull);
    });

    test('rejects IDs shorter than three characters', () {
      expect(NodeIdValidator.validationError('ab'), isNotNull);
    });
  });
}
