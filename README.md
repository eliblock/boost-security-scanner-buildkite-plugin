# Boost Security Scanner BuildKite Plugin

Executes the Boost Security Scanner cli tool to scan repositories for
vulnerabilities and uploads results to the Boost API. This plugin
runs as a post-command hook.

## Example

Add the following to your `pipeline.yml`:

```yml
steps:
  - command: YOUR BUILD COMMAND HERE
    plugins:
      - peaudecastor/boost-security-scanner#v0.1.0:
          api_token: 'TOKEN'
```

## Configuration

### `additional_args` (Optional, list[str])

Additional CLI args to pass to the `boost` cli.

### `api_endpoint` (Optional, string)

Overrides the API endpoint url

### `api_token` (Required, string)

The Boost Security API token

### `docker_create_args` (Optional, string)

Optional additional arguments to pass to `docker create` when preparing the
scanner container.

### `fail_on_error` (Optional, boolean, default=true)

Indicates that the scanner should exit with a non-zero exit status when it
encounters an error or a policy violation.

### `scanner_image` (Optional, string)

Overrides the docker image url to load when performing scans

### `scanner_version` (Optional, string)

Overrides the docker image tag to load when performing scans

### `org_name` (Optional, string)

Overrides the Organization slug when uploading reports to Boost Security.
This will default to the Organization slug defined in BuildKite.

### `repo_name` (Optional, string)

Overrides the Repository slug when uploading reports to Boost Security.
This will default to the Repository slug defined in BuildKite.

## Developing

To run the tests:

```shell
make lint
make tests
```
