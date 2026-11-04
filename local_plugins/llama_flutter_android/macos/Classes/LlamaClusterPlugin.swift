import FlutterMacOS
import Foundation

/// macOS entry point for the device cluster. Desktop builds are workers: the
/// full local-inference Pigeon API is intentionally not registered here, so
/// the app keeps using cloud models while lending this Mac's GPU to a master.
public class LlamaClusterPlugin: NSObject, FlutterPlugin {
    private var clusterChannel: ClusterChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LlamaClusterPlugin()
        instance.clusterChannel = ClusterChannel(messenger: registrar.messenger)
        registrar.publish(instance)
    }
}
