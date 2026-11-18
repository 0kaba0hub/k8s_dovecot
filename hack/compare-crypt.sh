#!/usr/bin/env bash
# The reference's encryption cost: A1 B1 A2 B2 A3 in one slot, the imaptest of
# yarilo's MAILCRYPT window against Dovecot (docs-internal#297).
#
# Usage, on the stand's runner, with yarilo-sb scaled to 0 (one run at a time):
#   KUBECONFIG=~/.kube/sbox.yaml YARILO_REPO=~/stand \
#     bash hack/compare-crypt.sh <out-dir>
#
# Every arm keeps the one-time keys mounted; an A arm writes plaintext
# (mailCrypt.writeAlgorithm empty), a B arm the default algorithm, so the two
# differ in writing alone. Each arm wipes the three types' account ranges,
# fills them over Dovecot's LMTP with the message yarilo's fill sends (200 a
# mailbox), then runs imaptest per type on the ranges yarilo's window uses.
# The stand is put back on the release's values and the Secret deleted at the
# end, whatever happened.

set -uo pipefail

OUT="${1:?output directory}"
KCFG="${KUBECONFIG:-$HOME/.kube/config}"
REPO="${YARILO_REPO:?the yarilo checkout, for the imaptest job and run-job.sh}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/../helm"
DNS=dovecot
FILL=200
BODY_LINES=24
mkdir -p "$OUT"

k() { kubectl --kubeconfig="$KCFG" -n "$DNS" --request-timeout=120s "$@"; }
tools() { k exec dovecot-tools -- sh -c "$1"; }
pod() { k get pod -l app=dovecot --field-selector=status.phase=Running -o name | head -1 | cut -d/ -f2; }

types="mdbox:d00001.test:1:50:1-20 maildir:d00002.test:51:100:51-70 sdbox:d00003.test:101:150:101-120"

deploy() { # <write algorithm, empty for plaintext>
  helm --kubeconfig="$KCFG" upgrade dovecot "$CHART" -n default --reuse-values --force-conflicts \
    --set mailCrypt.enabled=true --set mailCrypt.secretName=dovecot-mail-crypt \
    --set-string mailCrypt.writeAlgorithm="$1" --wait --timeout 5m >/dev/null || return 1
  for _ in $(seq 1 60); do [ -n "$(pod)" ] && return 0; sleep 5; done
  return 1
}

finish() {
  rc=$?
  echo "== restore: release values without mail_crypt, Secret deleted, tools pod removed"
  helm --kubeconfig="$KCFG" upgrade dovecot "$CHART" -n default --reuse-values --force-conflicts \
    --set mailCrypt.enabled=false --wait --timeout 5m >/dev/null && bash "$HERE/mailcrypt-keys.sh" delete
  k delete pod dovecot-tools --ignore-not-found --wait=false >/dev/null
  echo "compare-crypt: ended with status $rc"
  exit "$rc"
}

bash "$HERE/mailcrypt-keys.sh" create || exit 1
trap finish EXIT
k apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: dovecot-tools
  namespace: dovecot
spec:
  restartPolicy: Never
  containers:
  - name: tools
    image: busybox:1.37
    command: ["sleep", "86400"]
    volumeMounts:
    - name: data
      mountPath: /var/mail/vhosts
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: dovecot-data
EOF
k wait --for=condition=Ready pod/dovecot-tools --timeout=180s >/dev/null || exit 1
echo "-- tooling $(git -C "$HERE/.." log --oneline -1), yarilo $(git -C "$REPO" log --oneline -1 | cut -c1-8)"

