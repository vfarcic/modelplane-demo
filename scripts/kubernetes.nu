#!/usr/bin/env nu

# Creates a Kubernetes cluster with the specified provider
#
# Examples:
# > main create kubernetes aws --name my-cluster --min_nodes 3 --max_nodes 5
# > main create kubernetes kind --name test-cluster
def --env "main create kubernetes" [
    provider: string  # The Kubernetes provider to use (aws, azure, google, upcloud, kind)
    --name = "dot"  # Name of the Kubernetes cluster
    --min-nodes = 2  # Minimum number of nodes in the cluster
    --max-nodes = 4  # Maximum number of nodes in the cluster
    --node-size = "small" # Supported values: small, medium, large
    --auth = true  # Whether to perform authentication with the cloud provider
    --enable-ingress = true  # Whether to enable ingress for the kind provider
    --billing-account = ""  # Billing account to link. Google only. Auto-detected when empty
    --zone = ""  # Zone for the cluster. Defaults per provider
    --kind-image = ""  # Pinned KinD node image. Empty uses KinD's default
    --reuse = false  # Reconnect to an existing KinD cluster with the same name
] {

    $env.KUBECONFIG = $"($env.PWD)/kubeconfig-($name).yaml"
    $"export KUBECONFIG=($env.KUBECONFIG)\n" | save --append .env

    if $provider == "google" {

        (
            create gke --name $name --node_size $node_size
                --min_nodes $min_nodes --max_nodes $max_nodes
                --auth $auth --billing_account $billing_account --zone $zone
        )

    } else if $provider == "aws" {

        (
            create eks  --name $name --node_size $node_size
                --min_nodes $min_nodes --max_nodes $max_nodes --zone $zone
        )

    } else if $provider == "azure" {

        (
            create aks --name $name --node_size $node_size
                --min_nodes $min_nodes --max_nodes $max_nodes
        )

    } else if $provider == "upcloud" {

        (
            create upcloud --name $name --node_size $node_size
                --min_nodes $min_nodes --max_nodes $max_nodes
        )

    } else if $provider == "kind" {

        mut config = {
            kind: "Cluster"
            apiVersion: "kind.x-k8s.io/v1alpha4"
            name: $name
            nodes: [{
                role: "control-plane"
            }]
        }

        if $enable_ingress {
            $config = $config | merge {
                nodes: [{
                    role: "control-plane"
                    kubeadmConfigPatches: ['kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "ingress-ready=true"'
                    ]
                    extraPortMappings: [{
                        containerPort: 80
                        hostPort: 80
                        protocol: "TCP"
                    }, {
                        containerPort: 443
                        hostPort: 443
                        protocol: "TCP"
                    }]
                }]
            }
        }
        
        $config | to yaml | save $"kind.yaml" --force

        let clusters = (kind get clusters | complete)
        if $clusters.exit_code != 0 {
            error make {msg: $"Could not list KinD clusters: ($clusters.stderr)"}
        }
        if $reuse and ($name in ($clusters.stdout | lines)) {
            kind export kubeconfig --name $name --kubeconfig $env.KUBECONFIG
        } else {
            mut args = ["create" "cluster" "--config" "kind.yaml"]
            if ($kind_image | is-not-empty) {
                $args = ($args | append ["--image" $kind_image])
            }
            kind ...$args
        }
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: $"Could not create or reconnect to KinD cluster ($name)."}
        }
    
    } else {

        print $"(ansi red_bold)($provider)(ansi reset) is not a supported."
        exit 1

    }

    $env.KUBECONFIG

}

