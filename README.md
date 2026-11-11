# Math GitOps deployment

`application.yaml` configures Argo CD to synchronize the `dev` directory into
the `myapp` namespace. `dev` is a Helm chart that runs **three replicas** of the
math application and exposes them through a **NodePort Service** on port 8080.
Argo CD renders Helm templates and manages synchronization; do not run
`helm install` or `helm upgrade` against these same resources.

The Helm release name is explicitly `math`, preserving the existing Deployment
and Service names. Their selectors remain `app: math` so the existing Deployment
can be updated without changing its immutable selector. The pinned image and
pull policy are also preserved. The replica count changes from five to three.

## Configuration and validation

Edit `dev/values.yaml` for the replica count, image repository/tag/pull policy,
existing `imagePullSecrets`, Service port, optional fixed node port, and
container resources. By default Kubernetes allocates the node port. To choose
one, set `service.nodePort: 30080`, or another available port in your cluster's
NodePort range. Requests and limits are unset; configure them based on measured
load. Never put registry credentials in Git.

Install Helm and validate locally from this repository:

```sh
helm lint ./dev --strict
helm template math ./dev --namespace myapp
```

`application.yaml` retains automated synchronization, self-healing, and pruning.
Its `CreateNamespace=true` option lets Argo CD create `myapp` when necessary.
For the first migration, pause auto-sync through the mechanism that manages the
Application, push the chart conversion, then update the registered Application
and resume auto-sync. Do not let the old Application synchronize the chart
before `spec.source.helm.releaseName` is set to `math`: Helm otherwise defaults
to the Application name, producing differently named resources that pruning
could replace the existing ones with.

If the Application is already registered, update it through the mechanism that
manages it (for example, its parent Argo CD application). If it was registered
manually, apply the updated definition to the cluster where Argo CD is installed:

```sh
kubectl apply -f application.yaml
```

Commit and push this repository's chart and Application changes before
synchronization. Existing registration alone does not make Argo CD watch edits
to `application.yaml` unless another application manages that file.

## Access

```sh
kubectl -n myapp rollout status deployment/math
kubectl -n myapp get pods,service
```

Use `http://NODE_IP:NODE_PORT/health/ready` with a reachable node IP and the
allocated Service node port. Firewalls must permit that port. For Minikube,
run `minikube service math -n myapp --url`; on macOS with the Docker driver,
keep the command running if it creates a tunnel.

## Health probes

All probes contact the application's named `http` port (8080) directly:

| Probe | Endpoint | Interval | Timeout | Consecutive failures |
| --- | --- | --- | --- | --- |
| Startup | `/health/startup` | 5 seconds | 2 seconds | 24 |
| Readiness | `/health/ready` | 5 seconds | 2 seconds | 1 |
| Liveness | `/health/live` | 10 seconds | 2 seconds | 3 |

Startup permits approximately two minutes of initialization. Until it succeeds,
readiness and liveness are disabled. They then run independently. Readiness
failure removes the Pod from normal Service routing; startup or liveness failure
at its threshold triggers a container restart. Timing is approximate and includes
kubelet scheduling and the container's termination grace period.

The math application implements these endpoints in `handlers/health.go`.
Initialization is synchronous and there are no external dependencies, so each
endpoint confirms that the HTTP server is serving and returns HTTP 200.

## Publish before synchronizing

The Deployment still references the existing pinned image. It must be replaced
with an image built from the math application changes before these probes are
synchronized; an older image without the endpoints will fail its startup probe.

1. Commit and push the application changes to `math`'s `main` branch.
2. Wait for its GitHub Actions workflow to pass and publish
   `docker.io/cohavisi/mymath:<application-commit-sha>`.
3. Update `image.tag` in `dev/values.yaml` to that published tag.
4. Commit and push the GitOps changes. Argo CD then applies the Deployment and
   Service rendered from the `dev` Helm chart.

The Service needs no probe settings: it uses Pod readiness automatically.

## Prometheus and Grafana

`monitoring/application.yaml` is a separate Argo CD Application deploying
`kube-prometheus-stack` **93.2.0** with Git-hosted `monitoring/values.yaml`.
It requires Kubernetes 1.25+ and Argo CD 2.6+ for multi-source Helm values.
The Argo CD project must permit the upstream Helm repository, this Git
repository, the `monitoring` namespace, and the stack's cluster-scoped resources.
The stack includes Prometheus Operator/CRDs, Prometheus, Alertmanager, Grafana,
Node Exporter, kube-state-metrics, Kubernetes dashboards and alert rules.

These are development defaults, not measured production sizing: one Prometheus
replica, two days of retention capped at 4 GiB, a 5 GiB Prometheus PVC, and 1 GiB
PVCs for Grafana and Alertmanager. A default dynamic StorageClass is required;
set explicit storage classes for your cluster when necessary. Configure
resources, storage, retention and availability before production use. Avoid
running a second stack if this cluster already has an operator/monitoring
installation managing these resources.

