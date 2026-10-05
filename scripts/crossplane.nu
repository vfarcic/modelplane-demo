#!/usr/bin/env nu

# Installs and configures Crossplane with optional cloud provider setup
#
# Examples:
# > main apply crossplane --provider aws
# > main apply crossplane --provider google --app
# > main apply crossplane --provider azure --db-config --github-config --github-user user --github-token token
def --env "main apply crossplane" [
    --provider = none,            # Which provider to use. Available options are `none`, `google`, `aws`, and `azure`
    --app-config = false,         # Whether to apply DOT App Configuration
    --db-config = false,          # Whether to apply DOT SQL Configuration
    --github-config = false,      # Whether to apply DOT GitHub Configuration
    --github-user: string,        # GitHub user required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --github-token: string,       # GitHub token required for the DOT GitHub Configuration and optinal for the DOT App Configuration
    --policies = false,           # Whether to create Validating Admission Policies
    --skip-login = false,         # Whether to skip the login (only for Azure)
    --db-provider = false,        # Whether to apply database provider (not needed if --db-config is `true`)
    --version = "2.4.2",          # Crossplane Helm chart version
    --default-activations = ["*.m.upbound.io" "*.m.crossplane.io"], # Empty lets configurations activate only what they need
    --dependency-version-upgrades = false, # Let configurations upgrade their provider dependencies
    --timeout = "10m"             # Helm installation timeout
] {

    print $"\nInstalling (ansi green_bold)Crossplane(ansi reset)...\n"

    helm repo add crossplane https://charts.crossplane.io/stable

    helm repo update

    mut args = [
        "upgrade" "--install" "crossplane" "crossplane/crossplane"
        "--namespace" "crossplane-system" "--create-namespace"
        "--version" $version "--timeout" $timeout "--wait"
        "--set-json" $"provider.defaultActivations=($default_activations | to json --raw)"
    ]
    if $dependency_version_upgrades {
        $args = ($args | append ["--set" "args={--enable-dependency-version-upgrades}"])
    }
    helm ...$args
    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: "Crossplane installation failed."}
    }

    mut provider_data = {}
    if $provider == "google" {
        $provider_data = setup google
    } else if $provider == "aws" {
        setup aws
    } else if $provider == "azure" {
        setup azure --skip-login $skip_login
    }

    if $app_config {

        print $"\n(ansi green_bold)Applying `dot-application` Configuration...(ansi reset)\n"

        let version = "v3.0.46"
        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-app" }
            spec: { package: $"xpkg.upbound.io/devops-toolkit/dot-application:($version)" }
        } | to yaml | kubectl apply --filename -

        if $policies {

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicy"
                metadata: { name: "dot-app" }
                spec: {
                    failurePolicy: "Fail"
                    matchConstraints: {
                        resourceRules: [{
                            apiGroups:   ["devopstoolkit.live"]
                            apiVersions: ["*"]
                            operations:  ["CREATE", "UPDATE"]
                            resources:   ["appclaims"]
                        }]
                    }
                    validations: [
                        {
                            expression: "has(object.spec.parameters.scaling) && has(object.spec.parameters.scaling.enabled) && object.spec.parameters.scaling.enabled"
                            message: "`spec.parameters.scaling.enabled` must be set to `true`."
                        }, {
                            expression: "has(object.spec.parameters.scaling) && object.spec.parameters.scaling.min > 1"
                            message: "`spec.parameters.scaling.min` must be greater than `1`."
                        }
                    ]
                }
            } | to yaml | kubectl apply --filename -

            {
                apiVersion: "admissionregistration.k8s.io/v1"
                kind: "ValidatingAdmissionPolicyBinding"
                metadata: { name: "dot-app" }
                spec: {
                    policyName: "dot-app"
                    validationActions: ["Deny"]
                }
            } | to yaml | kubectl apply --filename -

        }

    }

    if ($db_config or $db_provider) and $provider == "google" {

        start $"https://console.cloud.google.com/marketplace/product/google/sqladmin.googleapis.com?project=($provider_data.project_id)"

        print $"\n(ansi yellow_bold)ENABLE(ansi reset) the API.\nPress the (ansi yellow_bold)enter key(ansi reset) to continue.\n"
        input

    }

    if $db_config {

        print $"\n(ansi green_bold)Applying `dot-sql` Configuration...(ansi reset)\n"

        let version = "v2.2.11"
        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "crossplane-sql" }
            spec: { package: $"xpkg.upbound.io/devops-toolkit/dot-sql:($version)" }
        } | to yaml | kubectl apply --filename -

    } else if $db_provider {

        apply db-provider $provider

    }

    if $github_config {

        print $"\n(ansi green_bold)Applying `dot-github` Configuration...(ansi reset)\n"

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Configuration"
            metadata: { name: "devops-toolkit-dot-github" }
            spec: { package: "xpkg.upbound.io/devops-toolkit/dot-github:v0.0.57" }
        } | to yaml | kubectl apply --filename -

    }

    if $db_config or $github_config or $app_config {

        print $"\n(ansi green_bold)Applying Kubernetes and Helm providers...(ansi reset)\n"

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRole"
            metadata: {
                name: "crossplane-all"
                labels: {
                    "rbac.crossplane.io/aggregate-to-crossplane": "true"
                }
            }
            rules: [{
                apiGroups: ["*"]
                resources: ["*"]
                verbs: ["*"]
            }]
        } | to yaml | kubectl apply --filename -


        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: {  name: crossplane-provider-helm }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-helm"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1beta1"
            kind: "DeploymentRuntimeConfig"
            metadata: { name: "crossplane-provider-helm" }
            spec: { deploymentTemplate: { spec: {
                selector: {}
                template: { spec: {
                    containers: [{ name: "package-runtime" }]
                    serviceAccountName: "crossplane-provider-helm"
                } }
            } } }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-helm" }
            spec: {
                package: "xpkg.upbound.io/crossplane-contrib/provider-helm:v1.0.0"
                runtimeConfigRef: { name: "crossplane-provider-helm" }
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "v1"
            kind: "ServiceAccount"
            metadata: {
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "rbac.authorization.k8s.io/v1"
            kind: "ClusterRoleBinding"
            metadata: { name: "crossplane-provider-kubernetes" }
            subjects: [{
                kind: "ServiceAccount"
                name: "crossplane-provider-kubernetes"
                namespace: "crossplane-system"
            }]
            roleRef: {
                kind: "ClusterRole"
                name: "cluster-admin"
                apiGroup: "rbac.authorization.k8s.io"
            }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1beta1"
            kind: "DeploymentRuntimeConfig"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: { deploymentTemplate: { spec: {
                selector: {}
                template: { spec: {
                    containers: [{ name: "package-runtime" }]
                    serviceAccountName: "crossplane-provider-kubernetes"
                } }
            } } }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "crossplane-provider-kubernetes" }
            spec: {
                package: "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.0.0"
                runtimeConfigRef: { name: "crossplane-provider-kubernetes" }
            }
        } | to yaml | kubectl apply --filename -

    }

    if $db_config or $app_config or $github_config or $db_provider {
        wait crossplane
    }

    if ($db_config and $provider != "none") or $db_provider {

        if $provider == "google" {
            (
                main apply crossplane-providerconfig $provider
                    --google-project-id $provider_data.project_id
            )
        } else {
            main apply crossplane-providerconfig $provider
        }


    }

    if ($github_user | is-not-empty) and ($github_token | is-not-empty) {

        {
            apiVersion: v1,
            kind: Secret,
            metadata: {
                name: github,
                namespace: crossplane-system
            },
            type: Opaque,
            stringData: {
                credentials: $"{\"token\":\"($github_token)\",\"owner\":\"($github_user)\"}"
            }
        } | to yaml | kubectl apply --filename -

        if $app_config or $github_config {

            {
                apiVersion: "github.upbound.io/v1beta1",
                kind: ProviderConfig,
                metadata: {
                    name: default
                },
                spec: {
                    credentials: {
                        secretRef: {
                            key: credentials,
                            name: github,
                            namespace: crossplane-system,
                        },
                        source: Secret
                    }
                }
            } | to yaml | kubectl apply --filename -

        }

    }

    $provider_data

}

