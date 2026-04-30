#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_trimconcat.sh — Trim & Concat Pipeline (v36+)
#
# Submeniu:
#   1) Trim clip              — tăiere un fișier (stream copy / re-encode)
#   2) Concat clips           — unire mai multe fișiere (compat check)
#   3) Trim + Concat + Encode — pipeline complet (trim → concat → encode)
#   4) Batch trim             — aceleași cuturi pe N fișiere (v37)
#   5) Înapoi
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"

# v36: Curatenie temp rezidual la intrare (foldere vechi din sesiuni anterioare)
tc_scan_leftover_temp

# ── Submeniu principal ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  TRIM & CONCAT                       ║"
echo "╠══════════════════════════════════════╣"
echo "║  1) Trim clip (un fisier)            ║"
echo "║  2) Concat clips (unire)             ║"
echo "║  3) Trim + Concat + Encode           ║"
echo "║  4) Batch trim (N fisiere, cuts comune)"
echo "║  5) Inapoi                           ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-5: " tc_choice

case "$tc_choice" in
    1) trimconcat_flow_trim ;;
    2) trimconcat_flow_concat ;;
    3) trimconcat_flow_pipeline ;;
    4) trimconcat_flow_batch_trim ;;
    5) echo "Inapoi."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
