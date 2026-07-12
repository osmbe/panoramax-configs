{ lib, ... }:
{
  # The Infomaniak 250 GB data volume, mounted at /srv/panoramax. Holds
  # everything that grows: the Docker data-root (images + the postgres_data
  # volume, i.e. the database), the upload tmp scratch, the local pgBackRest
  # repo, and logs. NixOS itself lives on the separate ~20 GB OS volume.
  #
  # Mounted BY LABEL, not /dev/sdX: Infomaniak's disk enumeration order is not
  # stable, so a device letter can point at the wrong disk. Deliberately not
  # managed by disko either, so an OS reinstall leaves this volume untouched.
  # See SPEC.md § Local disk layout for the full rationale.
  #
  # One-time format before the first rebuild that includes this module (the
  # label is capped at 12 chars by xfs, hence `pano-data`, not `panoramax-data`):
  #   mkfs.xfs -L pano-data /dev/<the 250 GB partition>
  #
  # `nofail` so a missing data disk never hangs boot (as with the NFS mounts);
  # docker and panoramax.service both RequireMountsFor /srv/panoramax, so the
  # stack still refuses to start without it.
  fileSystems."/srv/panoramax" = {
    device = "/dev/disk/by-label/pano-data";
    fsType = "xfs";
    options = [ "defaults" "nofail" "x-systemd.device-timeout=15s" ];
  };

  # Container images and the plain `postgres_data` named volume (the database)
  # are the largest local consumers, so the Docker data-root goes on the data
  # disk. Merges with the log-driver/autoPrune settings in common.nix.
  virtualisation.docker.daemon.settings.data-root = "/srv/panoramax/docker";

  # Docker must not start against an unmounted data-root — it would recreate an
  # empty tree on the OS disk. RequiresMountsFor makes docker wait for the mount.
  systemd.services.docker.unitConfig.RequiresMountsFor = "/srv/panoramax";
}
