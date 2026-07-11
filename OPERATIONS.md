# OPERATIONS — post-install changes and maintenance

For initial install see [`DEPLOY.md`](./DEPLOY.md). For *why* the system is shaped this way see [`spec.md`](./spec.md). For env-vars and `panoramax_backend` CLI surface see the [upstream Panoramax docs](https://docs.panoramax.fr).

## Two kinds of changes

| Change type | Lives in | How to apply |
|---|---|---|
| NixOS config (systemd, Caddy, firewall) | `*.nix` files | `nixos-rebuild switch` |
| Docker compose (containers, env vars, nginx rules) | `hosts/<host>/panoramax/*` | `nixos-rebuild switch` (triggers compose reload via `reloadTriggers`) |
| Runtime tweaks (debugging only) | RAM only | direct command — overwritten on next rebuild |

## Standard workflow

The repo uses a two-branch model (see [`DEPLOY.md` § 1.2](./DEPLOY.md#12-repos--secrets-bootstrap)): you commit to `main`, but the VPS only pulls from `prod`. To ship a config change you push to `main`, then merge `main → prod` and push `prod` - that merge is the explicit "yes, deploy this" gesture. The auto-upgrade timer also writes to `prod` (lockfile bumps only), so `main` stays a pure human-edit branch.

```bash
# on PC
$ nano hosts/panoramax-osmbe/instance.nix
$ nix flake check                    # dummy-fallback check, the CI invariant

# If you changed flake inputs (e.g. bumped the nixpkgs branch in flake.nix),
# update the lockfile first and commit the change together with the input
# change so the VPS builds from a known-good lockfile.
$ nix flake update
$ git commit -am "..." && git push   # to main

# Promote to prod when you're ready to deploy. Usually not ff because prod
# carries the auto-upgrade lockfile commits that aren't on main; a regular
# merge commit is fine.
$ git checkout prod
$ git pull --ff-only                 # pick up any auto-upgrade lockfile bumps
$ git merge main
$ git push origin prod
$ git checkout main

# on PC - SSH in with -A so the git pull on the VPS can use your laptop's key:
$ eval "$(ssh-agent -s)" && ssh-add
$ ssh -A -p 58422 panoramax@<vps>

# on VPS (checkout is permanently on `prod`)
$ cd /srv/panoramax-configs
$ git pull --ff-only                 # `submodule.recurse=true` set in DEPLOY § 2.5 also pulls the submodule
$ sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'
```

**Heads-up about `-A`:** if you're planning to `git pull` on the VPS, SSH in with agent forwarding (`-A`). The VPS has no permanent git credential of its own - the auto-upgrade unit's deploy key is scoped to that systemd unit only, not to your shell. Without a forwarded agent the pull fails with "Permission denied (publickey)". If you forgot, you don't have to redo everything; just exit and re-SSH with `-A`. (You can also skip the `-A` entirely if you're not pulling anything; e.g. just looking at logs or running a `nixos-rebuild switch` on an already-pulled tree).

**`-A` only works if your laptop's ssh-agent actually has your key loaded.** That's the part that's easy to miss. If ssh prompts you for your key's passphrase when you connect (like `Enter passphrase for key '/home/.../.ssh/id_ed25519':`), that means ssh read the key straight from disk and your agent is empty - so `-A` is forwarding nothing useful, and `git pull` on the VPS will still fail with "Permission denied (publickey)". Before SSHing in:

```bash
# on PC
$ eval "$(ssh-agent -s)"   # start an agent if you don't have one running already
$ ssh-add                  # load ~/.ssh/id_ed25519 - you'll enter the passphrase once
$ ssh-add -l               # confirm the key is listed
```

Then `ssh -A -p 58422 panoramax@<vps>` should connect **without** asking for the passphrase. To double-check the forward landed, on the VPS:

```bash
$ ssh-add -l               # should list the same key as on your PC
```

If it says "Could not open a connection to your authentication agent" or "The agent has no identities", the forward isn't carrying anything; exit, `ssh-add` on your laptop, and reconnect.

**Quick fix if `git pull` fails with "Permission denied (publickey)"** — the agent was empty when you connected:

```bash
# on PC
$ eval "$(ssh-agent -s)"
$ ssh-add
$ ssh-add -l

# reconnect with -A
$ ssh -A -p 58422 panoramax@<vps>
```

Then on the VPS:

```bash
$ ssh-add -l             # should list the key
$ git pull --ff-only
```

`?submodules=1` is required on every `nixos-rebuild` because the encrypted secrets file lives in the `secrets/` submodule. Without it, the build resolves to `secrets-dummy.yaml` and the stack would start with placeholder credentials — see [`spec.md` § Secrets](./spec.md#secrets) for why.

## Branch workflows

Testing changes on a feature branch directly on the VPS works:

```bash
ssh -p 58422 panoramax@<vps>
cd /srv/panoramax-configs
git fetch origin
git checkout my-feature
sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'
```

**Caveat:** the auto-upgrade timer's weekly run does `git checkout prod && git reset --hard origin/prod`, which will silently overwrite your branch checkout. For long-running branch testing, either disable auto-upgrade (set `panoramax.autoUpgrade.enable = false` and rebuild) or push your branch as `prod` for the duration.

## Secret rotation

The VPS does **not** auto-pull the private secrets repo (deliberate — see [`spec.md` § Secrets](./spec.md#secrets)). The submodule pin is updated manually with agent forwarding.

```bash
# on PC — edit, commit, and push to the private repo:
# sops opens the decrypted file in $EDITOR — set it if needed:
# export EDITOR=nano   # or vim, hx, micro, etc.
$ sops secrets/panoramax-osmbe.yaml
$ git -C secrets commit -am "rotate ..." && git -C secrets push

# Bump the public repo's submodule pin so prod tracks the new secret commit:
$ git add secrets
$ git commit -m "secrets: rotate ..."
$ git push

# on VPS — SSH in with agent forwarding (-A) so the submodule pull can
# authenticate against the private repo through your laptop's key:
$ ssh -A -p 58422 panoramax@<vps>
$ cd /srv/panoramax-configs
$ git pull --ff-only                  # also updates the submodule (submodule.recurse=true)
$ sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'
```

`nixos-rebuild switch` updates `/run/secrets/` but does not restart units, so what to do next depends on the kind of consumer:

- **Long-running services** — must be manually restarted; they hold the old value in memory until they stop.
  - `panoramax/env` → `sudo systemctl restart panoramax`
  - `loki/*` → `sudo systemctl restart alloy`
  - `netbird/setup-key` → no action needed; only consumed at first enrollment.
- **Timer-driven oneshots** — no manual action needed. Their scripts read `/run/secrets/...` at exec time, so the next firing picks up the rotated value automatically.
  - `s3/env` → consumed by `pgdump-s3.service` (next 00:30 UTC).
  - `borg/*` → consumed by `borgbackup-panoramax.service` (next 01:30 UTC).
  - `healthchecks/*` → consumed by `heartbeat`, `nfs-health`, `pgbackrest-incr/full`, `pgdump-s3`, `borgbackup-panoramax`, `flake-lock-update`, `nixos-upgrade`, `nixos-upgrade-postboot`.

If a rotation has to take effect immediately (e.g., a leaked S3 key), trigger the relevant oneshot with `sudo systemctl start <unit>.service`.

## Adding a new admin

The new admin generates their own age key on their developer machine — they keep the private key, you only need the public key:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # send the printed age1… line to an existing admin
```

Then, on an existing admin's machine:

1. Receive the new admin's age public key (the `age1…` line above) and SSH public key.
2. Add the age key to `secrets/.sops.yaml` under `keys:` and reference it in `creation_rules → key_groups → age:`.
3. `sops updatekeys secrets/panoramax-osmbe.yaml` (re-encrypts every secret to the new recipient set).
4. `git -C secrets commit -am "add admin: <name>" && git -C secrets push` — push to the private repo.
5. Bump the parent's submodule pin and add their SSH key to `instance.nix → admins`:
   ```bash
   git add secrets hosts/panoramax-osmbe/instance.nix
   git commit -m "add admin: <name>"
   git push
   ```
6. On the VPS: `git pull --ff-only` (recurses into the submodule automatically) and `sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'`.

The new admin doesn't need to be added as a NetBird peer — admin Postgres access goes through an SSH tunnel (see § Connecting to Postgres below), and SSH to the VPS is on the public internet at `instance.sshPort`. Keeping admins off the mesh means a co-admin with NetBird dashboard access can't route to other admins' machines.

## Connecting to Postgres

Postgres is bound to `127.0.0.1:5432` on the VPS — not exposed on NetBird, not exposed publicly. Reach it from your laptop with an SSH local port forward:

```bash
ssh -N -L 5433:127.0.0.1:5432 -p 58422 panoramax@<vps-public-ip>
```

Leave that running. In another terminal:

```bash
psql -h localhost -p 5433 -U gvs geovisio
```

Note the connection target is `localhost:5433` (your end of the tunnel), **not** the VPS IP. The VPS's docker-compose reads the `db` container by docker-network hostname, so the localhost binding doesn't affect the stack itself.

For repeated use, drop a stanza into `~/.ssh/config` so `psql` and GUI clients (DBeaver, pgAdmin, …) can use the host alias directly:

```
Host panoramax-vps
    HostName <vps-public-ip>
    User panoramax
    Port 58422
    LocalForward 5433 127.0.0.1:5432
```

Then `ssh -N panoramax-vps` opens the tunnel; clients point at `localhost:5433`. Most GUI clients also support a built-in "connect via SSH tunnel" option — that works too and avoids needing the `LocalForward` line.

**Why not direct over NetBird?** Earlier iterations bound Postgres to the VPS NetBird IP and added admin laptops as peers. That worked but put every admin's machine on a shared mesh, where any co-admin with NetBird dashboard admin (which they need to manage other peers) could route to other admins' machines. Tunnelling over SSH keeps admin laptops off the mesh entirely. See [`spec.md` § NetBird](./spec.md#netbird).

## CLI cheatsheet

These are run in the API container:

```bash
$ docker exec -it $(docker ps -qf name=api) <command>
```

Common ones (full surface in the [upstream Panoramax docs](https://panoramax.ign.fr/api/docs/swagger)):

- `panoramax_backend user --set-role admin <username>` — promote.
- `panoramax_backend user --delete-data <username>` — wipe a user's data.
- `panoramax_backend default-account-tokens get` — get a long-lived JWT.
- `panoramax_backend db refresh` — refresh materialized views.
- `panoramax_backend cleanup <SEQ_ID> --database --cache` — purge a sequence.
- `panoramax_backend sequences reorder` — reorder sequences after edits.

For one-off admin operations from outside the container, an OAuth token is the easiest auth. To get one:

1. Log into `panoramax.osm.be` as an admin.
2. Open browser DevTools → Application → Cookies; the `session` cookie carries your auth.
3. Or call `POST /api/auth/tokens/generate` (signed in) to get a JWT.
4. `Authorization: Bearer <token>` on subsequent API calls.

## Collecting container logs

For day-to-day inspection, query Grafana Cloud Loki — every container's stdout/stderr lands there via the journald log driver, labelled with `container=<name>`. Examples:

```
{host="panoramax-osmbe", container="panoramax-api"}
{host="panoramax-osmbe", container=~"panoramax-background-worker.*"}
```

For local inspection (no Grafana, e.g. while debugging on the VPS):

```bash
# All entries from one container, last hour:
sudo journalctl CONTAINER_NAME=panoramax-api --since '1 hour ago'

# `docker logs` still works (journald driver supports it):
sudo docker logs -f panoramax-api
```

To dump logs from every Panoramax compose container to disk for offline analysis:

```bash
SINCE="24h" && \
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S) && \
mkdir -p /srv/panoramax/logs/"$TIMESTAMP" && \
sudo docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env ps -q | while read -r c; do \
    name=$(docker inspect --format='{{.Name}}' "$c" | tr -d '/'); \
    docker logs "$c" --since "$SINCE" > "/srv/panoramax/logs/$TIMESTAMP/$name.log" 2>&1; \
done
```

This only captures the Panoramax stack (`api`, `db`, `website`, `reverseproxy`, `background-worker`, `migrations`). System services (e.g. `alloy`) are excluded because we use `docker compose` scoped to `/etc/panoramax` rather than `docker ps -aq`.

## Manual compose control (debugging)

If the stack is failing to start and you need real-time `docker compose up` output, flip the auto-start toggle in `hosts/panoramax-osmbe/default.nix`:

```nix
panoramax.composeAutoStart = false;
```

Run `nixos-rebuild switch`. The service will print:

```
⚠️  DIDN'T AUTO START PANORAMAX — composeAutoStart is set to false
```

Then start the stack manually:

```bash
sudo docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env up --remove-orphans
```

`Ctrl-C` stops the stack. To hand control back to systemd, flip the toggle back to `true` and rebuild. The env-merge and db-build units still run when auto-start is off, so `/run/panoramax.env` and the db image stay current.

## Recovering a stuck migration

If `migrations` was killed mid-run and `panoramax.service` won't start due to a yoyo lock:

```bash
$ docker compose run --rm migrations yoyo break-lock
```

Then restart the stack: `sudo systemctl restart panoramax`.

## When `nixos-upgrade` says "REBOOT REQUIRED"

The weekly auto-upgrade **does not auto-reboot**. When the rebuild produces a new kernel, initrd, or kernel modules, the `nixos-upgrade` Healthchecks check goes **red** with a body like:

```
BUILD SUCCEEDED — REBOOT REQUIRED at 2026-05-17T19:47:25Z
kernel/initrd/modules changed; run `sudo reboot` on the VPS at your convenience.
```

The new system is already activated — userspace is running the new closure — only the kernel is still the old one. To finish the job:

```bash
$ ssh -p 58422 panoramax@<vps>
$ sudo reboot
```

That's it. After the box comes back up, `nixos-upgrade-postboot.service` fires once during boot, notices the sentinel file at `/var/lib/nixos-upgrade/reboot-pending` plus a matching `booted == built`, deletes the sentinel, and pings success — the Healthchecks check flips back to green automatically. No manual ping needed.

**Heads-up on false-alerts during the reboot itself.** `heartbeat` and `nfs-health` ping every 5 min with a 10-min grace and no blind-spot. A reboot that finishes inside ~10 min stays green; one that takes longer briefly flips them red. If you want zero noise, pause both checks on hc.io before `sudo reboot` and unpause once the box is back.

**If the box doesn't come back from the reboot** (kernel panic, broken initrd, etc.) the Healthchecks check stays red — exactly when you want it loud. Roll back via GRUB to the previous generation; the previous closure's userspace is still on disk.

**If you want to check pending-reboot state without going to Healthchecks**: `ls /var/lib/nixos-upgrade/reboot-pending` on the VPS. File exists ⇒ reboot is pending; file absent ⇒ in sync.

## Rolling back a bad NixOS upgrade

```bash
$ sudo nixos-rebuild switch --rollback
# or pick an older generation in GRUB if the system won't boot
```

If the bad upgrade was from auto-upgrade, the bad commit is on `prod` — manually `git reset --hard origin/main` on the VPS, rebuild, then on your PC `git push --force-with-lease origin main:prod` after dealing with the underlying issue.

## Disaster recovery (VPS lost)

The auto-upgrade deploy key and the BorgBase SSH key in sops are **not VPS-tied** — they can stay as-is. Only the host SSH key needs regenerating because it's how sops authenticates the new VPS.

1. Provision a new Infomaniak VPS.
2. Pre-generate a *new* host SSH key locally and convert its pubkey to age form (same flow as `DEPLOY.md` § 1.3):
   ```bash
   ssh-keygen -t ed25519 -f keys/ssh_host_ed25519_key -N "" -C "panoramax-osmbe-host"
   ssh-to-age -i keys/ssh_host_ed25519_key.pub
   ```
3. Replace the old host's age line in `secrets/.sops.yaml` with the new one and run `sops updatekeys secrets/panoramax-osmbe.yaml` (re-encrypts every secret to the new host).
4. Build the `extra-files/etc/ssh/` mirror with the host key, then `nixos-anywhere --extra-files extra-files --flake '.?submodules=1#panoramax-osmbe' root@<new-vps-ip>` (see `DEPLOY.md` § 2.3 for the full incantation).
5. SSH in (with agent forwarding) and `git clone --recurse-submodules` the public repo (the submodule pull happens automatically via your forwarded key).
6. **Restore the database.** Two paths depending on what's available:
   - **From BorgBase** (physical backup, full PITR): `borg extract` the latest archive, then `pgbackrest restore --stanza=panoramax` against `/srv/panoramax/pgbackrest`. Full end-to-end procedure with all the gotchas is in § Borg-only restore drill below.
   - **From S3 pg_dump** (logical backup, faster to spin up but no WAL replay): `s3cmd get s3://...latest.dump - | docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env exec -T -u postgres db pg_restore -d geovisio`. § Test-restore drill below uses this path.
7. NFS re-mounts automatically on first boot — pictures are recovered (only the in-flight `/srv/panoramax/tmp` queue is lost).
   - The `panoramax` user UID is pinned to `1320` in `modules/users.nix`. This means TrueNAS ACLs survive a VPS rebuild without reconfiguration — a new VPS automatically remaps to the same user identity.
8. DNS still points at the old VPS — update the A/AAAA records.

PITR via `pgbackrest restore --type=time --target='2026-04-28 12:00:00'`.

**Practice this restore quarterly** into a temp Docker volume on port 5433, against a copy-of-prod environment. The drill catches what dry runs miss.

## Test-restore drill

```bash
# in a scratch directory
$ docker run -d --name pgr -p 5433:5432 \
    -e POSTGRES_PASSWORD=test -e POSTGRES_USER=gvs -e POSTGRES_DB=geovisio \
    postgis/postgis:16-3.4
$ s3cmd get s3://panoramax-osmbe-backups/pgdump/daily/<latest>.dump - \
    | docker exec -i pgr pg_restore -U gvs -d geovisio
$ psql -h localhost -p 5433 -U gvs geovisio -c 'SELECT count(*) FROM sequences;'
$ docker rm -f pgr
```

If that count is sensible, the backup is good.

## Borg-only restore drill

The S3 drill above only exercises the logical (pg_dump) backup. Borg is the *physical* backup — it stores pgBackRest's WAL + base-backup chain — and the restore path is meaningfully different. Practice it on its own.

Two phases: extract on the VPS, then restore-and-browse on your laptop.

### On the VPS — extract the latest archive

```bash
cd /tmp && mkdir -p borg-restore && cd borg-restore

sudo bash -c '
  cd /tmp/borg-restore
  export BORG_REPO=$(cat /run/secrets/borg/repo-url)
  export BORG_PASSCOMMAND="cat /run/secrets/borg/passphrase"
  export BORG_RSH="ssh -i /root/.ssh/borg-backup-key"
  archive=$(borg list --short | tail -1)
  echo "extracting $archive"
  borg extract -v "::$archive"
'

# Sanity check — should find backup.info under srv/panoramax/pgbackrest/...
sudo find /tmp/borg-restore -name backup.info

# Tar it up so the download is one file
sudo tar -czf /tmp/pgbackrest-repo.tar.gz -C /tmp/borg-restore .
sudo chown panoramax /tmp/pgbackrest-repo.tar.gz
```

`--strip-components` deliberately not used — the archive's internal paths are `srv/panoramax/pgbackrest/...` (because the unit calls `borg create ... /srv/panoramax/pgbackrest`), and it's easier to keep the prefix and adjust the bind-mount than to strip it cleanly.

### On your laptop — restore + start a throwaway postgres

```bash
mkdir -p ~/borg-restore-test && cd ~/borg-restore-test
scp -P 58422 panoramax@<vps>:/tmp/pgbackrest-repo.tar.gz .
mkdir pgbackrest-repo && tar -xzf pgbackrest-repo.tar.gz -C pgbackrest-repo

# Open up read perms — the extracted files come out owned by an arbitrary uid
# that the container's postgres user can't always reach.
sudo chmod -R a+rX pgbackrest-repo/

# Build the same db image the live stack uses (postgis:16-3.4 + pgbackrest)
cp /path/to/panoramax-configs/hosts/panoramax-osmbe/panoramax/Dockerfile.db .
sudo docker build -t panoramax-db-restore -f Dockerfile.db .

# Minimal pgbackrest.conf pointing at the extracted repo
cat > pgbackrest.conf <<'EOF'
[global]
repo1-path=/var/lib/pgbackrest
compress-type=zst
log-level-console=info

[panoramax]
pg1-path=/var/lib/postgresql/data
pg1-port=5432
pg1-user=gvs
pg1-database=geovisio
EOF

sudo docker volume create pgr-restore-data

# 1. Restore - mount the deeper srv/panoramax/pgbackrest path, not the top of the extract
sudo docker run --rm \
  -v "$PWD/pgbackrest-repo/srv/panoramax/pgbackrest":/var/lib/pgbackrest:ro \
  -v pgr-restore-data:/var/lib/postgresql/data \
  -v "$PWD/pgbackrest.conf":/etc/pgbackrest/pgbackrest.conf:ro \
  -u postgres \
  --entrypoint pgbackrest \
  panoramax-db-restore \
  --stanza=panoramax restore

# 2. Start postgres on :5433 - max_connections must match production (500)
#    or WAL replay refuses to start with "insufficient parameter settings".
sudo docker run -d --name pgr-restore -p 5433:5432 \
  -v pgr-restore-data:/var/lib/postgresql/data \
  -v "$PWD/pgbackrest-repo/srv/panoramax/pgbackrest":/var/lib/pgbackrest:ro \
  -v "$PWD/pgbackrest.conf":/etc/pgbackrest/pgbackrest.conf:ro \
  -e POSTGRES_PASSWORD=ignored \
  panoramax-db-restore \
  postgres -c max_connections=500

sudo docker logs -f pgr-restore
# wait for "database system is ready to accept connections", then Ctrl-C
```

Then point pgAdmin at `localhost:5433`, db `geovisio`, user `gvs`, password = whatever the live `PG_PASSWORD` was at the time of the backup (not whatever it is now if it's been rotated since).

### Cleanup

```bash
# on laptop
sudo docker rm -f pgr-restore
sudo docker volume rm pgr-restore-data
sudo docker rmi panoramax-db-restore
rm -rf ~/borg-restore-test

# on VPS
sudo rm -rf /tmp/borg-restore /tmp/pgbackrest-repo.tar.gz
```

### Gotchas worth knowing about

- **`max_connections` on the recovery container has to match (or exceed) the primary's value.** PG refuses to replay WAL otherwise. Currently `500` (see `hosts/panoramax-osmbe/panoramax/postgresql.conf`). If that value ever changes, bump it in the drill command too.
- **PG major version must match.** Bumping the `FROM postgis/postgis:` tag in `Dockerfile.db` means bumping it in your local rebuild as well — pgBackRest restores are tied to the major version.
- **`max_worker_processes`** is set to `4` in production, but PG's default is `8`, so the recovery container already satisfies it without an explicit `-c`.

## What to commit, what to leave alone

| File | Public repo? | Private (`secrets/`) repo? |
|---|---|---|
| `instance.nix` | Yes — public values, fork-friendly. | — |
| `hosts/.../hardware-configuration.nix` | Yes — generated by nixos-anywhere. Re-commit if regenerated. | — |
| `.gitmodules` | Yes — names the private repo's URL (already public knowledge). | — |
| `secrets/` (the gitlink SHA) | Yes — bumped whenever the private repo gets a new commit. | — |
| `panoramax-osmbe.yaml` | **No.** Submodule semantics make this structurally impossible. | Yes — encrypted. |
| `.sops.yaml` | — | Yes — recipient list. |
| `keys/ssh_host_ed25519_key*` | **No.** Gitignored. Keep a separate secure copy. | **No.** |
| `secrets-dummy.yaml` | Yes — public, plaintext placeholders only. | — |
| `flake.lock` | Yes — auto-upgrade pushes weekly bumps to `prod`. | — |
