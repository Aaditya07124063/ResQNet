package com.example.resqnet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // DeviceKeyPlugin is bespoke in-app native code (no pub.dev package
    // provides hardware-backed, non-exportable key management), so it is
    // registered manually here rather than through pubspec.yaml's
    // auto-registration (GeneratedPluginRegistrant), matching how the
    // project already handles this exact situation for iOS's
    // MeshConnectivityPlugin.swift.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(DeviceKeyPlugin())
    }
}
