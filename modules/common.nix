{ pkgs, lib, ... }:
{
  system.stateVersion = "25.11";

  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "be-latin1";

  networking = {
    useDHCP = lib.mkDefault true;
    firewall.enable = true;
  };

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];
      max-jobs = lib.mkDefault 1;  # small VPS, prefer binary cache
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 21d";
    };
  };

  services.fstrim.enable = true;

  # NixOS's logrotate config references container log paths that don't exist at
  # build time. Disable check so nixos-rebuild doesn't refuse to switch.
  services.logrotate.checkConfig = false;

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=2G
    SystemMaxFileSize=200M
  '';

  # fail2ban with a moderate ramp-up. Public-facing ssh + 80/443 only; bans
  # don't apply to NetBird-scoped traffic.
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h";
    };
  };

  # Admin tools every operator expects to find on the box.
  environment.systemPackages = with pkgs; [
    vim git htop btop tmux curl wget jq dig nano rsync tree file
    lsof ncdu sops age ssh-to-age borgbackup s3cmd
  ];

  virtualisation.docker = {
    enable = true;
    # Route container stdout/stderr to systemd-journald so Alloy's journal
    # scrape picks them up (each entry tagged with CONTAINER_NAME).
    # Switching the driver restarts every container on `nixos-rebuild switch`.
    daemon.settings.log-driver = "journald";
    autoPrune = {
      enable = true;
      dates = "weekly";
      # `--all` would delete the locally-built `db` image during the brief
      # window when the stack is stopped, forcing a costly rebuild on the
      # next start. `--force` only.
      flags = [ "--force" ];
    };
  };
}
