#!/bin/bash
# Script to create a private network using QBFT

usage() {
    echo ""
    echo "Usage: $0 besu-image-name [--node-dsa=<DSA>] [--accounts-dsas=<DSA,...>] [--terminals]"
    echo "       $0 --resume [--accounts-dsas=<DSA,...>] [--terminals]"
    echo "  --node-dsa   Node key algorithm: SECP256K1 (default), SECP256R1, SECP256K1-MLDSA44 or"
    echo "               SECP256K1-FALCON512 (experimental, see README)"
    echo "  --accounts-dsas  Comma-separated DSAs accepted for account (transaction) signatures, among"
    echo "               $ALL_ACCOUNTS_DSAS"
    echo "               (default: SECP256K1, or the nodes' current value with --resume)"
    echo "               Alias: --accounts-supported-dsas, as the option in config.toml"
    echo "  --terminals  Open one terminal window per node instead of running them all in this one"
    echo "  --resume     Start the network created by a previous run again, without regenerating"
    echo "               the genesis, keys, node configs or chain data"
    echo "Example: $0 hyperledger/besu"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-MLDSA44"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-FALCON512"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256R1"
    echo "The number of nodes is blockchain.nodes.count in genesis-generator/qbftConfig.json."
    echo ""
}

#Open a terminal window titled $1 running the command $2, with the first emulator found.
#The window stays open after the command ends so its last output can still be read.
open_terminal() {
    local cmd="$2; echo; read -rp 'Press Enter to close this window'"
    if command -v gnome-terminal > /dev/null; then gnome-terminal --title="$1" -- bash -c "$cmd"
    elif command -v konsole > /dev/null; then konsole -p tabtitle="$1" -e bash -c "$cmd" &
    elif command -v xfce4-terminal > /dev/null; then xfce4-terminal --title="$1" -x bash -c "$cmd" &
    elif command -v xterm > /dev/null; then xterm -T "$1" -e bash -c "$cmd" &
    elif command -v x-terminal-emulator > /dev/null; then x-terminal-emulator -e bash -c "$cmd" &
    else return 1
    fi
}

#Delete previous node containers (node-1, node-2, ...) whatever their number
remove_containers() {
    docker rm -f genesis-generator $(docker ps -aq --filter "name=^node-[0-9]+$") > /dev/null 2>&1
}

#Validate the --accounts-dsas list and turn it into the TOML array of accounts-supported-dsas
ACCOUNTS_DSAS_TOML=""
parse_accounts_dsas() {
    local dsa list=""
    IFS=',' read -ra dsas <<< "${ACCOUNTS_DSAS// /}"
    if [ ${#dsas[@]} -eq 0 ]; then
        echo "--accounts-dsas needs at least one DSA"; exit 1
    fi
    for dsa in "${dsas[@]}"; do
        if [[ ",$ALL_ACCOUNTS_DSAS," != *",$dsa,"* ]]; then
            echo "Unsupported account DSA: $dsa (supported: $ALL_ACCOUNTS_DSAS)"; exit 1
        fi
        list+="${list:+,}\"$dsa\""
    done
    ACCOUNTS_DSAS_TOML="[$list]"
}

#Set accounts-supported-dsas in the given config.toml files, when --accounts-dsas is given
set_accounts_dsas() {
    [ -z "$ACCOUNTS_DSAS_TOML" ] && return
    sed -i "s#^accounts-supported-dsas=.*#accounts-supported-dsas=$ACCOUNTS_DSAS_TOML#" "$@"
}

#Run the nodes as the current user, also for a later plain "docker compose up"
set_user_env() {
    export MY_UID=$(id -u)
    export MY_GID=$(id -g)
    printf 'MY_UID=%s\nMY_GID=%s\n' "$MY_UID" "$MY_GID" > .env
}

#Start the NODE_COUNT nodes of docker-compose.generated.yaml, all in this terminal or,
#with --terminals, each in its own window. Existing containers are reused, not recreated.
start_network() {
    if [ "$TERMINALS" == "true" ] && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
        #Create the network and containers here, then start each node attached in its own window:
        #Ctrl+C in a window stops only that node
        docker compose -f docker-compose.generated.yaml up --no-start
        for ((node = 1; node <= NODE_COUNT; node++)); do
            if ! open_terminal "node-$node" "docker start -a node-$node"; then
                echo "No terminal emulator found, running all nodes in this terminal"
                docker compose -f docker-compose.generated.yaml up
                return
            fi
        done
        echo "Nodes started in separate terminals. To stop them all:"
        echo "  docker compose -f docker-compose.generated.yaml down"
    else
        [ "$TERMINALS" == "true" ] && echo "No graphical session found, running all nodes in this terminal"
        docker compose -f docker-compose.generated.yaml up
    fi
}

IMAGE=""
NODE_DSA="SECP256K1"
TERMINALS=false
RESUME=false
ACCOUNTS_DSAS=""
ALL_ACCOUNTS_DSAS="SECP256K1,SECP256R1,FALCON512,MLDSA44,MLDSA65,MLDSA87,SECP256K1-MLDSA44,SECP256K1-FALCON512"
while [ $# -gt 0 ]; do
    case "$1" in
        --node-dsa=*) NODE_DSA="${1#*=}" ;;
        --node-dsa) NODE_DSA="$2"; shift ;;
        --terminals) TERMINALS=true ;;
        --resume) RESUME=true ;;
        --accounts-dsas=*|--accounts-supported-dsas=*) ACCOUNTS_DSAS="${1#*=}"; [ -z "$ACCOUNTS_DSAS" ] && ACCOUNTS_DSAS=" " ;;
        --accounts-dsas|--accounts-supported-dsas) ACCOUNTS_DSAS="${2:- }"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *) IMAGE="$1" ;;
    esac
    shift
