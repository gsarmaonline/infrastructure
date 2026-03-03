variable "node_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "size" {
  type = string
  default = "s-1vcpu-1gb"
}

variable "image" {
  type = string
  default = "ubuntu-18-04-x64"
}

variable "region" {
  type = string
  default = "blr1"
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

variable "infisical_client_id" {
  type      = string
  default   = "placeholder"
  sensitive = true
}

variable "infisical_client_secret" {
  type      = string
  default   = "placeholder"
  sensitive = true
}

variable "encryption_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Infisical ENCRYPTION_KEY (32-char hex). Auto-generated if empty."
}

variable "auth_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Infisical AUTH_SECRET (32-char hex). Auto-generated if empty."
}
