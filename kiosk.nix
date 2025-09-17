{ config, pkgs, lib, ... }:

let
  serverIP = "192.168.1.171"; # <- set your PC's IP here

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    tkinter
  ]);

  kioskClient = pkgs.writeText "kiosk_client.py" ''
    #!/usr/bin/env python3
    import socket, json, tkinter as tk, threading, time

    SERVER_IP = "${serverIP}"
    SERVER_PORT = 8080

    class Kiosk:
        def __init__(self):
            self.root = tk.Tk()
            self.root.title("Kiosk Display")
            self.root.configure(bg="#000022")
            try:
                self.root.attributes("-fullscreen", True)
            except Exception:
                self.root.geometry("1024x768")
            self.root.bind("<Escape>", lambda e: self.root.attributes("-fullscreen", False))
            self.label = tk.Label(
                self.root,
                text="Connecting...",
                font=("Arial", 28, "bold"),
                fg="#00CCFF",
                bg="#000022",
                wraplength=900,
                justify="center",
            )
            self.label.pack(expand=True, fill="both", padx=40, pady=40)
            self.sock = None
            threading.Thread(target=self.loop, daemon=True).start()

        def set_text(self, text, color="white"):
            self.root.after(0, lambda: self.label.config(text=text, fg=color))

        def loop(self):
            attempt = 0
            while True:
                attempt += 1
                try:
                    if self.sock:
                        self.sock.close()
                    self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    self.sock.settimeout(10)
                    self.set_text(f"Connecting to {SERVER_IP}:{SERVER_PORT} (try {attempt})", "#FFAA00")
                    self.sock.connect((SERVER_IP, SERVER_PORT))
                    self.set_text("Connected! Waiting for messages...", "#00FF00")
                    self.recv()
                except Exception as e:
                    self.set_text(f"Failed: {e}\nRetrying in 5s...", "#FF4444")
                    time.sleep(5)

        def recv(self):
            buf = ""
            try:
                while True:
                    data = self.sock.recv(1024).decode("utf-8")
                    if not data:
                        break
                    buf += data
                    lines = buf.split("\n")
                    buf = lines[-1]
                    for ln in lines[:-1]:
                        if not ln.strip():
                            continue
                        try:
                            j = json.loads(ln)
                            msg = j.get("message", "").strip()
                            ts = j.get("timestamp", "")
                            if msg:
                                self.set_text(f"{msg}\n\n🕐 {ts}", "white")
                        except Exception:
                            pass
            finally:
                try:
                    self.sock.close()
                except Exception:
                    pass

        def run(self):
            self.root.mainloop()

    if __name__ == "__main__":
        Kiosk().run()
  '';

  runSession = pkgs.writeShellScript "run_kiosk_session.sh" ''
    #!${pkgs.bash}/bin/bash
    export DISPLAY=:0
    ${pkgs.xorg.xset}/bin/xset -display :0 -dpms || true
    ${pkgs.xorg.xset}/bin/xset -display :0 s off || true
    ${pkgs.xorg.xset}/bin/xset -display :0 s noblank || true
    exec ${pythonEnv}/bin/python3 ${kioskClient}
  '';

startX = pkgs.writeShellScript "start_kiosk.sh" ''
  #!${pkgs.bash}/bin/bash
  set -ex

  COREUTILS=${pkgs.coreutils}/bin
  XORG=${pkgs.xorg.xorgserver}/bin
  XSET=${pkgs.xorg.xset}/bin
  XTERM=${pkgs.xterm}/bin/xterm

  echo "[kiosk] start_kiosk running from: $0"

  export HOME=/var/lib/kiosk
  export XDG_RUNTIME_DIR=/run/kiosk
  "$COREUTILS"/mkdir -p "$HOME"
  "$COREUTILS"/chown kiosk:kiosk "$HOME"
  "$COREUTILS"/mkdir -p "$XDG_RUNTIME_DIR"
  "$COREUTILS"/chown root:root "$XDG_RUNTIME_DIR"
  "$COREUTILS"/chmod 700 "$XDG_RUNTIME_DIR"

  "$COREUTILS"/mkdir -p /etc/X11/xorg.conf.d
  cat >/etc/X11/xorg.conf.d/10-modesetting.conf <<'EOF'
  Section "Device"
    Identifier "Modeset"
    Driver "modesetting"
  EndSection
  Section "Screen"
    Identifier "Screen0"
    Device "Modeset"
    DefaultDepth 24
    SubSection "Display"
      Depth 24
      Modes "1024x768"
    EndSubSection
  EndSection
  Section "ServerFlags"
    Option "AutoAddGPU" "false"
  EndSection
  EOF

  "$XORG"/Xorg :0 -nolisten tcp -config /etc/X11/xorg.conf.d/10-modesetting.conf &

  for i in $(seq 1 120); do
    [ -S /tmp/.X11-unix/X0 ] && break
    sleep 0.25
  done

  if ! pgrep -x Xorg >/dev/null 2>&1; then
    echo "[kiosk] Xorg is not running; see /var/log/Xorg.0.log"
    exit 1
  fi

  "$XSET"/xset -display :0 -dpms || true
  "$XSET"/xset -display :0 s off || true
  "$XSET"/xset -display :0 s noblank || true

  # DEBUG: keep X alive and prove display works (10 seconds)
/usr/bin/env echo "[kiosk] launching xterm"
/usr/bin/env "${XTERM}" -display :0 -geometry 80x24+10+10 \
  -e ${pkgs.bash}/bin/bash -c 'echo "Kiosk X up"; sleep 10' &

  # Now launch your Tk app
  exec sudo -u kiosk ${pythonEnv}/bin/python3 ${kioskClient}
'';
in
{
  # Basic networking (DHCP)
  networking.useDHCP = lib.mkDefault true;

  # Explicitly create the 'kiosk' group
  users.groups.kiosk = {};

  # Kiosk user
  users.users.kiosk = {
    isNormalUser = true;
    description = "Kiosk user";
    home = "/var/lib/kiosk";
    createHome = true;
    extraGroups = [ "video" "input" ];
    group = "kiosk";        # primary group
    hashedPassword = null;  # no password / not intended for login
  };

  # Packages required
  environment.systemPackages = with pkgs; [
    pythonEnv
    xorg.xorgserver
    xorg.xset
    xterm
    sudo
  ];

  # Passwordless sudo so the service can drop to 'kiosk'
  security.sudo = {
    enable = true;
    extraRules = [{
      groups = [ "wheel" ];
      commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
    }];
    extraConfig = ''
      kiosk ALL=(kiosk) NOPASSWD: ALL
      root  ALL=(kiosk) NOPASSWD: ALL
    '';
  };

  # Kiosk launcher service
  systemd.services.kiosk = {
    description = "Kiosk launcher (Xorg + Tk client)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "systemd-user-sessions.service" ];
    wants  = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${startX}";
      Restart = "always";
      RestartSec = "3s";
      User = "root";
      # A volatile runtime dir for the service (root-owned)
/* optional: */ RuntimeDirectory = "kiosk";
      StandardOutput = "journal";
      StandardError  = "journal";
      ExecStopPost   = "${pkgs.coreutils}/bin/rm -f /tmp/.X0-lock || true";
    };
  };

  # Optional: auto-login to console (not required for kiosk to run)
  services.getty.autologinUser = lib.mkDefault "root";

  # Boot loader & EFI support
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # No desktop environment; we start Xorg directly
  services.xserver.enable = false;
  services.displayManager.enable = false;

  # Misc
  nixpkgs.config.allowUnfree = true;
  time.timeZone = "UTC";
  networking.hostName = "kiosk-nixos";
}