Controller-manager, scheduler, etcd and kube-proxy scrapes/rules are disabled
because these endpoints are commonly inaccessible on local or managed clusters.
API server, kubelet/cAdvisor, nodes and workload-state monitoring remain enabled.
Re-enable the disabled components only after configuring reachable,
authenticated endpoints for your cluster.

### Bootstrap and enable application scraping

All following commands are operator steps; confirm your Kubernetes context.
No manifests are applied merely by adding files to this repository.

1. Commit/push the monitoring files. The existing math Application watches only
   `dev`; register the monitoring Application separately, or have a parent
   Argo CD Application manage its definition.
2. Before synchronization, create the `monitoring` namespace and an externally
   managed `grafana-admin` Secret there with keys `admin-user` and
   `admin-password`. Grafana references this Secret; credentials are not stored
   in Git. Provision it through your secret manager, or from protected local
   files, for example:

```sh
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-file=admin-user=/secure/path/admin-user \
  --from-file=admin-password=/secure/path/admin-password
kubectl apply -f monitoring/application.yaml
```

Use existing namespace/Secret management instead of the create commands if they
already exist. Allow Argo CD to synchronize the stack, then confirm the
monitoring Application is healthy and these CRDs exist:

```sh
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
kubectl -n monitoring get pods,pvc
```

3. Publish the instrumented application image from the `math` repository,
   update `dev/values.yaml`'s `image.tag` to that published SHA, and set
   `metrics.enabled: true` in the same GitOps commit. The checked-in old image
   is deliberately preserved; metrics are disabled until this step.
4. Commit/push and let the existing math Application synchronize. Confirm three
   math Pod targets are individually `UP` in Prometheus and send math requests
   to populate latency histograms.

Do not assume sync waves order independently registered Applications. Bootstrap
the stack/CRDs before enabling the math ServiceMonitor/PrometheusRule.

### Metrics wiring and dashboards

The API NodePort remains on port 8080. When `metrics.enabled` is true, the chart
adds port 9090 (configurable), the `math-metrics` **ClusterIP** Service, a
ServiceMonitor, a Grafana dashboard ConfigMap, and application alert rules.
The ServiceMonitor selects only the metrics Service, not the API Service.
It scrapes each Pod's `/metrics` every 30 seconds with a 10-second timeout.

Prometheus discovers monitors/rules labeled `release: monitoring` in the
`monitoring` and `myapp` namespaces. Change both discovery selectors if you
change the application namespace or monitoring release label. Prometheus adds
`namespace`, `pod`, `service`, and target labels to application samples; the
application does not construct Kubernetes identity labels itself.

Grafana's dashboard sidecar loads ConfigMaps labeled `grafana_dashboard: "1"`.
The provisioned **Math overview** dashboard uses datasource UID `prometheus` and
namespace/Pod filters. It shows throughput, p95 request/calculation latency,
in-flight requests, validation errors, panics/5xx, CPU, memory, throttling,
goroutines, heap, and restarts. Built-in dashboards cover cluster/node and
Deployment availability. Histograms are aggregated across Pods before
calculating percentiles.

```sh
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n monitoring port-forward svc/monitoring-prometheus 9090:9090
```

Run each port-forward in its own terminal. Access Grafana at
`http://localhost:3000` using the externally provisioned admin credentials and
Prometheus at `http://localhost:9090`. Grafana, Prometheus and Alertmanager remain
ClusterIP-only; configure authenticated TLS ingress if remote access is needed.
The metrics Service is internal, but namespace access is not a firewall:
use NetworkPolicies where your network plugin supports them.

### Alerts and upgrades

Application rules cover unreachable/missing scrape targets, request panics,
repeated validation failures, sustained p95 latency, HTTP 5xx and OOM restarts.
Latency/rate/error thresholds in `dev/values.yaml` are starting points; tune them
to measured load and an agreed SLO. Default stack rules cover replica
availability, crash loops, node pressure and monitoring health.

Alertmanager is deployed, but external notifications are **not configured**:
the upstream default receiver discards notifications. Configure a real receiver
and route in `monitoring/values.yaml`, referencing externally managed Secrets
for notification credentials, before relying on paging.

Upgrade the pinned stack version deliberately and follow its CRD migration
instructions. Argo CD uses server-side apply to avoid large CRD annotation
limits; this does not replace CRD compatibility checks. Do not blindly prune
monitoring CRDs, which may be shared with other applications.

### Local chart validation

```sh
helm lint ./dev --strict
helm lint ./dev --strict --set metrics.enabled=true
helm template math ./dev --namespace myapp --set metrics.enabled=true
helm template monitoring kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version 93.2.0 --namespace monitoring \
  --include-crds --values monitoring/values.yaml
```
