# QEMU integration suite

```sh
./tests/qemu/run-suite.sh
```

The runner:

1. builds the fixture if needed;
2. copies a fresh fixture disk per scenario;
3. sets the test-data scenario name with `debugfs`;
4. boots QEMU repeatedly until the guest logs `DURANIUM_TEST:DONE` or
   `DURANIUM_TEST:FAIL`;
5. optionally corrupts a slot when the guest requests it.

Scenarios:

- `acceptance` — clean A, install B, pending boots, mark-good, update A,
  STATE survival, corrupt B root, three-attempt rollback.
- `failures` — bad payload/manifest/key, wrong profile/arch/hardware,
  injected write/read-back failures, power loss.
- `recovery-both` — both normal slots corrupted before boot.
- `recovery-a` — A corrupted, B not bootable.
- `recovery-mixed` — B broken but A boots; A then corrupted; recovery.
- `corrupt-boot` — B kernel destroyed; systemd-boot counting falls back.

Run a subset:

```sh
DURANIUM_QEMU_SCENARIOS="recovery-mixed corrupt-boot" ./tests/qemu/run-suite.sh
```

Logs and per-boot NVRAM are under
`qemu/out/runs/<timestamp>/<scenario>/`. See
`../docs/10-QEMU-INTEGRATION.md` for the fixture layout and gotchas.
