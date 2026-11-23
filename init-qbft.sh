#!/bin/bash
# Script to create a private network using QBFT

usage() {
    echo ""
    echo "Usage: $0 besu-image-name [--node-dsa=<DSA>] [--accounts-dsas=<DSA,...>] [--terminals] [--monitoring]"
    echo "       $0 --resume [--accounts-dsas=<DSA,...>] [--terminals] [--monitoring|--no-monitoring]"
    echo "  --node-dsa   Node key algorithm: SECP256K1 (default), SECP256R1, SECP256K1-MLDSA44 or"
    echo "               SECP256K1-FALCON512 (experimental, see README)"
    echo "  --accounts-dsas  Comma-separated DSAs accepted for account (transaction) signatures, among"
    echo "               $ALL_ACCOUNTS_DSAS"
    echo "               (default: SECP256K1, or the nodes' current value with --resume)"
    echo "               Alias: --accounts-supported-dsas, as the option in config.toml"
    echo "  --terminals  Open one terminal window per node instead of running them all in this one"
    echo "  --resume     Start the network created by a previous run again, without regenerating"
    echo "               the genesis, keys, node configs or chain data"
    echo "  --monitoring Also start Prometheus and Grafana (off by default). --resume keeps the"
    echo "               network's current choice unless --monitoring or --no-monitoring is given"
    echo "  --no-monitoring  Start the nodes without Prometheus and Grafana (the default)"
    echo "With --monitoring, Prometheus and Grafana are published on ports 9090 and 3000 of the host, or on"
    echo "\$PROMETHEUS_PORT and \$GRAFANA_PORT when set (e.g. GRAFANA_PORT=3001 $0 --resume --monitoring)."
    echo "Example: $0 hyperledger/besu"
    echo "Example: $0 hyperledger/besu --monitoring"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-MLDSA44"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256K1-FALCON512"
    echo "Example: $0 hyperledger/besu:26.1.0-pqc --node-dsa=SECP256R1"
    echo "The number of nodes is blockchain.nodes.count in genesis-generator/qbftConfig.json"
    echo "(at most $MAX_NODES)."
    echo ""
    echo "       $0 --status | --stop | --logs [node-N|prometheus|grafana]"
    echo "  --status     Show the node key and account signature algorithms, each container's state,"
    echo "               the nodes' block height and peers, and the URLs"
    echo "  --stop       Stop and remove the network's containers, keeping the chain data:"
    echo "               --resume starts it again"
    echo "  --logs       Follow the logs of all the nodes, or of the given service"
    echo "These act on the network created in the current directory."
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

#Delete previous node containers (node-1, node-2, ...) whatever their number, and this script's
#monitoring containers
remove_containers() {
    docker rm -f genesis-generator qbft-prometheus qbft-grafana \
        $(docker ps -aq --filter "name=^node-[0-9]+$") > /dev/null 2>&1
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

#Run the nodes as the current user and publish the monitoring on the chosen host ports,
#also for a later plain "docker compose up"
set_user_env() {
    export MY_UID=$(id -u)
    export MY_GID=$(id -g)
    printf 'MY_UID=%s\nMY_GID=%s\nPROMETHEUS_PORT=%s\nGRAFANA_PORT=%s\n' \
        "$MY_UID" "$MY_GID" "$PROMETHEUS_PORT" "$GRAFANA_PORT" > .env
}

#Exit when the network has more nodes than the subnet has IPs for them
check_node_count() {
    if [ "$1" -gt "$MAX_NODES" ]; then
        echo "$1 nodes requested: at most $MAX_NODES fit in 172.20.0.0/24 next to the monitoring"
        exit 1
    fi
}

#Whether something on this host accepts connections on TCP port $1
port_in_use() {
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2> /dev/null
}

#Exit when a host port of the monitoring is taken by something else than its own container:
#docker compose would then fail halfway, with some nodes started in the background
check_monitoring_ports() {
    local container port var
    for container in qbft-prometheus qbft-grafana; do
        if [ "$container" == "qbft-prometheus" ]; then port=$PROMETHEUS_PORT; var=PROMETHEUS_PORT
        else port=$GRAFANA_PORT; var=GRAFANA_PORT
        fi
        [ -n "$(docker ps -q --filter "name=^$container$")" ] && continue
        if port_in_use "$port"; then
            echo "Port $port, needed by ${container#qbft-}, is already in use on this host."
            echo "Free it, choose another one with $var=<port> $0 ..., or start without --monitoring"
            exit 1
        fi
    done
}

#Prometheus scrape config with one target per node: node-N serves its metrics on port 9544+N
#of the nodes' network, where Prometheus reaches it by its service name
write_prometheus_config() {
    local node
    {
        echo "# Generated by init-qbft.sh for $NODE_COUNT nodes"
        echo "global:"
        echo "  scrape_interval: 5s"
        echo "  evaluation_interval: 5s"
        echo ""
        echo "scrape_configs:"
        echo "  - job_name: besu"
        echo "    static_configs:"
        for ((node = 1; node <= NODE_COUNT; node++)); do
            echo "      - targets: [\"node-$node:$((9544 + node))\"]"
            echo "        labels:"
            echo "          node: node-$node"
        done
    } > genesis-generator/prometheus/prometheus.generated.yml
}

#Download the Besu Full dashboard (grafana.com, recommended by the Besu documentation) for
#Grafana, which provisions it from genesis-generator/grafana/dashboards-grafana-com. The host
#downloads it, not the Grafana container, so a proxy CA trusted by the host is honoured.
#Without access to grafana.com the copy from a previous run is kept.
download_besu_full_dashboard() {
    local dir=genesis-generator/grafana/dashboards-grafana-com
    local url="https://grafana.com/api/dashboards/$BESU_FULL_DASHBOARD_ID/revisions/$BESU_FULL_DASHBOARD_REVISION/download"
    mkdir -p "$dir"
    if curl -fsSL --max-time 30 "$url" -o "$dir/besu-full.json.download"; then
        #The file is made for "Dashboards > Import": point its ${DS_PROMETHEUS} input at the
        #provisioned Prometheus datasource (uid "prometheus")
        sed 's/[$]{DS_PROMETHEUS}/prometheus/g' "$dir/besu-full.json.download" > "$dir/besu-full.json"
    elif [ -s "$dir/besu-full.json" ]; then
        echo "Could not download the Besu Full dashboard from $url: using the previous copy"
    else
        echo "Could not download the Besu Full dashboard from $url:"
        echo "Grafana opens on the Besu QBFT network dashboard instead"
    fi
    rm -f "$dir/besu-full.json.download"
}

#Compose file for this network's nodes (node-N at 172.20.0.(N+1)) and their monitoring
#(Prometheus at 172.20.0.253 and Grafana at 172.20.0.254, on the same network)
write_compose_file() {
    local node service ip=253
    {
        echo "# Generated by init-qbft.sh for $NODE_COUNT nodes"
        echo "networks:"
        echo "  besu:"
        echo "    driver: bridge"
        echo "    ipam:"
        echo "      config:"
        echo "        - subnet: 172.20.0.0/24"
        echo ""
        if [ "$MONITORING" == "true" ]; then
            echo "volumes:"
            echo "  prometheus-data:"
            echo "  grafana-data:"
            echo ""
        fi
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
        #Fixed IPs at the top of the subnet: a dynamic one could take a node's IP first
        [ "$MONITORING" == "true" ] && for service in prometheus grafana; do
            echo "  $service:"
            echo "    extends:"
            echo "      file: \"./genesis-generator/$service/docker-compose.yaml\""
            echo "      service: $service"
            echo "    networks:"
            echo "      besu:"
            echo "        ipv4_address: 172.20.0.$((ip++))"
        done
    } > docker-compose.generated.yaml
}

#Run docker-compose.generated.yaml in this terminal, showing only the nodes' logs
compose_up() {
    if [ "$MONITORING" == "true" ]; then
        docker compose -f docker-compose.generated.yaml up --no-attach prometheus --no-attach grafana
    else
        docker compose -f docker-compose.generated.yaml up
    fi
}

#Start the NODE_COUNT nodes of docker-compose.generated.yaml, all in this terminal or,
#with --terminals, each in its own window, along with Prometheus and Grafana.
#Existing containers are reused, not recreated.
start_network() {
    if [ "$MONITORING" == "true" ]; then
        check_monitoring_ports
        download_besu_full_dashboard
        echo "Monitoring: Prometheus at http://localhost:$PROMETHEUS_PORT," \
            "Grafana at http://localhost:$GRAFANA_PORT (admin/admin)"
    fi
    if [ "$TERMINALS" == "true" ] && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
        #Create the network and containers here, start the monitoring in the background, then
        #start each node attached in its own window: Ctrl+C in a window stops only that node
        docker compose -f docker-compose.generated.yaml up --no-start
        [ "$MONITORING" == "true" ] && docker compose -f docker-compose.generated.yaml start prometheus grafana
        for ((node = 1; node <= NODE_COUNT; node++)); do
            if ! open_terminal "node-$node" "docker start -a node-$node"; then
                echo "No terminal emulator found, running all nodes in this terminal"
                compose_up
                return
            fi
        done
        echo "Nodes started in separate terminals. To stop them all, with any monitoring:"
        echo "  docker compose -f docker-compose.generated.yaml down"
    else
        [ "$TERMINALS" == "true" ] && echo "No graphical session found, running all nodes in this terminal"
        compose_up
    fi
}

#Host path of the directory whose docker-compose.generated.yaml created container $1, if any.
#Separators and case are normalized, so Windows paths from Docker compare with this directory's.
container_dir() {
    container_dir_as_is "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]'
}
container_dir_as_is() {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2> /dev/null
}
THIS_DIR=$( (pwd -W 2> /dev/null || pwd) | tr '\\' '/' | tr '[:upper:]' '[:lower:]')

#This network's containers: node-1..node-NODE_COUNT, and the monitoring ones
network_containers() {
    local node
    for ((node = 1; node <= NODE_COUNT; node++)); do echo "node-$node"; done
    echo qbft-prometheus
    echo qbft-grafana
}

#Containers with this network's names that another directory's network created: every network
#made by this script uses the same container names, ports and subnet, and docker compose would
#treat a copy of this directory with the same folder name as the same project
foreign_containers() {
    local container dir
    for container in $(network_containers); do
        dir=$(container_dir "$container")
        [ -n "$dir" ] && [ "$dir" != "$THIS_DIR" ] && echo "$container $(container_dir_as_is "$container")"
    done
}

#Result (a hex quantity) of JSON-RPC method $2 on host port $1, as a decimal number, or "-"
rpc_number() {
    local hex
    hex=$(curl -s --max-time 3 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" "http://localhost:$1" |
        sed -n 's/.*"result" *: *"\(0x[0-9a-fA-F]*\)".*/\1/p')
    if [ -n "$hex" ]; then echo $((hex)); else echo "-"; fi
}

#Node key algorithm of node $1, from its config.toml
node_dsa_of() {
    local dsa
    dsa=$(sed -n 's/^node-dsa *= *"\(.*\)".*/\1/p' "node-$1/config.toml" 2> /dev/null | tail -n 1)
    echo "${dsa:-SECP256K1 (not set)}"
}

#Account signature algorithms of node $1: what the running node reports over JSON-RPC, else
#accounts-supported-dsas in its config.toml
accounts_dsas_of() {
    local dsas=""
    if [ "$(docker inspect -f '{{.State.Status}}' "node-$1" 2> /dev/null)" == "running" ] &&
        [ "$(container_dir "node-$1")" == "$THIS_DIR" ]; then
        dsas=$(curl -s --max-time 3 -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"vnt_getAccountsSupportedDSAs","params":[],"id":1}' \
            "http://localhost:$((8544 + $1))" | sed -n 's/.*"result" *: *\[\([^]]*\)\].*/\1/p')
    fi
    [ -z "$dsas" ] && dsas=$(sed -n 's/^accounts-supported-dsas *= *\[\(.*\)\].*/\1/p' \
        "node-$1/config.toml" 2> /dev/null | tail -n 1)
    dsas=$(echo "$dsas" | tr -d '" ' | sed 's/,/, /g')
    echo "${dsas:-unknown}"
}

#Print "$1: value" when every node has the same value from function $2, else one line per node
show_node_setting() {
    local node values
    values=$(for ((node = 1; node <= NODE_COUNT; node++)); do echo "node-$node $($2 "$node")"; done)
    if [ "$(echo "$values" | cut -d' ' -f2- | sort -u | wc -l)" -eq 1 ]; then
        echo "$1: $(echo "$values" | head -n 1 | cut -d' ' -f2-)"
    else
        echo "$1 (differs between nodes):"
        echo "$values" | sed 's/^/  /'
    fi
}

#--status: state of each container of this network, and the nodes' chain view over JSON-RPC
show_status() {
    local node container state dir port block peers foreign=""
    echo "Network in $(pwd): $NODE_COUNT nodes"
    show_node_setting "Node key algorithm" node_dsa_of
    show_node_setting "Account signature algorithms" accounts_dsas_of
    echo ""
    printf '%-16s %-10s %-9s %-6s %s\n' CONTAINER STATE BLOCK PEERS URL
    for container in $(network_containers); do
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2> /dev/null)
        dir=$(container_dir "$container")
        block="-"; peers="-"
        case "$container" in
            node-*) node=${container#node-}; port=$((8544 + node)) ;;
            qbft-prometheus) port=$PROMETHEUS_PORT ;;
            qbft-grafana) port=$GRAFANA_PORT ;;
        esac
        if [ -z "$state" ]; then
            [[ "$container" == qbft-* ]] && ! grep -q '^  prometheus:$' docker-compose.generated.yaml &&
                continue #started without --monitoring
            state="absent"
        elif [ -n "$dir" ] && [ "$dir" != "$THIS_DIR" ]; then
            state="elsewhere"; foreign+="${foreign:+ }$container"
        elif [ "$state" == "running" ] && [[ "$container" == node-* ]]; then
            block=$(rpc_number "$port" eth_blockNumber)
            peers=$(rpc_number "$port" net_peerCount)
        fi
        printf '%-16s %-10s %-9s %-6s %s\n' "$container" "$state" "$block" "$peers" "http://localhost:$port"
    done
    if [ -n "$foreign" ]; then
        echo ""
        echo "\"elsewhere\": created by the network of another directory, which holds these names now:"
        foreign_containers | sed 's/^/  /'
    fi
}

