#!/usr/bin/env bash

set -e

TEST_TMP="$(rm -rf "$0.tmpdir" && mkdir -p "$0.tmpdir" && (cd "$0.tmpdir" && pwd))"
TEST_LOGS="$(mkdir -p "$0.logs" && (cd "$0.logs" && pwd))"
FABLO_HOME="$TEST_TMP/../.."

CONFIG="$FABLO_HOME/samples/fablo-config-hlf2-2orgs-2chaincodes-raft.yaml"

networkUp() {
  # separate generate and up is intentional
  "$FABLO_HOME/fablo-build.sh"
  (cd "$TEST_TMP" && "$FABLO_HOME/fablo.sh" generate "$CONFIG")
  (cd "$TEST_TMP" && "$FABLO_HOME/fablo.sh" up)
}

dumpLogs() {
  echo "Saving logs of $1 to $TEST_LOGS/$1.log"
  mkdir -p "$TEST_LOGS"
  docker logs "$1" >"$TEST_LOGS/$1.log" 2>&1
}

networkDown() {
  sleep 2
  rm -rf "$TEST_LOGS"
  (for name in $(docker ps --format '{{.Names}}'); do dumpLogs "$name"; done)
  (cd "$TEST_TMP" && "$FABLO_HOME/fablo.sh" down)
}

waitForContainer() {
  sh "$TEST_TMP/../wait-for-container.sh" "$1" "$2"
}

waitForChaincode() {
  sh "$TEST_TMP/../wait-for-chaincode-tls.sh" "$1" "$2" "$3" "$4" "$5"
}

expectInvoke() {
  sh "$TEST_TMP/../expect-invoke-rest.sh" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

trap networkDown EXIT
trap 'networkDown ; echo "Test failed" ; exit 1' ERR SIGINT

# start the network
networkUp

# check if root org is ready
waitForContainer "ca.root.com" "Listening on http://0.0.0.0:7054"
waitForContainer "orderer0.root.com" "Starting Raft node channel=my-channel1"
waitForContainer "orderer0.root.com" "Starting Raft node channel=my-channel2"
waitForContainer "orderer1.root.com" "Starting Raft node channel=my-channel1"
waitForContainer "orderer1.root.com" "Starting Raft node channel=my-channel2"
waitForContainer "orderer2.root.com" "Starting Raft node channel=my-channel1"
waitForContainer "orderer2.root.com" "Starting Raft node channel=my-channel2"

# check if org1 is ready
waitForContainer "ca.org1.com" "Listening on http://0.0.0.0:7054"
waitForContainer "peer0.org1.com" "Joining gossip network of channel my-channel1 with 2 organizations"
waitForContainer "peer0.org1.com" "Learning about the configured anchor peers of Org1MSP for channel my-channel1"
waitForContainer "peer0.org1.com" "Anchor peer for channel my-channel1 with same endpoint, skipping connecting to myself"
waitForContainer "peer0.org1.com" "Membership view has changed. peers went online:.*peer0.org2.com:7070"
waitForContainer "peer1.org1.com" "Joining gossip network of channel my-channel2 with 2 organizations"
waitForContainer "peer1.org1.com" "Learning about the configured anchor peers of Org1MSP for channel my-channel2"
waitForContainer "peer1.org1.com" "Membership view has changed. peers went online:.*peer1.org2.com:7071"

# check if org2 is ready
waitForContainer "ca.org2.com" "Listening on http://0.0.0.0:7054"
waitForContainer "peer0.org2.com" "Joining gossip network of channel my-channel1 with 2 organizations"
waitForContainer "peer0.org2.com" "Learning about the configured anchor peers of Org2MSP for channel my-channel1"
waitForContainer "peer0.org2.com" "Anchor peer for channel my-channel1 with same endpoint, skipping connecting to myself"
waitForContainer "peer0.org2.com" "Membership view has changed. peers went online:.*peer0.org1.com:7060"
waitForContainer "peer1.org2.com" "Joining gossip network of channel my-channel2 with 2 organizations"
waitForContainer "peer1.org2.com" "Learning about the configured anchor peers of Org2MSP for channel my-channel2"
waitForContainer "peer1.org2.com" "Anchor peer for channel my-channel2 with same endpoint, skipping connecting to myself"
waitForContainer "peer1.org2.com" "Membership view has changed. peers went online:.*peer1.org1.com:7061"

# check if chaincodes are instantiated on peers
waitForChaincode "cli.org1.com" "peer0.org1.com:7060" "my-channel1" "chaincode1" "0.0.1"
waitForChaincode "cli.org2.com" "peer0.org2.com:7070" "my-channel1" "chaincode1" "0.0.1"
waitForChaincode "cli.org1.com" "peer1.org1.com:7061" "my-channel2" "chaincode2" "0.0.1"
waitForChaincode "cli.org2.com" "peer1.org2.com:7071" "my-channel2" "chaincode2" "0.0.1"

# invoke Node chaincode
fablo_rest_org1="localhost:8800"
fablo_rest_org2="localhost:8801"
expectInvoke "$fablo_rest_org1" "my-channel1" "chaincode1" \
  "KVContract:put" '["name", "Jack Sparrow"]' \
  '{\"success\":\"OK\"}'
expectInvoke "$fablo_rest_org2" "my-channel1" "chaincode1" \
  "KVContract:get" '["name"]' \
  '{\"success\":\"Jack Sparrow\"}'

# invoke Java chaincode
expectInvoke "$fablo_rest_org1" "my-channel2" "chaincode2" \
  "PokeballContract:createPokeball" '["id1", "Pokeball 1"]' \
  'status:200'
expectInvoke "$fablo_rest_org2" "my-channel2" "chaincode2" \
  "PokeballContract:readPokeball" '["id1"]' \
  '{"value":"Pokeball 1"}'

# restart the network and wait for chaincodes
(cd "$TEST_TMP" && "$FABLO_HOME/fablo.sh" stop && "$FABLO_HOME/fablo.sh" start)
waitForChaincode "cli.org1.com" "peer0.org1.com:7060" "my-channel1" "chaincode1" "0.0.1"
waitForChaincode "cli.org2.com" "peer0.org2.com:7070" "my-channel1" "chaincode1" "0.0.1"

# upgrade chaincode
(cd "$TEST_TMP" && "$FABLO_HOME/fablo.sh" chaincode upgrade "chaincode1" "0.0.2")
waitForChaincode "cli.org1.com" "peer0.org1.com:7060" "my-channel1" "chaincode1" "0.0.2"
waitForChaincode "cli.org2.com" "peer0.org2.com:7070" "my-channel1" "chaincode1" "0.0.2"

# check if state is kept after update
expectInvoke "$fablo_rest_org2" "my-channel1" "chaincode1" \
  "KVContract:get" '["name"]' \
  '{\"success\":\"Jack Sparrow\"}'
