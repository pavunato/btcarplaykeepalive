<div align="center">

# BT CarPlay KeepAlive

### Keep your Bluetooth tethering active while CarPlay is on.

A small, device-specific heartbeat for drivers who use a Bluetooth Personal Hotspot connection alongside CarPlay.

**Choose a device in Settings · Connect to CarPlay · Drive**

</div>

<div align="center">

[Download version 0.2.2](https://github.com/pavunato/btcarplaykeepalive/releases/download/v0.2.2/com.pavunato.btcarplaykeepalive_0.2.2_iphoneos-arm64.deb) · [Explore the product page](https://repopo.pages.dev/btcarplaykeepalive.html) · [View repopo](https://repopo.pages.dev/)

</div>

## Your connection, on your terms

CarPlay and Bluetooth tethering can share a drive, but an idle Bluetooth PAN connection may drop. BT CarPlay KeepAlive sends a tiny packet over the active PAN interface while CarPlay is in use and your chosen Bluetooth device is connected.

| | What you get |
| --- | --- |
| **Per-device control** | Enable the heartbeat from that device’s existing Bluetooth detail page. Other devices keep their own settings. |
| **CarPlay-aware activity** | Packets are sent only while a CarPlay scene and an enabled Bluetooth device are active. |
| **Visible status** | An optional CarPlay sidebar indicator shows green when a heartbeat was sent and red when it is inactive. |
| **No pairing changes** | The tweak does not pair, disconnect, or reconnect Bluetooth devices. |

### Turn it on

1. Open **Settings → Bluetooth** on your iPhone.
2. Tap **ⓘ** next to the Bluetooth device you use for tethering.
3. Under **CarPlay Connection**, enable **Stay Connected While CarPlay**.
4. Connect to CarPlay as usual.

The Bluetooth detail page also offers global controls to hide the native CarPlay Wi-Fi and cellular indicators or the tweak’s own hotspot indicator. Use **Respring to Apply CarPlay Visual Changes** after changing the visual settings.

## What happens during a drive

| CarPlay | Selected device | Heartbeat |
| --- | --- | --- |
| Active | Connected | A four-byte UDP packet is sent every five seconds on an active non-Wi-Fi `en*` interface. |
| Inactive | Connected | Off after CarPlay presence expires. |
| Active | Disconnected | Off. |
| Any state | Setting disabled | Off. |

Packets are bound to the interface so they cannot silently take the normal Wi-Fi or cellular route. This is a best-effort activity signal for an existing connection; it cannot force a disconnected device to reconnect or guarantee that a carrier or accessory keeps the link open.

## Compatibility

- Rootless jailbreak package for arm64 and arm64e.
- Built with a minimum iOS target of 15.0; the Bluetooth Settings integration was tested on an **iPhone 11 running iOS 18.5**.
- Uses private Settings and CarPlay UI classes. Other iOS versions may need updated hooks.

## Build from source

Install [Theos](https://theos.dev/) with an iOS SDK, then run:

```sh
THEOS=~/theos make package
```

The rootless `.deb` appears in `packages/`. Install it with your jailbreak package manager or over SSH, then reload SpringBoard and Settings. The tweak injects into `SpringBoard`, `Preferences`, and `CarPlayTemplateUIHost`.

Settings are stored per device at `/var/mobile/Library/Preferences/com.pavunato.btcarplaykeepalive.plist`. The keepalive uses only interface-bound UDP traffic; it does not hook Bluetooth daemons or call private reconnect methods.
