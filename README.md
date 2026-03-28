# Release Management Recipes

This repository is the home of [Bitrise Release Management]([https://bitrise.io](https://app.bitrise.io/release-management)) Recipes that is maintained by Bitrise itself.
In this continually evolving repository you can find easily usable recipes for interacting with Bitrise Release Management. 

Questions? Visit our [Support Center](https://support.bitrise.io/hc/en-us).


## 🙋 Contributing

We welcome pull requests and issues against this repository.

For pull requests, work on your changes in a forked repository and open a pull request to be merged into this one.

## CodePush signing

`api/upload_code_push_package.sh` supports optional CodePush package signing for zip uploads.

Set `CODE_PUSH_PRIVATE_KEY_PATH` to a PEM-encoded RSA private key file before invoking the script. When present, the script will:

- unpack the zip package,
- generate a CodePush `.codepushrelease` signature file,
- rebuild the zip,
- upload the signed package.

If `CODE_PUSH_PRIVATE_KEY_PATH` is not set, the existing unsigned upload behavior is unchanged.
