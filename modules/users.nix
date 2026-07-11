{ instance, lib, ... }: {
  users.mutableUsers = false;

  users.users.${instance.adminUser} = {
    isNormalUser = true;
    # Pinned to a non-default UID so the same identity can be created on
    # TrueNAS and matched in ZFS ACLs (NFS identity is numeric UID, not
    # username). Survives VPS rebuilds without reconfiguring the NAS.
    uid = 1320;
    extraGroups = [ "wheel" "docker" "systemd-journal" ];
    openssh.authorizedKeys.keys = map (a: a.sshKey) instance.admins;
  };

  security.sudo.wheelNeedsPassword = false;
}
