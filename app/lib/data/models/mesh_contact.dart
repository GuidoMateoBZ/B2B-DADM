class MeshContact {
  const MeshContact({
    required this.nodeId,
    required this.alias,
    required this.createdAt,
  });

  final String nodeId;
  final String? alias;
  final int createdAt;

  String get displayName =>
      alias == null || alias!.trim().isEmpty ? nodeId : alias!.trim();

  Map<String, Object?> toMap() => {
    'node_id': nodeId,
    'alias': alias,
    'created_at': createdAt,
  };

  factory MeshContact.fromMap(Map<String, Object?> map) => MeshContact(
    nodeId: map['node_id'] as String,
    alias: map['alias'] as String?,
    createdAt: map['created_at'] as int,
  );
}
