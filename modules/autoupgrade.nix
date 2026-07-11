{ config, lib, pkgs, instance, ... }:
let
  repoDir = instance.repoPath;
  upgradeBranch = "prod";
in
{
  # Auto-upgrade is gated by a NixOS option so the operator can enable it
  # *after* the instance has been stable for a week (per DECISIONS.md).
  # Enable by setting `panoramax.autoUpgrade.enable = true` in instance.nix
  # or another module — but DON'T enable on the first deploy.
  options.panoramax.autoUpgrade.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Enable the weekly flake.lock auto-update + nixos-rebuild timer.
      Disabled by default so the first-week deploy can stabilise. Flip to
      true after manually confirming the system is healthy.
    '';
  };

  config = lib.mkIf config.panoramax.autoUpgrade.enable {
    sops.secrets = {
      "git/deploy-key" = {
        mode = "0400";
        owner = "root";
        path = "/root/.ssh/deploy-key";
      };
      "healthchecks/flake-update-url".mode = "0400";
      "healthchecks/nixos-upgrade-url".mode = "0400";
    };

    # 1. Weekly flake.lock update + commit + push to `prod`. Sunday 03:30 UTC.
    # 2. Weekly nixos-rebuild from the committed lockfile. Sunday 04:30 UTC,
    #    after backups, with a heartbeat blind-spot to 05:00.
    #
    # The two units are deliberately separate runs so a flaky push doesn't
    # wedge the rebuild step (and vice versa).

    systemd.services.flake-lock-update = {
      description = "Weekly: update flake.lock, commit, push to ${upgradeBranch}";
      path = with pkgs; [ gitMinimal nix curl coreutils openssh ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Bound the run so it can't hang into the rebuild window. If a
        # GitHub network blip or a hung `nix flake update` would otherwise
        # straddle 04:30, this stops it cleanly and the next nixos-upgrade
        # falls back to whatever prod was last week (graceful no-op).
        TimeoutStartSec = "30min";
        # HOME: systemd doesn't set it; `git config --global` needs it.
        # GIT_CONFIG_*: override the `submodule.recurse=true` set in the
        # local .git/config (admins want it on for manual pulls). Auto-
        # upgrade only touches the public repo; recursing into `secrets/`
        # would try the private repo with a key it isn't authorised for.
        Environment = [
          "HOME=/root"
          "GIT_CONFIG_COUNT=1"
          "GIT_CONFIG_KEY_0=submodule.recurse"
          "GIT_CONFIG_VALUE_0=false"
          "GIT_AUTHOR_NAME=panoramax-auto-upgrade"
          "GIT_AUTHOR_EMAIL=auto-upgrade@${instance.hostName}"
          "GIT_COMMITTER_NAME=panoramax-auto-upgrade"
          "GIT_COMMITTER_EMAIL=auto-upgrade@${instance.hostName}"
        ];
      };
      script = ''
        set -euo pipefail
        export GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy-key -o StrictHostKeyChecking=accept-new"
        url=$(cat /run/secrets/healthchecks/flake-update-url)
        curl -fsS -m 10 --retry 3 "$url/start" || true

        # The repo is owned by the `panoramax` user but this unit runs as root.
        # Without this, git refuses to operate with "dubious ownership".
        git config --global --add safe.directory ${repoDir}
        git config --global --add safe.directory ${repoDir}/secrets

        cd ${repoDir}
        git fetch origin

        # Refuse to proceed if there are uncommitted local edits — `git reset
        # --hard` would silently destroy them. Operator handles those manually.
        if [ -n "$(git status --porcelain | grep -v '^?? ')" ]; then
          curl -fsS -m 10 --retry 3 "$url/fail" \
            -d "uncommitted local changes on ${repoDir}; refusing auto-upgrade." || true
          exit 1
        fi

        # Same for committed-but-unpushed local commits: `git reset --hard
        # origin/${upgradeBranch}` would discard them. Refuse with a /fail ping
        # naming the affected branch so the operator can rescue them.
        git checkout ${upgradeBranch} || git checkout -b ${upgradeBranch} origin/${upgradeBranch}
        ahead=$(git rev-list --count origin/${upgradeBranch}..HEAD || echo 0)
        if [ "$ahead" != "0" ]; then
          curl -fsS -m 10 --retry 3 "$url/fail" \
            -d "$ahead local commits on ${upgradeBranch} ahead of origin; refusing to discard." || true
          exit 1
        fi

        git reset --hard origin/${upgradeBranch}

        # Capture nix flake update output so we can post it as the /fail body
        # if the update or commit step blows up (e.g. registry rate-limit,
        # narHash mismatch, network blip).
        log=$(mktemp)
        if ! nix flake update --commit-lock-file \
             --commit-lockfile-summary "auto: weekly flake.lock bump" \
             2>&1 | tee "$log"; then
          curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@$log" || true
          exit 1
        fi

        # Don't auto-resolve conflicts. If the push is rejected, ping /fail
        # with the git output so the operator sees what happened.
        if ! git push origin ${upgradeBranch} 2> /tmp/push-error; then
          curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@/tmp/push-error" || true
          exit 1
        fi

        curl -fsS -m 10 --retry 3 "$url" -d "flake.lock pushed at $(date -u +%FT%TZ)" || true

        # Restore repo ownership to the admin user. This service runs as root,
        # and git operations create root-owned files under .git/ that later
        # break `git pull` for the operator. See solve_sudo_git.md.
        chown -R ${instance.adminUser}: ${repoDir}
      '';
    };

    systemd.timers.flake-lock-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 03:30:00 UTC";
        Persistent = true;
      };
    };

    # State file: nixos-upgrade writes it when a reboot becomes pending.
    # nixos-upgrade-postboot reads + removes it on first successful boot.
    systemd.tmpfiles.rules = [ "d /var/lib/nixos-upgrade 0755 root root - -" ];

    systemd.services.nixos-upgrade = {
      description = "Weekly: nixos-rebuild switch from committed lockfile (no auto-reboot; alerts when reboot pending)";
      after = [ "flake-lock-update.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ gitMinimal nix nixos-rebuild curl coreutils openssh ];
      # If the rebuild changes this unit's own definition, systemd will try to
      # restart the service mid-run without these flags. Same fix as upstream's
      # nixos-rebuild auto-upgrade module.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HOME=/root"
          "GIT_CONFIG_COUNT=1"
          "GIT_CONFIG_KEY_0=submodule.recurse"
          "GIT_CONFIG_VALUE_0=false"
        ];
      };
      script = ''
        set -euo pipefail
        export GIT_SSH_COMMAND="ssh -i /root/.ssh/deploy-key -o StrictHostKeyChecking=accept-new"
        url=$(cat /run/secrets/healthchecks/nixos-upgrade-url)
        curl -fsS -m 10 --retry 3 "$url/start" || true

        git config --global --add safe.directory ${repoDir}
        git config --global --add safe.directory ${repoDir}/secrets

        cd ${repoDir}
        git fetch origin
        git checkout ${upgradeBranch}
        git reset --hard origin/${upgradeBranch}

        # --no-update-lock-file: build from the committed lockfile, NOT a freshly
        # fetched one. Without this flag, the rebuild bypasses the just-pushed
        # commit and re-fetches, defeating the point of the two-step design.
        #
        # Capture stdout+stderr so a failed rebuild posts the error to
        # Healthchecks as the /fail body. Without this you only see "ping
        # missing" and have to SSH in to find the actual nix error.
        log=$(mktemp)
        if ! nixos-rebuild switch \
             --flake '.?submodules=1#${instance.hostName}' \
             --no-update-lock-file 2>&1 | tee "$log"; then
          curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@$log" || true
          exit 1
        fi

        # Reboot only when the kernel, initrd, or kernel modules actually
        # changed. Comparing the profile symlink would reboot on every
        # activation-only change (e.g. a Caddy reload), which is wasteful.
        booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
        built=$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})

        # Include the last 20 lines of rebuild output in the success body so
        # you can see what activated (or which generation got built) without
        # SSHing in.
        tail=$(tail -n 20 "$log")
        if [ "$booted" != "$built" ]; then
          # Don't auto-reboot. Mark the state, fail-ping with an obvious body,
          # let an admin run `sudo reboot` whenever it suits them.
          # nixos-upgrade-postboot.service will clear the red on next boot.
          echo "pending since $(date -u +%FT%TZ)" > /var/lib/nixos-upgrade/reboot-pending
          curl -fsS -m 10 --retry 3 "$url/fail" --data-raw \
            "BUILD SUCCEEDED — REBOOT REQUIRED at $(date -u +%FT%TZ)
