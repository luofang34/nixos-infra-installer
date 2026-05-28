# nixos-infra-installer

Public NixOS modules for producing a customised NixOS installer ISO and
the builder VM that publishes a fresh ISO on a periodic schedule.
Modules-only — site-local values (SSH keys, the Proxmox host the
builder talks to, IP addresses, retention cadence) belong in the
consuming deployment repo.

## Status

Experimental, built primarily for the author's own deployment. No
promises about stability or API compatibility.

## Modules

| Module | Purpose |
|---|---|
| `nixosModules.installer` | Live ISO content: NixOS minimal + QEMU guest agent + sshd (key-only) + the latest mainline kernel. Reads operator keys from the `local.installer.sshKeys` option (`listOf str`). |
| `nixosModules.nixos-builder` | Builder-VM-specific defaults: single-disk disko layout matching `infra-proxmox/lib/create-qemu-vm.sh`, the iso-builder service (via import), and the trust grant the iso-builder user needs to write to /nix/store. |
| `nixosModules.iso-builder` | Option-driven (`local.isoBuilder.*`) systemd service + timer that runs inside the builder VM: `git fetch` + `nix flake update` + `nix build .#installer-iso` + `scp` to Proxmox storage + atomic latest-symlink update + retention. Imported automatically by `nixos-builder`. |

## Option surface

```nix
local.installer.sshKeys = [ "ssh-ed25519 ... operator@…" … ];

local.isoBuilder = {
  flakeRepo            = "git@github.com:your-org/your-private-deployment.git";
  flakeBranch          = "main";
  proxmoxHost          = "<hypervisor>";
  proxmoxUser          = "root";
  proxmoxIsoDir        = "/var/lib/vz/template/iso";
  isoPrefix            = "nixos-installer";
  keepGenerations      = 5;
  shutdownAfterRun     = true;    # SuccessAction = poweroff on the service
  timerEnabled         = false;   # cadence owned externally (hypervisor cron)
  sshKeysOverrideFile  = "/etc/nixos-source/local/ssh-keys.nix";
                                  # optional: cp this over local/ssh-keys.nix
                                  # in the clone before each build cycle
};
```

The consuming repo (private) declares `nixosConfigurations.installer`
and `nixosConfigurations.nixos-builder` with these options set, then
builds `packages.installer-iso =
nixosConfigurations.installer.config.system.build.isoImage`.

## Consuming this flake

```nix
{
  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    installer.url  = "github:luofang34/nixos-infra-installer";
    installer.inputs.nixpkgs.follows = "nixpkgs";
    disko.url      = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # also typically inputs.infra-common ...
  };

  outputs = { self, nixpkgs, installer, disko, ... }@inputs: {
    nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        installer.nixosModules.installer
        { local.installer.sshKeys = import ./local/ssh-keys.nix; }
      ];
    };

    nixosConfigurations.nixos-builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        installer.nixosModules.nixos-builder
        ./hosts/nixos-builder/local.nix       # sets local.isoBuilder.*
        # …common modules, users, hostname, etc…
      ];
    };

    packages.x86_64-linux.installer-iso =
      self.nixosConfigurations.installer.config.system.build.isoImage;
  };
}
```

## License

[AGPL-3.0-or-later](./LICENSE).
