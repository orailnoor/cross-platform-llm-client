import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../models/task_model.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cloud_service.dart';

class TaskController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final _uuid = const Uuid();

  final tasks = <TaskModel>[].obs;
  final currentTask = Rxn<TaskModel>();
  final isPlanning = false.obs;
  final isExecuting = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadTasks();
  }

  void loadTasks() {
    final raw = _hive.getAllTasks();
    tasks.value = raw.map((m) => TaskModel.fromMap(m)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Create a new task: send goal to LLM to get a plan with steps.
  Future<void> createTask(String goal) async {
    if (goal.trim().isEmpty) return;

    final taskId = _uuid.v4();
    var task = TaskModel(id: taskId, goal: goal, status: 'planning');
    tasks.insert(0, task);
    _hive.saveTask(taskId, task.toMap());
    currentTask.value = task;
    isPlanning.value = true;

    try {
      final planPrompt = '''You are an Android automation planner. Given a user's goal, break it down into individual ADB shell commands to execute on an Android phone.

Output ONLY a numbered list of steps. Each step must have:
- A short description
- The exact ADB shell command (prefixed with CMD:)

Example:
1. Enable Do Not Disturb mode
CMD: settings put global zen_mode 1
2. Reduce screen brightness to 30%
CMD: settings put system screen_brightness 77
3. Enable dark mode
CMD: cmd uimode night yes

User Goal: $goal

Steps:''';

      String response;
      final mode = _hive.getSetting(AppConstants.keyInferenceMode,
              defaultValue: 'cloud') ??
          'cloud';

      if (mode == 'local') {
        final inference = Get.find<InferenceService>();
        response = await inference.generate(prompt: planPrompt);
      } else {
        final cloud = Get.find<CloudService>();
        response = await cloud.sendMessage(messages: [
          {'role': 'user', 'content': planPrompt},
        ]);
      }

      // Parse steps from response
      final steps = _parseSteps(response);

      if (steps.isEmpty) {
        task = task.copyWith(
          status: 'failed',
          steps: [
            TaskStep(
              index: 0,
              description: 'Failed to generate plan. Raw output: $response',
              status: 'failed',
            ),
          ],
        );
      } else {
        task = task.copyWith(status: 'pending', steps: steps);
      }

      currentTask.value = task;
      final idx = tasks.indexWhere((t) => t.id == taskId);
      if (idx >= 0) tasks[idx] = task;
      _hive.saveTask(taskId, task.toMap());
    } catch (e) {
      task = task.copyWith(status: 'failed');
      currentTask.value = task;
      final idx = tasks.indexWhere((t) => t.id == taskId);
      if (idx >= 0) tasks[idx] = task;
      _hive.saveTask(taskId, task.toMap());
    }

    isPlanning.value = false;
  }

  /// Execute all pending steps in sequence.
  Future<void> executeTask(TaskModel task) async {
    isExecuting.value = true;
    currentTask.value = task;

    var updatedTask = task.copyWith(status: 'running');
    _updateTask(updatedTask);

    final steps = List<TaskStep>.from(updatedTask.steps);

    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      steps[i] = step.copyWith(
        status: 'failed',
        output: 'Command execution is not available.',
      );
    }

    updatedTask = updatedTask.copyWith(steps: steps, status: 'failed');
    _updateTask(updatedTask);
    isExecuting.value = false;
  }

  void deleteTask(String id) {
    _hive.deleteTask(id);
    tasks.removeWhere((t) => t.id == id);
    if (currentTask.value?.id == id) {
      currentTask.value = null;
    }
  }

  void _updateTask(TaskModel task) {
    currentTask.value = task;
    final idx = tasks.indexWhere((t) => t.id == task.id);
    if (idx >= 0) tasks[idx] = task;
    _hive.saveTask(task.id, task.toMap());
  }

  /// Parse numbered steps from LLM output.
  List<TaskStep> _parseSteps(String raw) {
    final steps = <TaskStep>[];
    final lines = raw.trim().split('\n');

    String? currentDesc;
    int stepIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Check for step description (numbered line)
      final numMatch = RegExp(r'^\d+[\.\)]\s*(.+)').firstMatch(trimmed);
      if (numMatch != null) {
        currentDesc = numMatch.group(1)?.trim();
        continue;
      }

      // Check for CMD: line
      if (trimmed.startsWith('CMD:')) {
        final cmd = trimmed.substring(4).trim();
        steps.add(TaskStep(
          index: stepIndex++,
          description: currentDesc ?? 'Step ${stepIndex}',
          command: cmd,
        ));
        currentDesc = null;
      }
    }

    return steps;
  }
}
