# apk signing keys — provenance

SECURITY_AUDIT_2026-09-09 (Informational): these are **public** APK signing
keys, not secrets. They pin the trust anchors for reproducible offline-ish
Core builds (`build-core.sh` copies them into `/etc/apk/keys/`).

## Provenance

- Extracted 2026-09-08 from the pmbootstrap native chroot
  (`pmb-kukui-lab:/home/pmos/pmwork/chroot_native/etc/apk/keys/`), which
  cloned pmaports at pmbootstrap 3.11.1 / edge, channel `systemd-edge`.
- Contents: 19 keys — 18 × `alpine-devel@lists.alpinelinux.org-*.rsa.pub`
  (Alpine historic + current signers) + 1 × `build.postmarketos.org.rsa.pub`
  (postmarketOS package signer).

## Rotation

Edge rotates keys over time; if `apk update` reports UNTRUSTED signatures
during a build, refresh this directory from a fresh pmbootstrap chroot and
commit the new keyset with a note here. Old keys should be *added to*, not
removed from, this directory (packages built against them must stay
verifiable).

## Fingerprints (2026-09-08 extraction)

9c102bcc376af1498d549b77bdbfa815ae86faa1d2d82f040e616b18ef2df2d4  alloy/keys/alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub
ebf31683b56410ecc4c00acd9f6e2839e237a3b62b5ae7ef686705c7ba0396a9  alloy/keys/alpine-devel@lists.alpinelinux.org-5243ef4b.rsa.pub
1bb2a846c0ea4ca9d0e7862f970863857fc33c32f5506098c636a62a726a847b  alloy/keys/alpine-devel@lists.alpinelinux.org-524d27bb.rsa.pub
12f899e55a7691225603d6fb3324940fc51cd7f133e7ead788663c2b7eecb00c  alloy/keys/alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub
73867d92083f2f8ab899a26ccda7ef63dfaa0032a938620eda605558958a8041  alloy/keys/alpine-devel@lists.alpinelinux.org-58199dcc.rsa.pub
9a4cd858d9710963848e6d5f555325dc199d1c952b01cf6e64da2c15deedbd97  alloy/keys/alpine-devel@lists.alpinelinux.org-58cbb476.rsa.pub
780b3ed41786772cbc7b68136546fa3f897f28a23b30c72dde6225319c44cfff  alloy/keys/alpine-devel@lists.alpinelinux.org-58e4f17d.rsa.pub
59c01c57b446633249f67c04b115dd6787f4378f183dff2bbf65406df93f176d  alloy/keys/alpine-devel@lists.alpinelinux.org-5e69ca50.rsa.pub
db0b49163f07ffba64a5ca198bcf1688610b0bd1f0d8d5afeaf78559d73f2278  alloy/keys/alpine-devel@lists.alpinelinux.org-60ac2099.rsa.pub
207e4696d3c05f7cb05966aee557307151f1f00217af4143c1bcaf33b8df733f  alloy/keys/alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub
128d34d4aec39b0daedea8163cd8dc24dff36fd3d848630ab97eeb1d3084bbb3  alloy/keys/alpine-devel@lists.alpinelinux.org-61666e3f.rsa.pub
10877cce0a935e46ad88cb79e174a2491680508eccda08e92bf04fb9bf37fbc1  alloy/keys/alpine-devel@lists.alpinelinux.org-616a9724.rsa.pub
4a095a9daca86da496a3cd9adcd95ee2197fdbeb84638656d469f05a4d740751  alloy/keys/alpine-devel@lists.alpinelinux.org-616abc23.rsa.pub
0caf5662fde45616d88cfd7021b7bda269a2fcaf311e51c48945a967a609ec0b  alloy/keys/alpine-devel@lists.alpinelinux.org-616ac3bc.rsa.pub
ebe717d228555aa58133c202314a451f81e71f174781fd7ff8d8970d6cfa60da  alloy/keys/alpine-devel@lists.alpinelinux.org-616adfeb.rsa.pub
d11f6b21c61b4274e182eb888883a8ba8acdbf820dcc7a6d82a7d9fc2fd2836d  alloy/keys/alpine-devel@lists.alpinelinux.org-616ae350.rsa.pub
40a216cbd163f22e5f16a9e0929de7cde221b9cbae8e36aa368b1e128afe0a31  alloy/keys/alpine-devel@lists.alpinelinux.org-616db30d.rsa.pub
7cf4cb8314e6ccc985b0d7f1aa0c6e0a81e3588f69a41f383af7a63d1ba61793  alloy/keys/alpine-devel@lists.alpinelinux.org-66ba20fe.rsa.pub
b70e6ffc64a652d63aee0c28cb9ecb2ca3b49d759ca7a023bcb854d08780964b  alloy/keys/build.postmarketos.org.rsa.pub