# Adds a GPU node pool to an existing Kubernetes cluster
#
# The pool is tainted so that only workloads tolerating GPUs land on it. Keep
# system workloads on the general pool so the GPU pool can be recreated or
# scaled to zero without taking the rest of the cluster down.
#
# Examples:
# > main create gpu_nodes google --cluster-name dot
# > main create gpu_nodes google --cluster-name dot --accelerator nvidia-l4 --max-nodes 3
# > main create gpu_nodes aws --cluster-name dot --zone us-east-1d
def --env "main create gpu_nodes" [
    provider: string  # The Kubernetes provider to use (google, aws, azure)
    --cluster-name = "dot"  # Name of the Kubernetes cluster to add the pool to
    --name = "gpu"  # Name of the node pool
    --machine-type = ""  # Machine type backing the pool. Defaults per provider
    --accelerator = "nvidia-l4"  # Accelerator attached to each node. Google only
    --accelerator-count = 1  # Accelerators per node. Google only
    --num-nodes = 1  # Number of nodes to start with
    --min-nodes = 0  # Minimum number of nodes. Zero enables scale to zero
    --max-nodes = 1  # Maximum number of nodes
    --zone = ""  # Zone for the pool. Defaults per provider
    --region = "us-east-1"  # Region the cluster lives in. AWS only
    --taint = true  # Whether to taint the pool so only GPU workloads schedule on it
] {

    # Both defaults are a single NVIDIA L4 with 8 vCPUs and 32 GB of RAM, so the
    # two providers give the same machine. Azure has no L4 equivalent.
    mut size = $machine_type
    if $size == "" {
        $size = (if $provider == "aws" { "g6.2xlarge" } else { "g2-standard-8" })
    }

    if $provider == "google" {

        let google_zone = if $zone == "" { "us-east1-b" } else { $zone }

        mut project_id = ""
        if PROJECT_ID in $env {
            $project_id = $env.PROJECT_ID
        } else {
            $project_id = (gcloud config get-value project | str trim)
        }

        if $project_id == "" {
            print $"(ansi red_bold)Could not determine the project(ansi reset). Set PROJECT_ID or run `gcloud config set project`."
            exit 1
        }

        mut args = [
            $name
            --cluster $cluster_name
            --project $project_id
            --zone $google_zone
            --machine-type $size
            --accelerator $"type=($accelerator),count=($accelerator_count),gpu-driver-version=latest"
            --num-nodes $num_nodes
            --enable-autoscaling
            --min-nodes $min_nodes
            --max-nodes $max_nodes
            --no-enable-autoupgrade
        ]

        if $taint {
            $args = ($args | append [--node-taints $"nvidia.com/gpu=present:NoSchedule"])
        }

        gcloud container node-pools create ...$args

    } else if $provider == "aws" {

        let aws_zone = if $zone == "" { "us-east-1d" } else { $zone }

        # eksctl installs the NVIDIA device plugin itself once it sees a GPU
        # instance type, so there is no driver argument to pass here.
        mut node_group = {
            name: $name
            instanceType: $size
            availabilityZones: [$aws_zone]
            minSize: $min_nodes
            maxSize: $max_nodes
            desiredCapacity: $num_nodes
            iam: {
                withAddonPolicies: {
                    autoScaler: true
                    ebs: true
                }
            }
        }

        if $taint {
            $node_group = ($node_group | merge {
                taints: [{
                    key: "nvidia.com/gpu"
                    value: "present"
                    effect: "NoSchedule"
                }]
            })
        }

        {
            apiVersion: "eksctl.io/v1alpha5"
            kind: "ClusterConfig"
            metadata: {
                name: $cluster_name
                region: $region
            }
            managedNodeGroups: [$node_group]
        } | to yaml | save $"eksctl-nodegroup-($cluster_name).yaml" --force

        (
            eksctl create nodegroup
                --config-file $"eksctl-nodegroup-($cluster_name).yaml"
                --timeout 45m
        )

    } else if $provider == "azure" {

        print $"(ansi red_bold)azure(ansi reset) is not implemented yet. Azure has no L4 equivalent, and its A10 and T4 GPUs do not support FP8 natively."
        exit 1

    } else {

        print $"(ansi red_bold)($provider)(ansi reset) is not supported."
        exit 1

    }

}

