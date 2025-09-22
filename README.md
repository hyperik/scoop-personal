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

## Updating applications in this bucket

For manifests that contain an `autoupdate` section, there's a GitHub Actions workflow that runs every day and commits updated manifests to the repository.

For manifests that don't contain an `autoupdate` section, you can also [add an `autoupdate` section to the manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifest-Autoupdate) to ensure the application always remains up-to-date in the future.

## Maintaining the versions

Since we don't want these to become very out of date, but don't want to actively manage this, we have a need to create a self-defined meta-structure in the manifests which we will use to maintain these effectively.

These are supported by two scripts `Seed-ManifestSources.ps1` which we can use to initially seed the enriched manifests from the local locations where they may be found. And `Update-PersonalBucket.ps1` which uses this structure and keeps them up to date to ensure we can periodically update all references en masse, keeping it usable.

These should provide a simplified surface to allow regular automated invocation if we desire.

### Using Seed-ManifestSources

This script builds up the initial data structures from local repos. It has several helper features as the exact schema extension I added went through a few evolutions and I used this with AI assistance to the script to keep it maintained. It can also be used to cleanup certain problems like duplicate empty nodes under comments.

Ideally after running the first time in a repo it's not needed again unless we're changing format.

### Using Update-PersonalBucket.ps1

This is what ought to be run periodically and shouldn't need arugments by default. However if it's the first time running for a while, the `-Interactive` option allows a little more surety in the validity of the changes to make.

### Metadata

I've introduced several new metadata concepts under the over-arching "##" free-range comment, which unfortunately may only be a String or Array of Strings and still conform to the JSON schema for Scoop. To avoid potential future compatibility issues, we stick to this.

- source: where one may find the file locally. This is not very portable but without making shadow structures outside the main repository, which is a lot of additional material for little gain, just serves as a short-cut for locally cloned and maintained repos.
- sourceUrl: the ultimate web-accessible location for the manifest; typically the raw file on GitHub.
- sourceLastUpdated: the date of last modification to the manifest.
- sourceLastChangeFound: when we last ran the script and detected a change to be applied.
- sourceState: one of a number of states. 'active' means in regular use. 'dead' means ignored. 'manual' means there is no upstream to serve as a reference so all changes must be manually made. 'frozen' means the detected upstream changes have some aspect meaning we don't want to rely on automatic installation and it must be subject to manual update decisions.
- sourceDelayDays: (optional) how many days to wait after an upstream modification is found before it's applied. {NB: Might need more testing over time especially for high-churn upstreams}.
- sourceUpdateMinimumDays: (optional) after we have had an update to this script, as defined in 'sourceLastChangeFound', don't apply any updates for at least this many days.
- sourceComment: (optional) any additional comments, mostly used for explaining unusual provenance of freezing status.

## License

Files in this repository are licensed under CC0 1.0 Universal, see [LICENSE.md](LICENSE.md) for more information.

## Scoop Bucket Review TODO

There are many, many scoop buckets out there - some with thousands of applications. It's unrealistic to have full coverage but any application I use should be packaged into this format and some of the think regarding auto-updating, etc. may have already been done, so look to example buckets for references and ideas.

This is a good way to have periodic tool discovery since the software space changes regularly.

NOTE: a lot of buckets are for purposes like Chinese proxy evasion or translated or non-commercial safe licences so please be careful in what is used and always inspect the base .json file and source of executables.

### Buckets to review

- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Fzzhaq%2Fscoop-av%22&o=false> - lots of .exe and decompilation resources
- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Frizwan-r-r%2Fredesigned-fiesta%22&o=false> - development tools
