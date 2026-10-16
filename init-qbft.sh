#!/bin/bash
# Script to create a private network using QBFT

usage() {
    echo ""
    echo "Usage: $0 besu-image-name [--node-dsa=<DSA>]"
    echo "  --node-dsa   Node key algorithm: SECP256K1 (default), SECP256R1, SECP256K1-MLDSA44 or SECP256K1-FALCON512"
    echo "Example: $0 hyperledger/besu"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-MLDSA44"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-FALCON512"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256R1"
    echo ""
}

IMAGE=""
NODE_DSA="SECP256K1"
while [ $# -gt 0 ]; do
    case "$1" in
        --node-dsa=*) NODE_DSA="${1#*=}" ;;
        --node-dsa) NODE_DSA="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *) IMAGE="$1" ;;
    esac
    shift
done

#Expected node public key length (hex chars) and network elliptic curve for each supported DSA.
#Besu refuses to start when the node DSA (or a hybrid's classical half) signs on a curve other
#than the genesis ecCurve, so the curve is derived from the node DSA.
#Falcon signatures have no fixed length, which discovery (discv4) does not support, so Falcon
#networks connect their nodes through static nodes instead.
STATIC_NODES=false
case "$NODE_DSA" in
    SECP256K1) PUBKEY_HEX_LENGTH=128; EC_CURVE=secp256k1 ;;          # 64 bytes
    SECP256R1) PUBKEY_HEX_LENGTH=128; EC_CURVE=secp256r1 ;;          # 64 bytes
    SECP256K1-MLDSA44) PUBKEY_HEX_LENGTH=2752; EC_CURVE=secp256k1 ;; # 64 + 1312 bytes
    SECP256K1-FALCON512) PUBKEY_HEX_LENGTH=1920; EC_CURVE=secp256k1; STATIC_NODES=true ;; # 64 + 896 bytes
    *) echo "Unsupported --node-dsa: $NODE_DSA"; usage; exit 1 ;;
esac

if [ "$IMAGE" == "" ]; then
    usage
else
    echo "Using image $IMAGE with node DSA $NODE_DSA (ecCurve $EC_CURVE)"

    # Fixes User Permission Issues
    export MY_UID=$(id -u)
    export MY_GID=$(id -g)

    #Genesis Generation
    cd genesis-generator
    rm -rf networkFiles #Delete previous directory

    #Set the genesis ecCurve to the node DSA curve in a generated copy of qbftConfig.json
    sed -e '/"ecCurve"/d' \
        -e "s#^\( *\)\"chainId\":.*#&\n\1\"ecCurve\": \"$EC_CURVE\",#" qbftConfig.json > qbftConfig.generated.json

    #Image, config file and node DSA for the genesis generator's docker-compose.yaml
    export BESU_IMAGE="$IMAGE"
    export QBFT_CONFIG_FILE="qbftConfig.generated.json"
    export NODE_DSA

    docker rm -f node-1 node-2 node-3 node-4 genesis-generator > /dev/null 2>&1 #Delete previous containers with the same name
    docker compose up

    # for FOLDER in "grafana" "prometheus"; do
    #     if [ -d "$FOLDER" ]; then
    #         echo "Copying $FOLDER to the root directory..."
    #         cp -r "$FOLDER" ../
    #     else
    #         echo "$FOLDER folder not found inside genesis-generator!"
    #     fi
    # done

    #Nodes Creation
    count=1
    rpc_http_port=8545
    p2p_port=30303
    for dir in networkFiles/keys/*; do
        rm -rf ../node-$count #Delete previous directories with the same name
        mkdir -p ../node-$count/data/ #Create the node directory
        cp -f networkFiles/genesis.json ../node-$count/ #Copy the generated genesis to the node directory
        cp -rf $dir/* ../node-$count/data/ #Copy all files to /data
        for file in *.csv; do
            cp -f "$file" "../node-$count/"
        done
        #Set http and p2p port, p2p host and node DSA in node config.toml
        sed -e "s#rpc-http-port.*#rpc-http-port=$rpc_http_port#" \
            -e "s#p2p-port=.*#p2p-port=$p2p_port#" \
            -e "s#p2p-host=.*#p2p-host=\"172.20.0.$((count + 1))\"#" \
            -e "s#node-dsa=.*#node-dsa=\"$NODE_DSA\"#" \
            -e "s#metrics-port=.*#metrics-port=$((9544 + count))#" config.toml > ../node-$count/config.toml
        #Set the image name in the node docker-compose.yaml
        sed -e "s#image:.*#image: $IMAGE#" \
            -e "s#container_name:.*#container_name: node-$count#" \
            -e "s#PLACEHOLDER_RPC_PORT#$rpc_http_port:$rpc_http_port#" \
            -e "s#PLACEHOLDER_METRICS_PORT#$((9544 + count)):$((9544 + count))#" \
            node-docker-compose.yaml > ../node-$count/docker-compose.yaml

        ((count++))
        ((rpc_http_port++))
        ((p2p_port++))
    done

    #Get enodes: the node ID is the full public key of the active DSA
    #(ECDSA only for SECP256K1/SECP256R1, ECDSA || ML-DSA-44 for SECP256K1-MLDSA44,
    #ECDSA || Falcon-512 for SECP256K1-FALCON512)
    cd ..
    enodes=()
    for node in {1..4}; do
        pubkey=$(tr -d '[:space:]' < node-$node/data/key.pub)
        pubkey=${pubkey#0x}
        if [ ${#pubkey} -ne $PUBKEY_HEX_LENGTH ]; then
            echo "Invalid node-$node public key for $NODE_DSA: expected $PUBKEY_HEX_LENGTH hex chars, got ${#pubkey}"
            exit 1
        fi
        enodes+=("\"enode://$pubkey@172.20.0.$((node + 1)):$((30302 + node))\"")
    done

    if [ "$STATIC_NODES" == "true" ]; then
        #Discovery (discv4) cannot decode packets signed with variable-length signatures,
        #so the nodes connect directly to each other through a static nodes file instead
        echo "Discovery disabled for $NODE_DSA: connecting the nodes through static-nodes.json"
        static_nodes=$(IFS=,; echo "[${enodes[*]}]")
        for node in {1..4}; do
            echo "$static_nodes" > node-$node/static-nodes.json
            echo -e "\n\ndiscovery-enabled=false\nstatic-nodes-file=\"/usr/app/static-nodes.json\"" >> node-$node/config.toml
        done
    else
        #Set bootnodes in nodes 2, 3 and 4. (localhost:127.0.0.1 - P2P Port node-1:30303)
        for node in {2..4}; do
            echo -e "\n\nbootnodes=[${enodes[0]}]" >> node-$node/config.toml
        done
    fi

    docker rm node-1 node-2 node-3 node-4 genesis-generator > /dev/null 2>&1 #To avoid errors, delete previous containers with the same name

    #Start QBFT Network
    docker compose up

    # (cd ../prometheus && docker compose up -d)
    # (cd ../grafana && docker compose up -d)
fi