# Recreates a GPU node pool so workloads start without a warm host cache
#
# Examples:
# > main recreate gpu_nodes google --cluster-name dot --zone us-east1-b
# > main recreate gpu_nodes aws --cluster-name dot --zone us-east-1d
def --env "main recreate gpu_nodes" [
    provider: string  # The Kubernetes provider to use (google, aws)
    --cluster-name = "dot"  # Name of the Kubernetes cluster
    --name = "gpu"  # Name of the node pool
    --machine-type = ""  # Machine type backing the pool. Defaults per provider
    --accelerator = "nvidia-l4"  # Accelerator attached to each node. Google only
    --accelerator-count = 1  # Accelerators per node. Google only
    --num-nodes = 1  # Number of nodes to start with
    --min-nodes = 0  # Minimum number of nodes
    --max-nodes = 1  # Maximum number of nodes
    --zone = ""  # Zone for the pool. Defaults per provider
    --region = "us-east-1"  # Region the cluster lives in. AWS only
    --taint = true  # Whether to taint the pool
] {

    if $provider == "google" {

        let google_zone = if $zone == "" { "us-east1-b" } else { $zone }
        let existing = (
            do --ignore-errors {
                (
                    gcloud container node-pools describe $name
                        --cluster $cluster_name --zone $google_zone
                )
            } | complete
        )

        if $existing.exit_code == 0 {
            (
                gcloud container node-pools delete $name
                    --cluster $cluster_name --zone $google_zone --quiet
            )
        }

    } else if $provider == "aws" {

        let existing = (
            do --ignore-errors {
                (
                    eksctl get nodegroup --name $name --cluster $cluster_name
                        --region $region --output json
                )
            } | complete
        )

        if $existing.exit_code == 0 {
            (
                eksctl delete nodegroup --name $name --cluster $cluster_name
                    --drain=false --region $region --wait
            )
        }

    } else {

        print $"(ansi red_bold)($provider)(ansi reset) is not supported."
        exit 1

    }

    (
        main create gpu_nodes $provider --cluster-name $cluster_name --name $name
            --machine-type $machine_type --accelerator $accelerator
            --accelerator-count $accelerator_count --num-nodes $num_nodes
            --min-nodes $min_nodes --max-nodes $max_nodes --zone $zone
            --region $region --taint $taint
    )

}

# Lists the required packages for Kubernetes functionality
#
# Examples:
# > main packages kubernetes
def "main packages kubernetes" [] {

    print $"(ansi yellow_bold)Following Nix packages are required(ansi reset):
* kind
* kubectl
* awscli2
* eksctl
* google-cloud-sdk
* azure-cli
"

print $"(ansi yellow_bold)Following tools not available as Nix packages are required(ansi reset):
* upctl
"

}

# Destroys a Kubernetes cluster created with the specified provider
#
# Examples:
# > main destroy kubernetes aws --name my-cluster
# > main destroy kubernetes google --name test-cluster --delete_project false
def "main destroy kubernetes" [
    provider: string  # The Kubernetes provider to delete (aws, azure, google, upcloud, kind)
    --name = "dot"  # Name of the Kubernetes cluster to destroy
    --delete_project = true  # Whether to delete the associated cloud project
] {

    if $provider == "google" {

        rm --force $env.KUBECONFIG

        (
            gcloud container clusters delete $name
                --project $env.PROJECT_ID --zone us-east1-b --quiet
        )

        if $delete_project {
            gcloud projects delete $env.PROJECT_ID --quiet
        }
    
    } else if $provider == "aws" {

        let region = "us-east-1"

        do --ignore-errors {
            (
                eksctl delete addon --name aws-ebs-csi-driver
                    --cluster $name --region $region
            )
        }

        # Deletes every node group rather than just `primary`, since clusters
        # can carry extra pools such as GPU nodes. Cluster deletion would
        # normally sweep them up, but doing it explicitly keeps the failure
        # modes obvious rather than leaving instances behind if that stalls.
        let node_groups = (
            do --ignore-errors {
                eksctl get nodegroup --cluster $name --region $region --output json
            } | complete
        )

        if $node_groups.exit_code == 0 {
            for group in ($node_groups.stdout | from json | get Name) {
                (
                    eksctl delete nodegroup --name $group
                        --cluster $name --drain=false
                        --region $region --parallel 10 --wait
                )
            }
        }

        (
            eksctl delete cluster
                --config-file $"eksctl-config-($name).yaml"
                --wait
        )

    } else if $provider == "azure" {

        (
            az aks delete --resource-group $env.RESOURCE_GROUP
                --name $name --yes
        )

        if $delete_project {

            az group delete --name $env.RESOURCE_GROUP --yes

        }

    } else if $provider == "upcloud" {

        print $"Deleting (ansi yellow_bold)Kubernetes(ansi reset)..."

        upctl kubernetes delete $name

        print $"Waiting for (ansi yellow_bold)10 minutes(ansi reset) to fully clean up the cluster..."

        sleep 600sec

        print $"Deleting (ansi yellow_bold)network(ansi reset)..."

        upctl network delete $name

    } else if $provider == "kind" {

        kind delete cluster --name $name
        if $env.LAST_EXIT_CODE != 0 {
            error make {msg: $"Could not delete KinD cluster ($name)."}
        }

    }

    if "KUBECONFIG" in $env {
        rm --force $env.KUBECONFIG
    }

}

