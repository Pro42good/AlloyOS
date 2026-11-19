#!/bin/sh
# Dev/lab/prod image identity enforcement at update installation time.

set -u
UNIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$UNIT_DIR/lib.sh"

test_init profiles
make_key
assert_eq "boot GOOD A" "A" "$(sim_boot)"

make_artifact "$T/art-dev" 1.0 D-v2 dev
make_artifact "$T/art-lab" 1.0 L-v2 lab
make_artifact "$T/art-prod" 1.0 P-v2 prod

assert_fail "prod rejects lab update" \
    dk_env "DURANIUM_PROFILE=prod DURANIUM_DEV_OVERRIDE=0" update install "$T/art-lab"
assert_fail "prod rejects dev update" \
    dk_env "DURANIUM_PROFILE=prod DURANIUM_DEV_OVERRIDE=0" update install "$T/art-dev"
assert_fail "prod cannot use development override" \
    dk_env "DURANIUM_PROFILE=prod DURANIUM_DEV_OVERRIDE=1" update install "$T/art-lab" --allow-profile-mismatch
assert_ok "prod accepts prod update" \
    dk_env "DURANIUM_PROFILE=prod DURANIUM_DEV_OVERRIDE=0" update install "$T/art-prod"

test_init profiles-dev
make_key
assert_eq "boot GOOD A (dev)" "A" "$(sim_boot)"
make_artifact "$T/art-lab" 1.0 L-v2 lab
assert_fail "dev rejects lab without override" \
    dk_env "DURANIUM_PROFILE=dev DURANIUM_DEV_OVERRIDE=1" update install "$T/art-lab"
assert_ok "dev accepts lab with explicit override" \
    dk_env "DURANIUM_PROFILE=dev DURANIUM_DEV_OVERRIDE=1" update install "$T/art-lab" --allow-profile-mismatch

test_init profiles-arch
make_key
assert_eq "boot GOOD A (arch)" "A" "$(sim_boot)"
make_artifact "$T/art-arch" 1.0 X-v2 dev x86_64
assert_fail "architecture mismatch fails update" dk update install "$T/art-arch"

test_init profiles-hardware
make_key
assert_eq "boot GOOD A (hardware)" "A" "$(sim_boot)"
make_artifact "$T/art-hw" 1.0 H-v2 dev aarch64 krane-mt8183
assert_fail "hardware target mismatch fails update" dk update install "$T/art-hw"

test_done
