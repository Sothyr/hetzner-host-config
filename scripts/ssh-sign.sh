#!/bin/bash
# Signs an SSH key with the user CA. Same as ssh-sign.ps1, for Linux, macOS and CI.
#   scripts/ssh-sign.sh init-ca [CA]
#   scripts/ssh-sign.sh sign KEY IDENTITY PRINCIPALS [VALIDITY] [CA]
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
  init-ca)
    ca="${2:-$HOME/.ssh/hhc_user_ca}"
    [ -e "$ca" ] && { echo "CA $ca exists already" >&2; exit 1; }
    ssh-keygen -t ed25519 -f "$ca" -C hhc-user-ca
    echo "Public key for ssh.user_ca_public_keys:"
    cat "$ca.pub"
    ;;
  sign)
    key="$2" identity="$3" principals="$4" validity="${5:-+12h}" ca="${6:-$HOME/.ssh/hhc_user_ca}"
    [ -f "$ca" ] || { echo "CA $ca not found" >&2; exit 1; }
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -f "$key" -C "$identity"
    ssh-keygen -s "$ca" -I "$identity" -n "$principals" -V "$validity" "$key.pub"
    ssh-keygen -L -f "$key-cert.pub"
    ;;
  *)
    echo "usage: $0 init-ca [CA] | sign KEY IDENTITY PRINCIPALS [VALIDITY] [CA]" >&2
    exit 2
    ;;
esac
