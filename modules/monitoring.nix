{ config, lib, pkgs, instance, ... }:
let
  alloyConfig = ''
    loki.relabel "journal" {
      // This component is only used as a container for relabel rules that are
      // applied inside loki.source.journal via relabel_rules. Alloy drops
      // __journal_* internal labels before forwarding, so the relabeling must
      // happen at the journal source, not in a separate component.
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      rule {
        source_labels = ["__journal__hostname"]
        target_label  = "nodename"
      }

      // Surface Docker container names as a Loki label. Docker with
      // log-driver=journald (see modules/common.nix) tags each journal entry
      // with CONTAINER_NAME; Alloy exposes journald fields as __journal_<lowercase>.
      rule {
        source_labels = ["__journal_container_name"]
        target_label  = "container"
      }
    }

    loki.source.journal "default" {
      forward_to    = [loki.write.grafanacloud.receiver]
      relabel_rules = loki.relabel.journal.rules
      max_age       = "12h"
      labels = {
        job  = "systemd-journal",
        host = "${instance.hostName}",
      }
    }

    loki.write "grafanacloud" {
      endpoint {
        // URL + basic-auth credentials are env-expanded at Alloy startup so
        // secrets never enter the Nix store. Grafana Cloud Loki requires basic
        // auth (User ID + glc_... token), not bearer. URL must include the
        // /loki/api/v1/push path.
        url = sys.env("LOKI_URL")
        basic_auth {
          username = sys.env("LOKI_USER")
          password = sys.env("LOKI_TOKEN")
        }
      }
    }

    // ---- Metrics scraping and remote-write to Grafana Cloud Prometheus ----
    prometheus.scrape "node" {
      targets = [{
        __address__ = "127.0.0.1:9100",
      }]
      forward_to = [prometheus.remote_write.grafanacloud.receiver]
      job_name   = "node"
    }

    prometheus.scrape "cadvisor" {
      targets = [{
        __address__ = "127.0.0.1:9102",
      }]
      forward_to = [prometheus.remote_write.grafanacloud.receiver]
      job_name   = "cadvisor"
    }

    prometheus.remote_write "grafanacloud" {
      endpoint {
        // URL + credentials from the Grafana Cloud Prometheus "Remote Write"
        // integration. The token is prefixed glc_... and is separate from the
        // Loki token. Env-expanded so secrets never enter the Nix store.
        url = sys.env("PROMETHEUS_REMOTE_WRITE_URL")
        basic_auth {
          username = sys.env("PROMETHEUS_REMOTE_WRITE_USER")
          password = sys.env("PROMETHEUS_REMOTE_WRITE_TOKEN")
        }
      }
    }
  '';
