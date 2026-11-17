# Kukui Krane — what it is

**Krane = Lenovo IdeaPad Duet Chromebook (10.1" detachable 2-in-1)**
**Baseboard = `kukui` — SoC = MediaTek MT8183 / Kompanio 500**

This folder is your ARM experiment lab for Krane on Apple Silicon (arm64 Darwin).

## Hardware snapshot (for QEMU mapping)

| Krane real HW | Spec | QEMU `virt` equivalent in this lab |
|---|---|---|
| SoC | MT8183: 4x Cortex-A73 @ 2.0GHz + 4x Cortex-A53 @ 2.0GHz, big.LITTLE | `-cpu cortex-a72` (closest TCG model) or `-cpu host`/`max` with `-accel hvf` on M1/M2 (near-native ARM) |
| GPU | Mali-G72 MP3 → Panfrost, OpenGL ES 3.1 / GL 3.1 | `virtio-gpu-pci` + `display cocoa,gl=on` (virgl). No Panfrost in VM — use llvmpipe/virgl for UI tests |
| RAM | 4GB LPDDR4X | `-m 4096` |
| Storage | 64/128GB eMMC | `virtio-blk` raw/qcow2 image |
| Display | 10.1" 1920x1200 touch + stylus | QEMU cocoa/gtk window, USB tablet input |
| WiFi/BT | Qualcomm Atheros QCA6174A (ath10k, `LE_Krane` cal variant) + MT6358 audio | `virtio-net-pci` + usermode NAT (`-netdev user`). No ath10k passthrough in `virt` |
| Board DTB | `mt8183-kukui-krane-sku176.dts` → `compatible = "google,krane-sku176", "google,krane", "mediatek,mt8183"` | `virt` uses its own DTB (`-M virt` generates DTB internally). You **cannot** boot the Krane DTB in QEMU — no MT8183 machine model exists |
| Boot | Depthcharge (`deviceinfo_depthcharge_board="mt8183"`, `vmlinuz.kpart`) | QEMU boots via `-kernel` + `-initrd` (direct kernel) or EDK2 UEFI (`QEMU_EFI.fd`). No Depthcharge in VM |
| postmarketOS device | `google-kukui` (covers krane/kukui/kodama/juniper/etc, `deviceinfo_arch="aarch64"`, `deviceinfo_dtb="mediatek/mt8183-kukui*"`) | Lab VM uses `qemu-aarch64` device (`device-qemu-aarch64`), same arch `aarch64`, same pmOS release, same UI |

Sources: kernel `mt8183-kukui-krane-sku176.dts`, coreboot `BOARD_GOOGLE_KRANE`, pmOS `device-google-kukui/deviceinfo` (`depthcharge_board="mt8183"`), pmOS v26.06 (Kukui = community), VelvetOS Krane feature table.

## Important limitation — read this

> QEMU has **no MT8183 / Krane machine** (`qemu-system-aarch64 -M help` lists `virt`, `sbsa-ref`, NXP, Aspeed — no mediatek-kukui).
> A `google-kukui` (Krane) image therefore **will not boot in QEMU**, even on ARM.
> The supported experiment path is:
>
> 1. Download the real `google-kukui` image for flashing/analysis (real HW).
> 2. Build/run a `qemu-aarch64` pmOS image with the **same release + same UI + Krane package overlay** for app/dev experiments in QEMU with HVF acceleration.
>
> That is what `scripts/` does.
