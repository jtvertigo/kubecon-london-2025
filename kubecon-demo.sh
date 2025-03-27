
echo "##### Deploy KinD Cluster(s) #####"

export CLUSTER1=cluster1
bash ./scripts/deploy-cluster1.sh
bash ./scripts/check.sh cluster1

echo "##### Taint node #####"

kubectl --context ${CLUSTER1} taint node kind1-worker k6=only:NoSchedule

echo "##### installtooling for perftest #####"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack \
prometheus-community/kube-prometheus-stack \
--version 62.6.0 \
--kube-context ${CLUSTER1} \
--namespace monitoring \
--create-namespace \
--values - <<EOF
prometheus:
  service:
    type: LoadBalancer
  kubelet:
    serviceMonitor:
      cAdvisor: false
  kubeApiServer:
    enabled: false
  prometheusSpec:
    enableFeatures:
      - native-histograms
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    enableRemoteWriteReceiver: true
grafana:
  enabled: false
EOF

curl https://raw.githubusercontent.com/grafana/k6-operator/v0.0.19/bundle.yaml | kubectl --context ${CLUSTER1} apply -f -
kubectl --context ${CLUSTER1} create ns k6
kubectl --context ${CLUSTER1} label namespace k6 istio.io/dataplane-mode=ambient
kubectl --context ${CLUSTER1} label namespace k6 istio-injection=disabled
helm upgrade --install grafana grafana/grafana  \
--kube-context ${CLUSTER1} \
--create-namespace \
--namespace monitoring \
--version 8.5.1 \
--values - <<EOF
adminPassword: prom-operator
service:
  port: 3000
  type: LoadBalancer
sidecar:
  dashboards:
    enabled: true
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: prometheus
      type: prometheus
      url: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
      isDefault: true
EOF

kubectl -n monitoring create cm k6-dashboard \
--from-file=k6-custom-dashboard.json=k6-native-histograms.json -o yaml --dry-run=client | kubectl --context ${CLUSTER1} apply -f -
kubectl --context ${CLUSTER1} label -n monitoring cm k6-dashboard grafana_dashboard=1

echo "##### Deploy Istio using Helm #####"

curl -L https://istio.io/downloadIstio | sh -
if [ -d "istio-"*/ ]; then
  cd istio-*/
  export PATH=$PWD/bin:$PATH
  cd ..
fi

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm install istio-base istio/base --kube-context=${CLUSTER1} -n istio-system --create-namespace --wait

kubectl --context=${CLUSTER1} apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

helm install istiod istio/istiod --kube-context=${CLUSTER1} -n istio-system --set profile=ambient --wait

helm install istio-cni istio/cni --kube-context=${CLUSTER1} -n istio-system --set profile=ambient --wait

helm install ztunnel istio/ztunnel --kube-context=${CLUSTER1} -n istio-system --wait

echo "##### Installing metrics server #####"

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm --kube-context ${CLUSTER1} -n kube-system upgrade --install metrics-server metrics-server/metrics-server --set args="{--kubelet-insecure-tls=true}" 

echo "##### Installing Kiali #####"

helm repo add kiali https://kiali.org/helm-charts
helm repo update
helm --kube-context ${CLUSTER1} upgrade --install \
  --set cr.create=true \
  --set cr.namespace=istio-system \
  --set cr.spec.auth.strategy="anonymous" \
  --namespace kiali-operator \
  --create-namespace \
  kiali-operator \
  kiali/kiali-operator \
  -f - <<EOF
cr:
  spec:
    deployment:
      service_type: LoadBalancer
    external_services:
      prometheus:
        url: 'http://kube-prometheus-stack-prometheus.monitoring:9090/'
EOF

kubectl --context ${CLUSTER1} apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/addons/extras/prometheus-operator.yaml

echo "##### Deploy the httpbin demo app #####"

kubectl --context ${CLUSTER1} create ns httpbin
kubectl --context ${CLUSTER1} label namespace httpbin istio.io/dataplane-mode=ambient
kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: not-in-mesh
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: not-in-mesh
  namespace: httpbin
  labels:
    app: not-in-mesh
    service: not-in-mesh
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: not-in-mesh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: not-in-mesh
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: not-in-mesh
      version: v1
  template:
    metadata:
      labels:
        app: not-in-mesh
        version: v1
        istio.io/dataplane-mode: none
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: not-in-mesh
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: not-in-mesh
        ports:
        - name: http
          containerPort: 80
        livenessProbe:
          httpGet:
            path: /status/200
            port: http
        readinessProbe:
          httpGet:
            path: /status/200
            port: http
