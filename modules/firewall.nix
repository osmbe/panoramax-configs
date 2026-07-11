{ instance, ... }:
{
  # Default-closed firewall. SSH (chosen non-22 port) + HTTP + HTTPS public.
  # Postgres (5432) is NEVER opened in the host firewall — Docker binds it to
  # 127.0.0.1 only; admins reach it via SSH local port forward (see
  # OPERATIONS.md § Connecting to Postgres).
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      80
      443
      instance.sshPort
    ];

    # Monitoring exporters listen on all interfaces but are scoped to the
    # NetBird interface only via per-interface rules.
    interfaces.${instance.netbird.interface} = {
      allowedTCPPorts = [
        9100  # node_exporter
        9102  # cAdvisor
      ];
    };
  };
}
