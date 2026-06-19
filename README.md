## Private network using QBFT on Hyperledger Besu

**Script for creating a QBFT consensus network of four nodes using the informed Hyperledger Besu Docker image.**

The nodes expose their JSON-RPC endpoints on:

| Node | JSON-RPC URL |
|---|---|
| Node 1 | http://localhost:8545 |
| Node 2 | http://localhost:8546 |
| Node 3 | http://localhost:8547 |
| Node 4 | http://localhost:8548 |

The script streams the logs of all four nodes directly in the terminal — no separate `docker logs` command needed.




## Prerequisites

- `docker-compose`
- `Besu Image`


## Usage

- `chmod +x init-qbft.sh`
- You need to know the name of the besu image. Replace ***hyperledger/besu*** with your image name
- `./init-qbft.sh hyperledger/besu`


## Verifying the network

Once the network is running, confirm all four nodes are up and their RPC ports are published to the host:

```sh
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output shows `node-1` through `node-4` with `0.0.0.0:8545->8545/tcp` through `0.0.0.0:8548->8548/tcp`.

## Some JSON-RPC API endpoints
### Querying the supported DSAs

Use the Besu JSON-RPC API to verify which Digital Signature Algorithms are supported by the nodes:

```bash
curl -X POST --data '{"jsonrpc":"2.0","method":"vnt_getSupportedDSAs","params":[],"id":1}' http://localhost:8545
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

To stop and remove the containers explicitly:

```sh
docker stop node-1 node-2 node-3 node-4
docker rm node-1 node-2 node-3 node-4
```

Or in one command:

```sh
docker rm -f node-1 node-2 node-3 node-4
```
