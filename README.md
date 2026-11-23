# AIC8800D80 PCIe driver for Linux (Wi-Fi + Bluetooth)

Out-of-tree driver for **AICSemi AIC8800D80 PCIe Wi-Fi 6 / Bluetooth 5.4 combo cards**
(Ugreen CM958 and similar), patched to build and run on recent CachyOS / Arch kernels
(6.18 LTS and 7.3.x), with **working suspend/resume** and **DKMS packaging**.

This is a fork of [rzou89/aic8800d80-linux73-fix](https://github.com/rzou89/aic8800d80-linux73-fix),
which in turn builds on the vendor driver (v6.4.3.0). The driver source is GPL-2.0;
see [LICENSE](LICENSE).

> **Read the [Known issues](#known-issues) section before using this.**
> In particular: **never unload the module** (`modprobe -r` / `rmmod`). It can crash the kernel.

## Status

Tested on one machine (see [What was tested](#what-was-tested)). Your hardware may differ.

| Feature | Status |
| :-- | :-- |
| Wi-Fi (PCIe, `a69c:8d80`) | Works on 2.4 GHz and 5 GHz |
| Bluetooth (USB, `a69c:8d84`) | Works through the stock kernel `btusb` driver |
| Suspend / resume (`deep`) | Works after the fixes below, on all three tested kernels |
| WPA2 | Works |
| WPA3-only (SAE) | **Rejected by the driver in testing**, see [Known issues](#known-issues) |
| Module unload | **Broken, can kernel panic**, see [Known issues](#known-issues) |
| Hibernate, AP mode, monitor mode, P2P | Not tested |

## How the card shows up

The card has two halves that appear as different devices:

| Part | Bus | ID | Notes |
| :-- | :-- | :-- | :-- |
| Wi-Fi | PCIe x1 | `a69c:8d80` | Single 64 KiB BAR (`bar_count = 1`) |
| Bluetooth | USB (internal) | `a69c:8d84` | `lsusb` says `AIC Wlan` until the Wi-Fi driver uploads the Bluetooth firmware, then re-enumerates as `AIC 8800D80` |

The Wi-Fi driver (`aic8800D80_fdrv`) uploads firmware for **both** halves. Bluetooth only
appears after the Wi-Fi driver has loaded.

## Installation (CachyOS / Arch, Limine or any bootloader)

### 1. Dependencies

```bash
sudo pacman -S --needed base-devel git dkms linux-cachyos-headers
# plus headers for every other kernel you use, e.g. linux-cachyos-lts-headers
```

Kernels built with clang (the CachyOS default) also need `clang`, `llvm` and `lld`.
`dkms/dkms-make.sh` detects at build time whether a kernel was built with clang and adds
`LLVM=1` itself. Building a clang-built kernel's modules with gcc fails with errors such as
`unrecognized command-line option '-fms-anonymous-structs'`.

### 2. Firmware

The firmware is **not included** in this repository because the vendor's redistribution
terms are unclear. Get the vendor Linux package for the AX900 card and copy the D80 firmware:

```bash
unzip AIC-AX900-BT5.4_Linux_Driver_V1.1.zip -d aic-vendor
sudo mkdir -p /lib/firmware/aic8800D80
sudo cp aic-vendor/WiFi/aic8800_linux_drvier/fw/aic8800D80/* /lib/firmware/aic8800D80/
ls /lib/firmware/aic8800D80        # should list 11 files
```

The package was found at `https://www.lulian.cn/download/377.html`.
The Ugreen CM958 zip that the AUR package `aic8800d80-pcie-dkms` downloads returned HTTP 403
during testing.

### 3. Kernel parameters (required)

Add `pcie_port_pm=off pcie_aspm=off` to the kernel command line.

Without them, the card does not answer on the PCIe bus: every register read returns
`ffffffff`, the driver logs `aicpcie: FAILED TEST: aic_pcie_test_accs_emb -1`, and probing
fails with error -1. With them it works. It was not tested which of the two parameters is
the necessary one.

Limine:

```bash
echo 'KERNEL_CMDLINE[default]+=" pcie_port_pm=off pcie_aspm=off"' | sudo tee -a /etc/default/limine
sudo limine-update
```

Other bootloaders: add the parameters to your usual kernel command line (for GRUB,
`GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `sudo grub-mkconfig -o /boot/grub/grub.cfg`).

Reboot and check with `cat /proc/cmdline`.

### 4. Build and install with DKMS

```bash
sudo dkms/install.sh
dkms status
```

This copies `source/aic8800_fdrv` to `/usr/src/aic8800d80-pcie-<version>` and builds and
installs the module for the running kernel. DKMS builds it automatically for other installed
kernels with headers, and again after kernel updates (`AUTOINSTALL="yes"`). To build for a
specific kernel by hand:

```bash
sudo dkms install -m aic8800d80-pcie -v 6.4.3.0-local1 -k <kernel version>
```

After you change the driver source, run `sudo dkms/install.sh` again (it removes the old copy
first). A freshly installed module only takes effect after a **reboot**; do not try to reload
it by unloading (see [Known issues](#known-issues)).

The module has a PCI alias table, so udev should load it at boot. If it does not, add
`aic8800D80_fdrv` to `/etc/modules-load.d/aic.conf`.

**Secure Boot:** DKMS signs the module with its own key (`/var/lib/dkms/mok.pub`). With
Secure Boot enabled you would need to enrol that key with `mokutil --import`. This was not
tested: Secure Boot was disabled on the test machine.

### 5. Manual build (without DKMS)

```bash
cd source/aic8800_fdrv
make LLVM=1 -j"$(nproc)"      # drop LLVM=1 if your kernel was built with gcc
```

### 6. Verify

```bash
dkms status
lspci -nnk | grep -i -A3 a69c       # should show "Kernel driver in use: aic8800D80_fdrv"
nmcli device status | grep wlan0
bluetoothctl list
```

## Changes in this fork

Compared with the upstream fix repository:

1. **Resume: skip an out-of-bounds read on single-BAR boards.**
   `aicwf_pcie_resume()` checks whether the firmware survived by reading `BAR0 + 0x120000`.
   That offset only exists on boards with a large BAR0. This card has a single 64 KiB BAR, so the
   read landed outside the mapping and faulted inside the resume callback. The fault left the
   system hung on wake (fans spinning, no video). The kernel's `pm_trace` pointed at the PCI
   device `0000:04:00.0`, which is how it was found. For `bar_count == 1` the driver now assumes
   the firmware is gone and takes its normal reload path.

2. **Resume: reload the firmware after userspace is back, not inside the resume callback.**
   With fix 1, the reload ran inside the resume callback and failed with
   `file failed to open` for the firmware files, because the root filesystem is not readable that
   early in resume (the driver opens the files by path, `CONFIG_USE_FW_REQUEST = n`). Resume
   then returned `-1` and left both Wi-Fi and Bluetooth dead after waking. The reload now runs
   from a PM notifier (`PM_POST_SUSPEND` / `PM_POST_HIBERNATION`), after processes are thawed.
   Wi-Fi and Bluetooth come back on their own right after waking.

3. **DKMS packaging** (`dkms/`): `dkms.conf`, a build wrapper that picks clang or gcc to match
   the target kernel, and an install script.

Inherited from upstream and already in `source/aic8800_fdrv`: `cfg80211` API compatibility for
kernels 7.1 to 7.3 (guarded with `LINUX_VERSION_CODE`, so older kernels still build), and
`CONFIG_USB_BT = y` so that the driver uploads the Bluetooth firmware.

### Upstream files in `patches/`, `scripts/`, `docs/`, `config/`

These are from upstream and were **not used or validated** in this fork. Notes:

- `scripts/install.sh` builds the AUR package, whose source URL returned HTTP 403 during testing.
  This fork builds from `source/` instead.
- `patches/fix-wakelock-hang.patch` comments out `__pm_stay_awake`, but that code sits inside
  `#ifdef CONFIG_WS` and the Makefile has `CONFIG_WS = n`, so it does nothing in this build.
- `docs/TROUBLESHOOTING.md` recommends a systemd sleep hook that runs `modprobe -r` before sleep.
  **Do not use it**, for the reason in the next section. The resume fixes above make it
  unnecessary.
- `config/blacklist-modules.conf` blacklists the vendor `aic_load_fw` and `aic_btusb` modules.
  This fork never built those modules, so no blacklist was needed.
- The `docs/` files and the notes on power drains are in Indonesian and were not rechecked.

## What was tested

Machine: Gigabyte B550 GAMING X V2, card in a PCIe x1 slot, CachyOS, Plasma Desktop, NetworkManager,
Limine bootloader, Secure Boot disabled.

| Kernel | Built with | DKMS build | Wi-Fi + Bluetooth | Suspend / resume |
| :-- | :-- | :-- | :-- | :-- |
| 7.3.5-2-cachyos | clang | Works | Works | Works: repeated short sleeps and an extended sleep |
| 7.3.5-2-cachyos-eevdf-lto | not checked | Works | Works | Works: short sleeps |
| 6.18.60-3-cachyos-lts | gcc | Works | Works | Works: short sleeps |

Details:

- Suspend was tested in the default `deep` mode (`/sys/power/mem_sleep`). `s2idle` was tried
  only with earlier builds, hung, and was not retested after the final fix.
- Extended sleep (tens of minutes) was tested only on `7.3.5-2-cachyos`. The other two kernels
  were tested with short sleeps.
- On all three kernels, after waking, Wi-Fi reconnects to its network and Bluetooth is available
  again, without any manual step.
- Wi-Fi was tested on both 2.4 GHz and 5 GHz, on all three kernels. See
  [Known issues](#known-issues) for WPA3.
- Bluetooth was tested on all three kernels, after resuming from sleep: the controller appears
  and pairing and connecting a phone work.
- Not tested: access-point mode, monitor mode, P2P, 6 GHz, throughput.
  The upstream README claims 390 Mbit/s VHT; that was not measured here but given my past experience with this card that's about the speed it can reach.
- Normal reboots and shutdowns never showed a problem.

## Known issues

### Unloading the module can crash the kernel

`modprobe -r aic8800D80_fdrv` (or `rmmod`) will cause a kernel panic, typically on the second attempt:

```
BUG: unable to handle page fault for address: ffffcd0c043f221c
RIP: 0010:rwnx_task+0x46/0xa70 [aic8800D80_fdrv]
Call Trace: tasklet_action_common ... run_ksoftirqd
Kernel panic - not syncing: Fatal exception in interrupt
```

It happens right after `aicwf_pcie_remove`, from the driver's RX tasklet (`rwnx_task`), which reads
a register of the card through a mapping that no longer exists.

Observed on 7.3.5-2-cachyos, in 6 unload attempts, **3 panicked and 3 succeeded**:

- Unloading a driver that had been loaded at boot, with the Wi-Fi radio turned off first, succeeded
  3 times.
- Unloading with Wi-Fi connected panicked once.
- Unloading a driver that had already been unloaded and reloaded once panicked both times it was tried.

The cause is **not confirmed**. A plausible one, from reading the code: `aicwf_pcie_unregister_drv()`
frees the main driver structure (`rwnx_platform_deinit()` ending in `wiphy_free()`) before
`pci_unregister_driver()` reaches `aicwf_pcie_remove()`, which is where the interrupt is freed.
An interrupt arriving in between can queue the tasklet on freed memory.

One attempted fix, calling `disable_irq()` before `tasklet_kill()` in `rwnx_platform_off()`,
**did not stop the panic** and was dropped.

What follows from this:

- Do not unload the module. Reboot to load a new build.
- Do not use a suspend hook that unloads and reloads the module, such as the one shipped by the
  AUR package (`aic8800d80-sleep-hook`) or suggested in the upstream docs. It would panic on some
  suspends. It is not needed with the resume fixes above.
- DKMS installs, and reinstalls, replace the file on disk and never unload the running module.

Fixes are welcome.

### WPA3-only networks

Connecting with a WPA3-only (SAE) profile failed during testing: the association was rejected with
`status_code=53` and BSSID `00:00:00:00:00:00`. A WPA2 profile connected fine, and the GUI's later
default profile also connected, though it is unknown which security mode it negotiated. The driver does
register the `external_auth` callback and sets the SAE feature flag, so the cause was not found. If a
network refuses to connect, force WPA2 on the connection:

```bash
nmcli connection modify "<ssid>" wifi-sec.key-mgmt wpa-psk wifi-sec.pmf 1
```

### Smaller notes

- **Bluetooth during sleep.** The Bluetooth controller can stay visible to other devices while the PC is
  asleep but will not connect until the PC wakes. This is probably just the USB device staying powered
  while the host is frozen; it was not investigated.
- **Kernel taint and log noise.** The module is out-of-tree, so the kernel is marked tainted. The driver also prints very verbose `AICWFDBG(LOGTRACE)` lines
  to the kernel log. Filter them with `dmesg | grep -v LOGTRACE`.
- **Upstream notes** recommend a full power drain (unplugging the PSU for 30 seconds) after installing.
  It was not needed in this fork's testing.

## Troubleshooting

**No `wlan0` after a kernel update.** The module has to be rebuilt for the new kernel. With DKMS this
happens automatically if that kernel's headers are installed. Check `dkms status`, install the headers
for the new kernel, and run `sudo dkms autoinstall -k <kernel version>`.

**Driver loads but probing fails with `FAILED TEST: aic_pcie_test_accs_emb`.** The kernel
parameters from step 3 are missing. Check `cat /proc/cmdline`.

**Firmware errors in `dmesg` (`file failed to open`).** The firmware files are missing or in the wrong
folder. They must be in `/lib/firmware/aic8800D80/`.

**No Bluetooth controller.** Run `lsusb | grep -i aic`. If it still says `AIC Wlan`, the Wi-Fi driver has
not uploaded the Bluetooth firmware, so check that the driver loaded and the firmware files are in place.

**Finding which device hangs a suspend.** The kernel's `pm_trace` records the device that was running
when the machine hung. Run `echo 1 | sudo tee /sys/power/pm_trace`, suspend, force the machine off when it
hangs, reboot, and then run `sudo dmesg | grep -i -B2 -A12 "magic number"` immediately. It scrambles the
hardware clock, so turn it off again with `echo 0 | sudo tee /sys/power/pm_trace`.

## Repository layout

| Path | Contents |
| :-- | :-- |
| `source/aic8800_fdrv/` | Driver source, with this fork's changes applied |
| `dkms/` | DKMS config, build wrapper and install script |
| `patches/`, `scripts/`, `docs/`, `config/` | From upstream, see the notes above |

## License

GPL-2.0, see [LICENSE](LICENSE). The firmware files are the vendor's and are not part of this repository.
