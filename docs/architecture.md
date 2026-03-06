# DAWS_BAS Architecture

## Data Flow
```
Field Devices
    │  BACnet / Modbus / MQTT / OPC-UA / LON
    ▼
Protocol Gateway (192.168.30.18)
    │  Normalizes all data to standard JSON
    ▼
RabbitMQ (192.168.30.13)
    │  Routing key: point.<protocol>.<point_name>
    ├──► Telegraf → InfluxDB (192.168.30.14)
    ├──► Neo4j consumer (192.168.30.17)
    └──► Web UI consumer (future)
    ▼
Grafana (192.168.30.16)
```

## Normalized Message Format
```json
{
    "protocol":   "bacnet",
    "device_id":  "bacnet:3001",
    "point_name": "supply_temp",
    "value":      "21.5",
    "unit":       "degC",
    "timestamp":  1709123456789,
    "metadata":   {}
}
```

## IP Assignments

| CT  | Service           | IP            | Ports       |
|-----|------------------|---------------|-------------|
| 103 | Traffic Light     | 192.168.30.12 | 8500, 47808 |
| 113 | RabbitMQ          | 192.168.30.13 | 5672, 15672 |
| 114 | InfluxDB+Telegraf | 192.168.30.14 | 8086        |
| 116 | Grafana           | 192.168.30.16 | 3000        |
| 117 | Neo4j             | 192.168.30.17 | 7474, 7687  |
| 118 | Protocol Gateway  | 192.168.30.18 | —           |
