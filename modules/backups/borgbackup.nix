{ config, lib, pkgs, ... }:
{
  # Gated on panoramax.enable AND a per-job toggle. The stack-level gate is
  # because /srv/panoramax/pgbackrest is empty/missing when the stack is off —
  # Borg would silently back up garbage and report success. The per-job toggle
  # is so a fresh fork of this repo can defer external-system backups until
  # the stack is verified working (see DEPLOY.md § 1.12 / § 3.2).
  config = lib.mkIf (config.panoramax.enable
                  && config.panoramax.backups.borgbackup.enable) {
  # Borg expects an SSH-style path for its identity file (not /run/secrets/...).
  # Pin the key at /root/.ssh/borg-backup-key via sops.secrets path option.
  sops.secrets = {
    "borg/passphrase".mode = "0400";
    "borg/ssh-key" = {
      mode = "0400";
      owner = "root";
      path = "/root/.ssh/borg-backup-key";
    };
    "borg/repo-url".mode = "0400";
    "borg/host-key".mode = "0400";
    "healthchecks/borgbackup-ping-url".mode = "0400";
  };

  # The BorgBase host key lives in sops because publishing it on the public
  # repo discloses which BorgBase repo we use. Append it to known_hosts at
  # boot so subsequent `ssh` calls don't prompt.
  systemd.services.borg-known-hosts = {
    description = "Append BorgBase host key from sops to /root/.ssh/known_hosts";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -e
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh
      key="*.repo.borgbase.com $(cat /run/secrets/borg/host-key)"
      grep -qF "$key" /root/.ssh/known_hosts 2>/dev/null || \
        echo "$key" >> /root/.ssh/known_hosts
      chmod 644 /root/.ssh/known_hosts
    '';
  };

  # Custom unit (instead of services.borgbackup.jobs) because the job module
  # renders `repo` into the unit at NIX EVALUATION time as a literal string,
  # which means a shell expansion like "$(cat /run/secrets/...)" stays
  # literal. We need the repo URL read at exec time, so this owns the unit
  # directly and exports BORG_REPO from sops via a shell script.
  systemd.services.borgbackup-panoramax = {
    description = "Daily BorgBackup of /srv/panoramax/pgbackrest to BorgBase";
    after = [ "borg-known-hosts.service" ];
    requires = [ "borg-known-hosts.service" ];
    path = with pkgs; [ borgbackup curl coreutils openssh ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    script = ''
      set -euo pipefail

      url=$(cat /run/secrets/healthchecks/borgbackup-ping-url)
      curl -fsS -m 10 --retry 3 "$url/start" || true

      export BORG_REPO=$(cat /run/secrets/borg/repo-url)
      export BORG_PASSCOMMAND="cat /run/secrets/borg/passphrase"
      export BORG_RSH="ssh -i /root/.ssh/borg-backup-key -o StrictHostKeyChecking=accept-new"

      archive="panoramax-$(date -u +%Y%m%d-%H%M%S)"

      # Backup target is the pgBackRest repo, NOT Postgres directly.
      # pgBackRest already stitches WAL + bundling correctly; layering Borg
      # over that gives a single, consistent backup chain.
      if borg create --compression zstd,3 --stats "::$archive" /srv/panoramax/pgbackrest; then
        # Prune retention. BorgBase append-only is "delayed deletion" — the
        # server marks archives for deletion, real purge happens via BorgBase
        # compaction (manual or scheduled in the dashboard).
        borg prune --keep-daily 14 --keep-weekly 8 --keep-monthly 12 ::
        curl -fsS -m 10 --retry 3 "$url" -d "borg ok $archive at $(date -u +%FT%TZ)" || true
      else
        ec=$?
        curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@/dev/stdin" \
          < <(journalctl -u borgbackup-panoramax.service -n 50 --no-pager) || true
        exit $ec
      fi
    '';
  };

  # Daily 01:30 UTC, before the upgrade reboot window.
  systemd.timers.borgbackup-panoramax = {
    description = "Daily BorgBackup (01:30 UTC)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 01:30:00 UTC";
      Persistent = true;
    };
  };
  };
}
