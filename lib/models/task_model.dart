class TaskModel {
  final String id;
  final String goal;
  final List<TaskStep> steps;
  final String status; // 'pending', 'running', 'completed', 'failed'
  final DateTime createdAt;

  TaskModel({
    required this.id,
    required this.goal,
    List<TaskStep>? steps,
    this.status = 'pending',
    DateTime? createdAt,
  })  : steps = steps ?? [],
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'goal': goal,
        'steps': steps.map((s) => s.toMap()).toList(),
        'status': status,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TaskModel.fromMap(Map<dynamic, dynamic> map) => TaskModel(
        id: map['id'] ?? '',
        goal: map['goal'] ?? '',
        steps: (map['steps'] as List?)
                ?.map((s) => TaskStep.fromMap(Map<String, dynamic>.from(s)))
                .toList() ??
            [],
        status: map['status'] ?? 'pending',
        createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
      );

  TaskModel copyWith({
    List<TaskStep>? steps,
    String? status,
  }) =>
      TaskModel(
        id: id,
        goal: goal,
        steps: steps ?? this.steps,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

class TaskStep {
  final int index;
  final String description;
  final String? command;
  final String status; // 'pending', 'running', 'done', 'failed'
  final String? output;

  const TaskStep({
    required this.index,
    required this.description,
    this.command,
    this.status = 'pending',
    this.output,
  });

  Map<String, dynamic> toMap() => {
        'index': index,
        'description': description,
        'command': command,
        'status': status,
        'output': output,
      };

  factory TaskStep.fromMap(Map<String, dynamic> map) => TaskStep(
        index: map['index'] ?? 0,
        description: map['description'] ?? '',
        command: map['command'],
        status: map['status'] ?? 'pending',
        output: map['output'],
      );

  TaskStep copyWith({String? status, String? output}) => TaskStep(
        index: index,
        description: description,
        command: command,
        status: status ?? this.status,
        output: output ?? this.output,
      );
}
