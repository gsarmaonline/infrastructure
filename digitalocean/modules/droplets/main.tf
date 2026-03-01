resource "digitalocean_droplet" "this" {
  name      = "${var.environment}-${var.node_name}"
  size      = var.size
  image     = var.image
  region    = var.region
  vpc_uuid  = data.digitalocean_vpc.vpc.id
  user_data = file("${path.root}/../../../setup/init.sh")
}
