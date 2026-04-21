import AVFoundation
import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioSessionChannel: FlutterMethodChannel?
  private var wifiChannel: FlutterMethodChannel?

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

    // WiFi method channel for SoftAP connection.
    guard let wifiRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocketWiFi") else {
      return
    }
    let wifi = FlutterMethodChannel(
      name: "com.ys.locket/wifi",
      binaryMessenger: wifiRegistrar.messenger()
    )
    wifi.setMethodCallHandler { (call, result) in
      switch call.method {
      case "connectToAp":
        guard let args = call.arguments as? [String: Any],
              let ssid = args["ssid"] as? String,
              let password = args["password"] as? String else {
          result(FlutterError(
            code: "INVALID_ARGS",
            message: "ssid and password are required",
            details: nil
          ))
          return
        }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        config.joinOnce = true
        NEHotspotConfigurationManager.shared.apply(config) { error in
          if let error = error as NSError? {
            // Error code 13 = "already associated", treat as success.
            if error.domain == NEHotspotConfigurationErrorDomain &&
               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
              result(true)
            } else {
              result(FlutterError(
                code: "WIFI_ERROR",
                message: error.localizedDescription,
                details: nil
              ))
            }
          } else {
            result(true)
          }
        }
      case "disconnectFromAp":
        guard let args = call.arguments as? [String: Any],
              let ssid = args["ssid"] as? String else {
          result(FlutterError(
            code: "INVALID_ARGS",
            message: "ssid is required",
            details: nil
          ))
          return
        }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    wifiChannel = wifi
  }
}