IMAGE=""
NODE_DSA="SECP256K1"
TERMINALS=false
RESUME=false
ACTION=""
LOGS_SERVICE=""
MONITORING="" #true with --monitoring, false with --no-monitoring, else the default below
#Monitoring host ports: from the environment, else from the previous run's .env, else the defaults
env_file_value() { sed -n "s/^$1=//p" .env 2> /dev/null | tail -n 1; }
PROMETHEUS_PORT=${PROMETHEUS_PORT:-$(env_file_value PROMETHEUS_PORT)}
PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}
GRAFANA_PORT=${GRAFANA_PORT:-$(env_file_value GRAFANA_PORT)}
GRAFANA_PORT=${GRAFANA_PORT:-3000}
BESU_FULL_DASHBOARD_ID=16455 #https://grafana.com/grafana/dashboards/16455
BESU_FULL_DASHBOARD_REVISION=11
MAX_NODES=251 #node-N at 172.20.0.(N+1), below Prometheus (.253) and Grafana (.254)
ACCOUNTS_DSAS=""
ALL_ACCOUNTS_DSAS="SECP256K1,SECP256R1,FALCON512,MLDSA44,MLDSA65,MLDSA87,SECP256K1-MLDSA44,SECP256K1-FALCON512"
while [ $# -gt 0 ]; do
    case "$1" in
        --node-dsa=*) NODE_DSA="${1#*=}" ;;
        --node-dsa) NODE_DSA="$2"; shift ;;
        --terminals) TERMINALS=true ;;
        --resume) RESUME=true ;;
        --monitoring) MONITORING=true ;;
        --no-monitoring) MONITORING=false ;;
        --status) ACTION=status ;;
        --stop) ACTION=stop ;;
        --logs=*) ACTION=logs; LOGS_SERVICE="${1#*=}" ;;
        --logs)
            ACTION=logs
            if [ -n "$2" ] && [[ "$2" != -* ]]; then LOGS_SERVICE="$2"; shift; fi ;;
        --accounts-dsas=*|--accounts-supported-dsas=*) ACCOUNTS_DSAS="${1#*=}"; [ -z "$ACCOUNTS_DSAS" ] && ACCOUNTS_DSAS=" " ;;
        --accounts-dsas|--accounts-supported-dsas) ACCOUNTS_DSAS="${2:- }"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 1 ;;
        *) IMAGE="$1" ;;
    esac
    shift
