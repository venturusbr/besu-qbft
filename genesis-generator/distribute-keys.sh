#!/bin/bash

i=1
for dir in ./networkFiles/keys/*
do
    cp ./networkFiles/genesis.json ../node-$i/
    cp $dir/* ../node-$i/data/
    i=$((i+1)) 
done