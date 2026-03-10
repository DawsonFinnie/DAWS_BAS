# DAWS_BAS Architecture

## Overview

DAWS_BAS is an event-driven building automation platform built on open source components.
Field devices publish state changes to RabbitMQ. Subscribers consume those messages and
write to InfluxDB (history) and Neo4j (device model). Grafana visualizes the data.

The key design principle: **every service is decoupled via RabbitMQ**. Adding a new
consumer (alerts, web UI, ML pipeline) never requires changing existing services.

## Data Flow

```
Traffic Light (CT 103)              Protocol Gateway (CT 118) [planned]
192.168.30.12                        192.168.30.18
  ┌─────────────────┐                 ┌──────────────────────────┐
  │ state.py        │                 │ BACnet WhoIs/IAm         │
  │ __setattr__     │                 │ Modbus poll              │
  │ → rabbitmq.py   │                 │ MQTT subscribe           │
  │ → pika publish  │                 │ OPC-UA subscribe         │
  └────────┬────────┘                 │ LON/IP REST poll         │
           │                          │ → normalizer.py          │
           │ AMQP                     │ → publisher.py           │
           │ point.traffic.*          └──────────┬───────────────┘
           │                                     │ AMQP
           └──────────────┬──────────────────────┘ point.<protocol>.*
                          ▼
              ┌───────────────────────┐
              │ RabbitMQ (CT 113)     │
              │ 192.168.30.13         │
              │                       │
              │ Exchange: daws.bas    │
              │ Type: topic, durable  │
              │ VHost: bas            │
              └───────────┬───────────┘
                          │
           ┌──────────────┴──────────────┐
           │ binding: point.#            │ binding: point.# [planned]
           ▼                             ▼
  ┌─────────────────┐          ┌──────────────────┐
  │ Telegraf        │          │ Neo4j Consumer   │
  │ (on CT 114)     │          │ (CT 117)         │
  │ amqp_consumer   │          │ Updates device   │
  │ → InfluxDB v2   │          │ relationship graph│
  └────────┬────────┘          └──────────────────┘
           ▼
  ┌─────────────────┐
  │ InfluxDB        │
  │ (CT 114)        │
  │ 192.168.30.14   │
  │ Bucket: bas     │
  │ Org: DAWS       │
  └────────┬────────┘
           ▼
  ┌─────────────────┐
  │ Grafana         │
  │ (CT 116)        │
  │ 192.168.30.16   │
  │ Dashboards      │
  │ Auto-refresh 5s │
  └─────────────────┘
```

## Normalized Message Format

Every point update published to RabbitMQ uses this format regardless of source protocol.
This is what makes the system extensible — a BACnet temperature sensor and an MQTT
motion detector look identical to InfluxDB and Grafana.

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

Field definitions:
- `protocol` — source protocol: `traffic`, `bacnet`, `modbus`, `mqtt`, `opcua`, `lon`
- `device_id` — unique device identifier: `<protocol>:<device_number>`
- `point_name` — human-readable point name: `red_light`, `supply_temp`, etc.
- `value` — current value as string: `"active"`, `"21.5"`, `"true"`
- `unit` — engineering unit: `"degC"`, `"Pa"`, `"%RH"`, or `""` if none
- `timestamp` — Unix milliseconds from the device's own clock
- `metadata` — protocol-specific extras (BACnet instance, Modbus register, etc.)

## RabbitMQ Routing Keys

```
point.traffic.red_light        ← traffic light red light state
point.traffic.#                ← all traffic light points
point.bacnet.supply_temp       ← specific BACnet point
point.bacnet.#                 ← all BACnet points
point.modbus.#                 ← all Modbus points
point.mqtt.#                   ← all MQTT points
point.#                        ← everything from all protocols
```

Telegraf subscribes to `point.#` — it receives everything and writes it all to InfluxDB.

## InfluxDB Schema

Measurement: `point_update`

| Type  | Name       | Example value         | Notes                        |
|-------|------------|-----------------------|------------------------------|
| Tag   | device_id  | traffic-light:3001    | Indexed, used for filtering  |
| Tag   | point_name | red_light             | Indexed, used for filtering  |
| Tag   | protocol   | traffic               | Indexed, used for filtering  |
| Tag   | unit       | degC                  | Indexed, used for filtering  |
| Field | value      | active                | String — the actual reading  |
| Time  | —          | 2026-03-10T15:00:00Z  | From message timestamp field |

Example Flux query — traffic light red light history:
```flux
from(bucket: "bas")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "point_update")
  |> filter(fn: (r) => r.device_id == "traffic-light:3001")
  |> filter(fn: (r) => r.point_name == "red_light")
  |> filter(fn: (r) => r._field == "value")
```

## LXC IP Assignments

| CT  | Service            | IP              | Ports          | Status   |
|-----|-------------------|-----------------|----------------|----------|
| 103 | Traffic Light      | 192.168.30.12   | 8500, 47808    | ✅ Running |
| 113 | RabbitMQ           | 192.168.30.13   | 5672, 15672    | ✅ Running |
| 114 | InfluxDB+Telegraf  | 192.168.30.14   | 8086           | ✅ Running |
| 116 | Grafana            | 192.168.30.16   | 3000           | ✅ Running |
| 117 | Neo4j              | 192.168.30.17   | 7474, 7687     | ⬜ Planned |
| 118 | Protocol Gateway   | 192.168.30.18   | —              | ⬜ Planned |

Network: 192.168.30.0/24, gateway 192.168.30.1, DNS 192.168.1.201
Proxmox bridge: vmbr0, VLAN tag: 30 (required on all LXC net0 configs)

## Protocols Supported

| Protocol | Transport  | Discovery       | Handler File   | Status   |
|----------|-----------|-----------------|----------------|----------|
| BACnet   | UDP 47808 | WhoIs/IAm       | bacnet.py      | ⬜ Planned |
| Modbus   | TCP 502   | Manual config   | modbus.py      | ⬜ Planned |
| MQTT     | TCP 1883  | Subscribe #     | mqtt_client.py | ⬜ Planned |
| OPC-UA   | TCP 4840  | Manual config   | opcua.py       | ⬜ Planned |
| LON      | IP/REST   | SmartServer API | lon.py         | ⬜ Planned |
| Traffic  | AMQP/pika | n/a             | rabbitmq.py    | ✅ Working |
