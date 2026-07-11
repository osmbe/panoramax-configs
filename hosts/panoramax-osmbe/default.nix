{
  lib,
  sopsFile,
  hasRealSecrets,
  ...
}: let
  instance = import ./instance.nix;
in {
  imports = [
    ./hardware-configuration.nix
    ./disko.nix

    ../../modules/common.nix
    ../../modules/users.nix
    ../../modules/ssh.nix
    ../../modules/firewall.nix
    ../../modules/netbird.nix
    ../../modules/nfs.nix
    ../../modules/caddy.nix
    ../../modules/panoramax-stack.nix
    ../../modules/backups/pgbackrest.nix
    ../../modules/backups/borgbackup.nix
    ../../modules/backups/pgdump-s3.nix
    ../../modules/monitoring.nix
    ../../modules/autoupgrade.nix
  ];

  # Make `instance` available as a parameter to every module.
  _module.args = {inherit instance;};

  networking.hostName = instance.hostName;

  # Sops setup. defaultSopsFile points at either the real (encrypted) file or
  # the dummy fallback (see flake.nix). validateSopsFiles is skipped on the
  # fallback path so `nix flake check` doesn't complain about the plaintext
  # placeholder.
  sops = {
    defaultSopsFile = sopsFile;
    validateSopsFiles = hasRealSecrets;
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };

  # Master switch for the Panoramax docker-compose stack. Left on in the
  # committed repo because the live instance runs from this branch; fresh
  # installs set this to `false` temporarily (see DEPLOY.md § 1.12) so
  # nixos-anywhere can install the base system before NetBird and NFS are
  # ready. The flake falls back to secrets-dummy.yaml when the submodule is
  # not present; real deploys must use `?submodules=1`.
  panoramax.enable = true;

  # External-system backup toggles. Set both to `false` on a fresh fork
  # (DEPLOY.md § 1.12) and flip to `true` once you've verified the stack and
  # done a manual test of each job (§ 3.2). pgBackRest doesn't have a toggle
  # here on purpose — it's the local hot backup tied to panoramax.enable.
  panoramax.backups.borgbackup.enable = true;
  panoramax.backups.pgdumpS3.enable = true;

  panoramax.autoUpgrade.enable = true;
}
