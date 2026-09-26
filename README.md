# BT CarPlay KeepAlive

BT CarPlay KeepAlive is a standalone rootless jailbreak tweak. It adds a per-device switch to the existing Bluetooth accessory detail page in Settings:

> **Bluetooth → [device] → Stay Connected While CarPlay**

When the switch is enabled, the tweak checks the live Bluetooth device list and the live CarPlay scene state in SpringBoard. While CarPlay is active and the selected device is connected, it sends a four-byte UDP discard packet on each active non-Wi-Fi `en*` interface. The socket is explicitly bound to the interface, so the packet is not allowed to fall back to the ordinary cellular or Wi-Fi default route.

The setting is stored in `/var/mobile/Library/Preferences/com.pavunato.btcarplaykeepalive.plist` under a stable device key derived first from `BluetoothDevice -identifier`, then `-address`, then `-aclUID`. All known keys for a device are removed when it is disabled. The two visual switches are explicitly global. The tweak does not alter pairing state, invoke reconnect, or keep the link alive outside an active CarPlay scene.

## Build

Install Theos with an iOS SDK, then build from this directory:

From this directory, run:

```sh
THEOS=~/theos make package
```

The output package is rootless and targets arm64 plus arm64e. It is injected into `SpringBoard`, `Preferences`, and `CarPlayTemplateUIHost`.

## Runtime verification

The Bluetooth device page uses `BTSDeviceConfigController` on the tested iPhone 11 running iOS 18.5. If adapting this tweak to another iOS version, verify the controller and Bluetooth device selectors before installing.

The current implementation guards private selectors, device accessors, and network-interface boundaries. The packet transport is intentionally conservative: it avoids global Bluetooth daemon hooks and does not attempt to call private reconnect methods. CarPlay presence uses a short lease, so a missed host teardown expires automatically.

## Release check

1. Confirm CarPlay connects with the tweak installed and disabled.
2. Enable one device, connect CarPlay, and verify one interface-bound packet every five seconds.
3. Disconnect CarPlay and confirm packets stop within the 15-second presence lease plus one timer interval.
4. Disable the device and confirm packets stop immediately on the next tick.
