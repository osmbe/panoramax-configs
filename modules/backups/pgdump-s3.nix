{ config, lib, pkgs, ... }:
{
  # Gated on panoramax.enable AND a per-job toggle. The stack-level gate is
  # because timer-driven `docker compose ... exec` would /fail-ping every 24h
  # while the stack is intentionally off. The per-job toggle is so a fresh
  # fork can defer external-system backups until the stack is verified
  # working (see DEPLOY.md § 1.12 / § 3.2).
  config = lib.mkIf (config.panoramax.enable
                  && config.panoramax.backups.pgdumpS3.enable) {
  sops.secrets = {
    "s3/env".mode = "0400";
    "healthchecks/pgdump-s3-ping-url".mode = "0400";
  };

  # Daily logical pg_dump uploaded to S3-compatible storage (Hetzner Object
  # Storage). Existence reasoning: pgBackRest + Borg are physical backups
  # that replicate any on-disk corruption byte-for-byte. pg_dump reads
  # through the query engine and so fails loudly on corruption — and is
  # portable across major versions.
  systemd.services.pgdump-s3 = {
    description = "Logical pg_dump → S3 (with weekly/monthly server-side copies)";
    # Only `after`, not `requires`: stop-propagation from panoramax.service
    # would interrupt an in-flight dump.
    after = [ "panoramax.service" ];
    path = [ pkgs.docker pkgs.s3cmd pkgs.curl pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      ping_url=$(cat /run/secrets/healthchecks/pgdump-s3-ping-url)
      curl -fsS -m 10 --retry 3 "$ping_url/start" || true

      # Build s3cmd config from sops.
      cfg=$(mktemp)
      trap 'rm -f "$cfg" "$dump"' EXIT

      # shellcheck disable=SC1091
      set -a; . /run/secrets/s3/env; set +a

      cat > "$cfg" <<EOF
[default]
access_key = $AWS_ACCESS_KEY_ID
secret_key = $AWS_SECRET_ACCESS_KEY
host_base = ''${AWS_ENDPOINT_URL#https://}
host_bucket = %(bucket)s.''${AWS_ENDPOINT_URL#https://}
use_https = True
EOF

      ts=$(date -u +%Y%m%d-%H%M%S)
      dump=$(mktemp -t geovisio-pgdump.XXXXXX.dump)

      # `compose exec` (not `docker exec <hardcoded-name>`) so we don't
      # depend on the compose-project-derived container name.
      docker compose -f /etc/panoramax/docker-compose.yml --env-file /run/panoramax.env \
        exec -T -u postgres db pg_dump -Fc -U gvs -d geovisio > "$dump"

      # Sanity check: a valid pg_dump for an empty schema is still > 1 KB;
      # anything smaller is a silent failure.
      sz=$(stat -c%s "$dump")
      if [ "$sz" -lt 1000 ]; then
        echo "pg_dump output suspiciously small ($sz bytes)" >&2
        curl -fsS -m 10 --retry 3 "$ping_url/fail" -d "dump size $sz B" || true
        exit 1
      fi

      key="pgdump/daily/geovisio-$ts.dump"
      s3cmd -c "$cfg" put "$dump" "s3://$S3_BUCKET/$key"

      # Server-side copy on Sunday → weekly/, on the 1st → monthly/.
      # Capture exit codes — silent failure here would leave a daily-only
      # backup with no weekly/monthly retention copy and we'd never know.
      warnings=""
      dow=$(date -u +%u)
      dom=$(date -u +%d)
      if [ "$dow" = "7" ]; then
        if ! s3cmd -c "$cfg" cp "s3://$S3_BUCKET/$key" \
            "s3://$S3_BUCKET/pgdump/weekly/geovisio-$ts.dump" 2>&1; then
          warnings="$warnings; weekly copy failed"
        fi
      fi
      if [ "$dom" = "01" ]; then
        if ! s3cmd -c "$cfg" cp "s3://$S3_BUCKET/$key" \
            "s3://$S3_BUCKET/pgdump/monthly/geovisio-$ts.dump" 2>&1; then
          warnings="$warnings; monthly copy failed"
        fi
      fi

      msg="pgdump $sz B uploaded $key"
      if [ -n "$warnings" ]; then
        # Successful daily upload but with warnings: ping the success endpoint
        # so we don't false-alarm, but include the warnings in the payload so
        # they surface in the Healthchecks history.
        msg="$msg | warnings:$warnings"
      fi
      curl -fsS -m 10 --retry 3 "$ping_url" -d "$msg" || true
    '';
  };

  # Daily at 00:30 UTC.
  systemd.timers.pgdump-s3 = {
    description = "Daily pg_dump → S3 (00:30 UTC)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:30:00 UTC";
      Persistent = true;
    };
  };
  };
}
