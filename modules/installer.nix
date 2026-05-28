# Live NixOS minimal ISO with:
#   * QEMU guest agent enabled (so `qm agent ping` succeeds within ~30s
#     of boot and a hypervisor-side orchestrator can read the lease
#     without scraping ARP),
#   * sshd accepting root SSH key-only (so `nixos-anywhere root@<ip>`
#     works with zero prep — no console-side password set, no key push),
#   * `pkgs.linuxPackages_latest` so recent NIC / NVMe / virtio quirks
#     are supported on whatever the hypervisor throws at this ISO,
#   * `users.users.root.openssh.authorizedKeys.keys` populated from the
#     `local.installer.sshKeys` option below — the operator's deployment
#     repo declares the actual key list; this module only declares the
#     contract.

{ config, lib, modulesPath, pkgs, ... }: {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
  ];

  options.local.installer.sshKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Operator SSH public keys baked into the installer ISO's root
      account. Consumers (private deployment repos) typically pass
      `import ./local/ssh-keys.nix` here. An empty list produces an
      ISO that authorises nobody — useful for syntax checks, useless
      for actual deployment.
    '';
  };

  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = config.local.installer.sshKeys;

  environment.systemPackages = with pkgs; [
    git
    tmux
    htop
    jq
  ];

  # The minimal ISO already provides a `nixos` user; anything else this
  # ISO needs to do during install is driven remotely by nixos-anywhere,
  # not by anything baked in here.
  system.stateVersion = "25.11";
}
