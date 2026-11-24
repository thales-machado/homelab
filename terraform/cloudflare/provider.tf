terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.29"
    }
  }
}

# Credentials come from CLOUDFLARE_API_TOKEN in the environment, which is the
# same CF_API_TOKEN the rest of the homelab uses. It needs Single Redirect
# edit on top of the tunnel and DNS permissions DockFlare and cfgate rely on.
provider "cloudflare" {}