EOF

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: in-mesh
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: in-mesh
  namespace: httpbin
  labels:
    app: in-mesh
    service: in-mesh
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: in-mesh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: in-mesh
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: in-mesh
      version: v1
  template:
    metadata:
      labels:
        app: in-mesh
        version: v1
        sidecar.istio.io/inject: "true"
    spec:
      serviceAccountName: in-mesh
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: in-mesh
        ports:
        - name: http
          containerPort: 80
        livenessProbe:
          httpGet:
            path: /status/200
            port: http
        readinessProbe:
          httpGet:
            path: /status/200
            port: http
EOF

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: in-ambient
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: in-ambient
  namespace: httpbin
  labels:
    app: in-ambient
    service: in-ambient
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: in-ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: in-ambient
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: in-ambient
      version: v1
  template:
    metadata:
      labels:
        app: in-ambient
        version: v1
        istio.io/dataplane-mode: ambient
        sidecar.istio.io/inject: "false"
        istio-injection: disabled
    spec:
      serviceAccountName: in-ambient
      containers:
      - image: docker.io/kennethreitz/httpbin
        imagePullPolicy: IfNotPresent
        name: in-ambient
        ports:
        - name: http
          containerPort: 80
        livenessProbe:
          httpGet:
            path: /status/200
            port: http
        readinessProbe:
          httpGet:
            path: /status/200
            port: http
EOF


echo "##### Deploy the clients to make requests to other services #####"

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client-not-in-mesh
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: client-not-in-mesh
  namespace: httpbin
  labels:
    app: client-not-in-mesh
    service: client-not-in-mesh
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: client-not-in-mesh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-not-in-mesh
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client-not-in-mesh
      version: v1
  template:
    metadata:
      labels:
        app: client-not-in-mesh
        version: v1
        istio.io/dataplane-mode: none
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: client-not-in-mesh
      containers:
      - image: nicolaka/netshoot:latest
        imagePullPolicy: IfNotPresent
        name: netshoot
        command: ["/bin/bash"]
        args: ["-c", "while true; do ping localhost; sleep 60;done"]
EOF

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client-in-mesh
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: client-in-mesh
  namespace: httpbin
  labels:
    app: client-in-mesh
    service: client-in-mesh
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: client-in-mesh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-in-mesh
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client-in-mesh
      version: v1
  template:
    metadata:
      labels:
        app: client-in-mesh
        version: v1
        sidecar.istio.io/inject: "true"
    spec:
      serviceAccountName: client-in-mesh
      containers:
      - image: nicolaka/netshoot:latest
        imagePullPolicy: IfNotPresent
        name: netshoot
        command: ["/bin/bash"]
        args: ["-c", "while true; do ping localhost; sleep 60;done"]
EOF

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client-in-ambient
  namespace: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: client-in-ambient
  namespace: httpbin
  labels:
    app: client-in-ambient
    service: client-in-ambient
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: client-in-ambient
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-in-ambient
  namespace: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client-in-ambient
      version: v1
  template:
    metadata:
      labels:
        app: client-in-ambient
        version: v1
        istio.io/dataplane-mode: ambient
        sidecar.istio.io/inject: "false"
        istio-injection: disabled
    spec:
      serviceAccountName: client-in-ambient
      containers:
      - image: nicolaka/netshoot:latest
        imagePullPolicy: IfNotPresent
        name: netshoot
        command: ["/bin/bash"]
        args: ["-c", "while true; do ping localhost; sleep 60;done"]
EOF

echo "##### Disable Istio #####"

kubectl --context ${CLUSTER1} label ns k6 istio-injection-
kubectl --context ${CLUSTER1} label ns k6 istio.io/dataplane-mode-

echo "##### Update backend services #####"