# Waits for all managed resources to disappear before a control plane is removed.
# Foreground XR deletion can return while provider finalizers still remove cloud resources.
def "main wait crossplane_cleanup" [
    --namespace = ""
    --timeout: duration = 60min
    --interval: duration = 15sec
] {

    let deadline = (date now) + $timeout
    loop {
        mut arguments = ["get" "managed" "--output" "name"]
        if ($namespace | is-not-empty) {
            $arguments = ($arguments | append ["--namespace" $namespace])
        } else {
            $arguments = ($arguments | append ["--all-namespaces"])
        }
        let result = (kubectl ...$arguments | complete)
        if $result.exit_code != 0 {
            error make {msg: $"Could not check managed-resource deletion: ($result.stderr)"}
        }
        let remaining = ($result.stdout | str trim)
        if ($remaining | is-empty) { break }
        if (date now) >= $deadline {
            error make {msg: $"Keep the control plane running: managed resources remain.\n($remaining)"}
        }
        print $"Waiting for ($remaining | lines | length) managed resources to finish deleting..."
        sleep $interval
    }

}

# Deletes Crossplane resources and waits for managed resources to be cleaned up
#
# Examples:
# > main delete crossplane
# > main delete crossplane --kind AppClaim --name myapp --namespace default
def "main delete crossplane" [
    --kind: string,
    --name: string,
    --namespace: string
] {

    if ($kind | is-not-empty) and ($name | is-not-empty) and ($namespace | is-not-empty) {
        kubectl --namespace $namespace delete $kind $name
    }

    print $"\nWaiting for (ansi green_bold)Crossplane managed resources(ansi reset) to be deleted...\n"

    mut command = { kubectl get managed --output name }
    if ($name | is-not-empty) {
        $command = {
            (
                kubectl get managed --output name
                    --selector $"crossplane.io/claim-name=($name)"
            )
        }
    }

    mut resources = (do $command)
    mut counter = ($resources | wc -l | into int)

    while $counter > 0 {
        print $"($resources)\nWaiting for remaining (ansi green_bold)($counter)(ansi reset) managed resources to be (ansi green_bold)removed(ansi reset)...\n"
        sleep 10sec
        $resources = (do $command)
        $counter = ($resources | wc -l | into int)
    }

}

