# DAWS_BAS

An open-source Building Automation System (BAS) built for learning and experimentation.

## Architecture
```
Field Devices (BACnet, Modbus, MQTT, OPC-UA, LON)
          │
          ▼
    Protocol Gateway  (192.168.30.18)
    Discovers devices, normalizes data
          │
          ▼
    RabbitMQ          (192.168.30.13)
    Message broker — the spine of the system
          │
    ┌─────┴──────┬──────────────┐
    ▼            ▼              ▼
InfluxDB     Neo4j         Web UI
(history)  (device model)  (coming soon)
192.168.30.14  192.168.30.17
    │
    ▼
Grafana       (192.168.30.16)
Dashboards, trends, alerts
```

## Services

| Service | IP | Port | Purpose |
|---|---|---|---|
| Protocol Gateway | 192.168.30.18 | — | BACnet, Modbus, MQTT, OPC-UA, LON |
| RabbitMQ | 192.168.30.13 | 5672, 15672 | Message broker |
| InfluxDB + Telegraf | 192.168.30.14 | 8086 | Time-series database |
| Grafana | 192.168.30.16 | 3000 | Dashboards |
| Neo4j | 192.168.30.17 | 7474, 7687 | Graph database |

## Deployment

### Option 1 — Docker Compose (single machine)
```bash
cp .env.example .env
# Edit .env with your settings
docker compose up -d
```

### Option 2 — Proxmox LXC (individual services)
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/rabbitmq/install.sh)"
```

## Related Projects
- [Traffic Light Simulator](https://github.com/DawsonFinnie/Traffic-Lights)
