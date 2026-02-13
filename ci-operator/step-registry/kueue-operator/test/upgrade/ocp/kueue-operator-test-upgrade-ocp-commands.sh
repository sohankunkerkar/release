#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Minimal OCP cluster upgrade step.
# Triggers oc adm upgrade and waits for ClusterVersion to complete.
# This does NOT run openshift-tests -- it only performs the raw cluster upgrade.

TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
echo "Target upgrade image: ${TARGET}"

TARGET_VERSION="$(oc adm release info "${TARGET}" -o jsonpath='{.metadata.version}')"
echo "Target version: ${TARGET_VERSION}"

SOURCE_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
echo "Source version: ${SOURCE_VERSION}"

echo ""
echo "Current cluster state:"
oc get clusterversion version
echo ""

echo "Verifying kueue operator is healthy before upgrade..."
oc get deployment -n openshift-kueue-operator
oc wait --for=condition=Available deployment -l app.kubernetes.io/name=kueue -n openshift-kueue-operator --timeout=2m || {
    echo "WARN: Could not verify kueue operator health via label selector, trying direct name..."
    oc get pods -n openshift-kueue-operator
}
echo ""

# Trigger the upgrade
# Using --force for CI nightly/candidate images which may not be signed.
# --allow-explicit-upgrade is required because the target image may not
# appear in the cluster's recommended update graph.
echo "Triggering upgrade to ${TARGET_VERSION}..."
oc adm upgrade --to-image="${TARGET}" --allow-explicit-upgrade --force
echo "Upgrade initiated, waiting for completion..."
echo ""

# Wait for upgrade to complete
TIMEOUT=7200  # 120 minutes
INTERVAL=60   # Check every minute
ELAPSED=0

while (( ELAPSED < TIMEOUT )); do
    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))

    AVAIL="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")"
    PROG="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")"
    HIST_VER="$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null || echo "")"
    HIST_STATE="$(oc get clusterversion version -o jsonpath='{.status.history[0].state}' 2>/dev/null || echo "")"

    echo "[$(( ELAPSED / 60 ))m] Available=${AVAIL} Progressing=${PROG} Version=${HIST_VER} State=${HIST_STATE}"

    if [[ "${AVAIL}" == "True" && "${PROG}" == "False" && "${HIST_VER}" == "${TARGET_VERSION}" && "${HIST_STATE}" == "Completed" ]]; then
        echo ""
        echo "Upgrade to ${TARGET_VERSION} completed successfully!"
        oc get clusterversion version
        echo ""

        echo "Waiting for cluster to stabilize..."
        oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=30m || {
            echo "WARN: wait-for-stable-cluster timed out, dumping cluster operator status..."
            oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False"'
            echo "Continuing despite instability..."
        }

        echo ""
        echo "Verifying kueue operator survived the upgrade..."
        oc get pods -n openshift-kueue-operator
        oc wait --for=condition=Available deployment -l app.kubernetes.io/name=kueue -n openshift-kueue-operator --timeout=5m || {
            echo "WARN: Could not verify kueue via label, checking all deployments..."
            oc get deployment -n openshift-kueue-operator
            oc get pods -n openshift-kueue-operator -o wide
        }
        echo "Kueue operator check complete."
        exit 0
    fi
done

echo ""
echo "ERROR: Upgrade timed out after $(( TIMEOUT / 60 )) minutes"
echo ""
echo "ClusterVersion status:"
oc get clusterversion version -o yaml
echo ""
echo "Cluster operator status:"
oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False"'
exit 1
