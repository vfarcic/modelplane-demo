#!/usr/bin/env nu

# Prompts user to select a cloud provider from available options
#
# Returns:
# The selected provider name and saves it to .env file
def "main get provider" [
    --providers = [aws azure google kind upcloud]  # List of cloud providers to choose from
] {

    let message = $"
Right now, only providers listed below are supported in this demo.
Please send an email to (ansi yellow_bold)viktor@farcic.com(ansi reset) if you'd like to add additional providers.

(ansi yellow_bold)Select a provider(ansi green_bold)"

    let provider = $providers | input list $message
    print $"(ansi reset)"

    $"export PROVIDER=($provider)\n" | save --append .env

    $provider
}

# Runs an external command, preserving progress output and stopping on failure.
# Passing arguments as a list keeps external flags separate from Nu function flags.
def "main run command" [command: string, arguments: list<string> = []] {

    run-external $command ...$arguments
    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: $"Command failed: ($command) ($arguments | str join ' ')"}
    }

}

# Captures an external command's stdout and reports a failed exit status.
def "main capture command" [command: string, arguments: list<string> = []] {

    let result = (run-external $command ...$arguments | complete)
    if $result.exit_code != 0 {
        error make {msg: $"Command failed: ($command) ($arguments | str join ' ')\n($result.stderr)"}
    }
    $result.stdout | str trim

}

# Waits for a newly provisioned HTTP endpoint to become reachable.
# Cloud load balancers can publish an address before traffic is accepted.
def "main wait http" [
    url: string
    --timeout: duration = 5min
    --interval: duration = 5sec
] {

    let deadline = (date now) + $timeout
    loop {
        let result = (
            curl --fail --silent --show-error --connect-timeout 10 --max-time 20 $url
            | complete
        )
        if $result.exit_code == 0 { return $result.stdout }
        if (date now) >= $deadline { error make {msg: $"HTTP endpoint did not become ready: ($url)\n($result.stderr)"} }
        print $"Waiting for HTTP endpoint ($url)..."
        sleep $interval
    }

}

# Prints a reminder to source the environment variables
def "main print source" [] {

    print $"
Execute `(ansi yellow_bold)source .env(ansi reset)` to load the environment variables.
"

}

# Removes temporary files created during script execution
def "main delete temp_files" [] {

    rm --force .env

    rm --force kubeconfig*.yaml

}

# Retrieves and configures credentials for the specified cloud provider
#
# Examples:
# > main get creds aws
# > main get creds azure
def --env "main get creds" [
    provider: string,  # The cloud provider to configure credentials for (aws, azure, google)
    --account-id = true  # Ask for AWS account ID only when the caller needs it
] {

    mut creds = {provider: $provider}

    if $provider == "google" {

        # Only log in when there is no active account. `gcloud auth login` opens
        # a browser unconditionally, which makes re-running setup needlessly
        # interactive when the session is already valid.
        let active = (
            do --ignore-errors {
                gcloud auth list --filter=status:ACTIVE --format="value(account)"
            } | complete
        )

        let token = (gcloud auth print-access-token | complete)
        if ($active.exit_code != 0) or (($active.stdout | str trim) == "") or ($token.exit_code != 0) {
            gcloud auth login
        } else {
            print $"Already authenticated as (ansi yellow_bold)($active.stdout | str trim)(ansi reset)."
        }

    } else if $provider == "aws" {

        mut aws_access_key_id = ""
        if ("AWS_ACCESS_KEY_ID" in $env) and ($env.AWS_ACCESS_KEY_ID | is-not-empty) {
            $aws_access_key_id = $env.AWS_ACCESS_KEY_ID
        } else {
            $aws_access_key_id = input $"(ansi green_bold)Enter AWS Access Key ID: (ansi reset)"
        }
        $"export AWS_ACCESS_KEY_ID=($aws_access_key_id)\n"
            | save --append .env
        $creds = ( $creds | upsert aws_access_key_id $aws_access_key_id )
        $env.AWS_ACCESS_KEY_ID = $aws_access_key_id

        mut aws_secret_access_key = ""
        if ("AWS_SECRET_ACCESS_KEY" in $env) and ($env.AWS_SECRET_ACCESS_KEY | is-not-empty) {
            $aws_secret_access_key = $env.AWS_SECRET_ACCESS_KEY
        } else {
            $aws_secret_access_key = input $"(ansi green_bold)Enter AWS Secret Access Key: (ansi reset)" --suppress-output
            print ""
        }
        $"export AWS_SECRET_ACCESS_KEY=($aws_secret_access_key)\n"
            | save --append .env
        $creds = ( $creds | upsert aws_secret_access_key $aws_secret_access_key )
        $env.AWS_SECRET_ACCESS_KEY = $aws_secret_access_key

        if ("AWS_SESSION_TOKEN" in $env) and ($env.AWS_SESSION_TOKEN | is-not-empty) {
            $"export AWS_SESSION_TOKEN=($env.AWS_SESSION_TOKEN)\n" | save --append .env
            $creds = ($creds | upsert aws_session_token $env.AWS_SESSION_TOKEN)
        }

        if $account_id {
            mut aws_account_id = ""
            if ("AWS_ACCOUNT_ID" in $env) and ($env.AWS_ACCOUNT_ID | is-not-empty) {
                $aws_account_id = $env.AWS_ACCOUNT_ID
            } else {
                $aws_account_id = input $"(ansi green_bold)Enter AWS Account ID: (ansi reset)"
            }
            $"export AWS_ACCOUNT_ID=($aws_account_id)\n" | save --append .env
            $creds = ($creds | upsert aws_account_id $aws_account_id)
            $env.AWS_ACCOUNT_ID = $aws_account_id
        }

    } else if $provider == "azure" {

        mut tenant_id = ""

        if AZURE_TENANT in $env {
            $tenant_id = $env.AZURE_TENANT
        } else {
            $tenant_id = input $"(ansi green_bold)Enter Azure Tenant ID: (ansi reset)"
        }
        $creds = ( $creds | upsert tenant_id $tenant_id )

        az login --tenant $tenant_id
    
    } else {

        print $"(ansi red_bold)($provider)(ansi reset) is not a supported."
        exit 1

    }

    $creds

}
