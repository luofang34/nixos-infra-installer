# Builder-VM-specific defaults: single-disk disko layout matching the
# Proxmox VM that infra-proxmox/lib/create-qemu-vm.sh produces, the
# iso-builder service + timer, and the trust grant the iso-builder
# user needs to write to /nix/store as non-root.
#
# Site-local values — operator SSH keys, the static IP / gateway, the
# iso-builder option set (proxmoxHost, flakeRepo, scheduling cadence) —
# are NOT in this module. The consuming private deployment repo
# declares them at the host level.
{ lib, ... }: {
  imports = [
    ./iso-builder.nix
  ];

  # The by-id path is keyed on the QEMU drive name (`drive-scsi0`),
  # NOT on the `serial=` field set in the VM config — udev surfaces
  # the drive name, not the serial.
  disko.devices.disk.system = {
    type = "disk";
    device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = lib.mkDefault [ 22 ];

  # iso-builder service runs as a non-root system user; without
  # trusted-users it would have to round-trip through sudo every time
  # it touches /nix/store.
  nix.settings.trusted-users = [ "root" "iso-builder" ];

  system.stateVersion = "25.11";
}