in
{
  sops = {
    secrets = {
      "loki/push-url".mode = "0400";
      "loki/push-user".mode = "0400";
      "loki/push-token".mode = "0400";
      "prometheus/remote-write-url".mode = "0400";
      "prometheus/remote-write-user".mode = "0400";
      "prometheus/remote-write-token".mode = "0400";
      "healthchecks/heartbeat-url".mode = "0400";
      "healthchecks/nfs-health-url".mode = "0400";
    };

    # Render an env file Alloy can source. Using sops templates means the
    # secret values never appear in the Nix store.
    templates."alloy.env" = {
      content = ''
        LOKI_URL=${config.sops.placeholder."loki/push-url"}
        LOKI_USER=${config.sops.placeholder."loki/push-user"}
        LOKI_TOKEN=${config.sops.placeholder."loki/push-token"}
        PROMETHEUS_REMOTE_WRITE_URL=${config.sops.placeholder."prometheus/remote-write-url"}
        PROMETHEUS_REMOTE_WRITE_USER=${config.sops.placeholder."prometheus/remote-write-user"}
        PROMETHEUS_REMOTE_WRITE_TOKEN=${config.sops.placeholder."prometheus/remote-write-token"}
      '';
      mode = "0400";
    };
  };

  # ---- Alloy (log + metric shipping to Grafana Cloud) --------------------
  environment.etc."alloy/config.alloy".text = alloyConfig;

  services.alloy = {
    enable = true;
    configPath = "/etc/alloy";
    environmentFile = config.sops.templates."alloy.env".path;
  };

  # The NixOS module adds systemd-journal; adm is also recommended by upstream
  # for reading the systemd journal.
  systemd.services.alloy.serviceConfig.SupplementaryGroups = [ "systemd-journal" "adm" ];

  # ---- node_exporter -----------------------------------------------------
  # Listens on all interfaces; the firewall (modules/firewall.nix) only opens
  # 9100 on wt0, so only NetBird peers can scrape.
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "0.0.0.0";
    enabledCollectors = [ "systemd" "textfile" ];
    extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/node_exporter/textfile 0755 nobody nobody -"
  ];

  # ---- cAdvisor (container metrics) --------------------------------------
  # Per-container CPU, memory, network, disk, and restart metrics for the
  # Docker Compose stack. Listens on all interfaces; the firewall scopes 9102
  # to wt0 so only NetBird peers can scrape it. cAdvisor needs access to the
  # Docker socket and cgroups, which is why it runs as root.
  services.cadvisor = {
    enable = true;
    port = 9102;
    listenAddress = "0.0.0.0";
  };

  # ---- NetBird P2P-direct metric (custom textfile collector) -------------
  # Exposes `netbird_peer_direct{peer="..."}` so Prometheus on Grafana Cloud
  # can alert on relayed connections (relay = NFS bottleneck).
  systemd.services.netbird-peer-direct-metric = {
    description = "Write netbird_peer_direct metric to node_exporter textfile collector";
    path = [ pkgs.netbird pkgs.jq ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -e
      out=/var/lib/node_exporter/textfile/netbird_peer_direct.prom
      tmp=$(mktemp)
      # mktemp creates 0600 root:root by default, and `mv` preserves perms.
      # node_exporter runs as `nobody`, so the file needs to be world-readable
      # or it logs ERROR + skips collection on every scrape.
      chmod 0644 "$tmp"
      echo '# HELP netbird_peer_direct 1 if NetBird peer is connected directly (P2P), 0 if relayed.' > "$tmp"
      echo '# TYPE netbird_peer_direct gauge' >> "$tmp"
      netbird status -j 2>/dev/null \
        | jq -r '.peers.details[] | "netbird_peer_direct{peer=\"\(.fqdn)\"} \(if .relayed then 0 else 1 end)"' \
        >> "$tmp" || true
      mv "$tmp" "$out"
    '';
  };

  systemd.timers.netbird-peer-direct-metric = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      # Direct/relayed status changes rarely; 1-minute polling was high-
      # cardinality without payoff. 5 min is plenty for an alert.
      OnUnitActiveSec = "5min";
    };
  };

  # ---- Server-alive heartbeat (5 min) ------------------------------------
  # Pings Healthchecks.io. The check is configured as Simple mode (Period
  # 5 min, Grace 10 min) because the systemd timer fires every 5 minutes from
  # boot, not aligned to wall-clock minutes. The 10-minute grace absorbs the
  # auto-upgrade reboot window so it doesn't false-alarm.
  systemd.services.heartbeat = {
    description = "5-minute heartbeat ping to Healthchecks.io";
    path = [ pkgs.curl ];
    serviceConfig.Type = "oneshot";
    script = ''
      url=$(cat /run/secrets/healthchecks/heartbeat-url)
      curl -fsS -m 10 --retry 3 "$url" || true
    '';
  };
  systemd.timers.heartbeat = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  # ---- NFS health (5 min) ------------------------------------------------
  # `stat` will hang if NFS is wedged, so we time-box it. The missed ping is
  # what fires the alert when the mount is unhealthy.
  systemd.services.nfs-health = {
    description = "5-minute NFS health probe via timeout-stat";
    path = [ pkgs.curl pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      url=$(cat /run/secrets/healthchecks/nfs-health-url)
      if timeout 20 stat /srv/panoramax/pictures/permanent >/dev/null 2>&1 && \
         timeout 20 stat /srv/panoramax/pictures/derivates >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 3 "$url" || true
      else
        curl -fsS -m 10 --retry 3 "$url/fail" -d "stat /srv/panoramax/pictures/{permanent,derivates} timed out" || true
      fi
    '';
  };
  systemd.timers.nfs-health = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };
}
