## Private network using QBFT on Hyperledger Besu

**Script for creating a QBFT consensus network (four nodes by default) using the informed Hyperledger Besu Docker image.**

The nodes expose their JSON-RPC endpoints on consecutive ports starting at 8545:

| Node | JSON-RPC URL |
|---|---|
| Node 1 | http://localhost:8545 |
| Node 2 | http://localhost:8546 |
| Node 3 | http://localhost:8547 |
| Node 4 | http://localhost:8548 |
| Node N | http://localhost:(8544 + N) |

The script streams the logs of all nodes directly in the terminal — no separate `docker logs` command needed.

On Windows, read [Running on Windows](#running-on-windows) first.

## Contents

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Running on Windows](#running-on-windows)
  - [Behind an HTTPS proxy](#behind-an-https-proxy)
- [Usage](#usage)
  - [Number of nodes](#number-of-nodes)
  - [Node key algorithm (`--node-dsa`)](#node-key-algorithm---node-dsa)
  - [Account signature algorithms (`--accounts-dsas`)](#account-signature-algorithms---accounts-dsas)
- [Verifying the network](#verifying-the-network)
- [Monitoring (Prometheus and Grafana)](#monitoring-prometheus-and-grafana)
  - [Dashboards](#dashboards)
  - [How it fits together](#how-it-fits-together)
- [Some JSON-RPC API endpoints](#some-json-rpc-api-endpoints)
  - [Querying the accounts supported DSAs](#querying-the-accounts-supported-dsas)
  - [Querying Transactions and Blocks](#querying-transactions-and-blocks)
- [Stopping the network](#stopping-the-network)


## Prerequisites

- Docker with Docker Compose v2.20 or later (`docker compose`): Docker Engine on Linux, or Docker Desktop or Rancher Desktop on Windows and macOS
- Bash: any Linux or macOS shell, or Git Bash on Windows
- The **PQC Besu image**, e.g. `hyperledger/besu:26.1.0-pqc`. The node configs use the options `node-dsa` and `accounts-supported-dsas`, which only this custom Besu build has, so the stock `hyperledger/besu` image from Docker Hub does not work. The PQC image is not on Docker Hub: build it from the PQC Besu fork, or copy it from a teammate's machine (see [Quick start](#quick-start))
- `curl`, to query the nodes. With `--monitoring`, also access to grafana.com, to download the Besu Full dashboard (optional, see [Monitoring](#monitoring-prometheus-and-grafana))


## Quick start

1. **Get the image.** Check that it is there:

   ```sh
   docker images hyperledger/besu
   ```

   To copy it from another machine that has it:

   ```sh
   docker save hyperledger/besu:26.1.0-pqc -o besu-pqc.tar   # on the machine that has it
   docker load -i besu-pqc.tar                               # on yours
   ```

2. **Start a 4-node network** from the repository root. The terminal then shows the nodes' logs; leave it open:

   ```sh
   chmod +x init-qbft.sh
   ./init-qbft.sh hyperledger/besu:26.1.0-pqc
   ```

   The first run takes about a minute: it generates the genesis and the node keys, then starts the nodes. A new block every 2 seconds appears in the logs as `Produced empty block #N` or `Imported empty block #N`.

3. **Check it** from a second terminal, in the same directory:

   ```sh
   ./init-qbft.sh --status
   ```

   Every node should be `running`, with a block height that rises at each call. Any JSON-RPC client can now use http://localhost:8545 (node-1) to http://localhost:8548 (node-4), for example:

   ```sh
   curl -s -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545
   ```

4. **Stop it** with Ctrl+C in the first terminal, or `./init-qbft.sh --stop` from the second. The chain data is kept: `./init-qbft.sh --resume` starts the same network again, from the same block.

Next steps:

- Post-quantum node keys or account signatures: add [`--node-dsa`](#node-key-algorithm---node-dsa) or [`--accounts-dsas`](#account-signature-algorithms---accounts-dsas), e.g. `./init-qbft.sh hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-MLDSA44 --accounts-dsas=SECP256K1,SECP256K1-MLDSA44`.
- Dashboards: add `--monitoring` (or `./init-qbft.sh --resume --monitoring` on an existing network), then open Grafana at http://localhost:3000 (`admin` / `admin`). See [Monitoring](#monitoring-prometheus-and-grafana).
- More or fewer nodes: see [Number of nodes](#number-of-nodes).

Running `./init-qbft.sh <image>` again creates a **new** network: it deletes the `node-*` directories, chain data included. Use `--resume` to keep them.


## Running on Windows

The script is a Bash script and runs in **Git Bash** (installed with [Git for Windows](https://gitforwindows.org/)), with Docker Desktop or Rancher Desktop as the container engine. Run every command of this README in Git Bash, not in PowerShell or `cmd`.

- **Start the container engine first.** When it is not running, every `docker` command fails with `failed to connect to the docker API at npipe:////./pipe/docker_engine`. Rancher Desktop takes about a minute to start; `docker info` succeeds once it is ready.
- **Line endings.** Git for Windows usually converts text files to CRLF on checkout (`core.autocrlf=true`). Shell scripts with CRLF fail with errors such as `$'\r': command not found`, in Git Bash and also inside the Grafana container, which runs `genesis-generator/grafana/start.sh`. [.gitattributes](.gitattributes) keeps `*.sh` files LF on checkout. A clone made before that file existed keeps its CRLF copies until they are checked out again:

  ```sh
  rm init-qbft.sh init-gramine-qbft.sh genesis-generator/grafana/start.sh
  git checkout -- init-qbft.sh init-gramine-qbft.sh genesis-generator/grafana/start.sh
  ```

- **Paths in your own `docker` commands.** Git Bash rewrites arguments that look like Unix paths, so `docker run -v myvolume:/data ...` receives a Windows path instead of `/data`. Prefix such commands with `MSYS_NO_PATHCONV=1`. `init-qbft.sh` itself is not affected.
- **`--terminals`** needs a Linux graphical session: on Windows the script prints `No graphical session found` and runs every node in the current terminal. Use a second Git Bash window with `./init-qbft.sh --status` and `./init-qbft.sh --logs node-N` instead.
- **One network at a time.** Networks created by this script use the same container names, ports and subnet. If you have two copies of this repository, for example a clone and a copy made by another project, only one of them can run; `./init-qbft.sh --status` shows `elsewhere` for containers owned by the other one.

### Behind an HTTPS proxy

Some corporate networks inspect HTTPS traffic with their own certificate authority. Windows trusts it, but Docker containers do not, so HTTPS downloads made *inside* a container fail with `x509: certificate signed by unknown authority`. This is why `init-qbft.sh` downloads the Besu Full dashboard on the host and hands it to Grafana, instead of letting Grafana download it. If the download fails on the host too, Grafana uses the copy from a previous run, or opens on the Besu QBFT network dashboard.


## Usage

The [Quick start](#quick-start) covers the basic run. `./init-qbft.sh --help` lists every option; the main ones are described below.

### Number of nodes

The network has one validator node per key generated from `blockchain.nodes.count` in [genesis-generator/qbftConfig.json](genesis-generator/qbftConfig.json) (4 by default). Node N gets IP `172.20.0.(N+1)`, P2P port `30302 + N`, JSON-RPC port `8544 + N` and metrics port `9544 + N`. The script generates `docker-compose.generated.yaml` (gitignored) with one service per node and starts the network from it.

### Node key algorithm (`--node-dsa`)

By default the nodes use `SECP256K1` keys. To start a network with another node key algorithm, pass `--node-dsa`:

- `./init-qbft.sh hyperledger/besu:26.1.0-pqc --node-dsa=SECP256R1` (ECDSA on the secp256r1 curve)
- `./init-qbft.sh hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-MLDSA44` (hybrid ECDSA ‖ ML-DSA-44)
- `./init-qbft.sh hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-FALCON512` (hybrid ECDSA ‖ Falcon-512, **experimental**, see below)

The selected DSA is used to generate the node keys and the genesis validators, and it is written as `node-dsa` in every node's `config.toml`. All nodes in a network must use the same DSA. The enode of each node contains its full public key:

| `--node-dsa` | Public key (hex chars) | Genesis `ecCurve` |
|---|---|---|
| `SECP256K1` | 128 | `secp256k1` |
| `SECP256R1` | 128 | `secp256r1` |
| `SECP256K1-MLDSA44` | 2752 (ECDSA ‖ ML-DSA-44) | `secp256k1` |
| `SECP256K1-FALCON512` *(experimental)* | 1920 (ECDSA ‖ Falcon-512) | `secp256k1` |

Besu refuses to start when `--node-dsa` (or the classical half of a hybrid) signs on a different curve than the genesis `ecCurve`. The script therefore writes the matching `ecCurve` into `genesis-generator/qbftConfig.generated.json`, a copy of `qbftConfig.json` used to generate the genesis, so `qbftConfig.json` itself is left untouched. On a `secp256r1` network, legacy (non-flexible) transactions are signed on secp256r1 as well.

#### `SECP256K1-FALCON512` is experimental

Besu's p2p layer does not support Falcon yet:

- Peer discovery (discv4) cannot decode packets with variable-length signatures such as Falcon-512's, and fails with a `NullPointerException` in `Packet.publicKeyIndex`.
- The discovery node record (ENR) has no field for a Falcon key.

With `SECP256K1-FALCON512` the script therefore disables discovery (`discovery-enabled=false`) and connects the nodes through a `static-nodes.json` file in every node directory instead of bootnodes. This only works because disabling discovery also keeps the ENR out of the way. QBFT consensus itself runs normally over these static connections. Treat Falcon node keys as experimental until Besu's discovery and ENR support them, and don't enable discovery on these networks.

On `SECP256R1` networks Besu logs `Missing PKEY_SECP256K1 field` when writing the discovery node record. This is harmless and does not affect consensus.

### Account signature algorithms (`--accounts-dsas`)

By default the nodes accept only transactions signed with `SECP256K1`. To accept other DSAs, pass `--accounts-dsas` with a comma-separated list:

- `./init-qbft.sh hyperledger/besu:26.1.0-pqc --accounts-dsas=SECP256K1,MLDSA44` (new network)
- `./init-qbft.sh --resume --accounts-dsas=SECP256K1` (existing network, see [Stopping the network](#stopping-the-network))

The list is written as `accounts-supported-dsas` in every node's `config.toml`. It is independent of `--node-dsa`, which only sets the node keys. Each value must be one of:

| `--accounts-dsas` value | Algorithm |
|---|---|
| `SECP256K1` | ECDSA on the secp256k1 curve |
| `SECP256R1` | ECDSA on the secp256r1 curve |
| `FALCON512` | Falcon-512 |
| `MLDSA44`, `MLDSA65`, `MLDSA87` | ML-DSA-44, ML-DSA-65, ML-DSA-87 |
| `SECP256K1-MLDSA44` | hybrid ECDSA ‖ ML-DSA-44 |
| `SECP256K1-FALCON512` | hybrid ECDSA ‖ Falcon-512 |

Without the flag, a new network accepts only `SECP256K1`, and `--resume` keeps each node's current list. With `--resume`, the flag rewrites only that line in the existing `node-*/config.toml` files, keeping the chain data, so a DSA can be removed from (or added back to) a running chain to simulate a change in the accepted algorithms. Stop the network first, since the new list applies when the nodes start. The active list can be checked with [`vnt_getAccountsSupportedDSAs`](#querying-the-accounts-supported-dsas).


## Verifying the network

Once the network is running, check it from the directory where it was created, in another terminal:

```sh
./init-qbft.sh --status
```

It shows the network's node key algorithm (`--node-dsa`) and account signature algorithms (`--accounts-dsas`), then lists each container with its state and, for the running nodes, the block height and peer count reported over JSON-RPC, and the URLs on the host:

```
Network in /home/user/besu-qbft: 4 nodes
Node key algorithm: SECP256K1-MLDSA44
Account signature algorithms: SECP256K1, SECP256K1-MLDSA44

CONTAINER        STATE      BLOCK     PEERS  URL
node-1           running    33        3      http://localhost:8545
node-2           running    33        1      http://localhost:8546
node-3           running    33        1      http://localhost:8547
node-4           running    33        1      http://localhost:8548
qbft-prometheus  running    -         -      http://localhost:9090
qbft-grafana     running    -         -      http://localhost:3000
```

The node key algorithm comes from `node-dsa` in each `node-N/config.toml`. The account signature algorithms are those a running node reports through `vnt_getAccountsSupportedDSAs` (see [Querying the accounts supported DSAs](#querying-the-accounts-supported-dsas)), else `accounts-supported-dsas` in its `config.toml`. When the nodes disagree, for example after editing one node's `config.toml`, each node's value is listed instead. The `qbft-prometheus` and `qbft-grafana` rows appear only for a network started with `--monitoring`. The block height should rise every few seconds on every node. `absent` means the container does not exist (the network is stopped). `elsewhere` means a network created in **another directory**, such as another clone or copy of this repository, holds that container name now: every network made by this script uses the same container names, ports and subnet, so only one of them can run at a time. The directory owning it is printed below the table.

To follow the logs of all the nodes, or of one service (`node-N`, `prometheus` or `grafana`):

```sh
./init-qbft.sh --logs
./init-qbft.sh --logs node-2
```

The same check with Docker alone: confirm all nodes are up and their RPC ports are published to the host:

```sh
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

With the default four nodes, the expected output shows `node-1` through `node-4` with `0.0.0.0:8545->8545/tcp` through `0.0.0.0:8548->8548/tcp`, plus, with `--monitoring`, `qbft-prometheus` (`0.0.0.0:9090->9090/tcp`) and `qbft-grafana` (`0.0.0.0:3000->3000/tcp`).

## Monitoring (Prometheus and Grafana)

Monitoring is off by default. With `--monitoring`, `init-qbft.sh` (also with `--terminals`) starts Prometheus and Grafana along with the nodes, as the services `prometheus` and `grafana` (containers `qbft-prometheus` and `qbft-grafana`) of `docker-compose.generated.yaml`. They run on the nodes' network at the fixed IPs `172.20.0.253` and `172.20.0.254`, so they never take a node's IP:

| Service | URL | Notes |
|---|---|---|
| Prometheus | http://localhost:9090 | **Status > Target health** lists one `besu` target per node, which should all be `UP` |
| Grafana | http://localhost:3000 | Login `admin` / `admin`. Opens on the **Besu Full** dashboard |

```sh
./init-qbft.sh hyperledger/besu --monitoring
```

`--resume` keeps the network's current choice: a network created with `--monitoring` resumes with it. `--resume --monitoring` adds the monitoring to a network created without it, and `--resume --no-monitoring` starts the nodes alone (the existing metrics history is kept for the next time).

Monitoring costs a few hundred MB of memory and host ports 9090 and 3000, and adds the dashboard download to the start. Its disk use is small: with 4 nodes, about 1 to 5 MB of Prometheus data per hour, kept for 7 days.

To publish the monitoring on other host ports, set `PROMETHEUS_PORT` and `GRAFANA_PORT`, e.g. `GRAFANA_PORT=3001 ./init-qbft.sh --resume --monitoring`. The script saves them in `.env`, so later runs keep them. It stops before starting anything when one of these ports is already taken on the host. Networks started by an earlier version of this branch have monitoring containers named `prometheus` and `grafana`: remove them first with `docker rm -f prometheus grafana`.

### Dashboards

Grafana has two dashboards in the **Besu** folder, both reading the provisioned **Prometheus** datasource:

- **Besu Full**, the home dashboard: [grafana.com dashboard 16455](https://grafana.com/grafana/dashboards/16455), published by Consensys and recommended by the Besu documentation. `init-qbft.sh` downloads it from the host each time it starts the monitoring, into `genesis-generator/grafana/dashboards-grafana-com/` (gitignored), pinned to revision 11 by `BESU_FULL_DASHBOARD_REVISION` in [init-qbft.sh](init-qbft.sh). The host downloads it, not the Grafana container, so a proxy certificate the host trusts also works. Without access to grafana.com Grafana uses the copy from a previous run, or opens on Besu QBFT network if it never downloaded one. Several of its rows stay empty on this network because they do not apply to it: snap and fast sync, Execution Engine, the layered transaction pool (the nodes use `tx-pool="sequenced"`), RocksDB (metrics not enabled) and host disk usage (needs a host metrics exporter).
- **Besu QBFT network**: [genesis-generator/grafana/dashboards/besu-qbft.json](genesis-generator/grafana/dashboards/besu-qbft.json), a one-screen view for load tests: chain height, blocks per minute, transactions and gas per second, transaction pool, peers, JSON-RPC requests by method, JVM heap and scrape status, per node.

To change **Besu QBFT network**, edit it in Grafana, then use **Export > Export as JSON**, overwrite `genesis-generator/grafana/dashboards/besu-qbft.json` with the exported file and commit it. Changes saved only in Grafana are not in the repository, and Grafana can overwrite them with the file when it provisions the dashboard again. To follow a newer revision of Besu Full, change `BESU_FULL_DASHBOARD_REVISION` and run `./init-qbft.sh --resume`.

### How it fits together

- Each node serves its metrics (`metrics-enabled`, `metrics-host="0.0.0.0"` in [genesis-generator/config.toml](genesis-generator/config.toml)) on port `9544 + N` of the Docker network. These ports are not published to the host: Prometheus reaches each node by its service name (`node-1:9545`, `node-2:9546`, ...).
- The script writes `genesis-generator/prometheus/prometheus.generated.yml` (gitignored) with one scrape target per node, labelled `node="node-N"`, so it follows the number of nodes (at most 251). `--resume` rewrites it, and `docker-compose.generated.yaml`, from the existing node count.
- The service definitions are in [genesis-generator/prometheus/docker-compose.yaml](genesis-generator/prometheus/docker-compose.yaml) and [genesis-generator/grafana/docker-compose.yaml](genesis-generator/grafana/docker-compose.yaml), and the datasource and dashboard providers in [genesis-generator/grafana/provisioning](genesis-generator/grafana/provisioning).
- Metrics history and Grafana settings are kept in the `prometheus-data` and `grafana-data` Docker volumes across restarts. `docker compose -f docker-compose.generated.yaml down -v` deletes them.

To check the targets from the command line (one `"health":"up"` per node):

```sh
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
```

The node logs alone are shown in the terminal. To see the monitoring logs, run `docker logs qbft-prometheus` or `docker logs qbft-grafana`. To restart only the monitoring, for example after editing a dashboard file:

```sh
docker compose -f docker-compose.generated.yaml up -d --force-recreate prometheus grafana
```

## Some JSON-RPC API endpoints
### Querying the accounts supported DSAs

Use the Besu JSON-RPC API to verify which Digital Signature Algorithms are supported by the accounts:

```bash
curl -X POST --data '{"jsonrpc":"2.0","method":"vnt_getAccountsSupportedDSAs","params":[],"id":1}' http://localhost:8545
```

The expected response should contain a `result` that matches the list of supported DSAs contained in
the `accounts-supported-dsas` attribute in the file `config.toml`.

E.g.
```
{"jsonrpc":"2.0","id":1,"result":["SECP256K1","SECP256K1-MLDSA44"]}
```

### Querying Transactions and Blocks

Use the Besu JSON-RPC API to verify that transactions and blocks are being processed and queried correctly.

**Get a Transaction by Hash:**

```bash
curl -X POST --data '{"jsonrpc":"2.0","method":"eth_getTransactionByHash","params":["0xYOUR_TRANSACTION_HASH"],"id":1}' http://localhost:8545
```

Returns the full details of a transaction given its hash, including sender, receiver, value, and gas used.

**Get a Block by Number:**

```bash
curl -X POST --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":[YOUR_BLOCK_NUMBER, true],"id":1}' http://localhost:8545
```

Returns the full details of a block given its number. The second parameter `true` means the response will include full transaction objects instead of just hashes.


## Stopping the network

Pressing **Ctrl+C** in the terminal where `init-qbft.sh` is running is the quickest way to stop the network.

From any other terminal, in the directory where the network was created, this stops and removes all its containers, with any monitoring, whatever the number of nodes:

```sh
./init-qbft.sh --stop
```

The chain data in `node-*/data` and the Prometheus and Grafana volumes are kept. If the containers belong to a network created in another directory (see `elsewhere` in `--status`), `--stop` leaves them running and names that directory: run it there.

With `--terminals` (e.g. `./init-qbft.sh hyperledger/besu --terminals`), the script opens one terminal window per node (gnome-terminal, konsole, xfce4-terminal or xterm), and runs Prometheus and Grafana, if any, in the background. Ctrl+C in a window stops only that node; `./init-qbft.sh --stop` stops them all.

Without a graphical session or terminal emulator, it falls back to running every node in the current terminal.

To start a stopped network again without regenerating it (same genesis, keys, node configs and chain data, including any manual edits to `node-*/config.toml`), use `--resume`, optionally with `--terminals`:

```sh
./init-qbft.sh --resume --terminals
```

Without the script, `--stop` is the same as the following command, except for the check of the directory that owns the containers:

```sh
docker compose -f docker-compose.generated.yaml down
```

Or, with the default four nodes:

```sh
docker rm -f node-1 node-2 node-3 node-4 qbft-prometheus qbft-grafana
```
