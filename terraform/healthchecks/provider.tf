terraform {
  required_providers {
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = "~> 2.0"
    }
  }
}

provider "healthchecksio" {
  api_url = "https://healthchecks.lan.thalespm.me/api/v1"
}
