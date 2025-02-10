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

## License

Files in this repository are licensed under CC0 1.0 Universal, see [LICENSE.md](LICENSE.md) for more information.

## Scoop Bucket Review TODO

There are many, many scoop buckets out there - some with thousands of applications. It's unrealistic to have full coverage but any application I use should be packaged into this format and some of the think regarding auto-updating, etc. may have already been done, so look to example buckets for references and ideas.

This is a good way to have periodic tool discovery since the software space changes regularly.

NOTE: a lot of buckets are for purposes like Chinese proxy evasion or translated or non-commercial safe licences so please be careful in what is used and always inspect the base .json file and source of executables.

### Buckets to review

- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Fzzhaq%2Fscoop-av%22&o=false> - lots of .exe and decompilation resources
- <https://scoop.sh/#/apps?q=%22https%3A%2F%2Fgithub.com%2Frizwan-r-r%2Fredesigned-fiesta%22&o=false> - development tools
