#!/usr/bin/env bash
# One-time global mail_crypt keys for a comparison run.
#
#   KUBECONFIG=... bash hack/mailcrypt-keys.sh create   # Secret dovecot-mail-crypt
#   KUBECONFIG=... bash hack/mailcrypt-keys.sh delete
#
# An X25519 key pair is made under umask 077 in a temporary directory, put in
# the Secret and the files removed; nothing is printed but the key type. The
# run deletes the Secret when it ends. Deploy with
#   --set mailCrypt.enabled=true --set mailCrypt.secretName=dovecot-mail-crypt
set -euo pipefail

NS="${DOVECOT_NS:-dovecot}"
NAME=dovecot-mail-crypt
kube() { kubectl -n "$NS" --request-timeout=60s "$@"; }

case "${1:-}" in
  create)
    umask 077
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    openssl genpkey -algorithm X25519 -out "$dir/global.pem" 2>/dev/null
    openssl pkey -in "$dir/global.pem" -pubout -out "$dir/global.pub" 2>/dev/null
    kube create secret generic "$NAME" --from-file=global.pem="$dir/global.pem" \
      --from-file=global.pub="$dir/global.pub" >/dev/null
    echo "mailcrypt-keys: Secret $NAME made: X25519 key pair"
    ;;
  delete)
    kube delete secret "$NAME" --ignore-not-found >/dev/null
    echo "mailcrypt-keys: Secret $NAME deleted"
    ;;
  *)
    echo "usage: $0 create|delete" >&2
    exit 2
    ;;
esac
