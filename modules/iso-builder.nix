{ config, pkgs, lib, ... }:

let
  cfg = config.local.isoBuilder;
  homeDir = "/var/lib/iso-builder";
  repoDir = "${homeDir}/repo";
in {
  options.local.isoBuilder = {
    flakeRepo = lib.mkOption {
      type = lib.types.str;
      description = "Git URL of the flake the builder pulls and builds each cycle.";
      example = "https://github.com/your-org/infra-nixos-installer.git";
    };
    flakeBranch = lib.mkOption {
      type = lib.types.str;
      description = "Branch of the flake repo to track.";
      example = "main";
    };
    proxmoxHost = lib.mkOption {
      type = lib.types.str;
      description = "Hostname (or IP) of the Proxmox host that hosts the ISO storage.";
      example = "proxmox.lan";
    };
    proxmoxUser = lib.mkOption {
      type = lib.types.str;
      description = "SSH user on the Proxmox host with write access to the ISO directory.";
      example = "root";
    };
    proxmoxIsoDir = lib.mkOption {
      type = lib.types.str;
      description = "Filesystem path on the Proxmox host into which built ISOs are published.";
      example = "/var/lib/vz/template/iso";
    };
    isoPrefix = lib.mkOption {
      type = lib.types.str;
      description = "Filename prefix for produced ISOs; the latest symlink reuses it.";
      example = "nixos-installer";
    };
    keepGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Number of historical ISO generations to retain on the Proxmox host.";
      example = 5;
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Sun 03:00";
      description = ''
        systemd OnCalendar expression for the internal build timer.
        Ignored when `timerEnabled = false`.
      '';
    };
    timerEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the builder VM owns its own build schedule via a systemd
        timer. Set to `false` when build cadence is owned externally
        (e.g. a hypervisor-side `qm start` + ssh `systemctl start --wait`
        orchestrator, or a GitLab CI runner).
      '';
    };
    shutdownAfterRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the builder VM powers itself off after a successful
        publish. Combined with `timerEnabled = false` this lets an
        external orchestrator wake the VM, drive one build, and let the
        VM self-terminate — so it consumes no resources between builds.
        Only runs on success so failed builds stay up for debugging.
      '';
    };
    sshKeysOverrideFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute path on the builder VM's filesystem to a nix expression
        that overrides `local/ssh-keys.nix` in the iso-builder's clone
        before each build. Resolves the chicken-and-egg where the
        upstream repo carries a placeholder key (so the public flake
        evaluates) while the actual ISO needs the operator's real keys
        baked in.

        Point this at `/etc/nixos-source/local/ssh-keys.nix` on hosts
        that follow the documented on-builder nixos-rebuild pattern;
        the file must be world-readable so the iso-builder service
        account can read it.
      '';
      example = "/etc/nixos-source/local/ssh-keys.nix";
    };
  };

  config = {
    users.users.iso-builder = {
      isSystemUser = true;
      group = "iso-builder";
      home = homeDir;
      createHome = true;
      shell = pkgs.bashInteractive;
    };
    users.groups.iso-builder = { };

    systemd.tmpfiles.rules = [
      "d ${homeDir}      0750 iso-builder iso-builder -"
      "d ${homeDir}/.ssh 0700 iso-builder iso-builder -"
    ];

    nix.settings.trusted-users = [ "iso-builder" ];

    systemd.services.iso-builder = {
      description = "Build the installer ISO and publish it to Proxmox storage";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ git nix openssh coreutils gnused gawk findutils nettools ];

      serviceConfig = {
        Type = "oneshot";
        User = "iso-builder";
        Group = "iso-builder";
        WorkingDirectory = homeDir;
        OOMScoreAdjust = -100;
      };

      script = ''
        set -euo pipefail

        if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
          ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "iso-builder@$(hostname)"
          echo "FIRST-RUN: install this pubkey on ${cfg.proxmoxUser}@${cfg.proxmoxHost}:"
          cat "$HOME/.ssh/id_ed25519.pub"
          echo "Re-run this unit after the key is authorized; aborting now."
          exit 1
        fi

        if [ ! -d "${repoDir}/.git" ]; then
          rm -rf "${repoDir}"
          git clone --branch "${cfg.flakeBranch}" "${cfg.flakeRepo}" "${repoDir}"
        fi
        cd "${repoDir}"
        git fetch origin "${cfg.flakeBranch}"
        git reset --hard "origin/${cfg.flakeBranch}"

        ${lib.optionalString (cfg.sshKeysOverrideFile != null) ''
          # Public upstream ships a placeholder local/ssh-keys.nix so the
          # flake evaluates on a fresh clone. The real keys live on this
          # host outside the iso-builder's clone; copy them over before
          # build so the produced ISO actually authorises the operator.
          if [ -r "${cfg.sshKeysOverrideFile}" ]; then
            cp "${cfg.sshKeysOverrideFile}" local/ssh-keys.nix
            echo "applied ssh-keys override from ${cfg.sshKeysOverrideFile}"
          else
            echo "ERROR: sshKeysOverrideFile is set to '${cfg.sshKeysOverrideFile}' but the file is not readable by the iso-builder user." >&2
            exit 1
          fi
        ''}

        # Roll forward all flake inputs each build — that is how upstream
        # kernel/CVE fixes reach the ISO without manual intervention.
        nix flake update

        nix build --print-out-paths --no-link ".#installer-iso" > .build-out-path
        ISO_OUT="$(cat .build-out-path)/iso"
        ISO_SRC="$(ls "$ISO_OUT"/*.iso | head -n1)"
        [ -n "$ISO_SRC" ] || { echo "ERROR: no .iso produced in $ISO_OUT" >&2; exit 1; }

        SHA="$(git rev-parse --short HEAD)"
        DEST_NAME="${cfg.isoPrefix}-$SHA.iso"
        DEST_PATH="${cfg.proxmoxIsoDir}/$DEST_NAME"
        LATEST_LINK="${cfg.proxmoxIsoDir}/${cfg.isoPrefix}-latest.iso"

        SSH="ssh -o StrictHostKeyChecking=accept-new ${cfg.proxmoxUser}@${cfg.proxmoxHost}"
        SCP="scp -o StrictHostKeyChecking=accept-new"

        # Two-step publish (upload to *.partial, then rename) keeps the latest
        # symlink from ever pointing at a half-written file.
        $SCP "$ISO_SRC" "${cfg.proxmoxUser}@${cfg.proxmoxHost}:$DEST_PATH.partial"
        $SSH "mv -f '$DEST_PATH.partial' '$DEST_PATH' && ln -sfn '$DEST_NAME' '$LATEST_LINK'"

        # Retention: keep the N newest *real* files; never delete the
        # `<prefix>-latest.iso` symlink (which would otherwise count as a
        # listing entry and silently lower the effective N by one).
        $SSH "cd '${cfg.proxmoxIsoDir}' && find . -maxdepth 1 -type f -name '${cfg.isoPrefix}-*.iso' -printf '%T@\\t%f\\n' \
          | sort -rn \
          | awk -v n=${toString cfg.keepGenerations} 'NR > n {print \$2}' \
          | xargs -r rm -f --"

        echo "Published $DEST_NAME (linked as ${cfg.isoPrefix}-latest.iso)."
      '';

      # SuccessAction is executed by PID 1 (not by the service user) only
      # when the unit completes with Result=success — exactly what we want
      # for on-demand orchestration. Doing the shutdown via
      # `systemctl --no-block poweroff` inside the script would fail with
      # "Access denied" because the iso-builder user lacks polkit
      # privileges.
      unitConfig = lib.mkIf cfg.shutdownAfterRun {
        SuccessAction = "poweroff";
      };
    };

    systemd.timers.iso-builder = lib.mkIf cfg.timerEnabled {
      description = "Periodic installer ISO build";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