done

#A new network accepts only SECP256K1 account signatures by default; --resume keeps the current list
[ -z "$ACCOUNTS_DSAS" ] && [ "$RESUME" != "true" ] && ACCOUNTS_DSAS="SECP256K1"
[ -n "$ACCOUNTS_DSAS" ] && parse_accounts_dsas

if [ "$RESUME" == "true" ]; then
    if [ ! -f docker-compose.generated.yaml ]; then
        echo "No network to resume: run $0 besu-image-name first"
        exit 1
    fi
    NODE_COUNT=$(grep -c '^  node-[0-9]*:$' docker-compose.generated.yaml)
    echo "Resuming the existing $NODE_COUNT-node network"
    #The node directories are mounted in the containers, so the new value applies on this start
    set_accounts_dsas node-[0-9]*/config.toml
    grep -h "^accounts-supported-dsas=" node-[0-9]*/config.toml | sort | uniq -c
    set_user_env
    start_network
    exit
fi

#Expected node public key length (hex chars) and network elliptic curve for each supported DSA.
#Besu refuses to start when the node DSA (or a hybrid's classical half) signs on a curve other
#than the genesis ecCurve, so the curve is derived from the node DSA.
#Falcon is not supported by Besu's p2p layer yet: discovery (discv4) cannot decode its
#variable-length signatures and the node record (ENR) has no field for its key. Falcon networks
#therefore run without discovery, connecting their nodes through static nodes instead.
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
    if [ "$STATIC_NODES" == "true" ]; then
        echo "WARNING: --node-dsa $NODE_DSA is experimental: Besu's p2p layer does not support it yet,"
        echo "so the network runs without discovery, through static nodes (see README)."
    fi

    # Fixes User Permission Issues
    set_user_env

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

    remove_containers
    docker compose up

    if [ ! -f networkFiles/genesis.json ]; then
        echo "Genesis generation failed: see the genesis-generator output above"
        exit 1
    fi

    # for FOLDER in "grafana" "prometheus"; do
    #     if [ -d "$FOLDER" ]; then
    #         echo "Copying $FOLDER to the root directory..."
    #         cp -r "$FOLDER" ../
    #     else
    #         echo "$FOLDER folder not found inside genesis-generator!"
    #     fi
    # done

    #Nodes Creation: one node per generated key (blockchain.nodes.count in qbftConfig.json)
    rm -rf ../node-[0-9]* #Delete previous node directories, which may be more than this network's
    count=1
    rpc_http_port=8545
    p2p_port=30303
    for dir in networkFiles/keys/*; do
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
        set_accounts_dsas ../node-$count/config.toml
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
    NODE_COUNT=$((count - 1))
    echo "Created $NODE_COUNT nodes"

    #Get enodes: the node ID is the full public key of the active DSA
    #(ECDSA only for SECP256K1/SECP256R1, ECDSA || ML-DSA-44 for SECP256K1-MLDSA44,
    #ECDSA || Falcon-512 for SECP256K1-FALCON512)
    cd ..
    enodes=()
    for ((node = 1; node <= NODE_COUNT; node++)); do
        pubkey=$(tr -d '[:space:]' < node-$node/data/key.pub)
        pubkey=${pubkey#0x}
        if [ ${#pubkey} -ne $PUBKEY_HEX_LENGTH ]; then
            echo "Invalid node-$node public key for $NODE_DSA: expected $PUBKEY_HEX_LENGTH hex chars, got ${#pubkey}"
            exit 1
        fi
        enodes+=("\"enode://$pubkey@172.20.0.$((node + 1)):$((30302 + node))\"")
    done

    if [ "$STATIC_NODES" == "true" ]; then
        #Discovery is disabled, which also keeps the node record (ENR) out of the way,
        #so the nodes connect directly to each other through a static nodes file instead
        echo "Discovery disabled for $NODE_DSA: connecting the nodes through static-nodes.json"
        static_nodes=$(IFS=,; echo "[${enodes[*]}]")
        for ((node = 1; node <= NODE_COUNT; node++)); do
            echo "$static_nodes" > node-$node/static-nodes.json
            echo -e "\n\ndiscovery-enabled=false\nstatic-nodes-file=\"/usr/app/static-nodes.json\"" >> node-$node/config.toml
        done
    else
        #Set node-1 as the bootnode of every other node (P2P Port node-1:30303)
        for ((node = 2; node <= NODE_COUNT; node++)); do
            echo -e "\n\nbootnodes=[${enodes[0]}]" >> node-$node/config.toml
        done
    fi

    #Compose file for this network's nodes (node-N at 172.20.0.(N+1))
    {
        echo "# Generated by init-qbft.sh for $NODE_COUNT nodes"
        echo "networks:"
        echo "  besu:"
        echo "    driver: bridge"
        echo "    ipam:"
        echo "      config:"
        echo "        - subnet: 172.20.0.0/24"
        echo ""
        echo "services:"
        for ((node = 1; node <= NODE_COUNT; node++)); do
            echo "  node-$node:"
            echo "    extends:"
            echo "      file: \"./node-$node/docker-compose.yaml\""
            echo "      service: node"
            echo "    networks:"
            echo "      besu:"
            echo "        ipv4_address: 172.20.0.$((node + 1))"
        done
    } > docker-compose.generated.yaml

    remove_containers #To avoid errors, delete previous containers with the same name

    #Start QBFT Network
    start_network

    # (cd ../prometheus && docker compose up -d)
    # (cd ../grafana && docker compose up -d)
fi