fill_type() { # <domain> <from> <to>
  local dom=$1 from=$2 to=$3 acked=0 n
  for n in $(seq "$from" "$to"); do
    a=$(tools "
      { printf 'LHLO fill.invalid\r\n'
        i=1; while [ \$i -le $FILL ]; do
          printf 'MAIL FROM:<fill@test.invalid>\r\nRCPT TO:<u$n@$dom>\r\nDATA\r\n'
          printf 'Subject: fill %s\r\nFrom: <fill@test.invalid>\r\nTo: <u$n@$dom>\r\nDate: Thu, 18 Sep 2026 12:00:00 +0000\r\nMessage-ID: <fill-%s-u$n@$dom@test.invalid>\r\n\r\n' \$i \$i
          j=0; while [ \$j -lt $BODY_LINES ]; do printf 'filler text for a mailbox that is not empty\r\n'; j=\$((j+1)); done
          printf '.\r\n'; i=\$((i+1)); done
        printf 'QUIT\r\n'; } | nc -w 60 dovecot.dovecot.svc.cluster.local 24" | grep -c '^250 2.0.0')
    acked=$((acked + a))
  done
  echo "$acked"
}

cpu_watch() { # samples the dovecot pod's CPU every 5 s into $1
  while :; do k top pod -l app=dovecot --no-headers 2>/dev/null | awk '{print $2}' >> "$1"; sleep 5; done
}

checks_failed=0
for arm in A1 B1 A2 B2 A3; do
  alg=""; case "$arm" in B*) alg=aes-256-gcm-sha256 ;; esac
  echo "== arm $arm (crypt_write_algorithm='${alg}') from $(date -u +%H:%M:%S)" | tee -a "$OUT/arms.log"
  deploy "$alg" || { echo "compare-crypt: $arm did not deploy" | tee -a "$OUT/arms.log"; exit 1; }
  P=$(pod)
  for t in $types; do
    IFS=: read -r type dom from to range <<<"$t"
    tools "for n in \$(seq $from $to); do rm -rf /var/mail/vhosts/$dom/u\$n@$dom; done"
  done
  for t in $types; do
    IFS=: read -r type dom from to range <<<"$t"
    s=$(date +%s); acked=$(fill_type "$dom" "$from" "$to"); took=$(( $(date +%s) - s ))
    have=0
    for n in $(seq "$from" "$to"); do
      c=$(k exec "$P" -- doveadm mailbox status -u "u$n@$dom" messages INBOX 2>/dev/null | sed -n 's/messages=//p')
      have=$((have + ${c:-0}))
    done
    du=$(tools "du -sk \$(for n in \$(seq $from $to); do echo /var/mail/vhosts/$dom/u\$n@$dom; done) 2>/dev/null | awk '{s+=\$1} END {print s}'")
    echo "$arm $type fill: acked=$acked in_mailboxes=$have seconds=$took du_kb=$du" | tee -a "$OUT/arms.log"
  done
  for t in $types; do
    IFS=: read -r type dom from to range <<<"$t"
    manifest="$OUT/job-$arm-$type.yaml"
    sed -e "s/- host=.*/- host=dovecot.dovecot.svc.cluster.local/" -e "s/users=1-20/users=$range/" \
      -e "s/u%d@d00001\.test/u%d@$dom/" "$REPO/hack/imaptest/job.yaml" > "$manifest"
    rm -f "$OUT/cpu-$arm-$type.txt"; cpu_watch "$OUT/cpu-$arm-$type.txt" & w=$!
    KUBECONFIG="$KCFG" YARILO_NS=yarilo-sb bash "$REPO/hack/stand/run-job.sh" imaptest "$manifest" "$OUT/ab-$arm-$type.log" 900 >/dev/null 2>&1
    kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    logins=$(grep -A 3 '^Logi' "$OUT/ab-$arm-$type.log" | tail -1 | awk '{print $1}')
    stalls=$(grep -c 'stalled for' "$OUT/ab-$arm-$type.log")
    peak=$(sed 's/m$//' "$OUT/cpu-$arm-$type.txt" 2>/dev/null | sort -n | tail -1)
    echo "$arm $type logins=${logins:-?} stalls=$stalls dovecot_cpu_peak=${peak:-?}m" | tee -a "$OUT/arms.log"
  done
  case "$arm" in B*)
    f=$(tools "
      sig=0; bad=0; for x in \$(find /var/mail/vhosts/d00002.test -path '*/maildir/cur/*' -type f -o -path '*/maildir/new/*' -type f 2>/dev/null | head -2000); do
        if [ \"\$(head -c 7 \$x)\" = CRYPTED ]; then sig=\$((sig+1)); else bad=\$((bad+1)); fi; done
      echo \"maildir sig=\$sig plain=\$bad\"")
    echo "$arm files: $f" | tee -a "$OUT/arms.log"
    case "$f" in *"plain=0"*) ;; *) checks_failed=1 ;; esac
    # The body of one filled message read back through Dovecot equals the
    # plaintext the fill sent (line ends aside: doveadm prints LF).
    want=$(i=0; while [ $i -lt $BODY_LINES ]; do echo 'filler text for a mailbox that is not empty'; i=$((i+1)); done | md5sum | cut -d' ' -f1)
    got=$(k exec "$P" -- doveadm fetch -u u60@d00002.test body mailbox INBOX uid 7 2>/dev/null |
      sed '1s/^body: *//' | tr -d '\r' | sed '/^$/d' | md5sum | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
      echo "$arm fetch: PASS, u60's 'fill 7' body read back equals the plaintext" | tee -a "$OUT/arms.log"
    else
      echo "$arm fetch: FAIL, md5 $got, want $want" | tee -a "$OUT/arms.log"; checks_failed=1
    fi
    ;; esac
done
echo "== done at $(date -u +%H:%M:%S)" | tee -a "$OUT/arms.log"
[ "$checks_failed" = 0 ] || { echo "compare-crypt: a B check failed" >&2; exit 1; }