kubectl --context ${CLUSTER1} set image deployment/not-in-mesh not-in-mesh=fortio/fortio -n httpbin
kubectl --context ${CLUSTER1} set image deployment/in-mesh in-mesh=fortio/fortio -n httpbin
kubectl --context ${CLUSTER1} set image deployment/in-ambient in-ambient=fortio/fortio -n httpbin
kubectl --context ${CLUSTER1} scale --replicas=4 deployment/not-in-mesh -n httpbin
kubectl --context ${CLUSTER1} scale --replicas=4 deployment/in-mesh -n httpbin
kubectl --context ${CLUSTER1} scale --replicas=4 deployment/in-ambient -n httpbin
kubectl --context ${CLUSTER1} patch service not-in-mesh -n httpbin -p '{"spec": {"ports": [{"port": 8000, "targetPort": 8080}]}}'
kubectl --context ${CLUSTER1} patch service in-mesh -n httpbin -p '{"spec": {"ports": [{"port": 8000, "targetPort": 8080}]}}'
kubectl --context ${CLUSTER1} patch service in-ambient -n httpbin -p '{"spec": {"ports": [{"port": 8000, "targetPort": 8080}]}}'
kubectl --context ${CLUSTER1} patch deployment not-in-mesh -n httpbin --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/ports/0"}]'
kubectl --context ${CLUSTER1} patch deployment not-in-mesh -n httpbin -p '{"spec": {"template": {"spec": {"containers": [{"name": "not-in-mesh", "ports": [{"name": "http", "containerPort": 8080}]}]}}}}'
kubectl --context ${CLUSTER1} patch deployment in-mesh -n httpbin --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/ports/0"}]'
kubectl --context ${CLUSTER1} patch deployment in-mesh -n httpbin -p '{"spec": {"template": {"spec": {"containers": [{"name": "in-mesh", "ports": [{"name": "http", "containerPort": 8080}]}]}}}}'
kubectl --context ${CLUSTER1} patch deployment in-ambient -n httpbin --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/ports/0"}]'
kubectl --context ${CLUSTER1} patch deployment in-ambient -n httpbin -p '{"spec": {"template": {"spec": {"containers": [{"name": "in-ambient", "ports": [{"name": "http", "containerPort": 8080}]}]}}}}'
echo "##### Waiting for all deployments to be ready #####"

# Define namespaces containing critical components
NAMESPACES_TO_CHECK="kube-system monitoring k6-operator-system istio-system kiali-operator httpbin"
TIMEOUT="10m" # Adjust timeout as needed (e.g., 600s)

for ns in $NAMESPACES_TO_CHECK; do
  echo "--> Waiting for Deployments in namespace '$ns' to be Available..."
  # Get deployment names first, as 'wait --all' might include deployments being terminated
  DEPLOYMENTS=$(kubectl --context ${CLUSTER1} get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}')
  if [ -n "$DEPLOYMENTS" ]; then
      # Wait for each deployment individually
      for deploy in $DEPLOYMENTS; do
          echo "  --> Waiting for Deployment '$deploy'..."
          if ! kubectl --context ${CLUSTER1} wait deployment "$deploy" --for=condition=Available=true -n "$ns" --timeout=${TIMEOUT}; then
              echo "Error: Deployment '$deploy' in namespace '$ns' did not become Available within ${TIMEOUT}."
              kubectl --context ${CLUSTER1} get pods -n "$ns" # Show pod status on failure
              kubectl --context ${CLUSTER1} describe deployment "$deploy" -n "$ns" # Describe deployment on failure
              exit 1 # Exit the script if deployment isn't ready
          fi
      done
  else
      echo "  --> No deployments found in namespace '$ns'."
  fi
done

echo "All relevant Deployments are Available."

echo "##### Execute baseline perftest #####"

cat <<'EOF' | kubectl create configmap -n k6 k6-test --from-file=k6-test.js=/dev/stdin -o yaml --dry-run=client | kubectl --context ${CLUSTER1} apply -f -
import http from 'k6/http';
import { sleep, check } from 'k6';
export let options = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  scenarios: {
    "1": {
      executor: 'constant-arrival-rate',
      duration: '2m',
      startTime: '0s',
      rate: 1000,
      timeUnit: '1s',
      preAllocatedVUs: 10,
      maxVUs: 50
    }
  },
};
export default function () {
  const url = "http://not-in-mesh.httpbin.svc.cluster.local:8000/get";
  const res = http.get(url);
  check(res, {
    'is status 2xx': (r) => parseInt(r.status / 100) === 2,
    'is status 4xx': (r) => parseInt(r.status / 100) === 4,
    'is status 5xx': (r) => parseInt(r.status / 100) === 5,
    'is status else': (r) => parseInt(r.status / 100) !== 2 && parseInt(r.status / 100) !== 4 && parseInt(r.status / 100) !== 5,
  });
}
EOF