done

#--status, --stop and --logs act on the network created in this directory
if [ -n "$ACTION" ]; then
    if [ ! -f docker-compose.generated.yaml ]; then
        echo "No network in $(pwd): run $0 besu-image-name first"
        exit 1
    fi
    NODE_COUNT=$(grep -c '^  node-[0-9]*:$' docker-compose.generated.yaml)
    case "$ACTION" in
        status) show_status ;;
        stop)
            if [ -n "$(foreign_containers)" ]; then
                echo "Not stopping: these containers belong to the network of another directory:"
                foreign_containers | sed 's/^/  /'
                echo "Run $0 --stop in that directory instead"
                exit 1
            fi
            docker compose -f docker-compose.generated.yaml down
            echo "Network stopped. The chain data is kept in node-*/data: $0 --resume starts it again"
            ;;
        logs)
            [ -n "$(foreign_containers)" ] &&
                echo "Warning: some containers belong to the network of another directory (see --status)"
            docker compose -f docker-compose.generated.yaml logs -f --tail 100 $LOGS_SERVICE
            ;;
    esac
    exit
fi

#A new network has no monitoring unless --monitoring is given
[ -z "$MONITORING" ] && [ "$RESUME" != "true" ] && MONITORING=false

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
    check_node_count "$NODE_COUNT"
    #Keep the monitoring of the network unless --monitoring or --no-monitoring changes it
    if [ -z "$MONITORING" ]; then
        if grep -q '^  prometheus:$' docker-compose.generated.yaml; then MONITORING=true; else MONITORING=false; fi
    fi
    [ "$MONITORING" == "true" ] && echo "With Prometheus and Grafana (--no-monitoring to start without them)"
    #The node directories are mounted in the containers, so the new value applies on this start
    set_accounts_dsas node-[0-9]*/config.toml
    grep -h "^accounts-supported-dsas=" node-[0-9]*/config.toml | sort | uniq -c
    #Both depend only on the node count and the monitoring choice
    write_compose_file
    [ "$MONITORING" == "true" ] && write_prometheus_config
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

    #Nodes Creation: one node per generated key (blockchain.nodes.count in qbftConfig.json)
    check_node_count "$(ls -d networkFiles/keys/* | wc -l)"
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
        #Set http, p2p and metrics port, p2p host and node DSA in node config.toml
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

    #Compose file of the nodes and their monitoring, and the Prometheus scrape config
    write_compose_file
    [ "$MONITORING" == "true" ] && write_prometheus_config

    remove_containers #To avoid errors, delete previous containers with the same name

    #Start QBFT Network
    start_network
fi
