import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/home_controller.dart';
import '../core/colors.dart';
import 'chat_view.dart';
import 'log_view.dart';
import 'model_view.dart';
import 'settings_view.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  static const _tabs = [
    _NavItem(
        icon: Icons.chat_bubble_outline,
        activeIcon: Icons.chat_bubble,
        label: 'Chat'),
    _NavItem(
        icon: Icons.download_outlined,
        activeIcon: Icons.download,
        label: 'Models'),
    _NavItem(
        icon: Icons.article_outlined, activeIcon: Icons.article, label: 'Logs'),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
  ];

  bool get _isWide {
    // Use sidebar on web or when screen is wide enough (tablet/desktop)
    if (kIsWeb) return true;
    final width = Get.width;
    return width >= 800;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Obx(() {
        final content = IndexedStack(
          index: controller.currentTab.value,
          children: const [
            ChatView(),
            ModelView(),
            LogView(),
            SettingsView(),
          ],
        );

        if (_isWide) {
          return Row(
            children: [
              _buildSidebar(context),
              const VerticalDivider(width: 1, thickness: 0.5),
              Expanded(child: content),
            ],
          );
        }

        return content;
      }),
      bottomNavigationBar: _isWide ? null : Obx(() => _buildBottomNav(context)),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: controller.currentTab.value,
        onTap: controller.changeTab,
        items: [
          for (final tab in _tabs)
            BottomNavigationBarItem(
              icon: Icon(tab.icon),
              activeIcon: Icon(tab.activeIcon),
              label: tab.label,
            ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedColor =
        theme.bottomNavigationBarTheme.selectedItemColor ?? AppColors.primary;
    final unselectedColor =
        theme.bottomNavigationBarTheme.unselectedItemColor ?? theme.hintColor;
    final bg = isDark ? const Color(0xFF14141F) : const Color(0xFFFFFFFF);

    return Container(
      width: 72,
      color: bg,
      child: Column(
        children: [
          const SizedBox(height: 16),
          // App logo/icon at top
          Icon(
            Icons.auto_awesome,
            color: selectedColor,
            size: 28,
          ),
          const SizedBox(height: 24),
          const Divider(height: 1, indent: 12, endIndent: 12),
          const SizedBox(height: 8),
          Expanded(
            child: Obx(() {
              final current = controller.currentTab.value;
              return ListView.builder(
                itemCount: _tabs.length,
                itemBuilder: (context, index) {
                  final tab = _tabs[index];
                  final isSelected = current == index;
                  final color = isSelected ? selectedColor : unselectedColor;

                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Material(
                      color: isSelected
                          ? selectedColor.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => controller.changeTab(index),
                        child: SizedBox(
                          height: 56,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isSelected ? tab.activeIcon : tab.icon,
                                color: color,
                                size: 22,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tab.label,
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