cat <<'EOF' | kubectl --context ${CLUSTER1} apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-runner-1
  namespace: k6
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test
      file: k6-test.js
  separate: false
  arguments: -o experimental-prometheus-rw
  initializer: {}
  runner:
    image: grafana/k6
    env:
    - name: K6_PROMETHEUS_RW_SERVER_URL
      value: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
      value: "true"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      sysctls:
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
    tolerations:
    - key: k6
      operator: Exists
      effect: NoSchedule
    resources:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

export GRAFANA_TIMEINIT=$(date +"%s")000
sleep 60

until [ "$(kubectl --context ${CLUSTER1} get pods -n k6 --field-selector=status.phase=Running --no-headers | wc -l)" -eq "0" ]; do
  echo "Waiting for all pods to finish running..."
  sleep 5
done
echo "##### Annotating Grafana #####"
export GRAFANA_TIMEEND=$(date +"%s")000
kubectl --context=$CLUSTER1 -n monitoring port-forward svc/grafana 3000 &
PORT_FORWARD_PID=$!
sleep 5
curl -u "admin:prom-operator" \
     -H "Accept: application/json" \
     -H "Content-Type: application/json" \
     localhost:3000/api/annotations \
     -d "{\"time\":${GRAFANA_TIMEINIT},\"timeEnd\":${GRAFANA_TIMEEND},\"tags\":[\"perf\",\"baseline\"],\"text\":\"Baseline\"}"
kill $PORT_FORWARD_PID
echo ""
echo "##### Done annotating Grafana #####"

echo "##### Execute sidecar perftest #####"

cat <<'EOF' | kubectl create configmap -n k6 k6-test --from-file=k6-test.js=/dev/stdin -o yaml --dry-run=client | kubectl --context ${CLUSTER1} apply -f -
import http from 'k6/http';
import { sleep, check } from 'k6';
export let options = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  scenarios: {
    "1": {
      executor: 'constant-arrival-rate',
      duration: '2m',
      startTime: '0s',
      rate: 1000,
      timeUnit: '1s',
      preAllocatedVUs: 10,
      maxVUs: 50
    }
  },
};
export default function () {
  const url = "http://in-mesh.httpbin.svc.cluster.local:8000/get";
  const res = http.get(url);
  check(res, {
    'is status 2xx': (r) => parseInt(r.status / 100) === 2,
    'is status 4xx': (r) => parseInt(r.status / 100) === 4,
    'is status 5xx': (r) => parseInt(r.status / 100) === 5,
    'is status else': (r) => parseInt(r.status / 100) !== 2 && parseInt(r.status / 100) !== 4 && parseInt(r.status / 100) !== 5,
  });
}

export function teardown(data) {
  http.post("http://localhost:15020/quitquitquit");
}
EOF

kubectl --context ${CLUSTER1} delete testrun -A --all   

cat <<'EOF' | kubectl --context ${CLUSTER1} apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-runner-2
  namespace: k6
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test
      file: k6-test.js
  separate: false
  arguments: -o experimental-prometheus-rw
  initializer: {}
  runner:
    image: grafana/k6
    metadata:
      labels:
        sidecar.istio.io/inject: "true"
    env:
    - name: K6_PROMETHEUS_RW_SERVER_URL
      value: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
      value: "true"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      sysctls:
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
    tolerations:
    - key: k6
      operator: Exists
      effect: NoSchedule
    resources:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

export GRAFANA_TIMEINIT=$(date +"%s")000
sleep 60

until [ "$(kubectl --context ${CLUSTER1} get pods -n k6 --field-selector=status.phase=Running --no-headers | wc -l)" -eq "0" ]; do
  echo "Waiting for all pods to finish running..."
  sleep 5
