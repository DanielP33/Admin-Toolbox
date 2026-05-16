# Admin-Toolbox

> One terminal. One keypress. No hunting.

Windows scatters its settings across a dozen different menus. SystemToolkit doesn't. Launch it and everything is a keypress away system specs, activation status, network adapters, power settings, and more, all from a clean terminal interface.

---

## What it does

### 🖥️ System Information

- Live system specs CPU, GPU, RAM, motherboard, and per-drive storage with **brand-aware color coding**: Intel in blue, AMD in red, NVIDIA in green
- Full spec report exportable to a `.txt` file on your desktop
- Uptime, IP address, hostname, domain, OS, and timezone pinned to **every screen**
- One-click shortcuts to common Windows panels: Computer Management, Event Viewer, Task Scheduler, Mouse Settings, and more

### 🔧 Windows Tweaks

- Toggle Bluetooth discoverability without touching Settings
- Export your current desktop wallpaper as a timestamped `.jpg`
- Delete PowerShell command history in one step
- Toggle wallpaper JPEG compression Windows silently degrades wallpapers by default; this stops that
- Switch between the Windows 11 context menu and the classic right-click menu
- Add or remove a Spicetify update shortcut to your desktop right-click menu
- View saved Wi-Fi passwords for all known networks

### 🟢 NVIDIA Tweaks

- Toggle the DLSS overlay indicator *(RTX GPUs only)*
- Switch between old and new NVIDIA Image Scaling (NIS) modes, with automatic detection of the correct registry path across driver versions
- Quick link to [NvidiaProfileInspector Revamped](https://github.com/Orbmu2k/nvidiaProfileInspector) releases

---

## Design decisions

**Startup cache** All static system info (GPU, OS, last boot time) is collected once at launch and cached. No redundant CIM calls on every menu refresh.

**Smart IP detection** Physical interfaces are prioritized automatically. Virtual adapters (VMware, VirtualBox, vEthernet) are filtered out without any configuration.

**Stays unprivileged** Elevated actions run in a separate process with `-Verb RunAs`. The main session never needs to be launched as administrator.

---

## Requirements


| Requirement | Details |
|---|---|
| **OS** | Windows 10 / 11 |
| **Shell** | PowerShell 5.1+ |
| **NVIDIA features** | NVIDIA GPU required |
| **DLSS overlay toggle** | RTX card required |

---

## Main look
<img width="1107" height="619" alt="image" src="https://github.com/user-attachments/assets/c0765b59-be4f-4123-adb4-73a41a3fe576" />

---

## Credits

Made by **Daniel P.** free to use, modify, and distribute with attribution.

If you build on this, a mention goes a long way. ⭐
