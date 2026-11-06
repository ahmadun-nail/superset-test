server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

vault {
  enabled               = true
  address               = "http://vault:8200"
  jwt_auth_backend_path = "jwt-nomad"
  create_from_role      = "nomad-postgres-demo"

  default_identity {
    aud = ["vault.io"]
    ttl = "15m"
  }
}
