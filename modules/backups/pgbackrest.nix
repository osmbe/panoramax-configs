{ config, lib, pkgs, ... }:
let
  # Run a pgbackrest subcommand inside the db container via `compose exec`
  # so we don't depend on the compose-derived container name (which changes
  # if COMPOSE_PROJECT_NAME or the working directory changes).
  composeExec = "${pkgs.docker}/bin/docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env exec -T -u postgres db";
  # Single-line string (NOT a `''…''` multiline) — the trailing newline of a
  # multiline interpolated into `if ${...}; then` would parse as `if <cmd>\n; then`,
  # a bash syntax error.
  pgbInContainer = cmd: "${composeExec} pgbackrest --stanza=panoramax ${cmd}";
in
{
  # Gated on panoramax.enable: backup units are pointless (and noisy /fail
  # pings) when the stack isn't running. Re-enabled automatically once the
  # operator flips panoramax.enable = true.
  config = lib.mkIf config.panoramax.enable {
  sops.secrets."healthchecks/pgbackrest-ping-url" = { mode = "0400"; };

  # Stanza initialization. Runs once after the stack starts; idempotent
  # (pgbackrest happily reports "already exists"). Restart-on-failure with
  # rate limiting handles a slow first-boot db.
  systemd.services.pgbackrest-stanza-init = {
    description = "Initialise pgBackRest stanza (idempotent)";
    after = [ "panoramax.service" ];
    requires = [ "panoramax.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "30s";
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
    };
    script = ''
      set -e
      ${pgbInContainer "stanza-create"} || true
      ${pgbInContainer "check"}
    '';
  };

  # Hourly incremental + weekly Sunday-02:30 full.
  systemd.services.pgbackrest-incr = {
    description = "pgBackRest hourly incremental backup";
    # Only `after`, not `requires`: if panoramax.service is stopped
    # (rebuild/restart) while a backup is mid-flight, we want the backup to
    # finish, not be killed by stop-propagation.
    after = [ "panoramax.service" ];
    path = [ pkgs.docker pkgs.curl ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -e
      url=$(cat /run/secrets/healthchecks/pgbackrest-ping-url)
      curl -fsS -m 10 --retry 3 "$url/start" || true
      if ${pgbInContainer "backup --type=incr"}; then
        curl -fsS -m 10 --retry 3 "$url" -d "incremental ok at $(date -u +%FT%TZ)" || true
      else
        curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@/dev/stdin" \
          < <(journalctl -u pgbackrest-incr.service -n 50 --no-pager) || true
        exit 1
      fi
    '';
  };

  systemd.services.pgbackrest-full = {
    description = "pgBackRest weekly full backup";
    after = [ "panoramax.service" ];
    path = [ pkgs.docker pkgs.curl ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -e
      url=$(cat /run/secrets/healthchecks/pgbackrest-ping-url)
      curl -fsS -m 10 --retry 3 "$url/start" || true
      if ${pgbInContainer "backup --type=full"}; then
        curl -fsS -m 10 --retry 3 "$url" -d "full ok at $(date -u +%FT%TZ)" || true
      else
        curl -fsS -m 10 --retry 3 "$url/fail" --data-binary "@/dev/stdin" \
          < <(journalctl -u pgbackrest-full.service -n 50 --no-pager) || true
        exit 1
      fi
    '';
  };

  systemd.timers.pgbackrest-incr = {
    description = "Hourly pgBackRest incremental";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:15:00 UTC";
      Persistent = true;
    };
  };

  systemd.timers.pgbackrest-full = {
    description = "Weekly pgBackRest full backup (Sunday 02:30 UTC)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 02:30:00 UTC";
      Persistent = true;
    };
  };
  };
}
