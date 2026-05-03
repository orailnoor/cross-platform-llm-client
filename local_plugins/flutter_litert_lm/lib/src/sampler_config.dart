/// Configuration for the token sampling strategy.
class LiteLmSamplerConfig {
  final int topK;
  final double topP;
  final double temperature;

  const LiteLmSamplerConfig({
    this.topK = 40,
    this.topP = 0.95,
    this.temperature = 0.8,
  });

  Map<String, dynamic> toMap() => {
        'topK': topK,
        'topP': topP,
        'temperature': temperature,
      };
}
