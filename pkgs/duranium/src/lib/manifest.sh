#!/bin/sh
# Versioned update manifest and Ed25519 verification.
#
# SHA-256 is used for payload hashing; Ed25519 (OpenSSL) for signatures.
# No custom cryptography is implemented.
#
# Artifact directory:
#   manifest.txt       canonical key=value manifest (signed bytes)
#   manifest.sig       base64 of the raw Ed25519 signature over manifest.txt
#   system.img         root filesystem image (or system.img.gz)
#   boot/vmlinuz       slot kernel
#   boot/initramfs     slot initramfs
#
# Trusted public keys live in $DURANIUM_KEYS_DIR/<key_id>.pub.

MANIFEST_FIELDS="duranium_manifest format_version alloy_version build_id architecture profile hardware_target system_image system_image_size system_image_sha256 system_image_compression boot_kernel boot_kernel_sha256 boot_initramfs boot_initramfs_sha256 state_schema_required state_schema_backward_compatible rollback_compatible key_id created_at"

manifest_render_prefix() {
    local _k _p
    _p=$1
    for _k in $MANIFEST_FIELDS; do
        eval "printf '%s=%s\n' \"$_k\" \"\${${_p}_${_k}-}\""
    done
}

manifest_parse_file() {
    local _cr _expect _file _k _key _line _value
    _file=$1
    MF_BODY=""
    MF_BODY_NO_NL=""
    MF_SEEN=""
    for _k in $MANIFEST_FIELDS; do
        eval "MF_$_k=''"
    done
    [ -r "$_file" ] || return 1
    _cr=$(printf '\r')
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            *"$_cr"*) return 1 ;;
            *=*) ;;
            *) return 1 ;;
        esac
        _key=${_line%%=*}
        _value=${_line#*=}
        case "$_key" in
            ''|[0-9]*|*[!a-z0-9_]*) return 1 ;;
        esac
        case " $MF_SEEN " in
            *" $_key "*) return 1 ;;
        esac
        MF_SEEN="$MF_SEEN $_key"
        case " $MANIFEST_FIELDS " in
            *" $_key "*) ;;
            *) return 1 ;;
        esac
        meta_value_ok "$_value" || return 1
        eval "MF_$_key=\$_value"
        MF_BODY="${MF_BODY}${_line}
"
    done < "$_file"
    [ -n "$MF_BODY" ] || return 1
    MF_BODY_NO_NL=${MF_BODY%?}
    _expect=$(manifest_render_prefix MF) || return 1
    [ "$_expect" = "$MF_BODY_NO_NL" ] || return 1
    [ "$MF_duranium_manifest" = "1" ] || return 1
    [ "$MF_format_version" = "1" ] || return 1
    return 0
}

