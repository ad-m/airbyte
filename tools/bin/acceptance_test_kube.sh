#!/usr/bin/env bash

set -e

. tools/lib/lib.sh

assert_root

echo "Starting app..."

echo "Applying stable manifests to kubernetes..."
kubectl apply -k kube/overlays/stable-testing

kubectl wait --for=condition=Available deployment/airbyte-server --timeout=300s || (kubectl describe pods && exit 1)
kubectl wait --for=condition=Available deployment/airbyte-scheduler --timeout=300s || (kubectl describe pods && exit 1)

echo "Checking if scheduler and server are being scheduled on separate nodes..."
if [ -n "$IS_MINIKUBE" ]; then
  SCHEDULER_NODE=$(kubectl get pod -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName | grep scheduler | awk '{print $2}')
  SERVER_NODE=$(kubectl get pod -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName | grep server | awk '{print $2}')

  if [ "$SCHEDULER_NODE" = "$SERVER_NODE" ]; then
    echo "Scheduler and server were scheduled on the same node! This should not be the case for testing!"
    exit 1
  else
    echo "Scheduler and server were scheduled on different nodes."
  fi
fi

# allocates a lot of time to start kube. takes a while for postgres+temporal to work things out
sleep 120s

server_logs () { echo "server logs:" && kubectl logs deployment.apps/airbyte-server; }
scheduler_logs () { echo "scheduler logs:" && kubectl logs deployment.apps/airbyte-scheduler; }
pod_sweeper_logs () { echo "pod sweeper logs:" && kubectl logs deployment.apps/airbyte-pod-sweeper; }
describe_pods () { echo "describe pods:" && kubectl describe pods; }
print_all_logs () { server_logs; scheduler_logs; pod_sweeper_logs; describe_pods; }

trap "echo 'kube logs:' && print_all_logs" EXIT

kubectl port-forward svc/airbyte-server-svc 8001:8001 &

echo "Running worker integration tests..."
SUB_BUILD=PLATFORM ./gradlew :airbyte-workers:integrationTest --scan

echo "========"
echo "========"
echo "========"
echo "========"
echo "========"

kubectl describe pods | grep "Name\|Node"

echo "========"
echo "========"
echo "========"
echo "========"
echo "========"


echo "Running e2e tests via gradle..."
KUBE=true SUB_BUILD=PLATFORM USE_EXTERNAL_DEPLOYMENT=true ./gradlew :airbyte-tests:acceptanceTests --scan
