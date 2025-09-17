{ config, pkgs, lib, ... }:

let
  serverIP = "192.168.1.171";  # <- set your PC's IP here
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
    # Minimal Xorg session launching the Python Tk client
    export DISPLAY=:0
    # Disable screen blanking/DPMS once X is up
    ${pkgs.xorg.xset}/bin/xset -dpms || true
    ${pkgs.xorg.xset}/bin/xset s off || true
    ${pkgs.xorg.xset}/bin/xset s noblank || true
    exec ${pythonEnv}/bin/python3 ${kioskClient}
  '';

  startX = pkgs.writeShellScript "start_kiosk.sh" ''
    #!${pkgs.bash}/bin/bash
    export HOME=/var/lib/kiosk
    export XDG_RUNTIME_DIR=/run/kiosk
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    chown kiosk:kiosk "$HOME" "$XDG_RUNTIME_DIR" || true

    # Start bare Xorg on vt7 and run the kiosk session as the kiosk user
    exec ${pkgs.xorg.xorgserver}/bin/Xorg :0 -nolisten tcp vt7 &
    # Give X a moment to be ready
    for i in $(seq 1 20); do
      if [ -S /tmp/.X11-unix/X0 ]; then break; fi
      sleep 0.3
    done
    exec sudo -u kiosk ${runSession}
  '';
in
{
  imports = [ ];

  # Basic networking (DHCP)
  networking.useDHCP = lib.mkDefault true;

  # Create a dedicated user for the kiosk app
  users.users.kiosk = {
    isNormalUser = true;
    description = "Kiosk user";
    home = "/var/lib/kiosk";
    createHome = true;
    extraGroups = [ "video" "input" ];
    # No password; not intended for shell login
    hashedPassword = null;
  };

  # Install dependencies (python + tk, xorg server, xset, sudo for switching user)
  environment.systemPackages = with pkgs; [
    pythonEnv
    xorg.xorgserver
    xorg.xset
    sudo
  ];

  # Make sure sudo can run without password for the kiosk start script
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

  # Start at boot: a systemd service that starts Xorg and runs the kiosk client
  systemd.services.kiosk = {
    description = "Kiosk launcher (Xorg + Tk client)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "systemd-user-sessions.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${startX}";
      Restart = "always";
      RestartSec = "3s";
      User = "root";  # we start Xorg, then drop to 'kiosk' user for the app
      StandardOutput = "journal";
      StandardError = "journal";
      # Ensure a clean X lock on restart
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f /tmp/.X0-lock || true";
    };
  };

  # Console: auto-login root (optional; not required since service starts anyway)
  services.getty.autologinUser = lib.mkDefault "root";

  # Boot loader & EFI support (for ISO/UEFI installs)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep system lightweight: no desktop manager
  services.xserver.enable = false;
  services.displayManager.enable = false;

  # Allow unfree if needed in the future (e.g., VM drivers)
  nixpkgs.config.allowUnfree = true;

  # Timezone optional
  time.timeZone = "UTC";

  # Optional: set hostname
  networking.hostName = "kiosk-nixos";
}