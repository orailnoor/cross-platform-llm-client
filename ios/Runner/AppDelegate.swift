import Flutter
import UIKit
import CoreML
import StableDiffusion

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var pipeline: StableDiffusionPipeline?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "coreml_stable_diffusion", binaryMessenger: controller.binaryMessenger)
    
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      
      switch call.method {
      case "initModel":
          guard let args = call.arguments as? [String: Any],
                let path = args["path"] as? String else {
              result(FlutterError(code: "INVALID_ARGUMENT", message: "Path is null", details: nil))
              return
          }
          
          DispatchQueue.global(qos: .userInitiated).async {
              do {
                  let resourceURL = URL(fileURLWithPath: path)
                  let config = MLModelConfiguration()
                  config.computeUnits = .cpuAndGPU
                  
                  print("[CoreML] Initializing pipeline with resources at: \(resourceURL.path)")
                  self.pipeline = try StableDiffusionPipeline(
                      resourcesAt: resourceURL,
                      controlNet: [],
                      configuration: config,
                      disableSafety: true,
                      reduceMemory: true
                  )
                  
                  print("[CoreML] Pipeline initialized. Starting loadResources() (This may take several minutes on first run to optimize for the Neural Engine...)")
                  try self.pipeline?.loadResources()
                  print("[CoreML] loadResources() completed successfully.")
                  
                  DispatchQueue.main.async {
                      result("Model loaded successfully")
                  }
              } catch {
                  DispatchQueue.main.async {
                      result(FlutterError(code: "LOAD_ERROR", message: "Failed to load CoreML model: \(error.localizedDescription)", details: nil))
                  }
              }
          }
          
      case "generateImage":
          guard let args = call.arguments as? [String: Any],
                let prompt = args["prompt"] as? String,
                let steps = args["steps"] as? Int,
                let pipeline = self.pipeline else {
              result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments or model not loaded", details: nil))
              return
          }
          
          DispatchQueue.global(qos: .userInitiated).async {
              do {
                  var config = StableDiffusionPipeline.Configuration(prompt: prompt)
                  config.stepCount = steps
                  config.seed = UInt32.random(in: 0...UInt32.max)
                  config.schedulerType = .dpmSolverMultistepScheduler
                  
                  let images = try pipeline.generateImages(configuration: config) { progress in
                      DispatchQueue.main.async {
                          channel.invokeMethod("onProgress", arguments: [
                              "step": progress.step,
                              "total": progress.stepCount
                          ])
                      }
                      return true
                  }
                  
                  guard let firstImage = images.compactMap({ $0 }).first,
                        let uiImage = UIImage(cgImage: firstImage).pngData() else {
                      DispatchQueue.main.async {
                          result(FlutterError(code: "GENERATION_FAILED", message: "No image generated", details: nil))
                      }
                      return
                  }
                  
                  DispatchQueue.main.async {
                      result(FlutterStandardTypedData(bytes: uiImage))
                  }
              } catch {
                  DispatchQueue.main.async {
                      result(FlutterError(code: "GENERATION_ERROR", message: "Image generation failed: \(error.localizedDescription)", details: nil))
                  }
              }
          }
          
      case "unloadModel":
          self.pipeline?.unloadResources()
          self.pipeline = nil
          result(nil)
          
      default:
          result(FlutterMethodNotImplemented)
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

