resource "aws_instance" "instance" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  #availability_zone           = var.region
  key_name = var.key_name

  vpc_security_group_ids = [data.aws_security_group.sg.id]
  associate_public_ip_address = true
  subnet_id = data.aws_subnet.subnet.id
  user_data = templatefile("${path.root}/../../../setup/cloud-init.sh.tpl", {
    repo_url          = var.repo_url
    vpn_subnet        = var.vpn_subnet
    letsencrypt_email = var.letsencrypt_email
  })

  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = {
    Name = var.instance_name
    Env = var.environment
  }
}

resource "local_file" "instance_public_ip" {
  content  = aws_instance.instance.public_ip
  filename = "/tmp/${var.instance_name}__${var.environment}__public.ip"
}

resource "local_file" "instance_private_ip" {
  content  = aws_instance.instance.private_ip
  filename = "/tmp/${var.instance_name}__${var.environment}__private.ip"
}
