import AVFoundation
import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioSessionChannel: FlutterMethodChannel?
  private var wifiChannel: FlutterMethodChannel?
  private var sessionWasConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Phone calls / Siri deactivate the AVAudioSession; without
    // reactivation iOS stops crediting the app for background audio
    // and suspends the BLE relay a few minutes later. Same recovery
    // the official omi app performs after interruptions.
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard self?.sessionWasConfigured == true,
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue),
            type == .ended else {
        return
      }
      try? AVAudioSession.sharedInstance().setActive(true)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    // Re-assert the session when returning to the foreground in case
    // it was silently deactivated while backgrounded.
    if sessionWasConfigured {
      try? AVAudioSession.sharedInstance().setActive(true)
    }
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
    channel.setMethodCallHandler { [weak self] (call, result) in
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
          self?.sessionWasConfigured = true
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
          self?.sessionWasConfigured = false
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
