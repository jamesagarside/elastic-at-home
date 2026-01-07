workspace "Elastic at Home" "Self-managed Elastic Platform for SIEM and XDR on home networks" {

    !identifiers hierarchical

    model {
        properties {
            "structurizr.groupSeparator" "/"
        }

        # ═══════════════════════════════════════════════════════════════
        # CLOUD SERVICES (Top)
        # ═══════════════════════════════════════════════════════════════
        cloudflare = softwareSystem "Cloudflare" "DNS provider for TLS certificates" "Cloudflare"

        # ═══════════════════════════════════════════════════════════════
        # EXTERNAL ACTORS (Left)
        # ═══════════════════════════════════════════════════════════════
        group "External Sources" {
            user = person "Elastic User" "Uses Elastic Stack"
            networkDevices = softwareSystem "Network Devices" "Routers, firewalls, Ubiquiti, IoT devices" "External"
            remoteAgents = softwareSystem "Remote Agents" "Elastic Agents on external hosts" "Agent"
        }

        # ═══════════════════════════════════════════════════════════════
        # DOCKER SERVICES (Right)
        # ═══════════════════════════════════════════════════════════════
        group "Docker Engine" {
            # Ingress Layer
            traefik = softwareSystem "Traefik" "Reverse proxy with automatic TLS via Let's Encrypt and Layer 4 routing" "Ingress" {
                -> cloudflare "DNS-01 ACME challenge" "HTTPS"
            }

            # Elastic Stack
            elasticsearch = softwareSystem "Elasticsearch" "Search & analytics engine, stores all security events" "Database"
            kibana = softwareSystem "Kibana" "Dashboarding, SIEM, XDR, alerting, Fleet management UI" "WebApp"
            fleetServer = softwareSystem "Fleet Server" "Agent enrollment, policy distribution, APM" "FleetServer"
            elasticAgent = softwareSystem "Elastic Agent" "Collects system logs & metrics, syslog data and runs Synthetics" "Agent"
        }

        # ═══════════════════════════════════════════════════════════════
        # DATA FLOWS (Color-coded end-to-end paths through proxy)
        # ═══════════════════════════════════════════════════════════════

        # BLUE: User Access Flow (User → Kibana)
        user -> traefik "HTTPS :443" "" "UserFlow"
        traefik -> kibana "kibana.example.com → kibana:5601" "" "UserFlow"

        # TEAL+ORANGE: Agent Traffic (Management + Telemetry)
        remoteAgents -> traefik "HTTPS :443" "" "AgentFlow,TelemetryFlow"
        traefik -> fleetServer "fleet.example.com → fleet:8220" "" "AgentFlow"

        # PINK: Syslog Flow (Network Devices → Agent)
        networkDevices -> traefik "TCP/UDP :514" "" "SyslogFlow"
        traefik -> elasticAgent "syslog.example.com → agent:5514" "" "SyslogFlow"

        # ORANGE+PINK: All telemetry routes to Elasticsearch
        elasticAgent -> traefik "Logs & metrics → es.example.com" "" "SyslogFlow,TelemetryFlow"
        traefik -> elasticsearch "es.example.com → es01:9200" "" "TelemetryFlow,SyslogFlow"

        # Fleet Server connects directly to Elasticsearch
        fleetServer -> elasticsearch "Agent metadata & policies" "HTTPS :9200"

        # Kibana queries Elasticsearch directly
        kibana -> elasticsearch "Queries & dashboards" "HTTPS :9200"
    }

    views {
        properties {
            "structurizr.paperSize" "A3_Landscape"
        }

        branding {
            logo images/icons/elastic.png
            font "Inter" https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700
        }

        systemLandscape "Architecture" {
            include *
            autoLayout lr 400 300
            title "Elastic at Home - Architecture Overview"
            description "Data flows: Blue=User Access | Teal=Agent Management | Orange=Telemetry | Pink=Syslog Pipeline"
        }

        # Elastic Brand Styles (EUI Color Tokens)
        # Primary: #0B64DD | Accent: #BC1E70 | AccentSecondary: #008B87
        # Text: #111C2C (heading) | #1D2A3E (body) | #516381 (subdued)
        # Backgrounds: #FFFFFF (plain) | #E8F1FF (primary)
        styles {
            element "Person" {
                background #E8F1FF
                color #111C2C
                shape Person
            }
            element "Software System" {
                background #FFFFFF
                color #111C2C
                shape RoundedBox
                icon images/icons/elastic.png
            }
            element "External" {
                background #E8F1FF
                color #111C2C
                icon images/icons/network.svg
            }
            element "Cloudflare" {
                background #E8F1FF
                color #111C2C
                icon images/icons/cloudflare.svg
            }
            element "Ingress" {
                background #E8F1FF
                color #111C2C
                shape RoundedBox
                icon images/icons/traefik.svg
            }
            element "Database" {
                background #FFFFFF
                color #111C2C
                shape Cylinder
                icon images/icons/elasticsearch.png
                stroke #0B64DD
                strokeWidth 3
            }
            element "WebApp" {
                background #FFFFFF
                color #111C2C
                shape WebBrowser
                icon images/icons/kibana.png
                stroke #0B64DD
                strokeWidth 3
            }
            element "FleetServer" {
                background #FFFFFF
                color #111C2C
                shape Hexagon
                icon images/icons/agent.png
                stroke #0B64DD
                strokeWidth 3
            }
            element "Agent" {
                background #FFFFFF
                color #111C2C
                shape Component
                icon images/icons/agent.png
                stroke #0B64DD
                strokeWidth 3
            }
            relationship "Relationship" {
                thickness 2
                color #516381
            }
            # Color-coded data flows (visible through proxy)
            relationship "UserFlow" {
                thickness 3
                color #0B64DD
                style solid
            }
            relationship "AgentFlow" {
                thickness 3
                color #008B87
                style solid
            }
            relationship "TelemetryFlow" {
                thickness 3
                color #F5A623
                style solid
            }
            relationship "SyslogFlow" {
                thickness 3
                color #BC1E70
                style dashed
            }
            element "Group:External Sources" {
                color #516381
            }
            element "Group:Docker Engine" {
                color #0B64DD
            }
        }
    }
}