# Creates Kubernetes credentials in a kubeconfig file
#
# Examples:
# > main create kubernetes_creds --source_kuberconfig kubeconfig.yaml --destination_kuberconfig new-kubeconfig.yaml
def "main create kubernetes_creds" [
    --source_kuberconfig = "kubeconfig.yaml"  # Path to the source kubeconfig file
    --destination_kuberconfig = "kubeconfig_new.yaml"  # Path to the destination kubeconfig file
] {

    {
        apiVersion: "v1"
        kind: "ServiceAccount"
        metadata: {
            name: "creds"
            namespace: "kube-system"
        }
    } | to yaml | kubectl --kubeconfig $source_kuberconfig apply --filename -

    {
        apiVersion: "v1"
        kind: "Secret"
        metadata: {
            name: "creds"
            namespace: "kube-system"
            annotations: {
                "kubernetes.io/service-account.name": "creds"
            }
        }
        type: "kubernetes.io/service-account-token"
    } | to yaml | kubectl --kubeconfig $source_kuberconfig apply --filename -

    {
        apiVersion: "rbac.authorization.k8s.io/v1"
        kind: "ClusterRoleBinding"
        metadata: {
            name: "creds"
        }
        subjects: [{
            kind: "ServiceAccount"
            name: "creds"
            namespace: "kube-system"
        }]
        roleRef: {
            kind: "ClusterRole"
            name: "cluster-admin"
            apiGroup: "rbac.authorization.k8s.io"
        }
    }
        | to yaml
        | kubectl --kubeconfig $source_kuberconfig apply --filename -

    let kube_ca_data = open $source_kuberconfig
        | get clusters.0.cluster.certificate-authority-data

    let kube_url = open $source_kuberconfig
        | get clusters.0.cluster.server

    let token_encoded = (
        kubectl
            --kubeconfig $source_kuberconfig
            --namespace kube-system
            get secret creds --output yaml
    )
        | from yaml
        | get data.token

    let token = ($token_encoded | decode base64 | decode)

    {
        apiVersion: "v1"
        kind: "Config"
        clusters: [{
            name: "default-cluster"
            cluster: {
                certificate-authority-data: $kube_ca_data
                server: $"($kube_url):443"
            }
        }]
        contexts: [{
            name: "default-context"
            context: {
                cluster: "default-cluster"
                namespace: "default"
                user: "default-user"
            }
        }]
        current-context: "default-context"
        users: [{
            name: "default-user"
            user: {
                token: $token
            }
        }]
    } | to yaml | save $source_kuberconfig --force

}

def --env "main get kubeconfig" [
    provider: string                  # The Kubernetes provider (aws, azure, google, upcloud)
    --name = "dot"                    # Name of the Kubernetes cluster
    --resource_group = ""             # The resource group for Azure clusters
    --project-id = ""                 # The project ID for Google Cloud clusters
    --zone = "us-east1-b"             # The zone for Google Cloud clusters
    --destination = "kubeconfig.yaml" # Path to save the kubeconfig file
] {

    if $provider == "aws" {
        aws eks update-kubeconfig --name $name --region us-east-1 --kubeconfig $destination
    } else if $provider == "upcloud" {
        upctl kubernetes config $name --output yaml --write $env.KUBECONFIG --write $destination
    } else if $provider == "azure" {
        az aks get-credentials --resource-group $resource_group --name $name --file $env.KUBECONFIG --file $destination
    } else if $provider == "google" {
        $env.KUBECONFIG = $destination
        gcloud container clusters get-credentials $name --project $project_id --zone $zone
    } else {
        print $"(ansi red_bold)($provider)(ansi reset) is not a supported"
        return
    }

    print $"Kube config saved to (ansi yellow_bold)($destination)(ansi reset). Execute `(ansi yellow_bold)export KUBECONFIG=($destination)(ansi reset)` to use it in the current shell session."

}

