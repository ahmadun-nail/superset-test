job "postgres-credential-demo" {
  datacenters = ["dc1"]
  type        = "service"

  group "demo" {
    count = 1

    task "db-demo" {
      driver = "docker"

      vault {
        change_mode = "noop"
      }

      config {
        image        = "vault-lab/demo-service:local"
        network_mode = "vault-lab"
        force_pull   = false
      }

      template {
        destination = "secrets/db.json"
        change_mode = "noop"
        perms       = "0400"
        uid         = 10001
        gid         = 10001
        wait {
          min = "2s"
          max = "5s"
        }
        data = <<-EOT
          {{- with secret "database/creds/demo-rotation" -}}
          {"username":{{ .Data.username | toJSON }},"password":{{ .Data.password | toJSON }},"lease_id":{{ .LeaseID | toJSON }}}
          {{- end -}}
        EOT
      }

      identity {
        name = "vault"
        aud  = ["vault.io"]
        ttl  = "15m"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
