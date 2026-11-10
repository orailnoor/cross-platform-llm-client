import 'package:flutter/services.dart';
import 'llama_api.dart';

LlamaHostApi createHostApi(LlamaFlutterApi callbacks) => LlamaHostApi();
MethodChannel createClusterChannel() =>
    const MethodChannel('llama_flutter_android/cluster');
int? get loadedGpuLayers => null;
