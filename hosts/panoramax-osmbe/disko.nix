{ instance, ... }:
{
  # GPT layout for legacy-BIOS boot via GRUB.
  #
  # This partitions ONLY the OS volume — whatever disk `instance.diskDevice`
  # points at, which must be the disk the BIOS boots. Infomaniak VPS Cloud
  # ships two disks (a ~20 GB OS volume and a ~250 GB data volume) and their
  # enumeration order is not guaranteed, so confirm with `lsblk` which device
  # the BIOS boots before setting `diskDevice` — see DEPLOY.md § 2.1.
  #
  # The 250 GB data volume is NOT touched here: it is mounted by label in
  # modules/data-disk.nix so an OS reinstall leaves it intact. See
  # SPEC.md § Local disk layout.
  disko.devices.disk.main = {
    type = "disk";
    device = instance.diskDevice;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "4M";
          type = "EF02";  # BIOS boot partition for GRUB on GPT
        };
        swap = {
          size = "4G";
          content = {
            type = "swap";
            randomEncryption = true;
            # We don't hibernate on a VPS, so suppress the auto-generated
            # boot.resumeDevice. Without this, the kernel would try to
            # resume from a swap partition that gets a fresh random key on
            # every boot — slowing boot for nothing.
            resumeDevice = false;
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/";
            mountOptions = [ "defaults" ];
          };
        };
      };
    };
  };

  # GRUB on legacy BIOS. disko (on nixpkgs-25.11) auto-populates
  # `boot.loader.grub.devices` from the disk that owns the EF02 partition,
  # so we MUST NOT set `devices` here too — that triggers a "duplicated
  # devices in mirroredBoots" assertion.
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };
}