done
echo "##### Annotating Grafana #####"
export GRAFANA_TIMEEND=$(date +"%s")000
kubectl --context=$CLUSTER1 -n monitoring port-forward svc/grafana 3000 &
PORT_FORWARD_PID=$!
sleep 5
curl -u "admin:prom-operator" \
     -H "Accept: application/json" \
     -H "Content-Type: application/json" \
     localhost:3000/api/annotations \
     -d "{\"time\":${GRAFANA_TIMEINIT},\"timeEnd\":${GRAFANA_TIMEEND},\"tags\":[\"perf\",\"sidecars\"],\"text\":\"Sidecars\"}"
kill $PORT_FORWARD_PID
echo ""
echo "##### Done annotating Grafana #####"

echo "##### Sidecar L7 policy #####"

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: in-mesh
  namespace: httpbin
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: in-mesh
    port: 8000
  rules:
    - backendRefs:
        - name: in-mesh
          port: 8000
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: x-istio-workload
                value: "%ENVIRONMENT(HOSTNAME)%"
EOF

echo "##### Execute sidecar L7 perftest #####"

kubectl --context ${CLUSTER1} delete testrun -A --all   

cat <<'EOF' | kubectl --context ${CLUSTER1} apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-runner-3
  namespace: k6
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test
      file: k6-test.js
  separate: false
  arguments: -o experimental-prometheus-rw
  initializer: {}
  runner:
    image: grafana/k6
    metadata:
      labels:
        sidecar.istio.io/inject: "true"
    env:
    - name: K6_PROMETHEUS_RW_SERVER_URL
      value: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
      value: "true"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      sysctls:
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
    tolerations:
    - key: k6
      operator: Exists
      effect: NoSchedule
    resources:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

export GRAFANA_TIMEINIT=$(date +"%s")000
sleep 60

until [ "$(kubectl --context ${CLUSTER1} get pods -n k6 --field-selector=status.phase=Running --no-headers | wc -l)" -eq "0" ]; do
  echo "Waiting for all pods to finish running..."
  sleep 5
done
echo "##### Annotating Grafana #####"
export GRAFANA_TIMEEND=$(date +"%s")000
kubectl --context=$CLUSTER1 -n monitoring port-forward svc/grafana 3000 &
PORT_FORWARD_PID=$!
sleep 5
curl -u "admin:prom-operator" \
     -H "Accept: application/json" \
     -H "Content-Type: application/json" \
     localhost:3000/api/annotations \
     -d "{\"time\":${GRAFANA_TIMEINIT},\"timeEnd\":${GRAFANA_TIMEEND},\"tags\":[\"perf\",\"sidecars\"],\"text\":\"Sidecars with L7 policy\"}"
kill $PORT_FORWARD_PID
echo ""
echo "##### Done annotating Grafana #####"

echo "##### Ambient configuration #####"

kubectl --context ${CLUSTER1} -n httpbin delete httproute in-mesh
kubectl --context ${CLUSTER1} label ns k6 istio-injection=disabled --overwrite
kubectl --context ${CLUSTER1} label ns k6 istio.io/dataplane-mode=ambient

echo "##### Execute ambient perftest #####"

cat <<'EOF' | kubectl create configmap -n k6 k6-test --from-file=k6-test.js=/dev/stdin -o yaml --dry-run=client | kubectl --context ${CLUSTER1} apply -f -
import http from 'k6/http';
import { sleep, check } from 'k6';
export let options = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  scenarios: {
    "1": {
      executor: 'constant-arrival-rate',
      duration: '2m',
      startTime: '0s',
      rate: 1000,
      timeUnit: '1s',
      preAllocatedVUs: 10,
      maxVUs: 50
    }
  },
};
export default function () {
  const url = "http://in-ambient.httpbin.svc.cluster.local:8000/get";
  const res = http.get(url);
  check(res, {
    'is status 2xx': (r) => parseInt(r.status / 100) === 2,
    'is status 4xx': (r) => parseInt(r.status / 100) === 4,
    'is status 5xx': (r) => parseInt(r.status / 100) === 5,
    'is status else': (r) => parseInt(r.status / 100) !== 2 && parseInt(r.status / 100) !== 4 && parseInt(r.status / 100) !== 5,
  });
}
EOF

