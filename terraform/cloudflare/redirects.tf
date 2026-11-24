# Edge configuration, for hostnames the cluster does not serve. DockFlare
# writes records from Docker labels and cfgate from HTTPRoutes; this module
# writes only hostnames neither of them knows about, so the rule that matters
# holds: one writer per hostname.

# A redirect only applies to a hostname Cloudflare proxies, and this one has no
# origin, so the address is the documented placeholder: the edge answers the
# request and never connects to it. If the rule below stops matching, visitors
# get an origin error here rather than the wrong content.
resource "cloudflare_dns_record" "www" {
  zone_id = data.cloudflare_zone.thalesmachado_net.id
  name    = "www.thalesmachado.net"
  type    = "A"
  content = "192.0.2.1"
  ttl     = 1
  proxied = true
  comment = "redirect anchor, see terraform/cloudflare"
}

resource "cloudflare_ruleset" "redirects" {
  zone_id = data.cloudflare_zone.thalesmachado_net.id
  name    = "Redirect rules"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [
    {
      ref         = "www_to_apex"
      description = "One canonical URL: www redirects, it never serves"
      expression  = "(http.host eq \"www.thalesmachado.net\")"
      action      = "redirect"
      action_parameters = {
        from_value = {
          # 301, because this is permanent and search engines should collapse
          # the two hostnames into one.
          status_code           = 301
          preserve_query_string = true
          target_url = {
            expression = "concat(\"https://thalesmachado.net\", http.request.uri.path)"
          }
        }
      }
    }
  ]
}
