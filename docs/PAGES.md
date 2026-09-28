# Publishing the project homepage

The static homepage is `docs/index.html`. Its CSS and images use relative paths,
so it works both locally and under a GitHub Pages project path. There is no build
step or external site dependency.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8000 --directory docs
```

Open `http://localhost:8000/`.

## Publish from this repository

After the site files are pushed to `main`, open **Settings → Pages** in GitHub.
Set **Source** to **Deploy from a branch**, then select **main** and **/docs**
and save. The `.nojekyll` file tells Pages to serve the static files directly.
GitHub Pages will publish new changes to `docs/` after subsequent pushes to
`main`.

The current repository name is `HeadsetControl-MacOSTray`, so its normal project
site path uses that spelling: `https://chrislauinger77.github.io/HeadsetControl-MacOSTray/`.
To use the requested lowercase path,
`https://chrislauinger77.github.io/headsetcontrol-macostray/`, rename the GitHub
repository to `headsetcontrol-macostray` before publishing, or publish these
static files from a separate repository with that lowercase name. Review
release and cask integration before renaming the app repository.
