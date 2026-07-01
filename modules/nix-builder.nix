# Fleet remote-builder role: an SSH build user the nix daemon trusts, a
# harmonia binary cache serving this host's /nix/store, a dedicated /nix
# data disk, and GC watermarks for a store that doubles as the fleet
# cache.
#
# Site-local values — authorized build keys, the cache key name, GC
# watermarks — come from the consuming private repo via local.nixBuilder.*.
{ config, pkgs, lib, ... }:

let
  cfg = config.local.nixBuilder;
  keyDir = "/var/lib/harmonia";
  keyFile = "${keyDir}/cache-key.sec";
in
{
  options.local.nixBuilder = {
    enable = lib.mkEnableOption "the fleet nix remote-builder role";

    buildUserKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys allowed to run remote builds as the nix-remote
        user (ssh-ng:// clients: operator workstations, CI runners).
      '';
    };

    nixDisk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Format and mount the VM's second SCSI disk (drive-scsi1) at
        /nix. The store doubles as the binary cache, so it gets its own
        disk; the size lives in the VM env file, not here.
      '';
    };

    cache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Serve this host's /nix/store as a binary cache via harmonia.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "TCP port harmonia binds; opened in the firewall.";
      };
      keyName = lib.mkOption {
        type = lib.types.str;
        example = "builder.example.com-1";
        description = ''
          Name embedded in the cache signing key. The keypair is
          generated on first boot and the private half never leaves the
          host; read /var/lib/harmonia/cache-key.pub for the value
          clients put in trusted-public-keys.
        '';
      };
    };

    gc = {
      minFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = "Free-space floor that triggers automatic store GC.";
      };
      maxFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 150;
        description = "Automatic GC stops once this much space is free.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.nix-remote = {
      isNormalUser = true;
      group = "nix-remote";
      openssh.authorizedKeys.keys = cfg.buildUserKeys;
    };
    users.groups.nix-remote = { };

    nix.settings = {
      trusted-users = [ "nix-remote" ];
      # No "kvm": the hypervisor does not enable nested virtualization,
      # so vmTest-class builds must run elsewhere.
      system-features = [ "big-parallel" "benchmark" ];
      min-free = cfg.gc.minFreeGiB * 1024 * 1024 * 1024;
      max-free = cfg.gc.maxFreeGiB * 1024 * 1024 * 1024;
    };

    # Same by-id convention as the system disk in nixos-builder.nix:
    # udev surfaces the QEMU drive name, not the serial= field.
    disko.devices.disk.nix = lib.mkIf cfg.nixDisk {
      type = "disk";
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      content = {
        type = "gpt";
        partitions.store = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
          };
        };
      };
    };

    # Self-bootstrapping signing key: generated once, root-owned 0400;
    # harmonia only ever reads it, so no service-user access is needed.
    systemd.services.harmonia-keygen = lib.mkIf cfg.cache.enable {
      description = "Generate the harmonia cache signing key if absent";
      wantedBy = [ "multi-user.target" ];
      before = [ "harmonia.service" ];
      requiredBy = [ "harmonia.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        if [ ! -s ${keyFile} ]; then
          mkdir -p ${keyDir}
          ${pkgs.nix}/bin/nix key generate-secret --key-name ${cfg.cache.keyName} > ${keyFile}
          chmod 0400 ${keyFile}
        fi
        ${pkgs.nix}/bin/nix key convert-secret-to-public < ${keyFile} > ${keyDir}/cache-key.pub
      '';
    };

    services.harmonia.cache = lib.mkIf cfg.cache.enable {
      enable = true;
      signKeyPaths = [ keyFile ];
      settings.bind = "[::]:${toString cfg.cache.port}";
    };

    # Restating 22 is deliberate: this normal-priority definition
    # displaces the mkDefault [ 22 ] in nixos-builder.nix, and ssh must
    # stay open regardless of the openssh module's openFirewall default.
    networking.firewall.allowedTCPPorts =
      [ 22 ] ++ lib.optional cfg.cache.enable cfg.cache.port;
  };
}