kernel/initrd/modules changed; run \`sudo reboot\` on the VPS at your convenience.

--- last 20 lines ---
$tail" || true
        else
          # Belt-and-braces: an in-place activation without a reboot still
          # closes the loop if there was a stale sentinel from a previous run.
          rm -f /var/lib/nixos-upgrade/reboot-pending
          curl -fsS -m 10 --retry 3 "$url" --data-raw \
            "rebuild ok, no reboot needed at $(date -u +%FT%TZ)

--- last 20 lines ---
$tail" || true
        fi

        # Restore repo ownership to the admin user. This service runs as root,
        # and git operations create root-owned files under .git/ that later
        # break `git pull` for the operator. See solve_sudo_git.md.
        chown -R ${instance.adminUser}: ${repoDir}
      '';
    };

    systemd.timers.nixos-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 04:30:00 UTC";
        Persistent = true;
      };
    };

    # Fires once per boot. If nixos-upgrade left a "reboot-pending" sentinel
    # and the freshly-booted system now matches the built profile, the reboot
    # admin promised has happened — clear the sentinel and ping success so
    # Healthchecks goes green again. Without this, the check stays red until
    # the next weekly run.
    systemd.services.nixos-upgrade-postboot = {
      description = "Clear nixos-upgrade reboot-pending state on successful boot";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ curl coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        if [ ! -f /var/lib/nixos-upgrade/reboot-pending ]; then
          exit 0
        fi

        booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
        built=$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})
        if [ "$booted" = "$built" ]; then
          rm -f /var/lib/nixos-upgrade/reboot-pending
          url=$(cat /run/secrets/healthchecks/nixos-upgrade-url)
          curl -fsS -m 10 --retry 3 "$url" --data-raw \
            "reboot done, booted == built at $(date -u +%FT%TZ)" || true
        fi
      '';
    };
  };
}
