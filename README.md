# k8s_dovecot

Helm chart deploying a real, unmodified Dovecot 2.4 into the sandbox
Kubernetes cluster, configured as closely as possible to the [yarilo](https://github.com/0kaba0hub/yarilo)
sandbox deployment (`yarilo-sb` namespace). Used exclusively for wire-format
interop verification — confirming that yarilo's on-disk mdbox output is
readable by a genuine, independent Dovecot binary, not yarilo's own parser.

Not a production mail server. No TLS, no HA, single replica.

## What it does

- Deploys `dovecot/dovecot:2.4.4` in namespace `dovecot`.
- Authenticates against the **same MySQL auth database** yarilo-sb uses
  (`db` namespace, `yarilo` database, `mailbox`/`domain`/`alias` tables) —
  `passdb`/`userdb sql`, with `mail_driver` selected per-user from the
  `mailbox.mbtype` column (`mdbox`/`maildir`/`sdbox`), mirroring yarilo's
  own per-user storage-backend resolution.
- Operates on **its own writable copy** of yarilo's mail tree: an
  `initContainer` seeds a dedicated PVC (`dovecot-data`) from a read-only
  mount of the same underlying hostPath backing yarilo-sb's `yarilo-mail`
  PVC, on every pod start. Live yarilo-sb data is never mounted read-write
  and is never at risk from this chart.

## Deploy

```sh
helm upgrade --install dovecot helm \
  --kubeconfig ~/.kube/ihorru-sbox-nc.yaml \
  --set mysql.password="<mysql yarilo user password>"
```

The MySQL password matches whatever is currently set in
`igorru_dns/testing/yarilo/helm_values/mysql-sandbox.yaml`'s `mysql` Secret
(`MYSQL_PASSWORD`). It is **never committed** — `values.yaml` ships an empty
default; pass it via `--set` at deploy time, or keep a local
`values-secret.yaml` (gitignored) with just:

```yaml
mysql:
  password: "..."
```

and add `-f values-secret.yaml` to the command above.

## Values

| Key | Default | Description |
|:---|:---|:---|
| `image.repository` / `image.tag` | `dovecot/dovecot` / `2.4.4` | Dovecot image |
| `namespace` | `dovecot` | Target namespace |
| `mysql.host` / `mysql.port` / `mysql.database` / `mysql.user` | `mysql.db.svc.cluster.local` / `3306` / `yarilo` / `yarilo` | Same auth DB as yarilo-sb |
| `mysql.password` | `""` | **Not committed** — pass via `--set` or a gitignored values file |
| `mailRoot` | `/var/mail/vhosts` | Mail storage root, matches yarilo's `storage.maildir_root` |
| `sharedStorage.hostPath` | pinned to yarilo-sb's `yarilo-mail` PVC hostPath | Read-only source seeded into `dovecot-data` on pod start |
| `sharedStorage.node` | `sb-k8s-01` | Node the source hostPath and this pod are pinned to |
| `sharedStorage.size` | `10Gi` | Size for both the RO source PV and the writable `dovecot-data` PVC |
| `protocols.imap.port` / `pop3.port` / `lmtp.port` / `managesieve.port` | `143` / `110` / `24` / `4190` | Plaintext listeners (no TLS — internal interop testing only) |
| `resources` | `100m/128Mi` request, `512Mi` limit | Pod resource sizing |

## Known 2.4 gotchas (worth re-checking on any Dovecot version bump)

- **`mailbox_directory_name_legacy = yes` is required.** 2.4 moved
  per-folder dbox indexes to `<index>/mailboxes/<name>/dbox-Mails/` by
  default; yarilo (like Dovecot 2.3) writes `<index>/mailboxes/<name>/`
  directly. Without this setting, 2.4 opens every existing yarilo mailbox
  as empty with a fresh uidvalidity instead of reading what's there.
- 2.4 replaced `mail_location = <driver>:<path>:INDEX=<path>` with
  separate flat settings: `mail_driver`, `mail_path`, `mail_index_path`,
  `mail_home`.
- `passdb`/`userdb` blocks are named (`passdb sql { ... }`), and the SQL
  connection itself is a nested named block inside them
  (`mysql <name> { host = ...; ... }`) — not a flat `mysql_host` setting.
- `mail_plugins` is a block of `<name> = yes` entries per protocol
  (`protocol imap { mail_plugins { imap_sieve = yes } }`), not a
  space-separated string.
- `sieve_script <name> { type = ...; path = ...; active_path = ... }` is a
  named block, replacing the old `plugin { sieve = ... }` string.
- Global default `mail_home`/`mail_path`/`mail_index_path` templates are
  evaluated before the userdb SQL query resolves real per-user values —
  don't reference `%{domain}` in those global defaults unless a
  domain-splitting mechanism is configured; `%{user}` alone is safe.
- The upstream `dovecot/dovecot` image ships no `dovenull`/`dovecot`
  system users, so `default_login_user`/`default_internal_user` must be
  overridden (this chart uses `nobody`/`nogroup`) or process startup fails.

## Running an interop check

```sh
POD=$(kubectl -n dovecot get pod -l app=dovecot -o jsonpath='{.items[0].metadata.name}')

# Force a real Dovecot rebuild of a yarilo-written mailbox from scratch —
# the strongest signal for wire-format compatibility, since it ignores
# yarilo's own (non-Dovecot-compatible) map/index bookkeeping and re-derives
# everything from the raw m.<N> dbox v2 payload files.
kubectl -n dovecot exec "$POD" -c dovecot -- \
  /dovecot/bin/doveadm force-resync -u <user>@<domain> INBOX

kubectl -n dovecot exec "$POD" -c dovecot -- \
  /dovecot/bin/doveadm mailbox status -u <user>@<domain> messages INBOX

kubectl -n dovecot exec "$POD" -c dovecot -- \
  /dovecot/bin/doveadm fetch -u <user>@<domain> "uid hdr.subject" mailbox INBOX all
```

Or connect over IMAP directly (after a `kubectl -n dovecot port-forward
svc/dovecot 1143:143`) with the same credentials a yarilo IMAP client would
use — the `mailbox.password` column is already `{SCHEME}`-prefixed
(`{BCRYPT}...`), so Dovecot's SQL passdb authenticates against it natively.
