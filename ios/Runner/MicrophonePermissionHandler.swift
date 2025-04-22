import Flutter
import AVFoundation

public class MicrophonePermissionHandler: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "microphone_permission",
            binaryMessenger: registrar.messenger()
        )
        let instance = MicrophonePermissionHandler()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "requestPermission" {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                result(granted)
            }
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}
