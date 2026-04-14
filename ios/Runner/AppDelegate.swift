import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioSessionChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocketAudioSession") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.ys.locket/audioSession",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "configureForBluetooth":
        let session = AVAudioSession.sharedInstance()
        do {
          try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
          )
          try session.setActive(true)
          result(true)
        } catch {
          result(FlutterError(
            code: "AUDIO_SESSION_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      case "deactivate":
        do {
          try AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
          )
          result(true)
        } catch {
          result(FlutterError(
            code: "AUDIO_SESSION_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    audioSessionChannel = channel
  }
}