# Creates a UpCloud Kubernetes cluster
#
# Examples:
# > create upcloud --name my-cluster --node_size medium --min_nodes 3 --max_nodes 5
def --env "create upcloud" [
    --name = "dot"  # Name of the Kubernetes cluster
    --node_size = "small" # Supported values: small, medium, large
    --min_nodes = 2  # Minimum number of nodes in the cluster
    --max_nodes = 4  # Maximum number of nodes in the cluster
] {

print $"
Visit https://signup.upcloud.com/?promo=devops50 to (ansi yellow_bold)sign up(ansi reset) and get $50+ credits.
Make sure that (ansi yellow_bold)Allow API connections from all networks(ansi reset) is checked inside the https://hub.upcloud.com/account/overview page.
Install `(ansi yellow_bold)upctl(ansi reset)` from https://upcloudltd.github.io/upcloud-cli if you do not have it already.
Press the (ansi yellow_bold)enter key(ansi reset) to continue.
"
        input

        mut upcloud_username = ""
        if UPCLOUD_USERNAME in $env {
            $upcloud_username = $env.UPCLOUD_USERNAME
        } else {
            $upcloud_username = input $"(ansi green_bold)Enter UpCloud username: (ansi reset)"
            $env.UPCLOUD_USERNAME = $upcloud_username
        }
        $"export UPCLOUD_USERNAME=($upcloud_username)\n"
            | save --append .env
    
        mut upcloud_password = ""
        if UPCLOUD_PASSWORD in $env {
            $upcloud_password = $env.UPCLOUD_PASSWORD
        } else {
            $upcloud_password = input $"(ansi green_bold)Enter UpCloud password: (ansi reset)" --suppress-output
            $env.UPCLOUD_PASSWORD = $upcloud_password
        }
        $"export UPCLOUD_PASSWORD=($upcloud_password)\n"
            | save --append .env
        print ""

        mut vm_size = "2xCPU-4GB"
        if $node_size == "medium" {
            $vm_size = "4xCPU-8GB"
        } else if $node_size == "large" {
            $vm_size = "8xCPU-32GB"
        }

        print $"Creating (ansi yellow_bold)network(ansi reset)..."

        do --ignore-errors {(
            upctl network create --name $name --zone us-nyc1
                --ip-network address="10.0.1.0/24,dhcp=true"
        )}

        print $"Creating (ansi yellow_bold)Kubernetes(ansi reset) cluster..."

        (
            upctl kubernetes create --name $name --zone us-nyc1
                --node-group $"count=($min_nodes),name=dot,plan=($vm_size)"
                --plan dev-md  --network $name --version "1.30"
                --kubernetes-api-allow-ip "0.0.0.0/0" --wait
        )

        print $"Getting (ansi yellow_bold)kubeconfig(ansi reset)..."

        main get kubeconfig upcloud --name $name

        print $"Waiting for (ansi yellow_bold)5 minutes(ansi reset) to fully set up the cluster..."

        sleep 300sec

}

