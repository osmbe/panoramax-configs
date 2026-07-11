{ instance, ... }:
let
  proxyBlock = ''
    encode gzip zstd

    header {
      Strict-Transport-Security "max-age=31536000; includeSubDomains"
      X-Frame-Options SAMEORIGIN
      X-Content-Type-Options nosniff
      Referrer-Policy strict-origin-when-cross-origin
    }

    reverse_proxy 127.0.0.1:8080
  '';
in
{
  # Native Caddy on the host (not in Docker). Reasons:
  #   1. TLS state survives container rebuilds.
  #   2. Declarative NixOS config; no separate Caddy data directory
  #      management.
  #   3. Plays nicely across Docker networks.
  #
  # Both vhosts proxy to the compose-internal nginx on 127.0.0.1:8080.
  # `INFRA_NB_PROXIES=2` (Caddy + nginx) tells Flask to trust two upstream
  # X-Forwarded-* hops. Caddy adds them automatically.
  services.caddy = {
    enable = true;
    email = instance.acmeContactEmail;

    # Disable the Caddy admin API: we don't dynamically reconfigure, and
    # leaving it on adds an attack surface on localhost.
    globalConfig = ''
      admin off
    '';

    virtualHosts.${instance.domain}.extraConfig = proxyBlock;
    virtualHosts.${instance.imageDomain}.extraConfig = proxyBlock;
  };
}