kubectl --context ${CLUSTER1} delete testrun -A --all   

cat <<'EOF' | kubectl --context ${CLUSTER1} apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-runner-4
  namespace: k6
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test
      file: k6-test.js
  separate: false
  arguments: -o experimental-prometheus-rw
  initializer: {}
  runner:
    image: grafana/k6
    env:
    - name: K6_PROMETHEUS_RW_SERVER_URL
      value: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
      value: "true"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      sysctls:
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
    tolerations:
    - key: k6
      operator: Exists
      effect: NoSchedule
    resources:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

export GRAFANA_TIMEINIT=$(date +"%s")000
sleep 60

until [ "$(kubectl --context ${CLUSTER1} get pods -n k6 --field-selector=status.phase=Running --no-headers | wc -l)" -eq "0" ]; do
  echo "Waiting for all pods to finish running..."
  sleep 5
done
echo "##### Annotating Grafana #####"
export GRAFANA_TIMEEND=$(date +"%s")000
kubectl --context=$CLUSTER1 -n monitoring port-forward svc/grafana 3000 &
PORT_FORWARD_PID=$!
sleep 5
curl -u "admin:prom-operator" \
     -H "Accept: application/json" \
     -H "Content-Type: application/json" \
     localhost:3000/api/annotations \
     -d "{\"time\":${GRAFANA_TIMEINIT},\"timeEnd\":${GRAFANA_TIMEEND},\"tags\":[\"perf\",\"ambient\"],\"text\":\"Ambient\"}"
kill $PORT_FORWARD_PID
echo ""
echo "##### Done annotating Grafana #####"

echo "##### Ambient with waypoint #####"

kubectl --context ${CLUSTER1} apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/waypoint-for: service
  name: waypoint
  namespace: httpbin
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF

kubectl --context ${CLUSTER1} -n httpbin scale deploy waypoint --replicas=2
kubectl --context ${CLUSTER1} -n httpbin rollout status deploy waypoint
kubectl --context ${CLUSTER1} -n httpbin label svc in-ambient istio.io/use-waypoint=waypoint

kubectl apply --context ${CLUSTER1} -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: in-ambient
  namespace: httpbin
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: in-ambient
    port: 8000
  rules:
    - backendRefs:
        - name: in-ambient
          port: 8000
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: x-istio-workload
                value: "%ENVIRONMENT(HOSTNAME)%"
EOF

echo "##### Execute ambient with waypoint perftest #####"

kubectl --context ${CLUSTER1} delete testrun -A --all   

cat <<'EOF' | kubectl --context ${CLUSTER1} apply -f -
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: k6-runner-5
  namespace: k6
spec:
  parallelism: 4
  script:
    configMap:
      name: k6-test
      file: k6-test.js
  separate: false
  arguments: -o experimental-prometheus-rw
  initializer: {}
  runner:
    image: grafana/k6
    env:
    - name: K6_PROMETHEUS_RW_SERVER_URL
      value: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    - name: K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM
      value: "true"
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      runAsNonRoot: true
      sysctls:
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
    tolerations:
    - key: k6
      operator: Exists
      effect: NoSchedule
    resources:
      limits:
        cpu: "1"
        memory: "2Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
EOF

export GRAFANA_TIMEINIT=$(date +"%s")000
sleep 60

until [ "$(kubectl --context ${CLUSTER1} get pods -n k6 --field-selector=status.phase=Running --no-headers | wc -l)" -eq "0" ]; do
  echo "Waiting for all pods to finish running..."
  sleep 5
done
echo "##### Annotating Grafana #####"
export GRAFANA_TIMEEND=$(date +"%s")000
kubectl --context=$CLUSTER1 -n monitoring port-forward svc/grafana 3000 &
PORT_FORWARD_PID=$!
sleep 5
curl -u "admin:prom-operator" \
     -H "Accept: application/json" \
     -H "Content-Type: application/json" \
     localhost:3000/api/annotations \
     -d "{\"time\":${GRAFANA_TIMEINIT},\"timeEnd\":${GRAFANA_TIMEEND},\"tags\":[\"perf\",\"ambient\"],\"text\":\"Ambient with waypoint\"}"
kill $PORT_FORWARD_PID
echo ""
echo "##### Done annotating Grafana #####"
