#!/usr/bin/env nu

# Creates an isolated project with a unique ID for a new demo run.
# Consumers source common.nu for checked external-command helpers.
def --env "main create google_project" [
    --prefix = "dot"
    --billing-account = ""
    --state-file = ""  # Persist ownership before billing/API setup can fail
] {

    if not ($prefix =~ '^[a-z][a-z0-9-]{0,9}$') {
        error make {msg: "Project prefix must be lowercase and at most ten characters."}
    }
    let project = $"($prefix)-(date now | format date '%Y%m%d%H%M%S')-(random chars --length 4 | str lowercase)"
    mut billing = $billing_account
    if ($billing | is-empty) {
        let accounts = (main capture command gcloud ["billing" "accounts" "list" "--filter" "open=true" "--format" "value(name)"] | lines)
        if ($accounts | is-empty) {
            error make {msg: "No open billing account found. Pass --billing-account."}
        }
        if ($accounts | length) > 1 {
            error make {msg: "Multiple billing accounts found. Pass --billing-account to select one."}
        }
        $billing = ($accounts | first)
    }
    print $"Creating unique project ($project)..."
    main run command gcloud ["projects" "create" $project]
    if ($state_file | is-not-empty) {
        let state = if ($state_file | path exists) { open $state_file } else { {} }
        $state | upsert project_id $project | upsert project_created true | to json | save --force $state_file
    }
    # Save the ID before subsequent steps so a failed setup can be cleaned up.
    $env.PROJECT_ID = $project
    $"export PROJECT_ID=($project)\n" | save --append .env
    main run command gcloud ["billing" "projects" "link" $project "--billing-account" $billing]
    main run command gcloud [
        "services" "enable" "container.googleapis.com" "compute.googleapis.com"
        "iam.googleapis.com" "cloudresourcemanager.googleapis.com"
        "serviceusage.googleapis.com" "file.googleapis.com" "--project" $project
    ]
    $project

}

# Creates provider credentials scoped to a project instead of granting Owner.
# Reuses the local key on retries and returns its path without printing its data.
def "main create google_credentials" [
    project: string
    --service-account = "crossplane"
    --key-file = "gcp-creds.json"
] {

    let account = $"($service_account)@($project).iam.gserviceaccount.com"
    let existing = (gcloud iam service-accounts describe $account --project $project | complete)
    if $existing.exit_code != 0 {
        main run command gcloud ["iam" "service-accounts" "create" $service_account "--project" $project]
    }
    mut attempts = 0
    loop {
        let ready = (gcloud iam service-accounts describe $account --project $project | complete)
        if $ready.exit_code == 0 { break }
        if $attempts >= 30 { error make {msg: $"Service account ($account) did not become available."} }
        sleep 2sec
        $attempts = $attempts + 1
    }
    for role in [
        roles/container.admin
        roles/compute.admin
        roles/serviceusage.serviceUsageAdmin
        roles/iam.serviceAccountAdmin
        roles/iam.serviceAccountKeyAdmin
        roles/iam.serviceAccountUser
        roles/resourcemanager.projectIamAdmin
    ] {
        main run command gcloud [
            "projects" "add-iam-policy-binding" $project
            "--member" $"serviceAccount:($account)" "--role" $role "--condition=None" "--quiet" "--format=none"
        ]
    }
    if ($key_file | path exists) {
        let key = (open $key_file)
        if $key.project_id != $project or $key.client_email != $account {
            error make {msg: "Existing credential file belongs to a different project or account."}
        }
    } else {
        main run command gcloud ["iam" "service-accounts" "keys" "create" $key_file "--iam-account" $account "--project" $project]
    }
    $key_file | path expand

}

# Uploads a JSON service-account key to a Crossplane credential Secret.
def "main apply google_credentials" [
    key_file: string
    --namespace = "crossplane-system"
    --secret-name = "gcp-creds"
    --key = "credentials"
] {

    let data = ({} | upsert $key (open --raw $key_file))
    {
        apiVersion: "v1"
        kind: "Secret"
        metadata: {name: $secret_name namespace: $namespace}
        type: "Opaque"
        stringData: $data
    } | to yaml | kubectl apply --filename -
    if $env.LAST_EXIT_CODE != 0 { error make {msg: "Could not upload Google provider credentials."} }

}

# Deletes only a caller-specified demo project and waits for DELETE_REQUESTED.
def "main delete google_project" [project: string] {

    main run command gcloud ["projects" "delete" $project "--quiet"]
    let result = (main capture command gcloud ["projects" "describe" $project "--format" "value(lifecycleState)"])
    if $result != "DELETE_REQUESTED" {
        error make {msg: $"Project ($project) is not marked for deletion: ($result)."}
    }

}
