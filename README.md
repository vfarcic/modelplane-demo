# Modelplane conference demo

The same hands-on flow works with **AWS EKS** or **Google Cloud GKE**: prepare a
GPU fleet, declare a model's requirements, inspect its placement, and call one
OpenAI-compatible service. Slow cluster provisioning belongs to pre-talk setup;
model deployment and scaling remain live.

## Versions

- Modelplane v0.5.0; Crossplane v2.4.2; Nushell v0.115.1.
- Local KinD uses the pinned Kubernetes v1.34.0 image from Modelplane's guide.
- EKS defaults to Kubernetes 1.36; GKE defaults to 1.35.
- kubectl 1.35.4 remains compatible with both the control and inference clusters.
- vLLM v0.23.0 serves Qwen/Qwen2.5-0.5B-Instruct.

## Layout and source of truth

- `dot.nu`: user-facing setup, check, verify, credentials, query, and destroy.
- `scripts/common.nu`, `kubernetes.nu`, `crossplane.nu`, and `google.nu`: copied
  from <https://github.com/vfarcic/nu-scripts>. Make reusable changes there first.
- `scripts/modelplane.nu`: this demo's provider selection and Modelplane flow.
- `aws/` and `google/`: provider-specific hardware, fleet, credentials-config,
  and gateway manifests.
- `modelplane.yaml`: shared bootstrap; `inference.yaml`: shared model and service.

The original AWS files now live under `aws/`. A consumer clone includes its
helpers and does not need a sibling nu-scripts checkout at runtime.

## Before setup

Run in the updated demo checkout. Once published, a fresh checkout uses:

```sh
git clone https://github.com/vfarcic/modelplane-demo
cd modelplane-demo
git pull
devbox shell
chmod +x dot.nu
```

Skip cloning if the directory already exists. Until these changes are published,
use this local checkout. Keep Docker running and allocate at least 8 GB to Docker
Desktop. `./dot.nu check` checks local tools without provisioning infrastructure.

### AWS

Provide AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY through the existing Devbox
credential hook or your environment; setup prompts if missing. Temporary
credentials also need AWS_SESSION_TOKEN. The account needs EKS, EC2/network,
IAM, and EFS provisioning access and sufficient GPU quotas.

The fleet has one L4 in us-east-1 and one L40S each in us-west-2 and eu-central-1.
Classes currently use g6.2xlarge and g6e.2xlarge, retaining one GPU per node. GPU
pools span two existing VPC zones. Real AWS validation found the original xlarge
instances unavailable, and the larger instances were also unavailable during
that attempt. The attempt was destroyed; availability is not implied by a valid
manifest or AWS's suggested alternate zones.

### Google Cloud

Authenticate with `gcloud auth login`. You need project creation permissions and
an open billing account. Setup creates a **unique project for every fresh run**,
using a timestamp plus random suffix; it does not reuse or change the default
gcloud project. A single open billing account is selected automatically; with
multiple accounts, pass `--billing-account`.

The fleet has an L4 in us-central1 and an A100 40GB each in us-west1 and us-east1.
Quota and physical GPU availability are still required. Provider credentials use
a dedicated service account with the roles documented by Modelplane; its JSON
key is kept in the ignored `gcp-creds.json` and uploaded to the control plane.

## Setup

Select one provider:

```sh
export PROVIDER=google  # Or aws
./dot.nu setup "$PROVIDER"
source .env
```

With no provider argument, setup prompts for AWS or Google. Setup prepares the
local control plane, cloud credentials, three GPU clusters, and the gateway, then
verifies readiness. This provisions real, billed resources.

`.modelplane-state.json` records provider and project ownership. A second fresh
setup is refused while a run is recorded. Resume a failed or interrupted run with:

```sh
./dot.nu setup --resume
source .env
```

Resume retains the original unique project rather than orphaning it by starting
another. Refresh credentials with `./dot.nu credentials`. A setup timeout leaves
reconciliation running; do not delete KinD to reset partially created resources.

The scripts use the isolated `kubeconfig-modelplane.yaml`. `.env` exports the
provider, kubeconfig, and Google project ID where applicable. The shared AWS helper
also stores credential exports there, following the existing demo convention.
Both state and credentials files are ignored by Git.

