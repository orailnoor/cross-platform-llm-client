import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

void main() {
  test('legacyMapIsUnpaired', () {
    final w = ClusterWorker.fromMap({'name': 'a', 'host': '1.2.3.4', 'port': 50052});
    expect(w.paired, isFalse);
  });

  test('pairedSurvivesToMapAndMovedTo', () {
    const w = ClusterWorker(name: 'a', host: '1.2.3.4', port: 50052, id: 'w1', paired: true);
    expect(ClusterWorker.fromMap(w.toMap()).paired, isTrue);
    final moved = w.movedTo('5.6.7.8', 50052);
    expect(moved.paired, isTrue);
    expect(moved.host, '5.6.7.8');
  });
}
