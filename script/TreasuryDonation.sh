#!/bin/bash

set -e

# === CONFIGURATION ===
CARDANO_CLI="cardano-cli"
NETWORK="--mainnet"  # For testnet use: --testnet-magic 1097911063
SOCKET_PATH="$CNODE_HOME/sockets/node.socket"
WORK_DIR="./donation"
KEY_NAME="treasury_donor"
FEE_BUFFER=300000     # Transaction fee buffer (in Lovelace)
MIN_UTXO=1500000      # Minimum required change (in Lovelace)

# === FUNCTIONS ===
get_treasury_balance() {
  $CARDANO_CLI conway query treasury \
    $NETWORK \
    --socket-path "$SOCKET_PATH" | grep -o '[0-9]\+' || echo "0"
}

# === SETUP ===
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 🔑 Generate key pair and address if not already present
if [ ! -f "${KEY_NAME}.vkey" ]; then
  echo "🔑 Generating new keys..."
  $CARDANO_CLI address key-gen \
    --verification-key-file "${KEY_NAME}.vkey" \
    --signing-key-file "${KEY_NAME}.skey"
fi

if [ ! -f "${KEY_NAME}.addr" ]; then
  echo "🏠 Generating new address..."
  $CARDANO_CLI address build \
    --payment-verification-key-file "${KEY_NAME}.vkey" \
    $NETWORK \
    --out-file "${KEY_NAME}.addr"
fi

ADDRESS=$(cat "${KEY_NAME}.addr")
echo ""
echo "💳 Please send ADA to the following address:"
echo "--------------------------------------------"
echo "$ADDRESS"
echo "--------------------------------------------"
echo ""

# 📊 Check treasury balance before donation
echo "📊 Checking treasury balance before donation..."
TREASURY_BEFORE=$(get_treasury_balance)
echo "  Treasury balance before: $((TREASURY_BEFORE / 1000000)) ADA"
echo ""

# 💰 Wait for funds to arrive at the generated address
echo "⏳ Waiting for deposit..."
while true; do
  $CARDANO_CLI query utxo \
    --address "$ADDRESS" \
    $NETWORK \
    --socket-path "$SOCKET_PATH" > full_utxo.txt

  TX_IN_LINE=$(tail -n +3 full_utxo.txt | sort -k3 -nr | head -n 1)
  TX_HASH=$(echo "$TX_IN_LINE" | awk '{print $1}')
  TX_IX=$(echo "$TX_IN_LINE" | awk '{print $2}')
  BALANCE=$(echo "$TX_IN_LINE" | awk '{print $3}')

  if [ -n "$TX_HASH" ] && [ "$BALANCE" -gt 0 ]; then
    echo "✅ Received: $((BALANCE / 1000000)) ADA"
    break
  fi

  echo "⏳ Waiting... (checking again in 15s)"
  sleep 15
done

TX_IN="${TX_HASH}#${TX_IX}"

# 💸 Ask user how much to donate (in ADA)
echo ""
read -p "💰 How many ADA would you like to donate? (e.g., 10): " DONATION_ADA
DONATION_LOVELACE=$(echo "$DONATION_ADA * 1000000" | bc | awk '{print int($1)}')

# 🔄 Calculate and verify if change is above minimum threshold
CHANGE=$(($BALANCE - $DONATION_LOVELACE - $FEE_BUFFER))
if [ "$CHANGE" -lt "$MIN_UTXO" ]; then
  echo "❌ Not enough balance after fee and donation."
  echo "  Balance: $BALANCE"
  echo "  Donation: $DONATION_LOVELACE"
  echo "  Change after fee: $CHANGE"
  exit 1
fi

# 🧱 Build transaction with donation to treasury
echo "🧱 Building transaction..."
$CARDANO_CLI latest transaction build \
  --treasury-donation "$DONATION_LOVELACE" \
  --tx-in "$TX_IN" \
  --change-address "$ADDRESS" \
  --out-file tx.body \
  $NETWORK \
  --socket-path "$SOCKET_PATH"

# ✍️ Sign the transaction
echo "✍️ Signing transaction..."
$CARDANO_CLI latest transaction sign \
  --tx-body-file tx.body \
  --signing-key-file "${KEY_NAME}.skey" \
  $NETWORK \
  --out-file tx.signed

# 🚀 Submit the signed transaction
echo "🚀 Submitting transaction..."
$CARDANO_CLI latest transaction submit \
  --tx-file tx.signed \
  $NETWORK \
  --socket-path "$SOCKET_PATH"

# 🎉 Final message with Cardanoscan link
echo ""
echo "🎉 Donation of $DONATION_ADA ADA successfully submitted!"
echo ""
echo "🔍 Please check the donation field of your transaction on Cardanoscan:"
echo "https://cardanoscan.io/transaction/${TX_HASH}?tab=utxo"
