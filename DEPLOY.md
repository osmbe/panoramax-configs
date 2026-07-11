# DEPLOY - guide to setting up a Panoramax instance using nix

This doc gives you the step by step plan on what needs to be done to setup a Panoramax instance, some things here are specific to our setup so might need to be changed for your instance.
The other docs are [`OPERATIONS.md`](./OPERATIONS.md) which is where you'll find various things related to actually maintaining and debugging the instance;
And there is also the [`spec.md`](./spec.md) doc which tries to give an overview of the whole setup and why certain things are implemented the way they are.

**Order matters.** Each step builds on the previous ones, so if something breaks, fix it before moving on.

---

## Step 0 - Read first

- [x] Skim [`spec.md`](./spec.md) (and maybe [`OPERATIONS.md`](./OPERATIONS.md) too, though you can probably skip it for now). Make sure the design choices actually fit what you want (stuff like the SSH port, schedule timings, and monitoring target).

---

## Step 1 - Prerequisites

**Not running NixOS on your dev machine?** That's fine. You only need the Nix package manager itself. 
Either if you're on Windows/Linux, you can download the nix package manager (for Windows it's via WSL) from  [nixos.org/download](https://nixos.org/download.html).
Once that's done, enable flakes so the commands in this doc actually work:

```bash
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### 1.1 Local tools

Here's what you need on your dev machine:

- [x] Nix with flakes enabled
- [x] `sops`, `age`, `age-keygen`, `ssh-to-age`
- [x] `s3cmd`
- [x] `git`, `ssh-agent`

### 1.2 Repos + secrets bootstrap

We've split things across two repos: the **public** `panoramax-configs` repo (this one) has the Nix configs, compose files, and docs; the **private** `panoramax-secrets` repo holds the encrypted sops file. That private repo is wired into `./secrets/` as a git submodule. See [`spec.md` § Secrets](./spec.md#secrets) if you want to know why we did it this way.

- [x] **Fork (or clone) the public repo and point `origin` at your own fork.** The auto-upgrade timer just pushes to whatever `origin` points to. If you leave it on upstream it'll either fail (because you don't have write access) or accidentally push your config changes to upstream.

```bash
# Don't pass --recurse-submodules yet - your private secrets repo doesn't exist (you'll create it next), so the submodule init would fail. Skip it.
git clone git@github.com:<upstream-org>/panoramax-configs.git
cd panoramax-configs
git remote set-url origin git@github.com:<your-org>/panoramax-configs.git
git remote -v
```

- [x] **Create a `prod` branch on your fork.** The repo uses a two-branch model: `main` is where humans push config changes; `prod` is what the VPS actually runs from. The auto-upgrade timer commits its weekly `flake.lock` bumps to `prod` (never `main`), so `prod` = `main` + accumulated lockfile commits. Config changes only reach the VPS when an admin explicitly merges `main → prod` and pushes (see [`OPERATIONS.md` § Standard workflow](./OPERATIONS.md#standard-workflow)). This split exists so a half-finished commit on `main` can't accidentally ship to the machine.

```bash
# Initial prod is just a fast-forward of main:
git checkout -b prod
git push -u origin prod
git checkout main
```

Without this branch, the auto-upgrade unit will fail.

- [x] **Create a private repo** called `panoramax-secrets` on GitHub (or whatever forge you prefer). **Make sure you tick "Add a README file"** when you create it. `git submodule add` needs the remote to have at least one commit (a HEAD it can clone), and adding a README is the easiest way to do that. You don't need a license or a .gitignore.

- [x] **Repoint the `secrets/` submodule at your private repo.** This repo already has a `.gitmodules` entry pointing at osmbe's secrets repo, and the parent commit already records a gitlink SHA from that repo. Neither of those is reachable from your fork, so you need to swap two things: the URL in `.gitmodules` (point it at your private repo), and the recorded gitlink SHA (replace it with a commit that actually lives in your repo).

```bash
# Repoint .gitmodules at YOUR private secrets repo:
git submodule set-url secrets git@github.com:<your-org>/panoramax-secrets.git

# Init + clone from the new URL. The --remote flag pulls the tracking branch's HEAD instead of the recorded gitlink SHA. The recorded SHA is from osm-be's repo and doesn't exist in yours, so a plain `update --init` would fail at the checkout step.
git submodule update --init --remote secrets

# Commit both the URL change and the new gitlink:
git add .gitmodules secrets
git commit -m "repoint secrets submodule to our our secrets repo"
git push
```

After this, `./secrets/` is a clone of your private repo (just the README for now). You'll fill it in next.

- [x] **Swap out the placeholder README for the secrets template.** `secrets_example/` is the plaintext template you'll fill in and then encrypt; just copy its contents into the submodule and push.

```bash
rm secrets/README.md
cp -r secrets_example/. secrets/
git -C secrets add -A
git -C secrets commit -m "copied templates"
git -C secrets push

# Bump the parent's gitlink to record the new commit:
git add secrets
git commit -m "secrets: copied templates"
git push
```

- [x] **Check that the fresh-clone fallback still works.** Even after copying the templates, this still resolves to the dummy. `nix flake check` doesn't use `?submodules=1`, so Nix can't see anything inside the `secrets/` submodule and falls back to `secrets-dummy.yaml`.

```bash
nix flake check
```

  If it complains about a dirty git tree, you can ignore that part. If the command outputs nothing, you're good.

- [x] **Make sure the real-secrets path actually resolves.**

```bash
nix eval --raw '.?submodules=1#nixosConfigurations.panoramax-osmbe.config.sops.defaultSopsFile'
# Should end in `panoramax-osmbe.yaml`, NOT `secrets-dummy.yaml`. If you see the dummy here, the submodule isn't attached properly. Re-run the submodule commands from the previous step again.
```

### 1.3 Sops bootstrap (often skipped - don't)

This step creates **three keys**. Each section below tells you what the key is, where the private half lives, and where the public half needs to go.

- [x] **Your personal age key.** This lives on your dev machine and decrypts `secrets/panoramax-osmbe.yaml`. Every admin has their own.

  ```bash
  mkdir -p ~/.config/sops/age
  age-keygen -o ~/.config/sops/age/keys.txt  # generates age key - store this somewhere safe
  age-keygen -y ~/.config/sops/age/keys.txt  # prints the pubkey - copy this
  ```

  - **Private key** (`~/.config/sops/age/keys.txt`): keep this on your laptop. Back it up somewhere. If you lose it you can't decrypt secrets unless another admin re-encrypts everything to a new key.
  - **Public key** (the `age1…` line printed by the -y line): replace the placeholder value next to `&admin_adminname` in `keys:` with your actual `age1…` pubkey. If you rename the anchor, update the matching `*admin_…` reference in `creation_rules` too.

- [x] **The VPS host SSH key.** We generate this locally because the VPS doesn't exist yet, but sops needs to be able to decrypt at first boot.

  ```bash
  mkdir -p keys
  ssh-keygen -t ed25519 -f keys/ssh_host_ed25519_key -N "" -C "panoramax-osmbe-host"
  ssh-to-age -i keys/ssh_host_ed25519_key.pub   # prints the host's age pubkey - copy this
  ```

  - **Private key** (`keys/ssh_host_ed25519_key`): keep it in `keys/` (gitignored). It gets injected into the VPS at install time via `nixos-anywhere --extra-files keys/` (step 2.3). The flake reads it at runtime from `/etc/ssh/ssh_host_ed25519_key` to decrypt sops.
  - **Public key - converted to age** (the `age1…` line printed by `ssh-to-age`): replace the placeholder value next to `&host...` in `keys:` with your actual `age1…` pubkey.
  - **Public key - raw SSH form** (`keys/ssh_host_ed25519_key.pub`): not needed for anything.

- [x] **The auto-upgrade git deploy key.** The weekly auto-upgrade timer uses this to get git permissions to push `flake.lock` bumps to the public repo's `prod` branch.

  ```bash
  ssh-keygen -t ed25519 -f keys/ssh_deploy_key -N "" -C "panoramax-osmbe-deploy-key"
  ```

  - **Private key** (`keys/ssh_deploy_key`): paste the entire file contents into `secrets/panoramax-osmbe.yaml` under the `git/deploy-key` field. Once the secret is encrypted and committed to the private secrets repo, you can delete the local copy.
  - **Public key** (`keys/ssh_deploy_key.pub`): paste it into the **public GitHub repo → Settings → Deploy keys → Add deploy key**, and make sure you tick **"Allow write access"**.

  > **Heads-up:** for this key to actually work, the public repo on the VPS needs to be cloned using the **SSH URL form** (`git@github.com:<org>/panoramax-configs.git`), not HTTPS. The auto-upgrade unit sets `GIT_SSH_COMMAND` to use this deploy key, but `GIT_SSH_COMMAND` only works with SSH-protocol remotes. An HTTPS `origin` would just silently bypass the deploy key and the push would fail. Step 2.5 reminds you about this when you clone.

> **No key for the private secrets repo, and that's on purpose.** This deploy key is only for the public repo (auto-upgrade pushes `flake.lock` bumps to `prod`). The VPS never keeps a permanent credential for the private secrets repo; Instead, any time you need to make a change to the secrets, you just connect to the vps using **SSH agent forwarding** every time you SSH in: `ssh -A -p <port> panoramax@<vps>`. Your laptop's sops and GitHub key are used for the duration of that session, and nothing sticks around afterwards. See `spec.md` § Secrets, and step 2.5 below.

- [x] Now that you've got both age pubkeys (yours + the host's), commit `secrets/.sops.yaml` to the **private** secrets repo so that future `sops` calls use the right recipients:

```bash
git -C secrets add .sops.yaml
git -C secrets commit -m "set sops recipients"
git -C secrets push
# Bump the parent's gitlink so the public repo records this commit:
git add secrets
git commit -m "secrets: set sops recipients"
git push
```

- [x] Fill in your personal SSH public key in `instance.nix → admins[].sshKey`. This is the key you use to SSH into servers (like `~/.ssh/id_ed25519.pub`). It's completely unrelated to the age and host keys above. Without this, nixos-anywhere will install a machine you can't actually log into.

### 1.4 NetBird

- [x] Sign up for NetBird hosted (the free tier is fine).
- [x] Create a setup key (used for auto-enrolment into the netbird network). Make sure it's one that's 'reusable' but expires in a week or so.
- [x] Save it under `netbird/setup-key` in `secrets/panoramax-osmbe.yaml`.

The mesh is purely so that the VPS, TrueNAS and any other servers related to this project can communicate with each other over a secure connection.

The VPS NetBird IP gets **auto-assigned** when it first connects. You can't pre-allocate it. The flake itself doesn't reference the VPS IP, but you'll still need it in step 2.7 to lock down the TrueNAS NFS exports and to point Grafana Cloud's Prometheus scrape target at the right IP.

### 1.5 BorgBase

- [x] Sign up at <https://www.borgbase.com>.
- [x] Create a new repo, **enable append-only mode**.
- [x] Create a dedicated SSH key for the BorgBase repo:

```bash
ssh-keygen -t ed25519 -f keys/ssh_borg_key -N "" -C "panoramax-osmbe-borg"
```

- [x] Add the public key (`keys/ssh_borg_key.pub`) to the BorgBase repo's SSH keys list.
- [x] Paste the private key (`keys/ssh_borg_key`) into `secrets/panoramax-osmbe.yaml` under `borg/ssh-key`, and whatever passphrase you pick for Borg encryption (any strong random string) under `borg/passphrase`.
- [x] Save the repo URL to `borg/repo-url` in `secrets/panoramax-osmbe.yaml`.
- [x] Save the BorgBase **ssh-ed25519** host-key value to `borg/host-key`. After you create the borg repo, BorgBase shows a setup page (also reachable at <https://www.borgbase.com/setup>) that lists the SSH host keys for `*.repo.borgbase.com` in three flavours: RSA, ECDSA, and ed25519. Because the key we generated in the previous step is ed25519, the SSH handshake will use BorgBase's ed25519 host key; copy only the `AAAA…` part of the **ssh-ed25519** line (ignore the RSA and ECDSA ones, and don't include the leading hostname; the borgbackup module prepends `*.repo.borgbase.com ` automatically).
> **Note:** BorgBase only gives you an empty SSH endpoint - the actual borg repo at that path doesn't exist on the server side until you run `borg init` against it once. We'll do that in step **3.2** below, once the VPS is up.

### 1.6 OSM OAuth application

Go to `https://www.openstreetmap.org/oauth2/applications`:

- [x] Register a new application called "Panoramax Belgium".
- [x] Set the Redirect URI to `https://panoramax.osm.be/api/auth/redirect`.
- [x] Set the Permission scope to "Read user preferences".
- [x] Copy the Client ID and Secret into the `panoramax.env` block in `secrets/panoramax-osmbe.yaml` (`OAUTH_CLIENT_ID=`, `OAUTH_CLIENT_SECRET=`).

### 1.7 Healthchecks.io

- [x] Create eight checks. The expressions below match the systemd timers in `modules/`; if you change a timer, update its check to match.

| Check | hc.io mode | Expression / Period | Grace |
|---|---|---|---|
| `heartbeat` | **Simple** | Period 5 min | 10 min |
| `nfs-health` | **Simple** | Period 5 min | 10 min |
| `truenas-heartbeat` | **Simple** | Period 5 min | 10 min |
| `pgbackrest` | Cron | `15 * * * *` | 90 min |
| `borgbackup` | Cron | `30 1 * * *` | 6 h |
| `pgdump-s3` | Cron | `30 0 * * *` | 6 h |
| `flake-update` | Cron | `30 3 * * 0` | 6 h |
| `nixos-upgrade` | Cron | `30 4 * * 0` | 6 h |

The 5-minute checks use **Simple** mode (Period 5 min, Grace 10 min). The systemd timers fire every 5 minutes from boot, so pings arrive at e.g. `19:01, 19:06, 19:11, ...` rather than aligned to `:00, :05, :10`. Simple mode measures the gap between pings (interval-based), which is exactly the signal you want: "is the timer still firing every ~5 min?". A Cron expression would technically work too but would treat every real ping as 1-2 min "late" relative to the wall clock.

The scheduled jobs (`pgbackrest`, `borgbackup`, `pgdump-s3`, `flake-update`, `nixos-upgrade`) stay on **Cron**. For those you specifically want "the Sunday 03:30 run didn't happen" to alert - not "$gracedays+grace passed since last ping". Cron's wall-clock alignment is the right semantic.

**Server's Time Zone in the hc.io form (Cron-mode checks only): set it to `UTC`.** Every timer in `modules/` is anchored to UTC explicitly (you'll see `... UTC` on the `OnCalendar` lines), so hc.io needs to be on UTC too or the daily/weekly ones will drift by an hour twice a year when DST flips. The hourly `pgbackrest` (`15 * * * *`) doesn't care - "every hour at :15" matches in any timezone. Simple-mode checks don't have a timezone field; they're timezone-agnostic.

