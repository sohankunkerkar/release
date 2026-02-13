#!/bin/bash
set -euo pipefail

echo "Running kueue workload smoke test on upgraded cluster..."

echo "Checking kueue operator health before running workload test..."
oc get pods -n openshift-kueue-operator
echo ""

echo "Waiting for kueue CRDs to be available..."
for i in $(seq 1 12); do
  if oc get crd clusterqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd localqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd resourceflavors.kueue.x-k8s.io &>/dev/null; then
    echo "Kueue CRDs are available."
    break
  fi
  echo "Waiting for kueue CRDs... ($i/12)"
  sleep 10
done

echo "Creating ResourceFlavor..."
oc apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
EOF

echo "Creating ClusterQueue..."
oc apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cluster-queue-upgrade-test
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: default-flavor
      resources:
      - name: "cpu"
        nominalQuota: 4
      - name: "memory"
        nominalQuota: 4Gi
EOF

echo "Creating namespace and LocalQueue..."
oc create namespace kueue-upgrade-test || true
oc apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: local-queue-upgrade-test
  namespace: kueue-upgrade-test
spec:
  clusterQueue: cluster-queue-upgrade-test
EOF

echo "Submitting a Job workload..."
oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kueue-smoke-test-job
  namespace: kueue-upgrade-test
  labels:
    kueue.x-k8s.io/queue-name: local-queue-upgrade-test
spec:
  parallelism: 1
  completions: 1
  template:
    spec:
      containers:
      - name: busybox
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["sh", "-c", "echo 'Kueue workload running successfully on upgraded cluster' && sleep 5"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
      restartPolicy: Never
  backoffLimit: 3
EOF

echo "Waiting for workload to be admitted by kueue..."
for i in $(seq 1 30); do
  ADMITTED=$(oc get workloads -n kueue-upgrade-test -o jsonpath='{.items[0].status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)
  if [ "$ADMITTED" = "True" ]; then
    echo "Workload admitted by kueue successfully!"
    break
  fi
  echo "Waiting for workload admission... ($i/30)"
  sleep 10
done

if [ "$ADMITTED" != "True" ]; then
  echo "ERROR: Workload was not admitted by kueue within timeout"
  echo ""
  echo "=== Workload status ==="
  oc get workloads -n kueue-upgrade-test -o yaml
  echo ""
  echo "=== ClusterQueue status ==="
  oc get clusterqueue cluster-queue-upgrade-test -o yaml 2>/dev/null || true
  echo ""
  echo "=== Kueue operator pods ==="
  oc get pods -n openshift-kueue-operator
  echo ""
  echo "=== Kueue operator logs (last 50 lines) ==="
  oc logs -n openshift-kueue-operator deployment/kueue-operator-controller-manager --tail=50 2>/dev/null || \
    oc logs -n openshift-kueue-operator -l app.kubernetes.io/name=kueue --tail=50 2>/dev/null || true
  exit 1
fi

echo "Waiting for Job to complete..."
oc wait --for=condition=complete job/kueue-smoke-test-job -n kueue-upgrade-test --timeout=300s || {
  echo "ERROR: Job did not complete within timeout"
  echo ""
  echo "=== Job status ==="
  oc get job kueue-smoke-test-job -n kueue-upgrade-test -o yaml
  echo ""
  echo "=== Pod status ==="
  oc get pods -n kueue-upgrade-test -o wide
  echo ""
  echo "=== Pod events ==="
  oc get events -n kueue-upgrade-test --sort-by='.lastTimestamp' 2>/dev/null | tail -20
  exit 1
}

echo "Verifying workload finished status..."
FINISHED=$(oc get workloads -n kueue-upgrade-test -o jsonpath='{.items[0].status.conditions[?(@.type=="Finished")].status}' 2>/dev/null || true)
if [ "$FINISHED" = "True" ]; then
  echo "Kueue workload completed and finished successfully on upgraded cluster!"
else
  echo "WARNING: Workload Finished condition not set, but job completed."
  oc get workloads -n kueue-upgrade-test -o yaml
fi

echo "Smoke test PASSED - kueue operator is working correctly after OCP upgrade"
