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




## Prerequisites

- `docker-compose`
- `Besu Image`


## Usage

- `chmod +x init-qbft.sh`
- You need to know the name of the besu image. Replace ***hyperledger/besu*** with your image name
- `./init-qbft.sh hyperledger/besu`

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


## Verifying the network

Once the network is running, confirm all nodes are up and their RPC ports are published to the host:

```sh
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

With the default four nodes, the expected output shows `node-1` through `node-4` with `0.0.0.0:8545->8545/tcp` through `0.0.0.0:8548->8548/tcp`.

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

To stop and remove the containers explicitly, whatever the number of nodes:

```sh
docker compose -f docker-compose.generated.yaml down
```

Or, with the default four nodes:

```sh
docker rm -f node-1 node-2 node-3 node-4
```
