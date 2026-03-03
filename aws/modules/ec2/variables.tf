variable "instance_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
  default = "ap-south-1c"
}

variable "ami_id" {
    type = string
    default = "ami-06984ea821ac0a879"
}

variable "instance_type" {
    type = string
    default = "t2.micro"
}

variable "key_name" {
  type = string
  default = "pg-key"
}

variable "repo_url" {
  type        = string
  description = "HTTPS URL of the git repo to clone on boot."
}

variable "vpn_subnet" {
  type        = string
  default     = ""
  description = "VPN CIDR (e.g. 100.64.0.0/10). Enables firewall + ArgoCD ingress."
}

variable "letsencrypt_email" {
  type        = string
  default     = "you@example.com"
  description = "Email for Let's Encrypt notifications."
}