The `truenas-heartbeat` ping is sent from TrueNAS itself (see § 1.9), so the URL doesn't end up in `secrets/panoramax-osmbe.yaml` like the others - it gets pasted directly into a cron job on TrueNAS. Keep it on the same Healthchecks project regardless, so VPS alerts and TrueNAS alerts land in the same place.

> **About reboot-time false alerts:** the `nixos-upgrade` flow deliberately does **not** auto-reboot (see [`OPERATIONS.md` § When nixos-upgrade says "REBOOT REQUIRED"](./OPERATIONS.md#when-nixos-upgrade-says-reboot-required)). When an admin manually `sudo reboot`s after seeing the alert, `heartbeat` and `nfs-health` will skip a couple of pings and may briefly flip red if the boot takes longer than the 10 min grace. That's noise we accept in exchange for keeping the schedules simple. If you want to suppress it: pause `heartbeat` and `nfs-health` on hc.io for ~15 min before rebooting, unpause once the box is back up.

- [x] For each check: open it in the Healthchecks.io UI → click the check → copy the **Ping URL** (the `https://hc-ping.com/<uuid>` link in the integration panel). Paste it under the matching `healthchecks/*` entry in `secrets/panoramax-osmbe.yaml`.

### 1.8 Hetzner Object Storage

- [x] Create a project, then a bucket called `panoramax-osmbe-backups`.
- [x] Generate access keys.
- [x] **Don't enable Object Lock.** It clashes with our tiered retention.
- [x] Save the credentials into the `s3.env` block in `secrets/panoramax-osmbe.yaml` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `S3_BUCKET`).

- [x] Apply the lifecycle XML once from your PC after the bucket is created. Create this file and run the command:

```xml
<!-- /tmp/lifecycle.xml -->
<LifecycleConfiguration>
  <Rule><ID>daily</ID><Status>Enabled</Status>
    <Filter><Prefix>pgdump/daily/</Prefix></Filter>
    <Expiration><Days>7</Days></Expiration></Rule>
  <Rule><ID>weekly</ID><Status>Enabled</Status>
    <Filter><Prefix>pgdump/weekly/</Prefix></Filter>
    <Expiration><Days>30</Days></Expiration></Rule>
  <Rule><ID>monthly</ID><Status>Enabled</Status>
    <Filter><Prefix>pgdump/monthly/</Prefix></Filter>
    <Expiration><Days>365</Days></Expiration></Rule>
</LifecycleConfiguration>
```

```bash
s3cmd -c <your-s3cfg> setlifecycle /tmp/lifecycle.xml s3://panoramax-osmbe-backups
```

### 1.9 TrueNAS

- [x] **Install and enrol the NetBird agent on TrueNAS.** Install the NetBird community app from the TrueNAS app catalog and use its GUI to enrol with the setup key from § 1.4. Once it's connected, the dashboard will show TrueNAS as a peer with a `100.x.y.z` IP. Note that IP; you'll plug it into `instance.nix → netbird.truenasIp` further down.
- [x] Make sure the ZFS pool already exists.
- [x] Create the parent dataset `Panoramax-OSMBE` and two children: `permanent` and `derivates` (French spelling - Panoramax needs this internally; the public URL uses `derivatives` via an nginx alias).
- [x] Create **two** NFS shares - one for each child dataset - with a **temporary** subnet-wide network restriction (because you don't know the VPS IP yet). Maproot=root.
  - `/mnt/rowan-zpool1/Panoramax-OSMBE/permanent`
  - `/mnt/rowan-zpool1/Panoramax-OSMBE/derivates`

  For the temporary restriction, take the TrueNAS NetBird IP from a couple steps back turn it into the subnet version. So if TrueNAS got `100.98.205.52`, use `100.98.0.0/16`. 
  Once NetBird is up (step 2.6), you'll lock both shares down to the specific VPS IP; see step 2.7.
- [x] Now put the TrueNAS NetBird IP into the spot in instance.nix under `netbird.truenasIp`.
- [x] **Create a TrueNAS user `panoramax` with UID `1320`** (Accounts → Users). Set the shell to `/usr/sbin/nologin`. This lets the VPS admin user browse files over NFS without dropping through to the `Other` ACL mask.
- [x] **Add `panoramax` to the ZFS ACLs** for `Panoramax-OSMBE`, `permanent`, and `derivates` with Read | Write | Execute. Apply it recursively if prompted.
- [x] Keep `Maproot User = root` on the NFS exports; the Panoramax Docker containers run as root and need a root→root mapping.
- [x] **Set up the TrueNAS heartbeat cron job.** This is the ground-truth "TrueNAS is alive" ping for the `truenas-heartbeat` check from § 1.7 - it has to fire from TrueNAS itself, since that's the box we want to know about. In the TrueNAS UI → System Settings → Advanced → Cron Jobs (on newer versions: Data Protection → Scheduled Tasks → Cron Jobs), add a job that runs every 5 minutes as `root`:

  ```
  curl -fsS -m 10 --retry 3 https://hc-ping.com/<truenas-heartbeat-uuid> > /dev/null
  ```

  Replace `<truenas-heartbeat-uuid>` with the UUID from the Ping URL of the `truenas-heartbeat` check on Healthchecks.io. The URL lives only in the cron job; it's not in sops because this flake doesn't manage TrueNAS.

### 1.10 Monitoring (Grafana Cloud)

Metrics and dashboards live in **Grafana Cloud**; logs get shipped to **Grafana Cloud Loki** (free tier) over public TLS with basic auth (Grafana Cloud expects User ID + access-policy token, not bearer), so log access survives even when the VPS is down. See `spec.md` § Monitoring for why we set it up this way.

**Loki (logs)**

- [x] Sign up for **Grafana Cloud** (free tier is fine).
- [x] Create a Loki "Send logs" integration; copy the URL, the User ID, and the access-policy token.
- [x] Save `loki/push-url`, `loki/push-user`, and `loki/push-token` into `secrets/panoramax-osmbe.yaml`.
- [x] In Grafana Cloud, add Loki as a data source (use the URL + token from above).

**Prometheus (metrics)** - the scrape config needs the VPS NetBird IP, and you won't have that until step **2.7**. We'll cover it there; for now just make sure Grafana Cloud is reachable and you can configure it.

### 1.11 External uptime monitoring

- [x] UptimeRobot - create checks for `https://panoramax.osm.be/api`, `https://panoramax.osm.be/`. NOTE
- [x] Uptime Kuma (self-hosted) - same checks.

### 1.12 Final pre-deploy verification

The repo ships with OSM-BE values pre-filled, so there are no `SET-ME-…` placeholders to grep for. Walk through these specific fields and replace them with your own.

- [x] **`hosts/panoramax-osmbe/instance.nix`** review:
  - `domain`, `imageDomain` - your DNS records
  - `instanceName` - public-facing name
  - `acmeContactEmail` - your Let's Encrypt contact email
  - `sshPort` - optional; pick a different one if you don't like the default
  - `admins` - your name + SSH public key (and any co-admins)
  - `netbird.truenasIp` - the IP TrueNAS got from § 1.9
  - `nfs.permanentSharePath` and `nfs.derivatesSharePath` - your TrueNAS dataset paths
  - `s3.bucket` - your Hetzner bucket name
  - `diskDevice` - verify with `lsblk` on the VPS in § 2.1
- [x] **`hosts/panoramax-osmbe/panoramax/env.public`** review:
  - `DOMAIN`, `FLASK_SESSION_COOKIE_DOMAIN` - your domain
  - `API_PERMANENT_PICTURES_PUBLIC_URL`, `API_DERIVATES_PICTURES_PUBLIC_URL` - your image domain
  - `INSTANCE_NAME`, `API_SUMMARY` - public-facing branding (the JSON in `API_SUMMARY` has localised name/description fields)
  - `VITE_INSTANCE_NAME`, `VITE_CENTER`, `VITE_ZOOM`, `VITE_TITLE`, `VITE_META_TITLE`, `VITE_META_DESCRIPTION` - see explenations for all of these on the [Panoramax docs site](https://docs.panoramax.fr/frontend/03_Settings/)
- [x] Every secret in `secrets/panoramax-osmbe.yaml` has an actual value.
- [x] `panoramax.enable` in `hosts/panoramax-osmbe/default.nix` is set to **`false`**. It's set to `true` in the committed repo because the live instance is running; set it to `false` for the install. Keep it false until step 2.7; you want nixos-anywhere to install the base system cleanly so you can verify NetBird joined and the NFS mounts are healthy before bringing the Panoramax docker compose stack up.
- [x] In the same file, also set both **`panoramax.backups.borgbackup.enable`** and **`panoramax.backups.pgdumpS3.enable`** to **`false`**. Same reason as above; they're most likely set to `true` in this repo because our live instance has them on. You don't want Borg or the pg_dump→S3 job firing on a half-set-up stack: Borg would happily archive an empty pgbackrest dir and `/fail`-ping Healthchecks every 24h, and pg_dump would try `docker compose exec` on a db service that isn't running yet. Step 3.2 walks you through flipping them on once you've manually verified each backup works. (Note: `pgbackrest` doesn't have its own toggle, it's tied to `panoramax.enable` because it's the local hot backup that lives inside the compose stack itself.)
- [x] `git diff` looks sensible (no surprise changes).

### 1.13 Encrypt + push

- [x] Encrypt the secrets file (in place), commit it to the **private** repo, then bump the parent repo's gitlink:

```bash
sops --config secrets/.sops.yaml --encrypt -i secrets/panoramax-osmbe.yaml

# Make sure it's actually encrypted and decryptable (prints nothing on success):
cat secrets/panoramax-osmbe.yaml
sops --config secrets/.sops.yaml -d secrets/panoramax-osmbe.yaml > /dev/null && echo "decryption OK"

# Commit to the private repo:
git -C secrets add panoramax-osmbe.yaml
git -C secrets commit -m "added encrypted secrets"
git -C secrets push

# Bump the public repo's gitlink and commit instance.nix changes:
git add -A
git commit -m "added instance.nix + secrets pin"
git push
```

- [x] Final sanity check before deploy: make sure the flake resolves to the real file under `?submodules=1`:

```bash
nix eval --raw '.?submodules=1#nixosConfigurations.panoramax-osmbe.config.sops.defaultSopsFile' \
  | grep -q 'panoramax-osmbe.yaml' && echo "OK: real secrets" || echo "BROKEN: dummy fallback"
```

---

## Step 2 - VPS Setup

### 2.1 Provision
 
- [x] Create a Infomaniak VPS with 4 vCPU / 12 GB / 250 GB SSD. (We use Infomaniak but you can use pretty much any VPS provider obv)
- [x] Infomaniak comes with it's own firewall but since we have our own firewal in Nixos (`modules/firewall.nix`) , we're just going to set theirs to allow all. In the Infomaniak control panel of the vps, create a new firewall rule to allow all connections from any port.
- [x] SSH in once using the temporary credentials they gave you.
- [x] Confirm legacy BIOS boot (`[ -d /sys/firmware/efi ] && echo UEFI || echo BIOS`). If it says UEFI, stop. `disko.nix` is built for legacy BIOS (EF02 + GRUB) and you'd need to switch it to ESP + systemd-boot before continuing. (but for Infomaniak we tested and they used BIOS)
- [x] Run `lsblk` and make sure the disk layout matches what `instance.nix` expects:

  ```
  sda   250G   ← NixOS target; BIOS boots this disk first
  sdb    20G   ← Infomaniak OS disk; left untouched
  ```

  Infomaniak gives every VPS two disks: a 250 GB data disk and a 20 GB OS disk that comes with Debian. **The BIOS boots `sda` first.** On a fresh Infomaniak Debian image `sda` is consistently the 250 GB disk; both in the running OS and inside the kexec installer, so `diskDevice = "/dev/sda"` targets the right disk and the BIOS will find NixOS after reboot. If your `lsblk` shows `sda` = 20 GB instead, re-provision a fresh Debian image from the Infomaniak control panel (the old image had the ordering inverted) and check again before running nixos-anywhere.

  NOTE: THIS IS GOING TO BE CHANGED, WE'RE GOING TO SEE IF WE CAN USE SDA FOR THE NIXOS AND JUST USE SDA FOR SRV/ or something.

### 2.2 DNS

- [x] Open a PR to `osmbe/dns` to add A + AAAA records for both `panoramax.osm.be` and `images.panoramax.osm.be`, both pointing to the VPS.
- [x] Wait for propagation (`dig panoramax.osm.be`, `dig AAAA panoramax.osm.be`).

### 2.3 nixos-anywhere

All commands in this step run on **your dev machine**, not the VPS. nixos-anywhere SSHes into the Infomaniak VPS as root, kexecs into a NixOS installer (auto-downloaded from `nix-community/nixos-images` for x86_64 - no `--kexec` flag needed), partitions the disk per `disko.nix`, installs the flake, and reboots into the new system.

- [x] Build the `--extra-files` tree. `--extra-files <dir>` copies the *contents* of `<dir>` into the new filesystem root, so the directory needs to mirror the target paths. **Only the host SSH key goes here**. The deploy key and borg key live in sops, never as plaintext files on the VPS.

```bash
mkdir -p extra-files/etc/ssh
install -m 600 keys/ssh_host_ed25519_key     extra-files/etc/ssh/ssh_host_ed25519_key
install -m 644 keys/ssh_host_ed25519_key.pub extra-files/etc/ssh/ssh_host_ed25519_key.pub
```

The `--extra-files` injection is **mandatory**. Without the pre-generated host key, the VPS won't be able to decrypt its own sops secrets (a freshly-generated host key wouldn't be a recipient on any encrypted file).

- [x] Run `nixos-anywhere`. Notice the `?submodules=1` on the flake URL. That's what tells Nix to include the secrets submodule contents in the build, instead of using the dummy fallback. The `--generate-hardware-config` flag tells nixos-anywhere to write the real `hardware-configuration.nix` directly into your local flake checkout during install (overwriting the stub):

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake '.?submodules=1#panoramax-osmbe' \
  --extra-files extra-files \
  --generate-hardware-config nixos-generate-config hosts/panoramax-osmbe/hardware-configuration.nix \
  debian@<vps-public-ip> 2>&1 | tee nixos-anywhere-$(date +%Y%m%d-%H%M%S).log
```

  > **If you forget `?submodules=1`:** the build silently uses `secrets-dummy.yaml`. Because you set `panoramax.enable = false` in § 1.12 for the install, the install will still complete, but `/run/secrets/` will be empty (no NetBird enrolment, no Loki credentials, etc...).

- [x] After install, clean up the local copy of the host key (you no longer need it):

```bash
rm -rf extra-files
```

The host private key now lives on the VPS at `/etc/ssh/ssh_host_ed25519_key`; the copy in `keys/` isn't needed for day-to-day operation anymore. You can keep `keys/ssh_host_ed25519_key` as a disaster-recovery backup if you want (`keys/` is gitignored), but the canonical location is the VPS.

### 2.4 Commit hardware-configuration.nix

- [x] `--generate-hardware-config` already wrote the real file into your working tree. Check the diff and commit it:

```bash
git diff hosts/panoramax-osmbe/hardware-configuration.nix
git add hosts/panoramax-osmbe/hardware-configuration.nix
git commit -m "add real hardware-configuration.nix" && git push
```

### 2.5 SSH in (with agent forwarding) and clone the repo

- [x] Start the SSH agent on your laptop, load your GitHub key, then SSH in with `-A` so the VPS can use your laptop's key for the duration of the session:

```bash
eval "$(ssh-agent -s)" && ssh-add
ssh -A -p 58422 panoramax@<vps-ip>
# on the VPS:
sudo mkdir -p /srv/panoramax-configs && sudo chown panoramax /srv/panoramax-configs
# IMPORTANT: use the SSH URL form (git@github.com:org/repo.git), NOT HTTPS.
# The auto-upgrade unit's deploy key authenticates over SSH only; an HTTPS origin would silently bypass it and fail later pushes.
git clone --recurse-submodules \
  git@github.com:<your-org>/panoramax-configs.git /srv/panoramax-configs

# The box runs from `prod`, not `main` (see § 1.2). Switch the checkout now;
# subsequent rebuilds and the auto-upgrade unit both expect to be on `prod`.
cd /srv/panoramax-configs
git checkout prod
```

`--recurse-submodules` clones the public repo *and* the private `panoramax-secrets` submodule into `secrets/` in one step. The submodule clone uses your forwarded SSH agent; no permanent credential gets left on the VPS.

Agent forwarding is **always** how the VPS reaches the private secrets repo; both for this initial clone and for every later `git submodule update` after you rotate a secret. Get into the habit: any operation that touches `secrets/` requires you to have SSH'd in with `-A`. If you forget, the operation just fails. There's no silent fallback.

Regular reads from the public repo (`git pull` on `prod`) don't need agent forwarding; only submodule operations do. The auto-upgrade timer's *push* of `flake.lock` bumps uses the deploy key in sops, so that's also unaffected by agent forwarding.

- [x] Set `submodule.recurse = true` for this checkout so future `git pull`s update both layers automatically:

```bash
cd /srv/panoramax-configs
git config submodule.recurse true
```

### 2.6 Verify NetBird and sops

- [x] Check that NetBird is connected and sops decryption actually works:

```bash
sudo ip -4 addr show wt0   # should show a 100.x.y.z address
sudo ls -l /run/secrets/   # should list netbird/, panoramax/, healthchecks/, etc.
sudo cat /run/secrets/netbird/setup-key | head -c 8 && echo …  # decryption works
```

### 2.7 Wire up the VPS NetBird IP everywhere

The VPS now has a NetBird IP. Two external systems still need to know it.

- [x] Grab the auto-assigned VPS NetBird IP (`ip -4 addr show wt0`) or look it up on the NetBird dashboard.
- [x] Lock down both TrueNAS NFS exports to the VPS NetBird IP (they were on a temporary subnet rule from step 1.9).
- [x] SSH in as `panoramax` and check that `cd /srv/panoramax/pictures/permanent` and `derivates/` both work without a permission denied. If they fail, the TrueNAS `panoramax` user UID probably doesn't match the VPS `panoramax` UID (should be `1320`).
- [x] In Grafana Cloud, configure scraping for the VPS using its NetBird IP. If you run a Prometheus or Grafana Agent on a NetBird peer, add a scrape job like this:

```yaml
  - job_name: "panoramax-osmbe"
    static_configs:
      - targets: ["<vps-netbird-ip>:9100"]
        labels:
          host: "panoramax-osmbe"
```

  The global `scrape_interval` (15s) is fine; no per-job override needed. Reload the local scraper if applicable. Check in Grafana Cloud that the `panoramax-osmbe` target shows `UP`. (A `DOWN` with connection-refused usually means NetBird isn't connected on one end; the firewall on the VPS only scopes 9100 to `wt0`.)

- [x] In `hosts/panoramax-osmbe/default.nix`, switch `panoramax.enable` from `false` to `true`.
- [x] Commit, push.

Then on the VPS:

```bash
cd /srv/panoramax-configs
git pull --ff-only                      # also pulls the submodule because of submodule.recurse=true
sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'
```

`?submodules=1` is required on every rebuild from now on. It's how Nix sees the secrets file. Without it, the build silently falls back to `secrets-dummy.yaml` and the stack would start with placeholder credentials.

### 2.8 Verify the stack

- [x] Check the stack status:

```bash
systemctl status panoramax
panoramax-status   # wrapper around `docker compose ... ps`. Without it, raw `docker compose ps` floods you with "variable is not set" warnings because compose can't see /run/panoramax.env.
curl -sf https://panoramax.osm.be/api | head -c 200
```

- [x] Open <https://panoramax.osm.be> in your browser.

### 2.9 Test login + upload

- [x] Log in via OSM OAuth.
- [x] Upload a test sequence.
- [x] Confirm it reaches the worker, gets blurred (via OSM-FR's blur API), and shows up on the map.

### 2.10 Promote your account

- [x] Make your account an admin:

```bash
docker exec -it $(docker ps -qf name=api) panoramax_backend user --set-role admin <your-osm-username>
```

### 2.11 (Optional) verify Postgres over an SSH tunnel

Postgres is bound to `127.0.0.1:5432` on the VPS, so you reach it from your laptop by tunnelling the port through SSH. From your dev machine:

```bash
# leave this running in one terminal
ssh -N -L 5433:127.0.0.1:5432 -p 58422 panoramax@<vps-public-ip>

# in another terminal - connect to localhost:5433, NOT the VPS IP
psql -h localhost -p 5433 -U gvs geovisio -c '\dt'
```

---

## Step 3 - Post-launch

### 3.1 VPS provider snapshot

- [x] Take an Infomaniak snapshot now so you have a rollback baseline.

### 3.2 Verify backups (and enable the external ones)

pgBackRest is already running (it's tied to `panoramax.enable`). The other two are still off from step 1.12. The plan here is: trigger pgBackRest manually first to confirm it works, then flip the Borg + pg_dump toggles on, rebuild, and trigger those too.

- [x] **pgBackRest** - manually fire an incremental and confirm the Healthchecks ping:

```bash
sudo systemctl start pgbackrest-incr.service
journalctl -u pgbackrest-incr.service -n 50 --no-pager
```

  Check the `pgbackrest` check on Healthchecks.io went green. If it didn't, fix that before going any further; the other two backups are downstream of pgBackRest's output dir.

- [x] **Flip the external backup toggles on.** In `hosts/panoramax-osmbe/default.nix`, set both `panoramax.backups.borgbackup.enable` and `panoramax.backups.pgdumpS3.enable` to `true`. Commit, push. On the VPS: git pull and nixos-rebuild switch.

- [x] **Initialise the borg repo on BorgBase (one-time).** The systemd unit only runs `borg create` and `borg prune` - it never runs `borg init`, so without this the first backup would fail with `is not a valid repository. Check repo config.`. Run on the VPS as root (the SSH key lives at `/root/.ssh/borg-backup-key`):

```bash
sudo bash -c '
  export BORG_REPO=$(cat /run/secrets/borg/repo-url)
  export BORG_PASSCOMMAND="cat /run/secrets/borg/passphrase"
  export BORG_RSH="ssh -i /root/.ssh/borg-backup-key -o StrictHostKeyChecking=accept-new"
  borg init --encryption=repokey-blake2
'
```

  `repokey-blake2` is the encryption mode the unit script expects: the key is stored inside the repo and decrypted by the passphrase in sops (`BORG_PASSCOMMAND`). Don't use `none` or `keyfile` here - those don't match how the script is wired.

- [x] **BorgBackup** - manually fire it and confirm the Healthchecks ping:

```bash
sudo systemctl start borgbackup-panoramax.service
journalctl -u borgbackup-panoramax.service -n 50 --no-pager
```

- [x] **pg_dump → S3** - same drill:

```bash
sudo systemctl start pgdump-s3.service
journalctl -u pgdump-s3.service -n 50 --no-pager
```

  All three Healthchecks.io checks (`pgbackrest`, `borgbackup`, `pgdump-s3`) should now be green. The respective systemd timers take it from here on the regular schedule.

### 3.3 Terms of Service (mandatory)

- [ ] The compose env already has `API_ENFORCE_TOS_ACCEPTANCE=True`. Set the actual TOS content through the API:

```bash
PUT https://panoramax.osm.be/api/pages/terms-of-service
```

(check the upstream Panoramax API docs for the exact body format).

### 3.4 Belgium-only excluded area (required)

- [ ] Restrict uploads to Belgium and exclude military bases:

```bash
POST https://panoramax.osm.be/api/excluded-areas?invert=true
Content-Type: application/json

{ <Belgium GeoJSON> }
```

### 3.5 Register with the Panoramax metacatalog

- [ ] Contact the Panoramax team (panoramax-contact@panoramax.fr) to get `panoramax.osm.be` added to the federation/metacatalog.

### 3.6 Enable auto-upgrade (only after a stable week)

- [x] Once the instance has run cleanly for at least 7 days, turn auto-upgrade on in `hosts/panoramax-osmbe/default.nix`. The toggle goes next to the other `panoramax.*` ones (alongside `panoramax.enable` and the two `panoramax.backups.*` flags):

```nix
panoramax.autoUpgrade.enable = true;
```

- [x] Commit, push, and on the VPS `git pull && sudo nixos-rebuild switch --flake '.?submodules=1#panoramax-osmbe'`. Without flipping the toggle on first, the `flake-lock-update` and `nixos-upgrade` units don't exist (the whole module is wrapped in `lib.mkIf`), so there's nothing to fire manually.

- [x] **Don't wait for Sunday to find out it's broken.** Fire both units by hand once so you've actually seen them succeed before the scheduled run. They're two separate services on purpose - so a flaky `git push` doesn't wedge the rebuild and vice versa - so test them separately:

```bash
# 1. flake.lock bump + push to prod. Should ping `flake-update` green on Healthchecks.
sudo systemctl start flake-lock-update.service
journalctl -u flake-lock-update.service -n 200 --no-pager

# 2. rebuild from the committed lockfile. Won't auto-reboot. If a reboot is
#    needed it'll fail-ping Healthchecks and write /var/lib/nixos-upgrade/reboot-pending.
sudo systemctl start nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 200 --no-pager
```

  > **Heads-up about the reboot behaviour:** `nixos-upgrade` deliberately **does not call `systemctl reboot`**. If the rebuild produces a new kernel/initrd/modules, the unit posts a `/fail` ping to Healthchecks with body `BUILD SUCCEEDED — REBOOT REQUIRED ...` and writes a sentinel at `/var/lib/nixos-upgrade/reboot-pending`. To actually finish the upgrade, an admin SSHes in and runs `sudo reboot` at their convenience. The `nixos-upgrade-postboot.service` runs on next boot, notices `booted == built`, removes the sentinel, and pings success → the check goes green again. See [`OPERATIONS.md` § When nixos-upgrade says "REBOOT REQUIRED"](./OPERATIONS.md#when-nixos-upgrade-says-reboot-required).

  After both runs go green, the timers (Sun 03:30 + 04:30 UTC) take it from there. The first scheduled run won't double-fire today - timers only trigger on the OnCalendar match.

---

## Troubleshooting common deploy failures

| Symptom | Likely cause | Fix |
|---|---|---|
| sops decryption fails on VPS | host SSH key not injected via `--extra-files` | Rerun nixos-anywhere with `--extra-files keys/`, or copy the pre-generated key into `/etc/ssh/`. |
| Caddy can't get TLS cert | DNS not propagated / Caddy can't bind 80 | `dig` the records; `journalctl -u caddy`. |
| `db` container won't build | apt-fetch failure inside Dockerfile.db | Check `journalctl -u panoramax-build-db`; usually transient - restart the unit. |
| `panoramax.service` won't start and you need to debug | Need real-time compose startup output | Flip `panoramax.composeAutoStart = false`, rebuild, run `docker compose up` manually. See `OPERATIONS.md`. |
| NFS mount fails at boot | TrueNAS unreachable | Check NetBird ACL; the system boots anyway thanks to `nofail`, but `panoramax.service` won't start. |
