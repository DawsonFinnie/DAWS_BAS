# DAWS_BAS

An open-source Building Automation System (BAS) built for learning and experimentation.
Designed to be readable, beginner-friendly, and deployable on a home lab Proxmox server.

## What's Working

| Service | Status | URL |
|---|---|---|
| Traffic Light Simulator | ✅ Running | http://192.168.30.12:8500 |
| RabbitMQ | ✅ Running | http://192.168.30.13:15672 |
| InfluxDB + Telegraf | ✅ Running | http://192.168.30.14:8086 |
| Grafana | ✅ Running | http://192.168.30.16:3000 |
| Neo4j | ⬜ Planned | http://192.168.30.17:7474 |
| Protocol Gateway | ⬜ Planned | 192.168.30.18 |

## Architecture

```
Traffic Light (CT 103)          Protocol Gateway (CT 118) [planned]
192.168.30.12                   192.168.30.18
  BACnet device + Flask UI        BACnet, Modbus, MQTT, OPC-UA, LON
  Publishes state changes         Normalizes all protocols
          │                                │
          └──────────────┬─────────────────┘
                         ▼
                   RabbitMQ (CT 113)
                   192.168.30.13:5672
                   Exchange: daws.bas (topic)
                   Routing key: point.<protocol>.<point_name>
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
     Telegraf (on CT 114)      Neo4j (CT 117) [planned]
     Subscribes: point.#       Device relationship graph
     Writes to InfluxDB
              │
              ▼
       InfluxDB (CT 114)
       192.168.30.14:8086
       Bucket: bas
       Measurement: point_update
              │
              ▼
       Grafana (CT 116)
       192.168.30.16:3000
       Live dashboards + trends
```

## Normalized Message Format

Every device publishes this JSON to RabbitMQ regardless of protocol:

```json
{
    "protocol":   "traffic",
    "device_id":  "traffic-light:3001",
    "point_name": "red_light",
    "value":      "active",
    "unit":       "",
    "timestamp":  1709123456789,
    "metadata": {
        "bacnet_device_id": 3001,
        "ip": "192.168.30.12"
    }
}
```

## Proxmox LXC Install Order

Run each installer on the Proxmox host in this order:

```bash
# 1. RabbitMQ
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/rabbitmq/install.sh)"

# 2. InfluxDB + Telegraf
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/influxdb/install.sh)"

# 3. Grafana
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/grafana/install.sh)"

# 4. Neo4j (coming soon)
# 5. Protocol Gateway (coming soon)
```

> **Note:** All LXC containers require VLAN tag 30 on net0 for this network.
> The installers set this automatically. If you create containers manually,
> add `tag=30` to the net0 config: `pct set <id> --net0 name=eth0,bridge=vmbr0,...,tag=30`

## LXC IP Assignments

| CT  | Service            | IP              | Ports          |
|-----|-------------------|-----------------|----------------|
| 103 | Traffic Light      | 192.168.30.12   | 8500, 47808    |
| 113 | RabbitMQ           | 192.168.30.13   | 5672, 15672    |
| 114 | InfluxDB+Telegraf  | 192.168.30.14   | 8086           |
| 116 | Grafana            | 192.168.30.16   | 3000           |
| 117 | Neo4j              | 192.168.30.17   | 7474, 7687     |
| 118 | Protocol Gateway   | 192.168.30.18   | —              |

Network: 192.168.30.0/24, gateway 192.168.30.1

## Known Gotchas

- **Telegraf `json_string_fields`**: The `value` field is a string (`"active"`/`"inactive"`).
  Telegraf's JSON parser drops string fields by default. Must set `json_string_fields = ["value"]`
  in the `amqp_consumer` input or no point data will appear in Grafana.

- **InfluxDB GPG key**: InfluxData rotated their signing key in January 2026.
  Use `influxdata-archive.key` with fingerprint verification, not `influxdata-archive_compat.key`.
  Use the `debian stable` repo, not `ubuntu jammy`.

- **RabbitMQ apt repo**: The Cloudsmith and packagecloud repos are dead.
  Use `deb1.rabbitmq.com` and `deb2.rabbitmq.com` (official as of 2025).

- **Grafana permissions**: `grafana-cli` runs as root and corrupts `/var/lib/grafana` ownership.
  Always run `chown -R grafana:grafana /var/lib/grafana` after using `grafana-cli`.

## Related Projects

- [Traffic Light Simulator](https://github.com/DawsonFinnie/Traffic-Lights) — BACnet/Flask device that publishes to this stack