# Creates an Azure Kubernetes Service (AKS) cluster
#
# Examples:
# > create aks --name my-cluster --node_size medium --min_nodes 3 --max_nodes 5
def --env "create aks" [
    --name = "dot",  # Name of the Kubernetes cluster
    --min_nodes = 2,  # Minimum number of nodes in the cluster
    --max_nodes = 4,  # Maximum number of nodes in the cluster
    --node_size = "small" # Supported values: small, medium, large
    --auth = true  # Whether to perform authentication with Azure
] {

    mut tenant_id = ""
    let location = "eastus"

    if AZURE_TENANT in $env {
        $tenant_id = $env.AZURE_TENANT
    } else {
        $tenant_id = input $"(ansi green_bold)Enter Azure Tenant ID: (ansi reset)"
    }

    if $auth {
        az login --tenant $tenant_id
    }

    mut resource_group = ""
    if RESOURCE_GROUP in $env {
        $resource_group = $env.RESOURCE_GROUP
    } else {
        $resource_group = $"dot-(date now | format date "%Y%m%d%H%M%S")"
        $env.RESOURCE_GROUP = $resource_group
        $"export RESOURCE_GROUP=($resource_group)\n" | save --append .env
        az group create --name $resource_group --location $location
    }
    mut vm_size = "Standard_B2s"
    if $node_size == "medium" {
        $vm_size = "Standard_B4ms"
    } else if $node_size == "large" {
        $vm_size = "Standard_B8ms"
    }

    (
        az aks create --resource-group $resource_group --name $name
            --node-count $min_nodes --min-count $min_nodes
            --max-count $max_nodes
            --node-vm-size $vm_size
            --enable-managed-identity --generate-ssh-keys
            --enable-cluster-autoscaler --yes
    )

    main get kubeconfig azure --name $name --resource_group $resource_group

}

# Creates a Google Kubernetes Engine (GKE) cluster
#
# Examples:
# > create gke --name my-cluster --node_size medium --min_nodes 3 --max_nodes 5 --auth true
def --env "create gke" [
    --name = "dot",  # Name of the Kubernetes cluster
    --min_nodes = 2,  # Minimum number of nodes in the cluster
    --max_nodes = 4,  # Maximum number of nodes in the cluster
    --node_size = "small" # Supported values: small, medium, large
    --auth = true  # Whether to perform authentication with Google Cloud
    --billing_account = ""  # Billing account to link. Auto-detected when empty
    --zone = ""  # Zone for the cluster
] {

    let cluster_zone = if $zone == "" { "us-east1-b" } else { $zone }

    if $auth {
        gcloud auth login
    }

    mut project_id = ""
    if PROJECT_ID in $env and not $auth {
        $project_id = $env.PROJECT_ID
    } else {
        $project_id = $"dot-(date now | format date "%Y%m%d%H%M%S")"
        $env.PROJECT_ID = $project_id
        $"export PROJECT_ID=($project_id)\n" | save --append .env

        gcloud projects create $project_id

        mut billing = $billing_account
        if $billing == "" {
            let accounts = (
                gcloud billing accounts list --filter "open=true"
                    --format "value(name)" | lines
            )
            if ($accounts | is-empty) {
                print $"(ansi red_bold)No open billing account found(ansi reset). Pass --billing_account."
                exit 1
            }
            $billing = ($accounts | first)
        }

        gcloud billing projects link $project_id --billing-account $billing

        gcloud services enable container.googleapis.com --project $project_id
    }

    mut vm_size = "e2-standard-2"
    if $node_size == "medium" {
        $vm_size = "e2-standard-4"
    } else if $node_size == "large" {
        $vm_size = "e2-standard-8"
    }

    # `gcloud services enable` returns before the API is actually usable, so
    # cluster creation can fail with a 403 for a minute or two afterwards.
    # Retry until it takes. Closures cannot capture mutable variables, hence the
    # immutable copies.
    let pid = $project_id
    let size = $vm_size

    mut attempt = 0
    mut created = false

    while (not $created) and ($attempt < 10) {

        $attempt = $attempt + 1

        # `complete` captures the exit code. Do not pipe to `ignore` here: it is
        # a successful command in its own right and resets LAST_EXIT_CODE to 0,
        # which makes a 404 look like the cluster already exists.
        let existing = (
            do --ignore-errors {
                gcloud container clusters describe $name --project $pid --zone $cluster_zone
            } | complete
        )

        if $existing.exit_code == 0 {
            $created = true
            break
        }

        do --ignore-errors {
            (
                gcloud container clusters create $name --project $pid
                    --zone $cluster_zone --machine-type $size
                    --enable-autoscaling --num-nodes $min_nodes
                    --min-nodes $min_nodes --max-nodes $max_nodes
                    --enable-network-policy --no-enable-autoupgrade
                    --gateway-api=standard
            )
        }

        if $env.LAST_EXIT_CODE == 0 {
            $created = true
        } else {
            print $"(ansi yellow_bold)Cluster creation failed(ansi reset). The Kubernetes Engine API may still be propagating. Retrying in 30 seconds \(attempt ($attempt) of 10\)."
            sleep 30sec
        }

    }

    if not $created {
        print $"(ansi red_bold)Could not create the cluster(ansi reset) after ($attempt) attempts."
        exit 1
    }

    # Pre-create empty kubeconfig file to prevent gcloud from creating a directory
    touch $env.KUBECONFIG

    (
        main get kubeconfig google --name $name --project-id $project_id
            --zone $cluster_zone --destination $env.KUBECONFIG
    )

}

