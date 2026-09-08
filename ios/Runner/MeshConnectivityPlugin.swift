import Flutter
import Foundation
import MultipeerConnectivity

/// Native iOS side of the offline mesh network, backed by Apple's
/// MultipeerConnectivity framework (Bluetooth + peer-to-peer Wi-Fi). Exposes
/// the same shape of operations mesh_service_ios.dart expects: advertise,
/// discover, connect, accept, send bytes, and stop — so ResQNet's mesh relay
/// works phone-to-phone on iPhones with no internet and no Android nearby,
/// exactly as it already does on Android via Nearby Connections.
///
/// Note: this transport is NOT interoperable with Android's Nearby
/// Connections — the two OSes use different native protocols. An iPhone and
/// an Android phone still exchange hazards once either one has internet
/// (via the government feed / Firestore), but cannot relay directly to each
/// other over Bluetooth/Wi-Fi mesh.
public class MeshConnectivityPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate
{
  // Service type must be 1-15 chars, lowercase letters/numbers/hyphens only.
  private let serviceType = "resqnet-mesh"

  private var localPeerID: MCPeerID!
  private var session: MCSession!
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var eventSink: FlutterEventSink?

  // endpointId (the MCPeerID's full displayName, which we make unique) -> peer
  private var peersById: [String: MCPeerID] = [:]
  // Invitations we've received but the Dart side hasn't accepted yet.
  private var pendingInvitations: [String: (Bool, MCSession?) -> Void] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MeshConnectivityPlugin()
    let methodChannel = FlutterMethodChannel(
      name: "com.resqnet.mesh/methods", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(
      name: "com.resqnet.mesh/events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.eventSink?(payload)
    }
  }

  // MARK: - FlutterPlugin method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "startAdvertising":
      guard let userName = args?["userName"] as? String else {
        result(FlutterError(code: "bad_args", message: "userName required", details: nil))
        return
      }
      startAdvertising(userName: userName)
      result(nil)

    case "startDiscovery":
      guard let userName = args?["userName"] as? String else {
        result(FlutterError(code: "bad_args", message: "userName required", details: nil))
        return
      }
      startDiscovery(userName: userName)
      result(nil)

    case "requestConnection":
      guard let endpointId = args?["endpointId"] as? String else {
        result(FlutterError(code: "bad_args", message: "endpointId required", details: nil))
        return
      }
      requestConnection(endpointId: endpointId)
      result(nil)

    case "acceptConnection":
      guard let endpointId = args?["endpointId"] as? String else {
        result(FlutterError(code: "bad_args", message: "endpointId required", details: nil))
        return
      }
      resolveInvitation(endpointId: endpointId, accept: true)
      result(nil)

    case "sendBytes":
      guard let endpointId = args?["endpointId"] as? String,
        let bytes = args?["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "endpointId/bytes required", details: nil))
        return
      }
      sendBytes(endpointId: endpointId, data: bytes.data)
      result(nil)

    case "stopAll":
      stopAll()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Setup

  /// The visible device name plus a short random suffix, so two phones with
  /// the same profile name still get distinct peer identities.
  private func makeUniqueDisplayName(_ userName: String) -> String {
    let suffix = String(UUID().uuidString.prefix(6))
    let base = "\(userName)~\(suffix)"
    // MCPeerID displayName must be <= 63 UTF-8 bytes.
    let truncated = base.utf8.prefix(63)
    return String(decoding: truncated, as: UTF8.self)
  }

  private func ensureSession(userName: String) {
    if session != nil { return }
    localPeerID = MCPeerID(displayName: makeUniqueDisplayName(userName))
    session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
    session.delegate = self
  }

  private func startAdvertising(userName: String) {
    ensureSession(userName: userName)
    advertiser?.stopAdvertisingPeer()
    advertiser = MCNearbyServiceAdvertiser(
      peer: localPeerID, discoveryInfo: nil, serviceType: serviceType)
    advertiser?.delegate = self
    advertiser?.startAdvertisingPeer()
  }

  private func startDiscovery(userName: String) {
    ensureSession(userName: userName)
    browser?.stopBrowsingForPeers()
    browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
    browser?.delegate = self
    browser?.startBrowsingForPeers()
  }

  private func requestConnection(endpointId: String) {
    guard let peer = peersById[endpointId], let browser = browser else { return }
    browser.invitePeer(peer, to: session, withContext: nil, timeout: 15)
  }

  private func resolveInvitation(endpointId: String, accept: Bool) {
    guard let handler = pendingInvitations.removeValue(forKey: endpointId) else { return }
    handler(accept, accept ? session : nil)
  }

  private func sendBytes(endpointId: String, data: Data) {
    guard let peer = peersById[endpointId], session.connectedPeers.contains(peer) else { return }
    try? session.send(data, toPeers: [peer], with: .reliable)
  }

  private func stopAll() {
    advertiser?.stopAdvertisingPeer()
    advertiser = nil
    browser?.stopBrowsingForPeers()
    browser = nil
    session?.disconnect()
    session = nil
    peersById.removeAll()
    pendingInvitations.removeAll()
  }

  // MARK: - MCNearbyServiceAdvertiserDelegate (someone is inviting us)

  public func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    let id = peerID.displayName
    peersById[id] = peerID
    pendingInvitations[id] = invitationHandler
    // Mirrors the Android flow: the Dart side decides when to call
    // acceptConnection(id) in response to this event.
    emit(["event": "connectionInitiated", "id": id, "info": NSNull()])
  }

  // MARK: - MCNearbyServiceBrowserDelegate (peers we can see)

  public func browser(
    _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?
  ) {
    let id = peerID.displayName
    peersById[id] = peerID
    let visibleName = String(id.split(separator: "~").first ?? Substring(id))
    emit(["event": "endpointFound", "id": id, "name": visibleName])
  }

  public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    let id = peerID.displayName
    emit(["event": "endpointLost", "id": id])
  }

  // MARK: - MCSessionDelegate

  public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    let id = peerID.displayName
    switch state {
    case .connected:
      emit(["event": "connectionResult", "id": id, "connected": true])
    case .notConnected:
      // Distinguish "invite rejected/failed" from "was connected, now
      // dropped" the same way Android's plugin does: always surface both a
      // result and a disconnect so mesh_service.dart's bookkeeping (which
      // listens for both) stays in sync either way.
      emit(["event": "connectionResult", "id": id, "connected": false])
      emit(["event": "disconnected", "id": id])
    case .connecting:
      break
    @unknown default:
      break
    }
  }

  public func session(
    _ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID
  ) {
    emit(["event": "payloadReceived", "id": peerID.displayName, "bytes": FlutterStandardTypedData(bytes: data)])
  }

  public func session(
    _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
    fromPeer peerID: MCPeerID
  ) {}

  public func session(
    _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, with progress: Progress
  ) {}

  public func session(
    _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
  ) {}
}