def "main publish crossplane" [
    package: string
    --sources = ["compositions"]
    --version = ""
] {

    mut version = $version
    if $version == "" {
        $version = $env.VERSION
    }

    package generate --sources $sources

    up login --token $env.UP_TOKEN

    up xpkg build --package-root package --output $"($package).xpkg"

    (
        up xpkg push
            $"xpkg.upbound.io/($env.UP_ACCOUNT)/dot-($package):($version)"
    )

    rm --force $"package/($package).xpkg"

    open config.yaml
        | upsert spec.package $"xpkg.upbound.io/devops-toolkit/dot-($package):($version)"
        | save config.yaml --force

}

def "package generate" [
    --sources = ["compositions"]
] {

    for source in $sources {
        kcl run $"kcl/($source).k" |
            save $"package/($source).yaml" --force
    }

}

def "main apply crossplane-providerconfig" [
    provider: string,
    --google-project-id: string,
] {

    if $provider == "google" {

        {
            apiVersion: "gcp.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: "default" }
            spec: {
                projectID: $google_project_id
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "gcp-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "aws" {

        {
            apiVersion: "aws.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: Secret
                    secretRef: {
                        namespace: crossplane-system
                        name: aws-creds
                        key: creds
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "azure" {

        {
            apiVersion: "azure.m.upbound.io/v1beta1"
            kind: "ClusterProviderConfig"
            metadata: { name: default }
            spec: {
                credentials: {
                    source: "Secret"
                    secretRef: {
                        namespace: "crossplane-system"
                        name: "azure-creds"
                        key: "creds"
                    }
                }
            }
        } | to yaml | kubectl apply --filename -

    }

}

def "apply db-provider" [
    provider: string
] {

    if $provider == "google" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-gcp-sql" }
            spec: { package: "xpkg.crossplane.io/crossplane-contrib/provider-gcp-sql:v1.14.0" }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "aws" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-aws-rds" }
            spec: { package: "xpkg.crossplane.io/crossplane-contrib/provider-aws-rds:v1.23.0" }
        } | to yaml | kubectl apply --filename -

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-aws-ec2" }
            spec: { package: "xpkg.crossplane.io/crossplane-contrib/provider-aws-ec2:v1.23.0" }
        } | to yaml | kubectl apply --filename -

    } else if $provider == "azure" {

        {
            apiVersion: "pkg.crossplane.io/v1"
            kind: "Provider"
            metadata: { name: "provider-azure-dbforpostgresql" }
            spec: { package: "xpkg.crossplane.io/crossplane-contrib/provider-azure-dbforpostgresql:v1.13.0" }
        } | to yaml | kubectl apply --filename -

    }
}


# Waits for all Crossplane providers to be deployed and healthy
def "wait crossplane" [] {

    print $"\n(ansi green_bold)Waiting for Crossplane providers to be deployed...(ansi reset)\n"

    sleep 60sec

    (
        kubectl wait
            --for=condition=healthy provider.pkg.crossplane.io
            --all --timeout 30m
    )

}

def "setup google" [] {

    mut project_id = ""

    print $"\nInstalling (ansi green_bold)Crossplane Google Cloud Provider(ansi reset)...\n"

    if PROJECT_ID in $env {
        $project_id = $env.PROJECT_ID
    } else {

        gcloud auth login

        $project_id = $"dot-(date now | format date "%Y%m%d%H%M%S")"
        $env.PROJECT_ID = $project_id
        $"export PROJECT_ID=($project_id)\n" | save --append .env

        gcloud projects create $project_id

        start $"https://console.cloud.google.com/billing/enable?project=($project_id)"

        print $"
Select the (ansi yellow_bold)Billing account(ansi reset) and press the (ansi yellow_bold)SET ACCOUNT(ansi reset) button.
Press the (ansi yellow_bold)enter key(ansi reset) to continue.
"
        input

    }

    let sa_name = "devops-toolkit"

    let sa = $"($sa_name)@($project_id).iam.gserviceaccount.com"

    let project = $project_id

    do --ignore-errors {(
        gcloud iam service-accounts create $sa_name
            --project $project
    )}

    mut attempts = 0
    loop {
        let result = (
            gcloud iam service-accounts describe $sa --project $project
                | complete
        )
        if $result.exit_code == 0 { break }
        if $attempts >= 30 {
            error make { msg: $"Service account ($sa) did not become available in time" }
        }
        print $"Waiting for service account (ansi green_bold)($sa)(ansi reset) to propagate..."
        sleep 2sec
        $attempts = $attempts + 1
    }

    (
        gcloud projects add-iam-policy-binding
            --role roles/owner $project
            --member $"serviceAccount:($sa)"
    )

    (
        gcloud iam service-accounts keys
            create gcp-creds.json --project $project
            --iam-account $sa
    )

    (
        kubectl --namespace crossplane-system
            create secret generic gcp-creds
            --from-file creds=./gcp-creds.json
    )

    { project_id: $project }

}

def "setup aws" [] {

    print $"\nInstalling (ansi green_bold)Crossplane AWS Provider(ansi reset)...\n"

    if AWS_ACCESS_KEY_ID not-in $env {
        $env.AWS_ACCESS_KEY_ID = input $"(ansi yellow_bold)Enter AWS Access Key ID: (ansi reset)"
    }
    $"export AWS_ACCESS_KEY_ID=($env.AWS_ACCESS_KEY_ID)\n"
        | save --append .env

    if AWS_SECRET_ACCESS_KEY not-in $env {
        $env.AWS_SECRET_ACCESS_KEY = input $"(ansi yellow_bold)Enter AWS Secret Access Key: (ansi reset)" --suppress-output
        print ""
    }
    $"export AWS_SECRET_ACCESS_KEY=($env.AWS_SECRET_ACCESS_KEY)\n"
        | save --append .env

    mut credentials = $"[default]
aws_access_key_id = ($env.AWS_ACCESS_KEY_ID)
aws_secret_access_key = ($env.AWS_SECRET_ACCESS_KEY)
"
    if ("AWS_SESSION_TOKEN" in $env) and ($env.AWS_SESSION_TOKEN | is-not-empty) {
        $credentials = $"($credentials)aws_session_token = ($env.AWS_SESSION_TOKEN)\n"
    }
    $credentials | save aws-creds.conf --force

    main apply aws_credentials

}

# Applies an AWS credentials Secret for a Crossplane provider.
# Credentials must already be in the environment, for example from `main get creds`.
#
# Examples:
# > main apply aws_credentials
# > main apply aws_credentials --key credentials --secret-name aws-creds
def "main apply aws_credentials" [
    --namespace = "crossplane-system"
    --secret-name = "aws-creds"
    --key = "creds"
] {

    if ("AWS_ACCESS_KEY_ID" not-in $env) or ("AWS_SECRET_ACCESS_KEY" not-in $env) {
        error make {msg: "Retrieve AWS credentials before applying the provider Secret."}
    }
    if ($env.AWS_ACCESS_KEY_ID | is-empty) or ($env.AWS_SECRET_ACCESS_KEY | is-empty) {
        error make {msg: "AWS access key ID and secret access key must not be empty."}
    }

    mut credentials = $"[default]\naws_access_key_id = ($env.AWS_ACCESS_KEY_ID)\naws_secret_access_key = ($env.AWS_SECRET_ACCESS_KEY)\n"
    mut data = {
        accessKeyID: $env.AWS_ACCESS_KEY_ID
        secretAccessKey: $env.AWS_SECRET_ACCESS_KEY
    }
    if ("AWS_SESSION_TOKEN" in $env) and ($env.AWS_SESSION_TOKEN | is-not-empty) {
        $credentials = $"($credentials)aws_session_token = ($env.AWS_SESSION_TOKEN)\n"
        $data = ($data | upsert sessionToken $env.AWS_SESSION_TOKEN)
    }
    $data = ($data | upsert $key $credentials)

    {
        apiVersion: "v1"
        kind: "Secret"
        metadata: {name: $secret_name namespace: $namespace}
        type: "Opaque"
        stringData: $data
    } | to yaml | kubectl apply --filename -
    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: "Could not apply the AWS provider credentials Secret."}
    }

}

def "setup azure" [
    --skip-login = false
] {

    print $"\nInstalling (ansi green_bold)Crossplane Azure Provider(ansi reset)...\n"

    mut azure_tenant = ""
    if AZURE_TENANT not-in $env {
        $azure_tenant = input $"(ansi yellow_bold)Enter Azure Tenant: (ansi reset)"
    } else {
        $azure_tenant = $env.AZURE_TENANT
    }
    $"export AZURE_TENANT=($azure_tenant)\n" | save --append .env

    if $skip_login == false { az login --tenant $azure_tenant }

    let subscription_id = (az account show --query id -o tsv)

    (
        az ad sp create-for-rbac --sdk-auth --role Owner
            --scopes $"/subscriptions/($subscription_id)"
            | save azure-creds.json --force
    )

    (
        kubectl --namespace crossplane-system
            create secret generic azure-creds
            --from-file creds=./azure-creds.json
    )

}
