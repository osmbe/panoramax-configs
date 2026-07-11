{ config, lib, pkgs, instance, ... }:
let
  cfg = config.panoramax;
  composeDir = ./../hosts + "/${instance.hostName}/panoramax";

  # Files mirrored into /etc/panoramax/. Reading via environment.etc puts them
  # in the Nix store and exposes them at a stable path the compose stack can
  # bind-mount. Changes here re-trigger panoramax.service via reloadTriggers.
  composeFiles = {
    "panoramax/docker-compose.yml".source = "${composeDir}/docker-compose.yml";
    "panoramax/Dockerfile.db".source = "${composeDir}/Dockerfile.db";
    "panoramax/postgresql.conf".source = "${composeDir}/postgresql.conf";
    "panoramax/pgbackrest.conf".source = "${composeDir}/pgbackrest.conf";
    "panoramax/nginx.conf".source = "${composeDir}/nginx.conf";
    "panoramax/robots.txt".source = "${composeDir}/robots.txt";
    "panoramax/env.public".source = "${composeDir}/env.public";
    "panoramax/logo.png".source = "${composeDir}/logo.png";
    "panoramax/favicon.ico".source = "${composeDir}/favicon.ico";
  };
in {
  options.panoramax = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # Defaults to false so nixos-anywhere can install the base system
      # cleanly: the operator gets a chance to verify NetBird has joined and
      # the TrueNAS NFS mounts are reachable before the compose stack tries
      # to start (panoramax.service has RequiresMountsFor on both NFS paths).
      default = false;
      description = ''
        Master switch for the Panoramax docker-compose stack. Leave false on
        first boot; flip true once the operator has SSH'd in and confirmed
        the mesh is up and the NFS mounts are healthy.
      '';
    };

    composeAutoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When false, systemd will not start/stop the Panoramax compose stack.
        The env-merge and db-build units still run, but containers must be
        started manually with docker compose up. Flip to false when debugging
        startup issues.
      '';
    };

    # Backup toggles. pgBackRest isn't here on purpose — it's the local hot
    # backup and lives in the same compose stack as the db; it makes no sense
    # to defer. Borg and pg_dump-to-S3 both push to external systems and are
    # the ones you want off on first boot until the stack is verified.
    backups.borgbackup.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Daily BorgBackup of /srv/panoramax/pgbackrest to BorgBase. Leave off
        until the stack is healthy and you've verified pgBackRest is producing
        real backups; otherwise Borg ships an empty/garbage repo and the
        first healthcheck ping reports success on nothing.
      '';
    };

    backups.pgdumpS3.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Daily logical pg_dump uploaded to S3 (Hetzner Object Storage). Leave
        off until the stack is healthy; pg_dump runs via `docker compose exec`
        on the db service so it fails noisily (and /fail-pings every 24h) if
        the stack isn't actually running yet.
      '';
    };
  };

  config = lib.mkMerge [
    # Always mirror the compose-stack files into /etc, even when the stack
    # itself is disabled — this lets the operator inspect them on the host
    # without going into the Nix store.
    {
      environment.etc = composeFiles;

      sops.secrets."panoramax/env" = {
        mode = "0400";
        owner = "root";
      };
    }

    (lib.mkIf cfg.enable (lib.mkMerge [
      {
      # 1. Merge env.public + decrypted sops env into /run/panoramax.env.
      systemd.services.panoramax-env-merge = {
        description =
          "Build /run/panoramax.env from env.public + sops fragment";
        before = [ "panoramax.service" ];
        requiredBy = [ "panoramax.service" ];
        restartTriggers = [ config.environment.etc."panoramax/env.public".source ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          umask 077
          out=/run/panoramax.env
          tmp=$(mktemp /run/panoramax.env.XXXXXX)
          cat /etc/panoramax/env.public > "$tmp"
          printf '\n' >> "$tmp"
          cat /run/secrets/panoramax/env >> "$tmp"
          mv "$tmp" "$out"
        '';
      };

      # 2. Build the custom db image up-front. Doing this in a separate unit
      #    surfaces apt failures clearly, instead of hiding them inside a
      #    `docker compose up` invocation.
      systemd.services.panoramax-build-db = {
        description =
          "Build local panoramax-osmbe/db image (postgis + pgbackrest)";
        before = [ "panoramax.service" ];
        requiredBy = [ "panoramax.service" ];
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        path = [ pkgs.docker ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "/etc/panoramax";
        };
        script = ''
          tmp=$(mktemp -d)
          cp -L /etc/panoramax/Dockerfile.db "$tmp/Dockerfile.db"
          docker build --network host -t panoramax-osmbe/db:local -f "$tmp/Dockerfile.db" "$tmp"
          rm -rf "$tmp"
        '';
      };

      # 3. The compose stack itself.
      systemd.services.panoramax = {
        description = "Panoramax docker-compose stack";
        wantedBy = lib.mkIf cfg.composeAutoStart [ "multi-user.target" ];
        after = [
          "docker.service"
          "panoramax-env-merge.service"
          "panoramax-build-db.service"
          "wait-for-wt0.service"
          "srv-panoramax-pictures.mount"
        ];
        requires = [
          "docker.service"
          "panoramax-env-merge.service"
          "panoramax-build-db.service"
        ];
        # Refuse to start the stack until both NFS child-dataset mounts are
        # actually up (avoids an empty bind mount that Docker would gladly use).
        unitConfig.RequiresMountsFor =
          "/srv/panoramax/pictures/permanent /srv/panoramax/pictures/derivates";

        # Editing any compose-related file in /etc/panoramax/ triggers a reload
        # on `nixos-rebuild switch`.
        reloadTriggers =
          builtins.attrValues (lib.mapAttrs (_: v: v.source) composeFiles);

        path = [ pkgs.docker pkgs.docker-compose ];
        # Type=oneshot + RemainAfterExit=true with `up -d` is the right shape
        # for a compose stack under systemd. The previous Type=simple + `up`
        # (foreground) combined with an ExecReload that called `up -d`
        # (detached) would have had the foreground PID and the detached
        # containers fighting over signals + log streaming.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "/etc/panoramax";
          EnvironmentFile = "/run/panoramax.env";
          ExecReload =
            if cfg.composeAutoStart
            then "${pkgs.docker}/bin/docker compose --env-file /run/panoramax.env up -d --build --remove-orphans"
            else "${pkgs.coreutils}/bin/true";
          ExecStop =
            if cfg.composeAutoStart
            then "${pkgs.docker}/bin/docker compose --env-file /run/panoramax.env down"
            else "${pkgs.coreutils}/bin/true";
          TimeoutStartSec = "10min";
        };
        script =
          if cfg.composeAutoStart then ''
            ${pkgs.docker}/bin/docker compose --env-file /run/panoramax.env up -d --remove-orphans
            # Poll and record status for up to 60s as containers settle
            tmpf=$(mktemp)
            for i in $(seq 1 30); do
              ${pkgs.docker}/bin/docker compose ps > "$tmpf"
              if ! grep -qE 'Exited|unhealthy|Restarting|Dead' "$tmpf"; then
                break
              fi
              sleep 2
            done
            cp "$tmpf" /srv/panoramax/.last-compose-status
            rm -f "$tmpf"
            echo "" >> /srv/panoramax/.last-compose-status
            echo "Status captured at $(date -Iseconds) after $((i * 2))s" >> /srv/panoramax/.last-compose-status
            if [ "$i" -eq 30 ]; then
              echo "WARNING: Some containers may still be settling after 60s" >> /srv/panoramax/.last-compose-status
            fi
          '' else ''
            echo "⚠️  DIDN'T AUTO START PANORAMAX — composeAutoStart is set to false" >&2
            echo "   Run manually: sudo docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env up --remove-orphans" >&2
            touch /srv/panoramax/MANUAL_START_REQUIRED
          '';
      };

      # Convenience wrapper: quick container status without typing the full
      # docker compose path every time.
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "panoramax-status" ''
          if [ -f /srv/panoramax/MANUAL_START_REQUIRED ]; then
            echo "⚠️  composeAutoStart is false — stack is NOT managed by systemd" >&2
            echo "   Start manually: sudo docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env up --remove-orphans" >&2
            echo "" >&2
          fi
          exec sudo ${pkgs.docker}/bin/docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env ps "$@"
        '')
      ];

      # Local-disk directories the compose volumes bind to.
      systemd.tmpfiles.rules = [
        "d /srv/panoramax            0755 root     root     -"
        # uid 1000 = geovisio in the panoramax/api image. The upload pipeline
        # writes to tmp before moving to permanent; opendal mis-reports the
        # resulting EACCES as a `permanent` write failure.
        "d /srv/panoramax/tmp        0755 1000     1000     -"
        # uid 999 = postgres in the postgis image.
        "d /srv/panoramax/pgbackrest 0750 999      999      -"
        "d /srv/panoramax/logs       0755 1320     1320     -"
      ];
    }

    (lib.mkIf (!cfg.composeAutoStart) {
      system.activationScripts.panoramax-manual-start-warning = ''
        echo "⚠️  DIDN'T AUTO START PANORAMAX — composeAutoStart is set to false" >&2
        echo "   Run manually: sudo docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env up --remove-orphans" >&2
      '';
    })
    ]))
  ];
}
