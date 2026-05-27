#!/bin/bash
# Script to create a private network using QBFT

if [ "$1" == "" ]; then
    echo ""
    echo "Usage: $0 besu-image-name [dsa-algorithm]"
    echo "Example: $0 hyperledger/besu"
    echo "DSA Algorithm (optional): SECP256K1-MLDSA44"
    echo "Example: $0 hyperledger/besu SECP256K1-MLDSA44"
    echo ""
else
    # Fixes User Permission Issues
    export MY_UID=$(id -u)
    export MY_GID=$(id -g)

    #Genesis Generation
    cd genesis-generator
    rm -rf networkFiles #Delete previous directory

    sed -i "s#image:.*#image: $1#" docker-compose.yaml #Set image name
    sed -i "s#command:.*#command: operator generate-blockchain-config --config-file=/usr/app/qbftConfig.json --to=/usr/app/networkFiles --private-key-file-name=key#" docker-compose.yaml

    docker rm -f node-1 node-2 node-3 node-4 genesis-generator > /dev/null 2>&1 #Delete previous containers with the same name
    docker compose up

    for FOLDER in "grafana" "prometheus"; do
        if [ -d "$FOLDER" ]; then
            echo "Copying $FOLDER to the root directory..."
            cp -r "$FOLDER" ../
        else
            echo "$FOLDER folder not found inside genesis-generator!"
        fi
    done

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
        #Set http and p2p port in node config.toml
        sed -e "s#rpc-http-port.*#rpc-http-port=$rpc_http_port#" \
            -e "s#p2p-port=.*#p2p-port=$p2p_port#" \
            -e "s#metrics-port=.*#metrics-port=$((9544 + count))#" config.toml > ../node-$count/config.toml
        #Set DSA algorithm name in node config.toml
        if [ "$2" != "" ]; then
            echo -e "\ndsa-algorithm=\"$2\"" >> ../node-$count/config.toml
        fi
        #Set the image name in the node docker-compose.yaml
        sed -e "s#image:.*#image: $1#" \
            -e "s#container_name:.*#container_name: node-$count#" \
            -e "s#PLACEHOLDER_RPC_PORT#$rpc_http_port:$rpc_http_port#" \
            -e "s#PLACEHOLDER_METRICS_PORT#$((9544 + count)):$((9544 + count))#" \
            node-docker-compose.yaml > ../node-$count/docker-compose.yaml

        ((count++))
        ((rpc_http_port++))
        ((p2p_port++))
    done

    #Get enode
    cd ../node-1/data
    enode=$(cut -c3- < key.pub)

    #Set bootnodes in nodes 2, 3 and 4. (localhost:127.0.0.1 - P2P Port node-1:30303)
    cd ../../
    for node in {2..4}; do
        echo -e "\n\nbootnodes=[\"enode://$enode@172.20.0.2:30303\"]" >> node-$node/config.toml
    done

    docker rm node-1 node-2 node-3 node-4 genesis-generator > /dev/null 2>&1 #To avoid errors, delete previous containers with the same name

    #Start QBFT Network
    docker compose up

    (cd ../prometheus && docker compose up -d)
    (cd ../grafana && docker compose up -d)
fi
