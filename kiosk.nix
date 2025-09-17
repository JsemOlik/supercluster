{ config, pkgs, lib, ... }:

let
  # Set the server IP your kiosk should connect to
  serverIP = "192.168.1.171";

  # Python environment with Tkinter
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [ tkinter ]);

  # Your Python kiosk client stored in the Nix store
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
in
{
  ############################
  # Base system/network bits #
  ############################
  networking.useDHCP = lib.mkDefault true;
  time.timeZone = "UTC";
  nixpkgs.config.allowUnfree = true;

  ######################
  # Kiosk user account #
  ######################
  users.users.kiosk = {
    isNormalUser = true;
    createHome = true;
    home = "/home/kiosk";
    extraGroups = [ "video" "input" ];
  };

  ##############################
  # Desktop and display manager #
  ##############################
  services.xserver = {
    enable = true;

    # LXQt desktop (lightweight)
    desktopManager.lxqt.enable = true;

    # LightDM for login + autologin
    displayManager.lightdm.enable = true;
    displayManager.autoLogin.enable = true;
    displayManager.autoLogin.user = "kiosk";
    displayManager.defaultSession = "lxqt";
  };

  # Optional: Turn off DPMS/blanking system‑wide for X
  services.xserver.displayManager.sessionCommands = ''
    ${pkgs.xorg.xset}/bin/xset -dpms
    ${pkgs.xorg.xset}/bin/xset s off
    ${pkgs.xorg.xset}/bin/xset s noblank
  '';

  ########################################
  # Autostart the kiosk app for the user #
  ########################################
  # Use a systemd --user service so it restarts if it crashes.
  systemd.user.services.kiosk-client = {
    description = "Kiosk Tk client";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pythonEnv}/bin/python3 ${kioskClient}";
      Restart = "always";
      RestartSec = 2;
      # DISPLAY is set by the desktop session; this is a safe default
      Environment = "DISPLAY=:0";
    };
  };

  # No need to enable explicitly; wantedBy handles it at login.
  # If you want to force-enable it for the kiosk user on boot too, uncomment:
  # systemd.user.targets.default.wants = [ "kiosk-client.service" ];

  #############################
  # Packages available system #
  #############################
  environment.systemPackages = with pkgs; [
    pythonEnv
    xorg.xset
  ];

  ################################
  # Bootloader (for installed OS) #
  ################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}