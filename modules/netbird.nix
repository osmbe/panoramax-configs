{ pkgs, instance, ... }:
{
  # NetBird agent. Joins the mesh on first boot using a setup key from sops.
  # Hosted free tier; auto NAT traversal + identity-based peers + ACLs in the
  # NetBird dashboard.
  services.netbird.enable = true;

  sops.secrets."netbird/setup-key" = {
    mode = "0400";
    owner = "root";
  };

  # On first boot, run `netbird up` with the setup key. Idempotent: subsequent
  # boots see the agent already configured and the command is a no-op.
  #
  # We use a custom oneshot rather than relying on a NixOS-module enrollment
  # option because, as of nixpkgs-25.11, services.netbird.clients.<name> does
  # not expose a built-in setup-key/file mechanism — the daemon's job is just
  # to be running, and `netbird up` is the CLI surface that performs
  # enrollment. Pass the key by file path (NB_SETUP_KEY_FILE) instead of
  # interpolating it with $(cat …): no shell expansion brittleness, and the
  # secret never appears on the daemon's argv (visible to ps).
  systemd.services.netbird-enroll = {
    description = "NetBird first-boot enrollment";
    after = [ "netbird.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "netbird-enroll" ''
        set -e
        # If wt0 already has an IP, we're already enrolled.
        if ${pkgs.iproute2}/bin/ip -4 addr show ${instance.netbird.interface} 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -q 'inet '; then
          exit 0
        fi
        ${pkgs.netbird}/bin/netbird up --setup-key-file /run/secrets/netbird/setup-key
      '';
    };
  };

  # Helper used by other units that need the wt0 interface up before they can
  # bind / connect. Polls every second up to a minute.
  systemd.services.wait-for-wt0 = {
    description = "Wait for NetBird interface ${instance.netbird.interface} to have an IPv4";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "wait-for-wt0" ''
        for i in $(seq 1 60); do
          if ${pkgs.iproute2}/bin/ip -4 addr show ${instance.netbird.interface} 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -q 'inet '; then
            exit 0
          fi
          sleep 1
        done
        echo "wt0 never came up" >&2
        exit 1
      '';
    };
  };
}
