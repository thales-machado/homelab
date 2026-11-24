terraform {
  required_providers {
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = "~> 2.0"
    }
  }
}

# Reached by container name on cloudflare-net, which is where tf() runs this:
# the public hostname would need Pi-hole for DNS and Traefik for TLS, neither of
# which a container on that network has. ALLOWED_HOSTS already accepts the name.
provider "healthchecksio" {
  api_url = "http://healthchecks:8000/api/v1"
}
