{ instance, ... }: {
  # NFS mounts of the TrueNAS picture shares, reached over NetBird.
  # The two child datasets (permanent, derivates) are exported and mounted
  # separately so each can have independent ZFS properties (quota,
  # snapshots, replication). The parent /srv/panoramax/pictures is a local
  # directory created by tmpfiles.
  #
  # IMPORTANT: do NOT use x-systemd.automount. Automount creates an empty
  # mount point immediately, and Docker's bind mount may attach to that empty
  # path before NFS actually mounts. Hard mount with `nofail` is the right
  # tradeoff: boot continues if the NAS is unreachable; the panoramax service
  # has `RequiresMountsFor=` to refuse to start without the real mounts.
  systemd.tmpfiles.rules = [ "d /srv/panoramax/pictures 0755 root root -" ];

  # NetBird wt0 isn't part of `network-online.target`, so `_netdev` alone
  # isn't enough to keep the mount units from firing before the mesh is up.
  # `wait-for-wt0.service` (in modules/netbird.nix) polls until wt0 has an
  # IPv4; we explicitly require + order against it so the mounts only attempt
  # once NetBird has joined. Combined with `nofail` and `soft`, a genuinely
  # broken mesh still doesn't block boot - the mount fails cleanly and
  # `panoramax.service` correctly refuses to start.
  fileSystems."/srv/panoramax/pictures/permanent" = {
    device = "${instance.netbird.truenasIp}:${instance.nfs.permanentSharePath}";
    fsType = "nfs";
    options = [
      "soft" # error rather than hang on NFS timeouts
      "timeo=50" # 5-second I/O timeout
      "retrans=3"
      "_netdev"
      "nofail"
      "x-systemd.requires=wait-for-wt0.service"
      "x-systemd.after=wait-for-wt0.service"
    ];
  };

  fileSystems."/srv/panoramax/pictures/derivates" = {
    device = "${instance.netbird.truenasIp}:${instance.nfs.derivatesSharePath}";
    fsType = "nfs";
    options = [
      "soft" "timeo=50" "retrans=3" "_netdev" "nofail"
      "x-systemd.requires=wait-for-wt0.service"
      "x-systemd.after=wait-for-wt0.service"
    ];
  };
}
