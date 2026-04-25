import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/task_controller.dart';
import '../core/colors.dart';
import '../models/task_model.dart';

class TaskView extends GetView<TaskController> {
  const TaskView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Tasks', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      ),
      body: Obx(() {
        if (controller.currentTask.value != null) {
          return _buildTaskDetail(context, controller.currentTask.value!);
        }
        return _buildTaskList(context);
      }),
      floatingActionButton: Obx(() {
        if (controller.currentTask.value != null) return const SizedBox.shrink();
        return FloatingActionButton(
          onPressed: () => _showCreateDialog(context),
          backgroundColor: AppColors.primary,
          child: const Icon(Icons.add, color: Colors.white),
        );
      }),
    );
  }

  Widget _buildTaskList(BuildContext context) {
    if (controller.tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bolt, size: 64, color: AppColors.secondary.withOpacity(0.3)),
            const SizedBox(height: 16),
            Text(
              'No Tasks Yet',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a task and the AI will plan\nand execute it autonomously',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: controller.tasks.length,
      itemBuilder: (context, index) {
        final task = controller.tasks[index];
        return _buildTaskCard(context, task);
      },
    );
  }

  Widget _buildTaskCard(BuildContext context, TaskModel task) {
    final statusColor = _getStatusColor(context, task.status);
    final statusIcon = _getStatusIcon(task.status);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => controller.currentTask.value = task,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(statusIcon, color: statusColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.goal,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${task.steps.length} steps · ${task.status.toUpperCase()}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: statusColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).hintColor),
                onPressed: () => controller.deleteTask(task.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskDetail(BuildContext context, TaskModel task) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () => controller.currentTask.value = null,
              ),
              Expanded(
                child: Text(
                  task.goal,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Steps
        Expanded(
          child: Obx(() {
            final current = controller.currentTask.value;
            if (current == null) return const SizedBox.shrink();

            if (controller.isPlanning.value) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: AppColors.primary),
                    const SizedBox(height: 16),
                    Text(
                      'AI is planning steps...',
                      style: GoogleFonts.inter(color: Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey),
                    ),
                  ],
                ),
              );
            }

            if (current.steps.isEmpty) {
              return Center(
                child: Text(
                  'No steps generated.',
                  style: GoogleFonts.inter(color: Theme.of(context).hintColor),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: current.steps.length,
              itemBuilder: (context, index) => _buildStepTile(context, current.steps[index]),
            );
          }),
        ),

        // Execute button
        Obx(() {
          final current = controller.currentTask.value;
          if (current == null || current.steps.isEmpty) return const SizedBox.shrink();
          if (current.status == 'completed') {
            return Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.check_circle, color: AppColors.success),
                  const SizedBox(width: 8),
                  Text('Task Completed',
                      style: GoogleFonts.inter(
                          color: AppColors.success, fontWeight: FontWeight.w600)),
                ],
              ),
            );
          }
          if (current.status == 'planning') return const SizedBox.shrink();

          return Container(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: controller.isExecuting.value
                    ? null
                    : () => controller.executeTask(current),
                icon: controller.isExecuting.value
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow),
                label: Text(controller.isExecuting.value ? 'Executing...' : 'Execute All Steps'),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildStepTile(BuildContext context, TaskStep step) {
    final statusColor = _getStatusColor(context, step.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: step.status == 'running' ? AppColors.primary : Theme.of(context).dividerColor,
          width: step.status == 'running' ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildStepStatusIcon(context, step.status),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  step.description,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (step.command != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                step.command!,
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
          if (step.output != null && step.output!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              step.output!,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: statusColor,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStepStatusIcon(BuildContext context, String status) {
    switch (status) {
      case 'running':
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
        );
      case 'done':
        return const Icon(Icons.check_circle, size: 18, color: AppColors.success);
      case 'failed':
        return const Icon(Icons.error, size: 18, color: AppColors.error);
      default:
        return Icon(Icons.circle_outlined, size: 18, color: Theme.of(context).hintColor);
    }
  }

  Color _getStatusColor(BuildContext context, String status) {
    switch (status) {
      case 'running':
        return AppColors.primary;
      case 'completed':
      case 'done':
        return AppColors.success;
      case 'failed':
        return AppColors.error;
      default:
        return Theme.of(context).hintColor;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'running':
        return Icons.sync;
      case 'completed':
        return Icons.check_circle;
      case 'failed':
        return Icons.error;
      case 'planning':
        return Icons.auto_awesome;
      default:
        return Icons.circle_outlined;
    }
  }

  void _showCreateDialog(BuildContext context) {
    final textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New Task', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          maxLines: 3,
          style: GoogleFonts.inter(fontSize: 14),
          decoration: const InputDecoration(
            hintText: 'e.g., "Set up my phone for bedtime — turn on DND, lower brightness, enable dark mode"',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: GoogleFonts.inter(color: Theme.of(context).hintColor)),
          ),
          ElevatedButton(
            onPressed: () {
              if (textCtrl.text.trim().isNotEmpty) {
                controller.createTask(textCtrl.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
