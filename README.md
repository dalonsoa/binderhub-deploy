# binderhub-deploy

A set of scripts to automatically deploy a [BinderHub](https://binderhub.readthedocs.io/en/latest/index.html) onto [Microsoft Azure](https://azure.microsoft.com/en-gb/).

**List of scripts:**
* [**setup.sh**](#setup)
* [**deploy.sh**](#deploy)
* [**info.sh**](#info)
* [**logs.sh**](#logs)
* [**teardown.sh**](#teardown)

## Usage

Create a file called `config.json` which has the following format.
Fill the values with your desired namespaces, etc.
(Note that `#` tokens won't be permitted in the actual JSON file.)

```
{
  "azure": {
    "subscription": "",  # Azure subscription name
    "res_grp_name": "",  # Azure Resource Group name
    "location": "",      # Azure Data Centre location
    "cluster_name": "",  # Kubernetes cluster name
    "node_count": "",    # Number of nodes to deploy
    "vm_size": ""        # Azure virtual machine type to deploy
  },
  "binderhub": {
    "name": "",          # Name of you BinderHub
    "version": ""        # Helm chart version to deploy
  },
  "docker": {
    "id": "",            # DockerHub ID
    "org": null,         # The DockerHub organisation id belongs to (if necessary)
    "image_prefix": ""   # The prefix to preprend to Binder images (e.g. "binder-dev")
  },
  "secretFile": null     # Path to file containing DockerHub password (script will look for ~/.secret/BinderHub.json if left as null)
}
```

A `~/.secret` folder should also be created containing a `BinderHub.json` file with the following config.
The path to this file should be added to `secretFile` in `config.json`.
If this field is left as null, the script will look for `~/.secret/BinderHub.json` instead.

```
{
  "password": "<dockerhub-password>"  # DockerHub password to match id in config.json
}
```

---

<a name="setup"></a>
### setup.sh

This script uses [`curl`](https://curl.haxx.se/docs/) to install command line interfaces (CLIs) for Microsoft Azure (`azure-cli`), Kubernetes (`kubectl`) and Helm (`helm`).
The script will ask you to enter a passphrase when the SSH keys are being generated - this can be left blank.

Command line install scripts were found in the following documentation:
* [Azure-CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?view=azure-cli-latest#install-or-update)
* [Kubernetes-CLI](https://kubernetes.io/docs/tasks/tools/install-kubectl/#install-kubectl-binary-using-curl) (macOS version)
* [Helm-CLI](https://helm.sh/docs/using_helm/#from-script)

<a name="deploy"></a>
### deploy.sh

This script reads in `config.json` using `read_config.py`, then creates `config.yaml` and `secret.yaml` files via `create_config.py` and `create_secret.py` respectively (using `config-template.yaml` and `secret-template.yaml`).
Both a JupyterHub and BinderHub are installed and the `config.yaml` file is updated with the JupyterHub IP address.

<a name="info"></a>
### info.sh

The script will print the IP addresses of both the JupyterHub and the BinderHub to the terminal.
It reads the BinderHub name from `config.json` using `read_config.py`.

<a name="logs"></a>
### logs.sh

This script will print the JupyterHub logs to the terminal for debugging.
It reads `config.json` via `read_config.py` in order to get the BinderHub name.
It then finds the pod the JupyterHub is deployed on and calls the logs.

<a name="teardown"></a>
### teardown.sh

This script will purge the Helm release, delete the Kubernetes namespace and then delete the Azure Resource Group containing the computational resources.
The user should check the [Azure Portal](https://portal.azure.com/#home) to verify the resources have been deleted.
