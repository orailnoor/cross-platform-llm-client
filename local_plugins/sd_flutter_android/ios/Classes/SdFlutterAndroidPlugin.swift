import Flutter
import UIKit

public class SdFlutterAndroidPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel!
  private let wrapper = SdIosWrapper()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "sd_flutter_android", binaryMessenger: registrar.messenger())
    let instance = SdFlutterAndroidPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)

    case "initModel":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
        return
      }
      let success = wrapper.initModel(path)
      result(success)

    case "generateImage":
      guard let args = call.arguments as? [String: Any],
            let prompt = args["prompt"] as? String,
            let steps = args["steps"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
        return
      }

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        let data = self.wrapper.generateImage(prompt, steps: Int32(steps))
        DispatchQueue.main.async {
          if let data = data {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(FlutterError(code: "GENERATION_FAILED", message: "Native generation returned null", details: nil))
          }
        }
      }

    case "unloadModel":
      wrapper.unloadModel()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