## Live demo and rehearsal

Inspect the prepared platform without reapplying infrastructure on stage:

```sh
cat "$PROVIDER/cluster-classes.yaml"
cat "$PROVIDER/clusters.yaml"
kubectl get inferenceclasses,inferenceclusters
```

Then launch the model and service live:

```sh
cat inference.yaml
kubectl --namespace a-team apply --filename inference.yaml
kubectl --namespace a-team get modeldeployments,modelreplicas
kubectl --namespace a-team get modelendpoints,modelservices,modelroutes
```

For rehearsal, bounded waits make validation reproducible:

```sh
kubectl --namespace a-team wait modeldeployment/qwen-demo \
  --for=condition=Ready --timeout=30m
kubectl --namespace a-team wait modelservice/qwen \
  --for=condition=Ready --timeout=10m
./dot.nu query
```

The query reads `InferenceGateway/default.status.endpoints.openAI` and requests
`a-team/qwen` on either cloud. `./dot.nu verify` checks only platform readiness and
gateway connectivity, not token generation. The tutorial gateway is plain HTTP
and unauthenticated, matching upstream getting-started examples.

Remove the rehearsal's model resources to restore the live starting state:

```sh
kubectl --namespace a-team delete --filename inference.yaml \
  --cascade=foreground --timeout=30m
```

Keep the fleet and gateway. Measure model startup during rehearsal, then fit the
explanations between launch and status inspection. Do not block the talk on a long
readiness wait or present prepared output as newly generated.

## Destroy

```sh
./dot.nu destroy
```

The saved provider selects the manifests. Destroy withdraws routes, removes model
workloads and caches, deletes gateway and fleet, and waits for managed resources
to disappear before removing KinD. Foreground parent deletion can finish before
provider finalizers finish cloud deletion, so that extra wait is essential.

For Google, destroy also marks the run's dedicated project DELETE_REQUESTED;
Google retains recoverable project metadata for its recovery window. Never
substitute the default project ID. A partial run that created a project but not
KinD is also recorded so destroy can remove its project.

If deletion times out or fails, keep the control plane running and inspect the
remaining dependencies. Do not remove finalizers merely to hide cloud leftovers.

## Diagnostics

```sh
kubectl get configurations,providers,functions
kubectl get inferenceclusters,inferencegateways
kubectl --namespace modelplane-system get managed
kubectl --namespace a-team get modeldeployments,modelreplicas,modelendpoints,modelroutes
```

Use actual conditions rather than assuming Synced means ready to serve. Cloud
instance capacity failures may appear in provider/Auto Scaling diagnostics before
high-level readiness changes. Changes to immutable EKS placement fields require
replacing the affected node pool, not merely reapplying a different zone.

## Live validation

On October 5, 2026, Google setup completed in a uniquely created project:
all three inference clusters and the gateway reported Ready, and the gateway's
health endpoint answered from the laptop. Actual compute inventory confirmed one
L4 and two A100 GPU instances. No models were deployed, leaving the live demo's
starting state intact.

Validation exposed a cloud-load-balancer race: an address can be published before
connections are accepted. The reusable HTTP-readiness helper now retries that
check within a bounded timeout. `setup --resume` completed successfully without
creating another project or key. The default gcloud project remained unchanged.

The AWS attempt was fully destroyed and directly audited for matching clusters,
VPCs, instances, NAT gateways, volumes, Elastic IPs, EFS filesystems, and IAM
roles/policies; no matching leftovers were found. Its GPU capacity failures were
external availability constraints, not a successful AWS inference validation.

## References

- [Modelplane v0.5.0 getting-started manifests](https://github.com/modelplaneai/modelplane/tree/v0.5.0/docs/manifests/getting-started)
- [Installation prerequisites](https://github.com/modelplaneai/modelplane/blob/v0.5.0/docs/manifests/install/prerequisites.yaml)
- [Current API architecture](https://github.com/modelplaneai/modelplane/blob/v0.5.0/docs/content/overview/how-it-works.md)
- [Upstream cleanup](https://github.com/modelplaneai/modelplane/blob/v0.5.0/docs/content/getting-started/clean-up.md)
