import 'package:get/get.dart';

class HomeController extends GetxController {
  final currentTab = 0.obs;

  void changeTab(int index) {
    currentTab.value = index;
  }
}
