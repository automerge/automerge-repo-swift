# Release Process

Release process:

Check out the latest code, or at the mark you want to release.
While the CI system is solid, it's worthwhile to do a fresh repository clone, run a full build, and all the relevant tests before proceeding.

This process adds a tag into the GitHub repository, but not until we've made a commit that explicitly sets up the downloadable packages from GitHub release artifacts.

Steps:

- Note the version you are intending to release.
The version's tag number gets used in a number of places through this process.
This example uses the version `0.1.0`.

```bash
git tag 0.1.0
git push origin --tags
```

- Open a browser and navigate to the URL that you can use to create a release on GitHub.
  - https://github.com/automerge/automerge-repo-swift/releases/new
  - choose the existing tag (`0.1.0` in this example)

  - Add a release title
  - Add in a description for the release
  - Select the checkout for a pre-release if relevant.

  - click `Publish release`

## Oops, I made a mistake - what do I do?

If something in the process goes awry, don't worry - that happens.
_Do not_ attempt to delete or move any tsgs that you've made.
Instead, just move on to the next semantic version and call it a day.
For example, when I was testing this process, I learned about the unsafe flags constraint at the last minute.
To resolve this, I repeated the process with the next tag `0.1.1` even though it didn't have any meaningful changes in the code.