manifest_value_ok_path() {
    case "${1:-}" in
        ''|/*|*..*|*'//'*|*' '*) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    return 0
}

manifest_validate() {
    case "$MF_profile" in dev|lab|prod) ;; *) return 1 ;; esac
    [ -n "$MF_alloy_version" ] || return 1
    [ -n "$MF_build_id" ] || return 1
    [ -n "$MF_architecture" ] || return 1
    [ -n "$MF_hardware_target" ] || return 1
    manifest_value_ok_path "$MF_system_image" || return 1
    dur_is_uint "$MF_system_image_size" || return 1
    [ "$MF_system_image_size" -gt 0 ] || return 1
    dur_is_hex64 "$MF_system_image_sha256" || return 1
    case "$MF_system_image_compression" in
        none|gzip) ;;
        *) return 1 ;;
    esac
    manifest_value_ok_path "$MF_boot_kernel" || return 1
    manifest_value_ok_path "$MF_boot_initramfs" || return 1
    dur_is_hex64 "$MF_boot_kernel_sha256" || return 1
    dur_is_hex64 "$MF_boot_initramfs_sha256" || return 1
    dur_is_uint "$MF_state_schema_required" || return 1
    [ "$MF_state_schema_required" -ge 1 ] || return 1
    case "$MF_state_schema_backward_compatible" in 0|1) ;; *) return 1 ;; esac
    case "$MF_rollback_compatible" in 0|1) ;; *) return 1 ;; esac
    dur_is_safe_id "$MF_key_id" || return 1
    [ -n "$MF_created_at" ] || return 1
    return 0
}

manifest_load() {
    local _file
    _file=$1
    manifest_parse_file "$_file" || {
        DURANIUM_LAST_ERROR="manifest is missing, non-canonical, or malformed"
        return 1
    }
    manifest_validate || {
        DURANIUM_LAST_ERROR="manifest field values are invalid"
        return 1
    }
    return 0
}

manifest_signature_verify() {
    local _dir _key _manifest _sig _sigb64
    _dir=$1
    _manifest="$_dir/manifest.txt"
    _sigb64="$_dir/manifest.sig"
    _key="$DURANIUM_KEYS_DIR/$MF_key_id.pub"
    dur_is_safe_id "$MF_key_id" || return 1
    [ -r "$_manifest" ] || { DURANIUM_LAST_ERROR="missing manifest.txt"; return 1; }
    [ -r "$_sigb64" ] || { DURANIUM_LAST_ERROR="missing manifest.sig"; return 1; }
    [ -r "$_key" ] || { DURANIUM_LAST_ERROR="untrusted signing key: $MF_key_id"; return 1; }
    _sig="$DURANIUM_TMP/manifest.sig.$$"
    base64 -d < "$_sigb64" > "$_sig" 2>/dev/null || {
        rm -f "$_sig"
        DURANIUM_LAST_ERROR="manifest.sig is not valid base64"
        return 1
    }
    [ -s "$_sig" ] || {
        rm -f "$_sig"
        DURANIUM_LAST_ERROR="manifest.sig is empty"
        return 1
    }
    if ! openssl pkeyutl -verify -rawin -pubin -inkey "$_key" -in "$_manifest" -sigfile "$_sig" >/dev/null 2>&1; then
        rm -f "$_sig"
        DURANIUM_LAST_ERROR="manifest signature verification failed"
        return 1
    fi
    rm -f "$_sig"
    return 0
}

manifest_hash_payload() {
    local _dec_size _dir _hash _path _size _tmp
    _dir=$1
    _path="$_dir/$MF_system_image"
    [ -f "$_path" ] && [ ! -L "$_path" ] || {
        DURANIUM_LAST_ERROR="missing system image payload: $MF_system_image"
        return 1
    }
    _size=$(wc -c < "$_path" | tr -d ' ')
    case "$MF_system_image_compression" in
        none)
            [ "$_size" = "$MF_system_image_size" ] || {
                DURANIUM_LAST_ERROR="system image size mismatch"
                return 1
            }
            _hash=$(dur_sha256_file "$_path") || return 1
            ;;
        gzip)
            command -v gzip >/dev/null 2>&1 || { DURANIUM_LAST_ERROR="gzip unavailable"; return 1; }
            _tmp="$DURANIUM_TMP/system.img.$$"
            gzip -dc "$_path" > "$_tmp" || { rm -f "$_tmp"; DURANIUM_LAST_ERROR="gzip decompression failed"; return 1; }
            _dec_size=$(wc -c < "$_tmp" | tr -d ' ')
            if [ "$_dec_size" != "$MF_system_image_size" ]; then
                rm -f "$_tmp"
                DURANIUM_LAST_ERROR="decompressed system image size mismatch"
                return 1
            fi
            _hash=$(dur_sha256_file "$_tmp") || { rm -f "$_tmp"; return 1; }
            rm -f "$_tmp"
            ;;
    esac
    [ "$_hash" = "$MF_system_image_sha256" ] || {
        DURANIUM_LAST_ERROR="system image SHA-256 mismatch"
        return 1
    }
    return 0
}

manifest_hash_boot() {
    local _dir _ih _ip _kh _kp
    _dir=$1
    _kp="$_dir/$MF_boot_kernel"
    _ip="$_dir/$MF_boot_initramfs"
    [ -f "$_kp" ] && [ ! -L "$_kp" ] || { DURANIUM_LAST_ERROR="missing boot kernel"; return 1; }
    [ -f "$_ip" ] && [ ! -L "$_ip" ] || { DURANIUM_LAST_ERROR="missing boot initramfs"; return 1; }
    _kh=$(dur_sha256_file "$_kp") || return 1
    _ih=$(dur_sha256_file "$_ip") || return 1
    [ "$_kh" = "$MF_boot_kernel_sha256" ] || { DURANIUM_LAST_ERROR="boot kernel SHA-256 mismatch"; return 1; }
    [ "$_ih" = "$MF_boot_initramfs_sha256" ] || { DURANIUM_LAST_ERROR="boot initramfs SHA-256 mismatch"; return 1; }
    return 0
}

manifest_verify() {
    local _dir
    _dir=$1
    [ -d "$_dir" ] || { DURANIUM_LAST_ERROR="artifact directory not found: $_dir"; return 1; }
    manifest_load "$_dir/manifest.txt" || return 1
    manifest_signature_verify "$_dir" || return 1
    manifest_hash_payload "$_dir" || return 1
    manifest_hash_boot "$_dir" || return 1
    return 0
}

manifest_keygen() {
    local _dir _id
    _dir=$1
    _id=$2
    dur_is_safe_id "$_id" || { DURANIUM_LAST_ERROR="invalid key id"; return 1; }
    dur_mkdir "$_dir" || return 1
    openssl genpkey -algorithm ed25519 -out "$_dir/$_id.priv.pem" 2>/dev/null || {
        DURANIUM_LAST_ERROR="openssl key generation failed"
        return 1
    }
    chmod 600 "$_dir/$_id.priv.pem" 2>/dev/null || true
    openssl pkey -in "$_dir/$_id.priv.pem" -pubout -out "$_dir/$_id.pub.pem" 2>/dev/null || {
        DURANIUM_LAST_ERROR="openssl public key extraction failed"
        return 1
    }
    return 0
}

manifest_sign() {
    local _dir _priv _sig
    _dir=$1
    _priv=$2
    manifest_load "$_dir/manifest.txt" || return 1
    [ -r "$_priv" ] || { DURANIUM_LAST_ERROR="signing key not found"; return 1; }
    _sig="$DURANIUM_TMP/manifest.sig.raw.$$"
    openssl pkeyutl -sign -rawin -inkey "$_priv" -in "$_dir/manifest.txt" -out "$_sig" 2>/dev/null || {
        rm -f "$_sig"
        DURANIUM_LAST_ERROR="openssl signing failed"
        return 1
    }
    base64 < "$_sig" | tr -d '\n' > "$_dir/manifest.sig"
    printf '\n' >> "$_dir/manifest.sig"
    rm -f "$_sig"
    sync 2>/dev/null || true
    return 0
}

manifest_install_key() {
    local _id _pub
    _pub=$1
    _id=$2
    dur_is_safe_id "$_id" || { DURANIUM_LAST_ERROR="invalid key id"; return 1; }
    [ -r "$_pub" ] || { DURANIUM_LAST_ERROR="public key not found"; return 1; }
    dur_mkdir "$DURANIUM_KEYS_DIR" || return 1
    dur_copy_atomic "$_pub" "$DURANIUM_KEYS_DIR/$_id.pub" || return 1
    chmod 644 "$DURANIUM_KEYS_DIR/$_id.pub" 2>/dev/null || true
    return 0
}

manifest_show() {
    local _dir
    _dir=$1
    manifest_load "$_dir/manifest.txt" || { dur_err "$DURANIUM_LAST_ERROR"; return 1; }
    printf 'manifest format: %s\n' "$MF_format_version"
    printf 'alloy version:   %s\n' "$MF_alloy_version"
    printf 'build:           %s\n' "$MF_build_id"
    printf 'profile:         %s\n' "$MF_profile"
    printf 'architecture:    %s\n' "$MF_architecture"
    printf 'hardware:        %s\n' "$MF_hardware_target"
    printf 'state schema:    %s (backward-compatible=%s)\n' "$MF_state_schema_required" "$MF_state_schema_backward_compatible"
    printf 'system image:    %s (%s bytes, %s)\n' "$MF_system_image" "$MF_system_image_size" "$MF_system_image_compression"
    printf 'system sha256:   %s\n' "$MF_system_image_sha256"
    printf 'key id:          %s\n' "$MF_key_id"
    return 0
}
