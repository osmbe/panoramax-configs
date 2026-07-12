# =============================================================================
# THE FORKABLE FILE.
# =============================================================================
# Every non-secret instance-specific value lives here. To stand up your own
# Panoramax instance, edit this file and the secrets file
# (secrets/panoramax-osmbe.yaml). Nothing else should need to change for a
# normal fork.
#
# Anything that's a credential (OAuth secret, DB password, BorgBase repo URL,
# health-check URLs) lives in sops, NOT here.
# =============================================================================
{
  hostName = "panoramax-osmbe";

  # Public domains. DNS A + AAAA records for both must point to the VPS.
  # `imageDomain` is intentionally distinct from `domain` so that image
  # serving can be moved to a separate host later without changing
  # API-generated URLs. (Not redundancy — futureproofing.)
  domain = "panoramax.osm.be";
  imageDomain = "images.panoramax.osm.be";

  # Human-readable instance name shown by the website.
  instanceName = "Panoramax Belgium";

  # Contact email for ACME (Let's Encrypt). Not the public-facing API contact
  # address — that's the `email` field of API_SUMMARY in env.public.
  acmeContactEmail = "letsencrypt@thibaultmol.link";

  # SSH — moved off port 22 for cheap bot-noise reduction.
  # Random pick in the ephemeral range; document in DEPLOY.md.
  sshPort = 58422;

  # Admin user (single Linux user, multiple SSH keys).
  adminUser = "panoramax";
  admins = [{
    name = "thibault";
    sshKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPEZBh4+gIEjj/oTSqXqVt/4NDBiIX8kHsv+k3Q+yuVj thibaultmol@Framework-THIB";
  }
  # Add more admins by appending entries here. Each gets the same shell access;
  # multi-recipient sops handles secret access (see secrets/.sops.yaml).
    ];

  # NetBird mesh.
  # truenasIp is the only peer IP this flake actively uses (NFS source). The
  # VPS NetBird IP is auto-assigned and the flake never references it — the
  # mesh exists for VPS↔TrueNAS NFS and for the Prometheus scraper that feeds
  # Grafana Cloud, not for admin access. Admin machines reach Postgres via SSH
  # local port forward (see OPERATIONS.md) and don't need to be NetBird peers at all.
  netbird = {
    truenasIp = "100.98.205.52";
    interface = "wt0";
  };

  # NFS shares that the VPS mounts at /srv/panoramax/pictures/permanent
  # and /srv/panoramax/pictures/derivates. The parent directory is a local
  # path; the two child datasets are exported separately so each can have
  # independent ZFS properties (quota, snapshots, replication).
  # Hosted on TrueNAS; reached over NetBird.
  nfs = {
    permanentSharePath = "/mnt/rowan-zpool1/Panoramax-OSMBE/permanent";
    derivatesSharePath = "/mnt/rowan-zpool1/Panoramax-OSMBE/derivates";
  };

  # Backups
  s3.bucket = "panoramax-osmbe-backups";

  # Disk device for disko — the OS volume, i.e. the disk the BIOS boots. NixOS
  # is installed here; the separate 250 GB data volume is mounted by label in
  # modules/data-disk.nix. Infomaniak's disk enumeration order is not stable,
  # so confirm which device the BIOS boots with `lsblk` before running
  # nixos-anywhere (see DEPLOY.md § 2.1).
  diskDevice = "/dev/sda";

  # Where the public repo is checked out on the VPS. Used by the auto-upgrade
  # service to know what working tree to pull/rebuild.
  repoPath = "/srv/panoramax-configs";
}
