# Looked up by name so the zone id stays out of a public repo.
data "cloudflare_zone" "thalesmachado_net" {
  filter = {
    name = "thalesmachado.net"
  }
}
