{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  # Enable swap cgroup accounting for Docker/Wings
  boot.kernelParams = [ "swapaccount=1" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Prague";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "cs_CZ.UTF-8";
    LC_IDENTIFICATION = "cs_CZ.UTF-8";
    LC_MEASUREMENT = "cs_CZ.UTF-8";
    LC_MONETARY = "cs_CZ.UTF-8";
    LC_NAME = "cs_CZ.UTF-8";
    LC_NUMERIC = "cs_CZ.UTF-8";
    LC_PAPER = "cs_CZ.UTF-8";
    LC_TELEPHONE = "cs_CZ.UTF-8";
    LC_TIME = "cs_CZ.UTF-8";
  };

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  users.users.jsemolik = {
    isNormalUser = true;
    description = "Oliver Steiner";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [ ];
  };

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    curl
    wget
    nano
    jq
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };

  # Pterodactyl system user/group (avoid runtime useradd)
  users.groups.pterodactyl = { };

  users.users.pterodactyl = {
    isSystemUser = true;
    group = "pterodactyl";
    description = "Pterodactyl Wings user";
    home = "/var/lib/pterodactyl";
    createHome = true;
  };

  # Ensure dirs for Wings with proper ownership
  systemd.tmpfiles.rules = [
    "d /etc/pterodactyl 0755 root root -"
    "d /var/run/wings 0755 pterodactyl pterodactyl -"
    "d /var/lib/pterodactyl 0755 pterodactyl pterodactyl -"
    "d /var/log/pterodactyl 0755 pterodactyl pterodactyl -"
  ];

  # Download/install wings binary on switch (oneshot)
  systemd.services.install-wings = {
    description = "Install/Update Pterodactyl Wings binary";
    wantedBy = [ "multi-user.target" ];
    before = [ "wings.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = let
      arch =
        if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
        then "amd64"
        else "arm64";
      wingsUrl =
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}";
    in ''
      set -euo pipefail
      install -d -m 0755 /usr/local/bin
      tmp="$(mktemp)"
      echo "Downloading Wings from: ${wingsUrl}"
      ${pkgs.curl}/bin/curl -L -o "$tmp" "${wingsUrl}"
      install -m 0755 "$tmp" /usr/local/bin/wings
      rm -f "$tmp"
    '';
  };

  # Wings service
  systemd.services.wings = {
    description = "Pterodactyl Wings Daemon";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    partOf = [ "docker.service" ];

    # Add minimal path in case Wings calls out to common tools
    path = with pkgs; [ coreutils util-linux bash ];

    serviceConfig = {
      User = "pterodactyl";
      WorkingDirectory = "/etc/pterodactyl";
      LimitNOFILE = 4096;
      PIDFile = "/var/run/wings/daemon.pid";
      ExecStart = "/usr/local/bin/wings";
      Restart = "on-failure";
      StartLimitIntervalSec = 180;
      StartLimitBurst = 30;
      RestartSec = "5s";
      # Make sure logs and data are writable by the service user
      ReadWritePaths = [
        "/var/run/wings"
        "/var/lib/pterodactyl"
        "/var/log/pterodactyl"
        "/etc/pterodactyl"
      ];
    };

    wantedBy = [ "multi-user.target" ];
  };

  system.stateVersion = "25.05";
}