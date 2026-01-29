# Personal Scoop

A [Scoop](https://scoop.sh/) bucket for tools used for personal or non-commercial purposes. This project is a chimera of personal productivity and media tools, games and other ephemera. Some of the installers may be staged in corporate repositories, even if the licence is such that only licence-bearing users or usage may take place. This is to more cleanly separate from open-source and internal tools.

## Usage

After installing [Scoop](https://scoop.sh/), enter the following line in a Command Prompt or PowerShell window:

```powershell
scoop bucket add <TBD>
```

Once this is done, you can install any app from this bucket.

For instance, use the following command:

```powershell
# Don't include the .json file extension in the app name
scoop install freeorion
```

## Adding applications in this bucket

To add an application to this bucket, create a manifest file in JSON format and place it in the `bucket` directory. You can refer to the [Scoop Wiki](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) for detailed information on the manifest schema and guidelines.

Additionally, add in the customised metadata under the "##" comment section to allow for future maintenance and updating. This can be done manually, or by using the `Seed-ManifestSources.ps1` script provided in this repository.

The `Add-Manifest.ps1` script provides a convenient way to add new manifests to the bucket. It handles tasks such as validating the manifest, adding the necessary metadata, and committing the changes to the repository. It requires a source Scoop repository to contain the original manifest locally to be able to reference.

## Updating applications in this bucket

For manifests that contain an `autoupdate` section, there may be a GitHub Actions workflow that runs every day and commits updated manifests to the repository.

NOTE: this is dependent on repo configuration.

For manifests that don't contain an `autoupdate` section, you can also [add an `autoupdate` section to the manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifest-Autoupdate) to ensure the application always remains up-to-date in the future.

## Maintaining the versions

Since we don't want these to become very out of date, but don't want to actively manage this, we have a need to create a self-defined meta-structure in the manifests which we will use to maintain these effectively.

These are supported by two scripts:

- `Seed-ManifestSources.ps1` which we can use to initially seed the enriched manifests from the local locations where they may be found.

- `Update-Bucket.ps1` which uses this structure and keeps them up to date to ensure we can periodically update all references en masse, keeping it usable.

These should provide a simplified surface to allow regular automated invocation if we desire.

### Initialising Repository Using Seed-ManifestSources

This script builds up the initial data structures from local repos. It has several helper features as the exact schema extension I added went through a few evolutions and I used this with AI assistance to the script to keep it maintained. It can also be used to cleanup certain problems like duplicate empty nodes under comments.

Ideally after running the first time in a repo it's not needed again unless we're changing format.

This utilised the local file `local-repos.cfg` which has a special format of lines with:

```propertieshell
<local-path>;<url-to-raw-manifest-base>
```

This essentially allows us to map local paths to the web locations of the manifests for future reference. This is the extent of the expected source information to be contained in all manifests in this bucket.

### Maintaining A Repository Using Update-Bucket.ps1

Once an repository has been initialised, this script  is what ought to be run periodically and shouldn't need arguments by default. However if it's the first time running for a while, the `-Interactive` option allows a little more surety in the validity of the changes to make.

Standard usage:

```powershell
# Runs all updates automatically
.\Update-Bucket.ps1
```

Interactive usage for checking behaviour:

```powershell
# Runs with interactive prompts
.\Update-Bucket.ps1 -Interactive
```

Full forced updates of everything with limited checks (but still showing diffs and excluding "locked" and "manual" manifests):

```powershell
.\Update-Bucket.ps1 -FullUpdate
```

### Metadata

We've introduced several new metadata concepts under the over-arching "##" free-range comment, which unfortunately may only be a String or Array of Strings and still conform to the JSON schema for Scoop. To avoid potential future compatibility issues, we stick to this.

- source: where one may find the file locally. This is not very portable but without making shadow structures outside the main repository, which is a lot of additional material for little gain, just serves as a short-cut for locally cloned and maintained repos.
- sourceUrl: the ultimate web-accessible location for the manifest; typically the raw file on GitHub.
- sourceLastUpdated: the date of last modification to the manifest.
- sourceLastChangeFound: when we last ran the script and detected a change to be applied.
- sourceState: one of a number of states. 'active' means in regular use. 'dead' means ignored. 'manual' means there is no upstream to serve as a reference so all changes must be manually made. 'frozen' means the detected upstream changes have some aspect meaning we don't want to rely on automatic installation and it must be subject to manual update decisions.
- sourceHash: a hash of the upstream manifest file at the time of last update, to detect changes. This is particularly needed as Git can be wildly inefficient, and the Git log can take an inordinately long time for large repositories with many commits and manifests that haven't changed in a long time (for example, `vagrant-manager.json` in Scoop Main takes me 53s to find the last commit date on the file, locally).
- sourceDelayDays: (optional) how many days to wait after an upstream modification is found before it's applied. {NB: Might need more testing over time especially for high-churn upstreams}.
- sourceUpdateMinimumDays: (optional) after we have had an update to this script, as defined in 'sourceLastChangeFound', don't apply any updates for at least this many days.
- sourceComment: (optional) any additional comments, mostly used for explaining unusual provenance of freezing status.

#### Example Metadata

As an example of how these fully materialised metadata entries look, here is the `bitwarden.json` manifest from the [Scoop Extras](https://github.com/ScoopInstaller/Extras) repository.

```json
  "##": [
    "sourceLastChangeFound: 260128 15:32:50",
    "sourceHash: 8a55111ed3b27930d29947bdb445723d3c397e2d",
    "sourceUrl: https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/bitwarden.json",
    "sourceLastUpdated: 260113 20:30:03",
    "sourceState: active",
    "source: D:\\dev\\src\\third-party\\scoop-extras\\bucket\\bitwarden.json"
  ]
```

## License

Files in this repository are licensed under CC0 1.0 Universal, see [LICENSE.md](LICENSE.md) for more information.

## Scoop Bucket Review TODO

There are many, many scoop buckets out there - some with thousands of applications. It's unrealistic to have full coverage but any application I use should be packaged into this format and some of the think regarding auto-updating, etc. may have already been done, so look to example buckets for references and ideas.

This is a good way to have periodic tool discovery since the software space changes regularly.

NOTE: a lot of buckets are for purposes like Chinese proxy evasion or translated or non-commercial safe licences so please be careful in what is used and always inspect the base `.json` file and source of executables.

### Buckets to review

- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Fzzhaq%2Fscoop-av%22&o=false> - lots of .exe and decompilation resources
- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Frizwan-r-r%2Fredesigned-fiesta%22&o=false> - development tools

## Disclaimer

No warranty or guarantee of any nature is provided or implied. No liability will be incurred for use of any material in this repository. Use at your own risk. Scoop inherently trusts the sources of the manifests and their contents; ensure you validate these before use. Be aware that versions may change and software may become unsupported or insecure over time, both maliciously and accidentally.
