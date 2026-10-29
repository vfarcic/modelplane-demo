#!/usr/bin/env nu

# Modelplane-demo-specific orchestration. Generic helpers come from nu-scripts.
const MODELPLANE_ROOT = path self | path dirname | path dirname
const MODELPLANE_STATE = $MODELPLANE_ROOT | path join ".modelplane-state.json"
const CONTROL_PLANE_ZONE = "us-east1-b"

def "modelplane state" [] {
    if not ($MODELPLANE_STATE | path exists) { error make {msg: "No saved run. Execute ./dot.nu setup first."} }
    open $MODELPLANE_STATE
}

def "modelplane manifest" [name: string] {
    let state = (modelplane state)
    $MODELPLANE_ROOT | path join $state.provider $name
}

def "main check" [--provider = "aws"] {

    for tool in [docker kind helm kubectl curl] {
        if (which $tool | is-empty) {
            error make {msg: $"Missing required tool: ($tool). Enter devbox shell first."}
        }
    }
    if $provider == "google" and (which gcloud | is-empty) {
        error make {msg: "Missing gcloud. Enter devbox shell first."}
    }
    main run command docker ["info" "--format" "Docker server: {{.ServerVersion}}"]
    main run command kind ["version"]
    main run command helm ["version" "--short"]
    main run command kubectl ["version" "--client"]

}

def --env "modelplane context" [] {

    cd $MODELPLANE_ROOT
    let state = (modelplane state)
    $env.PROVIDER = $state.provider
    $env.KUBECONFIG = $MODELPLANE_ROOT | path join "kubeconfig-modelplane.yaml"
    let expected = if ($state.control_plane? | default "kind") == "gke" {
        $"gke_($state.project_id)_($CONTROL_PLANE_ZONE)_modelplane"
    } else { "kind-modelplane" }
    let context = (main capture command kubectl ["config" "current-context"])
    if $context != $expected {
        error make {msg: $"Expected ($expected) in ($env.KUBECONFIG); found ($context)."}
    }

}

def --env "main apply modelplane" [] {

    modelplane context
    print $"\n(ansi green_bold)Installing Modelplane v0.5.0...(ansi reset)\n"
    main run command kubectl ["apply" "--filename" "modelplane.yaml"]
    main run command kubectl ["wait" "configuration/modelplane" "--for=condition=Healthy" "--timeout=15m"]
    for crd in [
        inferenceclasses.modelplane.ai
        inferenceclusters.modelplane.ai
        inferencegateways.modelplane.ai
        modeldeployments.modelplane.ai
        modelservices.modelplane.ai
        modelreplicas.modelplane.ai
        modelendpoints.modelplane.ai
    ] {
        main run command kubectl ["wait" "--for=create" $"crd/($crd)" "--timeout=10m"]
        main run command kubectl ["wait" "--for=condition=Established" $"crd/($crd)" "--timeout=5m"]
    }
    let namespace = (main capture command kubectl ["create" "namespace" "a-team" "--dry-run=client" "--output" "yaml"])
    $namespace | kubectl apply --filename -
    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: "Could not prepare the a-team namespace."}
    }

}

def --env "main configure modelplane_provider" [] {
    modelplane context
    let state = (modelplane state)
    let group = if $state.provider == "aws" { "aws" } else { "gcp" }
    let crd = $"crd/clusterproviderconfigs.($group).m.upbound.io"
    main run command kubectl ["wait" "--for=create" $crd "--timeout=10m"]
    main run command kubectl ["wait" "--for=condition=Established" $crd "--timeout=5m"]
    if $state.provider == "aws" {
        main apply aws_credentials --key credentials
        main run command kubectl ["apply" "--filename" (modelplane manifest "config.yaml")]
    } else {
        main apply google_credentials ($MODELPLANE_ROOT | path join "gcp-creds.json")
        let config = (open (modelplane manifest "config.yaml") | upsert spec.projectID $state.project_id)
        $config | to yaml | kubectl apply --filename -
        if $env.LAST_EXIT_CODE != 0 { error make {msg: "Could not configure the GCP provider."} }
    }
}

