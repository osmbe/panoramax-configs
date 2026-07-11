{ instance, ... }:
{
  # GPT layout for legacy-BIOS boot via GRUB.
  #
  # Infomaniak VPS disk topology:
  #   sda — 250 GB data disk. The BIOS boots sda first. NixOS lives here.
  #   sdb — 20 GB OS disk. Debian ships here; left untouched by NixOS install.
  #
  # This naming is stable on fresh Infomaniak Debian images and matches the
  # kexec installer environment. If lsblk shows sda = 20 GB instead, re-
  # provision a fresh Debian image from the Infomaniak control panel before
  # continuing — see DEPLOY.md § 2.1.
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
