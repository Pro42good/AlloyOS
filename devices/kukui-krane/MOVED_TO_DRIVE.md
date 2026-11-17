# VM images moved to Google Drive

On 2026-09-28, the large VM disk images in this repo were moved off local
disk to free up space:

- `baselines/`  (5.3G)
- `images/`     (2.9G)
- `alloy/`      (2.6G)

New location:
`Google Drive/My Drive/Mac-Storage-Archive/Kukui-krane-vm-images/`

Symlinks were left in place at the original paths (`baselines`, `images`,
`alloy`) so tooling/scripts referencing these paths still resolve. Google
Drive for desktop streams file content on demand, so the first read of a
`.qcow2` will trigger a download and may be slow — if you're about to run
a VM that reads these heavily, open Google Drive and let it fully
materialize the file first (right-click > "Available offline") rather
than reading it live over the stream.

These images are NOT git-tracked, so this move has no effect on git
history or `.git/`.
