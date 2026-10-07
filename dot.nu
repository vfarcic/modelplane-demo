#!/usr/bin/env nu

source scripts/common.nu
source scripts/kubernetes.nu
source scripts/crossplane.nu
source scripts/google.nu
source scripts/modelplane.nu

const CROSSPLANE_VERSION = "2.4.2"
const KIND_IMAGE = "kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"

def main [] {}

# Prepares the complete platform before the talk.
# Modelplane provisions the GPU fleet; the shared helpers prepare its control plane.
#
# Example:
# > ./dot.nu setup
def --env "main setup" [
    provider: string = ""  # aws or google; prompts when omitted
    --resume              # Resume the saved run instead of creating a new project
    --billing-account = ""
] {

    cd $MODELPLANE_ROOT
    let selected = if $resume {
        let state = (modelplane state)
        if ($provider | is-not-empty) and $provider != $state.provider {
            error make {msg: "Cannot change provider while resuming an existing run."}
        }
        $state.provider
    } else {
        if ($MODELPLANE_STATE | path exists) {
            error make {msg: "A run is already recorded. Use setup --resume, or destroy it before starting a fresh run."}
        }
        let choice = if ($provider | is-empty) { main get provider --providers [aws google] } else { $provider }
        if not ($choice in ["aws" "google"]) { error make {msg: "Choose aws or google."} }
        {provider: $choice, project_id: "", project_created: false} | to json | save --force $MODELPLANE_STATE
        $choice
    }
    $env.PROVIDER = $selected
    $"export PROVIDER=($selected)\n" | save --append .env
    main check --provider $selected
    let credentials = (main get creds $selected --account-id false)

    if $selected == "google" {
        let state = (modelplane state)
        let project = if ($state.project_id | is-empty) {
            main create google_project --prefix modelplane --billing-account $billing_account --state-file $MODELPLANE_STATE
        } else { $state.project_id }
        $env.PROJECT_ID = $project
        $"export PROJECT_ID=($project)\n" | save --append .env
        let credential_file = (main create google_credentials $project --service-account modelplane-control)
    }

    print $"\n(ansi green_bold)Preparing the local control plane...(ansi reset)\n"
    (
        main create kubernetes kind --name modelplane --enable-ingress false
            --kind-image $KIND_IMAGE --reuse true
    )
    (
        main apply crossplane --version $CROSSPLANE_VERSION
            --default-activations [] --dependency-version-upgrades true
    )

    main apply modelplane
    main configure modelplane_provider
    main prepare modelplane_fleet
    main prepare modelplane_gateway
    main verify
    main print source

}

# Refreshes provider credentials without rebuilding the platform.
# Example:
# > ./dot.nu credentials
def --env "main credentials" [] {

    modelplane context
    let state = (modelplane state)
    let credentials = (main get creds $state.provider --account-id false)
    main configure modelplane_provider

}

# Removes the cloud resources before removing the local control plane.
# Example:
# > ./dot.nu destroy
def --env "main destroy" [] {

    cd $MODELPLANE_ROOT
    let state = (modelplane state)
    let kubeconfig = ($MODELPLANE_ROOT | path join "kubeconfig-modelplane.yaml")
    if ($kubeconfig | path exists) {
        modelplane context
        main delete modelplane_fleet
        main destroy kubernetes kind --name modelplane
    }
    if $state.provider == "google" and $state.project_created and ($state.project_id | is-not-empty) {
        main delete google_project $state.project_id
    }
    rm --force $MODELPLANE_STATE gcp-creds.json .env kind.yaml
    print "The Modelplane fleet and local control plane have been removed."

}
