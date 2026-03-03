resource "digitalocean_droplet" "this" {
  name      = "${var.environment}-${var.node_name}"
  size      = var.size
  image     = var.image
  region    = var.region
  vpc_uuid  = data.digitalocean_vpc.vpc.id
  user_data = templatefile("${path.root}/../../../setup/cloud-init.sh.tpl", {
    repo_url                = var.repo_url
    vpn_subnet              = var.vpn_subnet
    letsencrypt_email       = var.letsencrypt_email
    infisical_client_id     = var.infisical_client_id
    infisical_client_secret = var.infisical_client_secret
    encryption_key          = var.encryption_key
    auth_secret             = var.auth_secret
  })
}
