# Temporary Phalanx Vault instance

When doing some kinds of maintenance on the [Phalanx](https://phalanx.lsst.io) cluster that a [Vault](https://developer.hashicorp.com/vault) instance is provisioned in, like a full cluster rebuild, there needs to be a Vault instance accessible outside of the cluster.
For [Google Kubernetes Engine](https://cloud.google.com/kubernetes-engine) (GKE) clusters that use [Google Cloud Storage](https://cloud.google.com/storage) (GCS) as a backend and [Google Cloud Key Management](https://cloud.google.com/security/products/security-key-management) (GCKM) for sealing, we can quickly provision and destroy a Vault instance using a copy of the existing storage.
This repo contains Terraform config to do this for the [roundtable-prod](https://phalanx.lsst.io/environments/roundtable-prod/index.html) and [roundtable-dev](https://phalanx.lsst.io/environments/roundtable-dev/index.html) clusters.

> [!WARNING]
> This is only useful for read-only use cases for the temp Vault instance.
> No changes to the Vault will persist to the permanent instance.

## Runbook

Follow these steps to provision and use the temp Vault instance.

### Copy the storage

In the `roundtable-dev` and `roundtable-prod` Google Cloud accounts, there is a [Google Storage Transfer Service](https://cloud.google.com/storage-transfer-service) job with the description `Temporary copy of Vault Server storage`.
This job will copy the contents of the vault instance GCS bucket to another bucket, `rubin-us-central1-vault-server-dev-temp` or ``rubin-us-central1-vault-server-temp`` depending on which account you're in.
We will point our temp Vault instance against this copy so that we don't accidentally corrupt the real Vault instance's storage.

Manually start a run of this job.

### Deactivate the Cloud Run Invoker organization policy

We are going to provision a [Google Cloud Run](https://cloud.google.com/run) service to run our temp Vault instance.
In order to make it publicly accessible, we need to disable the `run-managed.requireInvokerIam` organization policy.
We'll re-activate it after we destroy the temp Vault instance.
If we don't do this, then every request to the temp Vault instance would have to include a Google Cloud authorization token in a header.
The temp Vault instance will have the same authentication and authorization configuration as the main Vault instance.

### Prepare your local machine

This repo contains [mise](https://mise.jdx.dev/) config to install all necessary tooling locally.
If you have mise installed, run `mise install`.
If you don't use mise, make sure you have all of the versions and tools in the [mise.lock](mise.lock) file installed and on your `PATH`.

### Provision the temp Vault instance

Next, provision the temp Vault instance using the simple (ha!) Terraform config in [main.tf](main.tf).
This will provision a Google Cloud Run service behind a load balancer with a public IP address and a TLS cert that matches the existing Vault domain.


> [!WARNING]
> This will store the terraform state on your computer in this directory in `.tfstate` files.
> Do not delete these files or else you will not be able to cleanly destroy this infrastructure when you're done.

```console
$ terraform init

# This will ask for confirmation
$ terraform apply -var-file=roundtable-<env>.tfvars
```

### Configure DNS

The above apply command will output the public IP address of the temp vault instance, and a DNS record to add to verify the domain for the TLS cert on the load balancer.
It will look something like this for `roundtable-dev` (the DNS record will have a different domain for `roundtable-prod`):

```
cert_dns = tolist([
  {
    "data" = "42193330-cef6-4005-a233-5fc280918e7b.9.authorize.certificatemanager.goog."
    "name" = "_acme-challenge_n23hcu3tq76tyc7i.vault-dev.lsst.cloud."
    "type" = "CNAME"
  },
])
ip_address = "35.201.105.189"
```

#. In Route53, add the  `CNAME` record from the `cert_dns` output from the Terraform apply
#. Go to the [certificate list](https://console.cloud.google.com/security/ccm/list/certificates) in Google Cloud and wait for the Status of the `vault-temp` certificate to be `active`
#. In Route53, record the details of the current `vault-dev.lsst.org` or `vault.lsst.org` record
#. Change the `vault-dev.lsst.org` or `vault.lsst.org` record to be an `A` record with the value of the `ip_address` output from the Terraform apply

Wait for DNS to propagate, and then you should be able to access the temp Vault server.

### Clean up

When you no longer need the temp Vault instance, clean up by:

#. In Route53, delete the Google certificate manager `CNAME` verification record
#. In Route53, change the `vault-dev.lsst.org` or `vault.lsst.org` record to be the value your recorded earlier
#. Run `terraform apply -destroy -var-file=roundtable-<env>.tfvars`

## Development

This repo has a GitHub action for some basic Terraform linting.
If you want to run the lint yourself:

```console
# This will install all of the necessary dependencies, like tflint
$ mise -E dev install

$ mise -E dev run lint
```
