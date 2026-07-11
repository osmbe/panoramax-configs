{ instance, ... }:
{
  services.openssh = {
    enable = true;
    ports = [ instance.sshPort ];
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitEmptyPasswords = "no";
      X11Forwarding = false;

      # Modern crypto only. Excludes very old PuTTY etc., which is fine.
      KexAlgorithms = [
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
      ];
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
      ];
      Macs = [
        "hmac-sha2-512-etm@openssh.com"
        "hmac-sha2-256-etm@openssh.com"
      ];
    };
  };
}