# Creates an Amazon Elastic Kubernetes Service (EKS) cluster
#
# Examples:
# > create eks --name my-cluster --node_size medium --min_nodes 3 --max_nodes 5
def --env "create eks" [
    --name = "dot",  # Name of the Kubernetes cluster
    --min_nodes = 2,  # Minimum number of nodes in the cluster
    --max_nodes = 4,  # Maximum number of nodes in the cluster
    --node_size = "small" # Supported values: small, medium, large
    --zone = ""  # Preferred zone for GPU-capable subnets
] {

    let region = "us-east-1"
    let primary_zone = if $zone == "" { "us-east-1d" } else { $zone }
    let secondary_zone = if $primary_zone == "us-east-1c" { "us-east-1d" } else { "us-east-1c" }

    mut aws_access_key_id = ""
    if AWS_ACCESS_KEY_ID in $env {
        $aws_access_key_id = $env.AWS_ACCESS_KEY_ID
    } else {
        $aws_access_key_id = input $"(ansi green_bold)Enter AWS Access Key ID: (ansi reset)"
    }
    $"export AWS_ACCESS_KEY_ID=($aws_access_key_id)\n"
        | save --append .env

    mut aws_secret_access_key = ""
    if AWS_SECRET_ACCESS_KEY in $env {
        $aws_secret_access_key = $env.AWS_SECRET_ACCESS_KEY
    } else {
        $aws_secret_access_key = input $"(ansi green_bold)Enter AWS Secret Access Key: (ansi reset)" --suppress-output
    }
    $"export AWS_SECRET_ACCESS_KEY=($aws_secret_access_key)\n"
        | save --append .env

    let aws_account_id = (
        aws sts get-caller-identity --query "Account" 
            --output text
    )
    $"export AWS_ACCOUNT_ID=($aws_account_id)\n"
        | save --append .env

    $"[default]
aws_access_key_id = ($aws_access_key_id)
aws_secret_access_key = ($aws_secret_access_key)
" | save aws-creds.conf --force

    mut vm_size = "t3.medium"
    if $node_size == "medium" {
        $vm_size = "t3.xlarge"
    } else if $node_size == "large" {
        $vm_size = "t3.2xlarge"
    }

    {
        apiVersion: "eksctl.io/v1alpha5"
        kind: "ClusterConfig"
        metadata: {
            name: $name
            region: $region
            version: "1.34"
        }
        availabilityZones: [$primary_zone $secondary_zone]
        autoModeConfig: {
            enabled: false
        }
        managedNodeGroups: [{
            name: "primary"
            instanceType: $vm_size
            minSize: $min_nodes
            maxSize: $max_nodes
            iam: {
                withAddonPolicies: {
                    autoScaler: true
                    ebs: true
                }
            }
        }]
    } | to yaml | save $"eksctl-config-($name).yaml" --force

    (
        eksctl create cluster
            --config-file $"eksctl-config-($name).yaml"
            --kubeconfig $env.KUBECONFIG
    )

    (
        eksctl create addon --name aws-ebs-csi-driver
            --cluster $name
            --service-account-role-arn $"arn:aws:iam::($aws_account_id):role/AmazonEKS_EBS_CSI_DriverRole"
            --region $region --force
    )

    (
        kubectl patch storageclass gp2
            --patch '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    )

    (
        eksctl utils associate-iam-oidc-provider --cluster $name
            --region $region --approve
    )

    let oidc_provider = (
        aws eks describe-cluster --name $name --region $region
            --query "cluster.identity.oidc.issuer"
            --output text | str replace "https://" ""
    )
    $"export OIDC_PROVIDER=($oidc_provider)\n"
        | save --append .env

    main get kubeconfig aws --name $name

}
