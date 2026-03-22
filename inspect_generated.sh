#!/usr/bin/env bash
# Inspects a generate_classes.sh output directory and recovers the original parameters.
#
# Usage: ./inspect_generated.sh <output_dir>

set -euo pipefail

OUTPUT_DIR="${1:?Usage: $0 <output_dir>}"
JARS="$OUTPUT_DIR/jars"

if [[ ! -d "$JARS" ]]; then
    echo "Error: $JARS not found — is this a generate_classes.sh output directory?" >&2
    exit 1
fi

# Count package jars (exclude base.jar and root.jar)
PKG_JARS=( "$JARS"/pkg*.jar )
PKG_COUNT=${#PKG_JARS[@]}

if [[ $PKG_COUNT -eq 0 ]]; then
    echo "Error: no pkg*.jar files found in $JARS" >&2
    exit 1
fi

# L1 and L2 counts from the first (full) package
L1_PER_PKG=$(jar tf "${PKG_JARS[0]}" 2>/dev/null | grep -c "Layer1Class" || true)
L2_IN_PKG0=$(jar tf "${PKG_JARS[0]}" 2>/dev/null | grep -c "Layer2Class" || true)

# L2 per L1 = Layer2 classes in pkg0 / L1 classes in pkg0
if [[ $L1_PER_PKG -gt 0 ]]; then
    L2_PER_L1=$(( L2_IN_PKG0 / L1_PER_PKG ))
else
    L2_PER_L1=0
fi

# Total L1 = sum Layer1 classes across all pkg jars
TOTAL_L1=0
for jar in "${PKG_JARS[@]}"; do
    count=$(jar tf "$jar" 2>/dev/null | grep -c "Layer1Class" || true)
    TOTAL_L1=$(( TOTAL_L1 + count ))
done

TOTAL_L2=$(( TOTAL_L1 * L2_PER_L1 ))
TOTAL=$(( 1 + TOTAL_L1 + TOTAL_L2 + 4 ))

echo "=== Recovered parameters for: $OUTPUT_DIR ==="
echo ""
echo "  ./generate_classes.sh $OUTPUT_DIR $TOTAL_L1 $L2_PER_L1 $L1_PER_PKG"
echo ""
echo "=== Derived values ==="
echo "  pkg_count   = $PKG_COUNT"
echo "  total_l1    = $TOTAL_L1"
echo "  l2_per_l1   = $L2_PER_L1"
echo "  l1_per_pkg  = $L1_PER_PKG"
echo "  total_l2    = $TOTAL_L2"
echo "  total_class = $TOTAL"
