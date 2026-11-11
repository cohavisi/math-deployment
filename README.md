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
