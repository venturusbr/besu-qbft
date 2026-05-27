## Private network using QBFT on Hyperledger Besu

**Script for creating a QBFT network on Hyperledger Besu using Docker.**


## Prerequisites

- `docker-compose`
- `Besu Image`


## Usage

- `chmod +x init-qbft.sh`
- You need to know the name of the besu image. Replace ***hyperledger/besu*** with your image name
- `./init-qbft.sh hyperledger/besu`
- To specify a DSA algorithm (optional), e.g. SECP256K1-MLDSA44:
- `./init-qbft.sh hyperledger/besu SECP256K1-MLDSA44`


## Verifying the network

Once the network is running, confirm all four nodes are up and their RPC ports are published to the host:

```sh
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output shows `node-1` through `node-4` with `0.0.0.0:8545->8545/tcp` through `0.0.0.0:8548->8548/tcp`.


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