def --env "main prepare modelplane_fleet" [] {

    modelplane context
    print $"\n(ansi green_bold)Provisioning the ($env.PROVIDER) GPU fleet...(ansi reset)\n"
    main run command kubectl ["apply" "--filename" (modelplane manifest "cluster-classes.yaml")]
    main run command kubectl ["apply" "--filename" (modelplane manifest "clusters.yaml")]
    main run command kubectl ["wait" "--filename" (modelplane manifest "clusters.yaml") "--for=condition=Ready" "--timeout=45m"]
    main run command kubectl ["get" "inferenceclusters"]

}

def --env "main prepare modelplane_gateway" [] {

    modelplane context
    print $"\n(ansi green_bold)Preparing the inference gateway...(ansi reset)\n"
    main run command kubectl ["apply" "--filename" (modelplane manifest "inference-gateway.yaml")]
    main run command kubectl ["wait" "inferencegateway/default" "--for=condition=Ready" "--timeout=15m"]

}

def "modelplane gateway_url" [] {

    let address = (main capture command kubectl [
        "get" "inferencegateway" "default" "--output" "jsonpath={.status.endpoints.openAI}"
    ])
    if ($address | is-empty) {
        error make {msg: "The inference gateway has no OpenAI base URL."}
    }
    $address

}

# Checks readiness and laptop-to-gateway connectivity without deploying a model.
def --env "main verify" [] {

    modelplane context
    main run command kubectl ["wait" "configuration/modelplane" "--for=condition=Healthy" "--timeout=1m"]
    main run command kubectl ["wait" "--filename" (modelplane manifest "clusters.yaml") "--for=condition=Ready" "--timeout=1m"]
    main run command kubectl ["wait" "inferencegateway/default" "--for=condition=Ready" "--timeout=1m"]
    main run command kubectl ["get" "inferenceclasses,inferenceclusters,inferencegateways"]
    let address = (modelplane gateway_url)
    let health = ($address | str replace --regex '/v1$' '/healthz')
    main wait http $health
    print $"\nSetup ready. OpenAI base URL: ($address)"

}

# Sends an ordinary OpenAI chat-completions request through the fleet gateway.
def --env "main query" [] {

    modelplane context
    let address = (modelplane gateway_url)
    let request = {
        model: "a-team/qwen"
        messages: [{role: "user" content: "What is Crossplane in one sentence?"}]
        max_tokens: 100
    } | to json --raw
    let response = (main capture command curl [
        "--fail" "--silent" "--show-error" "--connect-timeout" "10" "--max-time" "180"
        $"($address)/chat/completions" "--header" "Content-Type: application/json" "--data" $request
    ] | from json)
    if (($response | get choices? | default [] | length) == 0) {
        error make {msg: "The gateway did not return a completion."}
    }
    $response | to json

}

def --env "main delete modelplane_fleet" [] {

    modelplane context
    print $"\n(ansi green_bold)Removing models, gateway, and cloud resources...(ansi reset)\n"
    main run command kubectl ["--namespace" "a-team" "delete" "modelservices" "--all" "--cascade=foreground" "--timeout=15m"]
    main run command kubectl ["--namespace" "a-team" "delete" "modeldeployments" "--all" "--cascade=foreground" "--timeout=30m"]
    main run command kubectl ["--namespace" "a-team" "delete" "modelcaches" "--all" "--cascade=foreground" "--timeout=30m"]
    main run command kubectl ["delete" "--filename" (modelplane manifest "inference-gateway.yaml") "--ignore-not-found" "--cascade=foreground" "--timeout=20m"]
    main run command kubectl ["delete" "--filename" (modelplane manifest "clusters.yaml") "--ignore-not-found" "--cascade=foreground" "--timeout=60m"]
    main wait crossplane_cleanup --namespace modelplane-system

}
