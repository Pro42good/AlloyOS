# QEMU `virt` vs real Krane — verified mapping

All Krane facts below were verified from the official image
`20260803-0403-postmarketOS-v25.12-phosh-25-google-kukui.img`
(sha256 `3165c349…04bdf`, decompressed 2.6GB).

## Official Krane image layout (real HW — does NOT boot in QEMU)

```
GPT:
 1  4–36MiB    pmOS_kernel  chromeos_kernel flag   # Depthcharge kpart
 2  36–548MiB  pmOS_boot    ext2, boot+esp         # /boot
 3  548–2710MiB pmOS_root   ext4                   # /
```

`/boot` contains: `vmlinuz`, `vmlinuz.kpart` (Depthcharge),
`initramfs`, `System.map`, `config` (**Linux/arm64 6.12.87**),
`dtbs/mediatek/mt8183-kukui-krane-sku0.dtb`,
`mt8183-kukui-krane-sku176.dtb` (= Lenovo IdeaPad Duet), plus the whole
kukui/jacuzzi family. `/usr/lib/os-release` → `postmarketOS v25.12`.

## What the experiment VM keeps / drops

| Layer | Krane real | `qemu-aarch64` VM | Verdict |
|---|---|---|---|
| Arch | aarch64 | aarch64 (HVF `host`, near-native) | same |
| Release/UI | pmOS v25.12 Phosh, systemd | pmOS edge Phosh, systemd (built from same pmaports) | same family |
| Kernel | `linux-postmarketos-mediatek-mt8183` 6.12.87 + Krane DTB | `device-qemu-aarch64-kernel-stable` + `virt` DTB | different (must be) |
| GPU | Mali-G72 MP3 / Panfrost | `virtio-gpu-pci` (virgl/llvmpipe) | emulate approx |
| Net/audio/input | ath10k `LE_Krane`, MT6358, HID-over-I2C touch | `virtio-net-pci`, HDA, USB tablet/kbd | virtio substitutes |
| Boot | Depthcharge `vmlinuz.kpart` | EDK2 UEFI (`edk2-aarch64-code.fd` from brew) or `-kernel` direct | different loader |
| CPU | 4×A73 + 4×A53 MT8183 | `-cpu host` (M-series, HVF); TCG fallback `-cpu cortex-a72` | closest available |

## Practical consequences

- ✅ App/dev/UI experiments, packaging, `apk`, systemd services, networking,
  SSH (`localhost:2222`) — all representative.
- ❌ Driver work (Panfrost quirks, ath10k calibration, MT6358 audio,
  Depthcharge boot, touchscreen firmware) — needs real Krane HW; flash the
  official image from `images/krane-kukui.img`.
- The `google-kukui` image was inspected with `parted` + `e2tools` (no loop
  mounts needed) — see `scripts/download-kukui.sh`.
