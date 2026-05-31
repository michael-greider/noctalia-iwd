pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.System
import qs.Services.UI

Singleton {
  id: root

  // ─── Public API (identical to original) ──────────────────────────────

  readonly property bool wifiAvailable: _wifiAvailable
  readonly property bool ethernetAvailable: _ethernetAvailable
  readonly property bool internetConnectivity: _internetConnectivity
  readonly property string networkConnectivity: _networkConnectivity

  readonly property var supportedSecurityTypes: [
    { key: "open",     name: I18n.tr("wifi.panel.security-open") },
    { key: "wep",      name: I18n.tr("wifi.panel.security-wep") },
    { key: "wpa-psk",  name: I18n.tr("wifi.panel.security-wpa") },
    { key: "wpa2-psk", name: I18n.tr("wifi.panel.security-wpa23") },
    { key: "sae",      name: I18n.tr("wifi.panel.security-wpa3") },
    { key: "wpa-eap",  name: I18n.tr("wifi.panel.security-wpa-ent") },
    { key: "wpa2-eap", name: I18n.tr("wifi.panel.security-wpa2-ent") },
    { key: "wpa3-eap", name: I18n.tr("wifi.panel.security-wpa3-ent") }
  ]

  // Core state
  property bool _wifiAvailable: false
  property bool _ethernetAvailable: false
  property string _networkConnectivity: "unknown"
  property bool _internetConnectivity: false
  property string lastError: ""
  property int activeDetailsTtlMs: 10000

  // Ethernet
  property var ethernetInterfaces: ([])
  property var activeEthernetDetails: ({})
  property bool ethernetConnected: false
  property string activeEthernetIf: ""
  property bool ethernetDetailsLoading: false
  property double activeEthernetDetailsTimestamp: 0

  // Wi-Fi — wifiEnabled is now sourced from iwd Device.Powered, NOT Quickshell.Networking
  property bool _wifiPowered: false
  readonly property bool wifiEnabled: _wifiPowered
  property var networks: ({})
  property var activeWifiDetails: ({})
  property bool wifiConnected: false
  property string activeWifiIf: ""
  property bool wifiDetailsLoading: false
  property double activeWifiDetailsTimestamp: 0
  property bool wifiInit: false

  // Connection flow
  property bool connecting: false
  property string connectingTo: ""
  property string disconnectingFrom: ""
  property string forgettingNetwork: ""
  property bool scanPending: false
  property bool scanningActive: false
  property var existingProfiles: ({})

  // Airplane mode
  property bool airplaneModeEnabled: false
  property bool airplaneModeToggled: false

  // iwd backend state
  property bool iwdAvailable: false

  // ─── Signals ─────────────────────────────────────────────────────────

  Connections {
    target: root
    function onWifiEnabledChanged() {
      if (!root.wifiInit) return;
      wifiDebounce.restart();
    }
  }

  Component.onCompleted: {
    Logger.i("Network", "Service started (iwd backend)");
    wifiInitTimer.restart();
    deviceStatusProcess.running = true;
    connectivityCheckProcess.running = true;
  }

  // ─── Timers ──────────────────────────────────────────────────────────

  Timer {
    id: wifiInitTimer
    interval: 800
    onTriggered: {
      root.wifiInit = true;
      if (root.wifiEnabled) scan();
      // Check airplane mode (both wifi and bluetooth blocked)
      if (!root.wifiEnabled && BluetoothService.blocked)
        root.airplaneModeEnabled = true;
    }
  }

  Timer {
    id: wifiDebounce
    interval: 300
    onTriggered: {
      if (!root.iwdAvailable) return;
      if (root.airplaneModeToggled) {
        root.airplaneModeToggled = false;
        if (root.wifiEnabled) scan();
        else root.networks = ({});
        return;
      }
      if (root.wifiEnabled) {
        ToastService.showNotice(I18n.tr("common.wifi"), I18n.tr("common.enabled"), "wifi");
        scan();
      } else {
        ToastService.showNotice(I18n.tr("common.wifi"), I18n.tr("common.disabled"), "wifi-off");
        root.networks = ({});
      }
    }
  }

  Timer {
    id: connectivityCheckTimer
    interval: 15000
    running: root.iwdAvailable && (root.ethernetConnected || root.wifiConnected)
    repeat: true
    onTriggered: connectivityCheckProcess.running = true
  }

  Timer {
    id: delayedScanTimer
    interval: 7000
    onTriggered: scan()
  }

  // State poller — replaces nmcli monitor
  Timer {
    id: statePollerTimer
    interval: 5000
    running: root.iwdAvailable
    repeat: true
    onTriggered: deviceStatusProcess.running = true
  }

  // ─── Public Functions ────────────────────────────────────────────────

  function setWifiEnabled(enabled) {
    if (!root.iwdAvailable) return;
    Logger.i("Wi-Fi", "SetWifiEnabled", enabled);
    iwdSetPoweredProcess.powered = enabled;
    iwdSetPoweredProcess.running = true;
  }

  function setAirplaneMode(state) {
    if (state) {
      Quickshell.execDetached(["rfkill", "block", "all"]);
    } else {
      Quickshell.execDetached(["rfkill", "unblock", "all"]);
    }
  }

  function scan() {
    if (!root.iwdAvailable || !root.wifiEnabled) return;
    lastError = "";

    if (profileCheckProcess.running || scanProcess.running) {
      root.scanPending = true;
      return;
    }

    profileCheckProcess.running = true;
    root.scanningActive = true;
    Logger.d("Network", "Scanning Wi-Fi networks...");
  }

  function connect(ssid, password = "", isHidden = false, securityKey = "", identity = "", enterpriseConfig = {}) {
    if (!root.iwdAvailable || connecting) return;

    connecting = true;
    connectingTo = ssid;
    lastError = "";

    connectProcess.ssid = ssid;
    connectProcess.password = password;
    connectProcess.isHidden = isHidden;
    connectProcess.running = true;
  }

  function disconnect(ssid) {
    if (!root.iwdAvailable) return;
    disconnectingFrom = ssid;
    disconnectProcess.running = true;
  }

  function forget(ssid) {
    if (!root.iwdAvailable) return;
    forgettingNetwork = ssid;
    forgetProcess.ssid = ssid;
    forgetProcess.running = true;
  }

  function refreshActiveWifiDetails() {
    const now = Date.now();
    if (wifiDetailsLoading || (activeWifiIf && wifiConnected && activeWifiDetails
        && (now - activeWifiDetailsTimestamp) < activeDetailsTtlMs)) return;
    if (wifiConnected && activeWifiIf) {
      wifiDetailsLoading = true;
      deviceStatusProcess.running = true;
    }
  }

  function refreshActiveEthernetDetails() {
    const now = Date.now();
    if (ethernetDetailsLoading || (activeEthernetIf && activeEthernetDetails
        && (now - activeEthernetDetailsTimestamp) < activeDetailsTtlMs)) return;
    if (ethernetConnected && activeEthernetIf) {
      ethernetDetailsLoading = true;
      deviceStatusProcess.running = true;
    }
  }

  // ─── Helper Functions (unchanged API) ────────────────────────────────

  function updateNetworkStatus(ssid, connected) {
    let nets = networks;
    for (let key in nets) {
      if (nets[key].connected && key !== ssid)
        nets[key].connected = false;
    }
    if (nets[ssid]) {
      nets[ssid].connected = connected;
      nets[ssid].existing = true;
    } else if (connected) {
      nets[ssid] = {
        "ssid": ssid, "security": "--", "signal": 100,
        "connected": true, "existing": true
      };
    }
    networks = ({});
    networks = nets;
  }

  function getSignalInfo(signal, isConnected) {
    let icon = "";
    if (isConnected) {
      if (root._networkConnectivity === "limited")
        icon = "wifi-exclamation";
      else if (root._networkConnectivity === "portal" || root._networkConnectivity === "unknown")
        icon = "wifi-question";
    }
    const label = signal >= 80 ? I18n.tr("wifi.signal.excellent")
                : signal >= 60 ? I18n.tr("wifi.signal.good")
                : signal >= 35 ? I18n.tr("wifi.signal.fair")
                : signal >= 15 ? I18n.tr("wifi.signal.poor")
                : I18n.tr("wifi.signal.weak");
    if (!icon)
      icon = signal >= 80 ? "wifi" : signal >= 60 ? "wifi-3" : signal >= 35 ? "wifi-2" : signal >= 15 ? "wifi-1" : "wifi-0";
    return { icon, label };
  }

  function isSecured(security) {
    return security && security !== "--" && security.trim() !== "";
  }

  function isEnterprise(security) {
    if (!security) return false;
    const s = security.toUpperCase();
    return s.indexOf("802.1X") !== -1 || s.indexOf("EAP") !== -1 || s.indexOf("ENTERPRISE") !== -1;
  }

  function getStatusText(showSpeed = false) {
    if (root.connecting)
      return root.connectingTo
        ? I18n.tr("common.connecting") + " " + root.connectingTo
        : I18n.tr("common.connecting");

    if (NetworkService.airplaneModeEnabled)
      return I18n.tr("toast.airplane-mode.title");
    if (!root.wifiEnabled)
      return "";

    if (root.ethernetConnected) {
      const eth = root.activeEthernetDetails;
      const name = eth.connectionName || (root.ethernetInterfaces.length > 0 ? root.ethernetInterfaces[0].connectionName : "") || "";
      const speed = eth.speed || "";
      return name + (showSpeed && speed ? " - " + speed : "");
    }

    if (root.wifiConnected) {
      const wl = root.activeWifiDetails;
      const speed = wl.rateShort || wl.rate || "";
      const connectedNet = Object.values(root.networks).find(net => net.connected);
      const name = connectedNet ? connectedNet.ssid : (wl.connectionName || "");
      return name + (showSpeed && speed ? " - " + speed : "");
    }
    return "";
  }

  function getIcon(forceEthernet = false) {
    if (NetworkService.airplaneModeEnabled && !forceEthernet)
      return "plane";

    if (root.ethernetConnected || forceEthernet) {
      switch (root._networkConnectivity) {
        case "limited":  return "ethernet-exclamation";
        case "portal":
        case "unknown":  return "ethernet-question";
        case "full":     return "ethernet";
        default:         return "ethernet-off";
      }
    }

    if (root.wifiAvailable || !forceEthernet) {
      const networkCount = Object.values(root.networks).length;
      if (!root.wifiEnabled) return "wifi-off";
      if (root.wifiConnected) {
        let s = (root.activeWifiDetails && root.activeWifiDetails.signal !== undefined
                 && root.activeWifiDetails.signal !== "")
                ? root.activeWifiDetails.signal : 0;
        return root.getSignalInfo(s, true).icon;
      }
      if (root.connecting || networkCount > 0) return "wifi-question";
    }
    return (root.ethernetAvailable || root.ethernetConnected) ? "ethernet-off"
         : root.wifiAvailable ? "wifi-0" : "wifi-off";
  }

  // ─── Processes ───────────────────────────────────────────────────────

  // [1] Full device status
  Process {
    id: deviceStatusProcess
    running: false
    command: ["iwd-helper", "status"]

    stdout: StdioCollector {
      onStreamFinished: {
        if (!text.trim()) return;
        let data;
        try { data = JSON.parse(text); }
        catch (e) {
          Logger.w("Network", "iwd-helper status parse error: " + e);
          root.ethernetDetailsLoading = false;
          root.wifiDetailsLoading = false;
          return;
        }

        root.iwdAvailable = !data.error;

        // Wi-Fi powered state — this drives wifiEnabled
        root._wifiPowered = data.powered || false;
        root._wifiAvailable = data.wifiAvailable || false;
        root.wifiConnected = data.wifiConnected || false;

        // Ethernet
        const ethList = data.ethernetInterfaces || [];
        root._ethernetAvailable = ethList.length > 0;
        root.ethernetConnected = data.ethernetConnected || false;
        ethList.sort((a, b) => (a.connected !== b.connected)
          ? (a.connected ? -1 : 1)
          : a.ifname.localeCompare(b.ifname));
        root.ethernetInterfaces = ethList;

        if (data.ethernetConnected && data.activeEthernetDetails) {
          root.activeEthernetIf = data.activeEthernetDetails.ifname || "";
          root.activeEthernetDetails = data.activeEthernetDetails;
          root.activeEthernetDetailsTimestamp = Date.now();
        }
        root.ethernetDetailsLoading = false;

        // Wi-Fi details
        if (data.wifiConnected && data.activeWifiDetails) {
          root.activeWifiIf = data.deviceName || "";
          root.activeWifiDetails = data.activeWifiDetails;
          root.activeWifiDetailsTimestamp = Date.now();
        } else {
          root.activeWifiIf = data.deviceName || "";
        }
        root.wifiDetailsLoading = false;

        Logger.d("Network", "iwd sync: powered=" + root._wifiPowered
                 + " wifiAvail=" + data.wifiAvailable
                 + " wifiConn=" + root.wifiConnected + " (" + root.activeWifiIf + ")"
                 + " ethConn=" + root.ethernetConnected);
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text && text.trim())
          Logger.w("Network", "iwd-helper status stderr: " + text.trim());
        root.ethernetDetailsLoading = false;
        root.wifiDetailsLoading = false;
      }
    }
  }

  // [2] Internet connectivity check
  Process {
    id: connectivityCheckProcess
    running: false
    command: ["iwd-helper", "connectivity"]

    stdout: StdioCollector {
      onStreamFinished: {
        const r = text.trim();
        if (!r) return;
        root._networkConnectivity = (r === "none") ? "unknown" : r;
        root._internetConnectivity = (r === "full");
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim())
          Logger.w("Network", "Connectivity check error: " + text);
      }
    }
  }

  // [3] Get existing saved profiles
  Process {
    id: profileCheckProcess
    running: false
    command: ["iwd-helper", "profiles"]

    stdout: StdioCollector {
      onStreamFinished: {
        let data;
        try { data = JSON.parse(text); }
        catch (e) {
          Logger.w("Network", "Profile parse error: " + e);
          if (root.scanningActive) {
            delayedScanTimer.interval = 5000;
            delayedScanTimer.restart();
          }
          return;
        }
        root.existingProfiles = data.profiles || {};
        scanProcess.running = true;
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text && text.trim()) {
          Logger.w("Network", "Profile check stderr: " + text.trim());
          if (root.scanningActive) {
            if (root.scanPending) {
              root.scanPending = false;
              delayedScanTimer.interval = 3000;
            } else {
              delayedScanTimer.interval = 5000;
            }
            delayedScanTimer.restart();
          }
        }
      }
    }
  }

  // [4] Scan for Wi-Fi networks
  Process {
    id: scanProcess
    running: false
    command: ["iwd-helper", "scan"]

    stdout: StdioCollector {
      onStreamFinished: {
        let data;
        try { data = JSON.parse(text); }
        catch (e) {
          Logger.w("Network", "Scan parse error: " + e);
          root.scanningActive = false;
          return;
        }

        const networksMap = data.networks || {};

        // Mark saved profiles
        for (let ssid in networksMap) {
          networksMap[ssid].existing = !!root.existingProfiles[ssid];
        }

        // Diff logging
        const oldSSIDs = Object.keys(root.networks);
        const newSSIDs = Object.keys(networksMap);
        const appeared = newSSIDs.filter(s => oldSSIDs.indexOf(s) === -1);
        const vanished = oldSSIDs.filter(s => newSSIDs.indexOf(s) === -1);

        root.networks = networksMap;

        if (appeared.length > 0)
          Logger.d("Network", "New: " + appeared.join(", "));
        if (vanished.length > 0)
          Logger.d("Network", "Gone: " + vanished.join(", "));

        if (Object.values(networksMap).some(n => n.connected)) {
          root.refreshActiveWifiDetails();
          connectivityCheckProcess.running = true;
        }

        if (root.scanPending) {
          root.scanPending = false;
          delayedScanTimer.interval = 100;
          delayedScanTimer.restart();
        }
        root.scanningActive = false;
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim()) {
          Logger.w("Network", "Scan error: " + text);
          if (root.scanPending) {
            root.scanPending = false;
            delayedScanTimer.interval = 3000;
          } else if (root.scanningActive) {
            delayedScanTimer.interval = 10000;
          }
          delayedScanTimer.restart();
        }
        root.scanningActive = false;
      }
    }
  }

  // [5] Connect to Wi-Fi network
  Process {
    id: connectProcess
    property string ssid: ""
    property string password: ""
    property bool isHidden: false
    running: false

    command: {
      var cmd = ["iwd-helper", "connect", ssid];
      if (password) cmd.push("--password", password);
      if (isHidden) cmd.push("--hidden");
      return cmd;
    }

    stdout: StdioCollector {
      onStreamFinished: {
        let data;
        try { data = JSON.parse(text); }
        catch (e) {
          root.connecting = false;
          root.connectingTo = "";
          root.lastError = I18n.tr("toast.wifi.connection-failed");
          return;
        }

        if (data.success) {
          root.wifiConnected = true;
          root.updateNetworkStatus(connectProcess.ssid, true);
          root.refreshActiveWifiDetails();
          root.connecting = false;
          root.connectingTo = "";
          Logger.i("Network", "Connected to: '" + connectProcess.ssid + "'");
          ToastService.showNotice(I18n.tr("common.wifi"),
            I18n.tr("toast.wifi.connected", { "ssid": connectProcess.ssid }),
            root.getIcon(false));
          delayedScanTimer.interval = 5000;
          delayedScanTimer.restart();
        } else {
          root.connecting = false;
          root.connectingTo = "";
          const err = data.error || "";
          if (err.indexOf("password") !== -1 || err.indexOf("Passphrase") !== -1)
            root.lastError = I18n.tr("toast.wifi.incorrect-password");
          else if (err.indexOf("not found") !== -1 || err.indexOf("No network") !== -1)
            root.lastError = I18n.tr("toast.wifi.network-not-found");
          else if (err.indexOf("imeout") !== -1)
            root.lastError = I18n.tr("toast.wifi.connection-timeout");
          else
            root.lastError = I18n.tr("toast.wifi.connection-failed");
          Logger.w("Network", "Connect error: " + err);
          ToastService.showWarning(I18n.tr("common.wifi"),
            root.lastError, "wifi-exclamation");
          root.wifiConnected = false;
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim()) {
          root.connecting = false;
          root.connectingTo = "";
          root.lastError = I18n.tr("toast.wifi.connection-failed");
          Logger.w("Network", "Connect stderr: " + text);
          ToastService.showWarning(I18n.tr("common.wifi"),
            root.lastError, "wifi-exclamation");
        }
      }
    }
  }

  // [6] Disconnect
  Process {
    id: disconnectProcess
    running: false
    command: ["iwd-helper", "disconnect"]

    stdout: StdioCollector {
      onStreamFinished: {
        Logger.i("Network", "Disconnected");
        root.wifiConnected = false;
        ToastService.showNotice(I18n.tr("common.wifi"),
          I18n.tr("toast.wifi.disconnected", { "ssid": root.disconnectingFrom }),
          "wifi-off");
        root.updateNetworkStatus(root.disconnectingFrom, false);
        root.disconnectingFrom = "";
        delayedScanTimer.interval = 3000;
        delayedScanTimer.restart();
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        root.disconnectingFrom = "";
        if (text.trim())
          Logger.w("Network", "Disconnect error: " + text);
        delayedScanTimer.interval = 5000;
        delayedScanTimer.restart();
      }
    }
  }

  // [7] Forget a saved network
  Process {
    id: forgetProcess
    property string ssid: ""
    running: false
    command: ["iwd-helper", "forget", ssid]

    stdout: StdioCollector {
      onStreamFinished: {
        Logger.i("Network", "Forget: \"" + forgetProcess.ssid + "\"");
        let nets = root.networks;
        if (nets[forgetProcess.ssid]) {
          nets[forgetProcess.ssid].existing = false;
          root.networks = ({});
          root.networks = nets;
        }
        root.forgettingNetwork = "";
        delayedScanTimer.interval = 5000;
        delayedScanTimer.restart();
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        root.forgettingNetwork = "";
        if (text.trim())
          Logger.w("Network", "Forget error: " + text);
        delayedScanTimer.interval = 5000;
        delayedScanTimer.restart();
      }
    }
  }

  // [8] Set wifi device powered on/off via iwd
  Process {
    id: iwdSetPoweredProcess
    property bool powered: true
    running: false
    command: ["iwd-helper", "set-powered", powered ? "true" : "false"]

    stdout: StdioCollector {
      onStreamFinished: {
        Logger.d("Network", "Set powered result: " + text.trim());
        // Refresh state from iwd after toggling
        deviceStatusProcess.running = true;
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.trim())
          Logger.w("Network", "Set powered error: " + text);
        // Still refresh in case partial success
        deviceStatusProcess.running = true;
      }
    }
  }

  // [9] Monitor iwd D-Bus signals for real-time state changes
  Process {
    id: networkMonitorProcess
    running: root.iwdAvailable
    command: ["dbus-monitor", "--system",
              "type='signal',sender='net.connman.iwd',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"]

    stdout: SplitParser {
      onRead: data => {
        if (data.indexOf("State") !== -1 || data.indexOf("Connected") !== -1
            || data.indexOf("Powered") !== -1) {
          Logger.d("Network", "iwd state changed");
          deviceStatusProcess.running = true;
          connectivityCheckProcess.running = true;
        }
      }
    }
  }
}
