import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/home_controller.dart';
import 'chat_view.dart';
import 'model_view.dart';
import 'server_view.dart';
import 'settings_view.dart';

class HomeView extends GetView<HomeController> {
  const HomeView({super.key});

  static const _tabs = [
    _NavItem(
        icon: Icons.bubble_chart_outlined,
        activeIcon: Icons.bubble_chart,
        label: 'Chat'),
    _NavItem(
        icon: Icons.arrow_downward_rounded,
        activeIcon: Icons.arrow_downward_rounded,
        label: 'Models'),
    _NavItem(
        icon: Icons.dns_outlined,
        activeIcon: Icons.dns_rounded,
        label: 'Server'),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
  ];

  bool get _isWide {
    // Force bottom navbar for all layouts per user request
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.checkResumeModel(context);
    });
    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      body: Obx(() {
        final content = IndexedStack(
          index: controller.currentTab.value,
          children: const [
            ChatView(),
            ModelView(),
            ServerView(),
            SettingsView()
          ],
        );
        if (_isWide) {
          return Row(children: [
            _buildSidebar(context, isDark),
            VerticalDivider(
                width: 0.5,
                thickness: 0.5,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.08)),
            Expanded(child: content),
          ]);
        }
        return content;
      }),
      bottomNavigationBar:
          _isWide ? null : Obx(() => _buildBottomNav(context, isDark)),
    );
  }

  Widget _buildBottomNav(BuildContext context, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
        border: Border(
            top: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.5,
        )),
      ),
      child: BottomNavigationBar(
        currentIndex: controller.currentTab.value,
        onTap: controller.changeTab,
        backgroundColor: Colors.transparent,
        elevation: 0,
        items: [
          for (final tab in _tabs)
            BottomNavigationBarItem(
              icon: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Icon(tab.icon, size: 22),
              ),
              activeIcon: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Icon(tab.activeIcon, size: 22),
              ),
              label: tab.label,
            ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, bool isDark) {
    final accent = isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
    final muted = Theme.of(context).hintColor;

    return Container(
      width: 76,
      color: isDark ? Colors.black : Colors.white,
      child: Column(children: [
        // const SizedBox(height: 20),
        // Image.asset(
        //   'assets/icons/appicon.png',
        //   width: 40,
        //   height: 40,
        // ),
        // const SizedBox(height: 20),
        Expanded(child: Obx(() {
          final current = controller.currentTab.value;
          return ListView.builder(
            itemCount: _tabs.length,
            itemBuilder: (_, i) {
              final tab = _tabs[i];
              final sel = current == i;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Material(
                  color:
                      sel ? accent.withValues(alpha: 0.12) : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => controller.changeTab(i),
                    child: SizedBox(
                      height: 52,
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(sel ? tab.activeIcon : tab.icon,
                                color: sel ? accent : muted, size: 20),
                            const SizedBox(height: 3),
                            Text(tab.label,
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight:
                                        sel ? FontWeight.w600 : FontWeight.w400,
                                    color: sel ? accent : muted)),
                          ]),
                    ),
                  ),
                ),
              );
            },
          );
        })),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}
