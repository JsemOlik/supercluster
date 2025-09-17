{ config, pkgs, lib, ... }:

let
  serverIP = "192.168.1.171";
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [ tkinter ]);

  kioskClient = pkgs.writeText "kiosk_client.py" ''
#!/usr/bin/env python3
import socket, json, tkinter as tk, threading, time, traceback, sys

SERVER_IP = "${serverIP}"
SERVER_PORT = 8080

def log(msg):
    print(f"[kiosk] {msg}", flush=True)

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
        self.label = tk.Label(self.root, text="Connecting...",
                              font=("Arial", 28, "bold"),
                              fg="#00CCFF", bg="#000022",
                              wraplength=900, justify="center")
        self.label.pack(expand=True, fill="both", padx=40, pady=40)
        self.sock = None
        threading.Thread(target=self.loop, daemon=True).start()

    def set_text(self, text, color="white"):
        self.root.after(0, lambda: self.label.config(text=text, fg=color))

    def connect(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(30)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            # Linux keepalive tuning if available
            s.setsockopt(socket.IPPROTO_TCP, getattr(socket, "TCP_KEEPIDLE", 4), 60)
            s.setsockopt(socket.IPPROTO_TCP, getattr(socket, "TCP_KEEPINTVL", 5), 15)
            s.setsockopt(socket.IPPROTO_TCP, getattr(socket, "TCP_KEEPCNT", 6), 4)
        except Exception:
            pass
        return s

    def loop(self):
        backoff = 5
        while True:
            try:
                if self.sock:
                    try: self.sock.close()
                    except Exception: pass
                self.sock = self.connect()
                log(f"connecting to {SERVER_IP}:{SERVER_PORT}")
                self.set_text(f"Connecting to {SERVER_IP}:{SERVER_PORT} ...", "#FFAA00")
                self.sock.connect((SERVER_IP, SERVER_PORT))
                backoff = 5
                self.set_text("Connected! Waiting for messages...", "#00FF00")
                log("connected")
                self.recv()
            except Exception as e:
                log(f"connect/loop error: {e}")
                traceback.print_exc()
                self.set_text(f"Failed: {e}\nRetrying in {backoff}s...", "#FF4444")
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)

    def recv(self):
        buf = ""
        try:
            while True:
                data = self.sock.recv(1024)
                if not data:
                    log("server closed connection (EOF)")
                    break
                try:
                    chunk = data.decode("utf-8")
                except UnicodeDecodeError as e:
                    # Ignore binary noise
                    log(f"decode error: {e}")
                    continue

                buf += chunk
                lines = buf.split("\n")
                buf = lines[-1]
                for ln in lines[:-1]:
                    if not ln.strip():
                        continue
                    try:
                        j = json.loads(ln)
                        if j.get("type") == "heartbeat":
                            continue
                        msg = j.get("message", "").strip()
                        ts = j.get("timestamp", "")
                        if msg:
                            self.set_text(f"{msg}\n\n🕐 {ts}", "white")
                    except Exception as e:
                        log(f"json parse error: {e} line={ln!r}")
        except Exception as e:
            log(f"recv error: {e}")
            traceback.print_exc()
        finally:
            try: self.sock.close()
            except Exception: pass

    def run(self):
        self.root.mainloop()

if __name__ == "__main__":
    try:
        Kiosk().run()
    except Exception as e:
        log(f"fatal error: {e}")
        traceback.print_exc()
        sys.exit(1)
  '';
in
{
  # Base system
  networking.useDHCP = lib.mkDefault true;
  time.timeZone = "UTC";
  nixpkgs.config.allowUnfree = true;

  # Kiosk user
  users.users.kiosk = {
    isNormalUser = true;
    createHome = true;
    home = "/home/kiosk";
    extraGroups = [ "video" "input" ];
  };

  # Desktop + DM
  services.xserver = {
    enable = true;
    desktopManager.lxqt.enable = true;
    displayManager.lightdm.enable = true;
    displayManager.autoLogin.enable = true;
    displayManager.autoLogin.user = "kiosk";
    displayManager.defaultSession = "lxqt";
    # Disable DPMS/screensaver at session start
    displayManager.sessionCommands = ''
      ${pkgs.xorg.xset}/bin/xset -dpms
      ${pkgs.xorg.xset}/bin/xset s off
      ${pkgs.xorg.xset}/bin/xset s noblank
    '';
  };

  # Optional: system TCP keepalive tuning (helps behind NATs)
boot.kernel.sysctl = {
  "net.ipv4.tcp_keepalive_time" = 60;
  "net.ipv4.tcp_keepalive_intvl" = 8;
  "net.ipv4.tcp_keepalive_probes" = 4;
};

  # Autostart the client as systemd --user
  systemd.user.services.kiosk-client = {
    description = "Kiosk Tk client";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "${pythonEnv}/bin/python3 ${kioskClient}";
      Restart = "always";
      RestartSec = 2;
      Environment = "DISPLAY=:0";
    };
  };

  # Optional: hide LXQt power/saver autostarts (prevent popups)
  environment.etc."xdg/autostart/lxqt-powermanagement.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Power Management
    Exec=lxqt-powermanagement
    OnlyShowIn=LXQt;
    Hidden=true
  '';
  environment.etc."xdg/autostart/lxqt-screensaver.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=ScreenSaver
    Exec=lxqt-screensaver
    OnlyShowIn=LXQt;
    Hidden=true
  '';

  environment.systemPackages = with pkgs; [
    pythonEnv
    xorg.xset
  ];

  # Bootloader (if installing to disk)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}